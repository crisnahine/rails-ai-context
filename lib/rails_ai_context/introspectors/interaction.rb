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
    # file. `SuperclassChain.lookup_for` builds the one both consumers pass.
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

      # `nested` is the filters declared inside this one's block; `declared_by`
      # the class that declares it, which is not this file's class for an
      # inherited one.
      Filter = Data.define(:macro, :name, :options, :declared_by, :nested)

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
        interface(source, lookup: lookup) || []
      end

      # Both answers from one walk of the chain, for a caller that needs to
      # know whether the class is an interaction and what it takes: nil when
      # it is not one, the filters when it is - and an interaction with no
      # filters answers [], which is not nil.
      #
      # @return [Array<Filter>, nil]
      def interface(source, lookup: nil)
        links = chain(source, lookup: lookup)
        return nil if links.empty?

        one_per_name(links.reverse.flat_map { |link| own_filters(link) })
      end

      # The classes from ActiveInteraction::Base down to this one, nearest
      # first, or empty when the chain never reaches it.
      #
      # @return [Array<SuperclassChain::Link>]
      def chain(source, lookup: nil)
        SuperclassChain.to(source, bases: [ BASE ], lookup: lookup)
      end

      # `.filters` is a hash keyed by name, so a subclass that redeclares its
      # parent's filter replaces it and keeps the parent's position. Rendering
      # both printed the name twice, and generating `run(token: nil, token:
      # nil)` from it is a duplicate keyword argument.
      def one_per_name(filters)
        slots = {}
        filters.each_with_index do |filter, index|
          existing = slots[filter.name]
          slots[filter.name] = [ existing ? existing.first : index, filter ]
        end
        slots.values.sort_by(&:first).map(&:last)
      end

      # The filters one class declares, nested ones attached to the filter
      # whose block they sit in, paired by the parent call's own offset in the
      # source.
      def own_filters(link)
        records = SourceIntrospector.walk_source(
          link.source, { filters: -> { Listeners::GenericMacroListener.new(FILTERS) } }
        )[:filters] || []

        # Children first, so a filter is built once, with what it holds. One
        # macro call declares one filter that can take a block (`hash :a, :b
        # do` is not a shape ActiveInteraction accepts), so the call's own
        # offset names the parent of everything inside it.
        children = records.group_by { |record| record[:parent_offset] }
        build_filters(children[nil] || [], children, link.name)
      end

      def build_filters(records, children, declared_by)
        records.flat_map do |record|
          nested = build_filters(children[record[:offset]] || [], children, declared_by)
          Array(record[:args]).map do |name|
            Filter.new(
              macro: record[:macro].to_s,
              name: name.to_s,
              options: record[:option_values] || {},
              declared_by: declared_by,
              nested: nested
            )
          end
        end
      end
      private_class_method :chain, :own_filters, :build_filters, :one_per_name
    end
  end
end
