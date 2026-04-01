# frozen_string_literal: true

module RailsAiContext
  module Tools
    class Onboard < BaseTool
      tool_name "rails_onboard"
      description "Get a narrative walkthrough of the Rails application — stack, data model, authentication, key flows, " \
        "background jobs, frontend, testing, and getting started instructions. " \
        "Use when: first encountering a project, onboarding a new developer, or orienting an AI agent. " \
        "Key params: detail (quick/standard/full)."

      input_schema(
        properties: {
          detail: {
            type: "string",
            enum: %w[quick standard full],
            description: "Detail level. quick: 1-paragraph overview. standard: structured walkthrough (default). full: comprehensive with all subsystems."
          }
        }
      )

      annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true, open_world_hint: false)

      def self.call(detail: "standard", server_context: nil)
        ctx = cached_context

        case detail
        when "quick"
          text_response(compose_quick(ctx))
        when "full"
          text_response(compose_full(ctx))
        else
          text_response(compose_standard(ctx))
        end
      rescue => e
        text_response("Onboard error: #{e.message}")
      end

      class << self
        private

        # ── Quick: single paragraph ──────────────────────────────────────

        def compose_quick(ctx)
          app = ctx[:app_name] || "This Rails app"
          parts = [ "**#{app}** is a Rails #{ctx[:rails_version]} application running Ruby #{ctx[:ruby_version]}" ]

          schema = ctx[:schema]
          if schema.is_a?(Hash) && !schema[:error]
            parts << "on #{schema[:adapter]} with #{schema[:total_tables]} tables"
          end

          models = ctx[:models]
          if models.is_a?(Hash) && !models[:error] && models.any?
            top = central_models(models, 3).join(", ")
            parts << "— #{models.size} models (key: #{top})"
          end

          tests = ctx[:tests]
          if tests.is_a?(Hash) && !tests[:error]
            parts << "— tested with #{tests[:framework] || 'unknown framework'}"
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
          db = schema.is_a?(Hash) && !schema[:error] ? "#{schema[:adapter]} (#{schema[:total_tables]} tables)" : "unknown"
          lines << "#{ctx[:app_name]} is a Rails #{ctx[:rails_version]} application running Ruby #{ctx[:ruby_version]} on #{db}."

          gems = ctx[:gems]
          if gems.is_a?(Hash) && !gems[:error]
            notable = gems[:notable_gems] || []
            if notable.any?
              by_cat = notable.group_by { |g| g[:category]&.to_s || "other" }
              gem_parts = by_cat.first(5).map { |cat, list| "#{cat}: #{list.map { |g| g[:name] }.join(', ')}" }
              lines << "Notable gems — #{gem_parts.join('; ')}."
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
          lines << "The app has #{models.size} models. The central ones are:"
          lines << ""

          top.each do |name|
            data = models[name]
            next unless data.is_a?(Hash) && !data[:error]
            assocs = (data[:associations] || []).map { |a| "#{a[:type]} :#{a[:name]}" }
            val_count = (data[:validations] || []).size
            desc = "**#{name}**"
            desc += " (table: `#{data[:table_name]}`)" if data[:table_name]
            desc += " — #{assocs.first(4).join(', ')}" if assocs.any?
            desc += ", +#{assocs.size - 4} more" if assocs.size > 4
            desc += ". #{val_count} validations." if val_count > 0
            lines << "- #{desc}"
          end

          remaining = models.size - top.size
          lines << "- _...and #{remaining} more models._" if remaining > 0
          lines << ""
          lines
        end

        def section_auth(ctx)
          auth = ctx[:auth]
          return [] unless auth.is_a?(Hash) && !auth[:error]

          authentication = auth[:authentication] || {}
          authorization = auth[:authorization] || {}
          return [] if authentication.empty? && authorization.empty?

          lines = [ "## Authentication & Authorization", "" ]
          if authentication[:method]
            lines << "Authentication is handled by #{authentication[:method]}."
          end
          if authentication[:model]
            lines << "The #{authentication[:model]} model handles user accounts."
          end
          if authorization[:method]
            lines << "Authorization uses #{authorization[:method]}."
          end
          lines << ""
          lines
        end

        def section_key_flows(ctx)
          routes = ctx[:routes]
          controllers = ctx[:controllers]
          return [] unless routes.is_a?(Hash) && !routes[:error]

          lines = [ "## Key Flows", "" ]
          by_ctrl = routes[:by_controller] || {}

          # Find controllers with most actions (most important flows)
          internal_prefixes = %w[action_mailbox/ active_storage/ rails/ conductor/ devise/ turbo/]
          app_ctrls = by_ctrl.reject { |k, _| internal_prefixes.any? { |p| k.downcase.start_with?(p) } }
          top_ctrls = app_ctrls.sort_by { |_, routes_list| -routes_list.size }.first(5)

          top_ctrls.each do |ctrl, ctrl_routes|
            actions = ctrl_routes.map { |r| r[:action] }.compact.uniq
            verbs = ctrl_routes.map { |r| "#{r[:verb]} #{r[:path]}" }.first(3)
            lines << "- **#{ctrl}** — #{actions.join(', ')} (#{verbs.join(', ')})"
          end

          lines << ""
          lines << "Total: #{routes[:total_routes]} routes across #{app_ctrls.size} controllers."
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
            lines << "#{job_list.size} background jobs: #{names.join(', ')}#{job_list.size > 8 ? ', ...' : ''}."
          end
          lines << "#{mailers.size} mailers." if mailers.any?
          lines << "#{channels.size} Action Cable channels." if channels.any?
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
              lines << "Stimulus: #{count} controllers for interactive behavior."
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
          lines << "Data setup: #{factories ? "FactoryBot (#{factories[:count]} factories)" : fixtures ? "fixtures (#{fixtures[:count]} files)" : "inline"}."

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
          [
            "## Getting Started", "",
            "```bash",
            "git clone <repo-url>",
            "cd #{ctx[:app_name]&.underscore || 'app'}",
            "bundle install",
            "rails db:setup",
            "bin/dev  # or rails server",
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
          return [] unless (turbo.is_a?(Hash) && !turbo[:error]) || channels.any?

          lines = [ "## Real-Time Features", "" ]
          if channels.any?
            names = channels.map { |c| c[:name] || c[:class_name] }.compact
            lines << "Action Cable channels: #{names.join(', ')}."
          end
          if turbo.is_a?(Hash) && !turbo[:error] && turbo[:broadcasts]&.any?
            lines << "Turbo Stream broadcasts: #{turbo[:broadcasts].size} broadcast points."
          end
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
          return [] unless devops.is_a?(Hash) && !devops[:error]

          lines = [ "## Deployment & DevOps", "" ]
          lines << "Dockerfile: #{devops[:dockerfile] ? 'present' : 'not found'}."
          lines << "Procfile: #{devops[:procfile] ? 'present' : 'not found'}." if devops.key?(:procfile)
          deploy = devops[:deployment_method]
          lines << "Deployment: #{deploy}." if deploy
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

        def central_models(models, limit = 5)
          models
            .select { |_, d| d.is_a?(Hash) && !d[:error] }
            .sort_by { |_, d| -(d[:associations]&.size || 0) }
            .first(limit)
            .map(&:first)
        end
      end
    end
  end
end
