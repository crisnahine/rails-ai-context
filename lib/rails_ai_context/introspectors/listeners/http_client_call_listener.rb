# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    module Listeners
      # Calls on an HTTP client constant with a literal URL: `Faraday.get("https://x")`,
      # `Net::HTTP.get(URI("https://x"))`, `Faraday.new(url: "https://x")`, `URI.open("https://x")`,
      # and `Net::HTTP.start("api.x.com", 443)`, whose first argument is a host.
      class HttpClientCallListener < BaseListener
        CLIENTS = %w[Faraday Net::HTTP HTTParty RestClient HTTP Excon Typhoeus].freeze

        def on_call_node_enter(node)
          client = client_name(node) or return

          first = node.arguments&.arguments&.first
          if client == "Net::HTTP" && %i[start new].include?(node.name)
            host = literal_string(first)
            @results << { client: client, host: host, line: node.location.start_line } if host
          elsif (url = url_literal(first) || url_literal(extract_keyword_nodes(node)[:url]))
            @results << { client: client, url: url, line: node.location.start_line }
          end
        end

        private

        def client_name(node)
          receiver = node.receiver
          return nil unless receiver.is_a?(Prism::ConstantReadNode) || receiver.is_a?(Prism::ConstantPathNode)

          name = constant_path_string(receiver)
          return "URI.open" if name == "URI" && node.name == :open

          name if CLIENTS.include?(name)
        end

        # A string literal, or one wrapped in `URI(...)` or `URI.parse(...)`.
        def url_literal(node)
          return node.unescaped if node.is_a?(Prism::StringNode)
          return nil unless node.is_a?(Prism::CallNode)

          receiver = node.receiver
          wrapped = (receiver.nil? && node.name == :URI) ||
            (node.name == :parse && receiver.is_a?(Prism::ConstantReadNode) && receiver.name == :URI)
          inner = node.arguments&.arguments&.first
          inner.unescaped if wrapped && inner.is_a?(Prism::StringNode)
        end
      end
    end
  end
end
