# frozen_string_literal: true

require "digest"
require "set"

module RailsAiContext
  # Computes a SHA256 fingerprint of key application files to detect changes.
  # Used by BaseTool to invalidate cached introspection when files change.
  class Fingerprinter
    # One scope for fingerprint and watcher; app/, test/ and spec/ whole since readers scan any file there.
    WATCHED_DIRS = (%w[
      app/models
      app/controllers
      app/views
      app/mailers
      app/channels
      app/components
      app/helpers
      app/javascript/controllers
      app/middleware
      config
      db
      lib
      rakelib
    ] + Introspectors::ServiceClasses::ROOTS + Introspectors::JobIntrospector::JOB_DIRS + Introspectors::GrapeEndpoints::DIRS +
      %w[app test spec]).freeze

    # The files outside WATCHED_DIRS a reader opens or checks for, as globs
    # from the app root, each taken from the reader's own list. An entry that
    # names a folder stands for every file under it.
    WATCHED_FILES = (%w[Gemfile Gemfile.lock gems.rb gems.locked *.gemspec] + GemLock::VERSION_FILES +
      Introspectors::RakeTaskIntrospector::RAKEFILES +
      Introspectors::EnvReferences.root_globs.reject { |glob| WATCHED_DIRS.any? { |dir| glob.start_with?("#{dir}/") } } +
      Introspectors::EnvReferences::EXAMPLE_FILES + Introspectors::EnvReferences::CREDENTIALS_EXAMPLES +
      Introspectors::EnvReferences::DOCKERFILES + Introspectors::DevOpsIntrospector::PROCFILES +
      Introspectors::DevOpsIntrospector::COMPOSE_FILES + Introspectors::DevOpsIntrospector::DEPLOY_MARKERS.keys +
      Introspectors::TestIntrospector::CI_CONFIGS.values + Introspectors::ConventionIntrospector::CONFIG_FILES +
      Introspectors::FrontendFrameworkIntrospector::MANIFESTS).uniq.freeze

    # The kinds whose homes PathResolver resolves beyond the conventional
    # tree - packs/*, engines/* and configured extras. Derived at compute
    # time so an edit in a pack invalidates the cache the way one in app/
    # does; a stale answer that looks fresh is the failure this exists to
    # prevent.
    RESOLVED_KINDS = (%w[
      app/models app/controllers app/views app/mailers
      app/channels app/components app/helpers
    ] + Introspectors::ServiceClasses::ROOTS + Introspectors::JobIntrospector::JOB_DIRS).freeze

    # The file kinds a change can hide in. One list, so a walk that reports
    # a change and a walk that names it read the same tree.
    # sql: a structure dump, under whatever name database.yml's schema_dump gives it.
    # tt: a generator template override under lib/templates.
    WATCHED_EXTNAMES = %w[.rb .rake .js .jsx .mjs .cjs .ts .tsx .vue .svelte .erb .haml .slim .jbuilder .builder .ruby .yml .yaml .sql .tt].freeze
    WATCHED_EXTENSIONS = "**/*{#{WATCHED_EXTNAMES.join(",")}}"

    # jsbundling and cssbundling rewrite this on every frontend save, and no reader reads it.
    BUILD_OUTPUT = "/app/assets/builds/"
    # A test run re-records these; the VCR reader counts them and never opens one.
    CASSETTES = %r{\A(?:spec|test)/(?:[^/]+/)*(?:vcr_)?cassettes/}

    # What a reader holds so it can ask later whether the app moved. Taken
    # before the read it protects: a mark taken after introspection records
    # edits the answer never saw.
    Mark = Data.define(:digest)

    class << self
      def mark(app)
        Mark.new(digest: compute(app))
      end

      def stale?(app, mark)
        compute(app) != mark.digest
      end

      def compute(app)
        root = app.root.to_s
        digest = Digest::SHA256.new

        # Include the gem's own version so cache invalidates during gem development
        digest.update(RailsAiContext::VERSION)

        # Include gem lib directory fingerprint when using a local/path gem.
        # MEMOIZED - the gem lib contents don't change within a single process
        # lifetime unless a developer is actively editing the gem source (rare
        # audience, they should restart the server to see changes). Previously
        # this walked 123 gem files on every tool call, adding ~12ms to the
        # cached_context hot path for path:-installed users.
        digest.update(gem_lib_fingerprint(root))

        # Each path with its mtime, so a rename that keeps both moves the digest.
        manifests(root).each do |file|
          digest.update(file)
          digest.update(File.mtime(File.expand_path(file, root)).to_f.to_s)
        rescue Errno::ENOENT
          # File deleted between glob and mtime read - skip
        end

        prefix = SafePath.dir_prefix(root)
        # One run, so the resolvers and the link checks answer once per fingerprint.
        RunCache.around do
          watched_dirs(root).each do |full_dir|
            watched_files(full_dir, root).sort.each do |path|
              digest.update(path)
              digest.update(File.mtime(path).to_f.to_s) unless cassette?(path, prefix)
            rescue Errno::ENOENT
              # File deleted between glob and mtime read - skip
            end
          end
        end

        digest.hexdigest
      end

      # The WATCHED_FILES that exist and the manifests in each frontend root, root-relative, then
      # the ones PackageJson reads outside the app (declared frontend_paths, the workspace root), absolute.
      def manifests(root)
        root = root.to_s
        prefix = SafePath.dir_prefix(root)
        names = Introspectors::FrontendFrameworkIntrospector::MANIFESTS
        inside = PackageJson.manifest_dirs(root).reject { |dir| dir == root }.flat_map do |dir|
          Dir.glob(names, base: dir).filter_map { |name| File.join(dir.delete_prefix(prefix), name) if File.file?(File.join(dir, name)) }
        end
        outside = (PackageJson.configured_outside(root) + [ PackageJson.workspace_root(root) ].compact).flat_map do |dir|
          Dir.glob(names, base: dir[:dir]).filter_map { |name| PackageJson.outside_file(dir[:dir], name)&.to_s }
        end
        (matching(root, WATCHED_FILES) + inside + outside).uniq
      end

      # The folders outside the scope dirs that hold a WATCHED_FILES file (bin,
      # .github/workflows), for a watcher; a frontend root is left out, since
      # Listen would recurse into its node_modules.
      def manifest_dirs(root)
        root = root.to_s
        scope = watched_dirs(root)
        matching(root, WATCHED_FILES).filter_map { |file| File.join(root, File.dirname(file)) unless File.dirname(file) == "." }.uniq
                                     .reject { |dir| scope.any? { |other| SafePath.contained?(dir, other) } }
      end

      # Everything a change could hide in: the conventional dirs plus what
      # the resolvers add for this app (packs, engines, extra_app_paths,
      # concern homes such as app/serializers/concerns).
      def watched_dirs(root)
        # A dir under another one is already globbed and watched through it.
        SafePath.outermost(scope_dirs(root))
      end

      def scope_dirs(root)
        conventional = WATCHED_DIRS.map { |dir| File.join(root, dir) }
        resolved = RESOLVED_KINDS.flat_map { |kind| PathResolver.dirs_for(root, kind) }

        (conventional + resolved + ConcernPaths.resolve(root) + stimulus_dirs(root)).uniq.select { |dir| Dir.exist?(dir) }
      end

      # The controller homes the Stimulus introspector reads, so an edit under
      # app/webpacker or frontend/ invalidates the cache like one in app/javascript.
      def stimulus_dirs(root)
        Introspectors::StimulusIntrospector.controller_paths(root.to_s)
                                           .map { |path, _js_root| File.dirname(path) }.uniq
      end

      # Which directories hold a file newer than the given time, each named by
      # the narrowest scope dir that holds it, the way an app author would write it.
      def changed_since(root, time)
        base = File.expand_path(root.to_s)
        RunCache.around do
          named = scope_dirs(base)
          prefix = SafePath.dir_prefix(base)
          watched_dirs(base).flat_map { |dir| watched_files(dir, base).select { |path| !cassette?(path, prefix) && newer?(path, time) } }
                            .map { |path| named.select { |dir| path.start_with?("#{dir}/") }.max_by(&:size) }
                            .uniq.map { |dir| dir.delete_prefix(prefix) }
        end
      end

      private

      # A folder counts only where an entry names it (`.github/workflows`), not where a
      # wildcard meant for files meets one (`bin/*`), and a linked folder is never entered
      # (tested without the trailing slash, which would follow the link).
      def matching(root, globs)
        globs.flat_map do |glob|
          Dir.glob(glob, base: root).flat_map do |hit|
            full = File.join(root, hit)
            next [ hit ] if File.file?(full)
            next [] if glob.end_with?("*") || File.symlink?(full.chomp("/")) || !File.directory?(full)

            Dir.glob("**/*", base: full).filter_map { |file| File.join(hit, file) if File.file?(File.join(full, file)) }
          end
        end.uniq
      end

      # One walk with an extension filter: a brace glob walks the tree once per extension.
      # The glob lists a directory link and enters none, so a directory linked in
      # from the app's repository, which the readers walk (FileWalk), is globbed
      # on its own, whatever its name (`shared.v2` too, as the readers take it).
      def watched_files(dir, root, seen = Set.new)
        real_dir = File.realpath(dir)
        return [] unless seen.add?(real_dir)

        files = []
        linked = []
        # Relative to the dir, so its path is never read as glob syntax.
        Dir.glob("**/*", base: dir).each do |relative|
          path = File.join(dir, relative)
          extname = File.extname(path)
          if WATCHED_EXTNAMES.include?(extname)
            files << path unless path.include?(BUILD_OUTPUT)
          elsif File.symlink?(path) && File.directory?(path)
            target = File.realpath(path)
            # A link into the tree globbed here leads where the glob went already.
            linked << path if !SafePath.contained?(target, real_dir) && PathResolver.enter_link?(target, real_dir, root)
          end
        rescue SystemCallError
          next
        end
        files + linked.flat_map { |path| watched_files(path, root, seen) }
      rescue SystemCallError
        []
      end

      def cassette?(path, prefix)
        path.delete_prefix(prefix).match?(CASSETTES)
      end

      def newer?(path, time)
        File.mtime(path) > time
      rescue Errno::ENOENT
        false
      end

      # Memoized gem-lib fingerprint. Sampled once per process: only a
      # developer editing the gem's own source sees it move, and a restart
      # shows that edit.
      def gem_lib_fingerprint(root)
        @gem_lib_fingerprint ||= compute_gem_lib_fingerprint(root)
      end

      def compute_gem_lib_fingerprint(root)
        gem_lib = File.expand_path("../../..", __FILE__)
        return "" unless gem_lib.start_with?(root) || (defined?(Bundler) && local_gem_path?)

        sub = Digest::SHA256.new
        PathResolver.glob(gem_lib, "**/*.rb").sort.each do |path|
          sub.update(File.mtime(path).to_f.to_s)
        rescue Errno::ENOENT
          # File deleted between glob and mtime read - skip
        end
        sub.hexdigest
      end

      # Detect if this gem is loaded via a local path (path: in Gemfile)
      def local_gem_path?
        spec = Bundler.rubygems.find_name("rails-ai-context").first
        return false unless spec
        spec.source.is_a?(Bundler::Source::Path)
      rescue => e
        RailsAiContext.debug_fail(e, false, label: "local_gem_path?")
      end
    end
  end
end
