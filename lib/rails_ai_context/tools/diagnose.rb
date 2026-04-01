# frozen_string_literal: true

require "open3"

module RailsAiContext
  module Tools
    class Diagnose < BaseTool
      tool_name "rails_diagnose"
      description "One-call error diagnosis: parses the error, classifies it, gathers controller/model/schema context, " \
        "shows recent git changes, pulls relevant logs, and suggests a fix. " \
        "Use when: you hit an error and need to understand why. " \
        "Key params: error (required — paste the error message), file, line, action (controller#action)."

      input_schema(
        properties: {
          error: {
            type: "string",
            description: "Error message or exception (e.g. 'NoMethodError: undefined method `foo` for nil:NilClass')."
          },
          file: {
            type: "string",
            description: "File where error occurs, relative to Rails root (e.g. 'app/controllers/cooks_controller.rb')."
          },
          line: {
            type: "integer",
            description: "Line number where the error occurs."
          },
          action: {
            type: "string",
            description: "Controller#action format (e.g. 'cooks#create'). Pulls full action context."
          }
        },
        required: %w[error]
      )

      annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: false, open_world_hint: true)

      # ── Error classification ──────────────────────────────────────────

      ERROR_CLASSIFICATIONS = {
        /NoMethodError|NameError/ => {
          type: :nil_reference,
          likely: "A method was called on nil or an undefined name was referenced. Check for: missing association, unfetched record, typo in method name.",
          fix: "1. Check the variable/object is not nil before calling the method\n2. Verify the association or attribute exists on the model\n3. Use `&.` safe navigation if the value can legitimately be nil"
        },
        /RecordNotFound/ => {
          type: :record_not_found,
          likely: "A `.find()` or `.find_by!()` call failed because the record doesn't exist. Common causes: stale URL, deleted record, wrong ID parameter.",
          fix: "1. Use `.find_by` (returns nil) instead of `.find` (raises)\n2. Add a rescue handler or `before_action :set_record` with proper error handling\n3. Check the route parameter name matches what the controller expects"
        },
        /RecordInvalid|RecordNotSaved/ => {
          type: :validation_failure,
          likely: "A `.save!`, `.create!`, or `.update!` call failed validation. The model has validations that the submitted data doesn't satisfy.",
          fix: "1. Use `.save` (returns false) instead of `.save!` (raises) for user-facing flows\n2. Check model validations against the params being submitted\n3. Verify required associations exist before saving"
        },
        /RoutingError/ => {
          type: :routing,
          likely: "No route matches the request. The URL or HTTP verb doesn't match any defined route.",
          fix: "1. Run `rails_get_routes` to see all defined routes\n2. Check the HTTP verb (GET vs POST vs PATCH) matches\n3. Verify the route is not restricted by constraints"
        },
        /ParameterMissing/ => {
          type: :strong_params,
          likely: "A required parameter is missing from the request. The `params.require(:key)` call didn't find the expected key.",
          fix: "1. Check the form field names match what strong params expects\n2. Verify the parameter nesting (e.g., `params[:user][:name]` vs `params[:name]`)\n3. Check the controller's `*_params` method"
        },
        /StatementInvalid|UndefinedColumn|UndefinedTable/ => {
          type: :schema_mismatch,
          likely: "A database query references a column or table that doesn't exist. Common after migrations or in stale schema.",
          fix: "1. Run `rails db:migrate` to apply pending migrations\n2. Check `rails_get_schema(table:\"...\")` for actual column names\n3. Verify the migration was generated correctly"
        },
        /Template::Error|ActionView/ => {
          type: :view_error,
          likely: "An error occurred while rendering a view template. The underlying error is usually a NoMethodError or missing local variable.",
          fix: "1. Check the instance variables set in the controller action\n2. Verify partial locals are passed correctly\n3. Use `rails_get_view(controller:\"...\")` to see template structure"
        },
        /ArgumentError/ => {
          type: :argument_error,
          likely: "A method received wrong number or type of arguments.",
          fix: "1. Check the method signature matches the call site\n2. Use `rails_search_code(pattern:\"method_name\", match_type:\"trace\")` to see definition and callers"
        }
      }.freeze

      def self.call(error:, file: nil, line: nil, action: nil, server_context: nil)
        return text_response("The `error` parameter is required.") if error.nil? || error.strip.empty?

        parsed = parse_error(error)
        classification = classify_error(parsed)

        lines = [ "# Error Diagnosis", "" ]
        lines << "**Error:** `#{parsed[:exception_class] || 'Unknown'}`"
        lines << "**Message:** #{parsed[:message]}"
        lines << "**Classification:** #{classification[:type]}"
        lines << ""

        # Likely cause
        lines << "## Likely Cause"
        lines << classification[:likely]
        lines << ""

        # Suggested fix
        lines << "## Suggested Fix"
        lines << classification[:fix]
        lines << ""

        # Gather context based on parameters and error type
        lines.concat(gather_context(parsed, classification, file, line, action))

        # Recent git changes
        git_section = gather_git_context(file, parsed[:file_refs])
        lines.concat(git_section) if git_section.any?

        # Recent error logs
        log_section = gather_log_context(parsed[:exception_class])
        lines.concat(log_section) if log_section.any?

        # Next steps
        lines << "## Next Steps"
        if file
          lines << "_Use `rails_get_edit_context(file:\"#{file}\", near:\"#{parsed[:method_name] || line || parsed[:exception_class]}\")` to see the code._"
        end
        if parsed[:method_name]
          lines << "_Use `rails_search_code(pattern:\"#{parsed[:method_name]}\", match_type:\"trace\")` to trace the method._"
        end

        text_response(lines.join("\n"))
      rescue => e
        text_response("Diagnosis error: #{e.message}")
      end

      class << self
        private

        def parse_error(error_string)
          result = { exception_class: nil, message: error_string.strip, file_refs: [], method_name: nil }

          # Extract exception class: "NoMethodError: ..." or "ActiveRecord::RecordNotFound ..."
          if (m = error_string.match(/\A([\w:]+(?:Error|Exception|Invalid|NotFound|NotSaved|Missing))\s*[:—]\s*(.*)/m))
            result[:exception_class] = m[1]
            result[:message] = m[2].strip
          elsif (m = error_string.match(/\A([\w:]+::\w+)\s*[:—]\s*(.*)/m))
            result[:exception_class] = m[1]
            result[:message] = m[2].strip
          end

          # Extract file:line references
          error_string.scan(%r{(app/\S+\.rb):(\d+)}).each do |file, line|
            result[:file_refs] << { file: file, line: line.to_i }
          end

          # Extract method name from "undefined method `foo`" or "undefined method 'foo'"
          if (m = result[:message].match(/undefined method [`'](\w+[?!]?)[`']/))
            result[:method_name] = m[1]
          end

          result
        end

        def classify_error(parsed)
          error_str = "#{parsed[:exception_class]} #{parsed[:message]}"

          ERROR_CLASSIFICATIONS.each do |pattern, info|
            return info if error_str.match?(pattern)
          end

          {
            type: :unknown,
            likely: "Unable to automatically classify this error. Review the full error message and stack trace.",
            fix: "1. Check the error message for clues about what went wrong\n2. Use `rails_search_code` to find the failing code\n3. Use `rails_read_logs(level:\"ERROR\")` for more context"
          }
        end

        def gather_context(parsed, classification, file, line, action) # rubocop:disable Metrics
          lines = []

          # Controller context from action: parameter
          if action
            ctrl, act = action.split("#", 2)
            if ctrl && act
              begin
                ctrl_class = ctrl.end_with?("Controller") ? ctrl : "#{ctrl.camelize}Controller"
                result = GetControllers.call(controller: ctrl_class, action: act)
                text = result.content.first[:text]
                unless text.include?("not found")
                  lines << "## Controller Context"
                  lines << text
                  lines << ""
                end
              rescue => e
                lines << "## Controller Context"
                lines << "_Could not load: #{e.message}_"
                lines << ""
              end
            end
          end

          # File context
          if file && line
            begin
              result = GetEditContext.call(file: file, near: parsed[:method_name] || line.to_s)
              text = result.content.first[:text]
              unless text.include?("not found") || text.include?("not allowed")
                lines << "## Code Context"
                lines << text
                lines << ""
              end
            rescue => e
              lines << "## Code Context"
              lines << "_Could not load: #{e.message}_"
              lines << ""
            end
          end

          # Schema context for schema_mismatch errors
          if classification[:type] == :schema_mismatch
            # Try to extract table name from error
            table = parsed[:message].match(/(?:table|relation)\s+["']?(\w+)["']?/i)&.[](1)
            if table
              begin
                result = GetSchema.call(table: table)
                text = result.content.first[:text]
                unless text.include?("not found")
                  lines << "## Schema Context"
                  lines << text
                  lines << ""
                end
              rescue; end
            end
          end

          # Model context for validation errors
          if classification[:type] == :validation_failure
            # Try to extract model from file path or error
            model_name = if file&.match?(%r{app/models/(.+)\.rb})
              file.match(%r{app/models/(.+)\.rb})[1].camelize
            end
            if model_name
              begin
                result = GetModelDetails.call(model: model_name)
                text = result.content.first[:text]
                unless text.include?("not found")
                  lines << "## Model Context"
                  lines << text
                  lines << ""
                end
              rescue; end
            end
          end

          # Trace method if we know the method name
          if parsed[:method_name] && lines.none? { |l| l.include?("Code Context") }
            begin
              result = SearchCode.call(pattern: parsed[:method_name], match_type: "trace")
              text = result.content.first[:text]
              unless text.include?("No results") || text.include?("No definition")
                lines << "## Method Trace"
                lines << text
                lines << ""
              end
            rescue; end
          end

          lines
        end

        def gather_git_context(file, file_refs)
          lines = []
          root = Rails.root.to_s

          files_to_check = [ file, *file_refs.map { |r| r[:file] } ].compact.uniq.first(3)
          return lines if files_to_check.empty?

          git_output = []
          files_to_check.each do |f|
            full = File.join(root, f)
            next unless File.exist?(full)
            output, status = Open3.capture2("git", "log", "--oneline", "-5", "--", f, chdir: root)
            if status.success? && !output.strip.empty?
              git_output << "**#{f}:**\n#{output.strip}"
            end
          end

          if git_output.any?
            lines << "## Recent Git Changes"
            lines.concat(git_output)
            lines << ""
          end

          lines
        rescue
          []
        end

        def gather_log_context(exception_class)
          return [] unless exception_class

          begin
            result = ReadLogs.call(level: "ERROR", lines: 15, search: exception_class)
            text = result.content.first[:text]
            return [] if text.include?("Log file is empty") || text.include?("not found") || text.include?("No entries")

            [ "## Recent Error Logs", text, "" ]
          rescue
            []
          end
        end
      end
    end
  end
end
