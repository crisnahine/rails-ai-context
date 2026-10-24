# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    module Listeners
      # The owner a record is written in (`@owner_stack`) and Module.nesting there, innermost first (`@owner_nesting`): `class ::Foo` in `module A` stores ["::Foo", "A"].
      module OwnerScope
        def initialize(...)
          super
          @owner_stack = []
          @scope_stack = []
          @owner_nesting = []
          @saved_scopes = []
          @builder_writes = []
          @declared = {}
        end

        # The owner of what an `||=` builder block that never runs holds; its records are dropped.
        UNRUN = Object.new.freeze

        # These evaluate their block in the constant they build.
        CLASS_BUILDERS = { Struct: :new, Class: :new, Module: :new, Data: :define }.freeze

        # `Struct.new(:a) do ... end` and the like: a body for the constant it is assigned to, in no scope of its own.
        def self.builder?(node)
          return false unless node.is_a?(Prism::CallNode) && node.block.is_a?(Prism::BlockNode)

          receiver = node.receiver
          return false unless receiver.is_a?(Prism::ConstantReadNode) || (receiver.is_a?(Prism::ConstantPathNode) && receiver.parent.nil?)

          CLASS_BUILDERS[receiver.name] == node.name
        end

        def results
          super.tap { |records| records.reject! { |record| record.is_a?(Hash) && Array(record[:owner]).any? { |name| name.equal?(UNRUN) } } }
        end

        def on_class_node_enter(node)
          open_owner(node.constant_path.slice, scope: true, superclass: node.superclass)
        end

        def on_class_node_leave(_node)
          close_owner
        end

        def on_module_node_enter(node)
          open_owner(node.constant_path.slice, scope: true)
        end

        def on_module_node_leave(_node)
          close_owner
        end

        def on_constant_write_node_enter(node)
          enter_builder(node, node.name.to_s)
        end

        def on_constant_write_node_leave(node)
          leave_builder(node)
        end

        def on_constant_path_write_node_enter(node)
          enter_builder(node, DeclaredConstant.written(node))
        end

        def on_constant_path_write_node_leave(node)
          leave_builder(node)
        end

        # Ruby runs an `||=`'s right side only while the constant is undefined, so a builder block it never runs owns
        # nothing and holds nothing anyone owns.
        def on_constant_or_write_node_enter(node)
          assigned = DeclaredConstant.assigned?(node, @owner_nesting, @declared)
          return enter_builder(node, DeclaredConstant.written(node)) if assigned

          return unless OwnerScope.builder?(node.value)

          @saved_scopes.push([ @owner_stack, @scope_stack, @owner_nesting ])
          @owner_stack += [ UNRUN ]
          @builder_writes.push(node)
        end
        alias on_constant_path_or_write_node_enter on_constant_or_write_node_enter
        alias on_constant_or_write_node_leave on_constant_write_node_leave
        alias on_constant_path_or_write_node_leave on_constant_write_node_leave

        # A multiple assignment's target defines its constant without running a block in it.
        def on_constant_target_node_enter(node)
          DeclaredConstant.declare_node(node, @owner_nesting, @declared)
        end
        alias on_constant_path_target_node_enter on_constant_target_node_enter

        private

        def open_owner(written, scope:, superclass: nil)
          @saved_scopes.push([ @owner_stack, @scope_stack, @owner_nesting ])
          # A name read from the root keeps its `::`, so a walked slice's nesting reads it from the top level.
          name = DeclaredConstant.declare(written, @owner_nesting, @declared, superclass: superclass)
          # As written inside the scope it nests in, never a builder block, which opens none; whole where Ruby read its
          # first segment elsewhere. Inside a block that never runs, still no one's.
          owner = name == "#{@owner_nesting.first}::#{written}" ? @scope_stack + [ written ] : [ name.delete_prefix("::") ]
          @owner_stack = (@owner_stack.include?(UNRUN) ? [ UNRUN ] : []) + owner
          return unless scope

          @scope_stack = owner
          @owner_nesting = [ name ] + @owner_nesting
        end

        def close_owner
          @owner_stack, @scope_stack, @owner_nesting = @saved_scopes.pop
        end

        def enter_builder(node, name)
          if OwnerScope.builder?(node.value)
            open_owner(name, scope: false)
            @builder_writes.push(node)
          else
            DeclaredConstant.declare(name, @owner_nesting, @declared)
          end
        end

        def leave_builder(node)
          return unless @builder_writes.last.equal?(node)

          @builder_writes.pop
          close_owner
        end
      end
    end
  end
end
