# frozen_string_literal: true

module RailsAiContext
  module Tools
    class GetControllers < BaseTool
      tool_name "rails_get_controllers"
      description "Get controller information including actions, filters, strong params, and concerns. Optionally filter by controller name. Supports detail levels."

      input_schema(
        properties: {
          controller: {
            type: "string",
            description: "Optional: specific controller name (e.g. 'PostsController'). Omit for all controllers."
          },
          action: {
            type: "string",
            description: "Specific action name (e.g. 'index', 'create'). Requires controller. Returns the action source code and applicable filters."
          },
          detail: {
            type: "string",
            enum: %w[summary standard full],
            description: "Detail level for controller listing. summary: names + action counts. standard: names + action list (default). full: everything. Ignored when specific controller is given."
          }
        }
      )

      annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true, open_world_hint: false)

      def self.call(controller: nil, action: nil, detail: "standard", server_context: nil)
        data = cached_context[:controllers]
        return text_response("Controller introspection not available. Add :controllers to introspectors.") unless data
        return text_response("Controller introspection failed: #{data[:error]}") if data[:error]

        controllers = data[:controllers] || {}

        # Specific controller — always full detail
        if controller
          key = controllers.keys.find { |k| k.downcase == controller.downcase } || controller
          info = controllers[key]
          return text_response("Controller '#{controller}' not found. Available: #{controllers.keys.sort.join(', ')}") unless info
          return text_response("Error inspecting #{key}: #{info[:error]}") if info[:error]

          # Specific action — return source code
          if action
            return text_response(format_action_source(key, info, action))
          end

          return text_response(format_controller(key, info))
        end

        # Listing mode
        case detail
        when "summary"
          lines = [ "# Controllers (#{controllers.size})", "" ]
          controllers.keys.sort.each do |name|
            info = controllers[name]
            action_count = info[:actions]&.size || 0
            lines << "- **#{name}** — #{action_count} actions"
          end
          lines << "" << "_Use `controller:\"Name\"` for full detail._"
          text_response(lines.join("\n"))

        when "standard"
          lines = [ "# Controllers (#{controllers.size})", "" ]
          controllers.keys.sort.each do |name|
            info = controllers[name]
            actions = info[:actions]&.join(", ") || "none"
            lines << "- **#{name}** — #{actions}"
          end
          lines << "" << "_Use `controller:\"Name\"` for filters and strong params, or `detail:\"full\"` for everything._"
          text_response(lines.join("\n"))

        when "full"
          lines = [ "# Controllers (#{controllers.size})", "" ]
          controllers.keys.sort.each do |name|
            info = controllers[name]
            lines << "## #{name}"
            lines << "- Actions: #{info[:actions]&.join(', ')}" if info[:actions]&.any?
            if info[:filters]&.any?
              lines << "- Filters: #{info[:filters].map { |f| "#{f[:kind]} #{f[:name]}" }.join(', ')}"
            end
            lines << "- Strong params: #{info[:strong_params].join(', ')}" if info[:strong_params]&.any?
            lines << ""
          end
          text_response(lines.join("\n"))

        else
          list = controllers.keys.sort.map { |c| "- #{c}" }.join("\n")
          text_response("# Controllers (#{controllers.size})\n\n#{list}")
        end
      end

      private_class_method def self.format_action_source(controller_name, info, action_name)
        actions = info[:actions] || []
        unless actions.map(&:to_s).include?(action_name.to_s)
          return "Action '#{action_name}' not found in #{controller_name}. Available: #{actions.join(', ')}"
        end

        # Find applicable filters
        filters = (info[:filters] || []).select do |f|
          if f[:only]&.any?
            f[:only].map(&:to_s).include?(action_name.to_s)
          elsif f[:except]&.any?
            !f[:except].map(&:to_s).include?(action_name.to_s)
          else
            true
          end
        end

        # Extract source code with line numbers
        source_path = Rails.root.join("app", "controllers", "#{controller_name.underscore}.rb")
        source_with_lines = extract_method_with_lines(source_path, action_name)

        lines = [ "# #{controller_name}##{action_name}", "" ]
        lines << "**File:** `app/controllers/#{controller_name.underscore}.rb`"

        if filters.any?
          lines << "" << "## Applicable Filters"
          filters.each do |f|
            line = "- `#{f[:kind]}` **#{f[:name]}**"
            line += " (only: #{f[:only].join(', ')})" if f[:only]&.any?
            lines << line
          end
        end

        if source_with_lines
          lines << "" << "## Source (lines #{source_with_lines[:start_line]}-#{source_with_lines[:end_line]})"
          lines << "```ruby" << source_with_lines[:code] << "```"
          lines << "" << "_Use this exact code as old_string for Edit — no need to Read the full file._"
        else
          lines << "" << "_Could not extract source code. File: #{source_path}_"
        end

        if info[:strong_params]&.any?
          lines << "" << "## Strong Params" << "- #{info[:strong_params].join(', ')}"
        end

        lines.join("\n")
      end

      MAX_CONTROLLER_SIZE = 2_000_000 # 2MB safety limit

      private_class_method def self.extract_method_with_lines(file_path, method_name)
        return nil unless File.exist?(file_path)
        return nil if File.size(file_path) > MAX_CONTROLLER_SIZE
        source_lines = File.readlines(file_path)
        start_idx = source_lines.index { |l| l.match?(/^\s*def\s+#{Regexp.escape(method_name.to_s)}\b/) }
        return nil unless start_idx

        depth = 0
        result = []
        end_idx = start_idx
        source_lines[start_idx..].each_with_index do |line, i|
          depth += line.scan(/\b(?:def|do|if|unless|case|begin|class|module)\b/).size
          depth -= line.scan(/\bend\b/).size
          result << line.rstrip
          end_idx = start_idx + i
          break if depth <= 0
        end

        {
          code: result.join("\n"),
          start_line: start_idx + 1,
          end_line: end_idx + 1
        }
      rescue
        nil
      end

      private_class_method def self.format_controller(name, info)
        lines = [ "# #{name}", "" ]
        lines << "**Parent:** `#{info[:parent_class]}`" if info[:parent_class]
        lines << "**API controller:** yes" if info[:api_controller]

        if info[:actions]&.any?
          lines << "" << "## Actions"
          lines << info[:actions].map { |a| "- `#{a}`" }.join("\n")
        end

        if info[:filters]&.any?
          lines << "" << "## Filters"
          info[:filters].each do |f|
            detail = "- `#{f[:kind]}` **#{f[:name]}**"
            detail += " (only: #{f[:only].join(', ')})" if f[:only]&.any?
            lines << detail
          end
        end

        if info[:strong_params]&.any?
          lines << "" << "## Strong Params"
          lines << info[:strong_params].map { |p| "- `#{p}`" }.join("\n")
        end

        lines.join("\n")
      end
    end
  end
end
