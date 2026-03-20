# frozen_string_literal: true

module RailsAiContext
  module Tools
    class GetModelDetails < BaseTool
      tool_name "rails_get_model_details"
      description "Get detailed information about a specific ActiveRecord model including associations, validations, scopes, enums, callbacks, and concerns. If no model specified, lists all available models with configurable detail level."

      input_schema(
        properties: {
          model: {
            type: "string",
            description: "Model class name (e.g. 'User', 'Post'). Omit to list all models."
          },
          detail: {
            type: "string",
            enum: %w[summary standard full],
            description: "Detail level for model listing. summary: names only. standard: names + association/validation counts (default). full: names + full association list. Ignored when specific model is given (always returns full)."
          }
        }
      )

      annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true, open_world_hint: false)

      def self.call(model: nil, detail: "standard", server_context: nil)
        models = cached_context[:models]
        return text_response("Model introspection not available. Add :models to introspectors.") unless models
        return text_response("Model introspection failed: #{models[:error]}") if models[:error]

        # Specific model — always full detail
        if model
          key = models.keys.find { |k| k.downcase == model.downcase } || model
          data = models[key]
          return text_response("Model '#{model}' not found. Available: #{models.keys.sort.join(', ')}") unless data
          return text_response("Error inspecting #{key}: #{data[:error]}") if data[:error]
          return text_response(format_model(key, data))
        end

        # Listing mode
        case detail
        when "summary"
          model_list = models.keys.sort.map { |m| "- #{m}" }.join("\n")
          text_response("# Available models (#{models.size})\n\n#{model_list}\n\n_Use `model:\"Name\"` for full detail._")

        when "standard"
          lines = [ "# Models (#{models.size})", "" ]
          models.keys.sort.each do |name|
            data = models[name]
            next if data[:error]
            assoc_count = (data[:associations] || []).size
            val_count = (data[:validations] || []).size
            line = "- **#{name}**"
            line += " — #{assoc_count} associations, #{val_count} validations" if assoc_count > 0 || val_count > 0
            lines << line
          end
          lines << "" << "_Use `model:\"Name\"` for full detail, or `detail:\"full\"` for association lists._"
          text_response(lines.join("\n"))

        when "full"
          lines = [ "# Models (#{models.size})", "" ]
          models.keys.sort.each do |name|
            data = models[name]
            next if data[:error]
            assocs = (data[:associations] || []).map { |a| "#{a[:type]} :#{a[:name]}" }.join(", ")
            line = "- **#{name}**"
            line += " (table: #{data[:table_name]})" if data[:table_name]
            line += " — #{assocs}" unless assocs.empty?
            lines << line
          end
          lines << "" << "_Use `model:\"Name\"` for validations, scopes, callbacks, and more._"
          text_response(lines.join("\n"))

        else
          model_list = models.keys.sort.map { |m| "- #{m}" }.join("\n")
          text_response("# Available models (#{models.size})\n\n#{model_list}")
        end
      end

      private_class_method def self.format_model(name, data)
        lines = [ "# #{name}", "" ]
        lines << "**Table:** `#{data[:table_name]}`" if data[:table_name]

        # File structure with line ranges
        structure = extract_model_structure(name)
        if structure
          lines << "**File:** `#{structure[:path]}` (#{structure[:total_lines]} lines)"
          lines << "" << "## File Structure"
          structure[:sections].each do |section|
            lines << "- Lines #{section[:start]}-#{section[:end]}: #{section[:label]}"
          end
        end

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

      MAX_MODEL_SIZE = 2_000_000 # 2MB safety limit

      private_class_method def self.extract_model_structure(model_name)
        path = "app/models/#{model_name.underscore}.rb"
        full_path = Rails.root.join(path)
        return nil unless File.exist?(full_path)
        return nil if File.size(full_path) > MAX_MODEL_SIZE

        source_lines = File.readlines(full_path)
        sections = []
        current_section = nil
        current_start = nil

        source_lines.each_with_index do |line, idx|
          label = case line
          when /\A\s*class\s/ then "class definition"
          when /\A\s*(include|extend|prepend)\s/ then "includes"
          when /\A\s*[A-Z_]+\s*=/ then "constants"
          when /\A\s*(belongs_to|has_many|has_one|has_and_belongs_to_many)\s/ then "associations"
          when /\A\s*(validates|validate)\s/ then "validations"
          when /\A\s*scope\s/ then "scopes"
          when /\A\s*(enum|encrypts|normalizes|has_secure_password|has_one_attached|has_many_attached)\s/ then "macros"
          when /\A\s*(before_|after_|around_)/ then "callbacks"
          when /\A\s*def\s+self\./ then "class methods"
          when /\A\s*def\s/ then "instance methods"
          when /\A\s*private\s*$/ then "private"
          end

          if label && label != current_section
            sections << { start: current_start, end: idx + 1, label: current_section } if current_section
            current_section = label
            current_start = idx + 1
          end
        end
        sections << { start: current_start, end: source_lines.size, label: current_section } if current_section

        { path: path, total_lines: source_lines.size, sections: sections }
      rescue
        nil
      end
    end
  end
end
