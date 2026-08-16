# frozen_string_literal: true

require "digest"

module RailsAiContext
  # Computes a SHA256 fingerprint of key application files to detect changes.
  # Used by BaseTool to invalidate cached introspection when files change.
  class Fingerprinter
    WATCHED_FILES = %w[
      db/schema.rb
      db/structure.sql
      config/routes.rb
      config/database.yml
      Gemfile
      Gemfile.lock
      package.json
      tsconfig.json
    ].freeze

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
      config/initializers
      config/locales
      config/environments
      db/migrate
      lib/tasks
    ].freeze

    # The kinds whose homes PathResolver resolves beyond the conventional
    # tree - packs/*, engines/* and configured extras. Derived at compute
    # time so an edit in a pack invalidates the cache the way one in app/
    # does; a stale answer that looks fresh is the failure this exists to
    # prevent. WATCHED_DIRS stays a plain list because live_reload and the
    # watcher consume it as relative patterns.
    RESOLVED_KINDS = %w[
      app/models app/controllers app/views app/jobs app/mailers
      app/channels app/components app/helpers app/services
    ].freeze

    class << self
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
          Dir.glob(File.join(full_dir, "**/*.{rb,rake,js,ts,erb,haml,slim,yml}")).sort.each do |path|
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

      # Clear the memoized gem-lib fingerprint. Called by BaseTool.reset_cache!
      # and LiveReload so active gem development gets a fresh scan on next call
      # without requiring a process restart.
      def reset_gem_lib_fingerprint!
        @gem_lib_fingerprint = nil
      end

      private

      # Memoized gem-lib fingerprint. Computed ONCE per process lifetime
      # (or per reset_gem_lib_fingerprint! call) instead of on every
      # tool invocation.
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
        $stderr.puts "[rails-ai-context] local_gem_path? failed: #{e.message}" if ENV["DEBUG"]
        false
      end

      public

      def changed?(app, previous)
        compute(app) != previous
      end
    end
  end
end
