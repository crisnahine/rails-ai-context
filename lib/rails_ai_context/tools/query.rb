# frozen_string_literal: true

module RailsAiContext
  module Tools
    class Query < BaseTool
      tool_name "rails_query"
      description "Execute read-only SQL queries against the database. " \
        "Use when: checking data patterns, verifying migrations, debugging data issues. " \
        "Safety: SQL validation + database-level READ ONLY + statement timeout + row limit. " \
        "Development/test only by default. " \
        "Key params: sql (SELECT only), limit (default 100), format (table/csv)."

      input_schema(
        properties: {
          sql: {
            type: "string",
            description: "SQL query to execute. Only SELECT, WITH, SHOW, EXPLAIN, DESCRIBE allowed, and no UNION."
          },
          limit: {
            type: "integer",
            description: "Max rows to return. Default: 100, hard cap: 1000."
          },
          format: {
            type: "string",
            enum: %w[table csv],
            description: "Output format. table: markdown table (default). csv: comma-separated values."
          },
          explain: {
            type: "boolean",
            description: "Run EXPLAIN on the query. Returns execution plan analysis instead of data. SELECT only."
          },
          database: {
            type: "string",
            description: "The app database to query, by its config/database.yml name (for example queue). Default: the primary."
          }
        },
        required: [ "sql" ]
      )

      guide_row(
        order: 27,
        mcp: "rails_query(sql:\"X\")",
        cli_args: "sql=X",
        summary: "Safe read-only SQL queries with timeout, row limit, column redaction"
      )

      annotations(
        read_only_hint: true,
        destructive_hint: false,
        idempotent_hint: false,
        open_world_hint: false
      )

      HARD_ROW_CAP = 1000

      # SHOW/DESCRIBE/EXPLAIN return schema metadata, never application rows:
      # a LIMIT appended to them is a syntax error, and MySQL's DESCRIBE has a
      # column named "Key" that name redaction would filter into uselessness.
      SCHEMA_METADATA_PREFIX = /\A\s*(SHOW|DESCRIBE|DESC|EXPLAIN)\b/i

      # The session record is echoed back to the model; a full query body can
      # carry literals from the app's own data, so keep only enough to
      # recognise the call.
      def self.session_params(kwargs)
        params = super
        params.key?(:sql) ? params.merge(sql: params[:sql].to_s.truncate(60)) : params
      end

      def self.call(sql: nil, limit: nil, format: "table", explain: false, database: nil, server_context: nil, **_extra)
        if (refusal = static_tier_refusal("Running SQL queries"))
          return refusal
        end

        unless config.allow_query_in_production || rails_env_name != "production"
          return text_response(
            "rails_query is disabled in production for data privacy. " \
            "Set config.allow_query_in_production = true to override."
          )
        end

        # Before anything that rescues ActiveRecord::*: a rescue clause names
        # its class at raise time, a NameError on an app without ActiveRecord.
        unless defined?(ActiveRecord::Base)
          return text_response(
            "Database queries are unavailable: ActiveRecord is not loaded in this app. " \
            "This happens on API-only apps created with `rails new --api --skip-active-record`. " \
            "rails_query requires a database connection to function."
          )
        end

        AppDatabases.lease(rails_app.root, database) { |connection| answer(connection, sql, limit, format, explain) }
      rescue AppDatabases::Error => e
        error_response(e.message)
      rescue ActiveRecord::ConnectionNotEstablished, ActiveRecord::NoDatabaseError => e
        text_response("Database unavailable: #{clean_error_message(e.message)}\n\n**Troubleshooting:**\n- Check `config/database.yml` for correct host/port/credentials\n- Try `RAILS_ENV=test` if the development DB is remote\n- Run `bin/rails db:create` if the database doesn't exist yet")
      rescue DatabaseFamily::TimedOut
        text_response("Query exceeded #{config.query_timeout} second timeout. Simplify the query or add indexes.")
      rescue ActiveRecord::StatementInvalid => e
        # Only a missing DATABASE: PostgreSQL words a missing column and table the same way, and those are SQL errors.
        if e.message.match?(/database "[^"]*" does not exist|could not find (?:your )?database|Unknown database/i)
          text_response("Database not found: #{clean_error_message(e.message)}\n\n**Troubleshooting:**\n- Run `bin/rails db:create` to create the database\n- Check `config/database.yml` for the correct database name\n- Try `RAILS_ENV=test` if the development DB is remote")
        else
          error_response("SQL error: #{clean_error_message(e.message)}#{held_elsewhere(e.message, database)}")
        end
      rescue => e
        error_response("Query failed: #{clean_error_message(e.message)}")
      end

      private_class_method def self.answer(connection, sql, limit, format, explain)
        family = DatabaseFamily.of(connection)
        unless family.known?
          return error_response(
            "rails_query refuses the #{family.name} adapter: it runs SQL only on a database whose read-only " \
            "transaction and statement timeout it knows (PostgreSQL, MySQL with MariaDB, SQLite). No statement was sent."
          )
        end

        secrets = SecretColumns.for(connection, context: cached_context)
        timeout = config.query_timeout
        verdict = SqlGate.new(family: family, secrets: secrets, connection: connection, timeout: timeout).check(sql)
        return error_response(verdict.refusal) if verdict.refused?

        sql = verdict.sql
        return explain_response(family, connection, sql, timeout) if explain

        row_limit = limit ? [ limit.to_i, HARD_ROW_CAP ].min : config.query_row_limit
        row_limit = [ row_limit, 1 ].max
        result = cap_rows(family.read_only(connection, apply_row_limit(sql, row_limit), timeout: timeout), sql, row_limit)

        schema_metadata = sql.match?(SCHEMA_METADATA_PREFIX)
        definition = sql.match?(SqlGate::SHOW_CREATE_DEFINITION)
        redacted = if definition
          redact_definition(result)
        elsif schema_metadata
          result
        else
          redact_results(result, secrets, family.column_sources(connection, sql, plan: verdict.plan))
        end

        # The truncation note rides every format (for CSV after a blank line, so
        # a parser still reads the block); the unbounded note stays off CSV.
        cut = !schema_metadata && result.respond_to?(:truncated) && result.truncated
        truncation = cut ? truncation_note([ row_limit, HARD_ROW_CAP ].min, format) : ""
        output = if format == "csv"
          format_csv(redacted) + truncation
        else
          (definition ? format_definition(redacted) : format_table(redacted)) + truncation + unbounded_note(result)
        end

        text_response(output)
      end

      MISSING_TABLE = /no such table: (?:\w+\.)?(\w+)|relation "(?:\w+\.)?(\w+)" does not exist|Table '(?:[^'.]+\.)?(\w+)' doesn't exist/i

      # Where a table the statement did not find lives, read from the schema
      # section's tables for the primary and each other database's dump.
      private_class_method def self.held_elsewhere(message, database)
        table = message.match(MISSING_TABLE)&.captures&.compact&.first or return ""
        databases = AppDatabases.for(rails_app.root)
        asked = database.to_s.empty? ? databases.primary&.name : database.to_s
        schema = cached_context[:schema]
        return "" unless schema.is_a?(Hash)

        held = { (databases.primary&.name || "primary") => schema[:tables] }
        (schema[:secondary_databases] || {}).each { |name, dump| held[name.to_s] ||= dump[:tables] if dump.is_a?(Hash) }
        holder = held.find { |name, tables| name != asked && tables.is_a?(Hash) && tables.key?(table) }&.first or return ""

        found = databases[holder]
        return " The #{table} table is on the #{holder} database: run the query again with database: \"#{holder}\"." if found.nil? || found.here

        " The #{table} table is on the #{holder} database, which #{RailsAiContext.environment_name} does not configure."
      rescue StandardError => e
        RailsAiContext.debug_fail(e, "", label: "held_elsewhere")
      end

      private_class_method def self.unbounded_note(result)
        result.respond_to?(:unbounded) && result.unbounded ? UNBOUNDED_SQLITE_NOTE : ""
      end

      # Says, in every format, that the row cap held rows back, so a reader (or a
      # parser) is not told a partial answer is the whole one.
      private_class_method def self.truncation_note(cap, format)
        detail = if cap >= HARD_ROW_CAP
          "the 1000-row hard cap"
        else
          "the row limit of #{cap}; pass limit: up to 1000 to see more"
        end
        note = "#{cap} rows shown; the query returned more (#{detail})."
        format == "csv" ? "\n\n#{note}" : "\n\n_#{note}_"
      end

      private_class_method def self.explain_response(family, connection, sql, timeout)
        return error_response("EXPLAIN only supports SELECT queries.") unless sql.match?(/\A\s*(SELECT|WITH)\b/i)

        parsed = family.explain(connection, sql, timeout: timeout)

        lines = [ "# EXPLAIN Analysis", "" ]
        lines << "**Query:** `#{sql.truncate(120)}`"
        lines << ""

        if parsed[:scan_types]&.any?
          lines << "## Scan Summary"
          parsed[:scan_types].each do |scan|
            lines << "- **#{scan[:table] || "?"}**: #{scan[:type]}#{scan[:index] ? " using #{scan[:index]}" : ""}"
          end
          lines << ""
        end

        if parsed[:warnings]&.any?
          lines << "## Warnings"
          parsed[:warnings].each { |w| lines << "- #{w}" }
          lines << ""
        end

        lines << "## Raw Plan"
        lines << "```"
        lines << parsed[:raw]
        lines << "```"

        text_response(lines.join("\n") + (parsed[:unbounded] ? UNBOUNDED_SQLITE_NOTE : ""))
      rescue ActiveRecord::StatementInvalid => e
        error_response("EXPLAIN failed: #{clean_error_message(e.message)}")
      end

      # ── Row limit enforcement (Layer 3) ─────────────────────────────
      # The query's own limit ends the statement. A LIMIT anywhere else belongs
      # to a subquery or a string literal and is left as written. LIMIT ALL,
      # LIMIT NULL (PostgreSQL) and a negative limit (SQLite) are no limit at all.
      TRAILING_LIMIT = /\bLIMIT\s+(?:(\d+)\s*,\s*)?(\d+|ALL|NULL|-\s*\d+)(\s+OFFSET\s+\d+)?\s*;?\s*\z/i
      TRAILING_FETCH = /\bFETCH\s+(FIRST|NEXT)\s+(\d+)(\s+ROWS?\s+ONLY)\s*;?\s*\z/i

      # The text asks for one row past the cap, so the answer can tell a result
      # that fit from one the cap cut (cap_rows drops the extra row). A query's
      # own smaller LIMIT is left as written: then nothing was held back.
      private_class_method def self.apply_row_limit(sql, limit)
        return sql if sql.match?(SCHEMA_METADATA_PREFIX)

        fetch = [ limit, HARD_ROW_CAP ].min + 1

        if sql.match?(TRAILING_LIMIT)
          sql.sub(TRAILING_LIMIT) { "LIMIT #{"#{$1}, " if $1}#{$2.match?(/\A\d+\z/) ? [ $2.to_i, fetch ].min : fetch}#{$3}" }
        elsif sql.match?(TRAILING_FETCH)
          sql.sub(TRAILING_FETCH) { "FETCH #{$1} #{[ $2.to_i, fetch ].min}#{$3}" }
        elsif own_limit?(sql)
          # A limit in a spelling this does not rewrite (`LIMIT 1+1`, `WITH TIES`).
          # A second one would be a syntax error, so it runs as written and cap_rows holds the cap.
          sql
        else
          # On its own line, so nothing the database reads as a line comment takes it.
          "#{sql.sub(/;\s*\z/, "")}\nLIMIT #{fetch}"
        end
      end

      # Whether the last LIMIT or FETCH is the statement's own: nothing after
      # it closes a parenthesis or a quote that opened before it.
      private_class_method def self.own_limit?(sql)
        start = sql.rindex(/\b(?:LIMIT|FETCH\s+(?:FIRST|NEXT))\b/i) or return false
        tail = sql[start..]
        depth = 0
        tail.each_char do |char|
          depth += { "(" => 1, ")" => -1 }.fetch(char, 0)
          return false if depth.negative?
        end
        [ "'", '"', "`" ].all? { |quote| tail.count(quote).even? }
      end

      # The text carries the limit. This holds it whatever the database made of
      # that text, and marks the result truncated only when more than the cap
      # came back - the text fetched one row past it - so the answer says rows
      # were held back exactly when they were, and drops the extra row.
      private_class_method def self.cap_rows(result, sql, limit)
        cap = [ limit, HARD_ROW_CAP ].min
        return result if sql.match?(SCHEMA_METADATA_PREFIX) || result.rows.size <= cap

        unbounded = result.respond_to?(:unbounded) && result.unbounded
        ResultProxy.new(result.columns, result.rows.first(cap), unbounded, true)
      end

      # ── Column redaction (Layer 4) ──────────────────────────────────
      # A column is filtered when its output name or the table column it reads is secret. A source
      # whose column could not be read is filtered when its relation, or any relation, holds a secret.
      private_class_method def self.redact_results(result, secrets, sources)
        columns = result.columns
        rows = result.rows
        provenance = sources.filter_map do |i, column, relation|
          unread = column.nil? && (relation ? secrets.relation_secret?(relation) : secrets.in_schema.any?)
          i if unread || secrets.secret?(column)
        end

        redacted_indices = columns.each_index.select { |i| provenance.include?(i) || secrets.secret?(columns[i]) }

        return result if redacted_indices.empty?

        redacted_rows = rows.map { |row|
          row.each_with_index.map { |val, i|
            redacted_indices.include?(i) ? RailsAiContext::Redaction::FILTERED : val
          }
        }

        ResultProxy.new(columns, redacted_rows)
      end

      # A SHOW CREATE TABLE / VIEW definition is schema text, so it skips column
      # redaction, but a FEDERATED table's `CONNECTION='mysql://user:pass@...'`
      # carries a credential inside it: the text goes through the shared
      # redaction, which filters a URI's userinfo and secret-named settings.
      private_class_method def self.redact_definition(result)
        rows = result.rows.map do |row|
          row.map { |value| value.is_a?(String) ? RailsAiContext::Redaction.call(value) : value }
        end
        ResultProxy.new(result.columns, rows)
      end

      # ── Output formatting ───────────────────────────────────────────
      private_class_method def self.format_table(result)
        columns = result.columns
        rows = result.rows

        return "_Query returned 0 rows._" if rows.empty?

        # Format cell values
        formatted_rows = rows.map { |row|
          row.map { |val| format_cell(val) }
        }

        # Calculate column widths
        widths = columns.each_with_index.map { |col, i|
          [ col.length, *formatted_rows.map { |r| r[i].to_s.length } ].max
        }

        lines = []
        lines << "| #{columns.each_with_index.map { |c, i| c.ljust(widths[i]) }.join(" | ")} |"
        lines << "| #{widths.map { |w| "-" * w }.join(" | ")} |"
        formatted_rows.each do |row|
          lines << "| #{row.each_with_index.map { |v, i| v.to_s.ljust(widths[i]) }.join(" | ")} |"
        end
        lines << ""
        lines << "_#{count_phrase(rows.size, "row")} returned._"

        lines.join("\n")
      end

      # SHOW CREATE TABLE / VIEW in the default format. A definition is DDL to
      # read, so each one is shown whole, its line breaks kept, in a fenced code
      # block: as a table cell it would be cut at 100 characters and its lines
      # folded into `\n`. The text is already redacted (redact_definition), and
      # the response size cap in text_response still bounds the answer. Any
      # other column (a view's character set and collation) follows as a
      # `name: value` line.
      private_class_method def self.format_definition(result)
        columns = result.columns
        definition = columns.index { |col| col.to_s.match?(/\ACreate\b/i) }
        return format_table(result) if definition.nil? || result.rows.empty?

        result.rows.map { |row|
          text = csv_cell(row[definition])
          # Longer than any backtick run inside, so a backtick-quoted
          # identifier cannot close the fence.
          fence = "`" * [ 3, text.scan(/`+/).map(&:length).max.to_i + 1 ].max
          lines = [ "#{columns[0]}: #{csv_cell(row[0])}", "", "#{fence}sql", text, fence ]
          others = columns.each_index.reject { |i| i.zero? || i == definition }
          lines << "" if others.any?
          others.each { |i| lines << "#{columns[i]}: #{csv_cell(row[i])}" }
          lines.join("\n")
        }.join("\n\n")
      end

      private_class_method def self.format_csv(result)
        columns = result.columns
        rows = result.rows

        return "_Query returned 0 rows._" if rows.empty?

        lines = []
        lines << columns.map { |col| csv_field(col.to_s) }.join(",")
        rows.each do |row|
          lines << row.map { |val| csv_field(csv_cell(val)) }.join(",")
        end

        lines.join("\n")
      end

      # A CSV cell is the value itself: NULL is an empty field, and nothing is
      # escaped beyond CSV quoting or cut short - the markdown cell's `_NULL_`,
      # `\|` and 100-character cut are table rendering, not data. Binary data is
      # not text, so it stays the [BLOB] marker.
      private_class_method def self.csv_cell(val)
        return "" if val.nil?
        return "[BLOB]" if val.is_a?(String) && val.encoding == Encoding::ASCII_8BIT

        val.to_s
      end

      # RFC 4180: a field holding a comma, a quote or a line break is quoted, its
      # quotes doubled.
      private_class_method def self.csv_field(text)
        text.match?(/[",\r\n]/) ? "\"#{text.gsub('"', '""')}\"" : text
      end

      # A markdown table cell. A line break would end the table row, so it is
      # shown as the two characters `\n`; a pipe would end the cell, so it is
      # escaped, in a shortened value too.
      private_class_method def self.format_cell(val)
        return "_NULL_" if val.nil?

        if val.is_a?(String)
          # Detect binary/BLOB data
          return "[BLOB]" if val.encoding == Encoding::ASCII_8BIT

          text = val.gsub(/\r\n|\r|\n/, "\\n")
          text = "#{text[0...100]}..." if text.length > 100
          return text.gsub("|", "\\|")
        end

        val.to_s
      end

      private_class_method def self.clean_error_message(message)
        # Remove internal Ruby traces and framework noise
        message.lines.first&.strip || message.strip
      end

      # Quacks like ActiveRecord::Result for redacted output, for a SQLite query
      # that ran in-process with no time limit, or for a result the row cap cut.
      ResultProxy = Struct.new(:columns, :rows, :unbounded, :truncated)
      UNBOUNDED_SQLITE_NOTE = "\n\n_This SQLite query ran without a time limit: query_timeout needs a file-backed database, " \
        "a platform with fork, and nothing that only the app's own connection has._"
    end
  end
end
