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
      # search_path: the database's configured schema_search_path. rails_version: the app's,
      # whose connection names extensions and enum types (PgNaming). dialect: the database's, when the caller knows it.
      # own_sequences: keep the own_sequence mark on each column a serial's sequence backs, which a bigint key's name does not
      # show, and the auto_increment mark on MySQL's.
      def parse(content, search_path: PgNaming::DEFAULT_SEARCH_PATH, rails_version: nil, dialect: nil, own_sequences: false)
        tables = {}
        # The tables the search path does not show bare, findable only by schema-qualified name.
        qualified_tables = {}
        dialect = detect_sql_dialect(content) unless RailsAiContext::DatabaseFamily.of(dialect).known?
        enums = enum_types(content, dialect)
        domains = domain_types(content, dialect)
        created = postgres_rules?(dialect) ? content.scan(CREATE_SCHEMA).map { |name| SqlScan.unquote_name(*name) } : []
        path = PgNaming.existing_path(search_path, created)
        creates = []
        scan = SqlScan.new(content, family: dialect)
        each_create_table(content, scan, dialect) { |*create| creates << create }
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

          table, raw_types = parse_sql_table_body(body, shown, dialect: dialect, enums: enums, domains: domains, local: local, rails_version: rails_version)
          comment = string_after(trailer, /\bCOMMENT\s*=/i, dialect)
          table[:comment] = comment if comment
          all[name] = { table: table, raw_types: raw_types, parents: inherits && SqlScan.new(inherits, family: dialect).split(",").map { |parent| qualified_name(parent) } }
          table[:foreign_keys].each { |fk| fk[:from_table] = table_key(shown) }
          (SqlScan.qualified_parts(shown).size > 1 ? qualified_tables : tables)[table_key(shown)] = table
        end

        found_views = views(view_matches, local)
        scan.split(";").each { |statement| statement.scan(CREATE_INDEX) { |index| create_index(index, all, found_views, local, dialect, rails_version) } }

        content.scan(/ALTER TABLE\s+(?:ONLY\s+)?#{QUALIFIED_NAME}\s+ADD CONSTRAINT\s+#{CONSTRAINT_NAME}\s+UNIQUE\s*(NULLS\s+(?:NOT\s+)?DISTINCT\s*)?\(([^)]*)\)([^;]*)/m) do |table, *name, nulls, cols, tail|
          table = all.dig(qualified_name(table), :table) or next
          add_unique_key(table, unique_constraint(SqlScan.unquote_name(*name), cols.scan(/\w+/), "#{nulls}#{tail}"), rails_version)
        end

        content.scan(/ALTER TABLE\s+(?:ONLY\s+)?#{QUALIFIED_NAME}\s+ADD CONSTRAINT\s+#{CONSTRAINT_NAME}\s+EXCLUDE\b([^;]*)/m) do |table, *name, rest|
          table = all.dig(qualified_name(table), :table) or next
          entry = exclusion_constraint(SqlScan.unquote_name(*name), rest, dialect)
          (table[:exclusion_constraints] ||= []) << entry if entry
        end

        # pg_dump writes a NOT VALID check apart from its table.
        content.scan(/ALTER TABLE\s+(?:ONLY\s+)?#{QUALIFIED_NAME}\s+ADD CONSTRAINT\s+#{CONSTRAINT_NAME}\s+CHECK\s*(\([^;]*)/m) do |table, *name, rest|
          table = all.dig(qualified_name(table), :table) or next
          expression = SqlScan.first_group(rest, family: dialect)&.strip or next
          expression = SqlScan.unwrap(expression, family: dialect) if dialect == :mysql
          (table[:check_constraints] ||= []) << { name: SqlScan.unquote_name(*name), expression: expression, validate: (false if rest.match?(/\bNOT\s+VALID\s*\z/i)) }.compact
        end

        content.scan(/ALTER TABLE\s+(?:ONLY\s+)?#{QUALIFIED_NAME}\s+ADD CONSTRAINT[^;]*?PRIMARY KEY\s*\(([^)]*)\)/m) do |table, cols|
          table = all.dig(qualified_name(table), :table)
          table[:primary_key] = SchemaConventions.primary_key_value(cols.scan(/\w+/)) if table
        end

        content.scan(/ALTER TABLE\s+(?:ONLY\s+)?#{QUALIFIED_NAME}\s+ADD CONSTRAINT\s+#{CONSTRAINT_NAME}\s+FOREIGN KEY\s*\(([^)]*)\)\s*REFERENCES\s+#{QUALIFIED_NAME}\s*\(([^)]*)\)([^;]*)/m) do |from, *name, cols, to, pks, tail|
          from = qualified_name(from)
          all.dig(from, :table, :foreign_keys)&.push(SchemaConventions.foreign_key_entry(table_key(local.(from)), table_key(local.(qualified_name(to))), cols.scan(/\w+/), pks.scan(/\w+/),
                                                                                         name: SqlScan.unquote_name(*name), **foreign_key_actions(tail)))
        end

        alters = Hash.new { |h, k| h[k] = [] }
        content.scan(/^ALTER TABLE (?:ONLY )?#{QUALIFIED_NAME} ALTER COLUMN (?:#{SqlScan::NAME}) SET (NOT NULL|DEFAULT .+);$/) do |table, *name, change|
          alters[qualified_name(table)] << [ SqlScan.unquote_name(*name), change ]
        end
        resolved = {}
        all.each_key { |name| resolve_columns(name, all, alters, resolved, local, dialect: dialect, rails_version: rails_version) }
        all.each_value do |entry|
          entry[:table][:columns].each { |column| column[:enum_type] = names.type(column[:enum_type]) if column[:enum_type] }
        end
        all.each_value { |entry| entry[:table][:columns].each { |column| column.except!(:own_sequence, :auto_increment) } } unless own_sequences

        content.scan(/^COMMENT ON TABLE #{QUALIFIED_NAME} IS '((?:[^']|'')*)';/) do |table, text|
          table = all.dig(qualified_name(table), :table)
          table[:comment] = text.gsub("''", "'") if table
        end
        content.scan(/^COMMENT ON COLUMN ((?:(?:#{SqlScan::NAME_TEXT})\.)+)(?:#{SqlScan::NAME}) IS '((?:[^']|'')*)';/) do |table, *column, text|
          column = SqlScan.unquote_name(*column)
          found = all.dig(qualified_name(table.chomp(".")), :table, :columns)&.find { |c| c[:name] == column }
          found[:comment] = text.gsub("''", "'") if found
        end

        # pg_dump writes each partition as a table, then attaches it in exactly this form.
        content.scan(/^ALTER TABLE ONLY .+? ATTACH PARTITION #{QUALIFIED_NAME} /) do |(partition)|
          shown = local.(qualified_name(partition))
          (SqlScan.qualified_parts(shown).size > 1 ? qualified_tables : tables).delete(table_key(shown))
        end

        { dialect: dialect, tables: tables, qualified_tables: qualified_tables, names: names, enums: PgNaming.enum_list(enums, path, rails_version),
          views: found_views, virtual_tables: virtual_tables(virtual_matches, local, dialect), extensions: extensions(content, path, dialect, rails_version) }
      end

      def create_index((unique, double, back, plain, table, rest), all, found_views, local, dialect, rails_version)
        group = SqlScan.first_group(rest, family: dialect)
        keys = index_keys(group, dialect)
        return if keys.empty?

        # The method precedes the key list; INCLUDE, NULLS NOT DISTINCT and the condition follow it.
        open = rest.index("(")
        after = rest[(open + group.length + 2)..]
        where = after[/\bWHERE\s+(.+)\z/mi, 1]&.strip
        options = after.sub(/\bWHERE\b.*\z/mi, "")
        include = options[/\A\s*INCLUDE\s*\(([^)]*)\)/i, 1]
        detail = SchemaConventions.index_detail(keys, using: rest[0, open][/\bUSING\s+(\w+)/i, 1]&.downcase, include: include && index_keys(include, dialect),
                                                      nulls_not_distinct: RailsVersion.at_least?(rails_version, "7.1") && options.match?(/\bNULLS\s+NOT\s+DISTINCT\b/i),
                                                      **key_options(group, dialect))
        target = all.dig(qualified_name(table), :table) || found_views[local.(qualified_name(table))]
        (target[:indexes] ||= []) << { name: SqlScan.unquote_name(double, back, plain), columns: keys, unique: !!unique, where: where }.compact.merge(detail) if target
      end

      # pg_get_constraintdef's EXCLUDE USING method (elements) WHERE (predicate), as the connection reads it (exclusion_constraints, 7.1 to 8.1).
      def exclusion_constraint(name, rest, dialect)
        elements = SqlScan.first_group(rest, family: dialect) or return
        after = rest[(rest.index("(") + elements.length + 2)..].to_s
        where = after[/\bWHERE\s*(\(.*\))/m, 1]
        where = SqlScan.unwrap(where, family: dialect) while where&.start_with?("(") && SqlScan.unwrap(where, family: dialect) != where
        SchemaConventions.exclusion_constraint_entry(name, elements.strip, using: rest[/\A\s*USING\s+(\w+)/i, 1], where: where&.strip,
                                                                         deferrable: deferrable_mode(after))
      end

      # As PostgreSQL's connection names them (PgNaming.extension_name).
      def extensions(content, path, dialect, rails_version)
        found = content.scan(/^CREATE EXTENSION (?:IF NOT EXISTS )?(#{SqlScan::NAME_TEXT})(?: WITH SCHEMA (#{SqlScan::NAME_TEXT}))?/).map do |name, schema|
          [ name, schema ].map { |part| part && SqlScan.unquote_name(*SqlScan::NAME.match(part).captures) }
        end
        # Every PostgreSQL database starts with plpgsql in pg_catalog, and pg_dump leaves it out.
        if dialect == :postgresql && found.none? { |name, _| name == "plpgsql" } && content.scan(/^DROP EXTENSION (?:IF EXISTS )?(#{SqlScan::NAME_TEXT})/).none? { |(name)| SqlScan.names(name) == %w[plpgsql] }
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

      def virtual_tables(virtual_matches, local, dialect)
        virtual_matches.to_h do |name, mod, arguments|
          [ local.(qualified_name(name)), { module: mod, arguments: SqlScan.new(arguments.to_s, family: dialect).split(",") } ]
        end
      end

      # PostgreSQL's enum types by schema-qualified name, with their labels.
      def enum_types(content, dialect)
        content.scan(/CREATE TYPE\s+#{QUALIFIED_NAME}\s+AS\s+ENUM\s*\(([^;]*)\)\s*;/i).to_h do |name, labels|
          [ qualified_name(name), SqlScan.new(labels, family: dialect).split(",").map { |label| label.delete_prefix("'").delete_suffix("'").gsub("''", "'") } ]
        end
      end

      # A domain's first clause after its type. The lookbehind starts a search at the head of a run of blanks, not inside it.
      DOMAIN_CLAUSE = /(?<=\s)(?:NOT\s+NULL|NULL|DEFAULT|CONSTRAINT|CHECK|COLLATE)\b/i

      # PostgreSQL's domains by schema-qualified name, each with the type it is over.
      def domain_types(content, dialect)
        return {} unless postgres_rules?(dialect)

        content.scan(/CREATE DOMAIN\s+#{QUALIFIED_NAME}\s+AS\s+([^;]*);/im).to_h do |name, definition|
          [ qualified_name(name), definition[0, definition.index(DOMAIN_CLAUSE) || definition.size].strip ]
        end
      end

      # A column of a domain is its base type without the domain's sizes. The adapter types a domain over an array as its
      # element, so only `domain[]` is an array.
      def domain_base(type, domains)
        name = qualified_name(type.delete_suffix("[]"))
        base = domains[name] or return type
        seen = [ name ]
        while (inner = domains[qualified_name(base)]) && !seen.include?(qualified_name(base))
          seen << qualified_name(base)
          base = inner
        end
        "#{SqlScan.strip_array_suffix(base).first.gsub(/\(\s*\d+(?:\s*,\s*\d+)?\s*\)/, "").strip}#{"[]" if type.end_with?("[]")}"
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
      NEXT_STATEMENT = /\n[^\S\n]*(?:CREATE|ALTER|COMMENT|INSERT|DROP|SET|SELECT)\b/i
      # A view's body runs on to a SELECT line, so only another statement's keyword ends it.
      NEXT_DDL = /\n[^\S\n]*(?:CREATE\s+(?:(?:OR\s+REPLACE|UNIQUE|TEMP(?:ORARY)?|MATERIALIZED|VIRTUAL)\s+)*(?:TABLE|VIEW|INDEX|TRIGGER|SEQUENCE|TYPE|FUNCTION|EXTENSION|SCHEMA)\b|ALTER\s+(?:TABLE|SEQUENCE|TYPE|VIEW|INDEX)\b|COMMENT\s+ON\b|INSERT\s+INTO\b|DROP\s+(?:TABLE|VIEW|INDEX|TRIGGER)\b|SET\s+[\w.]+\s*(?:=|TO\b))/i

      # Each CREATE TABLE's name, body and INHERITS list. The body ends at its closing
      # parenthesis, since SQLite, MySQL and a semicolon-less dump each end the line differently.
      # A span that never closes hides every later table from the one scan, so the dump is read again from that table on.
      def each_create_table(content, scan, dialect)
        scanner = StringScanner.new(content)
        base = 0
        while scanner.skip_until(CREATE_TABLE)
          qualified = scanner[1]
          close = scan.paren_group(scanner.pos - base)
          unless close
            scan = SqlScan.new(content.byteslice(scanner.pos..), family: dialect)
            base = scanner.pos
            close = scan.paren_group(0) or next
          end
          close += base
          body = content.byteslice(scanner.pos + 1, close - scanner.pos - 1)
          scanner.pos = close + 1
          inherits = scanner[1] if scanner.scan(INHERITS)
          yield qualified, body, inherits, trailer(scanner, scan, base)
        end
      end

      # The table options after a CREATE TABLE body, to the statement's end or the line's.
      def trailer(scanner, scan, base)
        line = scanner.check(/[^\n]*/).to_s
        ends = StringScanner.new(line)
        while ends.skip_until(/;/)
          return line.byteslice(0, ends.pos - 1) if scan.top_level?(scanner.pos + ends.pos - 1 - base)
        end
        line
      end

      # A definition line's leading column name, unquoted, and the text after it.
      def leading_name(line)
        match = line.match(/\A(?:#{SqlScan::NAME})(?:\s+(.+)|\z)/m) or return
        [ SqlScan.unquote_name(*match.captures.first(3)), match[4].to_s ]
      end

      CONSTRAINT_NAME = /(?:#{SqlScan::NAME})/
      # A table name, optionally schema-qualified, each part bare or quoted.
      QUALIFIED_NAME = /(#{SqlScan::QUALIFIED_NAME_TEXT})/
      INHERITS_KEYWORD = /(?<!\s)\s*INHERITS\b/i
      # The optional INHERITS list after a CREATE TABLE body.
      INHERITS = /(?:#{INHERITS_KEYWORD}\s*\(([^)]*)\))?/
      CREATE_SCHEMA = /^CREATE SCHEMA (?:IF NOT EXISTS )?(?:#{SqlScan::NAME})/
      CREATE_TABLE = /CREATE\s+(?:UNLOGGED\s+)?TABLE\s+(?:IF NOT EXISTS\s+)?#{QUALIFIED_NAME}\s*(?=\()/i
      # One statement's CREATE INDEX: its name bare or quoted, its table, and the rest of the statement.
      CREATE_INDEX = /CREATE (UNIQUE )?INDEX\s+(?:CONCURRENTLY\s+)?(?:IF NOT EXISTS\s+)?(?:#{SqlScan::NAME})\s+ON\s+(?:ONLY\s+)?#{QUALIFIED_NAME}((?:(?!#{NEXT_STATEMENT}).)*)/m
      # mysqldump wraps the statement in version comments and names an algorithm, definer and security first;
      # sqlite3 closes it with a /* name(columns) */ comment.
      VIEW = /\bCREATE\s+(?:OR\s+REPLACE\s+)?(?:(?:ALGORITHM|DEFINER|SQL\s+SECURITY)\b[^;]*?\s)?(?:TEMP(?:ORARY)?\s+)?(MATERIALIZED\s+)?VIEW\s+(?:IF\s+NOT\s+EXISTS\s+)?#{QUALIFIED_NAME}(?:\s*\([^)]*\))?\s+AS\s+(.*?)(?<!\s)(?:\s+WITH\s+(?:NO\s+)?DATA)?(?:\s*\/\*\s*[\w"`]+\([^)]*\)\s*\*\/)?\s*(?:\*\/\s*)?(?:;|(?=#{NEXT_DDL})|\z)/im
      VIRTUAL_TABLE = /CREATE\s+VIRTUAL\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?#{QUALIFIED_NAME}\s+USING\s+(\w+)\s*(?:\(([^)]*)\))?/i

      # The key a table is listed under: its name as the database holds it, a schema in front (schema.name) where the search path
      # does not show it bare. Never SQL-quoted; `shown` is the quoted form the reader keeps its own maps in.
      def table_key(shown)
        SqlScan.qualified_parts(shown).join(".")
      end

      # "schema.name" with a quote only around a part that holds a dot; an unqualified name is in public.
      def qualified_name(text)
        parts = SqlScan.names(text.strip)
        parts.unshift("public") if parts.size == 1
        SqlScan.join_qualified(*parts)
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
            declared = { sql_type: entry[:raw_types].fetch(column_name), stored_default: default_clause(change, dialect) }
            default = DumpedColumn.call(declared, family: dialect, rails_version: rails_version)[:default]
            default.nil? ? column.delete(:default) : column[:default] = default
            column.replace(DumpedColumn.without_sequence(column))
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

        column.except(:primary_key).merge(own_sequence: PgNaming.owned_sequence(column, parent))
      end

      # A serial whose sequence does not follow its name (a copy, a renamed column or table) reads as the integer it
      # was made from with that sequence as its default (new_column_from_field).
      def detached_serial(column, table)
        return column unless column[:own_sequence]

        DumpedColumn.without_sequence(column).merge(default: DumpedColumn.nextval_default(PgNaming.owned_sequence(column, table)))
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
      def parse_sql_table_body(body, table_name, dialect:, enums:, domains:, local:, rails_version:)
        # One definition per line whatever the dump's layout: SQLite writes a
        # table on one line and its foreign key clause across three.
        body = SqlScan.new(body, family: dialect).split(",").map { |definition| definition.gsub(/(?<!\s)\s*\n\s*/, " ") }.join("\n")

        key = body[/^[^\S\n]*PRIMARY KEY\s*\(([^)]*)\)/i, 1]&.scan(/\w+/)
        columns, raw_types = parse_sql_columns(body, dialect: dialect, enums: enums, domains: domains, key: Array(key), table_name: table_name, local: local, rails_version: rails_version)
        table = { columns: columns, indexes: [], foreign_keys: [] }
        table[:primary_key] = SchemaConventions.primary_key_value(key) if key
        uniques = inline_uniques(body, columns, dialect)
        columns.each do |column|
          next unless SchemaConventions.serial_index?(dialect, raw_types[column[:name]], column, key) || (dialect == :mysql && uniques.key?(column[:name]))

          table[:indexes] << SchemaConventions.serial_index(table[:indexes], column[:name])
        end
        constraints = uniques.map { |column, (name, tail)| [ name, [ column ], tail ] }

        body.each_line do |line|
          line = line.strip.chomp(",")
          case line
          when FOREIGN_KEY_LINE
            match = $~
            # The SQLite adapter reads no key's name.
            name = SqlScan.names(match[:name]).first unless dialect == :sqlite
            table[:foreign_keys] << SchemaConventions.foreign_key_entry(table_name, SqlScan.names(match[:to]).last, SqlScan.names(match[:columns]),
                                                                        SqlScan.names(match[:keys]), name: name, **foreign_key_actions(match[:tail]))
          when CHECK_LINE
            name = SqlScan.names($~[:name]).first
            expression = SqlScan.first_group($~[:rest], family: dialect)&.strip
            # The MySQL adapter drops the parentheses MySQL wraps a check clause in.
            expression = SqlScan.unwrap(expression, family: dialect) if dialect == :mysql && expression
            (table[:check_constraints] ||= []) << { name: name, expression: expression }.compact if expression
          when INDEX_LINE
            match = $~
            next unless match[:quoted] || dialect == :mysql

            kind = (match[:unique] || match[:typed]).to_s.downcase
            rest = match[:rest]
            group = SqlScan.first_group(rest, family: dialect)
            keys = index_keys(group, dialect)
            keys = keys.map { |k| k.start_with?("(") ? mysql_expression_key(k) : k } if dialect == :mysql
            # Rails names a MySQL fulltext or spatial index by type:, any other by its method.
            typed = %w[fulltext spatial].include?(kind)
            using = (match[:using] || rest[(group.to_s.length + 2)..].to_s[/\bUSING\s+(\w+)/i, 1])&.downcase unless typed
            name = match[:quoted] ? SqlScan.unquote_name(*SqlScan::NAME.match(match[:quoted]).captures) : match[:bare]
            index = name ? { name: name, columns: keys } : SchemaConventions.serial_index(table[:indexes], keys).slice(:name, :columns)
            index[:unique] = kind == "unique"
            index.merge!(SchemaConventions.index_detail(keys, type: (kind if typed), using: using, **key_options(group, dialect)))
            table[:indexes] << index if keys.any?
          when UNIQUE_LINE
            match = $~
            name = SqlScan.names(match[:index] || match[:constraint]).first
            nulls = match[:nulls]
            rest = match[:rest]
            group = SqlScan.first_group(rest, family: dialect)
            keys = index_keys(group, dialect)
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
        (?:\s+(?:(?<quoted>#{SqlScan::QUOTED_NAME_TEXT})|(?!USING\b)(?<bare>\w+)))?(?:\s+USING\s+(?<using>\w+))?\s*(?<rest>\(.*)/ix

      # A MySQL functional key part as the connection reads it: MySQL's expression, in parentheses (indexes).
      # shortcut: a replayed expression keeps its written spelling, where MySQL stores `a` + 1 for a+1; normalize it if a tool compares them.
      def mysql_expression_key(key)
        inner = SqlScan.unwrap(key, family: :mysql)
        inner.start_with?("(") ? inner : "(#{inner})"
      end

      # A table body's foreign key and check lines, each with its constraint name bare or quoted.
      FOREIGN_KEY_LINE = /\A(?:CONSTRAINT\s+(?<name>#{SqlScan::NAME_TEXT})\s+)?FOREIGN\s+KEY\s*\((?<columns>[^)]*)\)\s*
        REFERENCES\s+(?<to>#{SqlScan::NAME_TEXT})\s*\((?<keys>[^)]*)\)(?<tail>.*)/ix
      CHECK_LINE = /\A(?:CONSTRAINT\s+(?<name>#{SqlScan::NAME_TEXT})\s+)?CHECK\s*(?<rest>\(.*)/i

      # A table-level UNIQUE the KEY line above leaves: unnamed, or named without quotes.
      UNIQUE_LINE = /\A(?:CONSTRAINT\s+(?<constraint>#{SqlScan::NAME_TEXT})\s+)?UNIQUE(?:\s+(?:KEY|INDEX))?(?<nulls>\s+NULLS\s+(?:NOT\s+)?DISTINCT)?
        (?:\s+(?<index>#{SqlScan::NAME_TEXT}))?\s*(?<rest>\(.*)/ix
      INLINE_UNIQUE = /(?:\bCONSTRAINT\s+(#{SqlScan::NAME_TEXT})\s+)?(?<![`"])\bUNIQUE\b(?![`"])/i

      # Each column that declares itself UNIQUE: the constraint name it gives, and the clause after it.
      def inline_uniques(body, columns, dialect)
        names = columns.map { |column| column[:name] }
        body.each_line.each_with_object({}) do |line, found|
          name, rest = leading_name(line.strip)
          next unless names.include?(name) && !line.strip.match?(/\A(?:PRIMARY|CONSTRAINT|CHECK|UNIQUE|EXCLUDE|FOREIGN)\b/i)

          rest = SqlScan.new(rest, family: dialect).masked
          match = INLINE_UNIQUE.match(rest) or next
          found[name] = [ SqlScan.names(match[1]).first, match.post_match ]
        end
      end

      # MySQL's unique index: the name given, else its first column's (serial_index).
      def unique_index(indexes, name, columns)
        name ? SchemaConventions.index_entry(name, columns, unique: true) : SchemaConventions.serial_index(indexes, columns)
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
          name ||= (0..).lazy.map { |n| PgNaming.serial_sequence_name(SqlScan.split_qualified(table_name).last, keys.join("_"), "key#{n unless n.zero?}") }.find { |c| !taken.include?(c) }
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
      COLUMN_KEY = /\A(?<column>#{SqlScan::NAME_TEXT})(?:\s*\((?<length>\d+)\))?(?<words>(?:\s+(?:[\w.]+|#{SqlScan::QUOTED_NAME_TEXT}))*)\z/

      # Each column key's prefix length, sort order and operator class, as the connection reads them.
      def key_options(list, dialect)
        options = { length: {}, order: {}, opclass: {} }
        SqlScan.new(list.to_s, family: dialect).split(",").each do |key|
          match = COLUMN_KEY.match(key.strip) or next
          column, length, words = SqlScan.names(match[:column]).first, match[:length], match[:words].split
          options[:length][column] = length.to_i if length
          opclass = words.map { |word| word.split(".").last }.find { |word| word.match?(/\A\w+_ops(?:_\w+)?\z/) }
          options[:opclass][column] = opclass if opclass
          desc = "DESC" if words.any? { |word| word.casecmp?("DESC") }
          nulls = match[:words][/\bNULLS\s+(?:FIRST|LAST)\b/i]&.upcase&.squeeze(" ")
          order = nulls ? [ desc, nulls ].compact.join(" ") : desc&.downcase
          options[:order][column] = order if order
        end
        options
      end

      # An index's keys, split on top-level commas: a column name, or an
      # expression as the dump spells it (COALESCE(a, '-1'::integer) is one key).
      def index_keys(list, dialect)
        return [] if list.nil?

        SqlScan.new(list, family: dialect).split(",").filter_map do |key|
          key = key.strip
          next if key.empty?

          (match = COLUMN_KEY.match(key)) ? SqlScan.names(match[:column]).first : key
        end
      end

      # The first clause after a column's type; (?<!\s) starts a search at the head of a run of blanks, not inside it.
      COLUMN_CLAUSE = /(?:\A|(?<!\s)\s+)(?:NOT\s+NULL|NULL|DEFAULT|PRIMARY|UNIQUE|CONSTRAINT|CHECK|AUTO_INCREMENT|AUTOINCREMENT|CHARACTER\s+SET|COLLATE|COMMENT|GENERATED|REFERENCES)\b/i

      # Column definitions from a CREATE TABLE body, and each column's type as the dump spells it.
      def parse_sql_columns(body, dialect:, enums:, domains:, key:, table_name:, local:, rails_version:)
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
            declared = rest.split(COLUMN_CLAUSE).first.to_s.strip
            col_type = declared.downcase
            domain = domain_base(declared, domains) if declared.match?(/\A#{QUALIFIED_NAME}(?:\[\])?\z/o) && domains.any?
            col_type = domain.downcase if domain && domain != declared
            # Only SQLite lets a column declare no type.
            next if col_type.empty? && dialect != :sqlite
            # NOT NULL, and primary keys (implicitly NOT NULL outside SQLite), are the only
            # dump-visible nullability signals.
            nullable = !rest.match?(dialect == :sqlite ? /\bNOT\s+NULL\b/i : /\bNOT\s+NULL\b|\bPRIMARY\s+KEY\b/i)
            primary_key = key == [ col_name ] || rest.match?(/\bPRIMARY\s+KEY\b/i)
            enum_type = qualified_name(col_type.delete_suffix("[]")) if col_type.match?(/\A#{QUALIFIED_NAME}(?:\[\])?\z/o)
            raw_types[col_name] = col_type
            stored_default = default_clause(rest, dialect)
            # An explicit cast to the domain is a default the adapter cannot read, so the column has none.
            stored_default = nil if domain && domains.key?(qualified_name(stored_default.to_s[/::(#{SqlScan::QUALIFIED_NAME_TEXT})\z/o, 1].to_s))
            source = { name: col_name, sql_type: dialect == :sqlite ? declared : col_type, primary_key: primary_key, null: nullable,
                       enum_type: (enum_type if enum_type && enums.key?(enum_type)), stored_default: stored_default,
                       comment: string_after(rest, /\bCOMMENT\b/i, dialect), collation: SqlScan.names(rest[COLLATION, 1]).last }
            source.merge!(auto_increment: true, null: false) if dialect == :mysql && rest.match?(/\bAUTO_INCREMENT\b/i)
            if (at = rest =~ /\bGENERATED\s+ALWAYS\s+AS\s*\(/i) && (expression = SqlScan.first_group(rest[at..], family: dialect))
              source.merge!(generated: expression.strip, stored: rest.match?(/\)\s*(?:STORED|PERSISTENT)\b/i))
            end
            column = DumpedColumn.call(source.compact, family: dialect, rails_version: rails_version)
            column[:primary_key] = true if rest.match?(/\bPRIMARY\s+KEY\b/i)
            sequence_default(column, rest, table: table_name, primary_key: primary_key, local: local) if postgres_rules?(dialect)
            columns << column
          end
        end
        [ columns, raw_types ]
      end

      # Where a DEFAULT clause ends: the next constraint keyword at the top level.
      DEFAULT_END = /\s+(?:NOT\s+NULL|NULL|CONSTRAINT|CHECK|REFERENCES|GENERATED|COLLATE|ON\s+UPDATE|COMMENT|AUTO_INCREMENT|PRIMARY|UNIQUE)\b/i

      # The DEFAULT clause's text, as the dump keeps it; nil when the column has none.
      def default_clause(rest, dialect)
        start = rest =~ /\bDEFAULT\s+/i or return nil
        default_text(rest[(start + Regexp.last_match(0).length)..], dialect)
      end

      # The DEFAULT value's text, up to the next constraint at the top level.
      def default_text(text, dialect)
        scan = SqlScan.new(text, family: dialect)
        scanner = StringScanner.new(text, fixed_anchor: true)
        # The head of each run of blanks, matched in place: a copy of the rest, or a try at every blank, costs a pass per blank.
        while scanner.skip_until(/(?<!\s)\s/)
          at = scanner.pos - 1
          scanner.pos = at
          return text.byteslice(0, at).strip if scan.top_level?(at) && scanner.match?(DEFAULT_END)

          scanner.pos = at + 1
        end
        text.strip
      end

      # The value of the string literal that follows keyword at the top level of text, as the family reads it.
      def string_after(text, keyword, dialect)
        scan = SqlScan.new(text, family: dialect)
        match = keyword.match(scan.masked) or return
        after = match.pre_match.bytesize + match[0].bytesize
        _, from, to = scan.quoted_spans.find { |_, at, _| at >= after }
        return unless from && text.byteslice(after, from - after).strip.empty?

        SqlScan.unquote(text.byteslice(from, to - from), family: dialect)
      end

      def postgres_rules?(dialect)
        RailsAiContext::DatabaseFamily.of(dialect).postgres_rules?
      end

      # A column's collation: the last part of its name, as pg_collation's collname, MySQL's and SQLite's own.
      COLLATION = /\bCOLLATE\s+((?:#{SqlScan::NAME_TEXT}\.)?#{SqlScan::NAME_TEXT})/i
      # The regclass a nextval default names, inside its string literal.
      NEXTVAL = /\bDEFAULT\s+nextval\('((?:[^']|'')+)'(?:::regclass)?\)/i

      # A nextval default the way PostgreSQL's columns read it (new_column_from_field): a serial when the
      # sequence is the one the column's own name makes, whoever owns it, else the function as its default.
      def sequence_default(column, rest, table:, primary_key:, local:)
        sequence = rest[NEXTVAL, 1] or return
        sequence = local.(qualified_name(sequence.gsub("''", "'")))
        if PgNaming.serial_sequence?(sequence, SqlScan.split_qualified(table).last, column[:name])
          column[:type] = DumpedColumn.serial_name(column[:type], primary_key)
          column[:own_sequence] = sequence
          column.delete(:default)
        else
          column[:default] = DumpedColumn.nextval_default(sequence)
        end
      end
    end
  end
end
