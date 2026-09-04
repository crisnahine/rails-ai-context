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
          after_touch after_initialize after_find
        ].to_set.freeze

        INLINE_BLOCK = "[inline_block]"
        NAME_SHAPED = /\A[A-Za-z_]\w*(::[A-Za-z_]\w*)*[?!]?\z/

        def on_call_node_enter(node)
          return unless CALLBACK_METHODS.include?(node.name) && node.receiver.nil?

          options = extract_keyword_options(node)
          callback_types = resolve_callback_types(node.name, options)
          methods = extract_symbol_args(node)

          if methods.any?
            emit(node, callback_types, methods.map(&:to_s), options, confidence_for(node))
          else
            emit_without_symbol_args(node, callback_types, options)
          end
        end

        private

        # `around_create Mastodon::Snowflake::Callbacks` names a real target
        # and was dropped entirely; a lambda names nothing and its source
        # slice spans lines, so it reports as a block like `after_create do`.
        def emit_without_symbol_args(node, callback_types, options)
          targets = extract_arg_values(node).map(&:to_s).grep(NAME_SHAPED)

          if targets.any?
            emit(node, callback_types, targets, options, confidence_for(node))
          elsif node.block || node.arguments
            emit(node, callback_types, [ INLINE_BLOCK ], options, RailsAiContext::Confidence::INFERRED)
          end
        end

        def emit(node, callback_types, methods, options, confidence)
          methods.each do |method_name|
            callback_types.each do |callback_type|
              @results << {
                # The declared macro, so a renderer can print what the file
                # says instead of the resolved type.
                name:       node.name.to_s,
                type:       callback_type,
                method:     method_name,
                options:    options,
                location:   node.location.start_line,
                confidence: confidence
              }
            end
          end
        end

        # Resolve after_commit with on: option to specific types.
        # Returns an array of type strings - one per event.
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
