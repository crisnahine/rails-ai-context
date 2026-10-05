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
      # Linked directories wait until the real tree is done, so a directory
      # both spell is named by its real path whatever order the disk lists.
      def ruby_files(dir, bounds, visited)
        pending = [ dir ]
        found = []
        found.concat(walk_dir(pending.shift, bounds, visited, pending)) while pending.any?
        found
      end

      def walk_dir(dir, bounds, visited, links)
        return [] unless visited.add?(File.realpath(dir))

        Dir.children(dir).sort.flat_map do |name|
          next [] if name.start_with?(".")

          path = File.join(dir, name)
          if !File.directory?(path)
            name.end_with?(".rb") ? [ path ] : []
          elsif !within?(File.realpath(path), *bounds)
            []
          elsif File.symlink?(path)
            links << path
            []
          else
            walk_dir(path, bounds, visited, links)
          end
        rescue Errno::ENOENT, Errno::EACCES, Errno::ELOOP
          []
        end
      rescue Errno::ENOENT, Errno::EACCES, Errno::ELOOP
        []
      end

      def within?(real, real_dir, real_root)
        SafePath.contained?(real, real_dir) || SafePath.contained?(real, real_root)
      end

      # The model directories plus the classes elsewhere that could be a model.
      # Only the model listing wants the second half: a count or a per-model
      # read of app/models would take in every service with a superclass.
      def model_paths(root, &block)
        return enum_for(:model_paths, root) unless block

        RunCache.fetch([ :source_scan_models, root.to_s ]) do
          found = paths(root, kind: "app/models", skip_concerns: false).to_a
          found + extra_model_candidates(root.to_s, found)
        end.each(&block)
      end

      CLASS_WITH_SUPERCLASS = /^[^\S\n]*class[^\S\n]+([\w:]+)[^\S\n]*<[^\S\n]*(?:::)?([\w:]+)/
      MODEL_BASES = %w[ActiveRecord::Base ApplicationRecord].freeze

      # Rails autoloads every app/* directory and the roots config/application.rb
      # adds, so a model can live outside app/models. A class there is kept when
      # its superclass, by last name segment, is a model base or a class already
      # kept; the listing still decides modelhood, but a thousand services are not parsed.
      def extra_model_candidates(root, model_records)
        pending = extra_model_declarations(root, File.realpath(root))
        known = model_records.to_set { |record| record.path_name.split("::").last }.merge(MODEL_BASES)
        kept = Set.new
        loop do
          added = pending.select { |record, pairs| !kept.include?(record) && pairs.any? { |_, base| known.include?(base) || known.include?(base.split("::").last) } }
          break if added.empty?

          added.each do |record, pairs|
            kept << record
            known.merge(pairs.map { |name, _| name.split("::").last })
          end
        end
        pending.filter_map { |record, _| record if kept.include?(record) }
      rescue Errno::ENOENT, Errno::EACCES, Errno::ELOOP
        []
      end

      # ponytail: the app/* kinds Rails generates for other code are skipped by name.
      def extra_model_declarations(root, real_root)
        seen = Set.new
        ignored = PathResolver.ignored_dirs(root).map { |dir| PathResolver.root_key(dir) }
        PathResolver.extra_model_roots(root).each_with_object([]) do |dir, found|
          scan_dir(dir, root, real_root, true) do |record|
            next unless seen.add?(record.path)
            next if ignored.any? { |ignored_dir| SafePath.contained?(record.path, ignored_dir) }

            pairs = SafeFile.read(record.path)&.scan(CLASS_WITH_SUPERCLASS)
            found << [ record, pairs ] if pairs&.any?
          end
        end
      end

      private_class_method :scan, :scan_dir, :ruby_files, :walk_dir, :within?, :extra_model_candidates, :extra_model_declarations

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
