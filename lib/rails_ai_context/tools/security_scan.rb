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
            description: "Run only specific checks (e.g. ['CheckSQL', 'CheckXSS']). Omit to run all checks."
          },
          detail: {
            type: "string",
            enum: %w[summary standard full],
            description: "Detail level. summary: counts only. standard: warnings with file/line (default). full: warnings with code snippets and remediation links."
          }
        }
      )

      annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true, open_world_hint: false)

      CONFIDENCE_MAP = { "high" => 0, "medium" => 1, "weak" => 2 }.freeze
      CONFIDENCE_NAMES = { 0 => "High", 1 => "Medium", 2 => "Weak" }.freeze

      def self.call(files: nil, confidence: "weak", checks: nil, detail: "standard", server_context: nil)
        unless brakeman_available?
          return text_response(
            "Brakeman is not installed. Add it to your Gemfile:\n\n" \
            "```ruby\ngem 'brakeman', group: :development\n```\n\n" \
            "Then run `bundle install` and try again."
          )
        end

        min_confidence = CONFIDENCE_MAP[confidence] || 2

        options = {
          app_path: Rails.root.to_s,
          quiet: true,
          report_progress: false,
          min_confidence: min_confidence,
          print_report: false
        }

        options[:run_checks] = Set.new(checks) if checks&.any?

        tracker = begin
          Brakeman.run(options)
        rescue => e
          return text_response("Brakeman scan failed: #{e.message}")
        end

        warnings = tracker.filtered_warnings

        if files&.any?
          normalized = files.map { |f| f.delete_prefix("/") }
          warnings = warnings.select do |w|
            path = w.file.relative
            normalized.any? { |f| path == f || path.start_with?(f) }
          end
        end

        warnings = warnings.sort_by { |w| [ w.confidence, w.file.relative, w.line || 0 ] }

        format_response(warnings, tracker, detail, files)
      end

      private_class_method def self.brakeman_available?
        return @brakeman_available unless @brakeman_available.nil?

        @brakeman_available = begin
          require "brakeman"
          true
        rescue LoadError
          false
        end
      end

      private_class_method def self.format_response(warnings, tracker, detail, files)
        checks_run = tracker.checks.checks_run.size

        if warnings.empty?
          scope = files&.any? ? " in #{files.join(', ')}" : ""
          return text_response("No security warnings found#{scope}. (#{checks_run} checks run)")
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

      private_class_method def self.format_summary(warnings, checks_run)
        by_type = warnings.group_by(&:warning_type)
        by_confidence = warnings.group_by { |w| w.confidence_name }

        lines = [ "# Security Scan Summary", "" ]
        lines << "**#{warnings.size} warnings** (#{checks_run} checks run)"
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
        lines << "**#{warnings.size} warnings** (#{checks_run} checks run)"

        current_type = nil
        warnings.each do |w|
          if w.warning_type != current_type
            current_type = w.warning_type
            lines << "" << "## #{current_type}"
          end
          loc = w.line ? "#{w.file.relative}:#{w.line}" : w.file.relative
          lines << "- [#{w.confidence_name}] #{loc} — #{w.message}"
        end

        text_response(lines.join("\n"))
      end

      private_class_method def self.format_full(warnings, checks_run)
        lines = [ "# Security Scan Results (Full)", "" ]
        lines << "**#{warnings.size} warnings** (#{checks_run} checks run)"

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
