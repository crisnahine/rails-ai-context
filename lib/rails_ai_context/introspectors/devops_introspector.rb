# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    # Discovers DevOps configuration: Puma, Procfile, health checks,
    # Dockerfile, deployment tools.
    class DevOpsIntrospector
      extend StaticTier
      static_tier :files_only

      attr_reader :app

      def initialize(app)
        @app = app
      end

      def call
        {
          puma: extract_puma_config,
          procfile: extract_procfile,
          health_check: detect_health_check,
          docker: extract_docker_info,
          deployment: detect_deployment_tool
        }
      rescue => e
        { error: e.message }
      end

      private

      def root
        app.root.to_s
      end

      PUMA_SETTINGS = %i[threads workers port].freeze

      # A number inside an ENV name is part of the name: the default in
      # `ENV.fetch("PORT_2", 3000)` is 3000, not 2.
      PUMA_INTEGER = /(?<!\w)\d+/

      def extract_puma_config
        path = File.join(root, "config/puma.rb")
        return nil unless File.exist?(path)

        config = {}
        puma_calls(path).each do |call|
          ints = call[:arguments].filter_map { |arg| puma_integer(arg) }
          case call[:name]
          when "threads" then config[:threads_min], config[:threads_max] = ints if ints.size >= 2
          when "workers" then config[:workers] = ints.first if ints.first
          when "port"    then config[:port] = ints.first if ints.first
          end
        end

        config.empty? ? nil : config
      rescue => e
        RailsAiContext.debug_fail(e, nil, label: "extract_puma_config")
      end

      # The puma macros are receiverless, so a `config.port` on some other
      # object is not one of them.
      #
      # Depth is deliberately not filtered. The generated puma.rb guards
      # `workers` behind an environment conditional, so a top-level-only
      # reader answers "no workers configured" for the most common config
      # there is. The cost is that a name set more than once reports the
      # last one, including one set inside `on_worker_boot`.
      def puma_calls(path)
        SourceIntrospector.walk(path, {
          puma: -> { Listeners::MethodCallListener.new(names: PUMA_SETTINGS) }
        })[:puma].reject { |call| call[:receiver] }
      end

      # An argument the listener could not read a literal from arrives as its
      # own source, which is where `ENV.fetch("PORT", 3000)` keeps its default.
      def puma_integer(arg)
        return arg if arg.is_a?(Integer)

        arg.to_s[PUMA_INTEGER]&.to_i
      end

      def extract_procfile
        %w[Procfile Procfile.dev].filter_map do |filename|
          path = File.join(root, filename)
          next unless File.exist?(path)

          entries = (RailsAiContext::SafeFile.read(path) || "").lines.filter_map do |line|
            line.strip!
            next if line.empty? || line.start_with?("#")
            parts = line.split(":", 2)
            { name: parts[0].strip, command: parts[1]&.strip } if parts.size == 2
          end

          { file: filename, entries: entries } if entries.any?
        end
      end

      def detect_health_check
        routes_path = File.join(root, "config/routes.rb")
        return nil unless File.exist?(routes_path)

        # Detect rails_health_check macro via AST
        ast_data = SourceIntrospector.walk(routes_path, {
          health: -> { Listeners::GenericMacroListener.new(:rails_health_check) }
        })
        return true if ast_data[:health].any?

        # Fall back to quoted route strings for custom health endpoints.
        # These are string arguments to route macros (get, match, etc.),
        # not bare method calls, so regex on content is appropriate.
        content = RailsAiContext::SafeFile.read(routes_path)
        return nil unless content
        return true if content.match?(%r{["']/?(?:up|health|ping|status|healthz|alive|liveness|readiness)["']})
        nil
      rescue => e
        RailsAiContext.debug_fail(e, nil, label: "detect_health_check")
      end

      def extract_docker_info
        dockerfile = File.join(root, "Dockerfile")
        return nil unless File.exist?(dockerfile)

        content = RailsAiContext::SafeFile.read(dockerfile)
        return nil unless content
        info = {}

        from_lines = content.scan(/^FROM\s+(.+)/)
        info[:base_images] = from_lines.flatten if from_lines.any?
        info[:multi_stage] = from_lines.size > 1

        compose = File.exist?(File.join(root, "docker-compose.yml")) || File.exist?(File.join(root, "docker-compose.yaml"))
        info[:compose] = compose

        info
      rescue => e
        RailsAiContext.debug_fail(e, nil, label: "extract_docker_info")
      end

      def detect_deployment_tool
        tools = []
        tools << "kamal" if File.exist?(File.join(root, "config/deploy.yml"))
        tools << "capistrano" if File.exist?(File.join(root, "Capfile"))
        tools << "heroku" if File.exist?(File.join(root, "app.json"))
        tools << "fly.io" if File.exist?(File.join(root, "fly.toml"))
        tools << "render" if File.exist?(File.join(root, "render.yaml")) || File.exist?(File.join(root, "render.yml"))
        tools << "railway" if File.exist?(File.join(root, "railway.toml")) || File.exist?(File.join(root, "railway.json"))
        tools.first # Return primary detected tool for backward compatibility
      end
    end
  end
end
