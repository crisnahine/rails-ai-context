# frozen_string_literal: true

require "bigdecimal"
require "strscan"

module RailsAiContext
  module Introspectors
    # Reads a structure.sql dump into the same table shape the other static
    # schema sources produce. Pure text in, tables out - the caller owns the
    # file, the size cap, and whatever presentation wraps the result.
    module StructureSqlReader
      module_function

      # @return [Hash] { dialect: Symbol, tables: { name => { columns:, indexes:, foreign_keys: } } }
      # search_path: the database's configured schema_search_path. rails_version: the app's,
      # whose connection names extensions and enum types (PgNaming). dialect: the database's, when the caller knows it.
      # own_sequences: keep the own_sequence mark on each column a serial's sequence backs, which a bigint key's name does not
      # show, and the auto_increment mark on MySQL's.
      def parse(content, search_path: PgNaming::DEFAULT_SEARCH_PATH, rails_version: nil, dialect: nil, own_sequences: false)
        tables = {}
        # The tables the search path does not show bare, findable only by schema-qualified name.
        qualified_tables = {}
        dialect = detect_sql_dialect(content) unless RailsAiContext::DatabaseFamily.of(dialect).known?
        enums = enum_types(content)
        created = postgres_rules?(dialect) ? content.scan(CREATE_SCHEMA).map { |(name)| name.delete('"') } : []
        path = PgNaming.existing_path(search_path, created)
        creates = []
        each_create_table(content) { |*create| creates << create }
        view_matches = content.scan(VIEW)
        virtual_matches = content.scan(VIRTUAL_TABLE)
        relations = creates.map(&:first) + view_matches.map { |match| match[1] } + virtual_matches.map(&:first)
        names = PgNaming.names(path, relations: relations.map { |name| qualified_name(name) }, types: enums.keys)
        local = names.method(:relation)

        # Every table the file creates, by schema-qualified name, so a parent
        # outside the listed tables still resolves.
        all = {}
        creates.each do |qualified, body, inherits, trailer|
          name = qualified_name(qualified)
          shown = local.(name)
          next if SchemaConventions.bookkeeping_table?(shown)
          # SQLite's own tables; Rails' data_sources leaves them out.
          next if dialect == :sqlite && shown.start_with?("sqlite_")

          table, raw_types = parse_sql_table_body(body, shown, dialect: dialect, enums: enums, local: local, rails_version: rails_version)
          comment = trailer[/\bCOMMENT\s*=\s*'((?:[^']|'')*)'/i, 1]
          table[:comment] = comment.gsub("''", "'") if comment
          all[name] = { table: table, raw_types: raw_types, parents: inherits && split_top_level(inherits).map { |parent| qualified_name(parent) } }
          if shown.match?(/\A\w+\z/)
            tables[shown] = table
          elsif shown.include?(".")
            qualified_tables[shown] = table
          end
        end

        found_views = views(view_matches, local)
        content.scan(/CREATE (UNIQUE )?INDEX\s+(?:CONCURRENTLY\s+)?(?:IF NOT EXISTS\s+)?[`"]?(\w+)[`"]?\s+ON\s+(?:ONLY\s+)?#{QUALIFIED_NAME}((?:(?!#{NEXT_STATEMENT})[^;])*)/m) do |unique, idx_name, table, rest|
          group = first_paren_group(rest)
          keys = index_keys(group)
          next if keys.empty?

          # The method precedes the key list; INCLUDE, NULLS NOT DISTINCT and the condition follow it.
          open = rest.index("(")
          after = rest[(open + group.length + 2)..]
          where = after[/\bWHERE\s+(.+)\z/mi, 1]&.strip
          options = after.sub(/\bWHERE\b.*\z/mi, "")
          include = options[/\A\s*INCLUDE\s*\(([^)]*)\)/i, 1]
          detail = SchemaConventions.index_detail(keys, using: rest[0, open][/\bUSING\s+(\w+)/i, 1]&.downcase, include: include && index_keys(include),
                                                        nulls_not_distinct: RailsVersion.at_least?(rails_version, "7.1") && options.match?(/\bNULLS\s+NOT\s+DISTINCT\b/i),
                                                        **key_options(group))
          target = all.dig(qualified_name(table), :table) || found_views[local.(qualified_name(table))]
          (target[:indexes] ||= []) << { name: idx_name, columns: keys, unique: !!unique, where: where }.compact.merge(detail) if target
        end

        content.scan(/ALTER TABLE\s+(?:ONLY\s+)?#{QUALIFIED_NAME}\s+ADD CONSTRAINT\s+("[^"]+"|\w+)\s+UNIQUE\s*(NULLS\s+(?:NOT\s+)?DISTINCT\s*)?\(([^)]*)\)([^;]*)/m) do |table, name, nulls, cols, tail|
          table = all.dig(qualified_name(table), :table) or next
          add_unique_key(table, unique_constraint(name.delete('"'), cols.scan(/\w+/), "#{nulls}#{tail}"), rails_version)
        end

        content.scan(/ALTER TABLE\s+(?:ONLY\s+)?#{QUALIFIED_NAME}\s+ADD CONSTRAINT[^;]*?PRIMARY KEY\s*\(([^)]*)\)/m) do |table, cols|
          table = all.dig(qualified_name(table), :table)
          table[:primary_key] = SchemaConventions.primary_key_value(cols.scan(/\w+/)) if table
        end

        # [^;]*? keeps the match inside one statement: with .*? a pkey-only
        # ADD CONSTRAINT would swallow up to the FOREIGN KEY of a LATER
        # statement and attribute the FK to the wrong table.
        content.scan(/ALTER TABLE\s+(?:ONLY\s+)?#{QUALIFIED_NAME}\s+ADD CONSTRAINT[^;]*?FOREIGN KEY\s*\(([^)]*)\)\s*REFERENCES\s+#{QUALIFIED_NAME}\s*\(([^)]*)\)([^;]*)/m) do |from, cols, to, pks, tail|
          from = qualified_name(from)
          all.dig(from, :table, :foreign_keys)&.push(SchemaConventions.foreign_key_entry(local.(from), local.(qualified_name(to)), cols.scan(/\w+/), pks.scan(/\w+/), **foreign_key_actions(tail)))
        end

        alters = Hash.new { |h, k| h[k] = [] }
        content.scan(/^ALTER TABLE (?:ONLY )?#{QUALIFIED_NAME} ALTER COLUMN (?:#{COLUMN_NAME}) SET (NOT NULL|DEFAULT .+);$/) do |table, *name, change|
          alters[qualified_name(table)] << [ unquote_name(*name), change ]
        end
        resolved = {}
        all.each_key { |name| resolve_columns(name, all, alters, resolved, local, dialect: dialect, rails_version: rails_version) }
        all.each_value do |entry|
          entry[:table][:columns].each { |column| column[:enum_type] = names.type(column[:enum_type]) if column[:enum_type] }
        end
        PgNaming.drop_real_limits(all.each_value.map { |entry| entry[:table] }, rails_version) if postgres_rules?(dialect)
        all.each_value { |entry| entry[:table][:columns].each { |column| column.except!(:own_sequence, :auto_increment) } } unless own_sequences

        content.scan(/^COMMENT ON TABLE #{QUALIFIED_NAME} IS '((?:[^']|'')*)';/) do |table, text|
          table = all.dig(qualified_name(table), :table)
          table[:comment] = text.gsub("''", "'") if table
        end
        content.scan(/^COMMENT ON COLUMN ((?:(?:"[^"]+"|\w+)\.)+)("[^"]+"|\w+) IS '((?:[^']|'')*)';/) do |table, column, text|
          column = column.delete('"')
          found = all.dig(qualified_name(table.chomp(".")), :table, :columns)&.find { |c| c[:name] == column }
          found[:comment] = text.gsub("''", "'") if found
        end

        # pg_dump writes each partition as a table, then attaches it in exactly this form.
        content.scan(/^ALTER TABLE ONLY .+? ATTACH PARTITION #{QUALIFIED_NAME} /) do |(partition)|
          shown = local.(qualified_name(partition))
          (shown.include?(".") ? qualified_tables : tables).delete(shown)
        end

        { dialect: dialect, tables: tables, qualified_tables: qualified_tables, names: names, enums: PgNaming.enum_list(enums, path, rails_version),
          views: found_views, virtual_tables: virtual_tables(virtual_matches, local), extensions: extensions(content, path, dialect, rails_version) }
      end

      # As PostgreSQL's connection names them (PgNaming.extension_name).
      def extensions(content, path, dialect, rails_version)
        found = content.scan(/^CREATE EXTENSION (?:IF NOT EXISTS )?("[^"]+"|\w+)(?: WITH SCHEMA ("[^"]+"|\w+))?/).map do |name, schema|
          [ name.delete('"'), schema&.delete('"') ]
        end
        # Every PostgreSQL database starts with plpgsql in pg_catalog, and pg_dump leaves it out.
        if dialect == :postgresql && found.none? { |name, _| name == "plpgsql" } && !content.match?(/^DROP EXTENSION (?:IF EXISTS )?"?plpgsql\b/)
          found.unshift([ "plpgsql", "pg_catalog" ])
        end
        found.map { |name, schema| PgNaming.extension_name(name, schema, path, rails_version) }
      end

      # Each view by the name the app reads it under, a later definition of a name replacing a placeholder.
      def views(view_matches, local)
        view_matches.each_with_object({}) do |(materialized, name, sql), found|
          name = local.(qualified_name(name))
          found[name] = { materialized: !materialized.nil?, sql: sql.strip } if name.match?(/\A\w+\z/)
        end
      end

      def virtual_tables(virtual_matches, local)
        virtual_matches.to_h do |name, mod, arguments|
          [ local.(qualified_name(name)), { module: mod, arguments: split_top_level(arguments.to_s) } ]
        end
      end

      # PostgreSQL's enum types by schema-qualified name, with their labels.
      def enum_types(content)
        content.scan(/CREATE TYPE\s+#{QUALIFIED_NAME}\s+AS\s+ENUM\s*\(([^;]*)\)\s*;/i).to_h do |name, labels|
          [ qualified_name(name), split_top_level(labels).map { |label| label.delete_prefix("'").delete_suffix("'").gsub("''", "'") } ]
        end
      end

      # The actions Rails names (cascade, nullify, restrict); NO ACTION is its default.
      FK_ACTIONS = { "CASCADE" => "cascade", "SET NULL" => "nullify", "RESTRICT" => "restrict" }.freeze

      def foreign_key_actions(text)
        actions = { on_delete: :DELETE, on_update: :UPDATE }.to_h do |key, word|
          [ key, FK_ACTIONS[text.to_s[/\bON\s+#{word}\s+(CASCADE|SET\s+NULL|RESTRICT)\b/i, 1]&.upcase&.squeeze(" ")] ]
        end
        actions.merge(deferrable: deferrable_mode(text), validate: (false if text.to_s.match?(/\bNOT\s+VALID\b/i))).compact
      end

      # How Rails names a DEFERRABLE clause; nil for NOT DEFERRABLE or none.
      def deferrable_mode(text)
        return nil unless text.to_s.match?(/(?<!NOT )\bDEFERRABLE\b/i)

        text.to_s.match?(/\bINITIALLY\s+DEFERRED\b/i) ? "deferred" : "immediate"
      end

      # Where a statement with no semicolon ends: the next one starting a line.
      NEXT_STATEMENT = /\n\s*(?:CREATE|ALTER|COMMENT|INSERT|DROP|SET|SELECT)\b/i
      # A view's body runs on to a SELECT line, so only another statement's keyword ends it.
      NEXT_DDL = /\n\s*(?:CREATE\s+(?:(?:OR\s+REPLACE|UNIQUE|TEMP(?:ORARY)?|MATERIALIZED|VIRTUAL)\s+)*(?:TABLE|VIEW|INDEX|TRIGGER|SEQUENCE|TYPE|FUNCTION|EXTENSION|SCHEMA)\b|ALTER\s+(?:TABLE|SEQUENCE|TYPE|VIEW|INDEX)\b|COMMENT\s+ON\b|INSERT\s+INTO\b|DROP\s+(?:TABLE|VIEW|INDEX|TRIGGER)\b|SET\s+[\w.]+\s*(?:=|TO\b))/i

      # Each CREATE TABLE's name, body and INHERITS list. The body ends at its closing
      # parenthesis, since SQLite, MySQL and a semicolon-less dump each end the line differently.
      def each_create_table(content)
        scanner = StringScanner.new(content)
        while scanner.skip_until(CREATE_TABLE)
          qualified = scanner[1]
          close = closing_paren(content, scanner.pos) or next
          body = content.byteslice(scanner.pos + 1, close - scanner.pos - 1)
          scanner.pos = close + 1
          inherits = scanner[1] if scanner.scan(INHERITS)
          yield qualified, body, inherits, scanner.check(/[^;\n]*/).to_s
        end
      end

      QUOTE_BYTES = "'\"`".bytes.freeze
      WHITESPACE_BYTES = " \t\n\r\f\v".bytes.freeze

      # The byte index of the parenthesis closing the one at `open`, quotes
      # respected; nil when it never closes. Byte-wise, so a long dump costs one pass.
      def closing_paren(text, open)
        depth = 0
        quote = nil
        index = open
        while (byte = text.getbyte(index))
          if quote
            quote = nil if byte == quote
          elsif QUOTE_BYTES.include?(byte)
            quote = byte
          elsif byte == 40
            depth += 1
          elsif byte == 41
            depth -= 1
            return index if depth.zero?
          end
          index += 1
        end
        nil
      end

      # A column name as SQL writes it: a plain word, or quoted with any doubled quote inside.
      COLUMN_NAME = /"((?:[^"]|"")+)"|`((?:[^`]|``)+)`|(\w+)/

      # A definition line's leading column name, unquoted, and the text after it.
      def leading_name(line)
        match = line.match(/\A(?:#{COLUMN_NAME})(?:\s+(.+)|\z)/m) or return
        [ unquote_name(*match.captures.first(3)), match[4].to_s ]
      end

      def unquote_name(double, back, plain)
        double&.gsub('""', '"') || back&.gsub("``", "`") || plain
      end

      # A table name, optionally schema-qualified, each part bare or quoted.
      QUALIFIED_NAME = /((?:(?:"[^"]+"|`[^`]+`|\w+)\.)?(?:"[^"]+"|`[^`]+`|\w+))/
      INHERITS_KEYWORD = /\s*INHERITS\b/i
      # The optional INHERITS list after a CREATE TABLE body.
      INHERITS = /(?:#{INHERITS_KEYWORD}\s*\(([^)]*)\))?/
      CREATE_SCHEMA = /^CREATE SCHEMA (?:IF NOT EXISTS )?("[^"]+"|\w+)/
      CREATE_TABLE = /CREATE\s+(?:UNLOGGED\s+)?TABLE\s+(?:IF NOT EXISTS\s+)?#{QUALIFIED_NAME}\s*(?=\()/i
      # mysqldump wraps the statement in version comments and names an algorithm, definer and security first;
      # sqlite3 closes it with a /* name(columns) */ comment.
      VIEW = /\bCREATE\s+(?:OR\s+REPLACE\s+)?(?:(?:ALGORITHM|DEFINER|SQL\s+SECURITY)\b[^;]*?\s)?(?:TEMP(?:ORARY)?\s+)?(MATERIALIZED\s+)?VIEW\s+(?:IF\s+NOT\s+EXISTS\s+)?#{QUALIFIED_NAME}(?:\s*\([^)]*\))?\s+AS\s+(.*?)(?:\s+WITH\s+(?:NO\s+)?DATA)?(?:\s*\/\*\s*[\w"`]+\([^)]*\)\s*\*\/)?\s*(?:\*\/)?\s*(?:;|(?=#{NEXT_DDL})|\z)/im
      VIRTUAL_TABLE = /CREATE\s+VIRTUAL\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?#{QUALIFIED_NAME}\s+USING\s+(\w+)\s*(?:\(([^)]*)\))?/i

      # "schema.name" with quotes removed; an unqualified name is in public.
      def qualified_name(text)
        parts = text.strip.scan(/"([^"]+)"|`([^`]+)`|(\w+)/).map { |groups| groups.compact.first }
        parts.unshift("public") if parts.size == 1
        parts.join(".")
      end

      # Each parent's columns, then the child's own. pg_dump writes only local
      # columns and sets an inherited one's NOT NULL and default by ALTER.
      def resolve_columns(name, all, alters, resolved, local, dialect:, rails_version:)
        entry = all[name]
        return entry if resolved[name]

        resolved[name] = true
        parents = {}
        raw_types = {}
        unresolved = []
        entry[:parents]&.each do |parent|
          unless all[parent]
            unresolved << local.(parent)
            next
          end

          resolved_parent = resolve_columns(parent, all, alters, resolved, local, dialect: dialect, rails_version: rails_version)
          parents[local.(parent)] = resolved_parent[:table]
          raw_types = resolved_parent[:raw_types].merge(raw_types)
          unresolved.concat(Array(resolved_parent[:table][:inherits_unresolved]))
        end
        columns = inherit(entry[:table][:columns], parents, keep_sequence: false)
        entry[:raw_types] = raw_types.merge(entry[:raw_types])

        alters[name].each do |column_name, change|
          column = columns.find { |c| c[:name] == column_name } or next
          if change == "NOT NULL"
            column[:null] = false
          else
            default = sql_default(change, column[:type], entry[:raw_types].fetch(column_name), dialect: dialect, rails_version: rails_version,
                                                                                                    scale: column[:scale])
            default.nil? ? column.delete(:default) : column[:default] = default
            column.replace(without_sequence(column))
            sequence_default(column, change, table: name, primary_key: entry[:table][:primary_key] == column_name, local: local)
          end
        end
        entry[:table][:columns] = columns
        entry[:table][:inherits_unresolved] = unresolved.uniq if unresolved.any?
        entry
      end

      # PostgreSQL's INHERITS: each parent's columns, then the child's own, one column per name.
      # parents: each parent table by its shown name. keep_sequence: hold a serial copy's sequence in the mark.
      def inherit(own, parents, keep_sequence:)
        columns = []
        parents.each { |parent, table| table[:columns].each { |column| merge_column(columns, inherited_column(column, parent, keep_sequence: keep_sequence)) } }
        own.each { |column| merge_column(columns, column) }
        columns
      end

      # A parent's column as the child gets it: no key, and its default copied, so a serial's copy keeps the parent's sequence.
      def inherited_column(column, parent, keep_sequence:)
        return detached_serial(column.except(:primary_key), parent) unless keep_sequence && column[:own_sequence]

        column.except(:primary_key).merge(own_sequence: owned_sequence(column, parent))
      end

      # A serial whose sequence does not follow its name (a copy, a renamed column or table) reads as the integer it
      # was made from with that sequence as its default (new_column_from_field).
      def detached_serial(column, table)
        return column unless column[:own_sequence]

        without_sequence(column).merge(default: nextval_default(owned_sequence(column, table)))
      end

      # A sequence's nextval as the default PostgreSQL's columns read it, with the ::regclass cast.
      def nextval_default(sequence)
        "-> { #{"nextval('#{sequence}'::regclass)".inspect} }"
      end

      # The sequence a serial uses: the one a rename left it (the mark holds its name), else the one table and column name make.
      def owned_sequence(column, table, suffix = "seq")
        return column[:own_sequence] if column[:own_sequence].is_a?(String)

        schema, _, name = table.rpartition(".")
        [ schema, serial_sequence_name(name, column[:name], suffix) ].reject(&:empty?).join(".")
      end

      # A sequence named for the table and column with any seq\d* suffix makes the column a serial (new_column_from_field).
      def serial_sequence?(sequence, table, column)
        suffix = sequence.to_s[/_(seq\d*)\z/, 1]
        !suffix.nil? && sequence == owned_sequence({ name: column }, table, suffix)
      end

      # A column that loses its own sequence is the integer its serial was made from.
      def without_sequence(column)
        return column unless column[:own_sequence]

        column.except(:own_sequence).merge(type: SERIALS.fetch(column[:type], column[:type]))
      end

      def merge_column(columns, column)
        at = columns.index { |c| c[:name] == column[:name] }
        return columns << column unless at

        # NOT NULL if either is; a replayed column leaves null: out when it allows NULL.
        columns[at] = columns[at].merge(column, null: columns[at][:null] != false && column[:null] != false)
      end

      # mysqldump always terminates CREATE TABLE with ") ENGINE=..." and
      # quotes identifiers with backticks; pg_dump wraps FK updates in
      # "ALTER TABLE ONLY", qualifies types with "::", and uses search_path /
      # extension setup that the other two dialects never emit; sqlite
      # marks autoincrementing primary keys and keeps its own sequence table.
      # Order matters: check MySQL and PostgreSQL markers before sqlite's
      # quoted-identifier fallback.
      def detect_sql_dialect(content)
        return :mysql if content.match?(/\)\s*ENGINE=/i) || content.match?(/CREATE TABLE\s+`/)
        return :postgresql if content.match?(/SET search_path|CREATE EXTENSION|ALTER TABLE ONLY|::\w+/)
        return :sqlite if content.match?(/sqlite_sequence|AUTOINCREMENT|CREATE TABLE\s+(?:IF NOT EXISTS\s+)?"/)

        :unknown
      end

      # MySQL keeps indexes and foreign keys inside the CREATE TABLE body as
      # KEY / UNIQUE KEY / CONSTRAINT lines; the other dialects emit separate
      # statements, so those lines simply never match here.
      def parse_sql_table_body(body, table_name, dialect:, enums:, local:, rails_version:)
        # One definition per line whatever the dump's layout: SQLite writes a
        # table on one line and its foreign key clause across three.
        body = split_top_level(body).map { |definition| definition.gsub(/\s*\n\s*/, " ") }.join("\n")

        key = body[/^\s*PRIMARY KEY\s*\(([^)]*)\)/i, 1]&.scan(/\w+/)
        columns, raw_types = parse_sql_columns(body, dialect: dialect, enums: enums, key: Array(key), table_name: table_name, local: local, rails_version: rails_version)
        table = { columns: columns, indexes: [], foreign_keys: [] }
        table[:primary_key] = SchemaConventions.primary_key_value(key) if key
        uniques = inline_uniques(body, columns)
        columns.each do |column|
          next unless serial_index?(dialect, raw_types[column[:name]], column, key) || (dialect == :mysql && uniques.key?(column[:name]))

          table[:indexes] << serial_index(table[:indexes], column[:name])
        end
        constraints = uniques.map { |column, (name, tail)| [ name, [ column ], tail ] }

        body.each_line do |line|
          line = line.strip.chomp(",")
          case line
          when /\A(?:CONSTRAINT\s+[`"]?\w+[`"]?\s+)?FOREIGN KEY\s*\(([^)]*)\)\s*REFERENCES\s+[`"]?(\w+)[`"]?\s*\(([^)]*)\)(.*)/i
            columns, to, keys, tail = $1, $2, $3, $4
            table[:foreign_keys] << SchemaConventions.foreign_key_entry(table_name, to, columns.scan(/\w+/), keys.scan(/\w+/), **foreign_key_actions(tail))
          when /\A(?:CONSTRAINT\s+[`"]?(\w+)[`"]?\s+)?CHECK\s*(\(.*)/i
            name = $1
            expression = first_paren_group($2)&.strip
            # The MySQL adapter drops the parentheses MySQL wraps a check clause in.
            expression = unwrap_parens(expression) if dialect == :mysql && expression
            (table[:check_constraints] ||= []) << { name: name, expression: expression }.compact if expression
          when INDEX_LINE
            match = $~
            next unless match[:quoted] || dialect == :mysql

            kind = (match[:unique] || match[:typed]).to_s.downcase
            rest = match[:rest]
            group = first_paren_group(rest)
            keys = index_keys(group)
            keys = keys.map { |k| k.start_with?("(") ? mysql_expression_key(k) : k } if dialect == :mysql
            # Rails names a MySQL fulltext or spatial index by type:, any other by its method.
            typed = %w[fulltext spatial].include?(kind)
            using = (match[:using] || rest[(group.to_s.length + 2)..].to_s[/\bUSING\s+(\w+)/i, 1])&.downcase unless typed
            name = match[:quoted] || match[:bare]
            index = name ? { name: name, columns: keys } : serial_index(table[:indexes], keys).slice(:name, :columns)
            index[:unique] = kind == "unique"
            index.merge!(SchemaConventions.index_detail(keys, type: (kind if typed), using: using, **key_options(group)))
            table[:indexes] << index if keys.any?
          when UNIQUE_LINE
            name = $3 || $1
            nulls = $2
            rest = $4
            group = first_paren_group(rest)
            keys = index_keys(group)
            next if keys.empty?

            dialect == :mysql ? table[:indexes] << unique_index(table[:indexes], name, keys) : constraints << [ name, keys, "#{nulls}#{rest[(group.length + 2)..]}" ]
          end
        end
        add_unique_constraints(table, table_name, constraints, columns, rails_version) if postgres_rules?(dialect)

        [ table, raw_types ]
      end

      # An index inside a CREATE TABLE body. Only MySQL writes one, so a name without quotes, or none, is
      # an index there alone; elsewhere KEY and INDEX are not reserved and such a line is a column.
      INDEX_LINE = /\A(?:(?<unique>UNIQUE)\s+(?:KEY|INDEX)|(?<typed>FULLTEXT|SPATIAL)(?:\s+(?:KEY|INDEX))?|KEY|INDEX)
        (?:\s+(?:[`"](?<quoted>\w+)[`"]|(?!USING\b)(?<bare>\w+)))?(?:\s+USING\s+(?<using>\w+))?\s*(?<rest>\(.*)/ix

      # A MySQL functional key part as the connection reads it: MySQL's expression, in parentheses (indexes).
      # shortcut: a replayed expression keeps its written spelling, where MySQL stores `a` + 1 for a+1; normalize it if a tool compares them.
      def mysql_expression_key(key)
        inner = unwrap_parens(key)
        inner.start_with?("(") ? inner : "(#{inner})"
      end

      # A table-level UNIQUE the KEY line above leaves: unnamed, or named without quotes.
      UNIQUE_LINE = /\A(?:CONSTRAINT\s+[`"]?(\w+)[`"]?\s+)?UNIQUE(?:\s+(?:KEY|INDEX))?(\s+NULLS\s+(?:NOT\s+)?DISTINCT)?(?:\s+[`"]?(\w+)[`"]?)?\s*(\(.*)/i
      INLINE_UNIQUE = /(?:\bCONSTRAINT\s+"?(\w+)"?\s+)?(?<![`"])\bUNIQUE\b(?![`"])/i

      # Each column that declares itself UNIQUE: the constraint name it gives, and the clause after it.
      def inline_uniques(body, columns)
        names = columns.map { |column| column[:name] }
        body.each_line.each_with_object({}) do |line, found|
          name, rest = leading_name(line.strip)
          next unless names.include?(name) && !line.strip.match?(/\A(?:PRIMARY|CONSTRAINT|CHECK|UNIQUE|EXCLUDE|FOREIGN)\b/i)

          rest = rest.gsub(/'(?:[^']|'')*'/, "''")
          match = INLINE_UNIQUE.match(rest) or next
          found[name] = [ match[1], match.post_match ]
        end
      end

      # MySQL's unique index: the name given, else its first column's (serial_index).
      def unique_index(indexes, name, columns)
        name ? SchemaConventions.index_entry(name, columns, unique: true) : serial_index(indexes, columns)
      end

      # PostgreSQL keeps one unique constraint per column list, none on the primary key's, under the first name any of them gives,
      # and names the rest <table>_<columns>_key, numbered while the name is taken (transformIndexConstraints, ChooseConstraintName).
      def add_unique_constraints(table, table_name, constraints, columns, rails_version)
        key = Array(table[:primary_key] || columns.select { |c| c[:primary_key] }.map { |c| c[:name] })
        kept = []
        constraints.each do |name, keys, tail|
          next if keys == key

          prior = kept.find { |entry| entry[1] == keys }
          prior ? prior[0] ||= name : kept << [ name, keys, tail ]
        end
        taken = kept.filter_map(&:first)
        kept.each do |name, keys, tail|
          name ||= (0..).lazy.map { |n| serial_sequence_name(table_name.split(".").last, keys.join("_"), "key#{n unless n.zero?}") }.find { |c| !taken.include?(c) }
          taken << name
          add_unique_key(table, unique_constraint(name, keys, tail), rails_version)
        end
      end

      # clause: what follows UNIQUE besides the key list, where NULLS NOT DISTINCT and the deferrable mode are.
      def unique_constraint(name, keys, clause)
        SchemaConventions.unique_constraint_entry(name, keys, deferrable_mode(clause), clause.match?(/\bNULLS\s+NOT\s+DISTINCT\b/i))
      end

      # Rails 7.1 dumps a unique constraint as one, with nulls_not_distinct from 8.0; 7.0 as the unique index behind it
      # (unique_constraints_in_create).
      def add_unique_key(table, constraint, rails_version)
        constraint = constraint.except(:nulls_not_distinct) unless RailsVersion.at_least?(rails_version, "8.0")
        return (table[:unique_constraints] ||= []) << constraint if RailsVersion.at_least?(rails_version, "7.1")

        table[:indexes] << SchemaConventions.index_entry(constraint[:name], constraint[:columns], unique: true)
      end

      # A key that is a column, with any prefix length, operator class, sort
      # order or collation after it. Anything else is an expression.
      COLUMN_KEY = /\A[`"]?(\w+)[`"]?(?:\s*\((\d+)\))?((?:\s+(?:[\w.]+|"[^"]*"))*)\z/

      # Each column key's prefix length, sort order and operator class, as the connection reads them.
      def key_options(list)
        options = { length: {}, order: {}, opclass: {} }
        split_top_level(list.to_s).each do |key|
          match = COLUMN_KEY.match(key.strip) or next
          column, length, words = match[1], match[2], match[3].split
          options[:length][column] = length.to_i if length
          opclass = words.map { |word| word.split(".").last }.find { |word| word.match?(/\A\w+_ops(?:_\w+)?\z/) }
          options[:opclass][column] = opclass if opclass
          desc = "DESC" if words.any? { |word| word.casecmp?("DESC") }
          nulls = match[3][/\bNULLS\s+(?:FIRST|LAST)\b/i]&.upcase&.squeeze(" ")
          order = nulls ? [ desc, nulls ].compact.join(" ") : desc&.downcase
          options[:order][column] = order if order
        end
        options
      end

      # An index's keys, split on top-level commas: a column name, or an
      # expression as the dump spells it (COALESCE(a, '-1'::integer) is one key).
      def index_keys(list)
        return [] if list.nil?

        split_top_level(list).filter_map do |key|
          key = key.strip
          next if key.empty?

          (match = COLUMN_KEY.match(key)) ? match[1] : key
        end
      end

      # Runs of text with nothing a top-level scan stops at, skipped in one regex
      # step so a megabyte dump is not walked a character at a time in Ruby.
      PAREN_RUN = /[^'"`()]+/
      SPLIT_RUN = /[^'"`()\[\],]+/
      DEFAULT_RUN = /[^'"()\[\]\s]+/
      QUOTE_ENDS = { 39 => /'/, 34 => /"/, 96 => /`/ }.freeze

      # Each byte outside quotes that `run` does not skip, its byte offset, and
      # the parenthesis and bracket depth once it is read. Every byte `run` stops at is ASCII.
      def scan_top_level(text, run = SPLIT_RUN)
        scanner = StringScanner.new(text)
        depth = 0
        until scanner.eos?
          next if scanner.skip(run)

          index = scanner.pos
          byte = text.getbyte(index)
          scanner.pos = index + 1
          if (closing = QUOTE_ENDS[byte])
            scanner.skip_until(closing) or break
          else
            depth += 1 if byte == 40 || byte == 91
            depth -= 1 if byte == 41 || byte == 93
            yield byte, index, depth
          end
        end
      end

      # The text inside the first balanced parentheses, quotes respected.
      def first_paren_group(text)
        start = text.to_s.index("(") or return nil
        group = text[start..]
        scan_top_level(group, PAREN_RUN) { |byte, i, depth| return group.byteslice(1, i - 1) if byte == 41 && depth.zero? }
        nil
      end

      # The expression inside one pair of parentheses that encloses all of it.
      def unwrap_parens(expression)
        inner = first_paren_group(expression) if expression.start_with?("(")
        inner && inner.bytesize == expression.bytesize - 2 ? inner.strip : expression
      end

      def split_top_level(body)
        parts = []
        from = 0
        scan_top_level(body) do |byte, i, depth|
          next unless byte == 44 && depth.zero?

          parts << body.byteslice(from, i - from)
          from = i + 1
        end
        rest = body.byteslice(from, body.bytesize - from)
        parts << rest unless rest.strip.empty?
        parts.map(&:strip)
      end

      # Column definitions from a CREATE TABLE body, and each column's type as the dump spells it.
      def parse_sql_columns(body, dialect:, enums:, key:, table_name:, local:, rails_version:)
        columns = []
        raw_types = {}
        body.each_line do |line|
          line = line.strip.chomp(",").strip
          next if line.empty?
          next if line.match?(/\A(PRIMARY|CONSTRAINT|CHECK|UNIQUE|EXCLUDE|FOREIGN)\b/i)
          next if (index = INDEX_LINE.match(line)) && (index[:quoted] || dialect == :mysql)

          # Match: column_name type_with_params [constraints]
          if (col_name, rest = leading_name(line))
            # Extract type: everything before NOT NULL, NULL, DEFAULT, etc.
            declared = rest.split(
              /(?:\A|\s+)(?:NOT\s+NULL|NULL|DEFAULT|PRIMARY|UNIQUE|CONSTRAINT|CHECK|AUTO_INCREMENT|AUTOINCREMENT|CHARACTER\s+SET|COLLATE|COMMENT|GENERATED|REFERENCES)\b/i
            ).first.to_s.strip
            col_type = declared.downcase
            # Only SQLite lets a column declare no type.
            next if col_type.empty? && dialect != :sqlite
            # NOT NULL, and primary keys (implicitly NOT NULL outside SQLite), are the only
            # dump-visible nullability signals.
            nullable = !rest.match?(dialect == :sqlite ? /\bNOT\s+NULL\b/i : /\bNOT\s+NULL\b|\bPRIMARY\s+KEY\b/i)
            primary_key = key == [ col_name ] || rest.match?(/\bPRIMARY\s+KEY\b/i)
            # An array is its element type with the flag, as schema.rb dumps it.
            type, detail = column_type(dialect == :sqlite ? declared : col_type, dialect, primary_key: primary_key)
            enum_type = qualified_name(col_type.delete_suffix("[]")) if col_type.match?(/\A(?:"[^"]+"|[\w.]+)(?:\[\])?\z/)
            type = "enum" if enum_type && enums.key?(enum_type)
            raw_types[col_name] = col_type
            column = { name: col_name, type: type, null: nullable }
            default = sql_default(rest, type, col_type, dialect: dialect, rails_version: rails_version, scale: detail[:scale])
            column[:default] = default unless default.nil?
            column[:primary_key] = true if rest.match?(/\bPRIMARY\s+KEY\b/i)
            column.merge!(auto_increment: true, null: false) if dialect == :mysql && rest.match?(/\bAUTO_INCREMENT\b/i)
            if (at = rest =~ /\bGENERATED\s+ALWAYS\s+AS\s*\(/i) && (expression = first_paren_group(rest[at..]))
              column[:generated] = expression.strip
              column[:stored] = rest.match?(/\)\s*(?:STORED|PERSISTENT)\b/i)
            end
            column[:enum_type] = enum_type if type == "enum"
            column.merge!(detail)
            sequence_default(column, rest, table: table_name, primary_key: primary_key, local: local) if postgres_rules?(dialect)
            comment = rest[/\bCOMMENT\s+'((?:[^']|'')*)'/i, 1]
            column[:comment] = comment.gsub("''", "'") if comment
            collation = rest[/\bCOLLATE\s+(?:pg_catalog\.)?"?([\w.-]+)"?/i, 1]
            column[:collation] = collation if collation
            columns << column
          end
        end
        [ columns, raw_types ]
      end

      # Where a DEFAULT clause ends: the next constraint keyword at the top level.
      DEFAULT_END = /\A\s+(?:NOT\s+NULL|NULL|CONSTRAINT|CHECK|REFERENCES|GENERATED|COLLATE|ON\s+UPDATE|COMMENT|AUTO_INCREMENT|PRIMARY|UNIQUE)\b/i

      # The default as the schema.rb reader reports it: a literal's value, an
      # expression as `-> { "expr" }` (on PostgreSQL only a function), nil for none, NULL or a serial's nextval(...).
      def sql_default(rest, type, raw_type, dialect:, rails_version:, scale: nil)
        start = rest =~ /\bDEFAULT\s+/i or return nil
        text = default_text(rest[(start + Regexp.last_match(0).length)..])
        return nil if text.nil? || text.empty? || text.match?(/\ANULL\z/i) || text.match?(/\Anextval\(/i)

        value = if dialect == :sqlite then sqlite_default(text, type, rails_version, scale)
        elsif (literal = text.match(/\A'((?:[^']|'')*)'(?:::[\w\s\[\]."]+)?\z/))
          quoted = literal[1].gsub("''", "'")
          raw_type.end_with?("[]") ? array_default(quoted, type, scale) : quoted
        elsif text.match?(DECIMAL_TEXT) || text.match?(/\A(?:true|false)\z/i)
          text.downcase
        elsif !postgres_rules?(dialect) || text.match?(PG_FUNCTION)
          "-> { #{text.inspect} }"
        end
        value = boolean_default(value) if type == "boolean"
        value = dumped_decimal(value, scale, server_rounds: dialect == :mysql) if type == "decimal"
        SchemaConventions.format_default(value)
      end

      # A SQLite default as the adapter reads it (extract_value_from_default, has_default_function?): SQLite keeps an
      # expression without its outer parentheses, and what is no literal, number or function is no default. Rails 7.0
      # reads a quoted literal with a | in it as one, and no || concatenation as a function.
      # shortcut: an x'..' blob literal reads as no default, where Rails 7.1 on reads its bytes; decode it if a tool shows one.
      def sqlite_default(text, type, rails_version, scale = nil)
        text = unwrap_parens(text)
        current = RailsVersion.at_least?(rails_version, "7.1")
        if RailsVersion.at_least?(rails_version, "8.1.4") ? text.match?(/\A(?:true|false)\z/i) : RailsVersion.at_least?(rails_version, "8.1") && %w[TRUE FALSE].include?(text)
          sqlite_truth(text, type, scale, rails_version)
        elsif (literal = text.match(current ? /\A(['"])([^|]*)\1\z/m : /\A(['"])(.*)\1\z/m))
          literal[2].gsub(literal[1] * 2, literal[1])
        elsif text.match?(/\A-?\d+(?:\.\d*)?\z/)
          text
        elsif text.match?(current ? SQLITE_FUNCTION : SQLITE_FUNCTION_70)
          "-> { #{text.inspect} }"
        end
      end

      # Rails 8.1.0 reads TRUE and FALSE as that text and 8.1.4 either case as a boolean, which the column's type casts
      # and the dumper writes; a value it cannot cast or dump reads as no default.
      def sqlite_truth(word, type, scale, rails_version)
        unless RailsVersion.at_least?(rails_version, "8.1.4")
          return case type
                 when "integer", "bigint", "decimal" then "0"
                 when "float" then "0.0"
                 when "date", "datetime", "time", "json" then nil
                 else word
                 end
        end

        truth = word.casecmp?("true")
        case type
        when "string", "text" then truth ? "t" : "f"
        when "float" then truth ? "1.0" : "0.0"
        when "decimal" then (truth ? "1" : "0") unless scale&.zero?
        when "integer", "bigint", "date", "datetime", "time" then nil
        else truth.to_s
        end
      end

      BOOLEAN_FALSE = %w[0 f F false FALSE off OFF].freeze

      # ActiveModel::Type::Boolean's cast: an empty string is no value, its false words are false, any other text is true.
      def boolean_default(value)
        return value unless value.is_a?(String) && !value.start_with?("-> {")

        (!BOOLEAN_FALSE.include?(value)).to_s unless value.empty?
      end

      # What PostgreSQL's adapter reads as a function default (has_default_function?, 7.0 to 8.1); any other expression is none.
      PG_FUNCTION = %r{\w+\(.*\)|\(.*\)::\w+|CURRENT_DATE|CURRENT_TIMESTAMP}

      SQLITE_FUNCTION = /\w+\(.*\)|CURRENT_TIME|CURRENT_DATE|CURRENT_TIMESTAMP|\|\|/
      SQLITE_FUNCTION_70 = /\w+\(.*\)|CURRENT_TIME|CURRENT_DATE|CURRENT_TIMESTAMP/

      # The DEFAULT value's text, up to the next constraint at the top level.
      def default_text(text)
        scan_top_level(text, DEFAULT_RUN) do |byte, i, depth|
          return text.byteslice(0, i).strip if depth.zero? && WHITESPACE_BYTES.include?(byte) && text.byteslice(i, text.bytesize - i).match?(DEFAULT_END)
        end
        text.strip
      end

      # A PostgreSQL array literal ({1,NULL} or {a,"b c"}) as Rails dumps it: OID::Array decodes each element and
      # casts it through the column's type. nil when the literal does not parse.
      # shortcut: a float element Infinity or NaN reads as Ruby shows it, where the dump writes ::Float::INFINITY; match it if a tool shows one.
      def array_default(value, type, scale = nil)
        scanner = StringScanner.new(value.strip)
        items = array_items(scanner) or return
        scanner.eos? ? array_cast(items, type, scale) : nil
      end

      # PG::TextDecoder::Array: an unquoted NULL is nil, quotes and backslashes escape.
      def array_items(scanner)
        return unless scanner.skip(/\{\s*/)
        return [] if scanner.skip(/\}/)

        items = []
        loop do
          if scanner.check(/\{/)
            items << (array_items(scanner) or return)
          elsif scanner.skip(/"/)
            items << scanner.scan(/(?:[^"\\]|\\.)*/m).gsub(/\\(.)/m, '\\1')
            return unless scanner.skip(/"/)
          else
            item = scanner.scan(/(?:[^,{}"\\]|\\.)+/m) or return
            items << (item.strip.match?(/\ANULL\z/i) ? nil : item.strip.gsub(/\\(.)/m, '\\1'))
          end
          scanner.skip(/\s*/)
          return items if scanner.skip(/\}/)
          return unless scanner.skip(/,\s*/)
        end
      end

      # Each element as its type's type_cast_for_schema writes it: a NULL decimal as "" (nil.to_s), a time on 2000-01-01.
      def array_cast(items, type, scale)
        items.map do |item|
          next array_cast(item, type, scale) if item.is_a?(Array)
          next (type == "decimal" ? "" : nil) if item.nil?

          case type
          when "integer", "bigint" then item.to_i
          when "float" then FLOAT_WORDS.fetch(item) { item.to_f }
          when "decimal" then dumped_decimal(item, scale)
          when "boolean" then item.empty? ? nil : !%w[f false 0 off].include?(item.downcase)
          when "time" then "2000-01-01 #{item[/\A\d\d:\d\d:\d\d/] || item}"
          else item
          end
        end
      end

      FLOAT_WORDS = { "Infinity" => Float::INFINITY, "-Infinity" => -Float::INFINITY, "NaN" => Float::NAN }.freeze
      # A decimal as a dump writes it, and a number as MySQL reads one: digits on either side of the point and an exponent.
      DECIMAL_TEXT = /\A-?\d+(?:\.\d+)?\z/
      MYSQL_NUMBER = /\A(?<sign>-?)(?=\.?\d)(?<whole>\d*)(?:\.(?<fraction>\d*))?(?<exponent>e[-+]?\d+)?\z/i

      # Rails casts a decimal default to a BigDecimal rounded to the column's scale, whole at scale 0
      # (DecimalWithoutScale casts with to_i), and dumps its to_s. MySQL rounds what it stores to the scale first, a zero unsigned.
      # Text that is no number stays as it is.
      def dumped_decimal(value, scale, server_rounds: false)
        return value unless value.is_a?(String) && value.match?(DECIMAL_TEXT)

        decimal = BigDecimal(value)
        decimal = decimal.round(scale).then { |rounded| rounded.zero? ? rounded.abs : rounded } if server_rounds && scale
        scale&.zero? ? decimal.to_i.to_s : (scale ? decimal.round(scale) : decimal).to_s("F")
      end

      def postgres_rules?(dialect)
        RailsAiContext::DatabaseFamily.of(dialect).postgres_rules?
      end

      # PostgreSQL's serials are not null integers of their size with a sequence.
      SERIALS = { "serial" => "integer", "smallserial" => "smallint", "bigserial" => "bigint" }.freeze

      # A column type as written in SQL, named and sized the way the adapter reads it back.
      def column_type(raw_type, dialect, primary_key: false)
        if postgres_rules?(dialect) && (integer = SERIALS[raw_type.downcase])
          type, detail = column_type(integer, dialect)
          return [ serial_name(type, primary_key), detail.merge(null: false, own_sequence: true) ]
        end
        # MySQL's serial is BIGINT UNSIGNED NOT NULL AUTO_INCREMENT UNIQUE (serial_index).
        return [ "bigint", { unsigned: true, null: false, auto_increment: true } ] if dialect == :mysql && raw_type.casecmp?("serial")
        # MySQL makes a bare bit a bit(1).
        raw_type = "bit(1)" if dialect == :mysql && raw_type.casecmp?("bit")

        type = normalize_sql_type(raw_type.delete_suffix("[]"), dialect)
        detail = type_detail(raw_type, type, dialect)
        detail[:array] = true if raw_type.end_with?("[]") && postgres_rules?(dialect)
        [ type, detail ]
      end

      # MySQL makes a column a statement declares serial unique, apart from the table's whole key (serial_index).
      def serial_index?(dialect, type, column, key)
        dialect == :mysql && type.to_s.casecmp?("serial") && column[:primary_key] != true && Array(key) != [ column[:name] ]
      end

      # The unique index MySQL adds for a serial column or an unnamed UNIQUE: named after its first column, or <column>_2 on when that name is taken.
      # shortcut: none is listed for a serial that is the whole key, where MySQL adds one and MariaDB none; tell the servers apart if a tool needs it.
      def serial_index(indexes, columns)
        column = Array(columns).first
        column = "functional_index" if column.start_with?("(")
        name = column
        suffix = 1
        name = "#{column}_#{suffix += 1}" while indexes.any? { |index| index[:name] == name }
        SchemaConventions.index_entry(name, Array(columns), unique: true)
      end

      # The name PostgreSQL's dumper gives a serial integer or bigint: serial or bigserial, and a bigserial that is the whole key
      # the default key (postgresql/schema_dumper.rb schema_type and default_primary_key?, 7.0 to 8.1).
      def serial_name(type, primary_key)
        return "serial" unless type == "bigint"

        primary_key ? "bigint" : "bigserial"
      end

      NEXTVAL = /\bDEFAULT\s+nextval\('"?([^'"]+)"?'(?:::regclass)?\)/i

      # A nextval default the way PostgreSQL's columns read it (new_column_from_field): a serial when the
      # sequence is the one the column's own name makes, whoever owns it, else the function as its default.
      def sequence_default(column, rest, table:, primary_key:, local:)
        sequence = rest[NEXTVAL, 1] or return
        sequence = local.(qualified_name(sequence))
        if serial_sequence?(sequence, table.split(".").last, column[:name])
          column[:type] = serial_name(column[:type], primary_key)
          column[:own_sequence] = sequence
          column.delete(:default)
        else
          column[:default] = nextval_default(sequence)
        end
      end

      # PostgreSQL's name for a serial's sequence, cut to its 63-byte identifiers (sequence_name_from_parts).
      def serial_sequence_name(table, column, suffix)
        over = [ table, column, suffix ].sum(&:length) + 2 - 63
        if over.positive?
          column_length = [ (63 - suffix.length - 2) / 2, column.length ].min
          over -= column.length - column_length
          column = column[0, column_length - [ over, 0 ].min]
        end
        table = table[0, table.length - over] if over.positive?
        "#{table}_#{column}_#{suffix}"
      end

      # The size a type was given, as schema.rb writes it: varchar(255) is
      # MySQL's default string, 6 a datetime's default precision.
      def type_detail(raw_type, type, dialect)
        detail = {}
        detail[:unsigned] = true if dialect == :mysql && raw_type.match?(/\bunsigned\b/i)
        size = SchemaConventions.mysql_text_size(raw_type) if dialect == :mysql
        detail[:size] = size if size
        # SQLite's type map reads no size off an integer's name.
        limit = INTEGER_LIMITS[raw_type[/\A\w+/].to_s.downcase] unless dialect == :sqlite
        detail[:limit] = limit if type == "integer" && limit
        float = float_limit(raw_type, dialect) if type == "float"
        detail[:limit] = float if float
        sizes = raw_type[/\((\d+(?:\s*,\s*\d+)?)\)/, 1]&.split(",")&.map(&:to_i)
        return detail unless sizes

        detail.merge(sized(type, sizes, dialect))
      end

      # The limit Rails reads off a float type: MySQL's double is 53 (real, float8 and float(25) up are
      # doubles there), PostgreSQL's real is 24 (float4 and float(1) to float(24) are reals there), its
      # array the element's, and SQLite keeps float(n) as written.
      def float_limit(raw_type, dialect)
        base = raw_type.delete_suffix("[]").downcase
        bits = base[/\Afloat\s*\((\d+)\)/, 1]&.to_i
        case dialect
        when :mysql then 53 if base.match?(/\A(?:double|real|float8)\b/) || bits.to_i > 24
        when :sqlite then base[/\((\d+)\)/, 1]&.to_i
        else 24 if %w[real float4].include?(base) || bits&.between?(1, 24)
        end
      end

      # The integer limit Rails reads off a smaller integer type.
      INTEGER_LIMITS = { "smallint" => 2, "int2" => 2, "tinyint" => 1, "mediumint" => 3 }.freeze

      def sized(type, sizes, dialect)
        case type
        when "string"
          sizes.first == 255 && dialect == :mysql ? {} : { limit: sizes.first }
        when "binary" then { limit: sizes.first }
        when "integer" then dialect == :sqlite ? { limit: sizes.first } : {}
        when "decimal" then { precision: sizes.first, scale: sizes[1] || 0 }
        when "datetime", "timestamp", "timestamptz", "time" then dumped_precision(type, sizes.first, dialect)
        else {}
        end
      end

      # The precision schema.rb writes (schema_precision, 7.0 to 8.1): a datetime's default 6 goes unsaid, and MySQL
      # leaves out a time or timestamp's 0.
      # shortcut: MySQL's datetime(0) and PostgreSQL's plain timestamp dump precision: nil, which a column here cannot carry; keep a nil precision if a tool shows it.
      def dumped_precision(type, precision, dialect)
        return {} if precision.nil? || (precision == 6 && %w[datetime timestamp].include?(type)) || (precision.zero? && dialect == :mysql)

        { precision: precision }
      end

      # SQLite's type map (initialize_type_map, 7.0 to 8.1): the last pattern registered that a type matches names it, an
      # alias by its target, and none gives no type. The dumper names a type written bigint in lowercase one (Column#bigint?).
      SQLITE_TYPES = [
        [ /boolean/i, "boolean" ], [ /char/i, "string" ], [ /binary/i, "binary" ], [ /text/i, "text" ], [ /date/i, "date" ],
        [ /time/i, "time" ], [ /datetime/i, "datetime" ], [ /float/i, "float" ], [ /blob/i, "binary" ], [ /clob/i, "text" ],
        [ /timestamp/i, "datetime" ], [ /numeric/i, "decimal" ], [ /number/i, "decimal" ], [ /double/i, "float" ],
        [ /\Ajson/i, "json" ], [ /decimal/i, "decimal" ], [ /int/i, "integer" ]
      ].reverse.freeze

      def sqlite_type(type)
        return "bigint" if type.match?(/\Abigint\b/)

        SQLITE_TYPES.find { |pattern, _| pattern.match?(type) }&.last
      end

      # MySQL's type map is that one with year and bit last (abstract_mysql_adapter.rb, 7.0 to 8.1); its other additions
      # rename no type the case below leaves, and the dumper writes an enum or set as declared (schema_type).
      MYSQL_TYPES = [ [ /bit/i, "binary" ], [ /year/i, "integer" ], *SQLITE_TYPES ].freeze

      def mysql_type(type)
        return type if type.match?(/\A(?:enum|set)\b/i)

        MYSQL_TYPES.find { |pattern, _| pattern.match?(type) }&.last
      end

      # The type schema.rb names: pg_dump qualifies an extension's type with its
      # schema, MySQL appends unsigned, and a size never changes the name.
      def normalize_sql_type(type, dialect = nil)
        return sqlite_type(type) if dialect == :sqlite

        # MySQL's boolean columns are a sized tinyint; bare tinyint is a real 1-byte integer, and SQLite's tinyint(1) one of limit 1.
        return "boolean" if dialect == :mysql && type.start_with?("tinyint(1)")

        type = type.sub(/\A(?:"[^"]+"|\w+)\.(?=[\w"])/, "")
        base = type.gsub(/\s*\([^)]*\)/, "").gsub(/\s+(?:unsigned|signed|zerofill)\b/i, "").strip

        case base
        when /\A(?:integer|int|int4|smallint|int2|tinyint|mediumint)\z/i then "integer"
        # SQLite's type map reads bigint alone as one.
        when /\Abigint\z/i then "bigint"
        when /\Aint8\z/i then dialect == :sqlite ? "integer" : "bigint"
        when /\A(?:character varying|varchar|character|char|bpchar)\z/i then "string"
        when /\A(?:text|longtext|mediumtext|tinytext)\z/i then "text"
        when /\A(?:boolean|bool)\z/i then "boolean"
        # SQLite's type map reads a timestamptz as a datetime.
        when /\A(?:timestamp with time zone|timestamptz)\z/i then dialect == :sqlite ? "datetime" : "timestamptz"
        # MySQL's dumper keeps a timestamp column a timestamp.
        when /\Atimestamp(?: without time zone)?\z/i then dialect == :mysql ? "timestamp" : "datetime"
        when /\Adatetime\z/i then "datetime"
        when /\Adate\z/i then "date"
        when /\Atime(?: without time zone)?\z/i then "time"
        when /\A(?:numeric|decimal)\z/i then "decimal"
        when /\A(?:float|double|double precision|real|float4|float8)\z/i then "float"
        when /\Ajsonb\z/i then "jsonb"
        when /\Ajson\z/i then "json"
        when /\A(?:bytea|longblob|mediumblob|tinyblob|blob|binary|varbinary)\z/i then "binary"
        # MariaDB has a uuid type, which Rails' MySQL type map does not name.
        when /\Auuid\z/i then "uuid" unless dialect == :mysql
        when /\A(?:inet|citext|hstore)\z/i then base.downcase
        when /\Aarray\z/i then "array"
        else dialect == :mysql ? mysql_type(type) : type
        end
      end
    end
  end
end
