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
        include LiteralPaths

        PATH_SETTINGS = %i[autoload_paths eager_load_paths autoload_once_paths].to_set.freeze

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
      end
    end
  end
end
