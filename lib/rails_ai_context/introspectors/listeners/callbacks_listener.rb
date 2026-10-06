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

        def on_call_node_enter(node)
          return record_skip(node) if node.name == :skip_callback && in_scope?(node)
          return unless CALLBACK_METHODS.include?(node.name) && in_scope?(node)

          # Sources, not literals: a lambda condition reads as the line the
          # file holds rather than as a marker.
          options = scope_options(receiver_name(node)).merge(extract_keyword_sources(node))
          emit(node, resolve_callback_types(node.name, options), callback_targets(node), options)
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

        # Rails' skip_callback; the kind defaults to :before, as normalize_callback_params does.
        def record_skip(node)
          positional = (node.arguments&.arguments || []).reject { |a| a.is_a?(Prism::KeywordHashNode) }
          event, *rest = positional.map { |a| literal_string(a) || one_line_source(a) }
          return unless event && literal_string(positional.first)

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

        # Each filter Rails registers, in its order: the block first, then every positional
        # argument. An object (`Normalizer.new`) is kept as written; a lambda names nothing.
        def callback_targets(node)
          positional = (node.arguments&.arguments || []).reject { |a| a.is_a?(Prism::KeywordHashNode) }
          targets = node.block ? [ [ INLINE_BLOCK, RailsAiContext::Confidence::INFERRED ] ] : []
          targets + positional.map do |arg|
            if (name = literal_string(arg)) then [ name, confidence_for(node) ]
            elsif proc_argument?(arg) then [ INLINE_BLOCK, RailsAiContext::Confidence::INFERRED ]
            else [ one_line_source(arg), confidence_for(node) ]
            end
          end
        end

        def emit(node, callback_types, targets, options)
          targets.each do |method_name, confidence|
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
