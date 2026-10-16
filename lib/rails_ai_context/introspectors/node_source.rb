# frozen_string_literal: true

require "prism"

module RailsAiContext
  module Introspectors
    # A node's source with its heredoc bodies: Prism's `slice` stops at the node's end, so
    # `where(<<~SQL, id)` sliced alone loses its SQL.
    module NodeSource
      HEREDOC_TYPES = [
        Prism::StringNode, Prism::InterpolatedStringNode,
        Prism::XStringNode, Prism::InterpolatedXStringNode
      ].freeze

      module_function

      # @param node [Prism::Node]
      # @return [String] the node's slice, followed by the body of every
      #   heredoc it opens whose body lies past its end
      def text(node)
        trailing = heredocs(node).select { |doc| body_end(doc).end_offset > node.location.end_offset }
        return node.slice if trailing.empty?

        first = trailing.min_by { |doc| body_start(doc).start_offset }
        last = trailing.max_by { |doc| body_end(doc).end_offset }
        "#{node.slice}\n#{body_start(first).join(body_end(last)).slice}"
      end

      def heredocs(node)
        found = []
        pending = [ node ]
        while (current = pending.pop)
          found << current if HEREDOC_TYPES.include?(current.class) && current.heredoc?
          pending.concat(current.compact_child_nodes)
        end
        found
      end

      # Where the heredoc's body begins; an empty body begins at its terminator.
      def body_start(doc)
        if doc.respond_to?(:content_loc) then doc.content_loc
        elsif doc.parts.any? then doc.parts.first.location
        else body_end(doc)
        end
      end

      # The terminator; an unterminated heredoc has none from prism 2 on, and ends with its body.
      def body_end(doc)
        doc.closing_loc || (doc.content_loc if doc.respond_to?(:content_loc)) || doc.parts.last&.location || doc.location
      end
    end
  end
end
