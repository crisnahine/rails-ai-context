# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    # Discovers mounted Rails engines and Rack apps from config/routes.rb.
    # Identifies well-known engines and provides context about what each does.
    class EngineIntrospector # rubocop:disable Metrics/ClassLength
      attr_reader :app

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

      def initialize(app)
        @app = app
      end

      # @return [Hash] mounted engines with paths and descriptions
      def call
        {
          mounted_engines: discover_mounted_engines,
          rails_engines: discover_rails_engines
        }
      rescue => e
        { error: e.message }
      end

      private

      def root
        app.root.to_s
      end

      def discover_mounted_engines
        routes_path = File.join(root, "config/routes.rb")
        return [] unless File.exist?(routes_path)

        ast_data = SourceIntrospector.walk(routes_path, { mounts: -> { Listeners::MountListener.new } })
        engines = []

        ast_data[:mounts].each do |mount|
          engine_name = mount[:engine]
          path = mount[:path] || "unknown"
          info = { engine: engine_name, path: path }
          known = KNOWN_ENGINES[engine_name]
          if known
            info[:category] = known[:category].to_s
            info[:description] = known[:description]
          end
          engines << info
        end

        engines.sort_by { |e| e[:engine] }
      end

      def discover_rails_engines
        return [] unless defined?(Rails::Engine)

        Rails::Engine.subclasses.filter_map do |engine|
          next if engine.name.nil?
          next if engine.name == "RailsAiContext::Engine"
          next if engine.name.start_with?("Rails::", "ActionPack::", "ActionView::", "ActiveModel::")

          entry = { name: engine.name, root: engine.root.to_s.sub("#{Gem.dir}/gems/", "") }
          # Count routes and models inside the engine
          if engine.respond_to?(:routes) && engine.routes.respond_to?(:routes)
            entry[:route_count] = engine.routes.routes.size rescue nil
          end
          models_dir = File.join(engine.root.to_s, "app", "models")
          entry[:model_count] = Dir.glob(File.join(models_dir, "**/*.rb")).size if Dir.exist?(models_dir)
          entry.compact
        rescue => e
          $stderr.puts "[rails-ai-context] discover_rails_engines failed: #{e.message}" if ENV["DEBUG"]
          nil
        end.sort_by { |e| e[:name] }
      rescue => e
        $stderr.puts "[rails-ai-context] discover_rails_engines failed: #{e.message}" if ENV["DEBUG"]
        []
      end
    end
  end
end
