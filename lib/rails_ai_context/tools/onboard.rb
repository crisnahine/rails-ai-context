# frozen_string_literal: true

module RailsAiContext
  module Tools
    class Onboard < BaseTool
      tool_name "rails_onboard"
      description "Get a narrative walkthrough of the Rails application - stack, data model, authentication, key flows, " \
        "background jobs, frontend, testing, and getting started instructions. " \
        "Use when: first encountering a project, onboarding a new developer, or orienting an AI agent. " \
        "Key params: detail (quick/standard/full)."

      input_schema(
        properties: {
          detail: {
            type: "string",
            enum: %w[quick standard full],
            description: "Detail level. quick: 1-paragraph overview. standard: structured walkthrough (default). full: all subsystems included."
          }
        }
      )

      annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true, open_world_hint: false)

      def self.call(detail: "standard", server_context: nil)
        ctx = cached_context

        body = case detail
        when "quick"
          compose_quick(ctx)
        when "full"
          compose_full(ctx)
        else
          compose_standard(ctx)
        end
        text_response(body, suffix: introspection_warnings_note(ctx))
      rescue => e
        text_response("Onboard error: #{e.message}")
      end

      class << self
        private

        # ── Quick: single paragraph ──────────────────────────────────────

        def compose_quick(ctx)
          app = ctx[:app_name] || "This Rails app"
          purpose = infer_app_purpose(ctx)

          parts = [ "**#{app}** is a Rails #{ctx[:rails_version]} / Ruby #{ctx[:ruby_version]}" ]
          parts << purpose if purpose

          # Stats: tables, models, jobs
          stats = []
          schema = ctx[:schema]
          if schema.is_a?(Hash) && !schema[:error]
            table_count = schema[:total_tables] || 0
            stats << count_phrase(table_count, "table") if table_count > 0
          end

          models = ctx[:models]
          if models.is_a?(Hash) && !models[:error] && models.any?
            stats << count_phrase(models.size, "model")
          end

          jobs = ctx[:jobs]
          if jobs.is_a?(Hash) && !jobs[:error]
            job_count = (jobs[:jobs] || []).size
            stats << count_phrase(job_count, "job") if job_count > 0
          end

          parts << "- #{stats.join(', ')}" if stats.any?

          # Frontend and testing
          frontend_desc = quick_frontend_summary(ctx)
          parts << "- #{frontend_desc}" if frontend_desc

          tests = ctx[:tests]
          if tests.is_a?(Hash) && !tests[:error]
            parts << "tested with #{tests[:framework] || 'unknown framework'}"
          end

          parts.join(" ") + "."
        end

        # ── Standard: structured walkthrough ─────────────────────────────

        def compose_standard(ctx) # rubocop:disable Metrics
          lines = [ "# Welcome to #{ctx[:app_name] || 'This Rails App'}", "" ]
          lines.concat(section_stack(ctx))
          lines.concat(section_data_model(ctx))
          lines.concat(section_auth(ctx))
          lines.concat(section_key_flows(ctx))
          lines.concat(section_jobs(ctx))
          lines.concat(section_frontend(ctx))
          lines.concat(section_testing(ctx))
          lines.concat(section_getting_started(ctx))
          lines.join("\n")
        end

        # ── Full: standard + all subsystems ──────────────────────────────

        def compose_full(ctx) # rubocop:disable Metrics
          lines = [ "# Welcome to #{ctx[:app_name] || 'This Rails App'} (Full Walkthrough)", "" ]
          lines.concat(section_stack(ctx))
          lines.concat(section_data_model(ctx))
          lines.concat(section_auth(ctx))
          lines.concat(section_key_flows(ctx))
          lines.concat(section_jobs(ctx))
          lines.concat(section_frontend(ctx))
          lines.concat(section_payments(ctx))
          lines.concat(section_realtime(ctx))
          lines.concat(section_storage(ctx))
          lines.concat(section_api(ctx))
          lines.concat(section_devops(ctx))
          lines.concat(section_i18n(ctx))
          lines.concat(section_engines(ctx))
          lines.concat(section_env(ctx))
          lines.concat(section_testing(ctx))
          lines.concat(section_getting_started(ctx))
          lines.join("\n")
        end

        # ── Section builders ─────────────────────────────────────────────

        def section_stack(ctx)
          lines = [ "## Stack", "" ]
          schema = ctx[:schema]
          if schema.is_a?(Hash) && !schema[:error]
            # Prefer live adapter from config over static_parse from schema introspector
            adapter = resolve_db_adapter(ctx, schema)
            db = "#{adapter} (#{count_phrase(schema[:total_tables].to_i, 'table')})"
          else
            db = "unknown"
          end
          lines << "#{ctx[:app_name]} is a Rails #{ctx[:rails_version]} application running Ruby #{ctx[:ruby_version]} on #{db}."

          gems = ctx[:gems]
          if gems.is_a?(Hash) && !gems[:error]
            notable = gems[:notable_gems] || []
            if notable.any?
              by_cat = notable.group_by { |g| g[:category]&.to_s || "other" }
              gem_parts = by_cat.first(5).map { |cat, list| "#{cat}: #{list.map { |g| g[:name] }.join(', ')}" }
              lines << "Notable gems - #{gem_parts.join('; ')}."
            end
          end

          conv = ctx[:conventions]
          if conv.is_a?(Hash) && !conv[:error]
            arch = conv[:architecture] || []
            lines << "Architecture: #{arch.join(', ')}." if arch.any?
          end

          lines << ""
          lines
        end

        def section_data_model(ctx)
          models = ctx[:models]
          return [] unless models.is_a?(Hash) && !models[:error] && models.any?

          lines = [ "## Data Model", "" ]
          top = central_models(models, 7)
          central_intro = models.size == 1 ? "" : " The central ones are:"
          lines << "The app has #{count_phrase(models.size, 'model')}.#{central_intro}"
          lines << ""

          top.each do |name|
            data = models[name]
            next unless data.is_a?(Hash) && !data[:error]
            assocs = (data[:associations] || []).map { |a| "#{a[:type]} :#{a[:name]}" }
            validations = data[:validations] || []
            desc = "**#{name}**"
            desc += " (table: `#{data[:table_name]}`)" if data[:table_name]
            desc += " - #{assocs.first(4).join(', ')}" if assocs.any?
            desc += ", +#{assocs.size - 4} more" if assocs.size > 4
            if validations.any?
              implicit_note = all_implicit_belongs_to_validations?(data) ? " (implicit belongs_to)" : ""
              desc += ". #{count_phrase(validations.size, 'validation')}#{implicit_note}."
            end
            lines << "- #{desc}"
          end

          remaining = models.size - top.size
          lines << "- _...and #{remaining} more #{remaining == 1 ? 'model' : 'models'}._" if remaining > 0
          lines << ""
          lines
        end

        def section_auth(ctx)
          auth = ctx[:auth]
          lines = [ "## Authentication & Authorization", "" ]
          has_content = false

          if auth.is_a?(Hash) && !auth[:error]
            authentication = auth[:authentication] || {}
            authorization = auth[:authorization] || {}
            if authentication[:method]
              lines << "Authentication is handled by #{authentication[:method]}."
              has_content = true
            end
            if authentication[:model]
              lines << "The #{authentication[:model]} model handles user accounts."
              has_content = true
            end
            if authorization[:method]
              lines << "Authorization uses #{authorization[:method]}."
              has_content = true
            end
          end

          # Fallback: detect auth from gems if introspector didn't provide data
          unless has_content
            gems = ctx[:gems]
            if gems.is_a?(Hash) && !gems[:error]
              notable = gems[:notable_gems] || []
              auth_gem_names = %w[devise omniauth rodauth sorcery clearance authlogic]
              auth_gems = notable.select { |g| g.is_a?(Hash) && auth_gem_names.include?(g[:name].to_s) }
              if auth_gems.any?
                lines << "Authentication via #{auth_gems.map { |g| "#{g[:name]}#{g[:version] ? " (#{g[:version]})" : ""}" }.join(', ')}."
                has_content = true
              end
              authz_gem_names = %w[pundit cancancan action_policy rolify]
              authz_gems = notable.select { |g| g.is_a?(Hash) && authz_gem_names.include?(g[:name].to_s) }
              if authz_gems.any?
                lines << "Authorization via #{authz_gems.map { |g| g[:name] }.join(', ')}."
                has_content = true
              end
            end
          end

          # Fallback: detect from conventions (global before_actions like authenticate_user!)
          unless has_content
            conv = ctx[:conventions]
            if conv.is_a?(Hash) && !conv[:error]
              before_acts = Array(conv[:before_actions]).select { |a| a.to_s.match?(/authenticat|authorize/) }
              auth_checks = Array(conv[:authorization_checks]) + before_acts
              if auth_checks.any?
                lines << "Auth checks detected: #{auth_checks.first(5).join(', ')}."
                has_content = true
              end
            end
          end

          return [] unless has_content
          lines << ""
          lines
        end

        def section_key_flows(ctx)
          routes = ctx[:routes]
          controllers = ctx[:controllers]
          return [] unless routes.is_a?(Hash) && !routes[:error]

          lines = [ "## Key Flows", "" ]
          by_ctrl = routes[:by_controller] || {}

          # Find controllers with most actions (most important flows). Uses the
          # same excluded-prefix config and PUT/PATCH dedup as rails_get_routes
          # so the route counts the two tools report agree with each other.
          prefixes = RailsAiContext.configuration.excluded_route_prefixes
          app_ctrls = by_ctrl.reject { |k, _| prefixes.any? { |p| k.downcase.start_with?(p) } }
            .transform_values { |route_list| dedupe_put_patch_routes(route_list) }
          top_ctrls = app_ctrls.sort_by { |_, routes_list| -routes_list.size }.first(5)

          top_ctrls.each do |ctrl, ctrl_routes|
            actions = ctrl_routes.map { |r| r[:action] }.compact.uniq
            verbs = ctrl_routes.map { |r| "#{r[:verb]} #{r[:path]}" }.first(3)
            lines << "- **#{ctrl}** - #{actions.join(', ')} (#{verbs.join(', ')})"
          end

          lines << ""
          # A single "total" invites mismatches with `rails routes` (the router
          # also holds internal and controller-less routes we never report), so
          # count app routes and framework-engine routes separately - both from
          # the same by_controller data, with the same PUT/PATCH dedup.
          app_route_count = app_ctrls.values.sum { |route_list| route_list.size }
          framework_count = by_ctrl
            .select { |k, _| prefixes.any? { |p| k.downcase.start_with?(p) } }
            .values.sum { |route_list| dedupe_put_patch_routes(route_list).size }
          framework_note = framework_count > 0 ? " (plus #{count_phrase(framework_count, 'framework route')})" : ""
          lines << "Total: #{count_phrase(app_route_count, 'app route')} across #{count_phrase(app_ctrls.size, 'controller')}#{framework_note}."
          lines << ""
          lines
        end

        def section_jobs(ctx)
          jobs = ctx[:jobs]
          return [] unless jobs.is_a?(Hash) && !jobs[:error]

          job_list = jobs[:jobs] || []
          mailers = jobs[:mailers] || []
          channels = jobs[:channels] || []
          return [] if job_list.empty? && mailers.empty? && channels.empty?

          lines = [ "## Background Jobs & Async", "" ]
          if job_list.any?
            names = job_list.map { |j| j[:name] || j[:class_name] }.compact.first(8)
            lines << "#{count_phrase(job_list.size, 'background job')}: #{names.join(', ')}#{job_list.size > 8 ? ', ...' : ''}."
          end
          lines << "#{count_phrase(mailers.size, 'mailer')}." if mailers.any?
          lines << "#{count_phrase(channels.size, 'Action Cable channel')}." if channels.any?
          lines << ""
          lines
        end

        def section_frontend(ctx)
          frontend = ctx[:frontend_frameworks]
          stimulus = ctx[:stimulus]
          turbo = ctx[:turbo]

          lines = []
          has_content = false

          if frontend.is_a?(Hash) && !frontend[:error] && frontend[:frameworks]&.any?
            lines << "## Frontend" << ""
            frameworks = frontend[:frameworks]
            if frameworks.is_a?(Hash)
              frameworks.each { |name, version| lines << "- #{name} #{version}".strip }
            elsif frameworks.is_a?(Array)
              frameworks.each { |fw| lines << "- #{fw.is_a?(Hash) ? "#{fw[:name]} #{fw[:version]}" : fw}".strip }
            end
            has_content = true
          end

          if stimulus.is_a?(Hash) && !stimulus[:error]
            count = stimulus[:total_controllers] || stimulus[:controllers]&.size || 0
            if count > 0
              lines << "## Frontend" << "" unless has_content
              lines << "Stimulus: #{count_phrase(count, 'controller')} for interactive behavior."
              has_content = true
            end
          end

          if turbo.is_a?(Hash) && !turbo[:error]
            frames = turbo[:frames]&.size || 0
            streams = turbo[:streams]&.size || 0
            if frames > 0 || streams > 0
              lines << "## Frontend" << "" unless has_content
              parts = []
              parts << "#{frames} Turbo Frames" if frames > 0
              parts << "#{streams} Turbo Streams" if streams > 0
              lines << "Hotwire: #{parts.join(', ')}."
              has_content = true
            end
          end

          lines << "" if has_content
          lines
        end

        def section_testing(ctx)
          tests = ctx[:tests]
          return [] unless tests.is_a?(Hash) && !tests[:error]

          lines = [ "## Testing", "" ]
          framework = tests[:framework] || "unknown"
          lines << "Framework: #{framework}."

          factories = tests[:factories]
          fixtures = tests[:fixtures]
          lines << "Data setup: #{factories ? "FactoryBot (#{count_phrase(factories[:count].to_i, 'factory')})" : fixtures ? "fixtures (#{count_phrase(fixtures[:count].to_i, 'file')})" : "inline"}."

          ci = tests[:ci_config]
          lines << "CI: #{ci.join(', ')}." if ci&.any?

          coverage = tests[:coverage]
          lines << "Coverage: #{coverage}." if coverage

          test_cmd = framework == "rspec" ? "bundle exec rspec" : "rails test"
          lines << "" << "Run tests: `#{test_cmd}`"
          lines << ""
          lines
        end

        def section_getting_started(ctx)
          test_cmd = (ctx[:tests].is_a?(Hash) && ctx[:tests][:framework] == "rspec") ? "bundle exec rspec" : "rails test"
          # bin/dev only exists in apps generated with a JS/CSS watcher;
          # recommending it elsewhere sends readers to a missing script.
          server_cmd = File.exist?(rails_app.root.join("bin", "dev")) ? "bin/dev  # or rails server" : "rails server"
          [
            "## Getting Started", "",
            "```bash",
            "git clone <repo-url>",
            "cd #{ctx[:app_name]&.underscore || 'app'}",
            "bundle install",
            "rails db:setup",
            server_cmd,
            "#{test_cmd}  # verify everything works",
            "```", ""
          ]
        end

        # ── Full-only sections ───────────────────────────────────────────

        def section_payments(ctx)
          gems = ctx[:gems]
          models = ctx[:models]
          return [] unless gems.is_a?(Hash) && !gems[:error] && models.is_a?(Hash)

          payment_gems = %w[stripe pay braintree paddle_pay]
          notable = gems[:notable_gems] || []
          found = notable.select { |g| payment_gems.include?(g[:name]) }
          payment_models = models.keys.select { |m| m.downcase.match?(/payment|subscription|charge|invoice|plan|billing/) }
          return [] if found.empty? && payment_models.empty?

          lines = [ "## Payments", "" ]
          lines << "Payment gems: #{found.map { |g| g[:name] }.join(', ')}." if found.any?
          lines << "Payment-related models: #{payment_models.join(', ')}." if payment_models.any?
          lines << ""
          lines
        end

        def section_realtime(ctx)
          turbo = ctx[:turbo]
          jobs = ctx[:jobs]
          channels = (jobs.is_a?(Hash) ? jobs[:channels] : nil) || []
          has_content = false

          lines = [ "## Real-Time Features", "" ]
          if channels.any?
            names = channels.map { |c| c[:name] || c[:class_name] }.compact
            lines << "Action Cable channels: #{names.join(', ')}."
            has_content = true
          end

          if turbo.is_a?(Hash) && !turbo[:error]
            broadcasts = turbo[:broadcasts] || turbo[:explicit_broadcasts] || []
            if broadcasts.any?
              lines << "Turbo Stream broadcasts: #{broadcasts.size} broadcast points."
              has_content = true
            end
            streams = turbo[:stream_subscriptions] || turbo[:subscriptions] || []
            if streams.any?
              lines << "Turbo Stream subscriptions: #{streams.size}."
              has_content = true
            end
          end

          # Fallback: check for turbo_stream usage in views
          unless has_content
            views = ctx[:view_templates] || ctx[:views]
            if views.is_a?(Hash) && !views[:error]
              templates = Array(views[:templates])
              turbo_views = templates.select { |v| v.is_a?(Hash) && (v[:path].to_s.include?("turbo_stream") || Array(v[:turbo_streams]).any?) }
              if turbo_views.any?
                lines << "Turbo Stream templates: #{turbo_views.size}."
                has_content = true
              end
            end
          end

          return [] unless has_content
          lines << ""
          lines
        end

        def section_storage(ctx)
          storage = ctx[:active_storage]
          text = ctx[:action_text]
          return [] unless (storage.is_a?(Hash) && !storage[:error]) || (text.is_a?(Hash) && !text[:error])

          lines = [ "## File Storage & Rich Text", "" ]
          if storage.is_a?(Hash) && !storage[:error] && storage[:attachments]&.any?
            lines << "Active Storage: #{storage[:attachments].size} attachment(s) across models."
          end
          if text.is_a?(Hash) && !text[:error] && text[:models]&.any?
            lines << "Action Text: #{text[:models].size} model(s) with rich text fields."
          end
          lines << ""
          lines
        end

        def section_api(ctx)
          api = ctx[:api]
          return [] unless api.is_a?(Hash) && !api[:error]
          return [] if api.empty? || (api[:endpoints]&.empty? && api[:graphql].nil?)

          lines = [ "## API", "" ]
          if api[:graphql]
            lines << "GraphQL API detected."
          end
          if api[:endpoints]&.any?
            lines << "#{api[:endpoints].size} API endpoint(s)."
          end
          if api[:serializers]&.any?
            lines << "Serializers: #{api[:serializers].size}."
          end
          lines << ""
          lines
        end

        def section_devops(ctx)
          devops = ctx[:devops]
          lines = [ "## Deployment & DevOps", "" ]
          has_content = false

          if devops.is_a?(Hash) && !devops[:error]
            lines << "Dockerfile: #{devops[:dockerfile] ? 'present' : 'not found'}."
            lines << "Procfile: #{devops[:procfile] ? 'present' : 'not found'}." if devops.key?(:procfile)
            deploy = devops[:deployment_method]
            lines << "Deployment: #{deploy}." if deploy
            has_content = true
          end

          # Fallback: check for Dockerfile/Procfile directly
          unless has_content
            root = rails_app.root.to_s
            has_dockerfile = File.exist?(File.join(root, "Dockerfile")) || File.exist?(File.join(root, "Dockerfile.dev"))
            has_procfile = File.exist?(File.join(root, "Procfile")) || File.exist?(File.join(root, "Procfile.dev"))
            has_ci = Dir.exist?(File.join(root, ".github", "workflows")) || File.exist?(File.join(root, ".gitlab-ci.yml"))

            if has_dockerfile || has_procfile || has_ci
              lines << "Dockerfile: #{has_dockerfile ? 'present' : 'not found'}."
              lines << "Procfile: #{has_procfile ? 'present' : 'not found'}."
              lines << "CI: #{has_ci ? 'detected' : 'not found'}."
              has_content = true
            end
          end

          return [] unless has_content
          lines << ""
          lines
        end

        def section_i18n(ctx)
          i18n = ctx[:i18n]
          return [] unless i18n.is_a?(Hash) && !i18n[:error]

          locales = i18n[:locales] || []
          return [] if locales.empty?

          [ "## Internationalization", "", "Locales: #{locales.join(', ')}.", "" ]
        end

        def section_engines(ctx)
          engines = ctx[:engines]
          return [] unless engines.is_a?(Hash) && !engines[:error]

          mounted = engines[:engines] || engines[:mounted] || []
          return [] if mounted.empty?

          lines = [ "## Mounted Engines", "" ]
          mounted.each do |e|
            name = e[:name] || e[:engine]
            path = e[:path] || e[:mount_path]
            lines << "- **#{name}** at `#{path}`" if name
          end
          lines << ""
          lines
        end

        def section_env(ctx)
          # Summarize from models that have encrypts, and auth/payment-related env patterns
          models = ctx[:models]
          return [] unless models.is_a?(Hash) && !models[:error]

          encrypted = models.select { |_, d| d.is_a?(Hash) && d[:encrypts]&.any? }
          return [] if encrypted.empty?

          lines = [ "## Encrypted Data", "" ]
          encrypted.each do |name, data|
            lines << "- **#{name}**: encrypts #{data[:encrypts].join(', ')}"
          end
          lines << ""
          lines
        end

        # ── Helpers ──────────────────────────────────────────────────────

        # "1 model" / "3 models" - raw interpolation reads wrong at count 1
        def count_phrase(count, noun)
          "#{count} #{count == 1 ? noun : noun.pluralize}"
        end

        # True when every validation on the model is the presence validator
        # ActiveRecord adds automatically for required belongs_to associations.
        # Those aren't hand-written rules, so the count deserves a qualifier.
        def all_implicit_belongs_to_validations?(data)
          validations = data[:validations] || []
          return false if validations.empty?

          belongs_to_names = (data[:associations] || [])
            .select { |a| a.is_a?(Hash) && a[:type].to_s == "belongs_to" }
            .map { |a| a[:name].to_s }
          return false if belongs_to_names.empty?

          validations.all? do |v|
            next false unless v.is_a?(Hash)
            kind = (v[:kind] || v["kind"]).to_s
            attrs = Array(v[:attributes] || v["attributes"]).map(&:to_s)
            kind == "presence" && attrs.any? && attrs.all? { |attr| belongs_to_names.include?(attr) }
          end
        end

        # Resolve the DB adapter name, preferring live config over schema introspection
        def resolve_db_adapter(ctx, schema)
          adapter = schema[:adapter]

          # If the schema introspector returned a non-informative adapter name, try config
          if adapter.nil? || adapter == "static_parse" || adapter == "unknown"
            config_data = ctx[:config]
            if config_data.is_a?(Hash) && !config_data[:error]
              live_adapter = config_data[:database_adapter] || config_data[:adapter]
              adapter = live_adapter if live_adapter
            end
          end

          # Try to resolve from gems as a fallback
          if adapter.nil? || adapter == "static_parse" || adapter == "unknown"
            gems_data = ctx[:gems]
            if gems_data.is_a?(Hash) && !gems_data[:error]
              notable = gems_data[:notable_gems] || []
              adapter = "PostgreSQL" if notable.any? { |g| g[:name] == "pg" }
              adapter = "MySQL" if notable.any? { |g| %w[mysql2 trilogy].include?(g[:name]) }
              adapter = "SQLite" if notable.any? { |g| g[:name] == "sqlite3" }
            end
          end

          adapter || "unknown"
        end

        def central_models(models, limit = 5)
          models
            .select { |_, d| d.is_a?(Hash) && !d[:error] }
            .sort_by { |_, d| -(d[:associations]&.size || 0) }
            .first(limit)
            .map(&:first)
        end

        # ── Purpose inference ────────────────────────────────────────────

        # Infer a short description of what the app does from its jobs,
        # services, models, gems, and architecture patterns.
        def infer_app_purpose(ctx)
          signals = collect_purpose_signals(ctx)
          return nil if signals.empty?

          # Deduplicate and join into a natural phrase
          capabilities = signals.uniq
          return nil if capabilities.empty?

          "#{capabilities.shift} app#{capabilities.any? ? ' with ' + join_capabilities(capabilities) : ''}"
        end

        # Collect domain signals from jobs, services, models, gems, and conventions
        def collect_purpose_signals(ctx) # rubocop:disable Metrics
          signals = []

          # Gather raw names from all sources
          job_names = extract_job_names(ctx)
          service_names = extract_service_names
          model_names = extract_model_names(ctx)
          gem_names = extract_gem_names(ctx)
          architecture = extract_architecture(ctx)

          # Infer primary domain from model names
          signals.concat(infer_domain(model_names, job_names, service_names))

          # Infer capabilities from jobs and services
          signals.concat(infer_ingestion_sources(job_names, service_names))
          signals.concat(infer_federation(service_names, gem_names, model_names))
          signals.concat(infer_ai_processing(service_names, job_names, gem_names))
          signals.concat(infer_social_features(model_names, service_names))
          signals.concat(infer_notifications(service_names, job_names))
          signals.concat(infer_search(gem_names, architecture))
          signals.concat(infer_ecommerce(model_names, service_names, gem_names))
          signals.concat(infer_messaging(model_names, job_names))

          signals
        end

        def extract_job_names(ctx)
          jobs = ctx[:jobs]
          return [] unless jobs.is_a?(Hash) && !jobs[:error]
          (jobs[:jobs] || []).map { |j| j[:name].to_s }.reject(&:empty?)
        end

        def extract_service_names
          services_dir = File.join(rails_app.root, "app", "services")
          return [] unless Dir.exist?(services_dir)

          real_root = File.realpath(rails_app.root).to_s
          safe_glob(services_dir, "**/*.rb", real_root).filter_map do |path|
            name = File.basename(path, ".rb").camelize
            name unless name == "ApplicationService" || name == "BaseService"
          end
        rescue => e
          $stderr.puts "[rails-ai-context] extract_service_names failed: #{e.message}" if ENV["DEBUG"]
          []
        end

        def extract_model_names(ctx)
          models = ctx[:models]
          return [] unless models.is_a?(Hash) && !models[:error]
          models.keys.map(&:to_s)
        end

        def extract_gem_names(ctx)
          gems = ctx[:gems]
          return [] unless gems.is_a?(Hash) && !gems[:error]
          (gems[:notable_gems] || []).map { |g| g[:name].to_s }
        end

        def extract_architecture(ctx)
          conv = ctx[:conventions]
          return [] unless conv.is_a?(Hash) && !conv[:error]
          conv[:architecture] || []
        end

        # Infer the primary domain of the app (e.g., "news aggregation", "e-commerce")
        def infer_domain(model_names, job_names, service_names)
          all_names = (model_names + job_names + service_names).map(&:downcase).join(" ")

          # Order matters: more specific patterns first
          if all_names.match?(/article|news|rss|feed/) && all_names.match?(/site|source|feed/)
            [ "news aggregation" ]
          elsif all_names.match?(/article|blog|post/) && all_names.match?(/comment|author/)
            [ "content publishing" ]
          elsif all_names.match?(/product|cart|order|checkout/)
            [ "e-commerce" ]
          elsif all_names.match?(/patient|appointment|doctor|medical/)
            [ "healthcare" ]
          elsif all_names.match?(/course|lesson|student|enrollment/)
            [ "education/LMS" ]
          elsif all_names.match?(/listing|property|booking|reservation/)
            [ "marketplace" ]
          elsif all_names.match?(/ticket|issue|sprint|project/) && all_names.match?(/assign|board/)
            [ "project management" ]
          elsif all_names.match?(/message|conversation|chat|thread/)
            [ "messaging" ]
          elsif all_names.match?(/invoice|payment|subscription|billing/)
            [ "billing/SaaS" ]
          elsif all_names.match?(/post|comment|follow|like|feed/)
            [ "social platform" ]
          elsif all_names.match?(/article|post|page|content/)
            [ "content management" ]
          else
            []
          end
        end

        # Infer content ingestion sources from job/service names
        def infer_ingestion_sources(job_names, service_names)
          all_names = (job_names + service_names).map(&:downcase)
          sources = []

          sources << "RSS" if all_names.any? { |n| n.include?("rss") }
          sources << "YouTube" if all_names.any? { |n| n.include?("youtube") }
          sources << "HackerNews" if all_names.any? { |n| n.include?("hackernews") || n.include?("hacker_news") }
          sources << "Reddit" if all_names.any? { |n| n.include?("reddit") }
          sources << "Gmail" if all_names.any? { |n| n.include?("gmail") }
          sources << "Twitter" if all_names.any? { |n| n.include?("twitter") }

          return [] if sources.empty?
          [ "#{sources.join(', ')} ingestion" ]
        end

        # Infer ActivityPub/federation features
        def infer_federation(service_names, gem_names, model_names)
          all = (service_names + gem_names + model_names).map(&:downcase)

          if all.any? { |n| n.match?(/mastodon|activitypub|federails|federation/) }
            [ "ActivityPub federation" ]
          elsif all.any? { |n| n.match?(/fediverse/) }
            [ "Fediverse integration" ]
          else
            []
          end
        end

        # Infer AI/ML processing features
        def infer_ai_processing(service_names, job_names, gem_names)
          all = (service_names + job_names + gem_names).map(&:downcase)

          if all.any? { |n| n.match?(/agent|openai|anthropic|llm|ai_|_ai/) }
            [ "AI processing" ]
          elsif all.any? { |n| n.match?(/ml_|machine_learn|predict/) }
            [ "ML processing" ]
          else
            []
          end
        end

        # Infer social features (follows, likes, etc.)
        def infer_social_features(model_names, service_names)
          all = (model_names + service_names).map(&:downcase)

          if all.any? { |n| n.match?(/follow|like|mention|social/) } && all.any? { |n| n.match?(/federation|mastodon/) }
            [] # Already covered by federation
          elsif all.any? { |n| n.match?(/oauth|social_media/) }
            [ "social media integration" ]
          else
            []
          end
        end

        # Infer push/notification features
        def infer_notifications(service_names, job_names)
          all = (service_names + job_names).map(&:downcase)

          if all.any? { |n| n.match?(/push_notif|web_push|notification/) }
            [ "push notifications" ]
          else
            []
          end
        end

        # Infer search capabilities
        def infer_search(gem_names, architecture)
          all = (gem_names + architecture).map(&:downcase)

          if all.any? { |n| n.match?(/elasticsearch|searchkick|meilisearch/) }
            [ "full-text search" ]
          else
            []
          end
        end

        # Infer e-commerce features
        def infer_ecommerce(model_names, service_names, gem_names)
          all = (model_names + service_names + gem_names).map(&:downcase)

          if all.any? { |n| n.match?(/stripe|pay\b|braintree/) }
            [ "payment processing" ]
          else
            []
          end
        end

        # Infer messaging/real-time features
        def infer_messaging(model_names, job_names)
          all = (model_names + job_names).map(&:downcase)

          if all.any? { |n| n.match?(/conversation|chat|direct_message/) }
            [ "real-time messaging" ]
          else
            []
          end
        end

        # Quick one-line frontend summary from conventions
        def quick_frontend_summary(ctx)
          conv = ctx[:conventions]
          return nil unless conv.is_a?(Hash) && !conv[:error]

          arch = conv[:architecture] || []
          parts = []

          parts << "Hotwire" if arch.include?("hotwire")
          parts << "Phlex" if arch.include?("phlex")
          parts << "ViewComponent" if arch.include?("view_components") && !arch.include?("phlex")
          parts << "Stimulus" if arch.include?("stimulus") && !arch.include?("hotwire")
          parts << "React" if arch.include?("react")
          parts << "Vue" if arch.include?("vue")

          # Check frontend frameworks introspection too
          frontend = ctx[:frontend_frameworks]
          if frontend.is_a?(Hash) && !frontend[:error]
            frameworks = frontend[:frameworks]
            if frameworks.is_a?(Hash)
              frameworks.each_key do |name|
                n = name.to_s.downcase
                parts << "React" if n.include?("react") && !parts.include?("React")
                parts << "Vue" if n.include?("vue") && !parts.include?("Vue")
                parts << "Angular" if n.include?("angular") && !parts.include?("Angular")
                parts << "Svelte" if n.include?("svelte") && !parts.include?("Svelte")
              end
            end
          end

          parts.any? ? "#{parts.join(' + ')} frontend" : nil
        end

        # Join a list of capabilities with commas and "and" before the last
        def join_capabilities(items)
          case items.size
          when 0 then ""
          when 1 then items.first
          when 2 then "#{items[0]} and #{items[1]}"
          else "#{items[0..-2].join(', ')}, and #{items.last}"
          end
        end
      end
    end
  end
end
