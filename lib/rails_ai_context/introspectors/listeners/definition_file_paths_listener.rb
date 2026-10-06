# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    module Listeners
      # Where a test helper points factory_bot, literal paths only:
      #
      #   FactoryBot.definition_file_paths = %w[custom/factories]  → { replace: true, paths: ["custom/factories"] }
      #   FactoryBot.definition_file_paths << "lib/factories"      → { replace: false, paths: ["lib/factories"] }
      #   FactoryBot.find_definitions / FactoryBot.reload           → { load: :find_definitions } / { load: :reload }
      #
      # The path forms are LiteralPaths'; a write whose paths it cannot read records `unread: true`.
      class DefinitionFilePathsListener < BaseListener
        include LiteralPaths

        LOADS = %i[find_definitions reload].freeze

        def initialize(file: nil)
          super()
          @file = file
        end

        def on_call_node_enter(node)
          if LOADS.include?(node.name) && factory_bot?(node.receiver)
            @results << { load: node.name }
          elsif node.name == :definition_file_paths= && factory_bot?(node.receiver)
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

        def record(replace)
          before = @results.size
          yield
          paths = @results.slice!(before..)
          @results << (paths.any? ? { replace: replace, paths: paths } : { replace: replace, paths: [], unread: true })
        end

        def setting?(node)
          node.is_a?(Prism::CallNode) && node.name == :definition_file_paths && factory_bot?(node.receiver)
        end

        def factory_bot?(node)
          case node
          when Prism::ConstantReadNode then node.name == :FactoryBot
          when Prism::ConstantPathNode then node.parent.nil? && node.name == :FactoryBot
          else false
          end
        end
      end
    end
  end
end
