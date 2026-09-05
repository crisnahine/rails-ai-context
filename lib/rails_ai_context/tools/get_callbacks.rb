# frozen_string_literal: true

module RailsAiContext
  module Tools
    class GetCallbacks < BaseTool
      tool_name "rails_get_callbacks"
      description "Get ActiveRecord model callbacks grouped by type, in Rails event order: before/after/around for validation, save, create, update, destroy. " \
        "Use when: understanding side effects, debugging callback chains, or checking what happens on save/create/destroy. " \
        "Specify model:\"User\" for one model's callbacks. detail:\"full\" includes callback method source code. " \
        "The list is what the model file and its concerns declare, and within one type the order is declaration order."

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
            enum: RailsAiContext::DetailLevel::SCHEMA_ENUM,
            description: "Detail level. summary: model names + callback counts. standard: callbacks by type in Rails event order (default). full: callbacks with method source code."
          }
        }
      )

      guide_row(
        order: 13,
        mcp: "rails_get_callbacks(model:\"X\")",
        cli_args: "model=X",
        summary: "Callbacks by type in Rails event order, with source"
      )

      annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true, open_world_hint: false)

      def self.call(model: nil, detail: "standard", server_context: nil)
        fetch_section(:models, subject: "Model introspection") do |models|
          # Every read of the shared cache deep-copies the whole payload, so
          # the listing reads it once and hands the copy down.
          ctx = cached_context

          # Specific model - show callbacks by type
          if model
            key = fuzzy_find_key(models.keys, model) || model
            data = models[key]
            unless data
              return not_found_response("Model", model, models.keys.sort,
                recovery_tool: "Call rails_get_callbacks(detail:\"summary\") to see all models with callbacks")
            end
            return text_response("Error inspecting #{key}: #{data[:error]}") if data[:error]

            return text_response(format_model_callbacks(key, data, detail, ctx))
          end

          # List all models with callbacks
          list_all_callbacks(models, detail, ctx)
        end
      end

      private_class_method def self.format_model_callbacks(name, data, detail, ctx)
        callbacks = data[:callbacks] || {}
        if callbacks.empty?
          return "# #{name}\n\nNo callbacks defined.\n\n_Next: `rails_get_model_details(model:\"#{name}\")` for full model detail._"
        end

        lines = [ "# #{name} - Callbacks", "" ]

        # Organize callbacks by type, in Rails event order
        ordered = order_callbacks(callbacks)

        if RailsAiContext::DetailLevel.full?(detail)
          # Show callback source code
          lines << "_Callbacks by type, in Rails event order, with source code:_"
          lines << ""

          ordered.each do |type, methods|
            lines << "## #{type}"
            methods.each do |method_name|
              source = extract_callback_source(name, method_name, data, ctx)
              if source
                lines << "### #{callback_target(method_name)} (#{source_location(source)})"
                lines << "```ruby"
                lines << source[:code]
                lines << "```"
                lines << ""
              else
                lines << "- `#{callback_target(method_name)}`"
              end
            end
          end
        else
          # Standard: show callbacks by type
          lines << "_Callbacks by type, in Rails event order:_"
          lines << ""

          ordered.each do |type, methods|
            lines << "- **#{type}** → #{format_targets(methods)}"
          end
        end

        # Which concern declared what. The callbacks themselves are already in
        # the execution-order list above, with their bodies at detail:full, so
        # repeating either here prints the same declaration twice.
        concern_callbacks = find_concern_callbacks(data)
        if concern_callbacks.any?
          lines << "" << "## From Concerns"
          concern_callbacks.each do |concern_name, entries|
            # Semicolons, because a declaration can carry its own comma-joined
            # options tail.
            lines << "- **#{concern_name}:** #{entries.map { |cb| cb[:declaration] }.join('; ')}"
          end
        end

        # Cross-reference hints
        lines << ""
        lines << "_Next: `rails_get_model_details(model:\"#{name}\")` for associations and validations"
        lines << " | `rails_get_concern(name:\"ConcernName\")` for concern-provided callbacks_"

        lines.join("\n")
      end

      private_class_method def self.list_all_callbacks(models, detail, ctx)
        # Filter to models that have callbacks
        models_with_callbacks = models.select do |_name, data|
          data.is_a?(Hash) && !data[:error] && data[:callbacks].is_a?(Hash) && data[:callbacks].any?
        end

        if models_with_callbacks.empty?
          return text_response("No models with callbacks found.")
        end

        lines = [ "# Model Callbacks (#{count_phrase(models_with_callbacks.size, "model")})", "" ]

        case detail
        when "summary"
          models_with_callbacks.sort_by { |_name, data| -(data[:callbacks]&.values&.flatten&.size || 0) }.each do |name, data|
            total = data[:callbacks].values.flatten.size
            types = data[:callbacks].keys.join(", ")
            lines << "- **#{name}** - #{count_phrase(total, "callback")} (#{types})"
          end
          lines << "" << "_Use `model:\"Name\"` for callbacks by type._"

        when "standard"
          models_with_callbacks.sort_by { |_name, data| -(data[:callbacks]&.values&.flatten&.size || 0) }.each do |name, data|
            ordered = order_callbacks(data[:callbacks])
            lines << "## #{name}"
            ordered.each do |type, methods|
              lines << "- **#{type}** → #{format_targets(methods)}"
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
                source = extract_callback_source(name, method_name, data, ctx)
                if source
                  lines << "### #{type} #{callback_target(method_name)} (#{source_location(source)})"
                  lines << "```ruby" << source[:code] << "```" << ""
                else
                  lines << "- **#{type}** → `#{callback_target(method_name)}`"
                end
              end
            end
            lines << ""
          end
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

      private_class_method def self.extract_callback_source(model_name, method_name, data, ctx)
        return nil unless method_name?(method_name)

        # A carried path can name a gem rather than the app, and joining that
        # to the app root opens nothing.
        path = RailsAiContext::PortablePath.resolve(
          RailsAiContext::Payload.model_file(ctx, model_name), rails_app.root.to_s
        )
        extract_method_source_from_file(path, method_name) ||
          concern_callback_source(data, method_name, model_name)
      end

      # A concern-declared callback has no `def` in the model file: the
      # concern that declared it is the file that defines it. Resolved the way
      # the introspector resolved it, so both find the same file.
      private_class_method def self.concern_callback_source(data, method_name, model_name)
        concern = Array(data && data[:concern_callbacks])
          .find { |cb| cb.is_a?(Hash) && cb[:method].to_s == method_name.to_s }
          &.dig(:from_concern)
        return nil unless concern

        path = RailsAiContext::ConcernPaths.find_file(
          rails_app.root.to_s, concern, prefer: "model", within: model_name
        )
        source = path && extract_method_source_from_file(path, method_name)
        source&.merge(from_concern: concern)
      end

      # Line numbers are the declaring file's, so the heading names it when
      # that is not the model file.
      private_class_method def self.source_location(source)
        prefix = source[:from_concern] ? "#{source[:from_concern]} " : ""
        "#{prefix}lines #{source[:start_line]}-#{source[:end_line]}"
      end

      private_class_method def self.format_targets(methods)
        methods.map { |m| "`#{callback_target(m.to_s)}`" }.join(", ")
      end

      # The introspector already walks the concern files and tags what it
      # found, on both tiers, so the section regroups that rather than
      # reading the same files a second time and disagreeing.
      private_class_method def self.find_concern_callbacks(data)
        Array(data[:concern_callbacks])
          .select { |cb| cb.is_a?(Hash) && cb[:from_concern] }
          .group_by { |cb| cb[:from_concern] }
          # One declaration resolves to one record per `on:` event, so the
          # declarations are deduped back down to the lines the file holds.
          .transform_values { |entries| entries.map { |cb| concern_callback_entry(cb) }.uniq }
      end

      private_class_method def self.concern_callback_entry(callback)
        { declaration: callback_declaration(callback) }
      end
    end
  end
end
