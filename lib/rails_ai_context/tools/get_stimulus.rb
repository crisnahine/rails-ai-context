# frozen_string_literal: true

module RailsAiContext
  module Tools
    class GetStimulus < BaseTool
      tool_name "rails_get_stimulus"
      description "Get Stimulus controller information including targets, values, actions, outlets, and classes. Filter by controller name."

      input_schema(
        properties: {
          controller: {
            type: "string",
            description: "Specific Stimulus controller name (e.g. 'hello', 'filter-form'). Case-insensitive."
          },
          detail: {
            type: "string",
            enum: %w[summary standard full],
            description: "Detail level. summary: names + counts. standard: names + targets + actions (default). full: everything including values, outlets, classes."
          }
        }
      )

      annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true, open_world_hint: false)

      def self.call(controller: nil, detail: "standard", server_context: nil)
        data = cached_context[:stimulus]
        return text_response("Stimulus introspection not available. Add :stimulus to introspectors.") unless data
        return text_response("Stimulus introspection failed: #{data[:error]}") if data[:error]

        controllers = data[:controllers] || []
        return text_response("No Stimulus controllers found.") if controllers.empty?

        # Specific controller
        if controller
          ctrl = controllers.find { |c| c[:name]&.downcase == controller.downcase }
          return text_response("Controller '#{controller}' not found. Available: #{controllers.map { |c| c[:name] }.sort.join(', ')}") unless ctrl
          return text_response(format_controller_full(ctrl))
        end

        case detail
        when "summary"
          lines = [ "# Stimulus Controllers (#{controllers.size})", "" ]
          controllers.sort_by { |c| c[:name]&.to_s || "" }.each do |ctrl|
            targets = (ctrl[:targets] || []).size
            actions = (ctrl[:actions] || []).size
            lines << "- **#{ctrl[:name]}** — #{targets} targets, #{actions} actions"
          end
          lines << "" << "_Use `controller:\"name\"` for full detail._"
          text_response(lines.join("\n"))

        when "standard"
          lines = [ "# Stimulus Controllers (#{controllers.size})", "" ]
          controllers.sort_by { |c| c[:name]&.to_s || "" }.each do |ctrl|
            lines << "## #{ctrl[:name]}"
            lines << "- Targets: #{(ctrl[:targets] || []).join(', ')}" if ctrl[:targets]&.any?
            lines << "- Actions: #{(ctrl[:actions] || []).join(', ')}" if ctrl[:actions]&.any?
            lines << ""
          end
          text_response(lines.join("\n"))

        when "full"
          lines = [ "# Stimulus Controllers (#{controllers.size})", "" ]
          controllers.sort_by { |c| c[:name]&.to_s || "" }.each do |ctrl|
            lines << format_controller_full(ctrl) << ""
          end
          text_response(lines.join("\n"))

        else
          text_response("Unknown detail level: #{detail}. Use summary, standard, or full.")
        end
      end

      private_class_method def self.format_controller_full(ctrl)
        lines = [ "## #{ctrl[:name]}" ]
        lines << "- **Targets:** #{ctrl[:targets].join(', ')}" if ctrl[:targets]&.any?
        lines << "- **Actions:** #{ctrl[:actions].join(', ')}" if ctrl[:actions]&.any?
        lines << "- **Values:** #{ctrl[:values].map { |k, v| "#{k}:#{v}" }.join(', ')}" if ctrl[:values]&.any?
        lines << "- **Outlets:** #{ctrl[:outlets].join(', ')}" if ctrl[:outlets]&.any?
        lines << "- **Classes:** #{ctrl[:classes].join(', ')}" if ctrl[:classes]&.any?
        lines << "- **File:** #{ctrl[:file]}" if ctrl[:file]
        lines.join("\n")
      end
    end
  end
end
