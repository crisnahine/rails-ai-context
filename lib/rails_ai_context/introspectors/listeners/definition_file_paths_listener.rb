# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    module Listeners
      # Where a test helper points factory_bot, literal paths only:
      #
      #   FactoryBot.definition_file_paths = %w[custom/factories]  → { replace: true, paths: ["custom/factories"] }
      #   FactoryBot.definition_file_paths << "lib/factories"      → { replace: false, paths: ["lib/factories"] }
      #
      # The path forms are the autoload listener's.
      class DefinitionFilePathsListener < AutoloadPathsListener
        def on_call_node_enter(node)
          if node.name == :definition_file_paths= && factory_bot?(node.receiver)
            record(true) { collect_arguments(node) }
          elsif APPENDING.include?(node.name) && setting?(node.receiver)
            record(false) { collect_arguments(node) }
          end
        end

        def on_call_operator_write_node_enter(node)
          return unless node.read_name == :definition_file_paths && node.binary_operator == :+ && factory_bot?(node.receiver)

          record(false) { collect_paths(node.value) }
        end

        private

        def collect_arguments(node)
          Array(node.arguments&.arguments).each { |argument| collect_paths(argument) }
        end

        # A replacement whose paths it cannot read is left out, so the defaults stand.
        def record(replace)
          before = @results.size
          yield
          paths = @results.slice!(before..)
          @results << { replace: replace, paths: paths } if paths.any?
        end

        def setting?(node)
          node.is_a?(Prism::CallNode) && node.name == :definition_file_paths && factory_bot?(node.receiver)
        end

        def factory_bot?(node)
          node.is_a?(Prism::ConstantReadNode) && node.name == :FactoryBot
        end
      end
    end
  end
end
