# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    # Discovers custom Rack middleware in app/middleware/ and detects
    # middleware inserted via initializers.
    class MiddlewareIntrospector < Base
      extend StaticTier
      static_tier :alternate_source

      # Only the two file facts. The stack and the count come from
      # app.middleware, and answering them from a rescue reported an app
      # with no middleware at all rather than an app nobody could ask.
      def static_call
        inserted = detect_middleware_from_initializers
        {
          custom_middleware: discover_custom_middleware(inserted),
          middleware_from_initializers: inserted,
          exceptions_app: exceptions_app,
          rackup: rackup.presence,
          unavailable_sections: %w[middleware_stack middleware_count]
        }.compact
      rescue StandardError
        { unavailable: StaticTier.unavailable_reason }
      end

      # @return [Hash] custom middleware files and middleware stack analysis
      def call
        inserted = detect_middleware_from_initializers
        custom = discover_custom_middleware(inserted)
        {
          custom_middleware: custom,
          middleware_stack: extract_middleware_stack,
          middleware_count: middleware_count(custom),
          middleware_from_initializers: inserted,
          exceptions_app: exceptions_app,
          rackup: rackup.presence
        }.compact
      end

      private

      MIDDLEWARE_DIRS = %w[app/middleware lib/middleware].freeze

      def discover_custom_middleware(inserted)
        exceptions_class = @exceptions_app_name
        from_dirs = MIDDLEWARE_DIRS.flat_map { |dir| middleware_files(File.join(root, dir)) }
                                   .reject { |entry| entry[:class_name] == exceptions_class }
        from_dirs + inserted_middleware_files(inserted, from_dirs)
      end

      # An app keeps its middleware wherever it likes: the insertions name the
      # classes, and the app owns one its autoload roots or its config declare.
      def inserted_middleware_files(inserted, already)
        seen = already.map { |entry| entry[:class_name] }
        inserted.filter_map do |entry|
          next if entry[:action] == "delete" || seen.include?(entry[:middleware])

          autoloaded = PathResolver.file_for_constant(root, entry[:middleware])
          path = autoloaded || @declared_in_config&.dig(entry[:middleware])
          next unless path

          described = describe_middleware(path, entry[:middleware])
          # A config file that reopens a gem's class (`class Rack::Attack` adding throttles)
          # declares it without implementing the middleware.
          next if autoloaded.nil? && !described&.dig(:has_call_method)

          seen << entry[:middleware]
          described
        end
      end

      def owned_file(name)
        PathResolver.file_for_constant(root, name) || @declared_in_config&.dig(name)
      end

      # The class `config.exceptions_app` names, which renders errors rather
      # than wrapping requests.
      def exceptions_app
        return nil unless @exceptions_app_name

        path = owned_file(@exceptions_app_name)
        { class_name: @exceptions_app_name, file: path&.sub("#{root}/", "") }.compact
      end

      def middleware_files(middleware_dir)
        return [] unless Dir.exist?(middleware_dir)

        Dir.glob(File.join(middleware_dir, "**/*.rb")).sort.filter_map { |path| describe_middleware(path) }
      end

      # The name comes from the declaration: a class under lib/middleware may
      # be `Middleware::RequestTracker` or a bare `RequestTracker`.
      def describe_middleware(path, name = nil)
        content = RailsAiContext::SafeFile.read(path) or return nil
        own_name = (name || File.basename(path, ".rb").camelize).split("::").last
        class_name = name || declared_name(content, own_name)

        methods = SourceIntrospector.walk(path, {
          methods: -> { Listeners::MethodsListener.new(include_initialize: true) }
        })[:methods]
        # A helper class nested in or beside the middleware is its own owner; the file's
        # name picks the middleware.
        owner = methods.map { |m| ActionResolver.owner_name(m) }
                       .find { |name| name.split("::").last == own_name }
        own = ActionResolver.own_methods(methods, owner || ActionResolver.default_owner(content, methods))

        info = {
          file: path.sub("#{root}/", ""),
          class_name: class_name,
          has_call_method: own.any? { |m| m[:name] == "call" },
          initializes_app: own.any? { |m|
            m[:name] == "initialize" && m[:params].any? { |p| p[:type] == :required && p[:name] == "app" }
          }
        }

        # Vocabulary matching, not structure: what a middleware body talks
        # about is the signal, and no AST node carries that. Regex stays.
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

      def declared_name(content, own_name)
        DeclaredConstant.declared_names(content).find { |declared| declared.split("::").last.casecmp?(own_name) } || own_name
      end

      # config.ru's own `use` and `map` run before Rails.application, so
      # app.middleware never lists them. Calls inside a `map` block belong to that mount.
      def rackup
        path = File.join(root, "config.ru")
        return [] unless File.file?(path)

        SourceIntrospector.walk(path, { calls: -> { Listeners::GenericMacroListener.new(:use, :map) } })[:calls].filter_map do |call|
          target = call[:values].first
          next if call[:parent_offset] || !target.is_a?(String)

          { call: call[:macro].to_s, target: target, line: call[:location] }
        end
      end

      def extract_middleware_stack
        app.middleware.map do |middleware|
          name = middleware.name || middleware.klass.to_s
          { name: name, category: categorize_middleware(name) }
        end
      rescue => e
        RailsAiContext.debug_fail(e, [], label: "extract_middleware_stack")
      end

      def middleware_count(custom)
        {
          total: app.middleware.size,
          custom: custom.size
        }
      rescue => e
        RailsAiContext.debug_fail(e, {}, label: "middleware_count")
      end

      # config/application.rb and the environment files change the stack as
      # often as an initializer does.
      def middleware_config_files
        PathResolver.initializer_paths(root) +
          Dir.glob(File.join(root, "config/environments/*.rb")).sort +
          [ File.join(root, "config/application.rb") ].select { |path| File.file?(path) }
      end

      def app_class
        return @app_class if defined?(@app_class)

        @app_class = AppKind.application_class(root)
      end

      # One walk per config file: the stack changes it makes, and the classes
      # it declares, which are the app's own wherever they are defined.
      def detect_middleware_from_initializers
        @declared_in_config = {}
        additions = middleware_config_files.flat_map do |path|
          walked = SourceIntrospector.walk(path, {
            middleware: -> { Listeners::MiddlewareConfigListener.new(app_class: app_class) },
            classes: Listeners::ClassDefinitionListener
          })
          Array(walked[:classes]).each { |klass| @declared_in_config[klass[:name]] ||= path }
          walked[:middleware].map { |m| { middleware: m[:middleware], action: m[:action], file: path.sub("#{root}/", "") } }
        end
        exceptions, stack = additions.uniq.partition { |entry| entry[:action] == "exceptions_app" }
        @exceptions_app_name = exceptions.last&.dig(:middleware)
        stack
      rescue => e
        RailsAiContext.debug_fail(e, [], label: "detect_middleware_from_initializers")
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
