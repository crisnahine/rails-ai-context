# frozen_string_literal: true

require "pathname"

module RailsAiContext
  module Introspectors
    module Listeners
      # Fixture directories a test helper sets, literal paths only:
      #
      #   config.fixture_paths = [Rails.root.join("spec/fixtures")]
      #   self.fixture_paths << "#{Rails.root}/test/fixtures/"
      #   self.fixture_path = "#{::Rails.root}/spec/fixtures"
      #   ActiveSupport::TestCase.fixture_paths << File.expand_path("../extra_fx", __dir__)
      #
      # A path built from __dir__ or __FILE__ is read only when the walk is given the helper's
      # `file`, relative to the app root.
      # The path forms are the autoload listener's, so both read one way. A write
      # whose path it cannot read records :unread, so a caller still knows the setting is set.
      class FixturePathsListener < BaseListener
        include LiteralPaths

        SETTINGS = %i[fixture_paths fixture_path].to_set.freeze
        ASSIGNING = %i[fixture_paths= fixture_path=].to_set.freeze

        def initialize(file: nil)
          super()
          @file = file
        end

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

        def collect_call_path(node)
          return super unless @file && node.receiver.is_a?(Prism::ConstantReadNode) && node.receiver.name == :File

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
          return unless rest.any? && rest.all? { |argument| argument.is_a?(Prism::StringNode) }

          Pathname.new(File.join(anchor, *rest.map(&:unescaped))).cleanpath.to_s
        end

        # `File.expand_path("x", __FILE__)` resolves against the file name itself, as Ruby does.
        def file_anchor(node)
          case node
          when Prism::SourceFileNode then @file
          when Prism::CallNode then File.dirname(@file) if node.name == :__dir__ && node.receiver.nil?
          end
        end

        def record_write
          before = @results.size
          yield
          @results << :unread if @results.size == before
        end

        def fixture_setting?(node)
          node.is_a?(Prism::CallNode) && SETTINGS.include?(node.name) && setting_receiver?(node.receiver)
        end

        # The test case class itself, named or as self, or RSpec's `config` (the block parameter `RSpec.configure` yields).
        def setting_receiver?(node)
          node.nil? || node.is_a?(Prism::SelfNode) || node.is_a?(Prism::ConstantReadNode) || node.is_a?(Prism::ConstantPathNode) ||
            ((node.is_a?(Prism::CallNode) || node.is_a?(Prism::LocalVariableReadNode)) && node.name == :config)
        end
      end
    end
  end
end
