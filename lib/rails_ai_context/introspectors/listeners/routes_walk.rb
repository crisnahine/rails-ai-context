# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    module Listeners
      # What both routes listeners track as the walk goes: the constants the file writes, Module.nesting, and the
      # calls made on the mapper a `tap { |m| }`, `then` or `yield_self` block hands its parameter.
      module RoutesWalk
        def initialize(...)
          super
          @nesting = []
          @constants = {}
          @blocks = []
          @mapper_blocks = {}.compare_by_identity
          @mapper_calls = Set.new.compare_by_identity
          @constant_writes = Set.new.compare_by_identity
        end

        def on_constant_write_node_enter(node)
          record_constant(node)
        end
        BaseListener::CONSTANT_WRITE_EVENTS.each { |event| alias_method event, :on_constant_write_node_enter }

        def on_module_node_enter(node)
          @nesting.unshift(declare_constant(node, @nesting))
        end

        def on_module_node_leave(_node)
          @nesting.shift
        end
        alias_method :on_class_node_enter, :on_module_node_enter
        alias_method :on_class_node_leave, :on_module_node_leave

        # The scopes Prism counts a local's depth in.
        def on_block_node_enter(node)
          @blocks.push(node)
        end

        def on_block_node_leave(_node)
          @blocks.pop
        end
        alias_method :on_lambda_node_enter, :on_block_node_enter
        alias_method :on_lambda_node_leave, :on_block_node_leave

        # Walks on in a replayed body's scopes under the site's branches, then its own not already stated.
        def enter_replay(blocks, conditions)
          site = branch_conditions
          walking_in = [ @blocks, site ]
          stated = site.map { |c| branch_text(c) }
          @blocks = blocks.dup
          @branch_conditions = site + conditions.reject { |c| stated.include?(branch_text(c)) }
          walking_in
        end

        def leave_replay(walking_in)
          @blocks, @branch_conditions = walking_in
        end

        private

        # Whether the mapper answers a call: one with no receiver, or one on a mapper block's parameter.
        def mapper_call?(node)
          node.receiver.nil? || @mapper_calls.include?(node)
        end

        # Run as the walk enters each call, where the call's local reads count their depth from.
        # shortcut: a parameter reassigned in the block still reads as the mapper, check the writes if a routes file ever does.
        def note_mapper_call(node)
          @mapper_calls << node if mapper_parameter?(node.receiver)
          return unless node.block.is_a?(Prism::BlockNode) && BaseListener::RUN_ONCE.include?(node.name)
          return unless node.receiver.is_a?(Prism::SelfNode) || mapper_call?(node)

          name = mapper_parameter_name(node.block.parameters)
          @mapper_blocks[node.block] = name if name
        end

        def mapper_parameter?(receiver)
          name, depth = case receiver
          when Prism::ItLocalVariableReadNode then [ :it, 0 ]
          when Prism::LocalVariableReadNode then [ receiver.name, receiver.depth ]
          end
          !name.nil? && depth < @blocks.size && @mapper_blocks[@blocks[-1 - depth]] == name
        end

        # The parameter Ruby hands a lone yielded value: a required one before or after the others, else an optional one.
        def mapper_parameter_name(params)
          case params
          when Prism::NumberedParametersNode then :_1
          when Prism::ItParametersNode then :it
          when Prism::BlockParametersNode
            list = params.parameters
            first = list && (list.requireds.first || list.posts.first || list.optionals.first)
            first.name if first.is_a?(Prism::RequiredParameterNode) || first.is_a?(Prism::OptionalParameterNode)
          end
        end

        # Ruby reads a constant the walked file assigns once as that value; one assigned twice (as in both arms of an
        # if), a multiple assignment's target, or one never assigned is left as written. A replayed body writes it once.
        def record_constant(node)
          return unless @constant_writes.add?(node)

          name = declare_constant(node, @nesting) or return
          @constants[name] = @constants.key?(name) || !node.respond_to?(:value) ? nil : written_value(node.value)
        end
      end
    end
  end
end
