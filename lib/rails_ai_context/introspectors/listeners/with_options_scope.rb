# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    module Listeners
      # ActiveSupport re-sends the calls in a `with_options` block with its options merged in;
      # this tracks the open blocks for `in_scope?` and `scope_options`.
      module WithOptionsScope
        UNNAMED_BLOCK_PARAM = :"*"

        def self.included(base)
          base.prepend(Dispatch)
        end

        # Prepended, so the listener's own handler never sees the call that
        # opened the scope and no listener repeats the guard.
        module Dispatch
          def on_call_node_enter(node)
            with_options_block?(node) ? enter_scope(node) : super
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
            @scopes.push({ node: node, param: hook_param(node), options: {} }) if mixin_hook?(node)
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

        def mixin_hook?(node)
          node.receiver.is_a?(Prism::SelfNode) && ConcernMembership::MIXIN_HOOKS.include?(node.name.to_s) && hook_param(node)
        end

        def hook_param(node)
          first = node.parameters&.requireds&.first
          first.name if first.respond_to?(:name)
        end

        def with_options_block?(node)
          node.name == :with_options && node.block
        end

        def enter_scope(node)
          @scopes.push({ node: node,
                         param: block_param(node.block),
                         options: scope_options(receiver_name(node)).merge(extract_keyword_sources(node)) })
        end

        def leave_scope(node)
          @scopes.pop if with_options_block?(node) && @scopes.last&.fetch(:node)&.equal?(node)
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
