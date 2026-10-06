# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    module Listeners
      class GenericMacroListener < BaseListener
        # `any_receiver` also counts `base.macro`, the shape a mixin's `self.included(base)` hook writes.
        def initialize(*target_methods, block_source: [], call_source: [], any_receiver: false)
          super()
          @any_receiver = any_receiver
          @target_methods = target_methods.flatten.map(&:to_sym).to_set
          @enclosing = []
          @block_source = block_source.to_set
          @call_source = call_source.to_set
        end

        def on_call_node_enter(node)
          return unless @any_receiver || node.receiver.nil? || node.receiver.is_a?(Prism::SelfNode)
          return unless @target_methods.include?(node.name)

          @results << {
            macro:         node.name,
            args:          extract_symbol_args(node),
            values:        extract_arg_values(node),
            options:       extract_keyword_options(node),
            option_values: extract_keyword_sources(node),
            option_nodes:  extract_keyword_nodes(node),
            block:         (one_line_source(node.block) if node.block.is_a?(Prism::BlockNode) && @block_source.include?(node.name)),
            # Where a block or a lambda argument opens: the line Proc#source_location gives.
            proc_lines:    proc_lines(node),
            # Offsets, not line numbers: a one-line block puts the parent and
            # its nested calls on one line, and a consumer pairing them by
            # line then attaches the second child to the first.
            offset:        node.location.start_offset,
            end_offset:    node.location.end_offset,
            parent_offset: @enclosing.last&.location&.start_offset,
            location:      node.location.start_line,
            confidence:    confidence_for(node)
          }
          @results.last[:text] = one_line_source(node) if @call_source.include?(node.name)
          condition = macro_condition
          @results.last[:condition] = condition if condition

          # A target macro that takes a block encloses whatever the block
          # declares: `string :title` inside `hash :order_params do ... end`
          # is a key of that hash, not a second filter of the class.
          @enclosing.push(node) if node.block
        end

        def on_call_node_leave(node)
          @enclosing.pop if @enclosing.last.equal?(node)
        end

        private

        def macro_condition; end

        # A def evaluates to its name, which is what `helper_method def foo` passes.
        def extract_symbol_args(node)
          Array(node.arguments&.arguments).filter_map { |arg| arg.is_a?(Prism::DefNode) ? arg.name : literal_string(arg)&.to_sym }
        end

        def proc_lines(node)
          procs = Array(node.arguments&.arguments).grep(Prism::LambdaNode)
          procs << node.block if node.block.is_a?(Prism::BlockNode)
          procs.map { |found| found.location.start_line }
        end
      end
    end
  end
end
