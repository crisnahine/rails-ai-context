# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    module Listeners
      # ViewComponent preview directories an app sets, literal paths only:
      #
      #   config.view_component.previews.paths += [Rails.root.join("lookbook/previews").to_s]
      #   config.view_component.preview_paths << "#{Rails.root}/spec/previews"
      #
      # The path forms are the autoload listener's, so both read one way.
      class PreviewPathsListener < AutoloadPathsListener
        ASSIGNING = %i[preview_paths= preview_path= paths=].to_set.freeze

        def on_call_node_enter(node)
          if ASSIGNING.include?(node.name)
            return unless preview_target?(node.name.to_s.delete_suffix("=").to_sym, node.receiver)
          else
            return unless APPENDING.include?(node.name) && node.receiver.is_a?(Prism::CallNode)
            return unless preview_target?(node.receiver.name, node.receiver.receiver)
          end

          Array(node.arguments&.arguments).each { |argument| collect_paths(argument) }
        end

        def on_call_operator_write_node_enter(node)
          return unless node.binary_operator == :+ && preview_target?(node.read_name, node.receiver)

          collect_paths(node.value)
        end

        private

        # `preview_paths` / `preview_path` on view_component, or `paths` on
        # its `previews`.
        def preview_target?(name, receiver)
          return false unless receiver.is_a?(Prism::CallNode)

          case name
          when :preview_paths, :preview_path then receiver.name == :view_component
          when :paths then receiver.name == :previews
          else false
          end
        end
      end
    end
  end
end
