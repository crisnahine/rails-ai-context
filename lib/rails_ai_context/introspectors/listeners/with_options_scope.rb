# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    module Listeners
      # ActiveSupport re-sends the calls in a `with_options` block with its options merged in;
      # this tracks the open blocks for `in_scope?` and `scope_options`.
      module WithOptionsScope
        UNNAMED_BLOCK_PARAM = :"*"
        UNCERTAIN_BLOCK = Object.new.freeze
        # Zero-arity blocks these run on the class itself, state_machines' and aasm's included;
        # any other such block may be evaluated on another object (`has_details_table do`, `Menu.define do`).
        OWN_BLOCKS = %i[with_options included prepended class_methods concerning state_machine state event aasm].to_set.freeze
        EVALS = %i[class_eval class_exec module_eval module_exec instance_eval instance_exec].to_set.freeze

        def self.included(base)
          base.prepend(Dispatch)
        end

        # Whether a block's declarations may belong to another object: it takes no parameters and
        # its call is neither a known one nor an eval on the class. The block answers whether a
        # local names an open mixin hook's class.
        def self.uncertain_block?(node)
          block = node.block
          return false unless block.is_a?(Prism::BlockNode) && block.parameters.nil?
          return !(OWN_BLOCKS.include?(node.name) || EVALS.include?(node.name)) if node.receiver.nil?

          receiver = node.receiver
          if EVALS.include?(node.name)
            own = receiver.is_a?(Prism::SelfNode) || (receiver.is_a?(Prism::LocalVariableReadNode) && block_given? && yield(receiver.name))
            return !own
          end

          # `Menu.define do`, `Class.new do`: a constant's DSL block; `[1].each {}` yields.
          receiver.is_a?(Prism::ConstantReadNode) || receiver.is_a?(Prism::ConstantPathNode)
        end

        # `base` in `def self.included(base)`: the class every includer is.
        def self.hook_param(node)
          return unless node.receiver.is_a?(Prism::SelfNode) && ConcernMembership::MIXIN_HOOKS.include?(node.name.to_s)

          first = node.parameters&.requireds&.first
          first.name if first.respond_to?(:name)
        end

        # Prepended, so the listener's own handler never sees the call that
        # opened the scope and no listener repeats the guard.
        module Dispatch
          def on_call_node_enter(node)
            return enter_scope(node) if with_options_block?(node)

            count = @results.size
            super
            # Kept, and marked so a schema check does not judge them against this class's table.
            @results.drop(count).each { |result| result[:scope_uncertain] = true } if uncertain_scope?
            @scopes.push({ node: node, param: UNCERTAIN_BLOCK, options: {} }) if uncertain_block?(node)
          end

          # `super` where the listener has its own leave hook: swallowing it
          # would drop an event with nothing to show that it had.
          def on_call_node_leave(node)
            leave_scope(node)
            super if defined?(super)
          end

          # `base.has_many` inside `def self.included(base)` declares on every includer,
          # as a `with_options` block's parameter does.
          def on_def_node_enter(node)
            param = WithOptionsScope.hook_param(node)
            @scopes.push({ node: node, param: param, options: {} }) if param
            super if defined?(super)
          end

          def on_def_node_leave(node)
            @scopes.pop if @scopes.last&.fetch(:node)&.equal?(node)
            super if defined?(super)
          end
        end

        def initialize
          super
          @scopes = []
        end

        private

        def with_options_block?(node)
          node.name == :with_options && node.block
        end

        def enter_scope(node)
          @scopes.push({ node: node,
                         param: block_param(node.block),
                         options: scope_options(receiver_name(node)).merge(extract_keyword_sources(node)) })
        end

        def leave_scope(node)
          @scopes.pop if @scopes.last&.fetch(:node)&.equal?(node)
        end

        def uncertain_block?(node)
          WithOptionsScope.uncertain_block?(node) { |name| enclosing_scope(name) }
        end

        def uncertain_scope?
          @scopes.any? { |scope| scope[:param].equal?(UNCERTAIN_BLOCK) }
        end

        # A macro this listener should read: receiverless, or sent to the
        # parameter of an open block.
        def in_scope?(node)
          receiver = receiver_name(node)
          return node.receiver.nil? if receiver.nil?

          !enclosing_scope(receiver).nil?
        end

        # A zero-arity block is instance_eval'd, so it re-sends receiverless
        # calls; nil matches those. UNNAMED matches nothing, for `do |*a|`.
        def block_param(block)
          params = block.parameters&.parameters
          return nil unless params

          first = params.requireds.first
          first.respond_to?(:name) ? first.name : UNNAMED_BLOCK_PARAM
        end

        def scope_options(receiver)
          enclosing_scope(receiver)&.fetch(:options) || {}
        end

        def enclosing_scope(receiver)
          @scopes.reverse_each.find { |scope| scope[:param] == receiver }
        end

        def receiver_name(node)
          node.receiver.name if node.receiver.is_a?(Prism::LocalVariableReadNode)
        end
      end
    end
  end
end
