# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    # Extracts route information from the Rails router including
    # HTTP verb, path, controller#action, and route constraints.
    class RouteIntrospector
      attr_reader :app

      def initialize(app)
        @app = app
      end

      # @return [Hash] routes grouped by controller
      def call
        routes = extract_routes
        root = routes.find { |r| r[:path] == "/" && r[:verb]&.include?("GET") }

        {
          total_routes: routes.size,
          by_controller: group_by_controller(routes),
          api_namespaces: detect_api_namespaces(routes),
          mounted_engines: detect_mounted_engines,
          root_route: root ? "#{root[:controller]}##{root[:action]}" : nil
        }
      rescue => e
        { error: e.message }
      end

      private

      def extract_routes
        # Force Rails to reload routes if routes.rb has changed
        app.routes_reloader&.execute_if_updated rescue nil

        app.routes.routes.filter_map do |route|
          # Journey::Route exposes the flag as a plain attribute reader
          # (`internal`), not a predicate - a respond_to?(:internal?) guard
          # never matches and would let Rails' info/mailers routes through.
          next if route.respond_to?(:internal) && route.internal
          next if route.defaults[:controller].blank?

          route_path = route.path.spec.to_s.gsub("(.:format)", "")
          action = route.defaults[:action]

          entry = {
            verb: route.verb.presence || "ANY",
            path: route_path,
            controller: route.defaults[:controller],
            action: action,
            name: route.name,
            constraints: extract_constraints(route)
          }

          params = route_path.scan(/:(\w+)/).flatten
          entry[:params] = params if params.any?

          entry[:restful] = %w[index show new create edit update destroy].include?(action)

          entry.compact
        end
      end

      def extract_constraints(route)
        constraints = route.constraints.to_s
        constraints.empty? ? nil : constraints
      rescue => e
        $stderr.puts "[rails-ai-context] extract_constraints failed: #{e.message}" if ENV["DEBUG"]
        nil
      end

      def group_by_controller(routes)
        routes.group_by { |r| r[:controller] }.transform_values do |controller_routes|
          controller_routes.map do |r|
            entry = { verb: r[:verb], path: r[:path], action: r[:action], name: r[:name] }
            entry[:params] = r[:params] if r[:params]
            entry[:restful] = r[:restful] unless r[:restful].nil?
            entry.compact
          end
        end
      end

      def detect_api_namespaces(routes)
        routes
          .select { |r| r[:path].match?(%r{/api/}) }
          .map { |r| r[:path].match(%r{(/api/v?\d*)})&.captures&.first }
          .compact
          .uniq
      end

      def detect_mounted_engines
        app.routes.routes
          .select { |r| r.app.respond_to?(:app) && r.app.app.is_a?(Class) }
          .filter_map do |r|
            engine_class = r.app.app
            next unless engine_class < Rails::Engine
            {
              engine: engine_class.name,
              path: r.path.spec.to_s
            }
          rescue => e
            $stderr.puts "[rails-ai-context] detect_mounted_engines failed: #{e.message}" if ENV["DEBUG"]
            nil
          end
      end
    end
  end
end
