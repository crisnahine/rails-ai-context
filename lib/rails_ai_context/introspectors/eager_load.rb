# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    # Loads a kind of app code before reflection reads it, when the app
    # did not eager load. eager_load_dir stops at the first unloadable file
    # and raises for a directory another loader owns, so both fall back to
    # loading one constant at a time; a file that cannot load costs itself.
    module EagerLoad
      module_function

      def dir(root, kind:)
        return if Rails.application.config.eager_load

        PathResolver.dirs_for(root, kind).each do |path|
          load_dir(path)
        end
      rescue StandardError, ScriptError => e
        $stderr.puts "[rails-ai-context] eager load of #{kind} failed: #{e.message}" if ENV["DEBUG"]
        nil
      end

      # eager_load_dir returns silently for a directory the loader manages
      # but does not eager load, so the per-constant walk always follows: a
      # constant already loaded is a hash lookup, and one that is not gets
      # loaded here. A file that cannot load costs itself.
      def load_dir(path)
        loader = Rails.autoloaders.main
        loader.eager_load_dir(path) if loader.respond_to?(:eager_load_dir)
      rescue StandardError, ScriptError => e
        $stderr.puts "[rails-ai-context] eager_load_dir #{path} failed: #{e.message}" if ENV["DEBUG"]
      ensure
        load_individually(path)
      end

      def load_individually(path)
        Dir.glob(File.join(path, "**/*.rb")).sort.each do |file|
          file.delete_prefix(path + File::SEPARATOR).sub(/\.rb\z/, "").camelize.constantize
        rescue StandardError, ScriptError
          next
        end
      end
      private_class_method :load_dir, :load_individually
    end
  end
end
