# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    module Listeners
      # Reads settings declared on a config object in an initializer:
      #
      #   config.timeout_in = 30.minutes        → path [:timeout_in], assignment
      #   config.action_mailer.delivery = :smtp → path [:action_mailer, :delivery], assignment
      #   config.jwt do |jwt| ... end           → path [:jwt], not an assignment
      #
      # The chain is matched from a root receiver name, so
      # `Rails.application.config.assets.paths = x` reports [:assets, :paths].
      class ConfigAssignmentListener < BaseListener
        DEFAULT_ROOTS = %w[config].freeze

        def initialize(*roots)
          super()
          names = roots.flatten.map(&:to_s)
          @roots = (names.empty? ? DEFAULT_ROOTS : names).to_set
        end

        def on_call_node_enter(node)
          return if node.receiver.nil?

          if node.name.to_s.end_with?("=")
            record_assignment(node)
          else
            record_reference(node)
          end
        end

        private

        def record_assignment(node)
          prefix = chain_path(node.receiver)
          return unless prefix

          value_node = node.arguments&.arguments&.first
          @results << {
            path:       prefix + [ node.name.to_s.delete_suffix("=").to_sym ],
            assignment: true,
            value:      value_node ? extract_value(value_node) : nil,
            source:     value_node&.slice,
            location:   node.location.start_line
          }
        end

        # A bare `config.jwt` reference, with or without a block. Enough to tell
        # that a section of the initializer exists at all.
        def record_reference(node)
          return unless node.arguments.nil?

          prefix = chain_path(node.receiver)
          return unless prefix

          @results << {
            path:       prefix + [ node.name ],
            assignment: false,
            value:      nil,
            source:     nil,
            location:   node.location.start_line
          }
        end

        # Returns the path segments after the root, or nil when the chain is not
        # rooted at a configured root name.
        def chain_path(node)
          parts = []
          current = node

          while current
            case current
            when Prism::CallNode
              return nil unless current.arguments.nil? && current.block.nil?
              parts.unshift(current.name)
              current = current.receiver
            when Prism::LocalVariableReadNode
              parts.unshift(current.name)
              current = nil
            when Prism::ConstantReadNode, Prism::ConstantPathNode
              parts.unshift(constant_path_string(current).to_sym)
              current = nil
            else
              return nil
            end
          end

          root_index = parts.rindex { |part| @roots.include?(part.to_s) }
          return nil unless root_index

          parts[(root_index + 1)..] || []
        end
      end
    end
  end
end
