# frozen_string_literal: true

module RailsAiContext
  module Tools
    class GetCallbacks < BaseTool
      tool_name "rails_get_callbacks"
      description "Get ActiveRecord model callbacks in execution order: before/after/around for validation, save, create, update, destroy. " \
        "Use when: understanding side effects, debugging callback chains, or checking what happens on save/create/destroy. " \
        "Specify model:\"User\" for one model's callbacks in execution order. detail:\"full\" includes callback method source code."

      CALLBACK_EXECUTION_ORDER = %w[
        before_validation
        after_validation
        before_save
        around_save
        before_create
        around_create
        after_create
        before_update
        around_update
        after_update
        after_save
        before_destroy
        around_destroy
        after_destroy
        after_commit
        after_create_commit
        after_update_commit
        after_destroy_commit
        after_save_commit
        after_rollback
        after_touch
        after_find
        after_initialize
      ].freeze

      input_schema(
        properties: {
          model: {
            type: "string",
            description: "Model class name (e.g. 'User', 'Post'). Omit to see all models with their callbacks."
          },
          detail: {
            type: "string",
            enum: %w[summary standard full],
            description: "Detail level. summary: model names + callback counts. standard: callbacks in execution order (default). full: callbacks with method source code."
          }
        }
      )

      annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true, open_world_hint: false)

      def self.call(model: nil, detail: "standard", server_context: nil)
        models = cached_context[:models]
        return text_response("Model introspection not available. Add :models to introspectors.") unless models
        return text_response("Model introspection failed: #{models[:error]}") if models[:error]

        # Specific model — show callbacks in execution order
        if model
          key = models.keys.find { |k| k.downcase == model.downcase } || model
          data = models[key]
          unless data
            return not_found_response("Model", model, models.keys.sort,
              recovery_tool: "Call rails_get_callbacks(detail:\"summary\") to see all models with callbacks")
          end
          return text_response("Error inspecting #{key}: #{data[:error]}") if data[:error]

          return text_response(format_model_callbacks(key, data, detail))
        end

        # List all models with callbacks
        list_all_callbacks(models, detail)
      end

      private_class_method def self.format_model_callbacks(name, data, detail)
        callbacks = data[:callbacks] || {}
        if callbacks.empty?
          return "# #{name}\n\nNo callbacks defined.\n\n_Next: `rails_get_model_details(model:\"#{name}\")` for full model detail._"
        end

        lines = [ "# #{name} — Callbacks", "" ]

        # Organize callbacks in execution order
        ordered = order_callbacks(callbacks)

        if detail == "full"
          # Show callback source code
          lines << "_Callbacks shown in execution order with source code:_"
          lines << ""

          ordered.each do |type, methods|
            lines << "## #{type}"
            methods.each do |method_name|
              source = extract_callback_source(name, method_name)
              if source
                lines << "### :#{method_name} (lines #{source[:start_line]}-#{source[:end_line]})"
                lines << "```ruby"
                lines << source[:code]
                lines << "```"
                lines << ""
              else
                lines << "- `:#{method_name}`"
              end
            end
          end
        else
          # Standard: show callbacks in execution order
          lines << "_Callbacks in execution order:_"
          lines << ""

          ordered.each do |type, methods|
            method_list = methods.map { |m| "`:#{m}`" }.join(", ")
            lines << "- **#{type}** → #{method_list}"
          end
        end

        # Concern-provided callbacks
        concern_callbacks = find_concern_callbacks(name, data)
        if concern_callbacks.any?
          lines << "" << "## From Concerns"
          concern_callbacks.each do |concern_name, cbs|
            lines << "- **#{concern_name}:** #{cbs.join(', ')}"
          end
        end

        # Cross-reference hints
        lines << ""
        lines << "_Next: `rails_get_model_details(model:\"#{name}\")` for associations and validations"
        lines << " | `rails_get_concern(name:\"ConcernName\")` for concern-provided callbacks_"

        lines.join("\n")
      end

      private_class_method def self.list_all_callbacks(models, detail)
        # Filter to models that have callbacks
        models_with_callbacks = models.select do |_name, data|
          data.is_a?(Hash) && !data[:error] && data[:callbacks].is_a?(Hash) && data[:callbacks].any?
        end

        if models_with_callbacks.empty?
          return text_response("No models with callbacks found.")
        end

        lines = [ "# Model Callbacks (#{models_with_callbacks.size} models)", "" ]

        case detail
        when "summary"
          models_with_callbacks.sort_by { |_name, data| -(data[:callbacks]&.values&.flatten&.size || 0) }.each do |name, data|
            total = data[:callbacks].values.flatten.size
            types = data[:callbacks].keys.join(", ")
            lines << "- **#{name}** — #{total} callbacks (#{types})"
          end
          lines << "" << "_Use `model:\"Name\"` for callbacks in execution order._"

        when "standard"
          models_with_callbacks.sort_by { |_name, data| -(data[:callbacks]&.values&.flatten&.size || 0) }.each do |name, data|
            ordered = order_callbacks(data[:callbacks])
            lines << "## #{name}"
            ordered.each do |type, methods|
              method_list = methods.map { |m| "`:#{m}`" }.join(", ")
              lines << "- **#{type}** → #{method_list}"
            end
            lines << ""
          end
          lines << "_Use `model:\"Name\"` with `detail:\"full\"` for callback source code._"

        when "full"
          models_with_callbacks.sort_by { |_name, data| -(data[:callbacks]&.values&.flatten&.size || 0) }.each do |name, data|
            ordered = order_callbacks(data[:callbacks])
            lines << "## #{name}"
            ordered.each do |type, methods|
              methods.each do |method_name|
                source = extract_callback_source(name, method_name)
                if source
                  lines << "### #{type} :#{method_name} (lines #{source[:start_line]}-#{source[:end_line]})"
                  lines << "```ruby" << source[:code] << "```" << ""
                else
                  lines << "- **#{type}** → `:#{method_name}`"
                end
              end
            end
            lines << ""
          end
        else
          return text_response("Unknown detail level: #{detail}. Use summary, standard, or full.")
        end

        text_response(lines.join("\n"))
      end

      private_class_method def self.order_callbacks(callbacks)
        ordered = []

        CALLBACK_EXECUTION_ORDER.each do |type|
          methods = callbacks[type] || callbacks[type.to_sym]
          next unless methods.is_a?(Array) && methods.any?
          ordered << [ type, methods ]
        end

        # Include any callback types not in the standard order
        callbacks.each do |type, methods|
          type_str = type.to_s
          next if CALLBACK_EXECUTION_ORDER.include?(type_str)
          next unless methods.is_a?(Array) && methods.any?
          ordered << [ type_str, methods ]
        end

        ordered
      end

      private_class_method def self.extract_callback_source(model_name, method_name)
        path = Rails.root.join("app", "models", "#{model_name.underscore}.rb")
        return nil unless File.exist?(path)
        return nil if File.size(path) > RailsAiContext.configuration.max_file_size

        source_lines = File.readlines(path, encoding: "UTF-8", invalid: :replace, undef: :replace)
        method_str = method_name.to_s

        # Find method definition (could be public or private)
        start_idx = source_lines.index { |l| l.match?(/\A\s*def\s+#{Regexp.escape(method_str)}\b/) }
        return nil unless start_idx

        # Use indentation-based matching
        def_indent = source_lines[start_idx][/\A\s*/].length
        result = []
        end_idx = start_idx

        source_lines[start_idx..].each_with_index do |line, i|
          result << line.rstrip
          end_idx = start_idx + i
          break if i > 0 && line.match?(/\A\s{#{def_indent}}end\b/)
        end

        {
          code: result.join("\n"),
          start_line: start_idx + 1,
          end_line: end_idx + 1
        }
      rescue
        nil
      end

      private_class_method def self.find_concern_callbacks(model_name, data)
        concern_callbacks = {}
        concerns = data[:concerns] || []
        max_size = RailsAiContext.configuration.max_file_size

        concerns.each do |concern_name|
          next unless concern_name.is_a?(String)
          # Skip framework concerns
          next if concern_name.include?("::") && !concern_name.start_with?("App")
          next if %w[Kernel JSON PP Marshal].include?(concern_name)

          underscore = concern_name.underscore
          concern_path = RailsAiContext.configuration.concern_paths
            .map { |dir| Rails.root.join(dir, "#{underscore}.rb") }
            .find { |p| File.exist?(p) }
          next unless concern_path
          next if File.size(concern_path) > max_size

          source = File.read(concern_path, encoding: "UTF-8", invalid: :replace, undef: :replace) rescue next
          callbacks = []

          source.each_line do |line|
            if (match = line.match(/\A\s*(before_\w+|after_\w+|around_\w+)\s+[: ]*(\w+)/))
              callbacks << "#{match[1]} :#{match[2]}"
            end
          end

          concern_callbacks[concern_name] = callbacks if callbacks.any?
        end

        concern_callbacks
      rescue
        {}
      end
    end
  end
end
