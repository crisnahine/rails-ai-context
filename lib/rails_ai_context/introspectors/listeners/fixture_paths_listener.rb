# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    module Listeners
      # Fixture directories a test helper sets, literal paths only:
      #
      #   config.fixture_paths = [Rails.root.join("spec/fixtures")]
      #   self.fixture_paths << "#{Rails.root}/test/fixtures/"
      #   self.fixture_path = "#{::Rails.root}/spec/fixtures"
      #
      # The path forms are the autoload listener's, so both read one way. A write
      # whose path it cannot read records :unread, so a caller still knows the setting is set.
      class FixturePathsListener < AutoloadPathsListener
        SETTINGS = %i[fixture_paths fixture_path].to_set.freeze
        ASSIGNING = %i[fixture_paths= fixture_path=].to_set.freeze

        def on_call_node_enter(node)
          if ASSIGNING.include?(node.name)
            return unless setting_receiver?(node.receiver)
          else
            return unless APPENDING.include?(node.name) && fixture_setting?(node.receiver)
          end

          record_write { Array(node.arguments&.arguments).each { |argument| collect_paths(argument) } }
        end

        def on_call_operator_write_node_enter(node)
          return unless SETTINGS.include?(node.read_name) && node.binary_operator == :+ && setting_receiver?(node.receiver)

          record_write { collect_paths(node.value) }
        end

        private

        def record_write
          before = @results.size
          yield
          @results << :unread if @results.size == before
        end

        def fixture_setting?(node)
          node.is_a?(Prism::CallNode) && SETTINGS.include?(node.name) && setting_receiver?(node.receiver)
        end

        # The test case class itself, or RSpec's `config` (the block parameter `RSpec.configure` yields).
        def setting_receiver?(node)
          node.nil? || node.is_a?(Prism::SelfNode) ||
            ((node.is_a?(Prism::CallNode) || node.is_a?(Prism::LocalVariableReadNode)) && node.name == :config)
        end
      end
    end
  end
end
