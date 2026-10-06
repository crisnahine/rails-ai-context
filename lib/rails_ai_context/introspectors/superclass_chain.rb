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
      # One link: the class, the superclass it names, and the source declaring it.
      Link = Data.define(:name, :superclass, :source)

      # A validator is wired with `validates_with` or an option, never `include`, so a mixin
      # catalogue must not count one.
      VALIDATOR_BASES = %w[ActiveModel::Validator ActiveModel::EachValidator].freeze

      # Hops, not names: a chain longer than this is a cycle, or a hierarchy
      # no reader is following either.
      MAX_DEPTH = 8

      # Application*, Base* or *Base[Worker|Job|Service]; Base mid-name is a word (TimeBasedJob).
      ABSTRACT_BASE_NAME = /\A(?:Application\w*|Base\w*|\w+Base(?:Worker|Job|Service)?)\z/

      module_function

      # The classes from this one up to the first of `bases`, nearest first,
      # or empty when the chain never reaches one.
      #
      # @param source [String] the file's source
      # @param bases [Array<String>] the superclass names the walk is looking for
      # @param lookup [#call, nil] constant name -> that class's source
      # @param only [String, nil] answer for this class name alone, ignoring the file's other
      #   declarations (a concern that nests a validator class declares both)
      # @return [Array<Link>]
      def to(source, bases:, lookup: nil, seen: [], only: nil)
        return [] if source.nil? || seen.size >= MAX_DEPTH

        declarations = DeclaredConstant.declarations(source)
        declarations = [ DeclaredConstant.declaration_named(declarations, only) ].compact if only
        return [] if declarations.empty?

        declaration = declarations.find { |d| bases.include?(d.superclass) }
        return [ Link.new(name: declaration.name, superclass: declaration.superclass, source: source) ] if declaration

        declarations.each do |candidate|
          parent = candidate.superclass
          next if parent.nil? || seen.include?(parent)

          parent_source = lookup&.call(parent)
          next if parent_source.nil?

          rest = to(parent_source, bases: bases, lookup: lookup, seen: seen + [ parent ])
          return [ Link.new(name: candidate.name, superclass: parent, source: source) ] + rest if rest.any?
        end

        []
      end

      # The validator base the class `name` reaches, or nil for anything else. A concern that
      # nests its own validator class declares both.
      #
      # The name arrives in whatever spelling the caller has, and a file name
      # is not the constant a class declares.
      def validator_base(source, name:, lookup: nil)
        constant = name.to_s.split("::").last.to_s.camelize
        to(source, bases: VALIDATOR_BASES, lookup: lookup, only: constant).last&.superclass
      end

      # Needs both the name and a subclass: an unsubclassed Base is called directly, and a
      # subclassed service is still a service. Rails' Application* bases count either way.
      def abstract_base?(name, inherited:)
        segment = name.to_s.split("::").last.to_s
        return false unless ABSTRACT_BASE_NAME.match?(segment)

        inherited || segment.start_with?("Application")
      end

      # The name half alone, for a caller with no inheritance to check (a directory glob).
      def abstract_base_name?(name)
        ABSTRACT_BASE_NAME.match?(name.to_s.split("::").last.to_s)
      end

      # Rails' own base for one layer, plain or an engine's namespaced copy.
      def conventional_base?(name, base)
        name = name.to_s
        name == base || name.end_with?("::#{base}")
      end

      # A bare superclass resolves through Module.nesting: `module Fasp; class W < BaseWorker` tries Fasp::BaseWorker first.
      # A nil `nesting` is read off the declared name, which is right for the nested form only.
      def resolve_in_scope(declared, parent, nesting: nil)
        parent = parent.to_s.delete_prefix("::")
        return nil if parent.empty?

        ((nesting || nesting_of(declared)).map { |scope| "#{scope}::#{parent}" } + [ parent ]).each do |candidate|
          # `class CostQuery::Export < Export` names the top-level Export; the
          # nearest candidate is the class itself, which is nobody's parent.
          next if candidate == declared.to_s

          found = yield(candidate)
          return found if found
        end
        nil
      end

      # The nesting the nested form gives a class: every enclosing name, innermost first.
      def nesting_of(declared)
        scope = declared.to_s.split("::")[0..-2]
        scope.size.downto(1).map { |i| scope.first(i).join("::") }
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
          roots ||= PathResolver.autoload_roots(root)
          sources.fetch(name) do
            path = PathResolver.file_for_constant(root, name, roots: roots)
            sources[name] = path && SafeFile.read(path)
          end
        end
      end
    end
  end
end
