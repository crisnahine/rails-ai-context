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

        content.scan(/CREATE (UNIQUE )?INDEX\s+(?:IF NOT EXISTS\s+)?[`"]?(\w+)[`"]?\s+ON\s+(?:public\.)?[`"]?(\w+)[`"]?.*?\((.+?)\)/m) do |unique, idx_name, table, cols|
          col_list = cols.scan(/\w+/) - %w[btree gin gist hash]
          tables[table]&.dig(:indexes)&.push({ name: idx_name, columns: col_list, unique: !!unique })
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

        body.each_line do |line|
          line = line.strip.chomp(",")
          case line
          when /\ACONSTRAINT\s+[`"]?\w+[`"]?\s+FOREIGN KEY\s*\([`"]?(\w+)[`"]?\)\s*REFERENCES\s+[`"]?(\w+)[`"]?\s*\([`"]?(\w+)[`"]?\)/i
            table[:foreign_keys] << { from_table: table_name, to_table: $2, column: $1, primary_key: $3 }
          when /\A(UNIQUE\s+)?(?:KEY|INDEX)\s+[`"](\w+)[`"]\s*\(([^)]*)\)/i
            # $1/$2/$3 must be captured to locals before any further regex
            # call: String#scan below re-runs matching and would otherwise
            # clobber $~ (and so $1) before the hash literal reads it.
            unique = !$1.nil?
            idx_name = $2
            cols = $3.scan(/\w+/)
            table[:indexes] << { name: idx_name, columns: cols, unique: unique }
          end
        end

        table
      end

      # Rewrite a one-line CREATE TABLE body as one definition per line,
      # splitting on commas that sit outside parentheses and quotes (so
      # numeric(10,2) and quoted defaults survive intact).
      def split_single_line_sql_body(body)
        parts = []
        current = +""
        depth = 0
        quote = nil
        body.each_char do |ch|
          if quote
            quote = nil if ch == quote
            current << ch
          elsif ch == "'" || ch == '"' || ch == "`"
            quote = ch
            current << ch
          elsif ch == "("
            depth += 1
            current << ch
          elsif ch == ")"
            depth -= 1
            current << ch
          elsif ch == "," && depth.zero?
            parts << current
            current = +""
          else
            current << ch
          end
        end
        parts << current unless current.strip.empty?
        parts.map(&:strip).join("\n")
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
            columns << { name: col_name, type: normalize_sql_type(col_type), null: nullable }
          end
        end
        columns
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
