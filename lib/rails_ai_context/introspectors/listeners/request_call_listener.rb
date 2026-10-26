# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    module Listeners
      # The requests a test sends: `get "/posts"`, `post posts_path`, `visit "/posts/#{id}"` and a
      # "GET /posts" group name. A record holds the verb and the path sent, or the route helper that
      # builds it (the path is nil for a helper, the helper nil for a path).
      class RequestCallListener < BaseListener
        VERBS = %i[get post put patch delete head visit].freeze
        NAMED = %r{\A(GET|POST|PUT|PATCH|DELETE|HEAD)\s+(/\S*)\z}
        HELPER = /\A(\w+)_(?:path|url)\z/

        def on_call_node_enter(node)
          return unless node.receiver.nil? && VERBS.include?(node.name)

          sent = sent_by(node.arguments&.arguments&.first) or return
          @results << sent.merge(verb: node.name == :visit ? "GET" : node.name.to_s.upcase)
        end

        def on_string_node_enter(node)
          verb, path = node.unescaped.match(NAMED)&.captures
          @results << { verb: verb, path: path, helper: nil } if verb
        end

        private

        def sent_by(node)
          case node
          when Prism::StringNode then literal_path(node.unescaped)
          when Prism::InterpolatedStringNode then interpolated(node)
          when Prism::CallNode then helper_call(node)
          end
        end

        def literal_path(text) = text.start_with?("/") ? { path: text, helper: nil } : nil

        # A part that is not literal text stands for one path segment, as a call's result would.
        def interpolated(node)
          first = node.parts.first
          embedded = first.is_a?(Prism::EmbeddedStatementsNode) && first.statements&.body&.first
          return helper_call(embedded) if embedded.is_a?(Prism::CallNode) && embedded.name.to_s.match?(HELPER)

          literal_path(node.parts.map { |part| part.is_a?(Prism::StringNode) ? part.unescaped : "1" }.join)
        end

        def helper_call(node)
          name = node.name.to_s[HELPER, 1]
          { path: nil, helper: name } if name && node.receiver.nil?
        end
      end
    end
  end
end
