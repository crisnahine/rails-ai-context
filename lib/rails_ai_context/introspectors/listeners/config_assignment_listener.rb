# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    module Listeners
      # Reads settings declared on a config object in an initializer:
      #
      #   config.timeout_in = 30.minutes        → path [:timeout_in], assignment
      #   config.action_mailer.delivery = :smtp → path [:action_mailer, :delivery], assignment
      #   config.jwt do |jwt| ... end           → path [:jwt], not an assignment, write :block
      #   config.hosts << "x"                   → path [:hosts, :<<], write :call
      #   config.headers["X"] = "y"             → path [:headers, :[]=], write :call
      #   config.filter_parameters += [:pin]    → path [:filter_parameters], write :operator
      #
      # The chain is matched from a root receiver name, so
      # `Rails.application.config.assets.paths = x` reports [:assets, :paths].
      class ConfigAssignmentListener < BaseListener
        DEFAULT_ROOTS = %w[config].freeze
        SETTER = /\A[A-Za-z_]\w*=\z/
        # A predicate or comparison with arguments reads a setting rather than changing it.
        MUTATOR = /\A(?:<<|\[\]=|[A-Za-z_]\w*!?)\z/

        def initialize(*roots)
          super()
          names = roots.flatten.map(&:to_s)
          @roots = (names.empty? ? DEFAULT_ROOTS : names).to_set
          @conditions = []
        end

        # The branch an assignment sits in. Rails' own generated
        # `config/environments/development.rb` assigns `perform_caching` in
        # both halves of one `if`, and reporting the first as the value made
        # this tool disagree with the running app.
        def on_if_node_enter(node)
          @conditions.push(condition_text(node.predicate))
        end

        def on_if_node_leave(_node)
          @conditions.pop
        end

        def on_unless_node_enter(node)
          @conditions.push("not #{condition_text(node.predicate)}")
        end

        def on_unless_node_leave(_node)
          @conditions.pop
        end

        def on_else_node_enter(_node)
          @conditions.push("else")
        end

        def on_else_node_leave(_node)
          @conditions.pop
        end

        def on_call_node_enter(node)
          return if node.receiver.nil?

          if node.name.to_s.match?(SETTER)
            record_assignment(node)
          elsif node.arguments
            return unless node.name.to_s.match?(MUTATOR)

            record_write(node.receiver, node.name, :call, node)
          else
            record_reference(node)
          end
        end

        def on_call_operator_write_node_enter(node)
          record_write(node.receiver, node.read_name, :operator, node)
        end

        def on_call_or_write_node_enter(node)
          record_write(node.receiver, node.read_name, :operator, node)
        end

        def on_call_and_write_node_enter(node)
          record_write(node.receiver, node.read_name, :operator, node)
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
            path, value: value, source: value_node && NodeSource.text(value_node)
          )

          @results << {
            path:       path,
            assignment: true,
            value:      redacted[:value],
            source:     redacted[:source],
            condition:  @conditions.compact.last,
            location:   node.location.start_line
          }
        end

        def condition_text(node)
          return nil unless node

          NodeSource.text(node).gsub(/\s+/, " ").strip
        end

        # A bare `config.jwt` reference, with or without a block. Enough to tell
        # that a section of the initializer exists at all.
        def record_reference(node)
          prefix = chain_path(node.receiver)
          return unless prefix

          entry = {
            path:       prefix + [ node.name ],
            assignment: false,
            value:      nil,
            source:     nil,
            location:   node.location.start_line
          }
          entry[:write] = :block if node.block
          @results << entry
        end

        # A setting changed without `=`: a call with arguments or an operator write.
        def record_write(receiver, name, kind, node)
          return if receiver.nil?

          prefix = chain_path(receiver)
          return unless prefix

          @results << {
            path:       prefix + [ name ],
            assignment: false,
            write:      kind,
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
