# frozen_string_literal: true

module RailsAiContext
  module Tools
    class Onboard < BaseTool
      tool_name "rails_onboard"
      description "Get a narrative walkthrough of the Rails application - stack, data model, authentication, key flows, " \
        "background jobs, frontend, testing, getting started instructions, and the app's custom rake tasks, generators and Railties. " \
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

      STANDARD_SECTIONS = %i[stack data_model auth key_flows jobs frontend testing getting_started rake_tasks generators].freeze
      FULL_SECTIONS = %i[
        stack data_model auth key_flows jobs frontend payments realtime storage api devops i18n engines env
        testing getting_started all_rake_tasks generators
      ].freeze

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

          ruby = ruby_phrase(ctx)
          rails = named_rails_version(ctx)
          head = "**#{app}** is a Rails#{" #{rails}" if rails}"
          # The slash pairs two versions; with no Rails version to pair, the
          # Ruby one follows the noun instead of sitting in front of it.
          head += " / #{ruby}" if ruby && rails
          parts = [ head, "app" ]
          parts << "running #{ruby}" if ruby && !rails

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
            framework = tests[:framework]
            parts << (RailsAiContext::TestFramework.none?(framework) ? "with no tests yet" : "tested with #{framework || 'unknown framework'}")
          end

          parts.join(" ") + "."
        end

        def compose_standard(ctx)
          compose_sections(ctx, "# Welcome to #{ctx[:app_name] || 'This Rails App'}", STANDARD_SECTIONS)
        end

        def compose_full(ctx)
          compose_sections(ctx, "# Welcome to #{ctx[:app_name] || 'This Rails App'} (Full Walkthrough)", FULL_SECTIONS)
        end

        def compose_sections(ctx, heading, sections)
          lines = [ heading, "" ]
          sections.each { |name| lines.concat(send(:"section_#{name}", ctx)) }
          lines.join("\n")
        end

        # ── Section builders ─────────────────────────────────────────────

        def section_stack(ctx)
          lines = [ "## Stack", "" ]
          schema = Payload.section(ctx, :schema)
          if schema
            # Prefer live adapter from config over static_parse from schema introspector
            adapter = RailsAiContext::SchemaAdapter.label(ctx)
            db = "#{adapter} (#{count_phrase(schema[:total_tables].to_i, 'table')})"
          elsif RailsAiContext::AppKind.mongoid?(rails_app.root)
            database = RailsAiContext::AppKind.mongoid_database(rails_app.root)
            db = "MongoDB through Mongoid#{" (database #{database})" if database}"
          elsif !RailsAiContext::AppKind.active_record?(rails_app.root)
            db = nil
          else
            db = RailsAiContext::SchemaAdapter.label(ctx)
          end
          rails = named_rails_version(ctx)
          lines << "#{ctx[:app_name]} is a Rails#{" #{rails}" if rails} application#{ruby_clause(ctx)} #{db ? "on #{db}" : "without Active Record"}."
          outside = RailsAiContext::GemLock.for(rails_app.root).outside_gemfile unless rails
          lines << "Its gems and Rails version are not read: config/boot.rb points Bundler at `#{outside}`, outside the app root." if outside

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
          found = auth ? auth_lines(auth) : []
          found = auth_gem_lines(ctx) if found.empty?
          return [] if found.empty?

          [ "## Authentication & Authorization", "", *found, "" ]
        end

        # What the auth introspector writes, one sentence per finding.
        def auth_lines(auth)
          authn = auth[:authentication] || {}
          authz = auth[:authorization] || {}
          modules = auth[:devise_modules_per_model] || {}
          lines = Array(authn[:devise]).map do |entry|
            used = Array(modules[entry[:model]])
            "Authentication via Devise on #{entry[:model]}#{" (#{used.join(', ')})" if used.any?}."
          end
          lines << "Authentication via the Rails authentication generator (Session and Current models)." if authn[:rails_auth]
          if (rodauth = authn[:rodauth])
            classes = Array(rodauth[:classes])
            lines << "Authentication via Rodauth#{" (#{classes.join(', ')})" if classes.any?}."
          end
          lines << "has_secure_password on #{authn[:has_secure_password].join(', ')}." if Array(authn[:has_secure_password]).any?
          lines << "OmniAuth providers: #{authn[:omniauth_providers].join(', ')}." if Array(authn[:omniauth_providers]).any?
          { pundit: "Pundit", action_policy: "Action Policy" }.each do |key, label|
            lines << "Authorization via #{label} (#{count_phrase(authz[key].size, "policy")})." if Array(authz[key]).any?
          end
          lines << "#{count_phrase(authz[:policies].size, "policy class")} in app/policies." if Array(authz[:policies]).any?
          lines << "Authorization via CanCanCan (app/models/ability.rb)." if authz[:cancancan]
          lines << "An Ability class in #{authz[:ability_class]}." if authz[:ability_class]
          lines
        end

        AUTH_GEMS = %w[devise omniauth rodauth-rails sorcery clearance authlogic].freeze
        AUTHZ_GEMS = %w[pundit cancancan action_policy rolify].freeze

        # With no auth section to read, the notable gems still name the framework.
        def auth_gem_lines(ctx)
          notable = Payload.notable_gems(ctx).select { |g| g.is_a?(Hash) }
          authn = notable.select { |g| AUTH_GEMS.include?(g[:name].to_s) }
          authz = notable.select { |g| AUTHZ_GEMS.include?(g[:name].to_s) }
          lines = []
          lines << "Authentication via #{authn.map { |g| "#{g[:name]}#{" (#{g[:version]})" if g[:version]}" }.join(', ')}." if authn.any?
          lines << "Authorization via #{authz.map { |g| g[:name] }.join(', ')}." if authz.any?
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
                   "#{RouteCoverage.controller_phrase(routes)}#{framework_note}" \
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

          lines << "Data setup: #{data_setup_phrase(tests)}."

          ci = tests[:ci_config]
          lines << "CI: #{ci.join(', ')}." if ci&.any?

          coverage = tests[:coverage]
          lines << "Coverage: #{coverage}." if coverage

          test_cmd = RailsAiContext::TestFramework.command(framework)
          lines << "" << "Run tests: `#{test_cmd}`"
          lines << ""
          lines
        end

        def data_setup_phrase(tests)
          if tests[:factories]
            "FactoryBot (#{factory_phrase(tests)})"
          elsif tests[:fabricators]
            "Fabrication (#{fabricator_phrase(tests)})"
          elsif tests[:fixtures]
            "fixtures (#{RailsAiContext::TestFramework.fixture_phrase(tests[:fixtures])})"
          else
            "inline"
          end
        end

        def fabricator_phrase(tests)
          files = count_phrase(tests[:fabricators][:count].to_i, "file")
          names = tests[:fabricator_names]
          return files unless names.is_a?(Hash) && names.any?

          "#{count_phrase(names.values.sum { |list| Array(list).size }, "fabricator")} in #{files}"
        end

        # The factories a suite defines, and the files they sit in: one file
        # commonly defines several, so the file count is not the factory count.
        def factory_phrase(tests)
          files = count_phrase(tests[:factories][:count].to_i, "file")
          names = tests[:factory_names]
          return files unless names.is_a?(Hash) && names.any?

          # A factory named in a loop defines at least one, so the count is a floor.
          computed = tests[:computed_factories].to_i
          phrase = count_phrase(names.values.sum { |list| Array(list).size } + computed, "factory", plural: "factories")
          "#{computed.positive? ? floor_phrase(phrase) : phrase} in #{files}"
        end

        def section_getting_started(ctx)
          test_cmd = RailsAiContext::TestFramework.command(ctx[:tests].is_a?(Hash) ? ctx[:tests][:framework] : nil)
          server_cmd = RailsAiContext::AppCommands.server(rails_app.root)
          [
            "## Getting Started", "",
            "```bash",
            "git clone <repo-url>",
            "cd #{File.basename(rails_app.root.to_s)}",
            "bundle install",
            RailsAiContext::AppCommands.setup(rails_app.root),
            server_cmd,
            "#{test_cmd}  # verify everything works",
            "```", ""
          ].compact
        end

        RAKE_TASKS_SHOWN = 15

        def section_rake_tasks(ctx, limit: RAKE_TASKS_SHOWN)
          tasks = Payload.list(ctx, :rake_tasks, :tasks)
          return [] if tasks.empty?

          limit ||= tasks.size
          lines = [ "## Rake Tasks", "" ]
          tasks.first(limit).each { |task| lines << rake_task_line(task) }
          lines << "...#{tasks.size - limit} more: `detail:\"full\"` lists every task." if tasks.size > limit
          lines << ""
        end

        def section_all_rake_tasks(ctx)
          section_rake_tasks(ctx, limit: nil)
        end

        def section_generators(ctx)
          data = Payload.section(ctx, :rake_tasks) || {}
          generators = Array(data[:generators])
          templates = Array(data[:generator_templates])
          railties = Array(data[:railties])
          return [] if generators.empty? && templates.empty? && railties.empty?

          lines = [ "## Generators and Railties", "" ]
          generators.each do |g|
            lines << "- `#{g[:command]}`#{" - #{g[:usage]}" if g[:usage]} (`#{g[:file]}`)"
          end
          templates.each do |t|
            lines << "- `#{t[:file]}` replaces the template the `#{t[:generator]}` generator writes"
          end
          railties.each do |r|
            line = "- Railtie `#{r[:name]}` (`#{r[:file]}`)"
            notes = []
            notes << "initializers #{r[:initializers].map { |i| "`#{i}`" }.join(', ')}" if Array(r[:initializers]).any?
            notes << "adds rake tasks" if r[:rake_tasks]
            lines << (notes.any? ? "#{line}: #{notes.join('; ')}" : line)
          end
          lines << ""
        end

        def rake_task_line(task)
          return "- `#{task[:file]}`: not read (#{task[:error]})" if task[:error]

          args = Array(task[:args])
          line = "- `#{task[:name]}#{"[#{args.join(',')}]" if args.any?}`"
          line += " - #{task[:description]}" if task[:description]
          line + " (`#{task[:file]}`)"
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

          lines = []
          if storage && storage[:attachments]&.any?
            lines << "Active Storage: #{count_phrase(storage[:attachments].size, "attachment")} across models."
          end
          if text && text[:models]&.any?
            lines << "Action Text: #{count_phrase(text[:models].size, "model")} with rich text fields."
          end
          return [] if lines.empty?

          [ "## File Storage & Rich Text", "", *lines, "" ]
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
          classes = Array(api.dig(:serializers, :serializer_classes))
          lines << "Serializers: #{classes.size}." if classes.any?
          lines << ""
          lines
        end

        def section_devops(ctx)
          devops = Payload.section(ctx, :devops)
          lines = [ "## Deployment & DevOps", "" ]
          has_content = false

          if devops
            lines << "Dockerfile: #{devops[:docker] ? 'present' : 'not found'}."
            lines << "Procfile: #{devops[:procfile].present? ? 'present' : 'not found'}."
            deploy = devops[:deployment]
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

          lines = [ "## Mounted Apps", "" ]
          mounted.each do |e|
            name = e[:engine]
            path = e[:path]
            lines << (path ? "- **#{name}** at `#{path}`" : "- **#{name}**") if name
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
          validations.any? && validations.all? { |v| v.is_a?(Hash) && v[:implicit] }
        end

        # Statically the Ruby version is the one the app declares, not one
        # anything is running - and with nothing declaring one, ruby_version
        # is the interpreter running this tool, which says nothing about the
        # app. Then the sentence names no Ruby at all.
        def ruby_clause(ctx)
          ruby = ruby_phrase(ctx)
          return "" unless ruby

          ctx[:tier].to_s == "static" ? " declaring #{ruby}" : " running #{ruby}"
        end

        # "Ruby 3.4.9", or the engine first ("JRuby 9.4.8.0 (Ruby 3.1.4)"):
        # JRuby's own version is not the Ruby version it implements.
        def ruby_phrase(ctx)
          version = named_ruby_version(ctx)
          engine = ctx[:ruby_engine].to_s
          return version && "Ruby #{version}" if engine.empty?

          version ? "#{engine} (Ruby #{version})" : engine
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
          Payload.models_by_connection(models)
            .select { |name| models[name].is_a?(Hash) && !models[name][:error] }
            .first(limit)
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
