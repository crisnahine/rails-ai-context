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

        content = File.read(path)
        config = {}

        if (threads_match = content.match(/threads\s+(\d+)\s*,\s*(\d+)/))
          config[:threads_min] = threads_match[1].to_i
          config[:threads_max] = threads_match[2].to_i
        end

        if (workers_match = content.match(/workers\s+(\d+)/))
          config[:workers] = workers_match[1].to_i
        end

        if (port_match = content.match(/port\s+ENV.+?(\d+)/))
          config[:port] = port_match[1].to_i
        end

        config.empty? ? nil : config
      rescue => e
        $stderr.puts "[rails-ai-context] extract_puma_config failed: #{e.message}" if ENV["DEBUG"]
        nil
      end

      def extract_procfile
        %w[Procfile Procfile.dev].filter_map do |filename|
          path = File.join(root, filename)
          next unless File.exist?(path)

          entries = File.readlines(path).filter_map do |line|
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

        content = File.read(routes_path)
        return true if content.match?(/\b(?:health|up|ping|status)\b/)
        nil
      rescue => e
        $stderr.puts "[rails-ai-context] detect_health_check failed: #{e.message}" if ENV["DEBUG"]
        nil
      end

      def extract_docker_info
        dockerfile = File.join(root, "Dockerfile")
        return nil unless File.exist?(dockerfile)

        content = File.read(dockerfile)
        info = {}

        from_lines = content.scan(/^FROM\s+(.+)/)
        info[:base_images] = from_lines.flatten if from_lines.any?
        info[:multi_stage] = from_lines.size > 1

        compose = File.exist?(File.join(root, "docker-compose.yml"))
        info[:compose] = compose

        info
      rescue => e
        $stderr.puts "[rails-ai-context] extract_docker_info failed: #{e.message}" if ENV["DEBUG"]
        nil
      end

      def detect_deployment_tool
        return "kamal" if File.exist?(File.join(root, "config/deploy.yml"))
        return "capistrano" if File.exist?(File.join(root, "Capfile"))
        return "heroku" if File.exist?(File.join(root, "app.json")) || File.exist?(File.join(root, "Procfile"))
        nil
      end
    end
  end
end
