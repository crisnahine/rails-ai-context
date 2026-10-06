# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    module Listeners
      # Roots an app hands Zeitwerk under a namespace, literal paths only:
      #
      #   Rails.autoloaders.main.push_dir(Rails.root.join("app/components"), namespace: Components)
      #     → ["app/components", "Components"]
      #
      # phlex:install writes this, so app/components/base.rb is Components::Base.
      class NamespacedRootsListener < BaseListener
        include LiteralPaths

        def on_call_node_enter(node)
          return unless node.name == :push_dir

          arguments = Array(node.arguments&.arguments)
          @namespace = namespace_of(extract_keyword_nodes(node)[:namespace])
          collect_paths(arguments.first) if @namespace
        end

        private

        def namespace_of(value)
          value.slice.delete_prefix("::") if value.is_a?(Prism::ConstantReadNode) || value.is_a?(Prism::ConstantPathNode)
        end

        def push_path(value)
          cleaned = value.to_s.strip.delete_prefix("/")
          @results << [ cleaned, @namespace ] unless cleaned.empty?
        end
      end
    end
  end
end
