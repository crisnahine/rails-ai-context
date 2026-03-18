# frozen_string_literal: true

module RailsAiContext
  module Tools
    class GetModelDetails < BaseTool
      tool_name "rails_get_model_details"
      description "Get detailed information about a specific ActiveRecord model including associations, validations, scopes, enums, callbacks, and concerns. If no model specified, lists all available models."

      input_schema(
        properties: {
          model: {
            type: "string",
            description: "Model class name (e.g. 'User', 'Post'). Omit to list all models."
          }
        }
      )

      annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true, open_world_hint: false)

      def self.call(model: nil, server_context: nil)
        models = cached_context[:models]
        return text_response("Model introspection failed: #{models[:error]}") if models.is_a?(Hash) && models[:error]

        unless model
          model_list = models.keys.sort.map { |m| "- #{m}" }.join("\n")
          return text_response("# Available models (#{models.size})\n\n#{model_list}")
        end

        # Support both "User" and "user" lookups
        key = models.keys.find { |k| k.downcase == model.downcase } || model
        data = models[key]
        return text_response("Model '#{model}' not found. Available: #{models.keys.sort.join(', ')}") unless data
        return text_response("Error inspecting #{key}: #{data[:error]}") if data[:error]

        text_response(format_model(key, data))
      end

      private_class_method def self.format_model(name, data)
        lines = [ "# #{name}", "" ]
        lines << "**Table:** `#{data[:table_name]}`" if data[:table_name]

        # Associations
        if data[:associations]&.any?
          lines << "" << "## Associations"
          data[:associations].each do |a|
            detail = "- `#{a[:type]}` **#{a[:name]}**"
            detail += " (class: #{a[:class_name]})" if a[:class_name] && a[:class_name] != a[:name].to_s.classify
            detail += " through: #{a[:through]}" if a[:through]
            detail += " [polymorphic]" if a[:polymorphic]
            detail += " dependent: #{a[:dependent]}" if a[:dependent]
            lines << detail
          end
        end

        # Validations
        if data[:validations]&.any?
          lines << "" << "## Validations"
          data[:validations].each do |v|
            attrs = v[:attributes].join(", ")
            opts = v[:options]&.any? ? " (#{v[:options].map { |k, val| "#{k}: #{val}" }.join(', ')})" : ""
            lines << "- `#{v[:kind]}` on #{attrs}#{opts}"
          end
        end

        # Enums
        if data[:enums]&.any?
          lines << "" << "## Enums"
          data[:enums].each do |attr, values|
            lines << "- `#{attr}`: #{values.join(', ')}"
          end
        end

        # Scopes
        if data[:scopes]&.any?
          lines << "" << "## Scopes"
          lines << data[:scopes].map { |s| "- `#{s}`" }.join("\n")
        end

        # Callbacks
        if data[:callbacks]&.any?
          lines << "" << "## Callbacks"
          data[:callbacks].each do |type, methods|
            lines << "- `#{type}`: #{methods.join(', ')}"
          end
        end

        # Concerns
        if data[:concerns]&.any?
          lines << "" << "## Concerns"
          lines << data[:concerns].map { |c| "- #{c}" }.join("\n")
        end

        # Key instance methods
        if data[:instance_methods]&.any?
          lines << "" << "## Key instance methods"
          lines << data[:instance_methods].first(15).map { |m| "- `#{m}`" }.join("\n")
        end

        lines.join("\n")
      end
    end
  end
end
