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
          setting = node.name.to_s.delete_suffix("=").to_sym

          # Redacted here rather than by each consumer: an initializer's
          # `config.secret_key = "..."` is a real credential, and a new reader
          # of this listener is safe without remembering anything.
          value = value_node ? extract_value(value_node) : nil
          # The whole path, not the leaf: `primary_key` is ordinary
          # ActiveRecord vocabulary, and only `active_record.encryption`
          # around it says the value is a credential.
          path = prefix + [ setting ]

          # One decision for both fields, or a reader pattern-matching the
          # marker finds it on one and the datum on the other.
          redacted = RailsAiContext::Redaction.redact_assignment(
            path, value: value, source: value_node&.slice
          )

          @results << {
            path:       path,
            assignment: true,
            value:      redacted[:value],
            source:     redacted[:source],
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
