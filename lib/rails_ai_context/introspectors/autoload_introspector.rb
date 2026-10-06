# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    # Extracts the autoloading configuration: Zeitwerk vs Classic, custom
    # inflections, autoload/eager-load paths, collapsed dirs, and ignored
    # paths. Covers RAILS_NERVOUS_SYSTEM.md §3 (Autoloading - Zeitwerk).
    class AutoloadIntrospector < Base
      extend StaticTier
      static_tier :runtime_only

      INFLECTION_DIRECTIVES = %i[acronym plural singular irregular uncountable human].freeze

      # @return [Hash] autoloader configuration
      def call
        once = config_paths(:autoload_once_paths)
        eager = config_paths(:eager_load_paths)
        main_roots = loader_roots(:main)
        once_roots = loader_roots(:once)
        {
          mode: detect_mode,
          zeitwerk_available: zeitwerk_available?,
          autoloaders: extract_autoloaders,
          # Rails' Engine#_all_autoload_paths, plus loader roots no config lists (engines, push_dir).
          autoload_paths: relativize(config_paths(:autoload_paths) + eager - once + app_first(main_roots.keys)),
          autoload_once_paths: relativize(once + app_first(once_roots.keys)),
          autoload_namespaces: relativize_namespaces(main_roots.merge(once_roots)),
          eager_load_paths: relativize(eager),
          eager_load: !!app.config.eager_load,
          custom_inflections: extract_custom_inflections
        }
      end

      private

      # 7.1+ keeps config.paths entries (app/models, ...) out of
      # config.autoload_paths and adds them in config.all_autoload_paths.
      def config_paths(name)
        config = app.config
        all = :"all_#{name}"
        Array(config.respond_to?(all) ? config.public_send(all) : config.public_send(name)).map(&:to_s)
      end

      def zeitwerk_available?
        defined?(Zeitwerk) && defined?(Rails) && Rails.respond_to?(:autoloaders) && Rails.autoloaders.respond_to?(:main)
      end

      def detect_mode
        return "zeitwerk" if zeitwerk_available?
        return "classic" if defined?(Rails) && app.config.respond_to?(:autoloader) && app.config.autoloader == :classic
        "unknown"
      end

      # Return per-autoloader metadata: name, collapsed dirs, ignored paths.
      # Rails exposes `Rails.autoloaders.main` and `.once` by default.
      def extract_autoloaders
        return [] unless zeitwerk_available?

        %i[main once].filter_map do |kind|
          loader = Rails.autoloaders.public_send(kind) if Rails.autoloaders.respond_to?(kind)
          next unless loader

          entry = { name: kind.to_s }
          entry[:tag] = loader.tag.to_s if loader.respond_to?(:tag)
          entry[:collapsed] = relativize(extract_collapsed(loader))
          entry[:ignored]   = relativize(extract_ignored(loader))
          entry[:root_dirs] = relativize(root_dirs_with_namespaces(loader).keys)
          entry[:not_eager_loaded] = relativize(loader_set(loader, :@eager_load_exclusions))
          entry
        rescue => e
          RailsAiContext.debug_fail(e, { name: kind.to_s, error: e.message }, label: "extract autoloader #{kind}")
        end
      end

      def extract_collapsed(loader)
        collapsed = loader.instance_variable_get(:@collapse_dirs)
        return [] unless collapsed
        collapsed.respond_to?(:to_a) ? collapsed.to_a.map(&:to_s) : []
      rescue => e
        RailsAiContext.debug_fail(e, [], label: "extract_collapsed")
      end

      def extract_ignored(loader)
        ignored = loader.instance_variable_get(:@ignored_paths)
        return [] unless ignored
        ignored.respond_to?(:to_a) ? ignored.to_a.map(&:to_s) : []
      rescue => e
        RailsAiContext.debug_fail(e, [], label: "extract_ignored")
      end

      def loader_set(loader, ivar)
        set = loader.instance_variable_get(ivar) if loader.instance_variable_defined?(ivar)
        set.respond_to?(:to_a) ? set.to_a.map(&:to_s) : []
      end

      def loader_roots(kind)
        return {} unless zeitwerk_available? && Rails.autoloaders.respond_to?(kind)

        loader = Rails.autoloaders.public_send(kind)
        loader ? root_dirs_with_namespaces(loader) : {}
      end

      # { dir => namespace name }; Zeitwerk before 2.6 has no dirs(namespaces:), but its
      # @root_dirs is that hash, so the namespaces are read there before the bare dirs.
      def root_dirs_with_namespaces(loader)
        keyword = loader.respond_to?(:dirs) && loader.method(:dirs).parameters.any? { |_, name| name == :namespaces }
        roots =
          if keyword then loader.dirs(namespaces: true)
          else
            internal = loader.instance_variable_get(:@root_dirs) || loader.instance_variable_get(:@roots)
            internal.is_a?(Hash) || !loader.respond_to?(:dirs) ? internal : loader.dirs
          end
        roots = roots.to_h { |dir| [ dir, nil ] } if roots.is_a?(Array)
        return {} unless roots.respond_to?(:each_pair)

        roots.each_pair.to_h { |dir, namespace| [ dir.to_s, namespace.respond_to?(:name) ? namespace.name : namespace&.to_s ] }
      rescue => e
        RailsAiContext.debug_fail(e, {}, label: "root_dirs_with_namespaces")
      end

      def app_first(dirs)
        app_root = "#{root}#{File::SEPARATOR}"
        dirs.partition { |dir| dir.start_with?(app_root) }.flatten
      end

      def relativize_namespaces(roots)
        roots.each_with_object({}) do |(dir, namespace), named|
          next if namespace.nil? || namespace == "Object"

          path = relativize([ dir ]).first
          named[path] = namespace if path
        end
      end

      # Collect `inflect` blocks and `Zeitwerk::Inflector` customizations
      # declared in the app's initializers.
      def extract_custom_inflections
        inflections = []
        PathResolver.initializer_paths(root).each do |path|
          rel = path.sub("#{root}/", "")
          ast = SourceIntrospector.walk(path, {
            directives: -> { Listeners::ChainedCallListener.new(INFLECTION_DIRECTIVES, receiver: :inflect) },
            chained:    -> { Listeners::ChainedCallListener.new(:inflect) },
            bare:       -> { Listeners::GenericMacroListener.new(:inflect) }
          })

          # inflect "api" => "API", "xml" => "XML"
          (ast[:chained] + ast[:bare]).each do |hit|
            hit[:options].each { |k, v| inflections << { file: rel, rule: "#{k} => #{v}" } }
          end

          # inflect.acronym "API" / inflect.plural(/…/, "…") / inflect.irregular "…", "…"
          ast[:directives].each do |hit|
            inflections << { file: rel, rule: directive_rule(hit) }
          end
        end
        inflections.uniq
      rescue => e
        RailsAiContext.debug_fail(e, [], label: "extract_custom_inflections")
      end

      def directive_rule(hit)
        values = hit[:values].map(&:to_s)
        return "#{hit[:method]}: #{values.first} => #{values.last}" if values.size > 1
        "#{hit[:method]}: #{values.first}"
      end

      # Rails lists a path once per railtie that contributed it, and every
      # engine's paths sit under the machine's gem prefix rather than the app.
      # This gem's own directories are not the app's, and a path with no
      # portable form is left out rather than carried absolute.
      # This gem's own code is its app/ and lib/: a bundle installed under its
      # checkout (vendor/bundle on CI) holds other gems, which stay.
      def relativize(paths)
        own = own_code_dirs
        app_root = "#{root}#{File::SEPARATOR}"
        Array(paths).reject { |path| own.any? { |dir| path.to_s.start_with?(dir) } && !path.to_s.start_with?(app_root) }
                    .filter_map { |path| PortablePath.portable(path, root) }.uniq
      end

      def own_code_dirs
        return [] unless defined?(RailsAiContext::Engine)

        %w[app lib].map { |dir| "#{File.join(RailsAiContext::Engine.root.to_s, dir)}#{File::SEPARATOR}" }
      end
    end
  end
end
