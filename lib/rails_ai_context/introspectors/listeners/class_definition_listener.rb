# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    module Listeners
      # Class definitions with their superclass, in source order.
      # `class Admin::User < ApplicationRecord` →
      #   { name: "Admin::User", superclass: "ApplicationRecord" }
      class ClassDefinitionListener < BaseListener
        def on_class_node_enter(node)
          name = constant_path_string(node.constant_path)
          return if name.empty?

          @results << {
            name:       name,
            superclass: superclass_name(node.superclass),
            location:   node.location.start_line
          }
        end

        private

        # nil for an anonymous or computed superclass (`< Struct.new(:a)`).
        def superclass_name(node)
          return nil unless node.is_a?(Prism::ConstantReadNode) || node.is_a?(Prism::ConstantPathNode)
          name = constant_path_string(node)
          name.empty? ? nil : name
        end
      end
    end
  end
end
