# frozen_string_literal: true

module RailsAiContext
  module Tools
    class GetContext < BaseTool
      tool_name "rails_get_context"

      # Each include key and the call it bundles, run only when the app serves that tool.
      INCLUDE_MAP = {
        "stimulus"    => [ "rails_get_stimulus", { detail: "standard" } ],
        "turbo"       => [ "rails_get_turbo_map", { detail: "standard" } ],
        "services"    => [ "rails_get_service_pattern", { detail: "standard" } ],
        "jobs"        => [ "rails_get_job_pattern", { detail: "standard" } ],
        "conventions" => [ "rails_get_config", { section: "conventions" } ],
        "helpers"     => [ "rails_get_helper_methods", { detail: "standard" } ],
        "env"         => [ "rails_get_config", { section: "env", detail: "summary" } ],
        "callbacks"   => [ "rails_get_callbacks", { detail: "standard" } ],
        "tests"       => [ "rails_get_test_info", { detail: "full" } ],
        "config"      => [ "rails_get_config", { section: "app" } ],
        "gems"        => [ "rails_get_config", { section: "gems" } ],
        "security"    => [ "rails_security_scan", { detail: "summary" } ]
      }.freeze
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
            description: "Additional context to bundle: #{INCLUDE_MAP.keys.map { |key| "'#{key}'" }.join(', ')}. Appends these to any mode."
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

        base_text = sections(base_text, *include_sections(include)) if include.is_a?(Array) && include.any?

        ctx = begin
          cached_context
        rescue StandardError
          nil
        end

        text_response(base_text, suffix: introspection_warnings_note(ctx))
      end

      # The sections that have text, with a rule between them.
      private_class_method def self.sections(*texts)
        texts.compact.reject(&:empty?).join("\n\n---\n\n")
      end

      private_class_method def self.section_text(response)
        response_text(response) unless empty?(response)
      end

      private_class_method def self.controller_action_context(controller_name, action_name)
        # Controller + action source + private methods + instance vars
        ctrl_result = compose(GetControllers, controller: controller_name, action: action_name)

        # Infer model from controller
        snake = RailsAiContext::Payload.controller_route_key(cached_context, controller_name)
        model_name = snake.split("/").last.singularize.camelize

        text = sections(response_text(ctrl_result), section_text(compose(GetModelDetails, model: model_name)),
                        section_text(compose(GetRoutes, controller: snake)), view_section(snake))
        extras = []

        # Cross-reference: controller ivars vs view ivars. The action's own
        # source, the methods it calls and the before filters that run for it
        # (a scaffold's `show` is empty and set_post sets @post) are the
        # controller's half; a body this app cannot read skips the cross-check.
        action_body = action_source(controller_name, action_name)
        resolver = RailsAiContext::Introspectors::ActionResolver
        ctrl_ivars = Set.new(action_body ? resolver.assigned_ivars(action_body) : [])
        origins = action_body ? ivar_origins(controller_name, action_name, action_body) : {}
        ctrl_ivars.merge(origins.keys)
        view_ivars = Payload.view_ivars(cached_context, "#{snake}/#{action_name}")
        rendered = action_body ? rendered_with_formats(action_body) : []
        other_templates = rendered.map(&:first).uniq.reject { |t| t == action_name }
        rendered.each do |tmpl, format|
          next if tmpl == action_name

          view_ivars.merge(Payload.view_ivars(cached_context, "#{snake}/#{tmpl}", format: format))
        end
        view_ivars.merge(action_body ? resolver.rendered_ivars(action_body) : [])
        # Without the view side's section every controller ivar reads as
        # unused, so no cross-check is the honest answer.
        if Payload.section(cached_context, :view_templates)
          ivar_check = cross_reference_ivars(ctrl_ivars, view_ivars, rendered_templates: other_templates, api_only: api_only_app?,
                                                                     origins: origins.except(*(action_body ? resolver.assigned_ivars(action_body) : [])))
          extras << ivar_check if ivar_check
        end

        # Hydrate: inject schema hints for models referenced in controller + view ivars
        if RailsAiContext.configuration.hydration_enabled
          all_ivars = (ctrl_ivars | view_ivars).to_a
          hydration = Hydrators::ViewHydrator.call(all_ivars, context: cached_context)
          hydration_text = Hydrators::HydrationFormatter.format(hydration)
          # Skip if get_controllers already injected schema hints
          extras << hydration_text unless hydration_text.empty? || text.include?("## Schema Hints")
        end

        [ text, *extras ].reject(&:empty?).join("\n\n")
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
      private_class_method def self.view_section(snake)
        view_result, view_note = controller_views(snake)
        return nil if empty?(view_result)

        [ view_note, response_text(view_result) ].compact.join("\n")
      end

      # @return [Array(MCP::Tool::Response, String, nil)] the view section and
      #   a note naming the directory it came from
      private_class_method def self.controller_views(snake)
        namespaced = compose(GetView, controller: snake, detail: "standard")
        return [ namespaced, "_Views from `app/views/#{snake}`._" ] unless empty?(namespaced)

        basename = snake.to_s.split("/").last
        return [ namespaced, nil ] if basename.nil? || basename == snake

        flat = compose(GetView, controller: basename, detail: "standard")
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

      private_class_method def self.cross_reference_ivars(ctrl_ivars, view_ivars, rendered_templates: [], api_only: false, origins: {})
        return nil if ctrl_ivars.empty? && view_ivars.empty?

        lines = [ "## Instance Variable Cross-Check" ]
        all = (ctrl_ivars | view_ivars).sort

        used_label = api_only ? "used in response" : "used in view"
        missing_label = api_only ? "referenced in response but NOT set in controller" : "used in view but NOT set in controller"
        unused_label = api_only ? "not rendered in response" : "not used in view"

        missing_ivars = []
        all.each do |ivar|
          in_ctrl = ctrl_ivars.include?(ivar)
          in_view = view_ivars.include?(ivar)
          set_by = origins[ivar] ? "set by `#{origins[ivar]}`" : "set in controller"
          if in_ctrl && in_view
            lines << "- \u2713 @#{ivar} - #{set_by}, #{used_label}"
          elsif in_view && !in_ctrl
            lines << "- \u2717 @#{ivar} - #{missing_label}"
            missing_ivars << ivar
          elsif in_ctrl && !in_view
            lines << "- \u26A0 @#{ivar} - #{set_by} but #{unused_label}"
          end
        end

        # The other template runs in this request, so its ivars are this
        # action's to set, whether it renders it on success (`render :show`)
        # or on failure (`render :new`).
        if missing_ivars.any? && rendered_templates.any?
          templates = rendered_templates.map { |t| "`#{t}`" }.join(", ")
          lines << ""
          lines << "_Note: This action also renders #{templates}, so that template's instance variables are counted here: " \
                   "this action or a filter it runs has to set them._"
        end

        (missing_ivars.any? || all.any?) ? lines.join("\n") : nil
      end

      KEYWORDS = %w[end else begin rescue ensure return super nil true false self yield next break redo retry].freeze

      # [template, format] for each `render :name` in the action: a render
      # inside a one-line `format.json { ... }` renders that format's template
      # only, any other every format's.
      private_class_method def self.rendered_with_formats(action_body)
        action_body.each_line.flat_map do |line|
          format = line[/\bformat\.(\w+)\s*(?:\{|do\b)/, 1]
          line.scan(/render\s+:(\w+)/).flatten.map { |tmpl| [ tmpl, format ] }
        end.uniq
      end

      # { ivar => the method that sets it } for the before and around
      # filters that run on the action, and the methods its body calls by
      # bare name, read from the controller's file, the ancestor or concern a
      # filter comes from.
      private_class_method def self.ivar_origins(controller_name, action_name, action_body)
        ctx = cached_context
        resolver = RailsAiContext::Introspectors::ActionResolver
        root = rails_app.root.to_s
        own = controller_source(ctx, controller_name)
        chain = RailsAiContext::ActionFilters.for(ctx, controller_name, action_name, root: root)[:chain]
        named = chain.select { |f| %w[before around].include?(f[:kind].to_s) }.map { |f| [ f[:name].to_s, f ] }
        called = action_body.scan(/^\s*(?:[a-z_]\w*\s*=\s*)?([a-z_]\w*[?!]?)\s*(?:\(|$)/).flatten.uniq
                            .reject { |name| name == action_name || KEYWORDS.include?(name) }.map { |name| [ name, {} ] }

        (named + called).each_with_object({}) do |(name, filter), found|
          sources = [ own, controller_source(ctx, filter[:from]), concern_source(root, filter[:from_concern]) ].compact
          body = sources.lazy.filter_map { |source| resolver.method_body(source, name)&.dig(:code) }.first
          next unless body&.match?(/\A\s*def\s+#{Regexp.escape(name)}\b/)

          resolver.assigned_ivars(body).each { |ivar| found[ivar] ||= name }
        end
      rescue => e
        RailsAiContext.debug_fail(e, {}, label: "ivar_origins")
      end

      private_class_method def self.controller_source(ctx, controller_name)
        carried = controller_name && Payload.controller_file(ctx, controller_name)
        carried && safe_read(File.join(rails_app.root.to_s, carried))
      end

      private_class_method def self.concern_source(root, concern)
        path = concern && RailsAiContext::ConcernPaths.find_file(root, concern)
        path && safe_read(path)
      end

      private_class_method def self.controller_context(controller_name)
        ctrl_result = compose(GetControllers, controller: controller_name)
        snake = RailsAiContext::Payload.controller_route_key(cached_context, controller_name)

        sections(response_text(ctrl_result), section_text(compose(GetRoutes, controller: snake)), view_section(snake))
      rescue => e
        "Error assembling context: #{e.message}"
      end

      private_class_method def self.model_context(model_name)
        # Normalize: try as-is, then singularized, then classified
        ctx = cached_context
        models = Payload.models(ctx)
        key = fuzzy_find_key(models.keys, model_name)

        resolved_name = key || model_name

        model_result = compose(GetModelDetails, model: resolved_name)

        # If model not found, fail fast - don't leak partial results from sub-tools.
        # A model the app has still gets its schema and tests when model details is turned off.
        return response_text(model_result) if empty?(model_result) && (key.nil? || own_served?(GetModelDetails))

        table = key && models[key][:table_name]
        sections(response_text(model_result), (section_text(compose(GetSchema, table: table)) if table),
                 section_text(compose(GetTestInfo, model: resolved_name, detail: "standard")))
      rescue => e
        "Error assembling context: #{e.message}"
      end

      private_class_method def self.include_sections(includes)
        includes.map do |key|
          name, args = INCLUDE_MAP[key.to_s.downcase]
          next "_`include` does not take '#{echo_input(key)}'. It takes: #{INCLUDE_MAP.keys.join(', ')}._" unless name

          off = include_off_message(name, args)
          next "_#{off}_" if off

          begin
            response_text(tool_class(name).call(**args))
          rescue => e
            "_Error loading #{key}: #{e.message}_"
          end
        end
      end

      # Why the app does not serve an include's tool or config section, or nil when it does.
      private_class_method def self.include_off_message(name, args)
        section = GetConfig.section_named(args[:section]) if name == "rails_get_config"
        return section.off_message if section && !section.on?

        RailsAiContext::Server.skipped_tool_message(name) unless section ? section.served? : own_served?(tool_class(name))
      end

      private_class_method def self.feature_context(feature_name)
        # Start with full-stack feature analysis
        analyze_result = compose(AnalyzeFeature, feature: feature_name)
        parts = [ response_text(analyze_result) ]
        related = []

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
            parts << section_text(compose(GetSchema, table: table_name))
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
              related << "## Related Controllers (by name)"
              related_ctrls.each do |c_name, c|
                actions = (c[:actions] || []).map { |a| a.is_a?(Hash) ? a[:name] : a }.compact
                related << "- **#{c_name}** - #{actions.join(', ')}"
              end
            end
          end
        end

        [ sections(*parts), related.join("\n") ].reject(&:empty?).join("\n\n")
      rescue => e
        # Fall back to plain analyze_feature on error
        RailsAiContext.debug_fail(e, label: "feature_context")
        response_text(compose(AnalyzeFeature, feature: feature_name))
      end
    end
  end
end
