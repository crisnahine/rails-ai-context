# frozen_string_literal: true

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

      def scan(root, kind, skip_concerns)
        root = root.to_s
        real_root = File.realpath(root)
        PathResolver.dirs_for(root, kind).each do |dir|
          real_dir = File.realpath(dir)
          Dir.glob(File.join(dir, "**", "*.rb")).sort.each do |path|
            relative_to_dir = path.delete_prefix(dir + File::SEPARATOR)
            next if skip_concerns && relative_to_dir.start_with?("concerns/")

            real = File.realpath(path)
            next unless SafePath.contained?(real, real_dir)

            path_name = relative_to_dir.sub(/\.rb\z/, "").split("/").map(&:camelize).join("::")
            yield Record.new(path: real, file: relative_file(path, real, root, real_root), path_name: path_name, source: nil)
          rescue Errno::ENOENT, Errno::EACCES, Errno::ELOOP
            next
          end
        rescue Errno::ENOENT, Errno::EACCES, Errno::ELOOP
          next
        end
      rescue Errno::ENOENT, Errno::EACCES, Errno::ELOOP
        nil
      end

      private_class_method :scan

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
