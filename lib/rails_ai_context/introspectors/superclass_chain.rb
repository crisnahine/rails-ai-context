# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    # What a class inherits from, followed through the app's own sources.
    #
    # A file says which class it declares and which one it names as its
    # superclass, and nothing more: the question "is this an
    # ActiveInteraction", or "is this a validator", is a question about the
    # chain, and the chain is spread across files. One level of string compare
    # answers it for a class that subclasses the framework directly and calls
    # every app's own base class a stranger - which is the ordinary shape, and
    # the one that produced the wrong answers this module exists to end.
    #
    # The parent's source is the caller's to find, so it arrives as `lookup` -
    # a callable from a constant name to that class's source, and nil to stop
    # at the one file. `lookup_for` builds the one this gem uses.
    module SuperclassChain
      # One link: the class and the source declaring it.
      Link = Data.define(:name, :source)

      # A chain longer than this is a cycle, or a hierarchy no reader is
      # following either.
      MAX_DEPTH = 8

      module_function

      # The classes from this one up to the first of `bases`, nearest first,
      # or empty when the chain never reaches one.
      #
      # @param source [String] the file's source
      # @param bases [Array<String>] the superclass names the walk is looking for
      # @param lookup [#call, nil] constant name -> that class's source
      # @return [Array<Link>]
      def to(source, bases:, lookup: nil, seen: [])
        return [] if source.nil? || seen.size >= MAX_DEPTH

        declarations = DeclaredConstant.declarations(source)
        return [] if declarations.empty?

        declaration = declarations.find { |d| bases.include?(d.superclass) }
        return [ Link.new(name: declaration.name, source: source) ] if declaration

        declarations.each do |candidate|
          parent = candidate.superclass
          next if parent.nil? || seen.include?(parent)

          parent_source = lookup&.call(parent)
          next if parent_source.nil?

          rest = to(parent_source, bases: bases, lookup: lookup, seen: seen + [ candidate.name, parent ])
          return [ Link.new(name: candidate.name, source: source) ] + rest if rest.any?
        end

        []
      end

      # A callable from a constant name to the source of the file declaring
      # it, probed against the app's autoload roots rather than a walk over
      # the tree: Zeitwerk resolves a constant to one path under one root, and
      # `underscore` is the half of the inflection that is right with or
      # without the app's own acronyms. A base class at a path its name does
      # not underscore to is not found, which is the same thing Zeitwerk would
      # say about it.
      #
      # The roots are resolved on the first question and each answer is kept,
      # so a tree of four hundred services sharing one base class reads that
      # base once.
      #
      # @return [Proc]
      def lookup_for(root)
        roots = nil
        sources = {}
        lambda do |name|
          roots ||= autoload_roots(root)
          sources.fetch(name) do
            relative = "#{name.to_s.underscore}.rb"
            path = roots.lazy.map { |dir| File.join(dir, relative) }.find { |candidate| File.file?(candidate) }
            sources[name] = path && SafeFile.read(path)
          end
        end
      end

      # Every directory Rails autoloads constants from: each app/* directory,
      # the concerns directories inside them (railties globs `{*,*/concerns}`),
      # and lib. Packs and in-repo engines come with PathResolver.
      def autoload_roots(root)
        app_trees = PathResolver.dirs_for(root, "app")
        app_trees.flat_map { |tree| Dir.glob(File.join(tree, "*")).select { |dir| File.directory?(dir) } } +
          ConcernPaths.resolve(root) +
          PathResolver.dirs_for(root, "lib")
      rescue StandardError => e
        RailsAiContext.debug_fail(e, [], label: "SuperclassChain.autoload_roots")
      end
    end
  end
end
