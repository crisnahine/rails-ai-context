# frozen_string_literal: true

require "open3"
require "json"
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
        return text_response(unavailable_message) unless scan
        return text_response("Brakeman scan failed: #{scan[:error]}") if scan[:error]

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
          print_report: false
        }
        options[:run_checks] = Set.new(resolved_checks) if resolved_checks

        tracker = Brakeman.run(options)
        {
          warnings: tracker.filtered_warnings,
          checks_run: tracker.checks.checks_run.map(&:to_s)
        }
      rescue => e
        { error: e.message }
      end

      # The scan the installed brakeman runs as its own process, outside the
      # app's bundle. Its JSON carries what the renderer reads, so the two
      # tiers answer the same question with the same scanner rather than one
      # of them refusing.
      private_class_method def self.unbundled_scan(min_confidence, resolved_checks)
        version = brakeman_on_machine
        return nil unless version

        report = run_brakeman_unbundled(min_confidence, resolved_checks)
        return nil unless report.is_a?(Hash) && report["warnings"].is_a?(Array)

        {
          # A report whose warnings array holds anything but objects is not a
          # report this can read, and one bad entry is not a reason to drop
          # the rest.
          warnings: report["warnings"].filter_map { |w| ExternalWarning.from_json(w) if w.is_a?(Hash) },
          checks_run: Array(report.dig("scan_info", "checks_performed")),
          note: "_Scanned with brakeman #{version} from outside the app's bundle, which does not carry it. " \
                "Add it to the Gemfile to scan in-process._"
        }
      end

      # The file a warning is about, in the shape brakeman's own warning
      # answers: the renderer asks for `w.file.relative`.
      WarningFile = Data.define(:relative)

      # What the renderer reads off a warning, built from brakeman's JSON so
      # the unbundled scan and the in-process one render identically. Brakeman
      # sorts by a numeric confidence, which the JSON spells as a name.
      ExternalWarning = Data.define(:warning_type, :confidence, :confidence_name, :file, :line,
                                    :message, :cwe_id, :code, :link) do
        def format_code = code

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

      # How long a child gets to end on the polite signal before it gets the
      # one it cannot trap: popen3 waits on the process itself when the block
      # returns, so a child that ignores TERM holds the tool open through the
      # wait this timeout exists to bound.
      KILL_GRACE = 5

      # Brakeman as its own process, with the app's bundle out of the way.
      # `-w` counts the other direction from the API's min_confidence: level 3
      # is high-only, level 1 is everything.
      #
      # @return [Hash, nil] the parsed report, or nil when it could not run
      #
      # The report goes to a file of its own rather than stdout: the binstub a
      # gem manager installs can print there first (RVM's executable-hooks
      # writes "Resolving dependencies..."), and a report parsed off stdout
      # died on that first byte.
      private_class_method def self.run_brakeman_unbundled(min_confidence, resolved_checks)
        executable = brakeman_executable or return nil

        Dir.mktmpdir("rails-ai-context-brakeman") do |dir|
          report_path = File.join(dir, "report.json")
          command = [ executable, "--format", "json", "--output", report_path, "--quiet",
                      "--no-exit-on-warn", "--no-exit-on-error",
                      "--confidence-level", (3 - min_confidence).to_s, "--path", rails_app.root.to_s ]
          command += [ "--test", resolved_checks.join(",") ] if resolved_checks&.any?

          with_unbundled_env { capture_with_timeout(command) } or next nil
          next nil unless File.file?(report_path) && File.size?(report_path)

          JSON.parse(File.read(report_path))
        end
      rescue StandardError => e
        RailsAiContext.debug_fail(e, nil, label: "run_brakeman_unbundled")
      end

      # The gem's own executable, not whatever `brakeman` resolves to on PATH.
      private_class_method def self.brakeman_executable
        Gem.path.map { |dir| File.join(dir, "bin", "brakeman") }.find { |path| File.executable?(path) }
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
      private_class_method def self.capture_with_timeout(command)
        Open3.popen3(*command) do |stdin, stdout, stderr, wait|
          stdin.close
          out = Thread.new { stdout.read }
          err = Thread.new { stderr.read }

          unless wait.join(SCAN_TIMEOUT)
            stop(wait)
            out.kill
            err.kill
            next nil
          end

          err.value
          out.value
        end
      end

      # A child that is already gone raises ESRCH, which is the outcome asked
      # for either way.
      private_class_method def self.stop(wait)
        Process.kill("TERM", wait.pid)
        return if wait.join(KILL_GRACE)

        Process.kill("KILL", wait.pid)
      rescue Errno::ESRCH
        nil
      end

      # Keyed by tier, because the two tiers ask a different question of the
      # same machine: booted, the app's bundle is set up and the load path
      # holds the app's gems only, so an app that does not bundle brakeman
      # cannot require it even though `gem list` shows it.
      private_class_method def self.brakeman_available?
        @brakeman_available = {} unless @brakeman_available.is_a?(Hash)
        key = RailsAiContext.static_tier? ? :static : :runtime
        return @brakeman_available[key] unless @brakeman_available[key].nil?

        @brakeman_available[key] = load_brakeman
      end

      private_class_method def self.load_brakeman
        require "brakeman"
        true
      rescue LoadError
        false
      end

      # The remedy has to match what is actually wrong. "Add it to your
      # Gemfile" is the wrong instruction for a machine that already has the
      # gem and an app whose bundle simply does not carry it.
      private_class_method def self.unavailable_message
        version = brakeman_on_machine
        return (
          "Brakeman #{version} is installed on this machine but not in this app's bundle, and running it from " \
          "outside the bundle produced no report either.\n\n" \
          "Add it to the Gemfile so the scan runs in this process:\n\n" \
          "```ruby\ngem 'brakeman', group: :development\n```\n\n" \
          "Then run `bundle install`. Running `brakeman` in the app directory shows what the outside run hit."
        ) if version

        "Brakeman is not installed. Add it to your Gemfile:\n\n" \
        "```ruby\ngem 'brakeman', group: :development\n```\n\n" \
        "Then run `bundle install` and try again."
      end

      # The newest brakeman installed on this machine, read off the gem
      # directories rather than asked of Gem::Specification: under Bundler the
      # spec set is the app's bundle, which is exactly the set that does not
      # have it.
      private_class_method def self.brakeman_on_machine
        # `brakeman-*` also matches brakeman-lib, a different gem: a version
        # starts with a digit.
        versions = Gem.path.flat_map { |dir|
          Dir.glob(File.join(dir, "specifications", "brakeman-*.gemspec"))
        }.filter_map { |path| File.basename(path)[/\Abrakeman-(\d[^-]*)\.gemspec\z/, 1] }

        versions.max_by { |v| Gem::Version.new(v) rescue Gem::Version.new("0") }
      rescue StandardError => e
        RailsAiContext.debug_fail(e, nil, label: "brakeman_on_machine")
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
          return text_response([ "No security warnings found#{scope}. (#{count_phrase(checks_run, "check")} run: #{categories})", note ].compact.join("\n\n"))
        end

        case detail
        when "summary"
          format_summary(warnings, checks_run, note)
        when "full"
          format_full(warnings, checks_run, note)
        else
          format_standard(warnings, checks_run, note)
        end
      end

      # Three detail levels open with the same headline.
      private_class_method def self.scan_headline(warnings, checks_run)
        "**#{count_phrase(warnings.size, "warning")}** (#{count_phrase(checks_run, "check")} run)"
      end

      private_class_method def self.format_summary(warnings, checks_run, note = nil)
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
        lines << "" << note if note

        text_response(lines.join("\n"))
      end

      private_class_method def self.format_standard(warnings, checks_run, note = nil)
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
        lines << "" << note if note

        text_response(lines.join("\n"))
      end

      private_class_method def self.format_full(warnings, checks_run, note = nil)
        lines = [ "# Security Scan Results (Full)", "" ]
        lines << scan_headline(warnings, checks_run)

        warnings.each do |w|
          lines << ""
          lines << "### #{w.warning_type} [#{w.confidence_name}]"
          loc = w.line ? "#{w.file.relative}:#{w.line}" : w.file.relative
          lines << "- **File:** #{loc}"
          lines << "- **Message:** #{w.message}"
          lines << "- **CWE:** #{Array(w.cwe_id).join(', ')}" if w.cwe_id&.any?

          if w.code
            lines << "- **Code:**"
            lines << "  ```ruby"
            lines << "  #{w.format_code}"
            lines << "  ```"
          end

          lines << "- **More info:** #{w.link}" if w.link
        end
        lines << "" << note if note

        text_response(lines.join("\n"))
      end
    end
  end
end
