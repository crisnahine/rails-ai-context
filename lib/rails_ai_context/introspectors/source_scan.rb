# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    # One walk over a kind of app source: every directory PathResolver
    # resolves for it, packs and engines included, each file with its
    # root-relative path and the name its path camelizes to. Thirteen
    # introspectors globbed app/<kind> directly and every one of them missed
    # a pack.
    #
    # `paths` stats only; `each` reads the source on top of it. A count or a
    # constantize wants the first, a parser the second.
    module SourceScan
      Record = Data.define(:path, :file, :path_name, :source)

      module_function

      def paths(root, kind:, skip_concerns: true)
        return enum_for(:paths, root, kind: kind, skip_concerns: skip_concerns) unless block_given?

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
      private_class_method :relative_file
    end
  end
end
