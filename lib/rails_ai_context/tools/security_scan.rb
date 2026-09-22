# frozen_string_literal: true

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

        return text_response(unavailable_message) unless brakeman_available?

        min_confidence = CONFIDENCE_MAP[confidence] || 2

        options = {
          app_path: rails_app.root.to_s,
          quiet: true,
          report_progress: false,
          min_confidence: min_confidence,
          print_report: false
        }

        if checks&.any?
          resolved = checks.map { |c| CHECK_ALIASES[c] || c }
          options[:run_checks] = Set.new(resolved)
        end

        tracker = begin
          Brakeman.run(options)
        rescue => e
          return text_response("Brakeman scan failed: #{e.message}")
        end

        warnings = tracker.filtered_warnings

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

        format_response(warnings, tracker, detail, files)
      end

      # Keyed by tier, because the two tiers ask a different question of the
      # same machine: booted, the app's bundle is set up and the load path
      # holds the app's gems only, so an app that does not bundle brakeman
      # cannot require it even though `gem list` shows it. One process-wide
      # boolean let whichever tier answered first decide for the other.
      private_class_method def self.brakeman_available?
        @brakeman_available ||= {}
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
          "Brakeman #{version} is installed on this machine but not in this app's bundle, so it cannot load " \
          "under the app's load path.\n\n" \
          "Scan with it by running `rails-ai-context tool security_scan --no-boot`, which reads the source " \
          "without booting the app, or add it to the Gemfile:\n\n" \
          "```ruby\ngem 'brakeman', group: :development\n```\n\n" \
          "Then run `bundle install`."
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
        versions = Gem.path.flat_map { |dir|
          Dir.glob(File.join(dir, "specifications", "brakeman-*.gemspec"))
        }.filter_map { |path| File.basename(path)[/\Abrakeman-(.+)\.gemspec\z/, 1] }

        versions.max_by { |v| Gem::Version.new(v) rescue Gem::Version.new("0") }
      rescue StandardError => e
        RailsAiContext.debug_fail(e, nil, label: "brakeman_on_machine")
      end

      private_class_method def self.format_response(warnings, tracker, detail, files)
        checks_run = tracker.checks.checks_run.size

        if warnings.empty?
          scope = files&.any? ? " in #{files.join(', ')}" : ""
          # Summarize what categories were checked for transparency
          check_names = tracker.checks.checks_run.map do |c|
            c.to_s.sub(/\ABrakeman::Checks::Check/, "").gsub(/([a-z])([A-Z])/, '\1 \2')
          end
          categories = check_names.first(6).join(", ")
          categories += ", ..." if check_names.size > 6
          return text_response("No security warnings found#{scope}. (#{count_phrase(checks_run, "check")} run: #{categories})")
        end

        case detail
        when "summary"
          format_summary(warnings, checks_run)
        when "full"
          format_full(warnings, checks_run)
        else
          format_standard(warnings, checks_run)
        end
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

        text_response(lines.join("\n"))
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

        text_response(lines.join("\n"))
      end

      private_class_method def self.format_full(warnings, checks_run)
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

        text_response(lines.join("\n"))
      end
    end
  end
end
