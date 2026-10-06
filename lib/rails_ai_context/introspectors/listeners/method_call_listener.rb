# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    module Listeners
      # Call sites by name, wherever they appear: inside a def, a lambda, a
      # callback block. The macro listener only sees class-body calls.
      class MethodCallListener < BaseListener
        def initialize(names: nil, pattern: nil)
          super()
          @names = names&.map(&:to_sym)&.to_set
          @pattern = pattern
        end

        def on_call_node_enter(node)
          name = node.name
          return unless @names&.include?(name) || (@pattern && name.to_s.match?(@pattern))

          @results << {
            name: name.to_s,
            receiver: node.receiver&.slice,
            line: node.location.start_line,
            offset: node.location.start_offset,
            arguments: extract_arg_values(node),
            computed: computed_arguments(node),
            options: extract_keyword_sources(node),
            snippet: node.slice.lines.first.to_s.strip
          }
        end

        private

        # The source of each positional argument, or array element, that is no literal,
        # since `arguments` gives a local variable's source and a string's value alike.
        def computed_arguments(node)
          (node.arguments&.arguments || []).flat_map { |arg| arg.is_a?(Prism::ArrayNode) ? arg.elements : [ arg ] }
            .select { |arg| extract_value(arg) == RailsAiContext::Confidence::INFERRED }.map { |arg| one_line_source(arg) }
        end
      end
    end
  end
end
