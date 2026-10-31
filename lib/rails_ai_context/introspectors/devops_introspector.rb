# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    # Discovers DevOps configuration: Puma, Procfile, health checks,
    # Dockerfile, deployment tools.
    class DevOpsIntrospector < Base
      extend StaticTier
      static_tier :files_only

      PROCFILES = %w[Procfile Procfile.dev].freeze
      COMPOSE_FILES = %w[docker-compose.yml docker-compose.yaml].freeze
      # The first one present names the deployment tool.
      DEPLOY_MARKERS = {
        "config/deploy.yml" => "kamal", "Capfile" => "capistrano", "app.json" => "heroku", "fly.toml" => "fly.io",
        "render.yaml" => "render", "render.yml" => "render", "railway.toml" => "railway", "railway.json" => "railway"
      }.freeze
      READS = (PROCFILES + COMPOSE_FILES + DEPLOY_MARKERS.keys).freeze

      def call
        {
          puma: extract_puma_config,
          procfile: extract_procfile,
          health_check: detect_health_check,
          docker: extract_docker_info,
          deployment: detect_deployment_tool
        }
      end

      private

      PUMA_SETTINGS = %i[threads workers port].freeze

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
      # A value computed from a literal (`Etc.nprocessors - 1`) is unknown.
      def puma_integer(arg)
        return arg if arg.is_a?(Integer)

        statements = AstCache.parse_string(arg.to_s).value.statements.body
        literal_integer(statements.first) if statements.size == 1
      end

      def literal_integer(node)
        case node
        when Prism::IntegerNode then node.value
        when Prism::StringNode then node.unescaped.to_i if node.unescaped.match?(/\A\d+\z/)
        when Prism::CallNode then passed_through_integer(node)
        when Prism::OrNode then literal_integer(node.right) if env_read?(node.left)
        when Prism::ParenthesesNode
          body = node.body
          literal_integer(body.body.first) if body.is_a?(Prism::StatementsNode) && body.body.size == 1
        end
      end

      def env_read?(node)
        node.is_a?(Prism::CallNode) && node.name == :[] && EnvReferences.env_constant?(node.receiver)
      end

      # `ENV.fetch`'s default, positional or from a block, and `.to_i` or `Integer()` around a literal.
      def passed_through_integer(node)
        args = node.arguments&.arguments || []
        case node.name
        when :to_i then literal_integer(node.receiver) if args.empty?
        when :Integer then literal_integer(args.first) if node.receiver.nil? && args.size == 1
        when :fetch then literal_integer(EnvReferences.fetch_default(node))
        end
      end

      def extract_procfile
        PROCFILES.filter_map do |filename|
          path = File.join(root, filename)
          next unless File.exist?(path)

          # A command leaves the app as source does, through Redaction: `rails ai:context` writes
          # it into .ai-context.json, which is committed (`--requirepass ...`, `DB_PASSWORD=...`).
          entries = (RailsAiContext::SafeFile.read(path) || "").lines.filter_map do |line|
            line.strip!
            next if line.empty? || line.start_with?("#")
            parts = line.split(":", 2)
            { name: parts[0].strip, command: RailsAiContext::Redaction.redact_source_line(parts[1].strip, path: filename) } if parts.size == 2
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
        return true if RubySource.without_comments(content).match?(%r{["']/?(?:up|health|ping|status|healthz|alive|liveness|readiness)["']})
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

        info[:compose] = COMPOSE_FILES.any? { |file| File.exist?(File.join(root, file)) }

        info
      rescue => e
        RailsAiContext.debug_fail(e, nil, label: "extract_docker_info")
      end

      def detect_deployment_tool
        DEPLOY_MARKERS.find { |file, _tool| File.exist?(File.join(root, file)) }&.last
      end
    end
  end
end
