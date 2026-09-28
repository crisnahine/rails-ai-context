# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    # Discovers mounted Rails engines and Rack apps from config/routes.rb.
    # Identifies well-known engines and provides context about what each does.
    class EngineIntrospector < Base
      extend StaticTier
      static_tier :alternate_source

      KNOWN_ENGINES = {
        "Sidekiq::Web" => { category: :admin, description: "Sidekiq background job dashboard" },
        "GoodJob::Engine" => { category: :admin, description: "GoodJob dashboard for background jobs" },
        "MissionControl::Jobs::Engine" => { category: :admin, description: "Rails Mission Control for SolidQueue jobs" },
        "ActiveAdmin::Engine" => { category: :admin, description: "ActiveAdmin administration framework" },
        "RailsAdmin::Engine" => { category: :admin, description: "Rails Admin dashboard" },
        "Administrate::Engine" => { category: :admin, description: "Thoughtbot Administrate dashboard" },
        "Avo::Engine" => { category: :admin, description: "Avo admin panel" },
        "Madmin::Engine" => { category: :admin, description: "Madmin admin interface" },
        "Flipper::UI" => { category: :feature_flags, description: "Flipper feature flag dashboard" },
        "Flipper::Api" => { category: :feature_flags, description: "Flipper feature flag API" },
        "PgHero::Engine" => { category: :monitoring, description: "PgHero PostgreSQL performance dashboard" },
        "Blazer::Engine" => { category: :monitoring, description: "Blazer SQL query dashboard" },
        "Coverband::Engine" => { category: :monitoring, description: "Coverband code coverage in production" },
        "Rswag::Api::Engine" => { category: :api_docs, description: "Rswag API documentation (Swagger)" },
        "Rswag::Ui::Engine" => { category: :api_docs, description: "Rswag Swagger UI" },
        "GraphiQL::Rails::Engine" => { category: :api_docs, description: "GraphiQL in-browser IDE for GraphQL" },
        "Lookbook::Engine" => { category: :ui, description: "Lookbook ViewComponent previews" },
        "LetterOpenerWeb::Engine" => { category: :dev_tools, description: "Letter Opener Web email preview" },
        "ActionCable.server" => { category: :realtime, description: "Action Cable WebSocket server" },
        "Devise::Engine" => { category: :auth, description: "Devise authentication engine" },
        "Doorkeeper::Engine" => { category: :auth, description: "Doorkeeper OAuth 2 provider" },
        "ActionMailbox::Engine" => { category: :mail, description: "Action Mailbox inbound email processing" },
        "ActiveStorage::Engine" => { category: :storage, description: "Active Storage file uploads" }
      }.freeze

      # @return [Hash] mounted engines with paths and descriptions
      def call
        {
          mounted_engines: discover_mounted_engines,
          rails_engines: discover_rails_engines,
          in_repo_engines: discover_in_repo_engines
        }
      end

      # config/routes.rb is a file, so mounts read the same either way. Which
      # engine classes a process loaded is only knowable from that process -
      # and testing `defined?(Rails::Engine)` instead of the tier answered from
      # the half-finished boot that put us here, which is the common way into
      # the static tier.
      def static_call
        {
          mounted_engines: discover_mounted_engines,
          rails_engines: { unavailable: StaticTier.unavailable_reason },
          in_repo_engines: discover_in_repo_engines
        }
      end

      private

      # The app's own engines, plugins and modules: trees here with an app/ of their own.
      # Mounts name only what routes.rb reaches, and Rails::Engine.subclasses needs a boot.
      def discover_in_repo_engines
        root = app.root.to_s
        PathResolver.code_roots(root).map do |dir|
          # No model count here: only the models section knows which of an
          # engine's files are models, and Payload fills it in from there.
          { name: File.basename(dir), path: PortablePath.relativize(dir, root) }
        end
      end

      # What config/routes.rb and the files it draws mount, on both tiers,
      # through the route introspector's own walk: on the static tier the
      # routes section reads the same walk, and booted it reads the live
      # route table, which also holds what a gem mounts for itself.
      def discover_mounted_engines
        engines = []

        RouteIntrospector.new(app).static_mounts.each do |mount|
          engine_name = mount[:engine]
          info = { engine: engine_name, path: mount[:path] }
          known = KNOWN_ENGINES[engine_name]
          if known
            info[:category] = known[:category].to_s
            info[:description] = known[:description]
          end
          engines << info
        end

        engines.sort_by { |e| e[:engine] }
      end

      # App-relative, or the gem and version for a gem's engine; a root
      # anywhere else has no form that means anything on another machine.
      def portable_root(root)
        path = root.to_s
        return "." if path == app.root.to_s

        relative = PortablePath.relativize("#{path}/", app.root).chomp("/")
        relative unless relative.start_with?(File::SEPARATOR)
      end

      def discover_rails_engines
        return [] unless defined?(Rails::Engine)

        Rails::Engine.subclasses.filter_map do |engine|
          next if engine.name.nil?
          next if engine.name == "RailsAiContext::Engine"
          next if engine.name.start_with?("Rails::", "ActionPack::", "ActionView::", "ActiveModel::")

          entry = { name: engine.name, root: portable_root(engine.root) }
          # Count routes and models inside the engine
          if engine.respond_to?(:routes) && engine.routes.respond_to?(:routes)
            entry[:route_count] = engine.routes.routes.size rescue nil
          end
          if Dir.exist?(File.join(engine.root.to_s, "app", "models"))
            entry[:model_count] = ModelIntrospector.new(StaticApp.new(engine.root.to_s)).model_count
          end
          entry.compact
        rescue => e
          RailsAiContext.debug_fail(e, nil, label: "discover_rails_engines")
        end.sort_by { |e| e[:name] }
      rescue => e
        RailsAiContext.debug_fail(e, [], label: "discover_rails_engines")
      end
    end
  end
end
