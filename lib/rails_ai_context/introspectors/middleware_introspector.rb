# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    # Discovers custom Rack middleware in app/middleware/ and detects
    # middleware inserted via initializers.
    class MiddlewareIntrospector
      attr_reader :app

      def initialize(app)
        @app = app
      end

      # @return [Hash] custom middleware files and middleware stack analysis
      def call
        custom = discover_custom_middleware
        {
          custom_middleware: custom,
          middleware_stack: extract_middleware_stack,
          middleware_count: middleware_count(custom),
          middleware_from_initializers: detect_middleware_from_initializers
        }
      rescue => e
        { error: e.message }
      end

      private

      def root
        app.root.to_s
      end

      def discover_custom_middleware
        middleware_dir = File.join(root, "app/middleware")
        return [] unless Dir.exist?(middleware_dir)

        Dir.glob(File.join(middleware_dir, "**/*.rb")).sort.map do |path|
          content = RailsAiContext::SafeFile.read(path) or next
          class_name = File.basename(path, ".rb").camelize

          parse_result = AstCache.parse(path)
          has_call = false
          init_app = false

          queue = [ parse_result.value ]
          while (node = queue.shift)
            if node.is_a?(Prism::DefNode)
              has_call = true if node.name == :call
              if node.name == :initialize
                params = node.parameters
                init_app = params&.requireds&.any? { |p| p.is_a?(Prism::RequiredParameterNode) && p.name == :app } || false
              end
            end
            node.child_nodes.compact.each { |c| queue << c }
          end

          info = {
            file: path.sub("#{root}/", ""),
            class_name: class_name,
            has_call_method: has_call,
            initializes_app: init_app
          }

          patterns = []
          patterns << "authentication" if content.match?(/auth|token|session|jwt/i)
          patterns << "rate_limiting" if content.match?(/rate.?limit|throttl/i)
          patterns << "logging" if content.match?(/log|Logger/i)
          patterns << "cors" if content.match?(/cors|origin|Access-Control/i)
          patterns << "caching" if content.match?(/cache|Cache-Control|etag/i)
          patterns << "error_handling" if content.match?(/rescue|error|exception/i)
          patterns << "tenant" if content.match?(/tenant|subdomain|account/i)
          info[:detected_patterns] = patterns if patterns.any?

          info
        rescue => e
          { file: path.sub("#{root}/", ""), error: e.message }
        end
      end

      def extract_middleware_stack
        app.middleware.map do |middleware|
          name = middleware.name || middleware.klass.to_s
          { name: name, category: categorize_middleware(name) }
        end
      rescue => e
        $stderr.puts "[rails-ai-context] extract_middleware_stack failed: #{e.message}" if ENV["DEBUG"]
        []
      end

      def middleware_count(custom)
        {
          total: app.middleware.size,
          custom: custom.size
        }
      rescue => e
        $stderr.puts "[rails-ai-context] middleware_count failed: #{e.message}" if ENV["DEBUG"]
        {}
      end

      def detect_middleware_from_initializers
        init_dir = File.join(root, "config/initializers")
        return [] unless Dir.exist?(init_dir)

        additions = []
        Dir.glob(File.join(init_dir, "*.rb")).each do |path|
          ast_data = SourceIntrospector.walk(path, { middleware: Listeners::MiddlewareConfigListener })
          ast_data[:middleware].each do |m|
            additions << { middleware: m[:middleware], file: File.basename(path) }
          end
        end
        additions.uniq
      rescue => e
        $stderr.puts "[rails-ai-context] detect_middleware_from_initializers failed: #{e.message}" if ENV["DEBUG"]
        []
      end

      def categorize_middleware(name)
        case name
        when /ActionDispatch::SSL|ForceSSL/ then "security"
        when /Session|Cookie/ then "session"
        when /Cache|ETag|Conditional/ then "caching"
        when /Logger|RequestId/ then "logging"
        when /Static|Files/ then "static_files"
        when /Rack::Attack/ then "rate_limiting"
        when /Cors|CORS/ then "cors"
        when /Executor|Reloader/ then "rails_internal"
        when /ActionDispatch/ then "request_handling"
        when /ActiveRecord/ then "database"
        else "other"
        end
      end
    end
  end
end
