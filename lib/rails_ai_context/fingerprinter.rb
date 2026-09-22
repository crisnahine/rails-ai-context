# frozen_string_literal: true

require "digest"

module RailsAiContext
  # Computes a SHA256 fingerprint of key application files to detect changes.
  # Used by BaseTool to invalidate cached introspection when files change.
  class Fingerprinter
    # The root manifests, plus the one file under a watched directory whose
    # extension WATCHED_EXTENSIONS does not name.
    WATCHED_FILES = %w[
      db/structure.sql
      Gemfile
      Gemfile.lock
      package.json
      tsconfig.json
    ].freeze

    # The one scope: everything the fingerprint walks is also everything the
    # watcher watches.
    WATCHED_DIRS = %w[
      app/models
      app/controllers
      app/views
      app/jobs
      app/mailers
      app/channels
      app/components
      app/helpers
      app/services
      app/javascript/controllers
      app/middleware
      config
      db
      lib/tasks
    ].freeze

    # The kinds whose homes PathResolver resolves beyond the conventional
    # tree - packs/*, engines/* and configured extras. Derived at compute
    # time so an edit in a pack invalidates the cache the way one in app/
    # does; a stale answer that looks fresh is the failure this exists to
    # prevent.
    RESOLVED_KINDS = %w[
      app/models app/controllers app/views app/jobs app/mailers
      app/channels app/components app/helpers app/services
    ].freeze

    # The file kinds a change can hide in. One list, so a walk that reports
    # a change and a walk that names it read the same tree.
    WATCHED_EXTENSIONS = "**/*.{rb,rake,js,ts,erb,haml,slim,yml}"

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

        watched_dirs(root).each do |full_dir|
          Dir.glob(File.join(full_dir, WATCHED_EXTENSIONS)).sort.each do |path|
            digest.update(File.mtime(path).to_f.to_s)
          rescue Errno::ENOENT
            # File deleted between glob and mtime read - skip
          end
        end

        digest.hexdigest
      end

      # Everything a change could hide in: the conventional dirs plus what
      # the resolvers add for this app (packs, engines, extra_app_paths,
      # concern homes such as app/serializers/concerns).
      def watched_dirs(root)
        conventional = WATCHED_DIRS.map { |dir| File.join(root, dir) }
        resolved = RESOLVED_KINDS.flat_map { |kind| PathResolver.dirs_for(root, kind) }

        (conventional + resolved + ConcernPaths.resolve(root)).uniq.select { |dir| Dir.exist?(dir) }
      end

      # The manifests, absolute and existing. Most sit at the app root, which
      # no watcher can follow - Listen recurses with no opt-out, so watching
      # the root would walk node_modules - so these are fingerprinted only.
      def watched_files(root)
        WATCHED_FILES.map { |file| File.join(root, file) }.select { |path| File.exist?(path) }
      end

      # Which watched directories hold a file newer than the given time,
      # named the way an app author would write them.
      def changed_since(root, time)
        base = File.expand_path(root.to_s)
        watched_dirs(base).select { |dir|
          Dir.glob(File.join(dir, WATCHED_EXTENSIONS)).any? { |path| newer?(path, time) }
        }.map { |dir| dir.delete_prefix(base + File::SEPARATOR) }
      end

      private

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
