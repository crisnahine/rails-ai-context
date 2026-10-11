# frozen_string_literal: true

require "digest"
require "set"

module RailsAiContext
  # Computes a SHA256 fingerprint of key application files to detect changes.
  # Used by BaseTool to invalidate cached introspection when files change.
  class Fingerprinter
    # The root manifests.
    WATCHED_FILES = (%w[
      Gemfile
      Gemfile.lock
      gems.rb
      gems.locked
      package.json
      tsconfig.json
      config.ru
    ] + Introspectors::RakeTaskIntrospector::RAKEFILES).freeze

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
    WATCHED_EXTNAMES = %w[.rb .rake .js .ts .erb .haml .slim .yml .sql .tt].freeze
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

        WATCHED_FILES.each do |file|
          path = File.join(root, file)
          digest.update(File.mtime(path).to_f.to_s) if File.exist?(path)
        rescue Errno::ENOENT
          # File deleted between exist? check and mtime read - skip
        end

        prefix = SafePath.dir_prefix(root)
        # One run, so the resolvers and the link checks answer once per fingerprint.
        RunCache.around do
          watched_dirs(root).each do |full_dir|
            watched_files(full_dir, root).sort.each do |path|
              digest.update(cassette?(path, prefix) ? path : File.mtime(path).to_f.to_s)
            rescue Errno::ENOENT
              # File deleted between glob and mtime read - skip
            end
          end
        end

        digest.hexdigest
      end

      # Everything a change could hide in: the conventional dirs plus what
      # the resolvers add for this app (packs, engines, extra_app_paths,
      # concern homes such as app/serializers/concerns).
      def watched_dirs(root)
        dirs = scope_dirs(root)
        # A dir under another one is already globbed and watched through it.
        dirs.reject { |dir| dirs.any? { |other| dir.start_with?("#{other}/") } }
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

      # One walk with an extension filter: a brace glob walks the tree once per extension.
      # The glob lists a directory link and enters none, so a directory linked in
      # from the app's repository, which the readers walk (FileWalk), is globbed
      # on its own; only a name with no extension is asked whether it is one.
      def watched_files(dir, root, seen = Set.new)
        real_dir = File.realpath(dir)
        return [] unless seen.add?(real_dir)

        files = []
        linked = []
        Dir.glob(File.join(dir, "**/*")).each do |path|
          extname = File.extname(path)
          if WATCHED_EXTNAMES.include?(extname)
            files << path unless path.include?(BUILD_OUTPUT)
          elsif extname.empty? && File.symlink?(path) && File.directory?(path)
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
        Dir.glob(File.join(gem_lib, "**/*.rb")).sort.each do |path|
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
