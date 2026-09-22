# frozen_string_literal: true

module RailsAiContext
  module Tools
    class GetContext < BaseTool
      tool_name "rails_get_context"
      description "Get cross-layer context in a single call - combines schema, model, controller, routes, views, stimulus, and tests. " \
        "Use when: you need full context for implementing a feature or modifying an action. " \
        "Specify controller:\"PostsController\" action:\"create\" to get everything for that action in one call."

      input_schema(
        properties: {
          controller: {
            type: "string",
            description: "Controller name (e.g. 'PostsController'). Returns action source, filters, strong params, routes, views."
          },
          action: {
            type: "string",
            description: "Specific action name (e.g. 'create'). Requires controller. Returns full action context."
          },
          model: {
            type: "string",
            description: "Model name (e.g. 'Post'). Returns schema, associations, validations, scopes, callbacks, tests."
          },
          feature: {
            type: "string",
            description: "Feature keyword (e.g. 'post'). Like analyze_feature but includes schema columns and scope bodies."
          },
          include: {
            type: "array",
            items: { type: "string" },
            description: "Additional context to bundle: 'stimulus', 'turbo', 'services', 'jobs', 'conventions', 'helpers', 'env', 'callbacks'. Appends these to any mode."
          }
        }
      )

      guide_row(
        order: 1,
        mcp: "rails_get_context(model:\"X\")",
        cli_args: "model=X",
        summary: "**START HERE** - schema + model + controller + routes + views in one call"
      )

      annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true, open_world_hint: false)

      def self.call(controller: nil, action: nil, model: nil, feature: nil, include: nil, server_context: nil)
        base_text = if controller && action
          controller_action_context(controller, action)
        elsif controller
          controller_context(controller)
        elsif model
          model_context(model)
        elsif feature
          feature_context(feature)
        else
          return error_response("Provide at least one of: controller, model, or feature.")
        end

        # Append additional context sections if include: is specified
        base_text += append_includes(include) if include.is_a?(Array) && include.any?

        ctx = begin
          cached_context
        rescue StandardError
          nil
        end

        text_response(base_text, suffix: introspection_warnings_note(ctx))
      end

      private_class_method def self.controller_action_context(controller_name, action_name)
        lines = []

        # Controller + action source + private methods + instance vars
        ctrl_result = GetControllers.call(controller: controller_name, action: action_name)
        lines << response_text(ctrl_result)

        # Infer model from controller
        snake = RailsAiContext::Payload.controller_route_key(cached_context, controller_name)
        model_name = snake.split("/").last.singularize.camelize

        # Model details
        model_result = GetModelDetails.call(model: model_name)
        unless empty?(model_result)
          lines << "" << "---" << "" << response_text(model_result)
        end

        # Routes for this controller
        route_result = GetRoutes.call(controller: snake)
        unless empty?(route_result)
          lines << "" << "---" << ""
          lines << response_text(route_result)
        end

        # Views for this controller
        view_result, view_note = controller_views(snake)
        unless empty?(view_result)
          lines << "" << "---" << ""
          lines << view_note if view_note
          lines << response_text(view_result)
        end

        # Cross-reference: controller ivars vs view ivars. The action's own
        # source is the origin for both sides of the controller's half; a
        # body this app cannot read skips the cross-check.
        action_body = action_source(controller_name, action_name)
        resolver = RailsAiContext::Introspectors::ActionResolver
        ctrl_ivars = Set.new(action_body ? resolver.assigned_ivars(action_body) : [])
        view_ivars = Payload.view_ivars(cached_context, "#{snake}/#{action_name}")
        rendered = action_body ? resolver.rendered_templates(action_body) : []
        other_templates = rendered.reject { |t| t == action_name }
        other_templates.each do |tmpl|
          view_ivars.merge(Payload.view_ivars(cached_context, "#{snake}/#{tmpl}"))
        end
        view_ivars.merge(action_body ? resolver.rendered_ivars(action_body) : [])
        # Without the view side's section every controller ivar reads as
        # unused, so no cross-check is the honest answer.
        if Payload.section(cached_context, :view_templates)
          ivar_check = cross_reference_ivars(ctrl_ivars, view_ivars, rendered_templates: other_templates, api_only: api_only?)
          lines << "" << ivar_check if ivar_check
        end

        # Hydrate: inject schema hints for models referenced in controller + view ivars
        if RailsAiContext.configuration.hydration_enabled
          all_ivars = (ctrl_ivars | view_ivars).to_a
          hydration = Hydrators::ViewHydrator.call(all_ivars, context: cached_context)
          hydration_text = Hydrators::HydrationFormatter.format(hydration)
          # Skip if get_controllers already injected schema hints
          unless hydration_text.empty? || lines.any? { |l| l.include?("## Schema Hints") }
            lines << "" << hydration_text
          end
        end

        lines.join("\n")
      rescue => e
        "Error assembling context: #{e.message}"
      end

      # The templates for a controller, read from the directory Rails would
      # resolve: the full controller_path, never its last segment. An app that
      # keeps a flat app/views still gets an answer, and it is labelled,
      # because those templates are not the ones this controller renders by
      # convention - on a namespaced app they belong to another component
      # entirely.
      #
      # @return [Array(MCP::Tool::Response, String, nil)] the view section and
      #   a note when the answer came from the flat directory
      private_class_method def self.controller_views(snake)
        namespaced = GetView.call(controller: snake, detail: "standard")
        return [ namespaced, nil ] unless empty?(namespaced)

        basename = snake.to_s.split("/").last
        return [ namespaced, nil ] if basename.nil? || basename == snake

        flat = GetView.call(controller: basename, detail: "standard")
        return [ namespaced, nil ] if empty?(flat)

        [ flat, "_No templates under `app/views/#{snake}`; these are `app/views/#{basename}`, which Rails resolves for this controller only if it sets its own view path._" ]
      end

      # The action's body out of the file the payload carried for the
      # controller - never a path rebuilt from the class name.
      private_class_method def self.action_source(controller_name, action_name)
        carried = Payload.controller_file(cached_context, controller_name)
        return nil unless carried

        source = safe_read(File.join(rails_app.root.to_s, carried))
        return nil unless source

        RailsAiContext::Introspectors::ActionResolver.method_body(source, action_name, owner: controller_name)
          &.dig(:code)
      end

      # True when the app runs in API-only mode (no view layer), so ivar
      # cross-referencing can drop "view" language that wouldn't be truthful.
      private_class_method def self.api_only?
        api_only_app?
      end

      private_class_method def self.cross_reference_ivars(ctrl_ivars, view_ivars, rendered_templates: [], api_only: false)
        return nil if ctrl_ivars.empty? && view_ivars.empty?

        lines = [ "## Instance Variable Cross-Check" ]
        all = (ctrl_ivars | view_ivars).sort

        used_label = api_only ? "used in response" : "used in view"
        missing_label = api_only ? "referenced in response but NOT set in controller" : "used in view but NOT set in controller"
        unused_label = api_only ? "set in controller but not rendered in response" : "set in controller but not used in view"

        missing_ivars = []
        all.each do |ivar|
          in_ctrl = ctrl_ivars.include?(ivar)
          in_view = view_ivars.include?(ivar)
          if in_ctrl && in_view
            lines << "- \u2713 @#{ivar} - set in controller, #{used_label}"
          elsif in_view && !in_ctrl
            lines << "- \u2717 @#{ivar} - #{missing_label}"
            missing_ivars << ivar
          elsif in_ctrl && !in_view
            lines << "- \u26A0 @#{ivar} - #{unused_label}"
          end
        end

        # If there are missing ivars AND this action renders another template,
        # add a note explaining why - the other action likely sets them
        if missing_ivars.any? && rendered_templates.any?
          templates = rendered_templates.map { |t| "`#{t}`" }.join(", ")
          lines << ""
          lines << "_Note: This action renders #{templates} on failure - those ivars are likely set in the corresponding action(s)._"
        end

        (missing_ivars.any? || all.any?) ? lines.join("\n") : nil
      end

      private_class_method def self.controller_context(controller_name)
        lines = []

        ctrl_result = GetControllers.call(controller: controller_name)
        lines << response_text(ctrl_result)

        snake = RailsAiContext::Payload.controller_route_key(cached_context, controller_name)

        # Routes for this controller
        route_result = GetRoutes.call(controller: snake)
        unless empty?(route_result)
          lines << "" << "---" << "" << response_text(route_result)
        end

        # Views for this controller
        view_result, view_note = controller_views(snake)
        unless empty?(view_result)
          lines << "" << "---" << ""
          lines << view_note if view_note
          lines << response_text(view_result)
        end

        lines.join("\n")
      rescue => e
        "Error assembling context: #{e.message}"
      end

      private_class_method def self.model_context(model_name)
        lines = []

        # Normalize: try as-is, then singularized, then classified
        ctx = cached_context
        models = Payload.models(ctx)
        key = fuzzy_find_key(models.keys, model_name)

        resolved_name = key || model_name

        model_result = GetModelDetails.call(model: resolved_name)

        # If model not found, fail fast - don't leak partial results from sub-tools
        return response_text(model_result) if empty?(model_result)

        lines << response_text(model_result)

        if key && models[key][:table_name]
          schema_result = GetSchema.call(table: models[key][:table_name])
          unless empty?(schema_result)
            lines << "" << "---" << "" << response_text(schema_result)
          end
        end

        # Tests for this model
        test_result = GetTestInfo.call(model: resolved_name, detail: "standard")
        unless empty?(test_result)
          lines << "" << "---" << "" << response_text(test_result)
        end

        lines.join("\n")
      rescue => e
        "Error assembling context: #{e.message}"
      end

      INCLUDE_MAP = {
        "stimulus"    => -> { GetStimulus.call(detail: "standard") },
        "turbo"       => -> { GetTurboMap.call(detail: "standard") },
        "services"    => -> { GetServicePattern.call(detail: "standard") },
        "jobs"        => -> { GetJobPattern.call(detail: "standard") },
        "conventions" => -> { GetConventions.call },
        "helpers"     => -> { GetHelperMethods.call(detail: "standard") },
        "env"         => -> { GetEnv.call(detail: "summary") },
        "callbacks"   => -> { GetCallbacks.call(detail: "standard") },
        "tests"       => -> { GetTestInfo.call(detail: "full") },
        "config"      => -> { GetConfig.call },
        "gems"        => -> { GetGems.call },
        "security"    => -> { SecurityScan.call(detail: "summary") }
      }.freeze

      private_class_method def self.append_includes(includes)
        extra = +""
        includes.each do |key|
          handler = INCLUDE_MAP[key.to_s.downcase]
          next unless handler
          begin
            extra << "\n\n---\n\n" << response_text(handler.call)
          rescue => e
            extra << "\n\n---\n\n_Error loading #{key}: #{e.message}_"
          end
        end
        extra
      end

      private_class_method def self.feature_context(feature_name)
        # Start with full-stack feature analysis
        analyze_result = AnalyzeFeature.call(feature: feature_name)
        lines = [ response_text(analyze_result) ]

        # Enrich with schema columns for matching models
        ctx = begin; cached_context; rescue; nil; end
        if ctx
          models = Payload.models(ctx)
          matched_tables = Set.new

          models.each_key do |model_name|
            next unless model_name.downcase.include?(feature_name.downcase)
            table_name = models[model_name][:table_name]
            next unless table_name
            matched_tables << table_name
            schema_result = GetSchema.call(table: table_name)
            unless empty?(schema_result)
              lines << "" << "---" << "" << response_text(schema_result)
            end
          end

          # Also include schema for related models (associated tables) if the
          # primary model was found but the feature analysis missed controllers/services
          analyze_text = response_text(analyze_result)
          has_controllers = analyze_text.include?("## Controllers")
          unless has_controllers
            # Check if any controllers or services reference this feature by name
            related_ctrls = Payload.controllers(ctx).select do |c_name, _|
              c_name.downcase.include?(feature_name.downcase) ||
                c_name.downcase.include?(feature_name.singularize.downcase) ||
                c_name.downcase.include?(feature_name.pluralize.downcase)
            end
            if related_ctrls.any?
              lines << "" << "## Related Controllers (by name)"
              related_ctrls.each do |c_name, c|
                actions = (c[:actions] || []).map { |a| a.is_a?(Hash) ? a[:name] : a }.compact
                lines << "- **#{c_name}** - #{actions.join(', ')}"
              end
            end

          end
        end

        lines.join("\n")
      rescue => e
        # Fall back to plain analyze_feature on error
        response_text(AnalyzeFeature.call(feature: feature_name))
      end
    end
  end
end
