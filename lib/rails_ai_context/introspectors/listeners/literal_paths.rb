# frozen_string_literal: true

require "pathname"

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
          return collect_file_path(node) if @file && node.receiver.is_a?(Prism::ConstantReadNode) && node.receiver.name == :File
          return collect_paths(node.receiver) unless node.name == :join

          segments = app_root_join(node)
          push_path(File.join(*segments)) if segments
        end

        # `File.expand_path("x", __dir__)` and `File.join(__dir__, "x")`, read when the
        # listener is given `@file`, the walked file's path relative to the app root.
        def collect_file_path(node)
          arguments = Array(node.arguments&.arguments)
          path = case node.name
          when :expand_path then file_relative(arguments.first, arguments[1]) if arguments.size == 2
          when :join then file_relative_join(arguments)
          end
          push_path(path) if path
        end

        def file_relative(relative, base)
          return unless relative.is_a?(Prism::StringNode)

          anchor = file_anchor(base) or return
          Pathname.new(File.join(anchor, relative.unescaped)).cleanpath.to_s
        end

        def file_relative_join(arguments)
          anchor = file_anchor(arguments.first) or return
          rest = arguments.drop(1)
          return unless rest.any? && rest.all?(Prism::StringNode)

          Pathname.new(File.join(anchor, *rest.map(&:unescaped))).cleanpath.to_s
        end

        # `File.expand_path("x", __FILE__)` resolves against the file name itself, as Ruby does.
        def file_anchor(node)
          case node
          when Prism::SourceFileNode then @file
          when Prism::CallNode then File.dirname(@file) if node.name == :__dir__ && node.receiver.nil?
          end
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
