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

          segments = app_root_join(node)
          push_path(File.join(*segments)) if segments
        end

        # The segments of `Rails.root.join("a", "b")`, nil unless every one is a literal.
        def app_root_join(node)
          return nil unless node.is_a?(Prism::CallNode) && node.name == :join && app_root?(node.receiver)

          segments = Array(node.arguments&.arguments)
          segments.map(&:unescaped) if segments.any? && segments.all?(Prism::StringNode)
        end

        # `root`, `config.root`, `Rails.root` or `::Rails.root`.
        def app_root?(node)
          node = node.statements if node.is_a?(Prism::EmbeddedStatementsNode)
          node = node.body.first if node.is_a?(Prism::StatementsNode)
          return false unless node.is_a?(Prism::CallNode) && node.name == :root && node.arguments.nil? && node.block.nil?

          receiver = node.receiver
          case receiver
          when nil then true
          when Prism::CallNode then receiver.name == :config && receiver.receiver.nil? && receiver.arguments.nil?
          when Prism::LocalVariableReadNode then receiver.name == :config
          when Prism::ConstantReadNode, Prism::ConstantPathNode then constant_path_string(receiver) == "Rails"
          else false
          end
        end

        def push_path(value)
          cleaned = value.to_s.strip.delete_prefix("/")
          @results << cleaned unless cleaned.empty?
        end
      end
    end
  end
end
