# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    module Listeners
      # Detects ActiveRecord callback declarations via Prism AST:
      # before_validation, after_save, after_commit, etc.
      class CallbacksListener < BaseListener
        CALLBACK_METHODS = %i[
          before_validation after_validation
          before_save after_save around_save
          before_create after_create around_create
          before_update after_update around_update
          before_destroy after_destroy around_destroy
          after_commit after_rollback
          after_create_commit after_update_commit after_destroy_commit
          after_save_commit
        ].to_set.freeze

        def on_call_node_enter(node)
          return unless CALLBACK_METHODS.include?(node.name) && node.receiver.nil?

          methods = extract_symbol_args(node)
          options = extract_keyword_options(node)

          callback_types = resolve_callback_types(node.name, options)

          methods.each do |method_name|
            callback_types.each do |callback_type|
              @results << {
                type:       callback_type,
                method:     method_name.to_s,
                options:    options,
                location:   node.location.start_line,
                confidence: confidence_for(node)
              }
            end
          end

          # Handle inline block callbacks (no symbol arg)
          if methods.empty? && node.block
            callback_types.each do |callback_type|
              @results << {
                type:       callback_type,
                method:     "[inline_block]",
                options:    options,
                location:   node.location.start_line,
                confidence: RailsAiContext::Confidence::INFERRED
              }
            end
          end
        end

        private

        # Resolve after_commit with on: option to specific types.
        # Returns an array of type strings — one per event.
        def resolve_callback_types(name, options)
          if name == :after_commit && options[:on]
            events = Array(options[:on])
            events.map { |e| "after_commit_on_#{e}" }
          else
            [ name.to_s ]
          end
        end
      end
    end
  end
end
