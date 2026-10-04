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

        # `singleton_class` called on what stands for the class: nothing or `self` in its body, `base` in a hook.
        # `singleton_class.include M` gives the class M's methods, as `extend` does, without `extended`.
        def self.singleton_class_of?(node, &stands_for_class)
          node.is_a?(Prism::CallNode) && node.name == :singleton_class && node.arguments.nil? && stands_for_class.call(node.receiver)
        end

        # The record of `node` mixing in `name`.
        def self.record(node, macro, name, ancestor:, owner: [])
          { macro: macro, name: name, ancestor: ancestor, owner: owner, location: node.location.start_line,
            confidence: RailsAiContext::Confidence.for_node(node) }
        end

        # `Type.include(StatusPatch)` mixes into Type, not the class the line sits in, so the
        # record names Type as `receiver` and it is never an ancestor of the enclosing class.
        def on_call_node_enter(node)
          receiver = node.receiver && constant_name(node.receiver)
          singleton = self.class.singleton_class_of?(node.receiver) { |inner| inner.nil? || inner.is_a?(Prism::SelfNode) }
          return unless node.receiver.nil? || receiver || singleton

          macro, arguments = mixin_call(node)
          return unless macro
          return if singleton && macro == :extend

          macro = :"singleton_#{macro}" if singleton

          arguments.each do |arg|
            name = constant_name(arg)
            next unless name

            ancestor = receiver.nil? && @singleton_depth.zero? && ANCESTOR_MACROS.include?(macro)
            record = self.class.record(node, macro, name, ancestor: ancestor, owner: @owner_stack.dup)
            record[:receiver] = receiver if receiver
            @results << record
          end
        end

        private

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
