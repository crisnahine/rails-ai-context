# frozen_string_literal: true

require "concurrent"
require "pathname"

module RailsAiContext
  # Resolves where a kind of Rails app code can live for a given app root.
  # Conventional layout, packs, in-repo code roots, then extra_app_paths. Only
  # existing directories come back, so callers glob without their own guards.
  module PathResolver
    # An app/ holding one of these is a Rails tree rather than a coincidence.
    RAILS_APP_DIRS = %w[
      models controllers views helpers jobs mailers channels
      serializers services workers components javascript
    ].freeze

    # The app's own tree, dependency output, and where dummy apps live.
    SKIP_DIRS = %w[
      app lib config db bin script spec test tmp log public
      vendor node_modules coverage doc docs storage
    ].freeze

    # gems/plugins/<name> is the deepest real case; the bound keeps a monorepo cheap to scan.
    MAX_ROOT_DEPTH = 3

    CODE_ROOTS = Concurrent::Map.new
    DECLARED_ROOTS = Concurrent::Map.new
    APP_ROOTS = Concurrent::Map.new
    PATH_GEM_LIBS = Concurrent::Map.new
    NAMESPACED_ROOTS = Concurrent::Map.new

    module_function

    def model_dirs(root) = dirs_for(root, "app/models")

    def controller_dirs(root) = dirs_for(root, "app/controllers")

    # Rails searches config.paths["app/views"] in order, so a root the app
    # unshifts wins over app/views even when it is nested inside it.
    def view_dirs(root)
      prepended, appended = declared(root)[:views].partition { |direction, _dir| direction == :prepend }
      spelled = ->(list) { list.map { |_direction, dir| File.join(root.to_s, dir) } }
      engines = RunCache.fetch([ :engine_view_dirs, root.to_s ]) do
        enclosing_engine_roots(root).map { |engine| File.join(engine, "app/views") }.select { |dir| Dir.exist?(dir) }
      end
      (spelled.(prepended) + dirs_for(root, "app/views") + spelled.(appended) + engines).uniq.freeze
    end

    # Every initializer Rails loads: railties globs config/initializers with **/*.rb, in path order.
    # A symlink that resolves outside the app root, or nowhere, is left out.
    def initializer_paths(root)
      real_root = File.realpath(root.to_s)
      Dir.glob(File.join(root.to_s, "config", "initializers", "**", "*.rb")).sort.select do |path|
        SafePath.contained?(File.realpath(path), real_root)
      rescue SystemCallError
        false
      end
    rescue SystemCallError
      []
    end

    # The initializers an app spells for `name`, however it spells them: a
    # load-order prefix (`009-omniauth.rb`), a hyphen where the gem uses an
    # underscore (`rack-attack.rb`), or a compound name (`custom_devise.rb`).
    def initializer_files(root, name)
      target = normalize_initializer_name(name)
      initializer_paths(root).select do |path|
        base = normalize_initializer_name(File.basename(path, ".rb"))
        base == target || base.end_with?("_#{target}")
      end
    end

    # The same list app-relative, which is the spelling every answer prints.
    def app_initializer_files(root, name)
      initializer_files(root, name).map { |path| path.sub("#{root}/", "") }
    end

    def normalize_initializer_name(name)
      name.to_s.sub(/\.rb\z/, "").tr("-", "_").sub(/\A\d+_/, "")
    end

    # Every directory Rails autoloads from: each app/* directory, the concerns
    # inside them (railties globs `{*,*/concerns}`), lib, and what it declares.
    def autoload_roots(root)
      app_roots(root) +
        ConcernPaths.resolve(root) +
        dirs_for(root, "lib") +
        declared_roots(root)
    rescue StandardError => e
      RailsAiContext.debug_fail(e, [], label: "PathResolver.autoload_roots")
    end

    def app_roots(root)
      APP_ROOTS.compute_if_absent(File.expand_path(root.to_s)) do
        dirs_for(root, "app").flat_map { |tree| Dir.glob(File.join(tree, "*")).select { |dir| File.directory?(dir) }.sort }.freeze
      end
    end

    # app/* directories Rails generates for code that is not a model.
    NON_MODEL_APP_DIRS = %w[
      assets javascript views controllers helpers mailers mailboxes jobs channels models
      components serializers policies decorators presenters workers graphql uploaders validators
    ].freeze

    # The autoload roots besides the model directories that can hold a model:
    # every other app/* root and the roots config/application.rb adds.
    def extra_model_roots(root)
      models = model_dirs(root).map { |dir| root_key(dir) }
      candidates = app_roots(root).reject { |dir| NON_MODEL_APP_DIRS.include?(File.basename(dir)) } + declared_roots(root)
      candidates.reject { |dir| models.any? { |model_dir| SafePath.contained?(model_dir, root_key(dir)) } }
                .uniq { |dir| root_key(dir) }
    end

    # Only path gems inside the repo (`path "../gems" do` locks as `remote: gems`);
    # one outside is an installed gem as far as the app's source goes.
    def path_gem_libs(root)
      key = File.expand_path(root.to_s)
      PATH_GEM_LIBS.compute_if_absent(key) { read_path_gem_libs(key) }
    end

    # Remotes are relative to the lockfile, which for a test/dummy is the engine's.
    def read_path_gem_libs(root)
      bundle = GemLock.bundle(root)
      lock = bundle.lockfile && SafeFile.read(bundle.lockfile)
      return [] unless lock

      trusted = File.realpath(bundle.trusted)
      remotes = lock.scan(/^PATH\r?\n  remote: (.+?)\r?$/).flatten.map(&:strip)
      remotes.flat_map do |remote|
        base = File.expand_path(remote, bundle.dir)
        next [] unless Dir.exist?(base) && SafePath.contained?(File.realpath(base), trusted)

        # Bundler's own glob for the gemspecs a path source holds.
        Dir.glob(File.join(base, "{,*,*/*}.gemspec")).map { |spec| File.join(File.dirname(spec), "lib") }
      end.uniq.select { |dir| Dir.exist?(dir) }.sort
    rescue StandardError => e
      RailsAiContext.debug_fail(e, [], label: "PathResolver.path_gem_libs")
    end
    private_class_method :read_path_gem_libs

    # The roots config/application.rb adds by hand, such as lib_static.
    def declared_roots(root)
      key = File.expand_path(root.to_s)
      declared(key)[:autoload].map { |relative| File.join(key, relative) }
    end

    # The lib subdirectories `autoload_lib(ignore:)` keeps out of autoloading.
    def ignored_dirs(root)
      key = File.expand_path(root.to_s)
      declared(key)[:ignored].map { |relative| File.join(key, relative) }
    end

    # One walk of config/application.rb for the autoload, ignored and view
    # roots it adds, app-relative and kept only when they exist inside the app.
    def declared(root)
      key = File.expand_path(root.to_s)
      DECLARED_ROOTS.compute_if_absent(key) { read_declared(key) }
    end

    NONE_DECLARED = { autoload: [].freeze, ignored: [].freeze, views: [].freeze }.freeze

    def read_declared(root)
      path = File.join(root, "config", "application.rb")
      return NONE_DECLARED unless File.file?(path)

      found = Introspectors::SourceIntrospector.walk(
        path, { autoload: Introspectors::Listeners::AutoloadPathsListener,
                ignored: Introspectors::Listeners::AutoloadIgnoreListener,
                views: Introspectors::Listeners::ViewPathsListener }
      )
      real_root = File.realpath(root)
      inside = ->(relative) { contained_dir?(File.join(root, relative), real_root) }
      {
        autoload: found[:autoload].uniq.select(&inside).freeze,
        ignored: found[:ignored].uniq.select(&inside).freeze,
        views: found[:views].uniq.select { |_direction, relative| inside.(relative) }.freeze
      }.freeze
    rescue StandardError => e
      RailsAiContext.debug_fail(e, NONE_DECLARED, label: "PathResolver.declared_roots")
    end

    # A declared root is still a path the file wrote: `#{config.root}/../shared`
    # names a tree the app does not own.
    def contained_dir?(dir, real_root)
      Dir.exist?(dir) && SafePath.contained?(File.realpath(dir), real_root)
    rescue SystemCallError
      false
    end

    # `roots:` takes pre-resolved roots, so a caller with many constants resolves once.
    def file_for_constant(root, name, roots: nil)
      relative = name.to_s.underscore
      return nil if relative.empty? || relative.include?("..")

      (roots || autoload_roots(root)).lazy
        .map { |dir| File.join(dir, "#{relative}.rb") }.find { |path| File.file?(path) } ||
        namespaced_file(root, name.to_s)
    end

    def namespaced_file(root, name)
      namespaced_roots(root).each do |dir, namespace|
        next unless name.start_with?("#{namespace}::")

        path = File.join(dir, "#{name.delete_prefix("#{namespace}::").underscore}.rb")
        return path if File.file?(path)
      end
      nil
    end
    private_class_method :namespaced_file

    # [dir, namespace] for each `push_dir(..., namespace: X)` in config/application.rb
    # or an initializer. Only files that say push_dir are parsed.
    def namespaced_roots(root)
      key = File.expand_path(root.to_s)
      NAMESPACED_ROOTS.compute_if_absent(key) { read_namespaced_roots(key) }
    end

    def read_namespaced_roots(root)
      real_root = File.realpath(root)
      files = [ "config/application.rb", *Dir.glob("config/initializers/**/*.rb", base: root).sort ]
      sources = files.filter_map { |relative| SafePath.read(relative, under: root).first }.select { |source| source.include?("push_dir") }
      sources.flat_map do |source|
        Introspectors::SourceIntrospector.walk_source(source, { roots: Introspectors::Listeners::NamespacedRootsListener })[:roots]
      end.uniq.filter_map do |relative, namespace|
        dir = File.join(root, relative)
        [ dir, namespace ] if contained_dir?(dir, real_root)
      end.freeze
    rescue StandardError => e
      RailsAiContext.debug_fail(e, [], label: "PathResolver.namespaced_roots")
    end
    private_class_method :read_namespaced_roots

    # The files a constant can be declared in, its own first, then each enclosing
    # namespace's (`CanonicalURL::Helpers` lives in `canonical_url.rb`).
    def namespace_files(root, name, roots: nil)
      roots ||= autoload_roots(root)
      parts = name.to_s.split("::")
      parts.size.downto(1).lazy.filter_map { |n| file_for_constant(root, parts.first(n).join("::"), roots: roots) }
    end

    # Kept for one run only: the answer lists directories that exist, so one
    # created later is seen next run. Keyed by real path, answered per spelling.
    def dirs_for(root, kind)
      root = root.to_s
      extra = Array(RailsAiContext.configuration.extra_app_paths).map(&:to_s)
      # The spelling is looked up first: the real path costs a syscall, and
      # this is asked thousands of times in a run.
      RunCache.fetch([ :dirs_for_spelled, root, kind, extra ]) do
        relative = RunCache.fetch([ :dirs_for, root_key(root), kind, extra ]) do
          resolve_dirs(root, kind).map { |dir| dir.start_with?("#{root}/") ? dir.delete_prefix("#{root}/") : dir }
        end
        relative.map { |dir| dir.start_with?(File::SEPARATOR) ? dir : File.join(root, dir) }.freeze
      end
    end

    # Booted from an engine's test/dummy, the engine whose root holds the app
    # root: its classes, views and tests are the project's own. Never this gem.
    def enclosing_engine_roots(root)
      return [] unless defined?(::Rails::Engine)

      RunCache.fetch([ :enclosing_engine_roots, root.to_s ]) do
        inside = "#{root_key(root.to_s)}#{File::SEPARATOR}"
        ::Rails::Engine.subclasses.filter_map do |engine|
          next if engine.root.nil? || (defined?(RailsAiContext::Engine) && engine.equal?(RailsAiContext::Engine))

          dir = engine.root.to_s
          dir if inside.start_with?("#{root_key(dir)}#{File::SEPARATOR}")
        rescue StandardError
          nil
        end
      end
    end

    # The root whose suite tests the app: an engine's test/dummy keeps none of its own.
    def test_root(root)
      root = root.to_s
      return root if %w[test spec].any? { |dir| Dir.exist?(File.join(root, dir)) }

      RunCache.fetch([ :test_root, root ]) { enclosing_engine_roots(root).first || bundle_engine_root(root) || root }
    end

    # Unbooted, the engine is the gemspec directory holding the bundle config/boot.rb
    # names, which GemLock only resolves inside the app's git repository.
    def bundle_engine_root(root)
      dir = GemLock.bundle(root).dir
      real_root = root_key(root)
      return nil if dir == root || !real_root.start_with?("#{dir}#{File::SEPARATOR}") || Dir.glob(File.join(dir, "*.gemspec")).empty?

      # In the root's own spelling, which every caller strips from the paths it prints.
      depth = real_root.delete_prefix("#{dir}#{File::SEPARATOR}").split(File::SEPARATOR).size
      depth.times.reduce(File.expand_path(root)) { |path, _| File.dirname(path) }
    end

    # A path under the suite root as the app root reads it: `../models/x_test.rb` from a test/dummy.
    def suite_relative(root, relative)
      suite = test_root(root)
      return relative if suite == root.to_s

      Pathname.new(File.join(root_key(suite), relative)).relative_path_from(Pathname.new(root_key(root))).to_s
    end

    # Inside the app root, or inside the engine its test/dummy runs in.
    def project_file?(path, root)
      real = File.realpath(path)
      dirs = RunCache.fetch([ :project_dirs, root.to_s ]) { [ root.to_s, *enclosing_engine_roots(root) ].map { |dir| root_key(dir) } }
      dirs.any? { |dir| SafePath.contained?(real, dir) }
    rescue SystemCallError
      false
    end

    def root_key(root)
      File.realpath(root)
    rescue SystemCallError
      File.expand_path(root)
    end

    # Relative to the root, for an answer that has to say where it looked.
    def search_patterns(root, kind)
      places(root, kind).map(&:first).uniq
    end

    def resolve_dirs(root, kind)
      places(root, kind).flat_map { |_shown, path, glob| glob ? Dir.glob(path).sort : [ path ] }
        .uniq.select { |dir| Dir.exist?(dir) }.freeze
    end
    private_class_method :resolve_dirs

    # The one list of places a kind can live: what an answer says it searched,
    # the path read, and whether that path is a glob.
    def places(root, kind)
      root = root.to_s
      expanded = File.expand_path(root)
      places = [
        [ kind, File.join(root, kind), false ],
        [ "packs/*/#{kind}", File.join(root, "packs", "*", kind), true ],
        [ "engines/*/#{kind}", File.join(root, "engines", "*", kind), true ]
      ]
      places += code_roots(root).map { |dir| [ File.join(dir.delete_prefix("#{expanded}/"), kind), File.join(dir, kind), false ] }
      Array(RailsAiContext.configuration.extra_app_paths).each do |extra|
        places << [ File.join(extra, kind), File.join(root, extra, kind), false ]
        # `custom/app` is the natural way to write an entry whose tree is
        # custom/app/models; appending the full kind would look in
        # custom/app/app/models and silently miss. Accept both spellings.
        if extra.to_s.chomp("/").end_with?("/app") || extra.to_s.chomp("/") == "app"
          short = kind.delete_prefix("app/")
          places << [ File.join(extra, short), File.join(root, extra, short), false ]
        end
      end
      places
    end
    private_class_method :places

    # Read from the layout: plugins that are not gems, or modules a Gemfile globs
    # at load time, are not in the Gemfile to find.
    def code_roots(root)
      root = File.expand_path(root.to_s)
      CODE_ROOTS.compute_if_absent(root) { discover_code_roots(root) }
    end

    def clear_code_roots
      CODE_ROOTS.clear
      DECLARED_ROOTS.clear
      APP_ROOTS.clear
      PATH_GEM_LIBS.clear
      NAMESPACED_ROOTS.clear
    end

    def discover_code_roots(root)
      found = []
      queue = [ [ root, 0 ] ]
      until queue.empty?
        dir, depth = queue.shift
        children(dir).each do |name|
          next if name.start_with?(".") || SKIP_DIRS.include?(name)

          path = File.join(dir, name)
          next unless File.directory?(path) && !File.symlink?(path)

          if code_root?(path)
            found << path
          elsif depth + 1 < MAX_ROOT_DEPTH
            queue << [ path, depth + 1 ]
          end
        end
      end
      found.sort
    end
    private_class_method :discover_code_roots

    # A Rails-shaped app/ plus something that says Ruby loads it: without the
    # second half an Ember tree reads as a Rails engine.
    def code_root?(path)
      app = File.join(path, "app")
      return false unless Dir.exist?(app)
      return false if (children(app) & RAILS_APP_DIRS).empty?

      ruby_root?(path)
    end
    private_class_method :code_root?

    def ruby_root?(path)
      Dir.glob(File.join(path, "{*.gemspec,plugin.rb}")).any? ||
        Dir.glob(File.join(path, "lib", "**", "engine.rb")).any?
    end
    private_class_method :ruby_root?

    # In-repo gems, engines and plugins that carry config/locales, app/ or not:
    # a Discourse plugin loads its locales without one.
    def locale_roots(root)
      root = File.expand_path(root.to_s)
      depths = (1..MAX_ROOT_DEPTH).map { |depth| Array.new(depth, "*").join("/") }.join(",")
      Dir.glob(File.join(root, "{#{depths}}", "config", "locales")).map { |dir| File.dirname(dir, 2) }
        .reject { |dir| dir.delete_prefix("#{root}/").split("/").intersect?(SKIP_DIRS) }
        .select { |dir| ruby_root?(dir) }.sort
    end

    # A directory's entries, or none for one that cannot be read.
    def children(dir)
      Dir.children(dir)
    rescue SystemCallError
      []
    end
  end
end
