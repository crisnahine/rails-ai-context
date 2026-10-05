# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    module Listeners
      # View roots an app adds to config.paths["app/views"], literal paths only,
      # each tagged with which side of app/views Rails searches it from:
      #
      #   config.paths["app/views"].unshift(Rails.root.join("app/views/custom").to_s) → [:prepend, "app/views/custom"]
      #   config.paths["app/views"] << "enterprise/app/views"                         → [:append, "enterprise/app/views"]
      class ViewPathsListener < AutoloadPathsListener
        def on_call_node_enter(node)
          direction = node.name == :unshift ? :prepend : (:append if APPENDING.include?(node.name))
          return unless direction && views_path?(node.receiver)

          @direction = direction
          Array(node.arguments&.arguments).each { |argument| collect_paths(argument) }
        end

        def on_call_operator_write_node_enter(_node); end

        private

        def views_path?(node)
          return false unless node.is_a?(Prism::CallNode) && node.name == :[] && paths_receiver?(node.receiver)

          key = node.arguments&.arguments&.first
          key.is_a?(Prism::StringNode) && key.unescaped == "app/views"
        end

        def push_path(value)
          cleaned = value.to_s.strip.delete_prefix("/")
          @results << [ @direction, cleaned ] unless cleaned.empty?
        end
      end
    end
  end
end
