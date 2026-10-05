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
      class NamespacedRootsListener < AutoloadPathsListener
        def on_call_node_enter(node)
          return unless node.name == :push_dir

          arguments = Array(node.arguments&.arguments)
          @namespace = namespace_of(arguments.find { |argument| argument.is_a?(Prism::KeywordHashNode) })
          collect_paths(arguments.first) if @namespace
        end

        def on_call_operator_write_node_enter(_node); end

        private

        def namespace_of(options)
          pair = options&.elements&.find do |element|
            element.is_a?(Prism::AssocNode) && element.key.is_a?(Prism::SymbolNode) && element.key.unescaped == "namespace"
          end
          value = pair&.value
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
