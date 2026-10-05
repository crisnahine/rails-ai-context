# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    module Listeners
      # Detects ActiveRecord callback declarations via Prism AST:
      # before_validation, after_save, after_commit, etc.
      class CallbacksListener < BaseListener
        include WithOptionsScope
        include OwnerScope

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
          return record_skip(node) if node.name == :skip_callback && in_scope?(node)
          return unless CALLBACK_METHODS.include?(node.name) && in_scope?(node)

          # Sources, not literals: a lambda condition reads as the line the
          # file holds rather than as a marker.
          options = scope_options(receiver_name(node)).merge(extract_keyword_sources(node))
          callback_types = resolve_callback_types(node.name, options)
          methods = extract_symbol_args(node)

          if methods.any?
            emit(node, callback_types, methods.map(&:to_s), options, confidence_for(node))
          else
            emit_without_symbol_args(node, callback_types, options)
          end
        end

        ON_EVENT = "after_commit_on_"

        # Every commit spelling lands in the one after-commit kind of one chain.
        def self.chain_key(type)
          type.to_s.match?(/\Aafter_(\w+_)?commit/) ? "after_commit" : type.to_s
        end

        def self.transaction?(type)
          type.to_s.match?(/\Aafter_(\w+_)?(commit|rollback)/)
        end

        def self.after?(type)
          type.to_s.start_with?("after_")
        end

        # `after_commit on: :create` resolves to a type that names its event.
        def self.names_event?(type)
          type.to_s.start_with?(ON_EVENT)
        end

        # The event such a type names, `"create"`, or nil.
        def self.event(type)
          type.to_s.delete_prefix(ON_EVENT) if names_event?(type)
        end

        private

        KINDS = %w[before after around].freeze

        # `skip_callback :save, :before, :stamp_audit` takes a callback the
        # class inherited (or declared above) out of its chain; the model
        # tier applies it where the chain is assembled. The kind defaults to
        # :before, as Rails' normalize_callback_params does.
        def record_skip(node)
          event, *rest = extract_symbol_args(node).map(&:to_s)
          return unless event

          kind = KINDS.include?(rest.first) ? rest.shift : "before"
          options = scope_options(receiver_name(node)).merge(extract_keyword_sources(node))
          rest.each do |method_name|
            @results << {
              name:       "skip_callback",
              type:       "#{kind}_#{event}",
              method:     method_name,
              skip:       true,
              options:    options,
              owner:      @owner_stack.dup,
              location:   node.location.start_line,
              confidence: confidence_for(node)
            }
          end
        end

        # `around_create Snowflake::Callbacks` names a real target;
        # a lambda names nothing, so it reports as a block.
        def emit_without_symbol_args(node, callback_types, options)
          positional = extract_arg_values(node).map(&:to_s)
          targets = positional.grep(NAME_SHAPED)

          if targets.any?
            emit(node, callback_types, targets, options, confidence_for(node))
          elsif node.block || positional.any?
            # Keyword options are not a target: `after_commit on: :create`
            # declares no block, so there is none to report.
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
                owner:      @owner_stack.dup,
                location:   node.location.start_line,
                confidence: confidence
              }
            end
          end
        end

        # `after_commit on: :create` is the after_commit_on_create type. One
        # declaration for several events stays one callback, its on: kept.
        def resolve_callback_types(name, options)
          events = Array(options[:on])
          name == :after_commit && events.one? ? [ "#{ON_EVENT}#{events.first}" ] : [ name.to_s ]
        end
      end
    end
  end
end
