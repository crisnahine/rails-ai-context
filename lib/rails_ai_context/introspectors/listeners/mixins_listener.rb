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

        def on_call_node_enter(node)
          return unless node.receiver.nil?
          return unless MIXIN_MACROS.include?(node.name)

          (node.arguments&.arguments || []).each do |arg|
            name = constant_name(arg)
            next unless name

            @results << {
              macro:      node.name,
              name:       name,
              ancestor:   @singleton_depth.zero? && ANCESTOR_MACROS.include?(node.name),
              location:   node.location.start_line,
              confidence: confidence_for(node)
            }
          end
        end

        private

        def constant_name(node)
          return unless node.is_a?(Prism::ConstantReadNode) || node.is_a?(Prism::ConstantPathNode)

          extract_value(node)
        end
      end
    end
  end
end
