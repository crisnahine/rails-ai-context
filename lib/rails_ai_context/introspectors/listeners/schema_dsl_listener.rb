# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    module Listeners
      # Detects schema.rb DSL patterns via Prism AST:
      # create_table, t.string, t.index, add_foreign_key, create_enum
      class SchemaDslListener < BaseListener
        # Whether a `t` receiver is a table: `Tag.find_each { |t| t.update! }` binds
        # `t` to a record. A receiverless block is a table helper's, a def's `t` a helper's argument.
        module TableBlock
          TABLE_BLOCKS = %i[create_table change_table create_join_table].to_set.freeze

          private

          # The dispatcher enters a block's call before anything inside it.
          def note_block(node)
            params = node.block.is_a?(Prism::BlockNode) && node.block.parameters.is_a?(Prism::BlockParametersNode) &&
                     node.block.parameters.parameters
            return unless params

            names = params.requireds.filter_map { |param| param.name if param.respond_to?(:name) }
            table = node.receiver.nil? || TABLE_BLOCKS.include?(node.name)
            (@blocks ||= []) << [ node.block.location, names, table ]
          end

          def table_param?(receiver)
            offset = receiver.location.start_offset
            _, _, table = Array(@blocks).reverse_each.find do |location, names, _|
              names.include?(receiver.name) && offset.between?(location.start_offset, location.end_offset)
            end
            table.nil? || table
          end
        end

        include TableBlock

        # Each adapter's ColumnMethods (Rails 7.0 to 8.1), plus neighbor's vector types and PostGIS's.
        COLUMN_TYPES = %w[
          bigint binary boolean date datetime decimal float integer json string text time timestamp virtual
          primary_key references belongs_to
          bigserial bit bit_varying cidr citext daterange hstore inet interval int4range int8range jsonb ltree
          macaddr money numrange oid point line lseg box path polygon circle serial tsrange tstzrange tsvector
          uuid xml timestamptz enum
          blob tinyblob mediumblob longblob tinytext mediumtext longtext
          unsigned_integer unsigned_bigint unsigned_float unsigned_decimal
          vector halfvec sparsevec cube
          spatial geography geometry geometry_collection line_string multi_line_string multi_point
          multi_polygon st_point st_polygon
        ].to_set.freeze

        def on_call_node_enter(node)
          note_block(node)
          if node.receiver.nil?
            extract_top_level_call(node)
          elsif column_call?(node)
            extract_column(node)
          elsif index_call?(node)
            extract_index(node)
          elsif check_constraint_call?(node)
            extract_check_constraint(node)
          elsif node.name == :unique_constraint && receiver_is_t?(node.receiver)
            extract_unique_constraint(node)
          elsif receiver_is_t?(node.receiver) && !read_elsewhere?(node.name)
            unread_call(node)
          end
        end

        # Block methods the replay reads, or that never add an index.
        OTHER_TABLE_METHODS = %i[
          foreign_key remove_foreign_key remove_check_constraint rename_index
          column_exists? index_exists? foreign_key_exists? check_constraint_exists?
        ].to_set.freeze

        private

        def read_elsewhere?(name)
          OTHER_TABLE_METHODS.include?(name) || MigrationReplayListener::TABLE_OPS.key?(name)
        end

        # A block call no reader interprets may add an index or a column.
        def unread_call(node)
          @results << { type: :unread_call, name: node.name.to_s, location: node.location.start_line }
        end

        def extract_top_level_call(node)
          case node.name
          when :create_table
            extract_create_table(node)
          when :add_foreign_key
            extract_foreign_key(node)
          when :create_enum
            extract_enum(node)
          when :add_index
            extract_top_level_add_index(node)
          when :add_check_constraint
            extract_top_level_check_constraint(node)
          when :enable_extension
            name = literal_string(node.arguments&.arguments&.first)
            @results << { type: :extension, name: name, location: node.location.start_line } if name
          end
        end

        def extract_create_table(node)
          args = node.arguments&.arguments || []
          table_arg = args.first
          return unless table_arg.is_a?(Prism::StringNode)

          @results << {
            type:     :create_table,
            table:    table_arg.unescaped,
            # id: false / id: :uuid / primary_key: ... decide whether the
            # implicit primary-key column exists and what to call it.
            options:  extract_keyword_options(node),
            location: node.location.start_line
          }
        end

        def extract_foreign_key(node)
          args = node.arguments&.arguments || []
          from_arg = args[0]
          to_arg = args[1]
          return unless from_arg.is_a?(Prism::StringNode) && to_arg.is_a?(Prism::StringNode)

          options = extract_keyword_options(node)

          @results << {
            type:        :foreign_key,
            from:        from_arg.unescaped,
            to:          to_arg.unescaped,
            # Absent means the Rails convention holds; naming it here would
            # make a declared column indistinguishable from a guessed one.
            column:      SchemaConventions.primary_key_value(options[:column]),
            primary_key: SchemaConventions.primary_key_value(options[:primary_key]),
            on_delete:   options[:on_delete],
            on_update:   options[:on_update],
            location:    node.location.start_line
          }.compact
        end

        def extract_enum(node)
          args = node.arguments&.arguments || []
          name_arg = args[0]
          values_arg = args[1]
          return unless name_arg.is_a?(Prism::StringNode)

          values = case values_arg
          when Prism::ArrayNode
            values_arg.elements.filter_map { |e|
              e.is_a?(Prism::StringNode) ? e.unescaped : nil
            }
          else []
          end

          @results << {
            type:     :enum,
            name:     name_arg.unescaped,
            values:   values,
            location: node.location.start_line
          }
        end

        def extract_top_level_add_index(node)
          args = node.arguments&.arguments || []
          table_arg = args[0]
          return unless table_arg.is_a?(Prism::StringNode)

          columns = literal_strings(args[1])
          options = extract_keyword_options(node)

          @results << {
            type:     :add_index,
            table:    table_arg.unescaped,
            columns:  columns,
            options:  options,
            location: node.location.start_line
          }
        end

        def extract_top_level_check_constraint(node)
          args = node.arguments&.arguments || []
          table_arg = args[0]
          expr_arg = args[1]
          return unless table_arg.is_a?(Prism::StringNode) && expr_arg.is_a?(Prism::StringNode)

          @results << {
            type:       :add_check_constraint,
            table:      table_arg.unescaped,
            expression: expr_arg.unescaped,
            name:       literal_string(keyword_hash(node) { |value| value }[:name]),
            location:   node.location.start_line
          }.compact
        end

        def check_constraint_call?(node)
          node.name == :check_constraint && receiver_is_t?(node.receiver)
        end

        def extract_check_constraint(node)
          args = node.arguments&.arguments || []
          expr_arg = args.first
          return unless expr_arg.is_a?(Prism::StringNode)

          @results << {
            type:       :check_constraint,
            expression: expr_arg.unescaped,
            name:       literal_string(keyword_hash(node) { |value| value }[:name]),
            location:   node.location.start_line
          }.compact
        end

        def extract_unique_constraint(node)
          @results << {
            type:     :unique_constraint,
            columns:  literal_strings(node.arguments&.arguments&.first),
            options:  extract_keyword_options(node),
            location: node.location.start_line
          }
        end

        def column_call?(node)
          return false unless node.name == :column || COLUMN_TYPES.include?(node.name.to_s)
          receiver_is_t?(node.receiver)
        end

        def index_call?(node)
          node.name == :index && receiver_is_t?(node.receiver)
        end

        def receiver_is_t?(receiver)
          case receiver
          when Prism::CallNode
            receiver.name == :t && receiver.receiver.nil?
          when Prism::LocalVariableReadNode
            receiver.name == :t && table_param?(receiver)
          else
            false
          end
        end

        # `t.references :a, :b` defines each name; primary_key's second argument is its type.
        def extract_column(node)
          # `t.string "name", { limit: 50 }` passes its options braced.
          braced, positional = (node.arguments&.arguments || []).reject { |arg| arg.is_a?(Prism::KeywordHashNode) }
                                                                 .partition { |arg| arg.is_a?(Prism::HashNode) }
          # TableDefinition#column(name, type): a type with no method of its own, as MySQL dumps enum('a','b').
          column_type = node.name == :column ? literal_string(positional[1]) : node.name.to_s
          positional = positional.first(1) if node.name == :primary_key || node.name == :column
          names = positional.map { |arg| literal_string(arg) }
          return unread_call(node) if names.empty? || names.any?(&:nil?) || column_type.nil?

          options = braced.map { |hash| hash_node_to_hash(hash) }.reduce(extract_keyword_options(node), :merge)
          virtual = node.name == :virtual
          # A generated column takes its own type from type: (each adapter's virtual, 7.0 to 8.1).
          column_type = options[:type].to_s if virtual && (options[:type].is_a?(Symbol) || options[:type].is_a?(String))
          names.each do |col_name|
            @results << {
              type:        :column,
              table:       nil,
              column_type: column_type,
              name:        col_name,
              options:     options,
              # A proc default (`default: -> { "now()" }`) has no literal value,
              # so keep its source for callers that report defaults verbatim.
              default_source: default_source(node),
              default_proc: proc_default?(node),
              location:    node.location.start_line
            }
            @results.last[:virtual] = true if virtual
          end
        end

        def extract_index(node)
          args = node.arguments&.arguments || []
          columns = literal_strings(args.first)
          options = extract_keyword_options(node)

          @results << {
            type:     :index,
            columns:  columns,
            string_key: args.first.is_a?(Prism::StringNode),
            options:  options,
            location: node.location.start_line
          }
        end
      end
    end
  end
end
