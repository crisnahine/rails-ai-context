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
        ruby_files(dir, real_dir, [ real_dir, real_root ], Set.new).sort_by(&:first).each do |path, real|
          relative_to_dir = path.delete_prefix(dir + File::SEPARATOR)
          next if skip_concerns && relative_to_dir.start_with?("concerns/")
          next unless within?(real, real_dir, real_root)

          path_name = relative_to_dir.sub(/\.rb\z/, "").split("/").map(&:camelize).join("::")
          yield Record.new(path: real, file: relative_file(path, real, root, real_root), path_name: path_name, source: nil)
        end
      rescue Errno::ENOENT, Errno::EACCES, Errno::ELOOP
        nil
      end

      # Zeitwerk follows symlinks, so the walk does too, as far as the app's
      # own tree; a directory reached twice (a link back up) is walked once.
      # Linked directories wait until the real tree is done, so a directory
      # both spell is named by its real path whatever order the disk lists.
      # Each entry is [path as spelled, real path].
      def ruby_files(dir, real_dir, bounds, visited)
        pending = [ [ dir, real_dir ] ]
        found = []
        found.concat(walk_dir(*pending.shift, bounds, visited, pending)) while pending.any?
        found
      end

      # One lstat per entry: below a real directory only a link needs a realpath.
      def walk_dir(dir, real_dir, bounds, visited, links)
        return [] unless visited.add?(real_dir)

        Dir.children(dir).sort.flat_map do |name|
          next [] if name.start_with?(".")

          path = File.join(dir, name)
          stat = File.lstat(path)
          if stat.symlink?
            real = File.realpath(path)
            if !File.directory?(real)
              name.end_with?(".rb") ? [ [ path, real ] ] : []
            else
              links << [ path, real ] if within?(real, *bounds)
              []
            end
          elsif stat.directory?
            walk_dir(path, File.join(real_dir, name), bounds, visited, links)
          else
            name.end_with?(".rb") ? [ [ path, File.join(real_dir, name) ] ] : []
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
      # A booted caller passes `base_model`, called with [name, superclass] for a
      # superclass the scan does not know, since a gem or initializer can define it.
      def model_paths(root, base_model: nil, &block)
        return enum_for(:model_paths, root, base_model: base_model) unless block

        RunCache.fetch([ :source_scan_models, root.to_s, !base_model.nil? ]) do
          found = paths(root, kind: "app/models", skip_concerns: false).to_a
          found + extra_model_candidates(root.to_s, found, base_model)
        end.each(&block)
      end

      CLASS_WITH_SUPERCLASS = /class[^\S\n]+([\w:]+)[^\S\n]*<[^\S\n]*(?:::)?([\w:]+)/
      MODEL_BASES = %w[ActiveRecord::Base ApplicationRecord].freeze

      # Rails autoloads every app/* directory and the roots config/application.rb
      # adds, so a model can live outside app/models. A class there is kept when
      # its superclass, looked up from the namespace its path names, is a model base,
      # a model or a class already kept; the listing still decides modelhood, but a
      # thousand services are not parsed.
      def extra_model_candidates(root, model_records, base_model = nil)
        pending, declared = RunCache.fetch([ :source_scan_model_declarations, root ]) { extra_model_declarations(root, File.realpath(root)) }
        known = model_records.to_set(&:path_name).merge(MODEL_BASES)
        declared = declared | known
        loaded = Hash.new { |cache, pair| cache[pair] = base_model ? base_model.call(*pair) : false }
        kept = Set.new
        loop do
          added = pending.select do |record, pairs|
            !kept.include?(record) && pairs.any? do |name, base|
              # Ruby takes the innermost scope that declares the name; a nested
              # `class Item < Base` names no namespace, the path does.
              resolved = lookup(record.path_name, base).reverse.find { |candidate| declared.include?(candidate) }
              resolved ? known.include?(resolved) : loaded[[ name.include?("::") ? name : record.path_name, base ]]
            end
          end
          break if added.empty?

          added.each do |record, pairs|
            kept << record
            known.merge(pairs.map { |name, _| name.include?("::") ? name : lookup(record.path_name, name).last })
          end
        end
        pending.filter_map { |record, _| record if kept.include?(record) }
      rescue Errno::ENOENT, Errno::EACCES, Errno::ELOOP
        []
      end

      # The names `base` can mean inside the namespace `path_name` sits in, outermost first.
      def lookup(path_name, base)
        scopes = path_name.split("::")[0...-1]
        (0..scopes.size).map { |depth| [ *scopes.first(depth), base ].join("::") }
      end

      # ponytail: the app/* kinds Rails generates for other code are skipped by name.
      # The candidates, and every name the scanned files declare by path or by a superclassed class.
      def extra_model_declarations(root, real_root)
        seen = Set.new
        declared = Set.new
        ignored = PathResolver.ignored_dirs(root).map { |dir| PathResolver.root_key(dir) }
        found = PathResolver.extra_model_roots(root).each_with_object([]) do |dir, records|
          scan_dir(dir, root, real_root, true) do |record|
            next unless seen.add?(record.path)
            next if ignored.any? { |ignored_dir| SafePath.contained?(record.path, ignored_dir) }

            declared << record.path_name
            pairs = class_declarations(SafeFile.read(record.path).to_s)
            next if pairs.empty?

            records << [ record, pairs ]
            pairs.each { |name, _| declared << (name.include?("::") ? name : lookup(record.path_name, name).last) }
          end
        end
        [ found, declared ]
      end

      # [name, superclass] of each `class X < Y` that starts its line. A `^` anchor
      # makes Onigmo try every offset, ten times slower over a service tree.
      def class_declarations(source)
        pairs = []
        source.scan(CLASS_WITH_SUPERCLASS) do |name, base|
          start = Regexp.last_match.begin(0)
          line_start = start.zero? ? 0 : (source.rindex("\n", start - 1) || -1) + 1
          pairs << [ name, base ] if source[line_start...start].match?(/\A[^\S\n]*\z/)
        end
        pairs
      end

      private_class_method :scan, :scan_dir, :ruby_files, :walk_dir, :within?, :extra_model_candidates, :extra_model_declarations, :class_declarations, :lookup

      # `kind: :models` reads model_paths: what model_details lists, not only app/models.
      def each(root, kind:, skip_concerns: true, base_model: nil, &block)
        return enum_for(:each, root, kind: kind, skip_concerns: skip_concerns, base_model: base_model) unless block

        read = lambda do |record|
          source = SafeFile.read(record.path) or next
          block.call(record.with(source: source))
        end
        return paths(root, kind: kind, skip_concerns: skip_concerns, &read) unless kind == :models

        model_paths(root, base_model: base_model) { |record| read.call(record) unless skip_concerns && record.path_name.start_with?("Concerns::") }
      end

      # The eager form: reads and parses every file for its declared name.
      # A caller that names only some files resolves DeclaredConstant itself.
      def classes(root, kind:, base_model: nil)
        each(root, kind: kind, base_model: base_model).filter_map do |record|
          next unless DeclaredConstant.declares_class?(record.source)

          [ DeclaredConstant.resolve(record.source, record.path_name), record ]
        end
      end

      # A pack or engine directory that is a symlink out of the root resolves
      # to a real path the root does not contain; the unresolved path is
      # still the one the app spells.
      def relative_file(path, real, root, real_root)
        real_prefix = SafePath.dir_prefix(real_root)
        return real.delete_prefix(real_prefix) if real.start_with?(real_prefix)

        path.delete_prefix(SafePath.dir_prefix(root))
      end

      # Either spelling may land inside the root (only one does for a symlinked
      # pack), but a spelled ".." can climb out through a symlink, so it needs the real one.
      def under_root?(path, real, root, real_root)
        return true if SafePath.contained?(real, real_root)

        !path.split(File::SEPARATOR).include?("..") && File.expand_path(path).start_with?(SafePath.dir_prefix(root))
      end
    end
  end
end
