# frozen_string_literal: true

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

        # Identifier quoting differs per dump tool: pg_dump uses bare or
        # "quoted" names with a public. prefix, mysqldump uses `backticks` and
        # terminates CREATE TABLE with ") ENGINE=...;", sqlite uses "quotes"
        # and IF NOT EXISTS. The body is captured up to the closing paren at
        # line start because MySQL's trailer means ");" alone never appears.
        # The negative lookahead in the body keeps a single-line CREATE TABLE
        # (e.g. sqlite's schema_migrations) from swallowing every table that
        # follows it: without it, the lazy scan has no "\n)" to stop at inside
        # that one-line statement, so it keeps consuming lines - including the
        # next CREATE TABLE - until it finds one.
        content.scan(/CREATE TABLE\s+(?:IF NOT EXISTS\s+)?(?:public\.)?[`"]?(\w+)[`"]?\s*\(((?:(?!CREATE TABLE).)*?)^\)/m) do |table_name, body|
          next if table_name.start_with?("ar_internal_metadata", "schema_migrations")

          tables[table_name] = parse_sql_table_body(body, table_name)
        end

        # Single-line CREATE TABLE statements (sqlite emits these for tiny
        # tables) close with ");" on the same line and miss the multi-line
        # scan above.
        content.scan(/CREATE TABLE\s+(?:IF NOT EXISTS\s+)?(?:public\.)?[`"]?(\w+)[`"]?\s*\(([^\n]*)\);/) do |table_name, body|
          next if table_name.start_with?("ar_internal_metadata", "schema_migrations")

          tables[table_name] ||= parse_sql_table_body(body, table_name)
        end

        content.scan(/CREATE (UNIQUE )?INDEX\s+(?:CONCURRENTLY\s+)?(?:IF NOT EXISTS\s+)?[`"]?(\w+)[`"]?\s+ON\s+(?:ONLY\s+)?(?:public\.)?[`"]?(\w+)[`"]?([^;]*)/m) do |unique, idx_name, table, rest|
          group = first_paren_group(rest)
          keys = index_keys(group)
          next if keys.empty?

          # The condition follows the key list, never inside it.
          where = rest[(rest.index("(") + group.length + 2)..][/\bWHERE\s+(.+)\z/mi, 1]&.strip
          tables[table]&.dig(:indexes)&.push({ name: idx_name, columns: keys, unique: !!unique, where: where }.compact)
        end

        content.scan(/ALTER TABLE\s+(?:ONLY\s+)?(?:public\.)?[`"]?(\w+)[`"]?\s+ADD CONSTRAINT[^;]*?PRIMARY KEY\s*\(([^)]*)\)/m) do |table, cols|
          tables[table][:primary_key] = SchemaConventions.primary_key_value(cols.scan(/\w+/)) if tables[table]
        end

        # [^;]*? keeps the match inside one statement: with .*? a pkey-only
        # ADD CONSTRAINT would swallow up to the FOREIGN KEY of a LATER
        # statement and attribute the FK to the wrong table.
        content.scan(/ALTER TABLE\s+(?:ONLY\s+)?(?:public\.)?[`"]?(\w+)[`"]?\s+ADD CONSTRAINT[^;]*?FOREIGN KEY\s*\([`"]?(\w+)[`"]?\)\s*REFERENCES\s+(?:public\.)?[`"]?(\w+)[`"]?\s*\([`"]?(\w+)[`"]?\)/m) do |from, col, to, pk|
          tables[from]&.dig(:foreign_keys)&.push({ from_table: from, to_table: to, column: col, primary_key: pk })
        end

        { dialect: detect_sql_dialect(content), tables: tables }
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
      def parse_sql_table_body(body, table_name)
        # sqlite's .schema emits whole CREATE TABLE statements on one line;
        # the per-line parsers below would then see a single "line" and keep
        # only its first column. Split such bodies on top-level commas first.
        body = split_single_line_sql_body(body) unless body.include?("\n")

        table = { columns: parse_sql_columns(body), indexes: [], foreign_keys: [] }
        if (key = body[/^\s*PRIMARY KEY\s*\(([^)]*)\)/i, 1])
          table[:primary_key] = SchemaConventions.primary_key_value(key.scan(/\w+/))
        end

        body.each_line do |line|
          line = line.strip.chomp(",")
          case line
          when /\ACONSTRAINT\s+[`"]?\w+[`"]?\s+FOREIGN KEY\s*\([`"]?(\w+)[`"]?\)\s*REFERENCES\s+[`"]?(\w+)[`"]?\s*\([`"]?(\w+)[`"]?\)/i
            table[:foreign_keys] << { from_table: table_name, to_table: $2, column: $1, primary_key: $3 }
          when /\A(UNIQUE\s+)?(?:KEY|INDEX)\s+[`"](\w+)[`"]\s*(\(.*)/i
            # Captured to locals first: the parsing below runs more regexes,
            # which would clobber $~ before the hash literal reads it.
            unique = !$1.nil?
            idx_name = $2
            keys = index_keys(first_paren_group($3))
            table[:indexes] << { name: idx_name, columns: keys, unique: unique } if keys.any?
          end
        end

        table
      end

      # A key that is a column, with any prefix length, operator class, sort
      # order or collation after it. Anything else is an expression.
      COLUMN_KEY = /\A[`"]?(\w+)[`"]?(?:\s*\(\d+\))?(?:\s+(?:[\w.]+|"[^"]*"))*\z/

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

      # Each character outside quotes, its index, and the parenthesis depth
      # once it is read. `quotes` are the characters that open a quoted run.
      def scan_top_level(text, quotes = "'\"`")
        depth = 0
        quote = nil
        text.each_char.with_index do |ch, i|
          if quote
            quote = nil if ch == quote
          elsif quotes.include?(ch)
            quote = ch
          else
            depth += 1 if ch == "("
            depth -= 1 if ch == ")"
            yield ch, i, depth
          end
        end
      end

      # The text inside the first balanced parentheses, quotes respected.
      def first_paren_group(text)
        start = text.to_s.index("(") or return nil
        group = text[start..]
        scan_top_level(group) { |ch, i, depth| return group[1, i - 1] if ch == ")" && depth.zero? }
        nil
      end

      # A one-line CREATE TABLE body as one definition per line, split on the
      # commas outside parentheses and quotes, so numeric(10,2) survives.
      def split_single_line_sql_body(body)
        split_top_level(body).join("\n")
      end

      def split_top_level(body)
        parts = []
        from = 0
        scan_top_level(body) do |ch, i, depth|
          next unless ch == "," && depth.zero?

          parts << body[from...i]
          from = i + 1
        end
        rest = body[from..]
        parts << rest unless rest.strip.empty?
        parts.map(&:strip)
      end

      # Parse column definitions from a CREATE TABLE body
      def parse_sql_columns(body)
        columns = []
        body.each_line do |line|
          line = line.strip.chomp(",").strip
          next if line.empty?
          next if line.match?(/\A(PRIMARY|CONSTRAINT|CHECK|UNIQUE|EXCLUDE|FOREIGN)\b/i)
          # KEY/INDEX are non-reserved words in PostgreSQL, so pg_dump emits
          # bare `key` or `index` columns unquoted. mysqldump always backticks
          # inline index names ("KEY `name` (...)"), so a quoted name after
          # KEY/INDEX is the reliable signal that this line is an index
          # definition rather than a column named "key" or "index".
          next if line.match?(/\A(?:UNIQUE\s+)?(?:KEY|INDEX)\s+[`"]/i)

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
            type = normalize_sql_type(col_type.delete_suffix("[]"))
            column = { name: col_name, type: type, null: nullable }
            default = sql_default(rest, type, col_type)
            column[:default] = default unless default.nil?
            column[:array] = true if col_type.end_with?("[]")
            columns << column
          end
        end
        columns
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
        scan_top_level(text, "'\"") do |ch, i, depth|
          return text[0, i].strip if depth.zero? && ch.match?(/\s/) && text[i..].match?(DEFAULT_END)
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

      def normalize_sql_type(type)
        # MySQL's boolean columns are a sized tinyint. This has to run
        # before the size-stripping below (and before the generic tinyint
        # match) because bare tinyint is a real 1-byte integer column.
        return "boolean" if type.start_with?("tinyint(1)")

        base = type.sub(/\(.+\z/m, "").strip

        case base
        when /\Ainteger\z/i, /\Aint\z/i, /\Aint4\z/i, /\Atinyint\z/i, /\Amediumint\z/i then "integer"
        when /\Abigint\z/i, /\Aint8\z/i then "bigint"
        when /\Asmallint\z/i, /\Aint2\z/i then "smallint"
        when /\Acharacter varying\z/i, /\Avarchar\z/i then "string"
        when /\Atext\z/i, /\Alongtext\z/i, /\Amediumtext\z/i, /\Atinytext\z/i then "text"
        when /\Aboolean\z/i, /\Abool\z/i then "boolean"
        when /\Atimestamp/i, /\Adatetime\z/i then "datetime"
        when /\Adate\z/i then "date"
        when /\Atime\z/i then "time"
        when /\Anumeric\z/i, /\Adecimal\z/i then "decimal"
        when /\Afloat/i, /\Adouble/i then "float"
        when /\Ajsonb?\z/i then "json"
        when /\Auuid\z/i then "uuid"
        when /\Ainet\z/i then "inet"
        when /\Acitext\z/i then "citext"
        when /\Aarray\z/i then "array"
        when /\Ahstore\z/i then "hstore"
        when /\Alongblob\z/i, /\Amediumblob\z/i, /\Ablob\z/i, /\Abinary\z/i, /\Avarbinary\z/i then "binary"
        else type
        end
      end
    end
  end
end
