# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    module Listeners
      # Call sites by name, wherever they appear: inside a def, a lambda, a
      # callback block. The macro listener only sees class-body calls, and
      # the line scanner this replaces could not tell a call from a comment.
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
            arguments: extract_arg_values(node),
            options: extract_keyword_sources(node),
            snippet: node.slice.lines.first.to_s.strip
          }
        end
      end
    end
  end
end
