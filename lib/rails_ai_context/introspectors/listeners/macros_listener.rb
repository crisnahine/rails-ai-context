# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    module Listeners
      # Detects Rails model macro calls via Prism AST:
      # has_secure_password, encrypts, normalizes, delegate, serialize,
      # store, has_one_attached, has_many_attached, has_rich_text,
      # broadcasts, generates_token_for, attribute, etc.
      class MacrosListener < BaseListener
        SIMPLE_MACROS = %i[
          has_secure_password
        ].to_set.freeze

        ATTRIBUTE_MACROS = %i[
          encrypts normalizes has_one_attached has_many_attached
          has_rich_text generates_token_for serialize store store_accessor
        ].to_set.freeze

        BROADCAST_MACROS = %i[
          broadcasts broadcasts_to broadcasts_refreshes_to
        ].to_set.freeze

        def on_call_node_enter(node)
          return unless node.receiver.nil?

          if SIMPLE_MACROS.include?(node.name)
            @results << {
              macro:      node.name,
              location:   node.location.start_line,
              confidence: confidence_for(node)
            }
          elsif ATTRIBUTE_MACROS.include?(node.name)
            extract_attribute_macro(node)
          elsif BROADCAST_MACROS.include?(node.name)
            extract_broadcast_macro(node)
          elsif node.name == :delegate
            extract_delegate(node)
          elsif node.name == :delegate_missing_to
            extract_delegate_missing_to(node)
          elsif node.name == :attribute
            extract_attribute_api(node)
          end
        end

        private

        def extract_attribute_macro(node)
          attrs   = extract_symbol_args(node)
          options = extract_keyword_options(node)

          attrs.each do |attr_name|
            @results << {
              macro:      node.name,
              attribute:  attr_name.to_s,
              options:    options,
              location:   node.location.start_line,
              confidence: confidence_for(node)
            }
          end
        end

        def extract_broadcast_macro(node)
          target = extract_symbol_args(node).first
          @results << {
            macro:      node.name,
            target:     target&.to_s,
            location:   node.location.start_line,
            confidence: confidence_for(node)
          }
        end

        def extract_delegate(node)
          methods = extract_symbol_args(node)
          options = extract_keyword_options(node)
          target  = options[:to]

          @results << {
            macro:      :delegate,
            methods:    methods.map(&:to_s),
            to:         target&.to_s,
            options:    options.except(:to),
            location:   node.location.start_line,
            confidence: confidence_for(node)
          }
        end

        def extract_delegate_missing_to(node)
          target = extract_first_symbol(node)
          @results << {
            macro:      :delegate_missing_to,
            to:         target.to_s,
            location:   node.location.start_line,
            confidence: confidence_for(node)
          }
        end

        def extract_attribute_api(node)
          args    = node.arguments&.arguments || []
          return if args.empty?

          name_arg = args.first
          return unless name_arg.is_a?(Prism::SymbolNode)

          type_arg = args[1]
          type = case type_arg
          when Prism::SymbolNode then type_arg.value
          end

          options = extract_keyword_options(node)

          @results << {
            macro:      :attribute,
            attribute:  name_arg.value,
            type:       type,
            options:    options,
            location:   node.location.start_line,
            confidence: confidence_for(node)
          }
        end
      end
    end
  end
end
