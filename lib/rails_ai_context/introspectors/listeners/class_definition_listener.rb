# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    module Listeners
      # Class definitions with their superclass, in source order.
      # `class Admin::User < ApplicationRecord` →
      #   { name: "Admin::User", superclass: "ApplicationRecord" }
      #
      # `nesting` is Module.nesting where the superclass is read, innermost
      # first, as DeclaredConstant::Declaration carries it: empty at the top
      # level, for a compact `class Admin::User`, and for a `< ::Base`.
      class ClassDefinitionListener < BaseListener
        def initialize
          super
          @nestings = [ [] ]
        end

        def on_class_node_enter(node)
          name = constant_path_string(node.constant_path)
          unless name.empty?
            rooted = node.superclass&.slice&.start_with?("::")
            @results << {
              name:       name,
              superclass: superclass_name(node.superclass),
              location:   node.location.start_line,
              nesting:    rooted ? [] : @nestings.last
            }
          end
          enter_scope(node)
        end

        def on_class_node_leave(_node)
          @nestings.pop
        end

        def on_module_node_enter(node)
          enter_scope(node)
        end

        def on_module_node_leave(_node)
          @nestings.pop
        end

        def on_constant_write_node_enter(node)
          declare_constant(node, @nestings.last)
        end
        CONSTANT_WRITE_EVENTS.each { |event| alias_method event, :on_constant_write_node_enter }

        private

        def enter_scope(node)
          outer = @nestings.last
          @nestings.push([ declare_constant(node, outer) ] + outer)
        end

        # nil for an anonymous or computed superclass (`< Struct.new(:a)`).
        def superclass_name(node)
          return nil unless node.is_a?(Prism::ConstantReadNode) || node.is_a?(Prism::ConstantPathNode)

          constant_path_string(node)
        end
      end
    end
  end
end
