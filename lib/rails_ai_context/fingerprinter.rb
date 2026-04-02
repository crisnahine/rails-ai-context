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
      app/javascript/controllers
      app/middleware
      config/initializers
      db/migrate
      lib/tasks
    ].freeze

    class << self
      def compute(app)
        root = app.root.to_s
        digest = Digest::SHA256.new

        # Include the gem's own version so cache invalidates during gem development
        digest.update(RailsAiContext::VERSION)

        # Include gem lib directory mtime when using a local/path gem (development mode)
        gem_lib = File.expand_path("../../..", __FILE__)
        if gem_lib.start_with?(root) || (defined?(Bundler) && local_gem_path?)
          Dir.glob(File.join(gem_lib, "**/*.rb")).sort.each do |path|
            digest.update(File.mtime(path).to_f.to_s)
          end
        end

        WATCHED_FILES.each do |file|
          path = File.join(root, file)
          digest.update(File.mtime(path).to_f.to_s) if File.exist?(path)
        end

        WATCHED_DIRS.each do |dir|
          full_dir = File.join(root, dir)
          next unless Dir.exist?(full_dir)

          Dir.glob(File.join(full_dir, "**/*.{rb,rake,js,ts,erb,haml,slim,yml}")).sort.each do |path|
            digest.update(File.mtime(path).to_f.to_s)
          end
        end

        digest.hexdigest
      end

      private

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
