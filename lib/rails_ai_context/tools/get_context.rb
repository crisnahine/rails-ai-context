# frozen_string_literal: true

module RailsAiContext
  module Tools
    class GetContext < BaseTool
      tool_name "rails_get_context"
      description "Get cross-layer context in a single call — combines schema, model, controller, routes, views, stimulus, and tests. " \
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

      annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true, open_world_hint: false)

      def self.call(controller: nil, action: nil, model: nil, feature: nil, include: nil, server_context: nil)
        set_call_params(controller: controller, action: action, model: model, feature: feature)
        result = if controller && action
          controller_action_context(controller, action)
        elsif controller
          controller_context(controller)
        elsif model
          model_context(model)
        elsif feature
          feature_context(feature)
        else
          return text_response("Provide at least one of: controller, model, or feature.")
        end

        # Append additional context sections if include: is specified
        if include.is_a?(Array) && include.any?
          base_text = result.content.first[:text]
          extra = append_includes(include)
          return text_response(base_text + extra)
        end

        result
      end

      private_class_method def self.controller_action_context(controller_name, action_name)
        lines = []

        # Controller + action source + private methods + instance vars
        ctrl_result = GetControllers.call(controller: controller_name, action: action_name)
        lines << ctrl_result.content.first[:text]

        # Infer model from controller
        snake = controller_name.to_s.underscore.delete_suffix("_controller")
        model_name = snake.split("/").last.singularize.camelize

        # Model details
        model_result = GetModelDetails.call(model: model_name)
        model_text = model_result.content.first[:text]
        unless model_text.include?("not found")
          lines << "" << "---" << "" << model_text
        end

        # Routes for this controller
        route_result = GetRoutes.call(controller: snake)
        route_text = route_result.content.first[:text]
        unless route_text.include?("not found") || route_text.include?("No routes")
          lines << "" << "---" << ""
          lines << route_text
        end

        # Views for this controller
        view_ctrl = snake.split("/").last
        view_result = GetView.call(controller: view_ctrl, detail: "standard")
        view_text = view_result.content.first[:text]
        unless view_text.include?("No views")
          lines << "" << "---" << ""
          lines << view_text
        end

        # Cross-reference: controller ivars vs view ivars
        # Also check templates rendered by the action (e.g., create renders :new on failure)
        ctrl_text = ctrl_result.content.first[:text]
        ctrl_ivars = extract_ivars_from_text(ctrl_text)
        view_ivars = extract_ivars_from_view_text(view_text, action: action_name)
        # Detect "render :other_template" and include those templates' ivars too
        rendered = ctrl_text.scan(/render\s+:(\w+)/).flatten.uniq
        other_templates = rendered.reject { |t| t == action_name }
        other_templates.each do |tmpl|
          view_ivars.merge(extract_ivars_from_view_text(view_text, action: tmpl))
        end
        ivar_check = cross_reference_ivars(ctrl_ivars, view_ivars, rendered_templates: other_templates)
        lines << "" << ivar_check if ivar_check

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

        text_response(lines.join("\n"))
      rescue => e
        text_response("Error assembling context: #{e.message}")
      end

      private_class_method def self.extract_ivars_from_text(text)
        # Extract from "## Instance Variables\n- @foo\n- @bar" section
        ivars = Set.new
        in_section = false
        text.each_line do |line|
          if line.include?("Instance Variables")
            in_section = true
            next
          end
          if in_section
            break unless line.strip.start_with?("- ")
            match = line.match(/@(\w+)/)
            ivars << match[1] if match
          end
        end
        ivars
      end

      private_class_method def self.extract_ivars_from_view_text(text, action: nil)
        # Extract from "ivars: foo, bar, baz" in view listing
        # When action is specified, only extract from the matching template (e.g., "show.html.erb" for action "show")
        ivars = Set.new
        text.each_line do |line|
          # Skip lines that don't match the action's template when filtering
          if action
            # Match: "posts/show.html.erb" for action "show", "posts/index.html.erb" for "index", etc.
            next unless line.match?(/\/#{Regexp.escape(action)}\.html\.erb\b/)
          end
          if (match = line.match(/ivars:\s*(.+?)(?:\s+turbo:|$)/))
            match[1].split(",").each { |v| ivars << v.strip }
          end
        end
        ivars
      end

      private_class_method def self.cross_reference_ivars(ctrl_ivars, view_ivars, rendered_templates: [])
        return nil if ctrl_ivars.empty? && view_ivars.empty?

        lines = [ "## Instance Variable Cross-Check" ]
        all = (ctrl_ivars | view_ivars).sort

        missing_ivars = []
        all.each do |ivar|
          in_ctrl = ctrl_ivars.include?(ivar)
          in_view = view_ivars.include?(ivar)
          if in_ctrl && in_view
            lines << "- \u2713 @#{ivar} — set in controller, used in view"
          elsif in_view && !in_ctrl
            lines << "- \u2717 @#{ivar} — used in view but NOT set in controller"
            missing_ivars << ivar
          elsif in_ctrl && !in_view
            lines << "- \u26A0 @#{ivar} — set in controller but not used in view"
          end
        end

        # If there are missing ivars AND this action renders another template,
        # add a note explaining why — the other action likely sets them
        if missing_ivars.any? && rendered_templates.any?
          templates = rendered_templates.map { |t| "`#{t}`" }.join(", ")
          lines << ""
          lines << "_Note: This action renders #{templates} on failure — those ivars are likely set in the corresponding action(s)._"
        end

        (missing_ivars.any? || all.any?) ? lines.join("\n") : nil
      end

      private_class_method def self.controller_context(controller_name)
        lines = []

        ctrl_result = GetControllers.call(controller: controller_name)
        lines << ctrl_result.content.first[:text]

        snake = controller_name.to_s.underscore.delete_suffix("_controller")

        # Routes for this controller
        route_result = GetRoutes.call(controller: snake)
        route_text = route_result.content.first[:text]
        unless route_text.include?("not found") || route_text.include?("No routes")
          lines << "" << "---" << "" << route_text
        end

        # Views for this controller
        view_ctrl = snake.split("/").last
        view_result = GetView.call(controller: view_ctrl, detail: "standard")
        view_text = view_result.content.first[:text]
        unless view_text.include?("No views")
          lines << "" << "---" << "" << view_text
        end

        text_response(lines.join("\n"))
      rescue => e
        text_response("Error assembling context: #{e.message}")
      end

      private_class_method def self.model_context(model_name)
        lines = []

        # Normalize: try as-is, then singularized, then classified
        ctx = cached_context
        models = ctx[:models] || {}
        key = fuzzy_find_key(models.keys, model_name)

        resolved_name = key || model_name

        model_result = GetModelDetails.call(model: resolved_name)
        model_text = model_result.content.first[:text]

        # If model not found, fail fast — don't leak partial results from sub-tools
        if model_text.include?("not found")
          return model_result
        end

        lines << model_text

        if key && models[key][:table_name]
          schema_result = GetSchema.call(table: models[key][:table_name])
          schema_text = schema_result.content.first[:text]
          # Only append schema if it actually has useful data (not "not found")
          unless schema_text.include?("not found") || schema_text.include?("Available:")
            lines << "" << "---" << "" << schema_text
          end
        end

        # Tests for this model
        test_result = GetTestInfo.call(model: resolved_name, detail: "standard")
        test_text = test_result.content.first[:text]
        unless test_text.include?("No test file found")
          lines << "" << "---" << "" << test_text
        end

        text_response(lines.join("\n"))
      rescue => e
        text_response("Error assembling context: #{e.message}")
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
            result = handler.call
            text = result.content.first[:text]
            extra << "\n\n---\n\n" << text
          rescue => e
            extra << "\n\n---\n\n_Error loading #{key}: #{e.message}_"
          end
        end
        extra
      end

      private_class_method def self.feature_context(feature_name)
        # Start with full-stack feature analysis
        analyze_result = AnalyzeFeature.call(feature: feature_name)
        lines = [ analyze_result.content.first[:text] ]

        # Enrich with schema columns for matching models
        ctx = begin; cached_context; rescue; nil; end
        if ctx
          models = ctx[:models] || {}
          matched_tables = Set.new

          models.each_key do |model_name|
            next unless model_name.downcase.include?(feature_name.downcase)
            table_name = models[model_name][:table_name]
            next unless table_name
            matched_tables << table_name
            schema_result = GetSchema.call(table: table_name)
            schema_text = schema_result.content.first[:text]
            unless schema_text.include?("not found")
              lines << "" << "---" << "" << schema_text
            end
          end

          # Also include schema for related models (associated tables) if the
          # primary model was found but the feature analysis missed controllers/services
          analyze_text = analyze_result.content.first[:text]
          has_controllers = analyze_text.include?("## Controllers")
          unless has_controllers
            # Check if any controllers or services reference this feature by name
            controllers = ctx[:controllers]
            if controllers.is_a?(Hash) && !controllers[:error]
              related_ctrls = (controllers[:controllers] || []).select do |c|
                c_name = c[:name] || ""
                c_name.downcase.include?(feature_name.downcase) ||
                  c_name.downcase.include?(feature_name.singularize.downcase) ||
                  c_name.downcase.include?(feature_name.pluralize.downcase)
              end
              if related_ctrls.any?
                lines << "" << "## Related Controllers (by name)"
                related_ctrls.each do |c|
                  actions = (c[:actions] || []).map { |a| a.is_a?(Hash) ? a[:name] : a }.compact
                  lines << "- **#{c[:name]}** — #{actions.join(', ')}"
                end
              end
            end

            # Check services
            services = ctx[:services] || ctx[:service_objects]
            if services.is_a?(Hash) && !services[:error]
              service_list = services[:services] || []
              related_svcs = service_list.select do |s|
                s_name = (s[:name] || s[:file] || "").to_s
                s_name.downcase.include?(feature_name.downcase) ||
                  s_name.downcase.include?(feature_name.singularize.downcase)
              end
              if related_svcs.any?
                lines << "" << "## Related Services (by name)"
                related_svcs.each { |s| lines << "- `#{s[:file] || s[:name]}`" }
              end
            end
          end
        end

        text_response(lines.join("\n"))
      rescue => e
        # Fall back to plain analyze_feature on error
        AnalyzeFeature.call(feature: feature_name)
      end
    end
  end
end
