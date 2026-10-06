# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    module Listeners
      # The literal path forms an app writes a setting with: a string, `%W(#{config.root}/x)`,
      # `Rails.root.join("x")`. Each one read lands in `push_path`; a path built at run time stays unread.
      module LiteralPaths
        APPENDING = %i[<< push append concat].to_set.freeze

        private

        def paths_receiver?(node)
          node.is_a?(Prism::CallNode) && node.name == :paths
        end

        def collect_paths(node)
          case node
          when Prism::ArrayNode then node.elements.each { |element| collect_paths(element) }
          when Prism::StringNode then push_path(node.unescaped)
          when Prism::InterpolatedStringNode then collect_interpolated_path(node)
          when Prism::CallNode then collect_call_path(node)
          end
        end

        # `"#{config.root}/lib_static"`, and only that: an interpolation of
        # some gem's root names a path outside the app.
        def collect_interpolated_path(node)
          return unless app_root?(node.parts.first)

          push_path(node.parts.filter_map { |part| part.content if part.is_a?(Prism::StringNode) }.join)
        end

        # `Rails.root.join("lib_static")` and its `.to_s`, whose arguments are
        # the path relative to the app root.
        def collect_call_path(node)
          return collect_paths(node.receiver) unless node.name == :join
          return unless app_root?(node.receiver)

          segments = Array(node.arguments&.arguments).filter_map { |argument| argument.unescaped if argument.is_a?(Prism::StringNode) }
          push_path(File.join(*segments)) if segments.any?
        end

        APP_ROOT = /\A(?:(?:::)?Rails\.|config\.)?root\z/

        def app_root?(node)
          node = node.statements if node.is_a?(Prism::EmbeddedStatementsNode)
          node = node.body.first if node.is_a?(Prism::StatementsNode)
          node.is_a?(Prism::CallNode) && APP_ROOT.match?(node.slice.strip)
        end

        def push_path(value)
          cleaned = value.to_s.strip.delete_prefix("/")
          @results << cleaned unless cleaned.empty?
        end
      end
    end
  end
end
