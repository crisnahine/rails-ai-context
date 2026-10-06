# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    module Listeners
      # Locale files an app adds to I18n's load path, literal paths and globs only:
      #
      #   config.i18n.load_path += Dir[Rails.root.join("my/locales/*.{rb,yml}")] → "my/locales/*.{rb,yml}"
      #   I18n.load_path << "#{Rails.root}/lib/locales/de.yml"                   → "lib/locales/de.yml"
      #   config.i18n.load_path = Dir[Rails.root.join("x/*.yml")]                → "x/*.yml"
      #
      # The path forms are the autoload listener's, plus the Dir[] / Dir.glob wrapper.
      class I18nLoadPathListener < BaseListener
        include LiteralPaths

        def on_call_node_enter(node)
          if node.name == :load_path= && i18n?(node.receiver)
            collect_paths(node.arguments&.arguments&.first)
          elsif APPENDING.include?(node.name) && load_path?(node.receiver)
            Array(node.arguments&.arguments).each { |argument| collect_paths(argument) }
          end
        end

        def on_call_operator_write_node_enter(node)
          return unless node.binary_operator == :+ && node.read_name == :load_path && i18n?(node.receiver)

          collect_paths(node.value)
        end

        private

        def load_path?(node)
          node.is_a?(Prism::CallNode) && node.name == :load_path && i18n?(node.receiver)
        end

        def i18n?(node)
          case node
          when Prism::CallNode then node.name == :i18n
          when Prism::ConstantReadNode, Prism::ConstantPathNode then node.slice.delete_prefix("::") == "I18n"
          else false
          end
        end

        def collect_call_path(node)
          if %i[[] glob].include?(node.name) && node.receiver&.slice&.delete_prefix("::") == "Dir"
            return collect_paths(node.arguments&.arguments&.first)
          end

          super
        end
      end
    end
  end
end
