# frozen_string_literal: true

require "open3"
require "json"
require "prism"
require "rbconfig"
require "tmpdir"

module RailsAiContext
  module Tools
    class SecurityScan < BaseTool
      tool_name "rails_security_scan"
      description "Run Brakeman static security analysis on Rails app. " \
        "Use when: after editing controllers/models/views, reviewing code for vulnerabilities, or before deploying. " \
        "Filter with files:[\"app/controllers/users_controller.rb\"], set confidence:\"high\" to reduce noise."

      input_schema(
        properties: {
          files: {
            type: "array",
            items: { type: "string" },
            description: "File paths relative to Rails root to filter results (e.g. ['app/controllers/users_controller.rb']). Omit to scan entire app."
          },
          confidence: {
            type: "string",
            enum: %w[high medium weak],
            description: "Minimum confidence level for reported warnings. high: fewest results, most certain. weak: all warnings (default)."
          },
          checks: {
            type: "array",
            items: { type: "string" },
            description: "Run only specific checks by Brakeman class name (e.g. ['CheckSQL', 'CheckCrossSiteScripting']). Omit to run all checks."
          },
          detail: RailsAiContext::DetailLevel.schema("Detail level. summary: counts only. standard: warnings with file/line (default). full: warnings with code snippets and remediation links.")
        }
      )

      guide_row(
        order: 24,
        mcp: "rails_security_scan",
        summary: "Brakeman static analysis: SQL injection, XSS, mass assignment"
      )

      annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true, open_world_hint: false)

      CONFIDENCE_MAP = { "high" => 0, "medium" => 1, "weak" => 2 }.freeze
      CONFIDENCE_NAMES = { 0 => "High", 1 => "Medium", 2 => "Weak" }.freeze

      # Map friendly short names to actual Brakeman check class names.
      # Accepts: "sql", "SQL", "xss", "XSS", etc.
      # Full Brakeman names (e.g. "CheckSQL", "CheckCrossSiteScripting") pass through unchanged.
      CHECK_ALIASES = {
        "sql" => "CheckSQL", "SQL" => "CheckSQL",
        "SQLInjection" => "CheckSQL",
        "xss" => "CheckCrossSiteScripting", "XSS" => "CheckCrossSiteScripting",
        "CheckXSS" => "CheckCrossSiteScripting", "CrossSiteScripting" => "CheckCrossSiteScripting",
        "csrf" => "CheckForgerySetting", "CSRF" => "CheckForgerySetting",
        "CheckCSRF" => "CheckForgerySetting",
        "mass_assignment" => "CheckMassAssignment", "MassAssignment" => "CheckMassAssignment",
        "redirect" => "CheckRedirect", "Redirect" => "CheckRedirect",
        "file_access" => "CheckFileAccess", "FileAccess" => "CheckFileAccess",
        "command_injection" => "CheckExecute", "CommandInjection" => "CheckExecute",
        "CheckCommandInjection" => "CheckExecute",
        "deserialize" => "CheckDeserialize", "Deserialize" => "CheckDeserialize"
      }.freeze

      def self.call(files: nil, confidence: "weak", checks: nil, detail: "standard", server_context: nil)
        # A leading slash has always meant "from the Rails root here", and the
        # filter below strips it. Normalize first, so the guard reads the path
        # this tool means rather than refusing the app's own file.
        files = files.map { |f| f.to_s.delete_prefix("/") } if files
        # Filtering by a path outside the app would report "no warnings found
        # in /etc/passwd", which reads as a file this tool looked at.
        refused = refuse_unsafe_paths(files)
        return refused if refused

        min_confidence = CONFIDENCE_MAP[confidence] || 2
        resolved_checks = checks&.any? ? checks.map { |c| CHECK_ALIASES[c] || c } : nil

        scan = if brakeman_available?
          in_process_scan(min_confidence, resolved_checks)
        else
          # One machine, one scanner: the app's bundle not carrying brakeman
          # is not the same as the machine not having it, and the second one
          # can still answer - from outside the bundle, which is where it is.
          unbundled_scan(min_confidence, resolved_checks)
        end
        return text_response(unavailable_message(scan&.dig(:unavailable))) if scan.nil? || scan.key?(:unavailable)
        return text_response("Brakeman scan failed: #{portable_error(scan[:error])}") if scan[:error]

        warnings = scan[:warnings]
        checks_run = scan[:checks_run]
        source_note = scan[:note]

        if files&.any?
          # Check if specified files exist
          missing = files.select { |f| !File.exist?(rails_app.root.join(f)) }
          if missing.any? && missing.size == files.size
            return text_response("File(s) not found: #{missing.join(', ')}. Provide paths relative to Rails root.")
          end

          warnings = warnings.select do |w|
            path = w.file.relative
            files.any? { |f| path == f || path.start_with?(f) }
          end
        end

        warnings = warnings.sort_by { |w| [ w.confidence, w.file.relative, w.line || 0 ] }

        format_response(warnings, checks_run, detail, files, source_note)
      end

      # The scan brakeman runs in this process, when the app's bundle carries
      # it. Returns the same shape the unbundled run returns, so the renderer
      # never learns which of the two answered.
      private_class_method def self.in_process_scan(min_confidence, resolved_checks)
        options = {
          app_path: rails_app.root.to_s,
          quiet: true,
          report_progress: false,
          min_confidence: min_confidence,
          print_report: false,
          # Forked parse workers cannot Marshal the Binding web-console's bindex hangs on a parse error.
          parallel_checks: false
        }
        options[:run_checks] = Set.new(resolved_checks) if resolved_checks

        tracker = BrakemanGuard.quietly { Brakeman.run(options) }
        {
          warnings: tracker.filtered_warnings,
          checks_run: tracker.checks.checks_run.map(&:to_s)
        }
      rescue StandardError, ScriptError => e
        { error: e.message }
      end

      # The scan the installed brakeman runs as its own process, outside the
      # app's bundle. Its JSON carries what the renderer reads, so the two
      # tiers answer the same question with the same scanner rather than one
      # of them refusing.
      private_class_method def self.unbundled_scan(min_confidence, resolved_checks)
        version = brakeman_on_machine
        return nil unless version

        report, failure = run_brakeman_unbundled(min_confidence, resolved_checks)
        return { unavailable: failure } unless report.is_a?(Hash) && report["warnings"].is_a?(Array)

        # The newest on disk is not always the one the binstub ran.
        version = report.dig("scan_info", "brakeman_version") || version
        {
          # A report whose warnings array holds anything but objects is not a
          # report this can read, and one bad entry is not a reason to drop
          # the rest.
          warnings: report["warnings"].filter_map { |w| ExternalWarning.from_json(w) if w.is_a?(Hash) },
          checks_run: Array(report.dig("scan_info", "checks_performed")),
          note: unbundled_note(version)
        }
      end

      # The app's Gemfile.lock, read because a static run never loads the
      # app's bundle: not reaching brakeman here says nothing about it.
      private_class_method def self.locked_brakeman
        RailsAiContext::GemLock.for(rails_app.root.to_s).version("brakeman")
      end

      private_class_method def self.unbundled_note(version)
        locked = locked_brakeman
        return "_Scanned with brakeman #{version} as its own process; the app's Gemfile.lock carries brakeman #{locked}._" if locked

        "_Scanned with brakeman #{version} from outside the app's bundle, which does not carry it. " \
          "Add it to the Gemfile to scan in-process._"
      end

      # The file a warning is about, in the shape brakeman's own warning
      # answers: the renderer asks for `w.file.relative`.
      WarningFile = Data.define(:relative)

      # What the renderer reads off a warning, built from brakeman's JSON so
      # the unbundled scan and the in-process one render identically. Brakeman
      # sorts by a numeric confidence, which the JSON spells as a name.
      ExternalWarning = Data.define(:warning_type, :confidence, :confidence_name, :file, :line,
                                    :message, :cwe_id, :code, :link) do
        def self.from_json(warning)
          name = warning["confidence"].to_s
          ExternalWarning.new(
            warning_type: warning["warning_type"].to_s,
            confidence: CONFIDENCE_NAMES.key(name) || 2,
            confidence_name: name,
            file: WarningFile.new(relative: warning["file"].to_s),
            line: warning["line"],
            message: warning["message"].to_s,
            cwe_id: Array(warning["cwe_id"]),
            code: warning["code"],
            link: warning["link"]
          )
        end
      end

      # A scan of a large app is minutes of work, and a hung one must not hold
      # the tool open forever.
      SCAN_TIMEOUT = 300

      # `--version` loads brakeman and scans nothing: a second is plenty.
      VERSION_TIMEOUT = 30

      # How long a child gets to end on the polite signal before it gets the
      # one it cannot trap: popen3 waits on the process itself when the block
      # returns, so a child that ignores TERM holds the tool open through the
      # wait this timeout exists to bound.
      KILL_GRACE = 5

      # Brakeman as its own process, with the app's bundle out of the way.
      # `-w` counts the other direction from the API's min_confidence: level 3
      # is high-only, level 1 is everything.
      #
      # @return [Array(Hash, nil), Array(nil, String)] the parsed report, or
      #   nil and the last line brakeman printed about why there is none
      #
      # The report goes to a file of its own rather than stdout: the binstub a
      # gem manager installs can print there first (RVM's executable-hooks
      # writes "Resolving dependencies..."), and a report parsed off stdout
      # died on that first byte.
      # A frame says where brakeman stopped, not why: Ruby prints the error
      # first (`file:12:in 'scan': message (Class)`) and the frames after it.
      BACKTRACE_FRAME = /\A(?:from\s+)?\S+:\d+:in\s/
      ERROR_LOCATION = /\A\S+:\d+:in\s+[`'][^`']*[`']:\s+/

      PATH_TAIL = %r{(?:[^\s'"`:,/]+/)*([^\s'"`:,/]+)}
      ABSOLUTE_PATH = %r{(?<![\w.:/~])/(?:[^\s'"`:,/]+/)+([^\s'"`:,/]+)}
      # Below a known root, a folder may hold an inner space when the file it leads to exists.
      SPACED_FOLDER = %r{[^\s'"`:,/](?:[^\n'"`:,/]*[^\s'"`:,/])?/}
      FILE_NAME = %r{[^\s'"`:,/]+\.\w+(?![^\s'"`:,/]*/)}

      # The answer leaves the machine: a file in the app is named from its root, any other by its base name.
      # The roots go by name first, since a space in one (/home/John Doe) breaks the folder run before it.
      private_class_method def self.portable_error(message)
        text = RailsAiContext::PortablePath.relativize_text(message, rails_app.root)
        roots = [ Dir.home, *Gem.path, Gem.dir ].map(&:to_s).reject { |root| root.empty? || root == "/" }
        unless roots.empty?
          known = roots.uniq.sort_by { |root| -root.length }.map { |root| Regexp.escape(root) }.join("|")
          text = existing_files_by_name(text, %r{(?:#{known})/})
          text = text.gsub(%r{(?:#{known})/#{PATH_TAIL}}, '\1')
        end
        text.gsub(ABSOLUTE_PATH, '\1')
      end

      # Each path after a known root that is a file on this machine, by its base name: the
      # first file-name end on the line that exists, as a dotted folder (`v1.2 build/`) ends one too.
      private_class_method def self.existing_files_by_name(text, root)
        out = +""
        pos = 0
        while (found = root.match(text, pos))
          start = found.begin(0)
          line = text[start...(text.index("\n", start) || text.size)]
          path = existing_path(line, found[0].size)
          out << text[pos...start] << (path ? File.basename(path) : found[0])
          pos = start + (path || found[0]).size
        end
        out << text[pos..]
      end

      private_class_method def self.existing_path(line, from)
        tail = line[from..]
        tail.to_enum(:scan, FILE_NAME).map { Regexp.last_match.end(0) }.each do |stop|
          next unless tail[0...stop].match?(%r{\A(?:#{SPACED_FOLDER})*#{FILE_NAME}\z})

          path = line[0, from + stop]
          return path if File.exist?(path)
        end
        nil
      end

      private_class_method def self.brakeman_error_line(err)
        lines = err.to_s.lines.map(&:strip).reject(&:empty?)
        raised = lines.find { |line| line.match?(ERROR_LOCATION) }
        return raised.sub(ERROR_LOCATION, "") if raised

        lines.reject { |line| line.match?(BACKTRACE_FRAME) }.last || lines.last
      end

      private_class_method def self.run_brakeman_unbundled(min_confidence, resolved_checks)
        brakeman = brakeman_command or return [ nil, nil ]

        Dir.mktmpdir("rails-ai-context-brakeman") do |dir|
          report_path = File.join(dir, "report.json")
          command = [ *brakeman, "--format", "json", "--output", report_path, "--quiet",
                      "--no-exit-on-warn", "--no-exit-on-error",
                      "--confidence-level", (3 - min_confidence).to_s, "--path", rails_app.root.to_s ]
          command += [ "--test", resolved_checks.join(",") ] if resolved_checks&.any?

          _out, err = with_unbundled_env { capture_with_timeout(command) }
          next [ nil, "no report after #{SCAN_TIMEOUT} seconds" ] if err.nil?
          next [ nil, brakeman_error_line(err) ] unless File.file?(report_path) && File.size?(report_path)

          [ JSON.parse(File.read(report_path)), nil ]
        end
      rescue StandardError => e
        RailsAiContext.debug_fail(e, [ nil, e.message ], label: "run_brakeman_unbundled")
      end

      # The installed gem's own script, run by this Ruby: not whatever
      # `brakeman` resolves to on PATH, and not the binstub, which RubyGems
      # writes to its bindir, outside every gem directory. The script puts
      # its own lib on the load path, so it runs with no bundle at all.
      private_class_method def self.brakeman_command
        script = brakeman_spec_on_machine&.bin_file("brakeman")
        [ RbConfig.ruby, script ] if script && File.file?(script)
      end

      # Why the brakeman outside the app's bundle would not run, or nil when
      # it answers `--version` the way the scan runs it. Doctor asks, so it
      # never says the scan runs a brakeman that this tool cannot start.
      def self.unbundled_failure
        command = brakeman_command or return "the installed gem has no bin/brakeman"
        out, err = with_unbundled_env { capture_with_timeout([ *command, "--version" ], seconds: VERSION_TIMEOUT) }
        return "`brakeman --version` gave no answer in #{VERSION_TIMEOUT} seconds" if out.nil?
        return nil if out.match?(/^brakeman \d/)

        portable_error(brakeman_error_line(err) || "`brakeman --version` printed no version")
      rescue StandardError => e
        RailsAiContext.debug_fail(e, e.message, label: "unbundled_failure")
      end

      # Bundler narrows the environment for child processes as well as for
      # this one, so the child has to be told to forget it.
      private_class_method def self.with_unbundled_env(&block)
        return yield unless defined?(Bundler) && Bundler.respond_to?(:with_unbundled_env)

        Bundler.with_unbundled_env(&block)
      end

      # Readers drain both pipes, so a report larger than the pipe buffer
      # cannot deadlock the wait, and a scan that never ends is killed rather
      # than waited on.
      #
      # @return [Array(String, String), nil] stdout and stderr, or nil on timeout
      private_class_method def self.capture_with_timeout(command, seconds: SCAN_TIMEOUT)
        Open3.popen3(*command) do |stdin, stdout, stderr, wait|
          stdin.close
          out = Thread.new { stdout.read }
          err = Thread.new { stderr.read }

          unless wait.join(seconds)
            stop(wait)
            out.kill
            err.kill
            next nil
          end

          [ out.value, err.value ]
        end
      end

      # A child that is already gone raises ESRCH, which is the outcome asked
      # for either way. Windows sends no TERM to another process (EINVAL);
      # KILL is how it stops one.
      private_class_method def self.stop(wait)
        unless Gem.win_platform?
          Process.kill("TERM", wait.pid)
          return if wait.join(KILL_GRACE)
        end

        Process.kill("KILL", wait.pid)
      rescue Errno::ESRCH
        nil
      end

      # Keyed by tier, because the two tiers ask a different question of the
      # same machine: booted, the app's bundle is set up and the load path
      # holds the app's gems only, so an app that does not bundle brakeman
      # cannot require it even though `gem list` shows it.
      # Returns `:bundle` (with its version), `:machine`, or nil. Doctor answers from this, so
      # it says what the scan would do.
      def self.brakeman_location
        return [ :bundle, ::Brakeman::Version ] if brakeman_available? && defined?(::Brakeman::Version)

        version = brakeman_on_machine
        version ? [ :machine, version ] : [ nil, nil ]
      end

      private_class_method def self.brakeman_available?
        @brakeman_available = {} unless @brakeman_available.is_a?(Hash)
        key = RailsAiContext.static_tier? ? :static : :runtime
        return @brakeman_available[key] unless @brakeman_available[key].nil?

        @brakeman_available[key] = load_brakeman
      end

      private_class_method def self.load_brakeman
        BrakemanGuard.quietly { require "brakeman" }
        true
      rescue LoadError
        false
      end

      # The remedy has to match what is actually wrong. "Add it to your
      # Gemfile" is the wrong instruction for a machine that already has the
      # gem and an app whose bundle simply does not carry it.
      private_class_method def self.unavailable_message(failure = nil)
        version = brakeman_on_machine
        said = failure ? " It said: `#{portable_error(failure)}`." : ""
        locked = locked_brakeman
        if locked
          problem = version ? "running brakeman #{version} produced no report.#{said}" : "it is not installed on this machine."
          return "This app's Gemfile.lock carries brakeman #{locked}, but #{problem}\n\n" \
                 "Run `bundle install`, then `bundle exec brakeman` in the app directory to see what it says."
        end
        return (
          "Brakeman #{version} is installed on this machine but not in this app's bundle, and running it from " \
          "outside the bundle produced no report either.#{said}\n\n" \
          "Add it to the Gemfile so the scan runs in this process:\n\n" \
          "```ruby\ngem 'brakeman', group: :development\n```\n\n" \
          "Then run `bundle install`. Running `brakeman` in the app directory shows what the outside run hit."
        ) if version

        "Brakeman is not installed. Add it to your Gemfile:\n\n" \
        "```ruby\ngem 'brakeman', group: :development\n```\n\n" \
        "Then run `bundle install` and try again."
      end

      private_class_method def self.brakeman_on_machine
        brakeman_spec_on_machine&.version&.to_s
      end

      # The newest brakeman installed on this machine, read off the gem
      # directories rather than asked of Gem::Specification: under Bundler the
      # spec set is the app's bundle, which is exactly the set that does not
      # have it.
      private_class_method def self.brakeman_spec_on_machine
        # `brakeman-*` also matches brakeman-lib, a different gem: a version
        # starts with a digit.
        specs = Gem.path.flat_map { |dir|
          Dir.glob(File.join(dir, "specifications", "brakeman-*.gemspec"))
        }.filter_map { |path| (version = File.basename(path)[/\Abrakeman-(\d[^-]*)\.gemspec\z/, 1]) && [ version, path ] }

        newest = specs.max_by { |version, _| Gem::Version.new(version) rescue Gem::Version.new("0") } or return nil
        Gem::Specification.load(newest.last)
      rescue StandardError => e
        RailsAiContext.debug_fail(e, nil, label: "brakeman_spec_on_machine")
      end

      # `checks` is the list of check names that ran, whichever scanner ran
      # them: the renderer knows a scan, not a Tracker.
      private_class_method def self.format_response(warnings, checks, detail, files, note = nil)
        checks_run = checks.size

        if warnings.empty?
          scope = files&.any? ? " in #{files.join(', ')}" : ""
          # Summarize what categories were checked for transparency
          check_names = checks.map { |c| c.to_s.gsub(/([a-z])([A-Z])/, '\1 \2') }
          categories = check_names.first(6).join(", ")
          categories += ", ..." if check_names.size > 6
          body = "No security warnings found#{scope}. (#{count_phrase(checks_run, "check")} run: #{categories})"
        else
          body = case detail
          when "summary" then format_summary(warnings, checks_run)
          when "full" then format_full(warnings, checks_run)
          else format_standard(warnings, checks_run)
          end
        end

        text_response([ body, note ].compact.join("\n\n"))
      end

      # Three detail levels open with the same headline.
      private_class_method def self.scan_headline(warnings, checks_run)
        "**#{count_phrase(warnings.size, "warning")}** (#{count_phrase(checks_run, "check")} run)"
      end

      private_class_method def self.format_summary(warnings, checks_run)
        by_type = warnings.group_by(&:warning_type)
        by_confidence = warnings.group_by { |w| w.confidence_name }

        lines = [ "# Security Scan Summary", "" ]
        lines << scan_headline(warnings, checks_run)
        lines << ""
        lines << "## By Confidence"
        %w[High Medium Weak].each do |level|
          count = (by_confidence[level] || []).size
          lines << "- #{level}: #{count}" if count > 0
        end
        lines << ""
        lines << "## By Type"
        by_type.sort_by { |_, ws| -ws.size }.each do |type, ws|
          lines << "- #{type}: #{ws.size}"
        end
        lines << "" << "_Use `detail:\"standard\"` for file locations, or `detail:\"full\"` for code and remediation._"
        lines.join("\n")
      end

      private_class_method def self.format_standard(warnings, checks_run)
        lines = [ "# Security Scan Results", "" ]
        lines << scan_headline(warnings, checks_run)

        current_type = nil
        warnings.each do |w|
          if w.warning_type != current_type
            current_type = w.warning_type
            lines << "" << "## #{current_type}"
          end
          loc = w.line ? "#{w.file.relative}:#{w.line}" : w.file.relative
          lines << "- [#{w.confidence_name}] #{loc} - #{w.message}"
        end
        lines.join("\n")
      end

      private_class_method def self.format_full(warnings, checks_run)
        lines = [ "# Security Scan Results (Full)", "" ]
        lines << scan_headline(warnings, checks_run)
        # A file is read and filtered once, however many warnings it holds.
        sources = Hash.new { |read, path| read[path] = read_source(path) }

        warnings.each do |w|
          lines << ""
          lines << "### #{w.warning_type} [#{w.confidence_name}]"
          loc = w.line ? "#{w.file.relative}:#{w.line}" : w.file.relative
          lines << "- **File:** #{loc}"
          lines << "- **Message:** #{w.message}"
          lines << "- **CWE:** #{Array(w.cwe_id).join(', ')}" if w.cwe_id&.any?

          code = w.code && warning_source(w, sources[w.file.relative])
          if code
            lines << "- **Code:**"
            lines << "  ```#{RailsAiContext::ViewFile.fence(w.file.relative)}"
            code.each { |line| lines << "  #{line}".rstrip }
            lines << "  ```"
          end

          lines << "- **More info:** #{w.link}" if w.link
        end
        lines.join("\n")
      end

      # A statement longer than this is shown by the one line the warning names.
      MAX_CODE_LINES = 12

      # A file a warning names, as written and with each line filtered as every
      # slice of the app's source a tool shows is: the whole file at once, so a
      # line inside a PEM key still knows it is in one. Nil for a file this tool
      # may not read.
      private_class_method def self.read_source(path)
        content, = RailsAiContext::SafePath.read(path, under: rails_app.root.to_s)
        content && [ content, RailsAiContext::Redaction.redact_source_lines(content.lines.map(&:chomp), path: path) ]
      end

      # The code a warning is about, as its file has it. Brakeman's own code
      # line is not the file: it writes the value of each variable and constant
      # it can follow in place of the name, so a literal assigned to `api_token`
      # a line up, or to a constant in an initializer, sat in the call with no
      # name beside it for the filter to know it by.
      #
      # @return [Array<String>, nil] the lines, or nil when the warning names no
      #   line of a file this tool may read
      private_class_method def self.warning_source(warning, source)
        content, redacted = source
        line = warning.line.to_i
        return nil unless redacted && line.between?(1, redacted.size)

        span = statement_span(content, line, warning.file.relative)
        shown = redacted[span.begin - 1, span.size]
        indent = shown.reject { |text| text.strip.empty? }.map { |text| text[/\A\s*/].size }.min.to_i
        shown.map { |text| text[indent..].to_s }
      end

      # Brakeman names the line its input is on, which in a call written across
      # lines can be a lone `:role,`. In Ruby the innermost statement holding
      # that line is what reads, when it fits in MAX_CODE_LINES.
      private_class_method def self.statement_span(content, line, path)
        return line..line unless File.extname(path) == ".rb"

        holds = ->(node) { node.location.start_line <= line && line <= node.location.end_line }
        found = nil
        nodes = [ RailsAiContext::AstCache.parse_string(content).value ]
        while (node = nodes.shift)
          # A `#{...}` holds statements too, but they are part of the string.
          next if node.is_a?(Prism::EmbeddedStatementsNode)

          if node.is_a?(Prism::StatementsNode)
            node.body.select(&holds).each do |statement|
              found = statement.location if found.nil? || statement.location.length < found.length
            end
          end
          # A node that does not reach the line holds nothing that does.
          nodes.concat(node.compact_child_nodes.select(&holds))
        end
        return line..line unless found && found.end_line - found.start_line < MAX_CODE_LINES

        found.start_line..found.end_line
      end
    end
  end
end
