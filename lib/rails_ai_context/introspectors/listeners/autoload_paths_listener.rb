# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    module Listeners
      # Autoload roots an app adds in config/application.rb:
      #
      #   config.autoload_paths << "lib_static"          → "lib_static"
      #   config.eager_load_paths += %W(#{config.root}/x) → "x"
      #   config.autoload_lib(ignore: %w[tasks])          → "lib"
      #
      # Literal paths only; a root built at run time stays unread.
      class AutoloadPathsListener < BaseListener
        PATH_SETTINGS = %i[autoload_paths eager_load_paths autoload_once_paths].to_set.freeze
        APPENDING = %i[<< push append concat].to_set.freeze

        def on_call_node_enter(node)
          return @results << "lib" if node.name == :autoload_lib && node.receiver
          return collect_added_path(node) if node.name == :add && paths_receiver?(node.receiver)
          return unless APPENDING.include?(node.name) && path_setting?(node.receiver)

          Array(node.arguments&.arguments).each { |argument| collect_paths(argument) }
        end

        # `-=` removes a root; only an addition adds one.
        def on_call_operator_write_node_enter(node)
          return unless PATH_SETTINGS.include?(node.read_name) && node.binary_operator == :+

          collect_paths(node.value)
        end

        private

        def paths_receiver?(node)
          node.is_a?(Prism::CallNode) && node.name == :paths
        end

        # `config.paths.add "lib/base", eager_load: true` is railties' own way
        # of adding a root; the same call without those options adds no code.
        def collect_added_path(node)
          arguments = Array(node.arguments&.arguments)
          options = arguments.find { |argument| argument.is_a?(Prism::KeywordHashNode) }
          return unless options && loads_code?(options)

          collect_paths(arguments.first)
        end

        def loads_code?(options)
          options.elements.any? do |element|
            element.is_a?(Prism::AssocNode) &&
              %w[eager_load autoload autoload_once].include?(element.key.slice.delete_suffix(":")) &&
              element.value.is_a?(Prism::TrueNode)
          end
        end

        def path_setting?(node)
          node.is_a?(Prism::CallNode) && PATH_SETTINGS.include?(node.name)
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
