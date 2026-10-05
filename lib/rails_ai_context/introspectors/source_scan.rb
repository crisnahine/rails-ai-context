# frozen_string_literal: true

require "set"

module RailsAiContext
  module Introspectors
    # One walk over a kind of app source: every directory PathResolver
    # resolves for it, packs and engines included, each file with its
    # root-relative path and the name its path camelizes to. A caller that
    # globs app/<kind> itself sees only the conventional layout, so every
    # pack and in-repo engine is invisible to it.
    #
    # `paths` stats only; `each` reads the source on top of it. A count or a
    # constantize wants the first, a parser the second.
    module SourceScan
      Record = Data.define(:path, :file, :path_name, :source)

      module_function

      # A run asks for the same kinds again and again (app/models five times on
      # OpenProject), and the glob plus a realpath per file was a fifth of its CPU.
      def paths(root, kind:, skip_concerns: true, &block)
        return enum_for(:paths, root, kind: kind, skip_concerns: skip_concerns) unless block

        RunCache.fetch([ :source_scan, root.to_s, kind, skip_concerns ]) do
          [].tap { |found| scan(root, kind, skip_concerns) { |record| found << record } }
        end.each(&block)
      end

      def scan(root, kind, skip_concerns, &block)
        root = root.to_s
        real_root = File.realpath(root)
        PathResolver.dirs_for(root, kind).each do |dir|
          scan_dir(dir, root, real_root, skip_concerns, &block)
        end
        scan_extra_model_roots(root, real_root, &block) if kind == "app/models"
      rescue Errno::ENOENT, Errno::EACCES, Errno::ELOOP
        nil
      end

      def scan_dir(dir, root, real_root, skip_concerns)
        real_dir = File.realpath(dir)
        ruby_files(dir, [ real_dir, real_root ], Set.new).sort.each do |path|
          relative_to_dir = path.delete_prefix(dir + File::SEPARATOR)
          next if skip_concerns && relative_to_dir.start_with?("concerns/")

          real = File.realpath(path)
          next unless within?(real, real_dir, real_root)

          path_name = relative_to_dir.sub(/\.rb\z/, "").split("/").map(&:camelize).join("::")
          yield Record.new(path: real, file: relative_file(path, real, root, real_root), path_name: path_name, source: nil)
        rescue Errno::ENOENT, Errno::EACCES, Errno::ELOOP
          next
        end
      rescue Errno::ENOENT, Errno::EACCES, Errno::ELOOP
        nil
      end

      # Zeitwerk follows symlinks, so the walk does too, as far as the app's
      # own tree; a directory reached twice (a link back up) is walked once.
      def ruby_files(dir, bounds, visited)
        return [] unless visited.add?(File.realpath(dir))

        Dir.children(dir).flat_map do |name|
          next [] if name.start_with?(".")

          path = File.join(dir, name)
          if File.directory?(path)
            within?(File.realpath(path), *bounds) ? ruby_files(path, bounds, visited) : []
          else
            name.end_with?(".rb") ? [ path ] : []
          end
        rescue Errno::ENOENT, Errno::EACCES, Errno::ELOOP
          []
        end
      end

      def within?(real, real_dir, real_root)
        SafePath.contained?(real, real_dir) || SafePath.contained?(real, real_root)
      end

      SUPERCLASS_DECLARATION = /^[^\S\n]*class[^\S\n]+[\w:]+[^\S\n]*</

      # Rails autoloads every app/* directory and the roots config/application.rb
      # adds, so a model can live outside app/models. Only a file that declares
      # a class with a superclass is kept: each one is read here, and parsed later.
      # ponytail: the app/* kinds Rails generates for other code are skipped by name.
      def scan_extra_model_roots(root, real_root)
        seen = Set.new
        PathResolver.extra_model_roots(root).each do |dir|
          scan_dir(dir, root, real_root, true) do |record|
            next unless seen.add?(record.path)

            source = SafeFile.read(record.path)
            yield record if source&.match?(SUPERCLASS_DECLARATION)
          end
        end
      end

      private_class_method :scan, :scan_dir, :ruby_files, :within?, :scan_extra_model_roots

      def each(root, kind:, skip_concerns: true)
        return enum_for(:each, root, kind: kind, skip_concerns: skip_concerns) unless block_given?

        paths(root, kind: kind, skip_concerns: skip_concerns) do |record|
          source = SafeFile.read(record.path) or next
          yield record.with(source: source)
        end
      end

      # The eager form: reads and parses every file for its declared name.
      # A caller that names only some files resolves DeclaredConstant itself.
      def classes(root, kind:)
        each(root, kind: kind).filter_map do |record|
          next unless DeclaredConstant.declares_class?(record.source)

          [ DeclaredConstant.resolve(record.source, record.path_name), record ]
        end
      end

      # A pack or engine directory that is a symlink out of the root resolves
      # to a real path the root does not contain; the unresolved path is
      # still the one the app spells.
      def relative_file(path, real, root, real_root)
        real_prefix = real_root + File::SEPARATOR
        return real.delete_prefix(real_prefix) if real.start_with?(real_prefix)

        path.delete_prefix(root + File::SEPARATOR)
      end

      # Either spelling may land inside the root (only one does for a symlinked
      # pack), but a spelled ".." can climb out through a symlink, so it needs the real one.
      def under_root?(path, real, root, real_root)
        return true if real.start_with?(real_root + File::SEPARATOR)

        !path.split(File::SEPARATOR).include?("..") && File.expand_path(path).start_with?(root + File::SEPARATOR)
      end
    end
  end
end
