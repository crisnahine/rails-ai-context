# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    module Listeners
      # Detects Rails model macro calls via Prism AST:
      # has_secure_password, encrypts, normalizes, delegate, serialize,
      # store, has_one_attached, has_many_attached, has_rich_text,
      # broadcasts, generates_token_for, attribute, etc.
      class MacrosListener < BaseListener
        include WithOptionsScope

        SIMPLE_MACROS = %i[
          has_secure_password
        ].to_set.freeze

        ATTRIBUTE_MACROS = %i[
          encrypts normalizes has_one_attached has_many_attached
          has_rich_text generates_token_for serialize
        ].to_set.freeze

        STORE_MACROS = %i[store store_accessor].to_set.freeze

        BROADCAST_MACROS = %i[
          broadcasts broadcasts_to broadcasts_refreshes_to
        ].to_set.freeze

        def on_call_node_enter(node)
          return record_ignored_columns(node, :assign) if node.name == :ignored_columns= && node.receiver.is_a?(Prism::SelfNode)
          return unless in_scope?(node)

          if SIMPLE_MACROS.include?(node.name)
            @results << {
              macro:      node.name,
              location:   node.location.start_line,
              confidence: confidence_for(node)
            }
          elsif ATTRIBUTE_MACROS.include?(node.name)
            extract_attribute_macro(node)
          elsif STORE_MACROS.include?(node.name)
            extract_store(node)
          elsif BROADCAST_MACROS.include?(node.name)
            extract_broadcast_macro(node)
          elsif node.name == :delegate
            extract_delegate(node)
          elsif node.name == :delegate_missing_to
            extract_delegate_missing_to(node)
          elsif node.name == :attribute
            extract_attribute_api(node)
          elsif node.name == :alias_attribute
            extract_alias_attribute(node)
          elsif node.name == :has_secure_token
            extract_secure_token(node)
          elsif node.name == :accepts_nested_attributes_for
            extract_nested_attributes(node)
          end
        end

        # self.ignored_columns += [...] and -= [...]
        def on_call_operator_write_node_enter(node)
          return unless node.read_name == :ignored_columns && node.receiver.is_a?(Prism::SelfNode)

          op = { :+ => :add, :- => :remove }[node.binary_operator]
          record_ignored_columns(node, op) if op
        end

        private

        def record_ignored_columns(node, op)
          value = node.is_a?(Prism::CallNode) ? node.arguments&.arguments&.first : node.value
          columns = value.is_a?(Prism::ArrayNode) && value.elements.all? { |e| literal_string(e) } ? literal_strings(value) : nil
          @results << {
            macro:      :ignored_columns,
            op:         op,
            columns:    columns,
            location:   node.location.start_line,
            confidence: columns ? RailsAiContext::Confidence::VERIFIED : RailsAiContext::Confidence::INFERRED
          }
        end

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

        # store :col, accessors: [...] and store_accessor :col, *keys both name
        # the column first; the keys follow it, positionally or as accessors:.
        def extract_store(node)
          args = node.arguments&.arguments || []
          column = args.first && literal_string(args.first)
          return unless column

          keys = args.drop(1).reject { |a| a.is_a?(Prism::KeywordHashNode) }.flat_map { |a| literal_strings(a) }
          keys_node = extract_keyword_nodes(node)[:accessors]
          keys += literal_strings(keys_node) if keys_node

          @results << {
            macro:      node.name,
            attribute:  column,
            keys:       keys,
            options:    extract_keyword_options(node).slice(:prefix, :suffix),
            location:   node.location.start_line,
            confidence: confidence_for(node)
          }
        end

        # Rails defaults the attribute to :token.
        def extract_secure_token(node)
          args = node.arguments&.arguments || []
          first = args.first
          return if first && !first.is_a?(Prism::KeywordHashNode) && literal_string(first).nil?

          @results << {
            macro:      :has_secure_token,
            attribute:  first && literal_string(first) || "token",
            location:   node.location.start_line,
            confidence: confidence_for(node)
          }
        end

        def extract_nested_attributes(node)
          names = extract_symbol_args(node).map(&:to_s)
          return if names.empty?

          @results << {
            macro:      :accepts_nested_attributes_for,
            names:      names,
            options:    extract_keyword_sources(node),
            location:   node.location.start_line,
            confidence: confidence_for(node)
          }
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
          when Prism::SymbolNode then type_arg.unescaped
          end

          # Sources, so `default: "anon"` prints as the file writes it.
          options = extract_keyword_sources(node).merge(extract_keyword_nodes(node).slice(:default).transform_values(&:slice))

          @results << {
            macro:      :attribute,
            attribute:  name_arg.unescaped,
            type:       type,
            options:    options,
            location:   node.location.start_line,
            confidence: confidence_for(node)
          }
        end

        def extract_alias_attribute(node)
          new_name, old_name = extract_symbol_args(node)
          return unless new_name && old_name

          @results << {
            macro:      :alias_attribute,
            attribute:  new_name.to_s,
            target:     old_name.to_s,
            location:   node.location.start_line,
            confidence: confidence_for(node)
          }
        end
      end
    end
  end
end
