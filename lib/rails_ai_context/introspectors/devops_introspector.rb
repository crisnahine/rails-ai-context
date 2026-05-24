# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    # Discovers DevOps configuration: Puma, Procfile, health checks,
    # Dockerfile, deployment tools.
    class DevOpsIntrospector
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

      def extract_puma_config
        path = File.join(root, "config/puma.rb")
        return nil unless File.exist?(path)

        # Walk AST directly for puma macro calls with integer/ENV arguments
        parse_result = AstCache.parse(path)
        config = {}
        extract_puma_calls(parse_result.value, config)

        config.empty? ? nil : config
      rescue => e
        $stderr.puts "[rails-ai-context] extract_puma_config failed: #{e.message}" if ENV["DEBUG"]
        nil
      end

      # Walk AST to find threads/workers/port calls and extract their arguments.
      def extract_puma_calls(node, config)
        case node
        when Prism::ProgramNode
          extract_puma_calls(node.statements, config)
        when Prism::StatementsNode
          node.body.each { |child| extract_puma_calls(child, config) }
        when Prism::CallNode
          if node.receiver.nil?
            args = node.arguments&.arguments || []
            case node.name
            when :threads
              ints = args.select { |a| a.is_a?(Prism::IntegerNode) }.map(&:value)
              if ints.size >= 2
                config[:threads_min] = ints[0]
                config[:threads_max] = ints[1]
              end
            when :workers
              int_arg = args.find { |a| a.is_a?(Prism::IntegerNode) }
              config[:workers] = int_arg.value if int_arg
            when :port
              # port is usually called with ENV.fetch("PORT", default_int)
              args.each do |arg|
                int_val = find_integer_in_node(arg)
                if int_val
                  config[:port] = int_val
                  break
                end
              end
            end
          end
        else
          # Recurse into child nodes for blocks, if-statements, etc.
          node.child_nodes.compact.each { |child| extract_puma_calls(child, config) }
        end
      end

      # Recursively search an AST node for an integer literal (handles ENV.fetch("X", 3000)).
      def find_integer_in_node(node)
        case node
        when Prism::IntegerNode then node.value
        when Prism::CallNode
          (node.arguments&.arguments || []).each do |arg|
            val = find_integer_in_node(arg)
            return val if val
          end
          nil
        else nil
        end
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
        $stderr.puts "[rails-ai-context] detect_health_check failed: #{e.message}" if ENV["DEBUG"]
        nil
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
        $stderr.puts "[rails-ai-context] extract_docker_info failed: #{e.message}" if ENV["DEBUG"]
        nil
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
