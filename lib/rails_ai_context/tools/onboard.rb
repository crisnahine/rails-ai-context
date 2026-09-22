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

      guide_row(
        order: 37,
        mcp: "rails_onboard(detail:\"standard\")",
        cli_args: "detail=standard",
        summary: "Narrative app walkthrough for new developers or AI agents"
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

          version = named_ruby_version(ctx)
          rails = named_rails_version(ctx)
          head = "**#{app}** is a Rails#{" #{rails}" if rails}"
          # The slash pairs two versions; with no Rails version to pair, the
          # Ruby one follows the noun instead of sitting in front of it.
          head += " / Ruby #{version}" if version && rails
          parts = [ head, "app" ]
          parts << "running Ruby #{version}" if version && !rails

          # Stats: tables, models, jobs
          stats = []
          schema = Payload.section(ctx, :schema)
          if schema
            table_count = schema[:total_tables] || 0
            stats << count_phrase(table_count, "table") if table_count > 0
          end

          models = Payload.models(ctx)
          if models.any?
            stats << count_phrase(models.size, "model")
          end

          jobs = Payload.section(ctx, :jobs)
          if jobs
            job_count = (jobs[:jobs] || []).size
            worker_count = (jobs[:workers] || []).size
            stats << count_phrase(job_count, "job") if job_count > 0
            stats << count_phrase(worker_count, "Sidekiq worker") if worker_count > 0
          end

          parts << "- #{stats.join(', ')}" if stats.any?

          # Frontend and testing
          frontend_desc = quick_frontend_summary(ctx)
          parts << "- #{frontend_desc}" if frontend_desc

          tests = Payload.section(ctx, :tests)
          if tests
            parts << "tested with #{tests[:framework] || 'unknown framework'}"
          end

          parts.join(" ") + "."
        end

        # ── Standard: structured walkthrough ─────────────────────────────

        def compose_standard(ctx)
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

        def compose_full(ctx)
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
          schema = Payload.section(ctx, :schema)
          if schema
            # Prefer live adapter from config over static_parse from schema introspector
            adapter = resolve_db_adapter(ctx, schema)
            db = "#{adapter} (#{count_phrase(schema[:total_tables].to_i, 'table')})"
          else
            db = "unknown"
          end
          rails = named_rails_version(ctx)
          lines << "#{ctx[:app_name]} is a Rails#{" #{rails}" if rails} application#{ruby_clause(ctx)} on #{db}."

          notable = Payload.notable_gems(ctx)
          if notable.any?
            by_cat = notable.group_by { |g| g[:category]&.to_s || "other" }
            gem_parts = by_cat.first(5).map { |cat, list| "#{cat}: #{list.map { |g| g[:name] }.join(', ')}" }
            lines << "Notable gems - #{gem_parts.join('; ')}."
          end

          conv = Payload.section(ctx, :conventions)
          if conv
            arch = conv[:architecture] || []
            lines << "Architecture: #{arch.join(', ')}." if arch.any?
          end

          lines << ""
          lines
        end

        def section_data_model(ctx)
          models = Payload.models(ctx)
          return [] unless models.any?

          lines = [ "## Data Model", "" ]
          top = central_models(models, 7)
          central_intro = models.size == 1 ? "" : " The central ones are:"
          lines << "The app has #{count_phrase(models.size, 'model')}.#{central_intro}"
          lines << ""

          top.each do |name|
            data = models[name]
            next unless data.is_a?(Hash) && !data[:error]
            assocs = Serializers::SectionFacts.associations_list(data)
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
          lines << "- _...and #{count_phrase(remaining, "more model")}._" if remaining > 0

          # A model whose introspection failed can never reach the list above,
          # and leaving it unnamed read as an app that does not have it.
          unavailable = models.select { |_, d| d.is_a?(Hash) && d[:error] }.keys
          lines << "- _#{count_phrase(unavailable.size, "model")} could not be read: #{unavailable.sort.join(', ')}._" if unavailable.any?
          lines << ""
          lines
        end

        def section_auth(ctx)
          auth = Payload.section(ctx, :auth)
          lines = [ "## Authentication & Authorization", "" ]
          has_content = false

          if auth
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
            notable = Payload.notable_gems(ctx)
            if notable.any?
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
            conv = Payload.section(ctx, :conventions)
            if conv
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
          routes = Payload.section(ctx, :routes)
          return [] unless routes

          lines = [ "## Key Flows", "" ]

          # Controllers with the most actions carry the app's key flows.
          app_ctrls = RouteCoverage.app_controllers(routes)
          top_ctrls = app_ctrls.sort_by { |_, routes_list| -routes_list.size }.first(5)

          top_ctrls.each do |ctrl, ctrl_routes|
            actions = ctrl_routes.map { |r| r[:action] }.compact.uniq
            verbs = ctrl_routes.map { |r| "#{r[:verb]} #{r[:path]}" }.first(3)
            lines << "- **#{ctrl}** - #{actions.join(', ')} (#{verbs.join(', ')})"
          end

          lines << ""
          # A single "total" invites mismatches with `rails routes` (the router
          # also holds internal and controller-less routes we never report), so
          # count app routes and framework-engine routes separately.
          app_route_count = RouteCoverage.app_route_count(routes)
          framework_count = RouteCoverage.framework_route_count(routes)
          framework_note = framework_count > 0 ? " (plus #{count_phrase(framework_count, 'framework route')})" : ""
          lines << "Total: #{count_phrase(app_route_count, 'app route')} across " \
                   "#{count_phrase(app_ctrls.size, 'controller')}#{framework_note}" \
                   "#{RailsAiContext::RouteCoverage.suffix(routes)}."
          lines << ""
          lines
        end

        def section_jobs(ctx)
          jobs = Payload.section(ctx, :jobs)
          return [] unless jobs

          job_list = jobs[:jobs] || []
          workers = jobs[:workers] || []
          mailers = jobs[:mailers] || []
          channels = jobs[:channels] || []
          return [] if job_list.empty? && workers.empty? && mailers.empty? && channels.empty?

          lines = [ "## Background Jobs & Async", "" ]
          if job_list.any?
            names = job_list.map { |j| j[:name] || j[:class_name] }.compact.first(8)
            lines << "#{count_phrase(job_list.size, 'background job')}: #{names.join(', ')}#{job_list.size > 8 ? ', ...' : ''}."
          end
          # The workers are in the same hash, and on an app that runs its
          # background work through Sidekiq they are all of it.
          if workers.any?
            names = workers.map { |w| w[:name] }.compact.first(8)
            lines << "#{count_phrase(workers.size, 'Sidekiq worker')}: #{names.join(', ')}#{workers.size > 8 ? ', ...' : ''}."
          end
          lines << "#{count_phrase(mailers.size, 'mailer')}." if mailers.any?
          lines << "#{count_phrase(channels.size, 'Action Cable channel')}." if channels.any?
          # The caveat points at app/workers, so it cannot stand next to a
          # list read out of app/workers.
          lines << GetJobPattern::NOT_COVERED if job_list.empty? && workers.empty?
          lines << ""
          lines
        end

        def section_frontend(ctx)
          frontend = Payload.section(ctx, :frontend_frameworks)
          stimulus = Payload.section(ctx, :stimulus)
          turbo = Payload.section(ctx, :turbo)

          lines = []
          has_content = false

          if frontend && frontend[:frameworks]&.any?
            lines << "## Frontend" << ""
            frameworks = frontend[:frameworks]
            if frameworks.is_a?(Hash)
              frameworks.each { |name, version| lines << "- #{name} #{version}".strip }
            elsif frameworks.is_a?(Array)
              frameworks.each { |fw| lines << "- #{fw.is_a?(Hash) ? "#{fw[:name]} #{fw[:version]}" : fw}".strip }
            end
            has_content = true
          end

          if stimulus
            count = stimulus[:total_controllers] || stimulus[:controllers]&.size || 0
            if count > 0
              lines << "## Frontend" << "" unless has_content
              lines << "Stimulus: #{count_phrase(count, 'controller')} for interactive behavior."
              has_content = true
            end
          end

          if turbo
            frames = turbo[:turbo_frames]&.size || 0
            streams = turbo[:turbo_streams]&.size || 0
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
          tests = Payload.section(ctx, :tests)
          return [] unless tests

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
            "cd #{File.basename(rails_app.root.to_s)}",
            "bundle install",
            "rails db:setup",
            server_cmd,
            "#{test_cmd}  # verify everything works",
            "```", ""
          ]
        end

        # ── Full-only sections ───────────────────────────────────────────

        def section_payments(ctx)
          gems = Payload.section(ctx, :gems)
          models = Payload.models(ctx)
          return [] unless gems

          payment_gems = %w[stripe pay braintree paddle_pay]
          found = Payload.notable_gems(ctx).select { |g| payment_gems.include?(g[:name]) }
          payment_models = models.keys.select { |m| m.downcase.match?(/payment|subscription|charge|invoice|plan|billing/) }
          return [] if found.empty? && payment_models.empty?

          lines = [ "## Payments", "" ]
          lines << "Payment gems: #{found.map { |g| g[:name] }.join(', ')}." if found.any?
          lines << "Payment-related models: #{payment_models.join(', ')}." if payment_models.any?
          lines << ""
          lines
        end

        def section_realtime(ctx)
          channels = Payload.channels(ctx)
          has_content = false

          lines = [ "## Real-Time Features", "" ]
          if channels.any?
            names = channels.map { |c| c[:name] || c[:class_name] }.compact
            lines << "Action Cable channels: #{names.join(', ')}."
            has_content = true
          end

          broadcasts = Payload.model_broadcasts(ctx)
          if broadcasts.any?
            lines << "Turbo Stream broadcasts: #{count_phrase(broadcasts.size, "broadcast point")}."
            has_content = true
          end
          streams = Payload.turbo_streams(ctx)
          if streams.any?
            lines << "Turbo Stream templates: #{streams.size}."
            has_content = true
          end

          # Fallback: check for turbo_stream usage in views
          unless has_content
            views = Payload.section(ctx, :view_templates) || Payload.section(ctx, :views)
            if views
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
          storage = Payload.section(ctx, :active_storage)
          text = Payload.section(ctx, :action_text)
          return [] unless storage || text

          lines = [ "## File Storage & Rich Text", "" ]
          if storage && storage[:attachments]&.any?
            lines << "Active Storage: #{count_phrase(storage[:attachments].size, "attachment")} across models."
          end
          if text && text[:models]&.any?
            lines << "Action Text: #{count_phrase(text[:models].size, "model")} with rich text fields."
          end
          lines << ""
          lines
        end

        def section_api(ctx)
          api = Payload.section(ctx, :api)
          return [] unless api
          return [] if api.empty? || (api[:endpoints]&.empty? && api[:graphql].nil?)

          lines = [ "## API", "" ]
          if api[:graphql]
            lines << "GraphQL API detected."
          end
          if api[:endpoints]&.any?
            lines << "#{count_phrase(api[:endpoints].size, "API endpoint")}."
          end
          if api[:serializers]&.any?
            lines << "Serializers: #{api[:serializers].size}."
          end
          lines << ""
          lines
        end

        def section_devops(ctx)
          devops = Payload.section(ctx, :devops)
          lines = [ "## Deployment & DevOps", "" ]
          has_content = false

          if devops
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
          i18n = Payload.section(ctx, :i18n)
          return [] unless i18n

          locales = i18n[:locales] || []
          return [] if locales.empty?

          [ "## Internationalization", "", "Locales: #{locales.join(', ')}.", "" ]
        end

        def section_engines(ctx)
          mounted = Payload.mounted_engines(ctx)
          return [] if mounted.empty?

          lines = [ "## Mounted Engines", "" ]
          mounted.each do |e|
            name = e[:engine]
            path = e[:path]
            lines << "- **#{name}** at `#{path}`" if name
          end
          lines << ""
          lines
        end

        def section_env(ctx)
          # Summarize from models that have encrypts, and auth/payment-related env patterns
          models = Payload.models(ctx)
          return [] unless models.any?

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

        # The gems loop here let the LAST match win, so an app carrying both pg
        # and sqlite3 was told SQLite by onboard and PostgreSQL by the
        # generated files. One seam, one answer.
        def resolve_db_adapter(ctx, _schema = nil)
          RailsAiContext::SchemaAdapter.label(ctx)
        end

        # Statically the Ruby version is the one the app declares, not one
        # anything is running - and with nothing declaring one, ruby_version
        # is the interpreter running this tool, which says nothing about the
        # app. Then the sentence names no Ruby at all.
        def ruby_clause(ctx)
          version = named_ruby_version(ctx)
          return "" unless version

          ctx[:tier].to_s == "static" ? " declaring Ruby #{version}" : " running Ruby #{version}"
        end

        # The version a sentence may name, or nil. Statically that is the one
        # the app declares; with nothing declared, the value is the interpreter
        # running this tool and says nothing about the app.
        # Keyed on the value the sentence would print, not on a sibling
        # section: an app with a Gemfile and no lockfile declares a Ruby
        # version that the gems section cannot answer for.
        def named_ruby_version(ctx)
          named_version(ctx[:ruby_version])
        end

        # Same rule for the Rails version: a lockfile naming no rails answers
        # a marker, and these sentences go into files the user commits.
        def named_rails_version(ctx)
          named_version(ctx[:rails_version])
        end

        def named_version(value)
          version = value.to_s
          return nil if version.empty? || version.start_with?("[UNAVAILABLE")

          version
        end

        def central_models(models, limit = 5)
          models
            .select { |_, d| d.is_a?(Hash) && !d[:error] }
            .sort_by { |_, d| -(d[:associations]&.size || 0) }
            .first(limit)
            .map(&:first)
        end

        # Quick one-line frontend summary from conventions
        def quick_frontend_summary(ctx)
          conv = Payload.section(ctx, :conventions)
          return nil unless conv

          arch = conv[:architecture] || []
          parts = []

          parts << "Hotwire" if arch.include?("hotwire")
          parts << "Phlex" if arch.include?("phlex")
          parts << "ViewComponent" if arch.include?("view_components") && !arch.include?("phlex")
          parts << "Stimulus" if arch.include?("stimulus") && !arch.include?("hotwire")
          parts << "React" if arch.include?("react")
          parts << "Vue" if arch.include?("vue")

          # Check frontend frameworks introspection too
          frontend = Payload.section(ctx, :frontend_frameworks)
          if frontend
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
      end
    end
  end
end
