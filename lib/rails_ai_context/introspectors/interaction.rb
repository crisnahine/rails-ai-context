# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    # What an ActiveInteraction service declares as its interface: whether the
    # class is one, and the filters it takes.
    #
    # Two things the filter macros alone do not say, and every consumer needs.
    #
    # A filter declared inside another filter's block is a key of that filter,
    # not an input of the class: `string :title` inside `hash :order_params do
    # ... end` never reaches `.filters`, and passing it to `.run` drops it
    # silently. So nesting is kept, never flattened.
    #
    # An interaction is often a subclass of the app's own base interaction
    # rather than of ActiveInteraction::Base, and its filters are then its own
    # plus the ones it inherits, parent's first, which is the order
    # `.filters` answers in. Following that chain needs the parent's source,
    # which only the caller can find, so it comes in as `lookup` - a callable
    # from a constant name to that class's source, or nil to stop at the one
    # file.
    #
    # Reading the loaded constant's `.filters` would answer both on a booted
    # app, but the two consumers (rails_get_service_pattern, rails_generate_test)
    # answer from source in both tiers, and a static answer that differs from
    # the booted one is the divergence this module exists to end.
    module Interaction
      BASE = "ActiveInteraction::Base"

      # The filter macros ActiveInteraction defines. `interface` and `record`
      # included: they are filters like any other.
      FILTERS = %w[
        array boolean date date_time decimal file float hash integer
        interface object record string symbol time
      ].freeze

      # Where an app keeps interactions. Both are conventional, and
      # PathResolver widens each to packs and in-repo engines.
      KINDS = %w[app/services app/interactions].freeze

      # A chain longer than this is a cycle or a class hierarchy no reader is
      # following either.
      MAX_DEPTH = 8

      # `nested` is the filters declared inside this one's block; `declared_by`
      # the class that declares it, which is not this file's class for an
      # inherited one.
      Filter = Data.define(:macro, :name, :options, :declared_by, :nested)

      # One link of the chain: the class and the source declaring it.
      Link = Data.define(:name, :source)

      module_function

      # @param source [String] the file's source
      # @param lookup [#call, nil] constant name -> that class's source
      # @return [Boolean] whether the class this source declares runs as an
      #   ActiveInteraction
      def interaction?(source, lookup: nil)
        chain(source, lookup: lookup).any?
      end

      # The filters the class takes, inherited ones first, each with the
      # filters nested inside it.
      #
      # @return [Array<Filter>] empty when the source declares no interaction
      def filters(source, lookup: nil)
        chain(source, lookup: lookup).reverse.flat_map { |link| own_filters(link) }
      end

      # The classes from ActiveInteraction::Base down to this one, nearest
      # first, or empty when the chain never reaches it.
      #
      # @return [Array<Link>]
      def chain(source, lookup: nil, seen: [])
        return [] if source.nil? || seen.size >= MAX_DEPTH

        declarations = DeclaredConstant.declarations(source)
        return [] if declarations.empty?

        declaration = declarations.find { |d| d.superclass == BASE }
        return [ Link.new(name: declaration.name, source: source) ] if declaration

        declarations.each do |candidate|
          parent = candidate.superclass
          next if parent.nil? || seen.include?(parent)

          parent_source = lookup&.call(parent)
          next if parent_source.nil?

          rest = chain(parent_source, lookup: lookup, seen: seen + [ candidate.name, parent ])
          return [ Link.new(name: candidate.name, source: source) ] + rest if rest.any?
        end

        []
      end

      # A callable from a constant name to the source of the file declaring
      # it, over the directories an app keeps interactions in. The walk is
      # deferred to the first call: an app whose interactions all name
      # ActiveInteraction::Base never pays for it.
      #
      # @return [Proc]
      def lookup_for(root)
        index = nil
        lambda do |name|
          index ||= build_index(root)
          index[name]
        end
      end

      def build_index(root)
        KINDS.each_with_object({}) do |kind, found|
          SourceScan.each(root, kind: kind) do |record|
            name = DeclaredConstant.resolve(record.source, record.path_name)
            found[name] ||= record.source
          end
        end
      rescue StandardError => e
        RailsAiContext.debug_fail(e, {}, label: "Interaction.build_index")
      end

      # The filters one class declares, nested ones attached to the filter
      # whose block they sit in. Records arrive in source order, so the parent
      # of a nested record is the last record opened with that macro name.
      def own_filters(link)
        records = SourceIntrospector.walk_source(
          link.source, { filters: -> { Listeners::GenericMacroListener.new(FILTERS) } }
        )[:filters] || []

        top = []
        by_line = {}

        records.each do |record|
          Array(record[:args]).each do |name|
            filter = Filter.new(
              macro: record[:macro].to_s,
              name: name.to_s,
              options: record[:options] || {},
              declared_by: link.name,
              nested: []
            )
            parent = record[:parent_location] && by_line[record[:parent_location]]
            parent ? parent.nested << filter : top << filter
            # One macro call declares one filter that can take a block
            # (`hash :a, :b do` is not a shape ActiveInteraction accepts), so
            # the call's line names the parent unambiguously.
            by_line[record[:location]] = filter
          end
        end

        top
      end
      private_class_method :build_index, :own_filters
    end
  end
end
