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
        include OwnerScope
        include BranchConditions

        SIMPLE_MACROS = %i[
          has_secure_password
        ].to_set.freeze

        ATTRIBUTE_MACROS = %i[
          encrypts normalizes has_one_attached has_many_attached
          has_rich_text generates_token_for serialize attr_readonly query_constraints
        ].to_set.freeze

        # Class settings each change how the model reads, writes or loads; kept as written.
        SETTINGS = %i[
          inheritance_column= store_full_sti_class= strict_loading_by_default=
          implicit_order_column= locking_column=
        ].to_set.freeze

        STORE_MACROS = %i[store store_accessor].to_set.freeze

        BROADCAST_MACROS = %i[
          broadcasts broadcasts_to broadcasts_refreshes broadcasts_refreshes_to
        ].to_set.freeze

        # Model gems' class macros, each listed as written; aasm's block is read in full.
        # `devise` names the modules a model turns on, which no other line says.
        GEM_MACROS = %i[
          devise
          has_paper_trail audited acts_as_paranoid friendly_id
          mount_uploader mount_uploaders monetize
          pg_search_scope multisearchable searchkick
          acts_as_list acts_as_tenant multi_tenant acts_as_taggable acts_as_taggable_on
          has_ancestry acts_as_nested_set has_closure_tree acts_as_tree
          state_machine workflow
        ].to_set.freeze

        def initialize
          super
          @def_depth = 0
          @eval_depths = []
        end

        def on_def_node_enter(_node)
          @def_depth += 1
        end

        def on_def_node_leave(_node)
          @def_depth -= 1
        end

        # A method body runs only when called, so only a call sent to a mixin hook's
        # includer counts there. Each record names the class it is written in.
        def on_call_node_enter(node)
          return if @def_depth.positive? && !(node.receiver && in_scope?(node))

          owned { record_call(node) }
          # `base.class_eval do` in a hook runs its block on the includer, as a class body.
          return unless @def_depth.positive? && node.block && WithOptionsScope::EVALS.include?(node.name)

          @eval_depths.push([ node, @def_depth ])
          @def_depth = 0
        end

        def on_call_node_leave(node)
          @def_depth = @eval_depths.pop.last if @eval_depths.last&.first.equal?(node)
          @aasm = nil if @aasm && @aasm[:node].equal?(node)
          @event = nil if @event && @event[:node].equal?(node)
        end

        # self.ignored_columns += [...] and -= [...]
        def on_call_operator_write_node_enter(node)
          return unless @def_depth.zero? && node.read_name == :ignored_columns && node.receiver.is_a?(Prism::SelfNode)

          op = { :+ => :add, :- => :remove }[node.binary_operator]
          owned { record_ignored_columns(node, op) } if op
        end

        private

        def owned
          count = @results.size
          yield
          @results.drop(count).each { |result| result[:owner] = @owner_stack.dup }
        end

        def record_call(node)
          return record_ignored_columns(node, :assign) if node.name == :ignored_columns= && node.receiver.is_a?(Prism::SelfNode)
          return record_setting(node) if SETTINGS.include?(node.name) && node.receiver.is_a?(Prism::SelfNode)
          return unless in_scope?(node)
          return read_aasm(node) if @aasm

          if node.name == :aasm
            open_aasm(node) if node.block || node.arguments
          elsif GEM_MACROS.include?(node.name)
            record_gem_macro(node)
          elsif node.name == :connects_to
            # Under a condition the app may never call it, so no table is routed to its database.
            condition = current_condition
            @results << { macro: :connects_to, text: one_line_source(node), condition: condition,
                          writing: (writing_database(node) unless condition),
                          location: node.location.start_line, confidence: confidence_for(node) }.compact
          elsif SIMPLE_MACROS.include?(node.name)
            # Rails defaults the attribute to :password.
            @results << {
              macro:      node.name,
              attribute:  (extract_symbol_args(node).first || :password).to_s,
              written:    written_options(node),
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

        # Every keyword option as the file writes it: a lambda, `2.days` or a nested hash
        # reads the same on every Ruby, where a value's inspect does not.
        def written_options(node)
          keyword_hash(node) { |value| one_line_source(value) }
        end

        def record_setting(node)
          value = node.arguments&.arguments&.first or return
          @results << { macro: :model_setting, setting: node.name.to_s.delete_suffix("="), value: value.slice,
                        literal: setting_literal(value), location: node.location.start_line, confidence: confidence_for(node) }
        end

        # A symbol or string names what it spells, nil is nil; anything else is not known without running it.
        def setting_literal(value)
          case value
          when Prism::SymbolNode, Prism::StringNode then value.unescaped
          when Prism::NilNode then nil
          else RailsAiContext::Confidence::INFERRED
          end
        end

        def record_gem_macro(node)
          text = one_line_source(node, upto: node.block&.location&.start_offset)
          text = text.gsub(/\s+/, " ").strip
          adds = monetized_names(node) if node.name == :monetize
          @results << { macro: :gem_macro, name: node.name, text: text, adds: adds.presence,
                        location: node.location.start_line, confidence: confidence_for(node) }.compact
        end

        # money-rails names the attribute `as:`, or the column minus its `_cents` postfix.
        def monetized_names(node)
          as = extract_keyword_options(node)[:as]
          return [ as.to_s ] if as.is_a?(Symbol) || as.is_a?(String)

          extract_symbol_args(node).map(&:to_s).filter_map { |column| column.delete_suffix("_cents") if column.end_with?("_cents") }
        end

        # A named machine's column defaults to its name (AASM::Base#default_column).
        def open_aasm(node)
          name = extract_symbol_args(node).first
          column = extract_keyword_options(node)[:column] || (name && name != :default ? name : "aasm_state")
          entry = { macro: :aasm, column: column.to_s, initial: nil, states: [], events: [],
                    location: node.location.start_line, confidence: confidence_for(node) }
          @results << entry
          @aasm = { node: node, entry: entry } if node.block.is_a?(Prism::BlockNode)
        end

        def read_aasm(node)
          entry = @aasm[:entry]
          case node.name
          when :state
            names = extract_symbol_args(node).map(&:to_s)
            entry[:states].concat(names)
            # The first state is the initial one until a state says `initial: true`.
            entry[:initial] = names.first if names.any? && (entry[:initial].nil? || extract_keyword_options(node)[:initial] == true)
          when :event
            name = extract_symbol_args(node).first or return
            event = { name: name.to_s, transitions: [] }
            entry[:events] << event
            @event = { node: node, event: event } if node.block
          when :transitions
            options = extract_keyword_nodes(node)
            from = options[:from] ? literal_strings(options[:from]) : []
            @event[:event][:transitions] << { from: from, to: options[:to] && literal_string(options[:to]) } if @event
          end
        end

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
              written:    written_options(node),
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

        # The database `connects_to database: { writing: :analytics }` writes to, which names its schema dump.
        def writing_database(node)
          roles = extract_keyword_nodes(node)[:database]
          return unless roles.is_a?(Prism::HashNode)

          pair = roles.elements.find { |element| element.is_a?(Prism::AssocNode) && literal_string(element.key) == "writing" }
          pair && literal_string(pair.value)
        end

        def extract_attribute_api(node)
          args    = node.arguments&.arguments || []
          return if args.empty?

          name_arg = args.first
          return unless name_arg.is_a?(Prism::SymbolNode)

          type_arg = args[1]
          type = case type_arg
          when Prism::SymbolNode then type_arg.unescaped
          when nil, Prism::KeywordHashNode then nil
          else one_line_source(type_arg)
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
