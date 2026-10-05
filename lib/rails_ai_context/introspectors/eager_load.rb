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

        dirs = PathResolver.dirs_for(root, kind) + enclosing_engine_roots(root).map { |engine| File.join(engine, kind) }
        dirs.select { |path| Dir.exist?(path) }.uniq.each { |path| load_dir(path) }
      rescue StandardError, ScriptError => e
        RailsAiContext.debug_fail(e, nil, label: "eager load of #{kind}")
      end

      # An engine's test/dummy runs inside the engine, whose classes are the project's.
      def enclosing_engine_roots(root)
        return [] unless defined?(::Rails::Engine)

        inside = "#{File.expand_path(root.to_s)}#{File::SEPARATOR}"
        ::Rails::Engine.subclasses.filter_map do |engine|
          next if engine.root.nil?

          dir = File.expand_path(engine.root.to_s)
          dir if inside.start_with?("#{dir}#{File::SEPARATOR}")
        rescue StandardError
          nil
        end
      end

      # eager_load_dir returns silently for a directory the loader manages
      # but does not eager load, so the per-constant walk always follows: a
      # constant already loaded is a hash lookup, and one that is not gets
      # loaded here. A file that cannot load costs itself.
      def load_dir(path)
        loader = Rails.autoloaders.main
        loader.eager_load_dir(path) if loader.respond_to?(:eager_load_dir)
      rescue StandardError, ScriptError => e
        RailsAiContext.debug_fail(e, label: "eager_load_dir #{path}")
      ensure
        load_individually(path)
      end

      # The loader names the constant, not `camelize`: an app inflection
      # makes the two disagree, and a wrong name silently loads nothing.
      def load_individually(path)
        loader = Rails.autoloaders.main
        Dir.glob(File.join(path, "**/*.rb")).sort.each do |file|
          cpath_for(loader, path, file).constantize
        rescue StandardError, ScriptError
          next
        end
      end

      # SourceScan records, each loaded by the constant its file holds. Without
      # the loader's answer (Zeitwerk < 2.6.9) the source's own declaration names
      # it: path_name reads app/services/x.rb as Services::X.
      def files(records)
        loader = Rails.autoloaders.main
        records.each do |record|
          names = [ expected_cpath(loader, record.path) ].compact
          names = DeclaredConstant.declarations(record.source).map(&:name) if names.empty?
          names = [ record.path_name ] if names.empty?
          names.each(&:constantize)
        rescue StandardError, ScriptError => e
          RailsAiContext.debug_fail(e, label: "load #{record.file}")
        end
      end

      # The loader declines a file it does not manage (a pack or an in-repo
      # engine runs its own), by nil or by raising; camelize still names it
      # well enough for that loader's autoload to answer.
      def cpath_for(loader, path, file)
        expected_cpath(loader, file) || file.delete_prefix(path + File::SEPARATOR).sub(/\.rb\z/, "").camelize
      end

      def expected_cpath(loader, file)
        loader.cpath_expected_at(file) if loader.respond_to?(:cpath_expected_at)
      rescue Zeitwerk::Error
        nil
      end
      private_class_method :load_dir, :enclosing_engine_roots, :load_individually, :cpath_for, :expected_cpath
    end
  end
end
