# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    # One reader for the filter macros a controller body declares.
    #
    # The listing reads them to build each entry, and the chain walk reads them
    # for a base class the listing leaves out. Two readers would answer one
    # question two ways, which is what happened while the walk had none: a
    # `before_action` in ApplicationController reached the generated overview
    # through its own file read and reached no tool at all.
    module ControllerFilters
      MACROS = %i[
        before_action after_action around_action
        prepend_before_action append_before_action
        skip_before_action skip_after_action skip_around_action append_after_action
      ].freeze

      LISTENERS = {
        filters: -> { Listeners::GenericMacroListener.new(*MACROS) },
        mixins: Listeners::MixinsListener
      }.freeze

      module_function

      # @param source [String] one controller's Ruby source
      # @return [Array<Hash>] { name:, kind:, skipped:/declared:, only:, except:, if:, unless: }
      def from_source(source)
        walk(source).filter_map { |entry| record(entry) }
      rescue => e
        RailsAiContext.debug_fail(e, [], label: "controller filter read")
      end

      # The class body's filters and every included concern's, in Rails' order: an `include`
      # adds its concern's filters where it stands, each named in `from_concern`.
      #
      # @param within [String] the class's constant, for a namespace-relative `include`
      # @param cache [Hash, nil] see ConcernMacros.collect
      # @return [Array(Array<Hash>, Array<String>)] the filters, and the
      #   included modules whose file could not be read
      def with_concerns(source, root:, within:, cache: nil)
        walked = SourceIntrospector.walk_source(source, LISTENERS)
        mixins = Array(walked[:mixins])
        # One walk, so a concern two includes reach is added once, as Ruby does.
        collected, unread, _hidden, _calls, placement = ConcernMacros.collect(
          root, mixins, keys: [ :filters ], prefer: "controller", within: within, cache: cache, listeners: LISTENERS
        )
        line_of = mixins.reverse.to_h { |mixin| [ mixin[:name], mixin[:location].to_i ] }
        placed = Array(walked[:filters]).map { |entry| [ entry[:location].to_i, -1, entry ] } +
                 Array(collected[:filters]).map do |entry|
                   top, order = placement[entry[:from_concern]]
                   [ line_of[top].to_i, order.to_i, entry ]
                 end
        filters = placed.each_with_index.sort_by { |(line, order, _), index| [ line, order, index ] }
                        .filter_map do |(_, _, entry), _|
          filter = record(entry)
          filter && entry[:from_concern] ? filter.merge(from_concern: entry[:from_concern]) : filter
        end
        [ filters, unread ]
      rescue => e
        RailsAiContext.debug_fail(e, [ [], [] ], label: "controller filter read with concerns")
      end

      def walk(source)
        SourceIntrospector.walk_source(source, LISTENERS.slice(:filters))[:filters] || []
      end

      def record(entry)
        name = entry[:args]&.first
        return nil unless name

        macro = entry[:macro].to_s
        skipped = macro.start_with?("skip_")
        # An excluded name is framework noise only while it runs. A skip of it
        # is the app's own decision, which the per-action answer reports.
        return nil if !skipped && RailsAiContext.configuration.excluded_filters.include?(name.to_s)

        filter = { name: name.to_s, kind: macro.sub(/_action\z/, "").sub(/\A(?:prepend|append|skip)_/, "") }
        # A skip states the opposite of what the plain kind says, so it has to
        # survive the fold into `before`/`after`/`around`. A declaration marks
        # the body that made it, so an ancestor's skip of the same name does
        # not reach it.
        skipped ? filter[:skipped] = true : filter[:declared] = true
        filter.merge(constraints(entry))
      end

      def constraints(entry)
        opts = entry[:options] || {}
        sources = entry[:option_values] || {}
        out = {}
        only = normalize(opts[:only])
        except = normalize(opts[:except])
        out[:only] = only if only&.any?
        out[:except] = except if except&.any?
        out[:unless] = condition_text(opts[:unless], sources[:unless]) if opts[:unless]
        if opts[:if]
          # When the condition compares action_name the AST can say which
          # action it names; that is worth more than the line itself.
          actions = action_condition(entry[:option_nodes]&.[](:if))
          out[:if] = actions ? %(action_name == "#{actions.first}") : condition_text(opts[:if], sources[:if])
        end
        out
      end

      # A lambda has no literal value, so the line the file holds is what
      # there is to print. A symbol stays one, so the renderer can spell it.
      def condition_text(value, source)
        value.to_s == RailsAiContext::Confidence::INFERRED ? source.to_s : value
      end

      def normalize(value)
        case value
        when Array then value.map(&:to_s)
        when Symbol then [ value.to_s ]
        when String then [ value ]
        when nil then nil
        else [ value.to_s ]
        end
      end

      def action_condition(node)
        node = lambda_body(node)
        return nil unless node.is_a?(Prism::CallNode) && node.name == :==

        receiver = node.receiver
        return nil unless receiver.is_a?(Prism::CallNode) && receiver.name == :action_name && receiver.receiver.nil?

        case node.arguments&.arguments&.first
        when Prism::StringNode then [ node.arguments.arguments.first.unescaped ]
        when Prism::SymbolNode then [ node.arguments.arguments.first.unescaped ]
        end
      end

      def lambda_body(node)
        return node unless node.is_a?(Prism::LambdaNode) || node.is_a?(Prism::BlockNode)

        statements = node.body
        return nil unless statements.is_a?(Prism::StatementsNode) && statements.body.size == 1

        statements.body.first
      end

      private_class_method :walk, :record, :constraints, :condition_text, :normalize, :action_condition, :lambda_body
    end
  end
end
