# frozen_string_literal: true

require "prism"

module RailsAiContext
  module Introspectors
    module Listeners
      # Detects `include`, `prepend` and `extend` with a constant argument.
      #
      # `ancestor` marks the ones that reach the ancestor chain, which is what
      # reflection reports - so a caller can answer the same question the
      # booted tier answers.
      class MixinsListener < BaseListener
        MIXIN_MACROS = %i[include prepend extend].to_set.freeze
        ANCESTOR_MACROS = %i[include prepend].to_set.freeze

        include OwnerScope

        def initialize
          super
          @singleton_depth = 0
        end

        # `include` inside `class << self` lands on the singleton class, so it
        # never reaches `ancestors` - extend semantics wearing an include's name.
        def on_singleton_class_node_enter(_node)
          @singleton_depth += 1
        end

        def on_singleton_class_node_leave(_node)
          @singleton_depth -= 1
        end

        # `Type.include(StatusPatch)` mixes into Type, not the class the line sits in, so the
        # record names Type as `receiver` and it is never an ancestor of the enclosing class.
        # `singleton_class.include M` gives the class M's methods, as `extend` does, without its hook.
        def on_call_node_enter(node)
          receiver = node.receiver && constant_name(node.receiver)
          singleton = own_singleton?(node.receiver)
          return unless node.receiver.nil? || receiver || singleton

          macro, arguments = mixin_call(node)
          return unless macro
          return if singleton && macro == :extend

          macro = :"singleton_#{macro}" if singleton

          arguments.each do |arg|
            name = constant_name(arg)
            next unless name

            record = {
              macro:      macro,
              name:       name,
              ancestor:   receiver.nil? && @singleton_depth.zero? && ANCESTOR_MACROS.include?(macro),
              owner:      @owner_stack.dup,
              location:   node.location.start_line,
              confidence: confidence_for(node)
            }
            record[:receiver] = receiver if receiver
            @results << record
          end
        end

        private

        # `singleton_class` or `self.singleton_class`.
        def own_singleton?(node)
          node.is_a?(Prism::CallNode) && node.name == :singleton_class && node.arguments.nil? &&
            (node.receiver.nil? || node.receiver.is_a?(Prism::SelfNode))
        end

        # `include X`, and `send :include, X`, the same include written to reach a private method.
        def mixin_call(node)
          arguments = node.arguments&.arguments || []
          return [ node.name, arguments ] if MIXIN_MACROS.include?(node.name)
          return unless %i[send public_send __send__].include?(node.name)

          first = arguments.first
          macro = first.unescaped.to_sym if first.is_a?(Prism::SymbolNode)
          [ macro, arguments.drop(1) ] if MIXIN_MACROS.include?(macro)
        end

        def constant_name(node)
          return unless node.is_a?(Prism::ConstantReadNode) || node.is_a?(Prism::ConstantPathNode)

          extract_value(node)
        end
      end
    end
  end
end
