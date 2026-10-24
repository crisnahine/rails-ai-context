# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    module MigrationReplay
      # Applies one statement to the tables the way Rails runs it, whether a
      # migration calls it or a change_table block's `t` does.
      module Statements
        module_function

        # A change_column_default that names no new value leaves the default.
        NOT_GIVEN = Object.new.freeze

        # rails_version: the app's; an unknown one takes the newest rules.
        def apply(entry, tables, pk_type, adapter: nil, rails_version: nil)
          table = entry[:table]
          options = entry[:options] || {}
          case entry[:action]
          when :create_table
            options = legacy_key_options(options, entry, adapter)
            drop_table(tables, table, options, adapter) if options[:force]
            options[:as].is_a?(String) ? create_table_as(tables, table, options[:as], adapter, entry) : seed_table(tables, table, options, pk_type, default: SchemaConventions.key_default(options, entry), adapter: adapter)
          when :create_table_sql then create_table_sql(tables, entry, adapter, rails_version)
          when :rename_index
            index = tables[table]&.dig(:indexes)&.find { |idx| idx[:name] == entry[:old_name] }
            index[:name] = entry[:new_name] if index && entry[:new_name]
          when :create_join_table then create_join_table(entry, tables, pk_type, adapter, rails_version)
          when :drop_table then drop_table(tables, table, options, adapter)
          when :drop_join_table then tables.delete(join_table_name(entry))
          when :rename_table
            new_name = entry[:new_name]
            if table && new_name && tables[table]
              tables[new_name] = tables.delete(table)
              tables.each_value { |child| child[:inherits]&.map! { |parent| parent == table ? new_name : parent } }
              rename_table_indexes(tables[new_name], table, new_name)
              sequence = rename_table_sequences(tables[new_name], table, new_name, rails_version)
              follow_sequence(tables, *sequence) if sequence
              each_foreign_key(tables) do |fk|
                fk[:from_table] = new_name if fk[:from_table] == table
                fk[:to_table] = new_name if fk[:to_table] == table
              end
            end
          when :add_column then add_column(tables[table], entry, adapter, pk_type, rails_version)
          when :add_timestamps then add_timestamps(tables, entry, adapter, rails_version)
          when :remove_column then remove_columns_from(tables[table], [ entry[:column] ])
          when :remove_columns then remove_columns_from(tables[table], entry[:columns])
          when :remove_reference, :remove_belongs_to then remove_reference_from(tables[table], entry[:ref], options)
          when :rename_column then rename_column_in(tables, table, entry[:column], entry[:new_name], adapter)
          when :change_column
            col = column_in(tables, entry)
            change_column(col, entry, adapter, rails_version)
            add_serial_index(tables[table], entry[:column_type], col, adapter)
          when :change_column_default, :change_column_null then alter_column(column_in(tables, entry), entry, adapter, rails_version)
          when :add_index then apply_schema_index(entry, table, tables)
          when :remove_index then remove_index_from(tables[table], entry[:columns], options)
          when :add_reference, :add_belongs_to
            apply_reference(tables, table, entry[:ref], entry[:options], pk_type, version: entry[:migration_version], adapter: adapter,
                                                                                  rails_version: rails_version)
          when :remove_foreign_key then remove_foreign_key_from(tables[table], entry[:to_table], options)
          when :add_foreign_key then add_foreign_key(tables[table], table, entry[:to_table], options, adapter, rails_version)
          when :add_check_constraint then add_check_constraint(tables[table], table, entry[:expression], options, adapter)
          when :remove_check_constraint then remove_check_constraint(tables[table], table, entry[:expression], options)
          when :add_unique_constraint then add_unique_constraint(tables[table], entry[:columns], options, adapter, rails_version)
          when :remove_unique_constraint then remove_unique_constraint(tables[table], table, entry[:columns], options)
          end
        end

        # PostgreSQL's DROP TABLE ... CASCADE also drops each table that INHERITS this one, and theirs, and every
        # foreign key to them; MySQL refuses that drop and SQLite keeps the other tables as they are.
        def drop_table(tables, table, options, adapter)
          return unless tables.delete(table) && options[:force] == :cascade && postgres_rules?(adapter)

          tables.each_value { |data| data[:foreign_keys]&.reject! { |fk| fk[:to_table] == table } }
          tables.select { |_, data| data[:inherits]&.include?(table) }.each_key { |child| drop_table(tables, child, options, adapter) }
        end

        # PostgreSQL and MySQL skip an existing key or check under if_not_exists; SQLite's table rebuild ignores it (7.0 to 8.1).
        # 7.0's add_check_constraint has no if_not_exists, but a second constraint of the same name fails there.
        def skip_existing?(options, adapter)
          if_not_exists?(options) && family(adapter) != :sqlite
        end

        def if_not_exists?(options)
          options.is_a?(Hash) && options[:if_not_exists] == true
        end

        # The existing key if_not_exists skips: 7.0 matches to_table only, 7.1 and 8.0 also a column the
        # call gives, and 8.1 fills the default column first and matches a given primary_key too.
        def add_foreign_key(table_data, table, to_table, options, adapter, rails_version)
          return unless table_data

          key = SchemaConventions.foreign_key_entry(table, to_table, options[:column], options[:primary_key],
                                                    **options.slice(*SchemaConventions::FOREIGN_KEY_OPTIONS))
          newest = RailsVersion.at_least?(rails_version, "8.1")
          column = newest ? key[:column] : (options[:column] if RailsVersion.at_least?(rails_version, "7.1"))
          found = foreign_keys_for(table_data, to_table&.to_s, column)
          found = found.select { |fk| fk[:primary_key] == key[:primary_key] } if newest && options[:primary_key]
          return if skip_existing?(options, adapter) && found.any?

          table_data[:foreign_keys] << key
        end

        # A name Rails makes up (chk_rails_...) is one the dump leaves out.
        def add_check_constraint(table_data, table, expression, options, adapter)
          return unless table_data && expression

          name = options[:name] if options[:name].is_a?(String) || options[:name].is_a?(Symbol)
          return if skip_existing?(options, adapter) && check_constraint_for(table_data[:check_constraints], table, expression, name)

          (table_data[:check_constraints] ||= []) << { name: name&.to_s, expression: expression }.compact
        end

        # By name, the given one or the one Rails derives from the expression (check_constraint_for, 7.0 to 8.1).
        def check_constraint_for(constraints, table, expression, name)
          name = name&.to_s || SchemaConventions.check_constraint_name(table, expression)
          Array(constraints).find { |c| (c[:name] || SchemaConventions.check_constraint_name(table, c[:expression])) == name }
        end

        def remove_check_constraint(table_data, table, expression, options)
          constraints = table_data && table_data[:check_constraints] or return

          found = check_constraint_for(constraints, table, expression, options[:name])
          constraints.delete(found) if found
          table_data.delete(:check_constraints) if constraints.empty?
        end

        # Only PostgreSQL has unique constraints (7.1 to 8.1). One made with using_index: takes that index over; a name Rails
        # makes up (uniq_rails_...) is one the dump leaves out; 8.0 adds nulls_not_distinct:.
        # shortcut: 8.0 writes NULLS NOT DISTINCT only on PostgreSQL 15 and later, which the replay takes as given; split by server version if an app on 14 shows it.
        def add_unique_constraint(table_data, columns, options, adapter, rails_version)
          return unless table_data && postgres_rules?(adapter)

          columns = Array(columns)
          if columns.empty? && options[:using_index]
            index = table_data[:indexes].find { |idx| idx[:name] == options[:using_index].to_s } or return
            columns = table_data[:indexes].delete(index)[:columns]
          end
          return if columns.empty?

          nulls_not_distinct = options[:nulls_not_distinct] if RailsVersion.at_least?(rails_version, "8.0")
          (table_data[:unique_constraints] ||= []) << SchemaConventions.unique_constraint_entry(options[:name], columns, options[:deferrable], nulls_not_distinct)
        end

        # The one remove_unique_constraint names, by its columns or its name (unique_constraint_for, 7.1 to 8.1).
        def remove_unique_constraint(table_data, table, columns, options)
          constraints = table_data && table_data[:unique_constraints] or return

          columns = Array(columns)
          found = constraints.find do |c|
            (options[:name].nil? || (c[:name] || SchemaConventions.unique_constraint_name(table, c[:columns])) == options[:name].to_s) &&
              (columns.empty? || c[:columns] == columns)
          end
          constraints.delete(found) if found
          table_data.delete(:unique_constraints) if constraints.empty?
        end

        # PostgreSQL and MySQL make a composite key's columns not null; SQLite leaves them nullable.
        def composite_keys_not_null(tables, adapter)
          return if family(adapter) == :sqlite

          tables.each_value do |table|
            key = table[:primary_key]
            Array(table[:columns]).each { |column| column[:null] = false if key.is_a?(Array) && key.include?(column[:name]) }
          end
        end

        # A create_table implies its key column the way a dump does. A table
        # the replay cannot name is left out: a nil key breaks every reader.
        def seed_table(tables, table, options, pk_type, default: nil, adapter: nil)
          return if table.nil? || table.to_s.empty?

          unless tables.key?(table)
            tables[table] = { columns: implicit_pk_columns(options, pk_type, default: default, adapter: adapter), indexes: [], foreign_keys: [] }
            inherit_options(tables, table, options, adapter)
          end
          key = (options || {})[:primary_key]
          tables[table][:primary_key] = SchemaConventions.primary_key_value(key) if key.is_a?(Array)
        end

        # create_table's options: string follows the column list, so an INHERITS there names the table's parents.
        def inherit_options(tables, table, options, adapter)
          sql = (options || {})[:options]
          list = sql[/\bINHERITS\s*\(([^)]*)\)/i, 1] if sql.is_a?(String) && postgres_rules?(adapter)
          return unless list

          inherit_parents(tables, table, StructureSqlReader.split_top_level(list).map { |parent| StructureSqlReader.qualified_name(parent).delete_prefix("public.") })
        end

        # A table takes its parents' columns first; a parent no earlier statement made stays inherits_unresolved.
        def inherit_parents(tables, table, parents)
          data = tables[table]
          found, missing = parents.partition { |parent| tables.key?(parent) }
          data.merge!(inherits: found, local_columns: data[:columns].map { |c| c[:name] }) if found.any?
          data[:columns] = StructureSqlReader.inherit(data[:columns], tables.slice(*found), keep_sequence: true)
          data[:inherits_unresolved] = missing if missing.any?
        end

        # Compatibility::V5_0 gives a declared integer or bigint key default: nil, so it has no sequence, but not a bigint key on MySQL.
        # shortcut: Rails 7.0 exempts Mysql2 and not the trilogy gem's adapter, which no answer shows; split by adapter if one does.
        def legacy_key_options(options, entry, adapter)
          version = entry[:migration_version]
          return options unless version && (version <=> [ 5, 0 ]) <= 0 && %w[integer bigint].include?(options[:id].to_s) && !options.key?(:default)
          return options if options[:id].to_s == "bigint" && family(adapter) == :mysql

          options.merge(default: nil)
        end

        # MySQL's CREATE TABLE takes its SELECT without the AS.
        CREATE_AS = /\A\s*CREATE\s+(?:UNLOGGED\s+)?TABLE\s+(?<keep>IF\s+NOT\s+EXISTS\s+)?(?<name>[\w."`]++)(?:\s*\((?!\s*SELECT\b)(?<list>(?:[^()]|\([^()]*\))*)\))?\s*(?<as>AS\s+|(?=\(*\s*SELECT\b))(?<query>.+)\z/im

        # A table the SQL creates; an INHERITS parent an earlier statement made gives it its columns.
        def create_table_sql(tables, entry, adapter, rails_version)
          sql = entry[:sql]
          if (as = CREATE_AS.match(sql)) && (!as[:as].empty? || family(adapter) == :mysql)
            name = as[:name].delete('"`').split(".").last
            create_table_as(tables, name, as[:query], adapter, entry, as[:list]) unless as[:keep] && tables.key?(name)
            return [ name ]
          end

          kept = sql.scan(/\bTABLE\s+IF\s+NOT\s+EXISTS\s+([\w."`]+)/i).map { |(found)| StructureSqlReader.qualified_name(found).delete_prefix("public.") }
          StructureSqlReader.parse(sql, dialect: family(adapter), own_sequences: true, rails_version: rails_version)[:tables].each do |name, table|
            next if tables.key?(name) && kept.include?(name)

            parents = Array(table.delete(:inherits_unresolved))
            tables[name] = table
            inherit_parents(tables, name, parents)
          end
        end

        QUERY_END = /\s+WITH\s+(?:NO\s+)?DATA\s*\z/i
        COLUMN_REF = /\A(?:(?<qualifier>#{StructureSqlReader::COLUMN_NAME})\s*\.\s*)?(?:(?<column>#{StructureSqlReader::COLUMN_NAME})|(?<star>\*))\z/
        QUOTED_NAME = /\A(?:#{StructureSqlReader::COLUMN_NAME})\z/
        FROM_TABLE = /\A(?:["`]?\w+["`]?\.)?["`]?(\w+)["`]?(?:\s+(?:AS\s+)?(?!(?:JOIN|INNER|LEFT|RIGHT|FULL|CROSS|NATURAL|WHERE|GROUP|ORDER|LIMIT|HAVING|UNION|INTERSECT|EXCEPT|WINDOW|OFFSET|FETCH|FOR)\b)(\w+))?(.*)\z/im
        # Words that take an operand on their right after one on their left; the second word of a two-word one goes with it.
        INFIX_WORDS = %w[AND OR IS LIKE ILIKE SIMILAR BETWEEN IN ESCAPE COLLATE DIV MOD XOR REGEXP RLIKE GLOB MATCH OPERATOR SOUNDS MEMBER].freeze
        INFIX_SECOND = { "SIMILAR" => %w[TO], "SOUNDS" => %w[LIKE], "MEMBER" => %w[OF], "BETWEEN" => %w[SYMMETRIC ASYMMETRIC] }.freeze
        # MySQL reads a string after a temporal type or a character set as that type's literal, and any other as the alias;
        # after N, X or B only when the quote touches the letter.
        MYSQL_INTRODUCER = /\A(?:DATE|TIME|TIMESTAMP|_\w+)\z/
        # A string after one of these is its own literal, which MySQL joins to no string after it.
        MYSQL_TYPED = /\A(?:DATE|TIME|TIMESTAMP|[XB])\z/
        INTERVAL_UNIT = /\A(?:MICROSECOND|SECOND|MINUTE|HOUR|DAY|WEEK|MONTH|QUARTER|YEAR)(?:_(?:MICROSECOND|SECOND|MINUTE|HOUR|DAY|MONTH))?\z/i

        # CREATE TABLE ... AS: the selected columns with no key, typed by the FROM table they come from; one the query
        # computes or takes from another table has no type the replay knows. The entry counts a column it cannot name
        # (unnamed_columns) and a query it cannot read (unread_query), which makes no table.
        def create_table_as(tables, table, sql, adapter, entry, list = nil)
          return if table.nil? || table.to_s.empty?

          picked = (selected_columns(tables, sql, adapter) unless list && family(adapter) == :sqlite)
          return entry[:unread_query] = true unless picked

          # MySQL's column list declares columns: the ones the query does not select come first, and a selected one keeps its
          # definition. PostgreSQL's list names the selected ones in order.
          mysql = family(adapter) == :mysql
          declared = (StructureSqlReader.parse("CREATE TABLE t (#{list})", dialect: :mysql)[:tables]["t"] if list && mysql) || { columns: [], indexes: [], foreign_keys: [] }
          list.to_s.split(",").map { |name| name.strip.delete('"') }.each_with_index { |name, i| picked[i] = picked[i].merge(name: name) if i < picked.size } unless mysql
          named = picked.select { |c| c[:name] }
          entry[:unnamed_columns] = picked.size - named.size
          columns = named.map { |c| selected_column(StructureSqlReader.without_sequence(c.except(:primary_key)), adapter) }
          columns = columns.map { |c| declared[:columns].find { |d| d[:name].casecmp?(c[:name]) } || c }
          tables[table] = declared.merge(columns: (declared[:columns] - columns) + columns)
        end

        # A select item's expression and alias: the name after a complete expression when nothing follows it, a type's,
        # an interval's, a window's and an infix keyword's own words staying with the expression; nil for any other shape.
        def item_alias(item, adapter)
          mysql = family(adapter) == :mysql
          tokens = item_tokens(item, adapter)
          kind = ->(at) { tokens[at]&.first }
          text = ->(at) { tokens[at] && tokens[at][1] }
          word = ->(at) { kind.(at) == :word && text.(at).match?(/\A[a-z_]\w*\z/i) && text.(at).upcase }
          mysql_string = ->(at) { mysql && (kind.(at) == :string || (kind.(at) == :quoted && text.(at).start_with?('"'))) }
          operand = false
          i = 0
          while i < tokens.size
            if !operand && word.(i) == "INTERVAL" && text.(i + 1) && (!word.(i + 1) || text.(i + 2).to_s.match?(INTERVAL_UNIT))
              i = interval_fields(tokens, i + 1)
              operand = true
            elsif !operand
              i += 1 if word.(i).to_s.match?(/\ANFK?[CD]\z/) && word.(i + 1) == "NORMALIZED"
              operand = !(word.(i) == "NOT" || (mysql && word.(i) == "BINARY") || (kind.(i) == :punct && text.(i) != "*"))
              i = type_words(tokens, i) if word.(i)
            elsif text.(i) == ":" && text.(i + 1) == ":" then i = type_words(tokens, i + 2)
            elsif kind.(i) == :punct then operand = false
            elsif kind.(i) == :group || (!mysql && %w[ISNULL NOTNULL].include?(word.(i)))
            elsif word.(i) == "AS"
              name = sql_name(text.(i + 1), adapter) if i + 2 == tokens.size && kind.(i + 1) != :number
              return name && [ item[0, tokens[i][2]].strip, name ]
            elsif kind.(i) == :string && word.(i - 1) && (postgres_rules?(adapter) || (mysql && word.(i - 1).match?(MYSQL_INTRODUCER)) ||
                                                         (tokens[i][2] == tokens[i - 1][2] + 1 && word.(i - 1).match?(mysql ? /\A[NXB]\z/ : /\AX\z/)))
            elsif mysql_string.(i) && mysql_string.(i - 1) && !(i >= 2 && word.(i - 2).to_s.match?(MYSQL_TYPED))
            elsif i + 1 == tokens.size && kind.(i) != :number && (name = sql_name(text.(i), adapter))
              return [ item[0, tokens[i][2]].strip, name ]
            elsif word.(i) == "NOT"
            elsif word.(i) == "AT" && word.(i + 1) == "TIME" && word.(i + 2) == "ZONE"
              i += 2
              operand = false
            elsif word.(i) == "OVER" || (word.(i) == "WITHIN" && word.(i + 1) == "GROUP") then i += 1
            elsif word.(i) == "FILTER" && kind.(i + 1) == :group
            elsif INFIX_WORDS.include?(word.(i))
              i += 1 if INFIX_SECOND[word.(i)]&.include?(word.(i + 1))
              operand = false
            else return nil
            end
            i += 1
          end
          [ item.strip, nil ]
        end

        # A select item's top-level tokens as [kind, text, offset], read by SqlGate's tokenizer for the family's quotes: a
        # number whole, as 1.5 or 1e-3, and each group in parentheses or brackets and each CASE ... END as one :group.
        def item_tokens(item, adapter)
          db = RailsAiContext::DatabaseFamily.of(adapter.to_s)
          at = 0
          flat = SqlGate.tokens(item, db, brackets: db.sqlite?).map { |kind, span| [ kind, span, at = item.index(span, at) ].tap { at += span.size } }
          opens = ->(kind, span) { (kind == :punct && "([".include?(span)) || (kind == :word && span.casecmp?("CASE")) }
          closes = ->(kind, span) { (kind == :punct && ")]".include?(span)) || (kind == :word && span.casecmp?("END")) }
          close_of = lambda do |at|
            depth = 0
            (at...flat.size).find { |j| (depth += opens.(*flat[j].first(2)) ? 1 : (closes.(*flat[j].first(2)) ? -1 : 0)) <= 0 }
          end
          tokens = []
          i = 0
          while i < flat.size
            kind, span, from = flat[i]
            last = i
            # A CASE with no END after it is a word, as the alias in k case.
            if opens.(kind, span) && (closed = close_of.(i) || (kind == :punct && flat.size - 1))
              last = closed
              kind = :group
            elsif span.match?(/\A\.?\d/) || (span == "." && flat[i + 1]&.[](1)&.match?(/\A\d/))
              joined = span
              (i + 1...[ i + 5, flat.size ].min).each do |j|
                break unless flat[j][2] == flat[j - 1][2] + flat[j - 1][1].size

                joined += flat[j][1]
                last = j if joined.match?(StructureSqlReader::MYSQL_NUMBER)
              end
              kind = :number if last > i
            end
            tokens << [ kind, item[from...(flat[last][2] + flat[last][1].size)], from ]
            i = last + 1
          end
          tokens
        end

        # The last index of a type whose name runs over several words, as double precision or timestamp(3) with time zone,
        # from its first word at i; an interval's fields go with it.
        def type_words(tokens, i)
          name = tokens[i]&.[](1).to_s.downcase
          return interval_fields(tokens, i) if name == "interval"

          last = i
          loop do
            following = tokens[i + 1]&.first == :group ? i + 2 : i + 1
            break unless tokens[following] && PG_TYPE_NAMES.keys.any? { |type| type.start_with?("#{name} #{tokens[following][1].downcase}") }

            i = following
            name = "#{name} #{tokens[i][1].downcase}"
            last = i if PG_TYPE_NAMES.key?(name)
          end
          last
        end

        # The last index of an interval's fields after index i, as DAY or DAY TO SECOND; i when none follow.
        def interval_fields(tokens, i)
          unit = ->(at) { tokens[at]&.first == :word && tokens[at][1].match?(INTERVAL_UNIT) }
          i += 1 if unit.(i + 1)
          i += 2 if unit.(i) && tokens[i + 1]&.[](1)&.casecmp?("TO") && unit.(i + 2)
          i
        end

        # A bare or quoted name as the database spells the column: PostgreSQL folds a bare one to lower case, MySQL and
        # SQLite take a string as a name too, and SQLite a bracketed one.
        def sql_name(text, adapter)
          postgres = postgres_rules?(adapter)
          if !postgres && text.match?(/\A'.*'\z/m) then text[1...-1].gsub("''", "'")
          elsif text.match?(/\A\[.*\]\z/m) then text[1...-1]
          elsif (name = QUOTED_NAME.match(text))
            postgres && name[3] ? name[3].downcase : StructureSqlReader.unquote_name(*name.captures)
          end
        end

        # Each selected column, nil for a query the replay cannot read.
        def selected_columns(tables, sql, adapter)
          query = StructureSqlReader.unwrap_parens(sql.sub(QUERY_END, "").strip)
          return Array(tables.dig(Regexp.last_match(1), :columns)).dup.presence if query =~ /\ATABLE\s+(?:["`]?\w+["`]?\.)?["`]?(\w+)["`]?\z/i

          list, from_clause = top_level_from(query[/\ASELECT\s+(?:ALL\s+|DISTINCT\s+ON\s*\((?:[^()]|\([^()]*\))*\)\s*|DISTINCT\b\s*)?(.+)\z/im, 1] || return)
          from, as, rest = FROM_TABLE.match(from_clause.to_s)&.captures
          source = tables.dig(from, :columns)
          single = from && !rest.match?(/\A\s*,|\b(?:JOIN|UNION|INTERSECT|EXCEPT)\b/i)
          StructureSqlReader.split_top_level(list).each_with_object([]) do |item, picked|
            expression, alias_name = item_alias(item, adapter)
            next picked << { type: nil } unless expression

            expression = StructureSqlReader.unwrap_parens(expression)
            literal = literal_column(expression, adapter)
            next picked << (alias_name ? literal.merge(name: alias_name) : literal) if literal

            # A number such as 1.5e3 is a constant, never a qualified column.
            qualifier, column, star = COLUMN_REF.match(expression)&.captures unless expression.match?(StructureSqlReader::MYSQL_NUMBER)
            qualifier = qualifier&.delete('"`')
            column = sql_name(column, adapter) if column
            own = qualifier ? [ from, as ].include?(qualifier) : single
            if star
              return nil unless own && source && (qualifier || single)

              picked.concat(source)
            else
              found = Array(source).find { |c| c[:name] == column } if own
              picked << (found || { type: nil }).merge(name: alias_name || (column unless postgres_rules?(adapter)) || computed_name(item.strip, adapter))
            end
          end
        end

        LITERAL = /\A(?:(-?\d+)|(-?(?:\d*\.\d+|\d+\.))|'((?:[^']|'')*)'|(true|false))\z/i

        # A literal as each database types the column it makes: PostgreSQL names it ?column?, MySQL by its value, and SQLite
        # by its text with no type. MySQL 8.4 makes it not null with its type's zero.
        # MySQL joins adjacent strings into one, named by the first.
        # shortcut: MariaDB gives a literal column no default, types an integer by other lengths and names joined strings by all of them, which the replay cannot tell from MySQL; split by server if a MariaDB app shows one.
        def literal_column(text, adapter)
          parts = item_tokens(text, adapter) if family(adapter) == :mysql
          if parts && parts.size > 1 && parts.all? { |kind, span| kind == :string || span.start_with?('"') }
            first, *rest = parts.map { |_, span| span[1...-1].gsub(span[0] * 2, span[0]) }
            return literal_column("'#{(first + rest.join).gsub("'", "''")}'", adapter).merge(name: first)
          end

          integer, decimal, string, truth = LITERAL.match(text)&.captures
          return unless integer || decimal || string || truth

          if postgres_rules?(adapter)
            bits = Integer(integer, 10).bit_length if integer
            type = if bits then bits < 32 ? "integer" : (bits < 64 ? "bigint" : "decimal")
            else decimal ? "decimal" : (string ? "text" : "boolean")
            end
            { name: "?column?", type: type }
          elsif family(adapter) == :mysql
            value = string&.gsub("''", "'")
            column = if value then { type: "string", limit: value.size, default: "" }
            elsif decimal
              whole, _, scale = decimal.delete("-").partition(".")
              { type: "decimal", precision: (whole.empty? ? 0 : [ whole.sub(/\A0+/, "").size, 1 ].max) + scale.size, scale: scale.size, default: "0" }
            else { **(truth ? { type: "integer" } : mysql_integer(integer)), default: "0" }
            end
            { name: value || text, null: false, **column }
          else { name: text, type: nil }
          end
        end

        # MySQL 8.4 types an integer literal by its text's length, sign and leading zeros counted, then by its value.
        def mysql_integer(text)
          value = Integer(text, 10)
          if text.size <= (value.negative? ? 11 : 8) then { type: "integer" }
          elsif value.bit_length < 64 then { type: "bigint" }
          elsif value.positive? && value.bit_length == 64 then { type: "bigint", unsigned: true }
          else { type: "decimal", precision: text.delete("-").sub(/\A0+/, "").size, scale: 0 }
          end
        end

        # A computed column's name: MySQL and SQLite name it by its text, PostgreSQL as its FigureColname does.
        def computed_name(text, adapter)
          postgres_rules?(adapter) ? postgres_name(text)&.first : text
        end

        PG_OPERATOR = %r{[-+*/%<>=~!@\#^&|`?]|\b(?:IS|ISNULL|NOTNULL|NOT|AND|OR|BETWEEN|IN|LIKE|ILIKE|SIMILAR|OPERATOR)\b}i
        PG_NAME = /"_*"|\w+/
        PG_CALL = /\A(?:(?:#{PG_NAME})\s*\.\s*)*(#{PG_NAME})\s*\(_*\)(?:\s*FILTER\s*\(_*\))?(?:\s*OVER\s*(?:\(_*\)|\w+))?\z/i
        PG_TYPED_LITERAL = /\A(?<type>[A-Za-z_][\w ]*?)\s*'_*'\z|\A(?<type>INTERVAL)\s*'_*'\s+\w+(?:\s+TO\s+\w+)?\z/i
        PG_REF = /\A(?:(?:#{PG_NAME})\s*\.\s*)*(#{PG_NAME})\z/
        PG_TYPE_NAMES = {
          "int" => "int4", "integer" => "int4", "smallint" => "int2", "bigint" => "int8", "real" => "float4", "float" => "float8",
          "double precision" => "float8", "decimal" => "numeric", "dec" => "numeric", "boolean" => "bool", "char" => "bpchar",
          "character" => "bpchar", "character varying" => "varchar", "char varying" => "varchar", "bit varying" => "varbit",
          "timestamp without time zone" => "timestamp", "timestamp with time zone" => "timestamptz",
          "time without time zone" => "time", "time with time zone" => "timetz"
        }.freeze

        # PostgreSQL's name for a select item and its strength (FigureColnameInternal, as PostgreSQL 16 names it): 2 for a name
        # it takes over a cast's type or a CASE's, 1 for a cast's type or case, 0 for ?column?. nil for a shape the replay
        # cannot read, which stays unnamed.
        def postgres_name(text)
          text = text.strip
          text = StructureSqlReader.unwrap_parens(text) while text.start_with?("(") && StructureSqlReader.unwrap_parens(text) != text
          return [ "?column?", 0 ] if text.match?(LITERAL) || text.match?(StructureSqlReader::MYSQL_NUMBER) || text.match?(/\A(?:NULL|(?:[BEXN]|U&)'(?:[^']|'')*')\z/i)
          return postgres_sublink(text) if text.match?(/\A(?:SELECT|VALUES|WITH|TABLE)\b/i)

          top, cases = top_level(text)
          if cases == [ [ 0, text.size ] ]
            else_at = case_else(text)
            name = else_at ? postgres_name(text[else_at...-3]) : [ "case", 1 ]
            return name && (name[1] == 2 ? name : [ "case", 1 ])
          end
          if (normalized = top.match(/\s+IS\s+(?:NFK?[CD]\s+)?NORMALIZED\z/i)) && !top[0, normalized.begin(0)].match?(/\b(?:AND|OR|NOT)\b/i)
            return [ "is_normalized", 2 ]
          end
          return [ "?column?", 0 ] if top.match?(PG_OPERATOR)
          return [ "timezone", 2 ] if top.match?(/\bAT\s+TIME\s+ZONE\b/i)
          return postgres_name(text[0, Regexp.last_match.begin(0)]) if top =~ /\s+COLLATE\s+\S+\z/i

          if (cast = top.rindex("::")) && (!top[0, cast].strip.match?(/\s/) || top[0, cast].match?(PG_TYPED_LITERAL))
            postgres_cast(text[0, cast], text[(cast + 2)..])
          elsif top.match?(/\ACAST\s*\(_*\)\z/i) && (as = top_level(inner = text[(text.index("(") + 1)...-1])[0].rindex(/\sAS\s/i))
            postgres_cast(inner[0, as], inner[(as + 4)..])
          elsif top =~ /\A(\S+?)\s*(?:\[_*\])+\z/ && !Regexp.last_match(1).casecmp?("ARRAY")
            postgres_name(text[0, Regexp.last_match.end(1)])
          elsif top.match?(/\AARRAY\s*[\[(]_*[\])]\z/i) then [ "array", 2 ]
          elsif (literal = PG_TYPED_LITERAL.match(top)) then [ postgres_type_name(literal[:type]), 1 ]
          elsif top.match?(/\ATRIM\s*\(_*\)\z/i)
            [ { "leading" => "ltrim", "trailing" => "rtrim" }.fetch(text[/\(\s*(LEADING|TRAILING)\b/i, 1].to_s.downcase, "btrim"), 2 ]
          elsif (call = PG_CALL.match(top) || PG_REF.match(top)) then [ folded_name(text[call.begin(1)...call.end(1)]), 2 ]
          end
        end

        # A scalar subquery takes its first column's name, ?column? included; nil for one that does not start with SELECT
        # or whose first item is a star.
        def postgres_sublink(query)
          return unless query.match?(/\ASELECT\b/i)

          list, = top_level_from(query[/\ASELECT\b\s*(?:ALL\b\s*|DISTINCT\b\s*)?(.+)\z/im, 1] || return)
          expression, alias_name = item_alias(StructureSqlReader.split_top_level(list).first.to_s, "postgresql")
          return if COLUMN_REF.match(expression.to_s)&.[](:star)
          name = alias_name || (expression && postgres_name(expression)&.first)
          [ name, 2 ] if name
        end

        # A cast takes its argument's name when PostgreSQL names that by itself, else its type's last name.
        def postgres_cast(arg, type)
          name = postgres_name(arg) or return
          name[1] == 2 ? name : [ postgres_type_name(type), 1 ]
        end

        # A type's last name as PostgreSQL's grammar spells it: int is int4, double precision float8, float(n) float4 up to 24 bits.
        def postgres_type_name(type)
          type = type.strip.sub(/(?:\s*\[\d*\])+\z/, "")
          last = type[/(?:"[^"]+"|[^."]+)\z/].strip
          return last.delete('"') if last.start_with?('"')

          bits = last[/\Afloat\s*\(\s*(\d+)/i, 1]
          return bits.to_i <= 24 ? "float4" : "float8" if bits

          words = last.gsub(/\s*\([^)]*\)/, " ").squeeze(" ").strip.downcase
          PG_TYPE_NAMES.fetch(words, words)
        end

        def folded_name(name)
          name.start_with?('"') ? name[1...-1].gsub('""', '"') : name.downcase
        end

        # The text with quoted text, the inside of parentheses and brackets, and each CASE's body blanked, so a pattern sees
        # only the top level; and the start and end of each top-level CASE.
        def top_level(text)
          shown = Array.new(text.bytesize, false)
          after = 0
          depth = 0
          # Between two bytes the scan yields lies quoted text, shown by its quotes alone.
          quoted = ->(to) { shown[after] = shown[to - 1] = true if depth <= 0 && to - after > 1 }
          StructureSqlReader.scan_top_level(text, EVERY_BYTE) do |byte, i, depth_after|
            quoted.(i) if i > after
            shown[i] = (byte == 41 || byte == 93 ? depth_after : depth) <= 0
            depth = depth_after
            after = i + 1
          end
          quoted.(text.bytesize) if text.bytesize > after
          at = 0
          masked = text.each_char.map { |char| (shown[at] ? char : "_").tap { at += char.bytesize } }.join
          cases = case_spans(masked)
          cases.each { |from, to| masked[(from + 4)...(to - 3)] = "_" * (to - from - 7) }
          [ masked, cases ]
        end

        # A run scan_top_level skips nothing with, so it yields each byte outside quotes.
        EVERY_BYTE = /(?!)/

        # Each top-level CASE ... END in a masked text, as its start and end.
        def case_spans(masked)
          depth = 0
          from = nil
          masked.to_enum(:scan, /\b(?:CASE|END)\b/i).filter_map do
            match = Regexp.last_match
            if match[0].casecmp?("CASE")
              from = match.begin(0) if depth.zero?
              depth += 1
              nil
            elsif depth.positive?
              depth -= 1
              [ from, match.end(0) ] if depth.zero?
            end
          end
        end

        # Where the ELSE result of the CASE that is the whole text starts, nil when it has none.
        def case_else(text)
          masked = top_level(text[4...-3])[0]
          depth = 0
          masked.to_enum(:scan, /\b(?:CASE|ELSE|END)\b/i).each do
            match = Regexp.last_match
            word = match[0].upcase
            return match.end(0) + 4 if word == "ELSE" && depth.zero?

            depth += word == "CASE" ? 1 : (word == "END" ? -1 : 0)
          end
          nil
        end

        # The select list and what follows its FROM, split at the FROM outside parentheses and quotes.
        def top_level_from(query)
          StructureSqlReader.scan_top_level(query, StructureSqlReader::DEFAULT_RUN) do |byte, i, depth|
            next unless depth.zero? && StructureSqlReader::WHITESPACE_BYTES.include?(byte)

            from = query.byteslice(i, query.bytesize - i)[/\A\s+FROM\s+/i] or next
            return [ query.byteslice(0, i), query.byteslice(i + from.bytesize, query.bytesize) ]
          end
          [ query, nil ]
        end

        # MySQL keeps a column's not null and default, and an auto-increment one takes 0; PostgreSQL keeps neither;
        # SQLite also types the column by its affinity, the text, integer or no type a booted app reads.
        def selected_column(col, adapter)
          case family(adapter)
          when :mysql then col[:auto_increment] ? col.except(:auto_increment).merge(null: false, default: "0") : col
          when :sqlite
            type = { "string" => "text", "text" => "text", "integer" => "integer", "bigint" => "integer" }[col[:type]]
            { name: col[:name], type: type }
          else col.except(:null, :default, :auto_increment)
          end
        end

        def implicit_pk_columns(options, pk_type, default: nil, adapter: nil)
          options ||= {}
          SchemaConventions.implicit_primary_key(options, pk_type, default: default).map do |pk|
            type, sizes = dumped_type(pk[:type], options.slice(:unsigned).merge(pk[:options] || {}), adapter, primary_key: true)
            # PostgreSQL backs an integer or bigint key with its own sequence unless a default is given (integer_like_primary_key?).
            # MySQL makes the same key AUTO_INCREMENT.
            sequenced = %w[integer bigint].include?(type) && !options.key?(:default) && !(pk[:options] || {}).key?(:default)
            increments = sequenced && family(adapter) == :mysql
            sequenced &&= postgres_rules?(adapter)
            type = StructureSqlReader.serial_name(type, true) if sequenced
            { name: pk[:name], type: type, null: false, primary_key: true, default: pk[:default], **sizes, own_sequence: (true if sequenced || sizes[:own_sequence]),
              auto_increment: (true if increments || sizes[:auto_increment]) }.compact
          end
        end

        def family(adapter)
          RailsAiContext::DatabaseFamily.of(adapter.to_s).key
        end

        # An adapter with no family reads with PostgreSQL's rules, as structure.sql does.
        def postgres_rules?(adapter)
          RailsAiContext::DatabaseFamily.of(adapter.to_s).postgres_rules?
        end

        # A declared type and its sizes as the dump writes them, MySQL's unsigned among them (type_to_sql, schema_precision, 7.0 to 8.1).
        def dumped_type(type, options, adapter, primary_key: false)
          mysql = family(adapter) == :mysql
          if mysql && (signed = type.to_s[/\Aunsigned_(\w+)\z/, 1])
            type = signed
            options = options.merge(unsigned: true)
          end
          sizes = options.slice(:limit, :precision, :scale).select { |_, value| value.is_a?(Integer) }
          limit = sizes[:limit]
          name, detail = case type.to_s
          when "decimal" then [ type, sizes.slice(:precision, :scale) ]
          # numeric is no native type, so type_to_sql writes it bare, and every adapter's type map reads it as decimal.
          when "numeric" then [ "decimal", {} ]
          when "string" then [ type, mysql && limit == 255 ? {} : sizes.slice(:limit) ]
          when "integer" then dumped_integer(limit, adapter)
          # Only MySQL reads a timestamp back as one; the others read it as a datetime.
          when "datetime", "timestamp", "time"
            [ type == "time" ? type : StructureSqlReader.normalize_sql_type(type.to_s, family(adapter)),
              StructureSqlReader.dumped_precision(type.to_s, sizes[:precision], family(adapter)) ]
          when "text", "binary" then [ type, dumped_blob_size(type.to_s, limit, adapter) ]
          # type_to_sql writes float(n) for a float's limit on every adapter.
          when "float" then [ type, StructureSqlReader.column_type(limit ? "float(#{limit})" : "float", family(adapter)).last ]
          # A type the replay cannot read (add_column with a computed one) stays nil, not the reader's "".
          when "" then [ type, {} ]
          else StructureSqlReader.column_type(type.to_s, family(adapter), primary_key: primary_key)
          end
          [ name, mysql && options[:unsigned] == true ? detail.merge(unsigned: true) : detail ]
        end

        # PostgreSQL's text and bytea take no limit; MySQL picks tiny to long by it (a binary under 4 KB
        # is a varbinary that keeps it); SQLite keeps it as declared.
        def dumped_blob_size(type, limit, adapter)
          return {} if limit.nil? || postgres_rules?(adapter)
          return { limit: limit } unless family(adapter) == :mysql && !(type == "binary" && limit <= 0xfff)

          size = case limit
          when 0..0xff then "tiny"
          when 0x100..0xffff then nil
          when 0x10000..0xffffff then "medium"
          else "long"
          end
          size ? { size: size } : {}
        end

        def dumped_integer(limit, adapter)
          postgres = postgres_rules?(adapter)
          return [ "integer", limit ? { limit: limit } : {} ] unless postgres || family(adapter) == :mysql
          return [ "bigint", {} ] if limit.to_i > 4
          return [ "integer", {} ] if limit.nil? || limit == 4 || (postgres && limit == 3)

          [ "integer", { limit: postgres ? 2 : limit } ]
        end

        # A computed column name is counted in the note instead: a nil name trips every reader.
        def add_column(table_data, entry, adapter, pk_type, rails_version)
          return unless table_data && entry[:column]
          return if if_not_exists?(entry[:options]) && table_data[:columns].any? { |c| c[:name] == entry[:column] }

          table_data[:columns].reject! { |c| c[:name] == entry[:column] }
          table_data[:columns] << declared_column(entry[:column], entry[:column_type], entry, adapter, pk_type, rails_version)
          add_serial_index(table_data, entry[:column_type], table_data[:columns].last, adapter)
        end

        def add_serial_index(table_data, type, col, adapter)
          return unless col && StructureSqlReader.serial_index?(family(adapter), type, col, table_data[:primary_key])

          table_data[:indexes] << StructureSqlReader.serial_index(table_data[:indexes], col[:name])
        end

        # A column a statement makes the key reads as the key create_table implies (TableDefinition#primary_key, 7.0 to 8.1).
        def declared_column(name, type, entry, adapter, pk_type, rails_version)
          opts = entry[:options] || {}
          return column_entry(name, type, entry, adapter, rails_version) unless type == "primary_key" || opts[:primary_key] == true

          id = opts.except(:primary_key)
          id = id.merge(type: type) unless type == "primary_key"
          implicit_pk_columns({ id: id, primary_key: name }, pk_type, default: SchemaConventions.key_default({ id: id }, entry), adapter: adapter).first
        end

        # A column as the dump writes it, whether a table block or add_column declares it.
        def column_entry(name, type, entry, adapter, rails_version)
          opts = entry[:options] || {}
          virtual = entry[:virtual] || type == "virtual"
          # A generated column takes its own type from type: (each adapter's virtual, 7.0 to 8.1).
          type = opts[:type].to_s if type == "virtual" && (opts[:type].is_a?(Symbol) || opts[:type].is_a?(String))
          declared = type
          type, sizes = dumped_type(type, opts, adapter, primary_key: opts[:primary_key] == true)
          col = { name: name, type: type, **sizes }
          col[:year] = true if year_type?(declared)
          col[:null] = false if opts[:null] == false
          col.merge!(auto_increment: true, null: false) if opts[:auto_increment] == true && family(adapter) == :mysql
          default = declared_default(opts, entry, adapter, col.merge(array: opts[:array] == true), rails_version)
          col[:default] = SchemaConventions.format_default(default) if opts.key?(:default) && default != RailsAiContext::Confidence::INFERRED
          sent_default(col) unless postgres_rules?(adapter) || entry[:default_proc]
          col[:array] = true if opts[:array] == true
          if virtual
            col[:generated] = opts[:as].is_a?(String) ? opts[:as] : ""
            col[:stored] = opts[:stored] == true
          end
          col
        end

        # MySQL's YEAR, which the dump reads as an integer; its column carries a year mark until the replay settles.
        def year_type?(type)
          type.to_s.match?(/\Ayear\b/i)
        end

        # The new default is to: of a from:/to: pair, or the positional value
        # (extract_new_default_value, 7.0 and 8.1); an unreadable one is left.
        def change_column_default(col, entry, adapter, rails_version, sent: true)
          opts = entry[:options] || {}
          new_default = if opts.key?(:to) then opts[:to]
          elsif entry.key?(:new_default) then entry[:new_default]
          else NOT_GIVEN
          end
          new_default = declared_default({ default: new_default }, entry, adapter, col, rails_version)
          return if col.nil? || new_default.equal?(NOT_GIVEN) || new_default == RailsAiContext::Confidence::INFERRED

          col.replace(StructureSqlReader.without_sequence(col))
          col[:default] = SchemaConventions.format_default(new_default)
          sent_default(col) if sent && !entry[:default_proc]
        end

        # change_column builds the type from its own sizes on every adapter. PostgreSQL and MySQL
        # set the default and null only when given; SQLite rebuilds the column from the options alone (7.0 to 8.1).
        def change_column(col, entry, adapter, rails_version)
          return unless col

          return col.replace(column_entry(col[:name], entry[:column_type] || col[:type], entry, adapter, rails_version).merge(col.slice(:primary_key))) if family(adapter) == :sqlite

          opts = entry[:options] || {}
          col[:type], sizes = dumped_type(entry[:column_type] || col[:type], opts, adapter)
          col.except!(:limit, :precision, :scale, :unsigned, :year).merge!(sizes)
          col[:year] = true if year_type?(entry[:column_type])
          # change_column keeps a column's AUTO_INCREMENT unless the options name it (change_column_for_alter, 7.0 to 8.1).
          col[:auto_increment] = opts[:auto_increment] == true if opts.key?(:auto_increment)
          change_column_null(col, opts[:null]) if opts.key?(:null)
          change_column_default(col, entry.merge(options: { to: opts[:default] }), adapter, rails_version,
                                sent: !postgres_rules?(adapter) && !entry[:default_proc]) if opts.key?(:default)
        end

        # Only null: false is stored, so allowing NULL again removes the mark; MySQL keeps an AUTO_INCREMENT column NOT NULL.
        def change_column_null(col, null)
          return if col.nil? || null.nil? || (null && col[:auto_increment])

          null ? col.delete(:null) : col[:null] = false
        end

        def column_in(tables, entry)
          tables[entry[:table]]&.dig(:columns)&.find { |c| c[:name] == entry[:column] }
        end

        def apply_schema_column(entry, current_table, tables, pk_type, adapter, rails_version = nil)
          return unless tables[current_table]
          col_type = entry[:column_type]

          if %w[references belongs_to].include?(col_type)
            apply_reference(tables, current_table, entry[:name], entry[:options], pk_type,
                            version: entry[:migration_version], adapter: adapter, rails_version: rails_version)
            return
          end

          # Skip non-column types
          return if %w[index check_constraint].include?(col_type)

          col = declared_column(entry[:name], col_type, entry, adapter, pk_type, rails_version)
          opts = entry[:options] || {}
          data = tables[current_table]
          if data[:local_columns] && !data[:local_columns].include?(col[:name]) && data[:columns].any? { |c| c[:name] == col[:name] }
            # PostgreSQL merges a column a child declares into the one it inherits, in that column's place.
            StructureSqlReader.merge_column(data[:columns], col)
          else
            # Only one branch of an if runs, so a second declaration of a name replaces the first.
            data[:columns].reject! { |c| c[:name] == col[:name] }
            data[:columns] << col
          end
          data[:local_columns] |= [ col[:name] ] if data[:local_columns]
          add_serial_index(tables[current_table], col_type, col, adapter)
          return unless opts[:index] && opts[:index] != false

          # TableDefinition#column indexes a column declared with index: (7.0 to 8.1).
          index_opts = opts[:index].is_a?(Hash) ? opts[:index] : {}
          apply_schema_index({ columns: [ col[:name] ], options: index_opts }, current_table, tables)
        end

        # TableDefinition#timestamps and add_timestamps (7.0 and 8.1). Only a
        # table definition indexes them; add_timestamps adds the columns alone.
        def add_timestamps(tables, entry, adapter, rails_version)
          table_data = tables[entry[:table]] or return
          options = entry[:options] || {}
          if options.key?(:default)
            default = declared_default(options, entry, adapter, { type: "datetime" }, rails_version)
            options = default == RailsAiContext::Confidence::INFERRED ? options.except(:default) : options.merge(default: default)
          end
          stamps = SchemaConventions.timestamps_columns(options, version: entry[:migration_version])
          table_data[:columns].reject! { |c| stamps.any? { |stamp| stamp[:name] == c[:name] } }
          table_data[:columns].concat(stamps)
          return unless entry[:definition] && options[:index]

          stamps.each do |stamp|
            apply_schema_index({ columns: [ stamp[:name] ], options: options[:index].is_a?(Hash) ? options[:index] : {} },
                               entry[:table], tables)
          end
        end

        # A literal default, or a proc's source the way the dump readers report
        # it; any other expression is a value only the running migration knows.
        # SQLite keeps a proc's SQL as written and reads it back as the reader does, nil being no default.
        # shortcut: MariaDB writes CURRENT_TIMESTAMP back lowercase, which the replay cannot tell from MySQL; split by server if one shows it.
        def declared_default(options, entry, adapter, col, rails_version)
          value = options[:default]
          unless value == RailsAiContext::Confidence::INFERRED && entry[:default_proc]
            return mysql_year(BigDecimal(value)) || value if col&.dig(:year) && value.is_a?(Integer) && family(adapter) == :mysql

            return postgres_rules?(adapter) && col&.dig(:array) && (value.is_a?(Array) || value.is_a?(String)) ? postgres_array(value, col) || value : value
          end

          sql = entry[:default_literal]
          if sql && family(adapter) == :sqlite
            scale = col&.dig(:scale) || (0 if col&.dig(:precision))
            return boolean_default(StructureSqlReader.sqlite_default(sql, col&.dig(:type), rails_version, scale), col)
          end

          literal = if postgres_rules?(adapter) then postgres_value(sql, col)
          elsif family(adapter) == :mysql then mysql_value(sql, col)
          end
          return if literal.equal?(NO_DEFAULT)

          literal.nil? ? entry[:default_source] : literal
        end

        PG_LITERAL = /\AB?'((?:[^']|'')*)'(?:\s*::\s*"?[\w. ]+"?(?:\[\])?)?\z/m
        PG_TRUE = /\A(?:t(?:r(?:ue?)?)?|y(?:es?)?|on|1)\z/
        PG_FALSE = /\A(?:f(?:a(?:l(?:se?)?)?)?|no?|off?|0)\z/
        # The reader's rule on the SQL as declared, which PostgreSQL stores with its keywords upper case.
        # shortcut: an explicit cast PostgreSQL drops or folds (to the column's own type, of a bare number) is judged as written; model the cast if a dump shows one.
        PG_FUNCTION_AS_WRITTEN = Regexp.new(StructureSqlReader::PG_FUNCTION.source, Regexp::IGNORECASE | Regexp::MULTILINE)
        NO_DEFAULT = Object.new.freeze

        # PostgreSQL stores one whole literal, in parentheses or not, as the column's type reads it, and Rails decodes
        # that back (extract_value_from_default, 7.0 to 8.1): a boolean by PostgreSQL's input words, an array as its
        # elements. A date or time word such as 'now' becomes the moment the table was made, which no replay knows.
        # Any other expression is a function default only where has_default_function? accepts it, else none.
        def postgres_value(sql, col)
          case sql
          when /\A\((.*)\)\z/m then postgres_value(Regexp.last_match(1).strip, col)
          when /\A\(\s*(B?'(?:[^']|'')*')\s*\)(\s*::.+)\z/m then postgres_value(Regexp.last_match(1) + Regexp.last_match(2), col)
          when PG_LITERAL
            value = Regexp.last_match(1).gsub("''", "'")
            type = col&.dig(:type)
            return if TIME_TYPES.include?(type) && !value.match?(/\A\d/)
            return postgres_array(value, col) if col&.dig(:array)

            type == "boolean" ? postgres_boolean(value) : value
          when /\A(?:true|false)\z/i then sql.downcase
          when /\A-?\d+(?:\.\d*)?(?:::bigint)?\z/ then sql.delete_suffix("::bigint")
          when PG_FUNCTION_AS_WRITTEN then nil
          when String then NO_DEFAULT
          end
        end

        TIME_TYPES = %w[date datetime time timestamp timestamptz].freeze

        # An array literal, or a Ruby array as PostgreSQL stores its elements' text, a boolean one by PostgreSQL's input
        # words. A decimal whose precision has no scale is scale 0, as dumped_decimals reads it.
        def postgres_array(value, col)
          scale = col[:scale] || (0 if col[:precision])
          items = value.is_a?(Array) ? array_text(value) : StructureSqlReader.array_default(value, nil) or return
          items = array_text(items) { |item| postgres_boolean(item) } if col[:type] == "boolean"
          StructureSqlReader.array_cast(items, col[:type], scale)
        end

        def array_text(items, &each)
          items.map { |item| item.is_a?(Array) ? array_text(item, &each) : item.nil? ? nil : (each ? each.call(item.to_s) : item.to_s) }
        end

        def postgres_boolean(value)
          word = value.strip.downcase
          if word.match?(PG_TRUE) then "true"
          elsif word.match?(PG_FALSE) then "false"
          end
        end

        # MySQL stores a bare literal or number as the value, which reads back as the column's type casts it; one in
        # parentheses is an expression it keeps. A backslash escape stays a proc.
        def mysql_value(sql, col)
          value = case sql
          when /\A'((?:[^'\\]|'')*)'\z/ then Regexp.last_match(1).gsub("''", "'")
          when StructureSqlReader::MYSQL_NUMBER then mysql_number(Regexp.last_match, col)
          when /\A(?:true|false)\z/i then sql.casecmp?("true") ? "1" : "0"
          end
          boolean_default(value, col)
        end

        # A boolean column's stored default as the dump writes it, through ActiveModel's Boolean cast.
        def boolean_default(value, col)
          col&.dig(:type) == "boolean" ? StructureSqlReader.boolean_default(value) : value
        end

        # A number as MySQL stores it for the column's type: rounded half away from zero for an integer or a boolean's
        # tinyint, a float's value in its six digits and a double's in its shortest, a decimal's value, and a string's or
        # binary's own text. A date or time column turns it into a date, and MySQL refuses an e-notation number no double
        # holds, or stores one on a float column as no double; either stays the proc.
        def mysql_number(number, col)
          value = mysql_decimal(number)
          return if (number[:exponent] || col&.dig(:type) == "float") && !value.to_f.finite?

          case col&.dig(:type)
          when "integer", "bigint", "boolean" then col[:year] ? mysql_year(value) : value.round.to_i.to_s
          when "float" then mysql_double(col[:limit].to_i > 24 ? value.to_f.to_s : format("%.6g", value.to_f))
          when "decimal" then (number[:exponent] ? BigDecimal(value.to_f.to_s) : value).to_s("F")
          when "string", "text", "binary" then mysql_number_text(number, value)
          when *TIME_TYPES then nil
          else number[0]
          end
        end

        # MySQL stores a number on a YEAR column rounded to a year: 1 to 69 in the 2000s, 70 to 99 in the 1900s and 0 as 0000.
        # It refuses a negative one and any other outside 1901 to 2155, which stays the proc.
        def mysql_year(value)
          year = value.round.to_i
          return if value.negative?

          case year
          when 0, 1901..2155 then year.to_s
          when 1..69 then (2000 + year).to_s
          when 70..99 then (1900 + year).to_s
          end
        end

        # MySQL writes a whole or decimal number without its leading zeros, and the sign of a zero not at all; an e-notation
        # one is a double, in its shortest digits.
        def mysql_number_text(number, value)
          return mysql_double(value.to_f.to_s) if number[:exponent]

          whole = number[:whole].sub(/\A0+(?=\d)/, "").presence || "0"
          "#{number[:sign] unless value.zero?}#{whole}#{".#{number[:fraction]}" if number[:fraction].present?}"
        end

        # The number's value; bigdecimal before 3.2 reads no point without a digit after it.
        def mysql_decimal(number)
          BigDecimal("#{number[:sign]}#{number[:whole].presence || 0}.#{number[:fraction].presence || 0}#{number[:exponent]}")
        end

        # A double's digits as MySQL writes them: out from 1e-15 to under 1e15, in e notation outside that.
        def mysql_double(number)
          value = BigDecimal(number)
          return "0" if value.zero?

          sign, digits, _, exponent = value.split
          return value.to_s("F").delete_suffix(".0") if (exponent - 1).between?(-15, 14)

          "#{'-' if sign.negative?}#{digits[0]}#{".#{digits[1..]}" if digits.size > 1}e#{exponent - 1}"
        end

        # An index follows its column to the new name, and one Rails named for
        # the old columns is renamed for the new (rename_column_indexes, 7.0 to 8.1).
        def rename_index_columns(table_data, table, old_name, new_name)
          Array(table_data && table_data[:indexes]).each do |idx|
            next unless idx[:columns].include?(old_name)

            old_default = SchemaConventions.default_index_name(table, idx[:columns])
            idx[:columns] = idx[:columns].map { |col| col == old_name ? new_name.to_s : col }
            idx[:name] = SchemaConventions.default_index_name(table, idx[:columns]) if idx[:name] == old_default
          end
        end

        # An index Rails named for the old table takes the name for the new one;
        # a name the migration chose stays (rename_table_indexes, 7.0 and 8.1).
        def rename_table_indexes(table_data, old_table, new_table)
          Array(table_data[:indexes]).each do |idx|
            next unless idx[:name] == SchemaConventions.default_index_name(old_table, idx[:columns])

            idx[:name] = SchemaConventions.default_index_name(new_table, idx[:columns])
          end
        end

        # PostgreSQL's rename_table renames the key's first column's sequence when it has the name Rails builds from the
        # old table (pk_and_sequence_for, key_sequence_name); every other sequence keeps its name. Returns the old and new name.
        def rename_table_sequences(table_data, old_table, new_table, rails_version)
          key = Array(table_data[:primary_key]).first || table_data[:columns].find { |c| c[:primary_key] }&.dig(:name)
          renamed = nil
          table_data[:columns].each do |c|
            keep_sequence_name(c, old_table)
            next unless c[:name] == key && c[:own_sequence]

            schema, dot, sequence = c[:own_sequence].rpartition(".")
            next unless sequence == key_sequence_name(old_table, key, rails_version)

            renamed = [ c[:own_sequence], "#{schema}#{dot}#{key_sequence_name(new_table, key, rails_version)[0, 63]}" ]
            c[:own_sequence] = renamed.last
          end
          renamed
        end

        # A default here is the dump's text, which a structure.sql column gives as well as a proc, so this reads text, not a node.
        NEXTVAL_DEFAULT = /\A->\s*\{\s*"nextval\('"?(?:public\.)?([\w.]+?)"?'(?:::regclass)?\)"\s*\}\z/

        # A nextval default holds its sequence, not the name, so it reads back under the name the sequence has now.
        def follow_sequence(tables, old_name, new_name)
          tables.each_value do |data|
            Array(data[:columns]).each { |c| c[:default] = nextval_default(new_name) if c[:default].to_s[NEXTVAL_DEFAULT, 1] == old_name }
          end
        end

        # Rails sends a default cast through the column's type (quote_default_expression), so a decimal whose precision
        # has no scale, scale 0 by extract_scale, sends its whole part (DecimalWithoutScale casts with to_i). PostgreSQL's
        # adapter casts only change_column_default's, which reads the column back; its other defaults, and a proc's SQL
        # on any adapter, go as written.
        def sent_default(col)
          return unless col[:type] == "decimal" && col[:precision] && col[:scale].to_i.zero? && col[:default].to_s.match?(StructureSqlReader::DECIMAL_TEXT)

          col[:default] = BigDecimal(col[:default]).to_i.to_s
        end

        # The dump reads a decimal of scale 0 as DecimalWithoutScale, which casts its default with to_i, and rounds any
        # other scale. MySQL stores one with neither size as decimal(10,0), rounding the default the server gets.
        def dumped_decimals(tables, adapter)
          mysql = family(adapter) == :mysql
          tables.each_value do |table|
            Array(table[:columns]).each do |c|
              next unless c[:type] == "decimal"

              scale = c.delete(:scale) || (0 if c[:precision] || mysql)
              c[:scale] = scale if scale&.positive?
              c[:precision] ||= 10 if mysql
              c[:default] = StructureSqlReader.dumped_decimal(c[:default], scale, server_rounds: mysql) if c.key?(:default)
            end
          end
        end

        # PostgreSQL writes a nextval default back with its ::regclass cast, and without public on the search path; one naming
        # the sequence the column's own name makes reads as a serial (new_column_from_field), which settle_sequences types.
        def nextval_defaults(tables)
          tables.each do |name, data|
            Array(data[:columns]).each do |c|
              sequence = c[:default].to_s[NEXTVAL_DEFAULT, 1] or next
              next c[:default] = nextval_default(sequence) unless StructureSqlReader.serial_sequence?(sequence, name, c[:name])

              c.delete(:default)
              c[:own_sequence] = sequence
            end
          end
        end

        def nextval_default(sequence)
          StructureSqlReader.nextval_default(sequence)
        end

        # 7.1 to 8.1 cut the table to fit the key's name and _seq in 63 bytes; 7.0 does not, and PostgreSQL cuts the result.
        def key_sequence_name(table, key, rails_version)
          table = table[0, 63 - "_#{key}_seq".size] if RailsVersion.at_least?(rails_version, "7.1")
          "#{table}_#{key}_seq"
        end

        # own_sequence is true until the serial's sequence is named (name_sequences), then that name; a rename leaves the
        # sequence its name, so the name is fixed before the column or table changes.
        def keep_sequence_name(col, table)
          col[:own_sequence] = StructureSqlReader.owned_sequence(col, table) if col[:own_sequence]
        end

        def following_sequence?(col, table)
          return false unless col[:own_sequence]

          col[:own_sequence] == true || StructureSqlReader.serial_sequence?(col[:own_sequence], table, col[:name])
        end

        # PostgreSQL names a new serial's sequence for its table and column, numbering the suffix seq1, seq2 and on
        # while another relation holds the name (ChooseRelationName); the mark then holds it. held keeps each table's
        # relation_names, refreshed here for the tables a statement touched.
        def name_sequences(tables, touched, adapter, held)
          return unless postgres_rules?(adapter)

          touched.each do |table|
            fresh = Array(tables.dig(table, :columns)).select { |c| c[:own_sequence] == true }
            fresh.each do |col|
              col[:own_sequence] = (0..).lazy.map { |n| StructureSqlReader.owned_sequence(col.except(:own_sequence), table, "seq#{n unless n.zero?}") }.find do |name|
                tables.each_key.none? { |other| (other == table ? relation_names(tables, table) : held[other] ||= relation_names(tables, other)).include?(name) }
              end
            end
          end
          touched.each { |table| tables.key?(table) ? held[table] = relation_names(tables, table) : held.delete(table) }
        end

        # The names a table, its indexes and its columns' sequences hold.
        def relation_names(tables, table)
          schema = table.rpartition(".").first
          data = tables[table]
          Set[table] + Array(data[:indexes]).map { |idx| [ schema, idx[:name] ].reject(&:empty?).join(".") } +
            Array(data[:columns]).filter_map { |c| c[:own_sequence] if c[:own_sequence].is_a?(String) }
        end

        # The columns of a table some table INHERITS, before a statement changes them (follow_parent).
        def inherited_state(tables, table)
          return unless tables[table] && (tables[table][:inherits] || tables.each_value.any? { |t| t[:inherits]&.include?(table) })

          tables[table][:columns].map { |c| [ c, c.dup ] }
        end

        # The statements whose ALTER COLUMN PostgreSQL runs on each child too, so they set the child's own value.
        COLUMN_ALTERS = %i[change_column change_column_default change_column_null].to_set.freeze

        # PostgreSQL's ALTER TABLE reaches every table that INHERITS the one it names: a column added or renamed changes
        # in each child, an altered one takes the same statement, and a dropped one goes unless the child declares it or
        # another parent has it. A column a statement adds to a child itself is the child's own.
        def follow_parent(tables, table, before, entry, adapter, rails_version)
          columns = tables.dig(table, :columns) or return
          kept = before.map(&:first)
          added = columns.reject { |c| kept.any? { |k| k.equal?(c) } }
          altered = COLUMN_ALTERS.include?(entry[:action])
          own_columns(tables[table], before, added)
          tables.each do |name, child|
            next unless Array(child[:inherits]).include?(table)

            child_before = inherited_state(tables, name)
            before.each do |column, was|
              mine = child[:columns].find { |c| c[:name] == was[:name] } or next
              if columns.none? { |c| c.equal?(column) }
                remove_columns_from(child, [ was[:name] ]) unless inherited_elsewhere?(tables, child, table, was[:name])
              elsif altered
                alter_column(mine, entry, adapter, rails_version) if was[:name] == entry[:column]
              elsif column != was
                follow_column(child, mine, column, was, table)
              end
            end
            added.each { |c| child[:columns] << StructureSqlReader.inherited_column(c, table, keep_sequence: true) unless child[:columns].any? { |m| m[:name] == c[:name] } }
            follow_parent(tables, name, child_before, entry, adapter, rails_version) if child_before
          end
        end

        def alter_column(col, entry, adapter, rails_version)
          case entry[:action]
          when :change_column then change_column(col, entry, adapter, rails_version)
          when :change_column_default then change_column_default(col, entry, adapter, rails_version)
          when :change_column_null then change_column_null(col, entry[:null])
          end
        end

        def own_columns(table_data, before, added)
          return unless table_data[:local_columns]

          before.each { |column, was| table_data[:local_columns] = renamed(table_data[:local_columns], was[:name], column[:name]) }
          table_data[:local_columns] |= added.map { |c| c[:name] }
        end

        def inherited_elsewhere?(tables, child, parent, name)
          child[:local_columns]&.include?(name) ||
            (child[:inherits] - [ parent ]).any? { |other| Array(tables.dig(other, :columns)).any? { |c| c[:name] == name } }
        end

        # A child's copy takes what changed in the parent's column; a rename leaves the child's index names (rename_column_indexes runs on the parent).
        def follow_column(child, mine, column, was, parent)
          (column.keys | was.keys).each do |key|
            next if key == :primary_key || column[key] == was[key]

            case key
            when :name
              Array(child[:indexes]).each { |idx| idx[:columns] = renamed(idx[:columns], was[:name], column[:name]) }
              Array(child[:unique_constraints]).each { |uc| uc[:columns] = renamed(uc[:columns], was[:name], column[:name]) }
              Array(child[:foreign_keys]).each { |fk| fk[:column] = renamed(fk[:column], was[:name], column[:name]) }
              mine[:name] = column[:name]
            when :own_sequence then column[:own_sequence] ? mine[:own_sequence] = StructureSqlReader.owned_sequence(column, parent) : mine.delete(:own_sequence)
            else column.key?(key) ? mine[key] = column[key] : mine.delete(key)
            end
          end
        end

        # The dump reads a serial by name (serial?): one whose sequence follows its current names is a serial of its size
        # whatever its type (schema_type), any other its type with that sequence as its default. The marks go before output,
        # and so does a nil default, which the dump writes as no default.
        def settle_sequences(tables)
          tables.each do |name, table|
            Array(table[:columns]).map! do |c|
              key = c[:primary_key] == true || Array(table[:primary_key]) == [ c[:name] ]
              settled = following_sequence?(c, name) ? c.merge(type: StructureSqlReader.serial_name(StructureSqlReader.without_sequence(c)[:type], key)) : StructureSqlReader.detached_serial(c, name)
              settled.except(:own_sequence, :auto_increment, :year, *(:default if settled[:default].nil?))
            end
            table.except!(:inherits, :local_columns)
          end
        end

        def rename_column_in(tables, table, old_name, new_name, adapter)
          col = tables[table]&.dig(:columns)&.find { |c| c[:name] == old_name.to_s }
          return unless col && new_name

          keep_sequence_name(col, table)
          col[:name] = new_name.to_s
          tables[table][:primary_key] = renamed(tables[table][:primary_key], old_name.to_s, new_name.to_s) if tables[table].key?(:primary_key)
          rename_index_columns(tables[table], table, old_name.to_s, new_name.to_s)
          Array(tables[table][:unique_constraints]).each { |uc| uc[:columns] = renamed(uc[:columns], old_name.to_s, new_name.to_s) }
          each_foreign_key(tables) do |fk|
            fk[:column] = renamed(fk[:column], old_name.to_s, new_name.to_s) if fk[:from_table] == table
            # SQLite rebuilds the table, which leaves another table's key naming the old column.
            fk[:primary_key] = renamed(fk[:primary_key], old_name.to_s, new_name.to_s) if fk[:to_table] == table && family(adapter) != :sqlite
          end
        end

        # A key's column, or each column of a composite key, under its new name.
        def renamed(columns, old_name, new_name)
          columns.is_a?(Array) ? columns.map { |c| c == old_name ? new_name : c } : (columns == old_name ? new_name : columns)
        end

        # A foreign key names its tables and columns, so it follows them through a rename the way the database does.
        def each_foreign_key(tables, &block)
          tables.each_value { |data| Array(data[:foreign_keys]).each(&block) }
        end

        # remove_reference drops <ref>_id, and <ref>_type when polymorphic
        # (schema_statements.rb, 7.0 and 8.1); the database drops the index.
        def remove_reference_from(table_data, ref, options)
          return unless ref

          names = [ SchemaConventions.reference_column_name(ref) ]
          names << "#{ref}_type" if options[:polymorphic]
          remove_columns_from(table_data, names)
        end

        # The one index remove_index would drop, by name, by exact columns or
        # both (index_name_for_remove, 7.0 and 8.1); Rails raises on any other count.
        def remove_index_from(table_data, columns, options)
          return unless table_data

          cols = Array(columns).map(&:to_s)
          cols = Array(options[:column]).map(&:to_s) if cols.empty?
          name = options[:name]&.to_s
          return if name.nil? && cols.empty?

          matches = table_data[:indexes].select do |idx|
            (name.nil? || idx[:name].to_s == name) && (cols.empty? || Array(idx[:columns]) == cols)
          end
          table_data[:indexes].delete(matches.first) if matches.size == 1
        end

        # The key remove_foreign_key would drop (foreign_key_for, 8.1): by
        # to_table and column:, and a key on <to_table singular>_id first.
        def remove_foreign_key_from(table_data, to_table, options)
          return unless table_data

          to = (to_table || options[:to_table])&.to_s
          column = options[:column]
          return if to.nil? && column.nil?

          keys = foreign_keys_for(table_data, to, column)
          if column.nil?
            preferred = keys.select { |fk| fk[:column].to_s == "#{to.singularize}_id" }
            keys = preferred if preferred.any?
          end
          table_data[:foreign_keys].delete(keys.first) if keys.any?
        end

        # The keys to to_table on column:, each compared as a list so a composite key matches (ForeignKeyDefinition#defined_for?).
        def foreign_keys_for(table_data, to, column)
          Array(table_data[:foreign_keys]).select do |fk|
            (to.nil? || fk[:to_table].to_s == to) && (column.nil? || Array(fk[:column]).map(&:to_s) == Array(column).map(&:to_s))
          end
        end

        # PostgreSQL and SQLite drop every index holding a dropped column.
        # ponytail: MySQL shrinks a composite index instead; split by adapter if a MySQL app needs it.
        def remove_columns_from(table_data, names)
          return unless table_data

          names = names.compact.map(&:to_s)
          table_data[:columns].reject! { |c| names.include?(c[:name]) }
          table_data[:indexes].reject! { |idx| (Array(idx[:columns]) & names).any? }
          table_data[:foreign_keys].reject! { |fk| names.include?(fk[:column].to_s) }
          table_data[:unique_constraints]&.reject! { |uc| (uc[:columns] & names).any? }
          table_data.delete(:unique_constraints) if table_data[:unique_constraints]&.empty?
        end

        # create_join_table (7.0 and 8.1): no id, two non-null unindexed references,
        # named by table_name: or derive_join_table_name, which it returns for the block.
        def create_join_table(entry, tables, pk_type, adapter, rails_version)
          first, second = entry[:tables]
          return nil unless first && second

          options = entry[:options] || {}
          name = join_table_name(entry)
          seed_table(tables, name, { id: false }, pk_type, adapter: adapter)
          column_options = { null: false, index: false }.merge(options[:column_options].is_a?(Hash) ? options[:column_options] : {})
          [ first, second ].each do |t|
            apply_reference(tables, name, t.to_s.singularize, column_options, pk_type, version: entry[:migration_version], adapter: adapter, rails_version: rails_version)
          end
          name
        end

        def join_table_name(entry)
          first, second = entry[:tables]
          (entry.dig(:options, :table_name) || HabtmJoinTables.join_table_name(first, second)).to_s if first && second
        end

        # From 7.1 ReferenceDefinition passes if_not_exists: to each add_column, add_index and add_foreign_key
        # it makes; 7.0 passes it to add_column only, so its migration fails on the existing index.
        def apply_reference(tables, table, name, options, pk_type, version: nil, adapter: nil, rails_version: nil)
          return unless tables[table] && name

          options ||= {}
          keep = if_not_exists?(options)
          ref = SchemaConventions.reference_definition(table, name, options, pk_type, version: version)
          ref[:columns].each do |col|
            # Only the id column takes the reference's own options (ReferenceDefinition#columns).
            if col[:name] == SchemaConventions.reference_column_name(name)
              type, sizes = dumped_type(col[:type], options, adapter)
              col.merge!(type: type, **sizes)
            end
            next if keep && tables[table][:columns].any? { |c| c[:name] == col[:name] }

            tables[table][:columns].reject! { |c| c[:name] == col[:name] }
            tables[table][:columns] << col
          end
          add_reference_foreign_key(tables[table], table, name, options, adapter, rails_version)
          return unless ref[:index]
          return if keep && tables[table][:indexes].any? { |idx| idx[:name] == ref[:index][:name] }

          tables[table][:indexes].reject! { |idx| idx[:name] == ref[:index][:name] }
          tables[table][:indexes] << ref[:index]
        end

        # ReferenceDefinition's foreign_key: (7.0 to 8.1): true points at the
        # pluralized name, a hash may name to_table: and primary_key:, and it is added with add_foreign_key.
        def add_reference_foreign_key(table_data, table, name, options, adapter, rails_version)
          fk = options[:foreign_key]
          return if !fk || options[:polymorphic]

          fk = {} unless fk.is_a?(Hash)
          to = fk[:to_table] || name.to_s.pluralize
          return if to == RailsAiContext::Confidence::INFERRED

          table_data[:foreign_keys] ||= []
          key_options = fk.slice(:primary_key, *SchemaConventions::FOREIGN_KEY_OPTIONS)
                          .merge(column: SchemaConventions.reference_column_name(name), if_not_exists: options[:if_not_exists])
          add_foreign_key(table_data, table, to.to_s, key_options, adapter, rails_version)
        end

        def apply_schema_index(entry, current_table, tables)
          return unless tables[current_table]
          cols = entry[:columns]&.map(&:to_s) || []
          opts = entry[:options] || {}
          return if cols.empty?

          idx_name = opts[:name]&.to_s || SchemaConventions.default_index_name(current_table, entry[:string_key] ? cols.first : cols)
          return if if_not_exists?(opts) && tables[current_table][:indexes].any? { |idx| idx[:name] == idx_name }
          tables[current_table][:indexes] << SchemaConventions.index_entry(idx_name, cols, opts)
        end
      end
    end
  end
end
