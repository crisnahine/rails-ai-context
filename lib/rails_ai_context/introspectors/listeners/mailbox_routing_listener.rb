# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    module Listeners
      class MailboxRoutingListener < BaseListener
        LIFECYCLE_CALLBACKS = %i[
          before_processing after_processing around_processing
        ].to_set.freeze

        def on_call_node_enter(node)
          return unless node.receiver.nil?

          if node.name == :routing
            extract_routing(node)
          elsif LIFECYCLE_CALLBACKS.include?(node.name)
            extract_callback(node)
          end
        end

        private

        def extract_routing(node)
          args = node.arguments&.arguments || []
          args.each do |arg|
            case arg
            when Prism::KeywordHashNode, Prism::HashNode
              arg.elements.each do |assoc|
                next unless assoc.is_a?(Prism::AssocNode)
                pattern = node_source(assoc.key)
                action = extract_value(assoc.value)
                @results << {
                  type:     :routing,
                  pattern:  pattern,
                  action:   action.to_s,
                  location: node.location.start_line
                }
              end
            end
          end
        end

        def extract_callback(node)
          methods = extract_symbol_args(node)
          methods.each do |method|
            @results << {
              type:          :callback,
              callback_type: node.name.to_s,
              method:        method.to_s,
              location:      node.location.start_line
            }
          end
        end

        def node_source(node)
          node.slice
        rescue
          RailsAiContext::Confidence::INFERRED
        end
      end
    end
  end
end
