# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    module Listeners
      # The class or module a record is written in, so a nested class's
      # declarations stay its own. `Sib = Class.new(Base) do` opens Sib.
      module OwnerScope
        def initialize
          super
          @owner_stack = []
          @class_new_writes = []
        end

        def on_class_node_enter(node)
          @owner_stack.push(constant_path_string(node.constant_path))
        end

        def on_class_node_leave(_node)
          @owner_stack.pop
        end

        def on_module_node_enter(node)
          @owner_stack.push(constant_path_string(node.constant_path))
        end

        def on_module_node_leave(_node)
          @owner_stack.pop
        end

        def on_constant_write_node_enter(node)
          enter_class_new(node, node.name.to_s)
        end

        def on_constant_write_node_leave(node)
          leave_class_new(node)
        end

        def on_constant_path_write_node_enter(node)
          enter_class_new(node, node.target.slice)
        end

        def on_constant_path_write_node_leave(node)
          leave_class_new(node)
        end

        private

        def enter_class_new(node, name)
          value = node.value
          return unless value.is_a?(Prism::CallNode) && value.name == :new && value.block &&
                        value.receiver.is_a?(Prism::ConstantReadNode) && value.receiver.name == :Class

          @owner_stack.push(name)
          @class_new_writes.push(node)
        end

        def leave_class_new(node)
          return unless @class_new_writes.last.equal?(node)

          @class_new_writes.pop
          @owner_stack.pop
        end
      end
    end
  end
end
