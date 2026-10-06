# frozen_string_literal: true

require "strscan"

module RailsAiContext
  module Introspectors
    # Reads a structure.sql dump into the same table shape the other static
    # schema sources produce. Pure text in, tables out - the caller owns the
    # file, the size cap, and whatever presentation wraps the result.
    module StructureSqlReader
      module_function

      # @return [Hash] { dialect: Symbol, tables: { name => { columns:, indexes:, foreign_keys: } } }
      def parse(content)
        tables = {}
        dialect = detect_sql_dialect(content)
        enums = enum_types(content)

        # Every table the file creates, by schema-qualified name, so a parent
        # outside the listed tables still resolves.
        all = {}
        each_create_table(content) do |qualified, body, inherits, trailer|
          name = qualified_name(qualified)
          shown = shown_name(name)
          next if shown.start_with?("ar_internal_metadata", "schema_migrations")
          # SQLite's own tables; Rails' data_sources leaves them out.
          next if dialect == :sqlite && shown.start_with?("sqlite_")

          table, raw_types = parse_sql_table_body(body, shown, dialect, enums)
          comment = trailer[/\bCOMMENT\s*=\s*'((?:[^']|'')*)'/i, 1]
          table[:comment] = comment.gsub("''", "'") if comment
          all[name] = { table: table, raw_types: raw_types, parents: inherits && split_top_level(inherits).map { |parent| qualified_name(parent) } }
          tables[shown] = table if shown.match?(/\A\w+\z/)
        end

        found_views = views(content)
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
                                                        nulls_not_distinct: options.match?(/\bNULLS\s+NOT\s+DISTINCT\b/i), **key_options(group))
          target = all.dig(qualified_name(table), :table) || found_views[shown_name(qualified_name(table))]
          (target[:indexes] ||= []) << { name: idx_name, columns: keys, unique: !!unique, where: where }.compact.merge(detail) if target
        end

        content.scan(/ALTER TABLE\s+(?:ONLY\s+)?#{QUALIFIED_NAME}\s+ADD CONSTRAINT\s+("[^"]+"|\w+)\s+UNIQUE\s*(?:NULLS\s+(?:NOT\s+)?DISTINCT\s*)?\(([^)]*)\)([^;]*)/m) do |table, name, cols, tail|
          table = all.dig(qualified_name(table), :table) or next
          (table[:unique_constraints] ||= []) << SchemaConventions.unique_constraint_entry(name.delete('"'), cols.scan(/\w+/), deferrable_mode(tail))
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
          all.dig(from, :table, :foreign_keys)&.push(SchemaConventions.foreign_key_entry(shown_name(from), shown_name(qualified_name(to)), cols.scan(/\w+/), pks.scan(/\w+/), **foreign_key_actions(tail)))
        end

        alters = Hash.new { |h, k| h[k] = [] }
        content.scan(/^ALTER TABLE (?:ONLY )?#{QUALIFIED_NAME} ALTER COLUMN "?(\w+)"? SET (NOT NULL|DEFAULT .+);$/) do |table, column, change|
          alters[qualified_name(table)] << [ column, change ]
        end
        resolved = {}
        all.each_key { |name| resolve_columns(name, all, alters, resolved) }

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
          name = qualified_name(partition)
          tables.delete(shown_name(name)) if name.start_with?("public.")
        end

        { dialect: dialect, tables: tables, enums: enums.map { |name, values| { name: name, values: values } },
          views: found_views, virtual_tables: virtual_tables(content), extensions: extensions(content) }
      end

      # As PostgreSQL's connection names them: qualified unless in the public schema.
      def extensions(content)
        content.scan(/^CREATE EXTENSION (?:IF NOT EXISTS )?("[^"]+"|\w+)(?: WITH SCHEMA ("[^"]+"|\w+))?/).map do |name, schema|
          [ (schema.delete('"') unless schema.nil? || schema == "public"), name.delete('"') ].compact.join(".")
        end
      end

      # Each view by the name the app reads it under, a later definition of a name replacing a placeholder.
      def views(content)
        content.scan(VIEW).each_with_object({}) do |(materialized, name, sql), found|
          name = qualified_name(name)
          found[shown_name(name)] = { materialized: !materialized.nil?, sql: sql.strip } if shown_name(name).match?(/\A\w+\z/)
        end
      end

      def virtual_tables(content)
        content.scan(VIRTUAL_TABLE).to_h do |name, mod, arguments|
          [ shown_name(qualified_name(name)), { module: mod, arguments: split_top_level(arguments.to_s) } ]
        end
      end

      # PostgreSQL's enum types, by the name schema.rb gives them, with their labels.
      def enum_types(content)
        content.scan(/CREATE TYPE\s+#{QUALIFIED_NAME}\s+AS\s+ENUM\s*\(([^;]*)\)\s*;/i).to_h do |name, labels|
          [ shown_name(qualified_name(name)), split_top_level(labels).map { |label| label.delete_prefix("'").delete_suffix("'").gsub("''", "'") } ]
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

      # Each CREATE TABLE's name, body and INHERITS list. The body ends at the
      # parenthesis that closes it, whatever the line layout or terminator: SQLite
      # closes mid-line after a multi-line foreign key, MySQL adds ENGINE=, and
      # a Rails 7 SQLite dump through sqlite_master writes no semicolon.
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

      # A table name, optionally schema-qualified, each part bare or quoted.
      QUALIFIED_NAME = /((?:(?:"[^"]+"|`[^`]+`|\w+)\.)?(?:"[^"]+"|`[^`]+`|\w+))/
      INHERITS_KEYWORD = /\s*INHERITS\b/i
      # The optional INHERITS list after a CREATE TABLE body.
      INHERITS = /(?:#{INHERITS_KEYWORD}\s*\(([^)]*)\))?/
      CREATE_TABLE = /CREATE TABLE\s+(?:IF NOT EXISTS\s+)?#{QUALIFIED_NAME}\s*(?=\()/i
      # mysqldump wraps the statement in version comments and names an algorithm, definer and security first;
      # sqlite3 closes it with a /* name(columns) */ comment.
      VIEW = /\bCREATE\s+(?:OR\s+REPLACE\s+)?(?:(?:ALGORITHM|DEFINER|SQL\s+SECURITY)\b[^;]*?\s)?(?:TEMP(?:ORARY)?\s+)?(MATERIALIZED\s+)?VIEW\s+(?:IF\s+NOT\s+EXISTS\s+)?#{QUALIFIED_NAME}(?:\s*\([^)]*\))?\s+AS\s+(.*?)(?:\s+WITH\s+(?:NO\s+)?DATA)?(?:\s*\/\*\s*[\w"`]+\([^)]*\)\s*\*\/)?\s*(?:\*\/)?\s*;/im
      VIRTUAL_TABLE = /CREATE\s+VIRTUAL\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?#{QUALIFIED_NAME}\s+USING\s+(\w+)\s*(?:\(([^)]*)\))?/i

      # "schema.name" with quotes removed; an unqualified name is in public.
      def qualified_name(text)
        parts = text.strip.scan(/"([^"]+)"|`([^`]+)`|(\w+)/).map { |groups| groups.compact.first }
        parts.unshift("public") if parts.size == 1
        parts.join(".")
      end

      def shown_name(name)
        SchemaConventions.local_name(name)
      end

      # Each parent's columns, then the child's own. pg_dump writes only local
      # columns and sets an inherited one's NOT NULL and default by ALTER.
      def resolve_columns(name, all, alters, resolved)
        entry = all[name]
        return entry if resolved[name]

        resolved[name] = true
        columns = []
        raw_types = {}
        unresolved = []
        entry[:parents]&.each do |parent|
          unless all[parent]
            unresolved << shown_name(parent)
            next
          end

          resolved_parent = resolve_columns(parent, all, alters, resolved)
          resolved_parent[:table][:columns].each { |column| merge_column(columns, column.dup) }
          raw_types = resolved_parent[:raw_types].merge(raw_types)
          unresolved.concat(Array(resolved_parent[:table][:inherits_unresolved]))
        end
        entry[:table][:columns].each { |column| merge_column(columns, column) }
        entry[:raw_types] = raw_types.merge(entry[:raw_types])

        alters[name].each do |column_name, change|
          column = columns.find { |c| c[:name] == column_name } or next
          if change == "NOT NULL"
            column[:null] = false
          else
            default = sql_default(change, column[:type], entry[:raw_types].fetch(column_name))
            default.nil? ? column.delete(:default) : column[:default] = default
          end
        end
        entry[:table][:columns] = columns
        entry[:table][:inherits_unresolved] = unresolved.uniq if unresolved.any?
        entry
      end

      def merge_column(columns, column)
        at = columns.index { |c| c[:name] == column[:name] }
        return columns << column unless at

        columns[at] = columns[at].merge(column, null: columns[at][:null] && column[:null])
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
      def parse_sql_table_body(body, table_name, dialect = nil, enums = {})
        # One definition per line whatever the dump's layout: SQLite writes a
        # table on one line and its foreign key clause across three.
        body = split_top_level(body).map { |definition| definition.gsub(/\s*\n\s*/, " ") }.join("\n")

        columns, raw_types = parse_sql_columns(body, dialect, enums)
        table = { columns: columns, indexes: [], foreign_keys: [] }
        if (key = body[/^\s*PRIMARY KEY\s*\(([^)]*)\)/i, 1])
          table[:primary_key] = SchemaConventions.primary_key_value(key.scan(/\w+/))
        end

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
          when /\A(UNIQUE\s+|FULLTEXT\s+|SPATIAL\s+)?(?:KEY|INDEX)\s+[`"](\w+)[`"]\s*(\(.*)/i
            # Captured to locals first: the parsing below runs more regexes,
            # which would clobber $~ before the hash literal reads it.
            kind = $1.to_s.strip.downcase
            idx_name = $2
            rest = $3
            group = first_paren_group(rest)
            keys = index_keys(group)
            # Rails names a MySQL fulltext or spatial index by type:, any other by its method.
            typed = %w[fulltext spatial].include?(kind)
            using = rest[(group.to_s.length + 2)..].to_s[/\bUSING\s+(\w+)/i, 1]&.downcase unless typed
            index = { name: idx_name, columns: keys, unique: kind == "unique" }
            index.merge!(SchemaConventions.index_detail(keys, type: (kind if typed), using: using, **key_options(group)))
            table[:indexes] << index if keys.any?
          end
        end

        [ table, raw_types ]
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
      SPLIT_RUN = /[^'"`(),]+/
      DEFAULT_RUN = /[^'"()\s]+/
      QUOTE_ENDS = { 39 => /'/, 34 => /"/, 96 => /`/ }.freeze

      # Each byte outside quotes that `run` does not skip, its byte offset, and
      # the parenthesis depth once it is read. Every byte `run` stops at is ASCII.
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
            depth += 1 if byte == 40
            depth -= 1 if byte == 41
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
      def parse_sql_columns(body, dialect = nil, enums = {})
        columns = []
        raw_types = {}
        body.each_line do |line|
          line = line.strip.chomp(",").strip
          next if line.empty?
          next if line.match?(/\A(PRIMARY|CONSTRAINT|CHECK|UNIQUE|EXCLUDE|FOREIGN)\b/i)
          # KEY/INDEX are non-reserved words in PostgreSQL, so pg_dump emits
          # bare `key` or `index` columns unquoted. mysqldump always backticks
          # inline index names ("KEY `name` (...)"), so a quoted name after
          # KEY/INDEX is the reliable signal that this line is an index
          # definition rather than a column named "key" or "index".
          next if line.match?(/\A(?:UNIQUE\s+|FULLTEXT\s+|SPATIAL\s+)?(?:KEY|INDEX)\s+[`"]/i)

          # Match: column_name type_with_params [constraints]
          if (match = line.match(/\A[`"]?(\w+)[`"]?\s+(.+)/))
            col_name = match[1]
            rest = match[2]
            # Extract type: everything before NOT NULL, NULL, DEFAULT, etc.
            col_type = rest.split(
              /\s+(?:NOT\s+NULL|NULL|DEFAULT|PRIMARY|UNIQUE|CONSTRAINT|CHECK|AUTO_INCREMENT|AUTOINCREMENT|CHARACTER\s+SET|COLLATE|COMMENT|GENERATED|REFERENCES)\b/i
            ).first&.strip&.downcase
            next unless col_type && !col_type.empty?
            # NOT NULL, and primary keys (implicitly NOT NULL), are the only
            # dump-visible nullability signals.
            nullable = !rest.match?(/\bNOT\s+NULL\b|\bPRIMARY\s+KEY\b/i)
            # An array is its element type with the flag, as schema.rb dumps it.
            type = normalize_sql_type(col_type.delete_suffix("[]"), dialect)
            enum_type = shown_name(qualified_name(col_type.delete_suffix("[]"))) if col_type.match?(/\A(?:"[^"]+"|[\w.]+)(?:\[\])?\z/)
            type = "enum" if enum_type && enums.key?(enum_type)
            raw_types[col_name] = col_type
            column = { name: col_name, type: type, null: nullable }
            default = sql_default(rest, type, col_type)
            column[:default] = default unless default.nil?
            column[:array] = true if col_type.end_with?("[]")
            column[:primary_key] = true if rest.match?(/\bPRIMARY\s+KEY\b/i)
            if (at = rest =~ /\bGENERATED\s+ALWAYS\s+AS\s*\(/i) && (expression = first_paren_group(rest[at..]))
              column[:generated] = expression.strip
              column[:stored] = rest.match?(/\)\s*(?:STORED|PERSISTENT)\b/i)
            end
            column[:enum_type] = enum_type if type == "enum"
            column.merge!(type_detail(col_type, type, dialect))
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
      # expression as `-> { "expr" }`, nil for none, NULL or a serial's nextval(...).
      def sql_default(rest, type, raw_type)
        start = rest =~ /\bDEFAULT\s+/i or return nil
        text = default_text(rest[(start + Regexp.last_match(0).length)..])
        return nil if text.nil? || text.empty? || text.match?(/\ANULL\z/i) || text.match?(/\Anextval\(/i)

        value = if (literal = text.match(/\A'((?:[^']|'')*)'(?:::[\w\s\[\]."]+)?\z/))
          quoted = literal[1].gsub("''", "'")
          if raw_type.end_with?("[]") then array_default(quoted, raw_type)
          elsif type == "boolean" then { "0" => "false", "1" => "true" }.fetch(quoted, quoted)
          else quoted
          end
        elsif text.match?(/\A-?\d+(?:\.\d+)?\z/) || text.match?(/\A(?:true|false)\z/i)
          text.downcase
        else
          "-> { #{text.inspect} }"
        end
        SchemaConventions.format_default(value)
      end

      # The DEFAULT value's text, up to the next constraint at the top level.
      def default_text(text)
        scan_top_level(text, DEFAULT_RUN) do |byte, i, depth|
          return text.byteslice(0, i).strip if depth.zero? && WHITESPACE_BYTES.include?(byte) && text.byteslice(i, text.bytesize - i).match?(DEFAULT_END)
        end
        text.strip
      end

      # A PostgreSQL array literal ({1,2} or {a,"b c"}) the way Rails dumps
      # the array: [1, 2] for numbers, ["a", "b c"] otherwise.
      def array_default(value, raw_type)
        inner = value.delete_prefix("{").delete_suffix("}")
        return [] if inner.empty?

        items = split_top_level(inner).map { |item| item.strip.delete_prefix('"').delete_suffix('"') }
        numeric = raw_type.match?(/\A(?:integer|bigint|smallint|numeric|double precision|real|decimal)/)
        numeric ? items.map { |item| item.include?(".") ? item.to_f : item.to_i } : items
      end

      # The size a type was given, as schema.rb writes it: varchar(255) is
      # MySQL's default string, 6 a datetime's default precision.
      def type_detail(raw_type, type, dialect)
        detail = {}
        detail[:unsigned] = true if raw_type.match?(/\bunsigned\b/i)
        size = SchemaConventions.mysql_text_size(raw_type) if dialect == :mysql
        detail[:size] = size if size
        limit = INTEGER_LIMITS[raw_type[/\A\w+/]]
        detail[:limit] = limit if type == "integer" && limit
        sizes = raw_type[/\((\d+(?:\s*,\s*\d+)?)\)/, 1]&.split(",")&.map(&:to_i)
        return detail unless sizes

        detail.merge(sized(type, sizes, dialect))
      end

      # The integer limit Rails reads off a smaller integer type.
      INTEGER_LIMITS = { "smallint" => 2, "int2" => 2, "tinyint" => 1, "mediumint" => 3 }.freeze

      def sized(type, sizes, dialect)
        case type
        when "string"
          sizes.first == 255 && dialect == :mysql ? {} : { limit: sizes.first }
        when "binary" then { limit: sizes.first }
        when "decimal" then { precision: sizes.first, scale: sizes[1] || 0 }
        when "datetime" then [ 0, 6 ].include?(sizes.first) ? {} : { precision: sizes.first }
        when "time" then sizes.first.zero? ? {} : { precision: sizes.first }
        else {}
        end
      end

      # The type schema.rb names: pg_dump qualifies an extension's type with its
      # schema, MySQL appends unsigned, and a size never changes the name.
      def normalize_sql_type(type, dialect = nil)
        # MySQL's boolean columns are a sized tinyint; bare tinyint is a real 1-byte integer.
        return "boolean" if type.start_with?("tinyint(1)")

        type = type.sub(/\A(?:"[^"]+"|\w+)\.(?=[\w"])/, "")
        base = type.gsub(/\s*\([^)]*\)/, "").gsub(/\s+(?:unsigned|signed|zerofill)\b/i, "").strip

        case base
        when /\A(?:integer|int|int4|smallint|int2|tinyint|mediumint)\z/i then "integer"
        when /\A(?:bigint|int8)\z/i then "bigint"
        when /\A(?:character varying|varchar|character|char|bpchar)\z/i then "string"
        when /\A(?:text|longtext|mediumtext|tinytext)\z/i then "text"
        when /\A(?:boolean|bool)\z/i then "boolean"
        when /\A(?:timestamp with time zone|timestamptz)\z/i then "timestamptz"
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
        when /\A(?:uuid|inet|citext|hstore)\z/i then base.downcase
        when /\Aarray\z/i then "array"
        else type
        end
      end
    end
  end
end
