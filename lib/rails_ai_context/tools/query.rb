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
            description: "SQL query to execute. Only SELECT, WITH, SHOW, EXPLAIN, DESCRIBE allowed."
          },
          limit: {
            type: "integer",
            description: "Max rows to return. Default: 100, hard cap: 1000."
          },
          format: {
            type: "string",
            enum: %w[table csv],
            description: "Output format. table: markdown table (default). csv: comma-separated values."
          }
        },
        required: [ "sql" ]
      )

      annotations(
        read_only_hint: true,
        destructive_hint: false,
        idempotent_hint: false,
        open_world_hint: false
      )

      # ── Layer 1: SQL validation ─────────────────────────────────────
      BLOCKED_KEYWORDS = /\b(INSERT|UPDATE|DELETE|DROP|ALTER|TRUNCATE|CREATE|GRANT|REVOKE|SET|COPY|MERGE|REPLACE)\b/i
      BLOCKED_CLAUSES  = /\bFOR\s+(UPDATE|SHARE|NO\s+KEY\s+UPDATE)\b/i
      BLOCKED_SHOWS    = /\bSHOW\s+(GRANTS|PROCESSLIST|BINLOG|SLAVE|MASTER|REPLICAS)\b/i
      SELECT_INTO      = /\bSELECT\b[^;]*\bINTO\b/i
      MULTI_STATEMENT  = /;\s*\S/
      ALLOWED_PREFIX   = /\A\s*(SELECT|WITH|SHOW|EXPLAIN|DESCRIBE|DESC)\b/i

      HARD_ROW_CAP = 1000

      def self.call(sql: nil, limit: nil, format: "table", server_context: nil, **_extra)
        # ── Environment guard ───────────────────────────────────────
        unless config.allow_query_in_production || !Rails.env.production?
          return text_response(
            "rails_query is disabled in production for data privacy. " \
            "Set config.allow_query_in_production = true to override."
          )
        end

        # ── Layer 1: SQL validation ─────────────────────────────────
        valid, error = validate_sql(sql)
        return text_response(error) unless valid

        # Resolve row limit
        row_limit = limit ? [ limit.to_i, HARD_ROW_CAP ].min : config.query_row_limit
        row_limit = [ row_limit, 1 ].max
        timeout_seconds = config.query_timeout

        # ── Layers 2-3: Execute with DB-level safety + row limit ────
        result = execute_safely(sql.strip, row_limit, timeout_seconds)

        # ── Layer 4: Redact sensitive columns ───────────────────────
        redacted = redact_results(result)

        # ── Format output ───────────────────────────────────────────
        output = case format
        when "csv"
          format_csv(redacted)
        else
          format_table(redacted)
        end

        text_response(output)
      rescue ActiveRecord::ConnectionNotEstablished
        text_response("Database connection unavailable. Ensure database is running and config/database.yml is correct.")
      rescue ActiveRecord::StatementInvalid => e
        if e.message.match?(/timeout|statement_timeout|MAX_EXECUTION_TIME/i)
          text_response("Query exceeded #{config.query_timeout} second timeout. Simplify the query or add indexes.")
        else
          text_response("SQL error: #{clean_error_message(e.message)}")
        end
      rescue => e
        text_response("Query failed: #{clean_error_message(e.message)}")
      end

      # ── SQL comment stripping ───────────────────────────────────────
      def self.strip_sql_comments(sql)
        sql
          .gsub(/\/\*.*?\*\//m, " ")   # Block comments: /* ... */
          .gsub(/--[^\n]*/, " ")        # Line comments: -- ...
          .gsub(/#[^\n]*/, " ")         # MySQL-style comments: # ...
          .squeeze(" ").strip
      end

      # ── SQL validation (Layer 1) ────────────────────────────────────
      def self.validate_sql(sql)
        return [ false, "SQL query is required." ] if sql.nil? || sql.strip.empty?

        cleaned = strip_sql_comments(sql)

        # Check multi-statement and clause patterns first — they provide more
        # specific error messages than the generic keyword blocker.
        return [ false, "Blocked: multiple statements (no semicolons)" ] if cleaned.match?(MULTI_STATEMENT)
        return [ false, "Blocked: FOR UPDATE/SHARE clause" ] if cleaned.match?(BLOCKED_CLAUSES)
        return [ false, "Blocked: sensitive SHOW command" ] if cleaned.match?(BLOCKED_SHOWS)
        return [ false, "Blocked: SELECT INTO creates a table" ] if cleaned.match?(SELECT_INTO)

        # Check blocked keywords before the allowed-prefix fallback so that
        # INSERT/UPDATE/DELETE/DROP etc. get a specific "Blocked" error
        # rather than the generic "Only SELECT... allowed" message.
        if (m = cleaned.match(BLOCKED_KEYWORDS))
          return [ false, "Blocked: contains #{m[0]}" ]
        end

        return [ false, "Only SELECT, WITH, SHOW, EXPLAIN, DESCRIBE allowed" ] unless cleaned.match?(ALLOWED_PREFIX)

        [ true, nil ]
      end

      # ── Database-level execution (Layer 2) ──────────────────────────
      private_class_method def self.execute_safely(sql, row_limit, timeout_seconds)
        conn = ActiveRecord::Base.connection
        adapter = conn.adapter_name.downcase

        limited_sql = apply_row_limit(sql, row_limit)

        case adapter
        when /postgresql/
          execute_postgresql(conn, limited_sql, timeout_seconds)
        when /mysql/
          execute_mysql(conn, limited_sql, timeout_seconds)
        when /sqlite/
          execute_sqlite(conn, limited_sql, timeout_seconds)
        else
          # Unknown adapter -- rely on Layer 1 regex validation only
          conn.select_all(limited_sql)
        end
      end

      private_class_method def self.execute_postgresql(conn, sql, timeout)
        result = nil
        conn.transaction do
          conn.execute("SET TRANSACTION READ ONLY")
          conn.execute("SET LOCAL statement_timeout = '#{(timeout * 1000).to_i}'")
          result = conn.select_all(sql)
          raise ActiveRecord::Rollback
        end
        result
      end

      private_class_method def self.execute_mysql(conn, sql, timeout)
        # Inject MAX_EXECUTION_TIME hint for per-query timeout
        hinted_sql = if sql.match?(/\ASELECT/i) && !sql.match?(/\/\*\+/)
          sql.sub(/\ASELECT/i, "SELECT /*+ MAX_EXECUTION_TIME(#{(timeout * 1000).to_i}) */")
        else
          sql
        end

        result = nil
        conn.transaction do
          conn.execute("SET TRANSACTION READ ONLY")
          result = conn.select_all(hinted_sql)
          raise ActiveRecord::Rollback
        end
        result
      end

      private_class_method def self.execute_sqlite(conn, sql, timeout)
        raw = conn.raw_connection
        result = nil
        begin
          conn.execute("PRAGMA query_only = ON")
          # SQLite has no native statement timeout. Use a progress handler
          # to abort queries that run too long (checked every 1000 VM steps).
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
          if raw.respond_to?(:set_progress_handler)
            raw.set_progress_handler(1000) do
              if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
                1 # non-zero = abort
              else
                0
              end
            end
          end
          result = conn.select_all(sql)
        ensure
          raw.set_progress_handler(0, nil) if raw.respond_to?(:set_progress_handler)
          conn.execute("PRAGMA query_only = OFF")
        end
        result
      end

      # ── Row limit enforcement (Layer 3) ─────────────────────────────
      private_class_method def self.apply_row_limit(sql, limit)
        effective_limit = [ limit, HARD_ROW_CAP ].min

        if sql.match?(/\bLIMIT\s+(\d+)/i)
          sql.sub(/\bLIMIT\s+(\d+)/i) do
            user_limit = $1.to_i
            "LIMIT #{[ user_limit, effective_limit ].min}"
          end
        elsif sql.match?(/\bFETCH\s+FIRST\s+(\d+)/i)
          sql.sub(/\bFETCH\s+FIRST\s+(\d+)/i) do
            user_limit = $1.to_i
            "FETCH FIRST #{[ user_limit, effective_limit ].min}"
          end
        else
          "#{sql.chomp.chomp(';')} LIMIT #{effective_limit}"
        end
      end

      # ── Column redaction (Layer 4) ──────────────────────────────────
      private_class_method def self.redact_results(result)
        redacted_cols = config.query_redacted_columns.map(&:downcase).to_set
        columns = result.columns
        rows = result.rows

        redacted_indices = columns.each_with_index.filter_map { |col, i|
          i if redacted_cols.include?(col.downcase)
        }

        return result if redacted_indices.empty?

        redacted_rows = rows.map { |row|
          row.each_with_index.map { |val, i|
            redacted_indices.include?(i) ? "[REDACTED]" : val
          }
        }

        # Return a struct-like object with columns and rows
        ResultProxy.new(columns, redacted_rows)
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
        lines << "_#{rows.size} row#{"s" unless rows.size == 1} returned._"

        lines.join("\n")
      end

      private_class_method def self.format_csv(result)
        columns = result.columns
        rows = result.rows

        return "_Query returned 0 rows._" if rows.empty?

        lines = []
        lines << columns.join(",")
        rows.each do |row|
          lines << row.map { |val|
            formatted = format_cell(val)
            # Quote values that contain commas, quotes, or newlines
            if formatted.include?(",") || formatted.include?('"') || formatted.include?("\n") || formatted.include?("\r")
              "\"#{formatted.gsub('"', '""')}\""
            else
              formatted
            end
          }.join(",")
        end

        lines.join("\n")
      end

      private_class_method def self.format_cell(val)
        return "_NULL_" if val.nil?

        if val.is_a?(String)
          # Detect binary/BLOB data
          if val.encoding == Encoding::ASCII_8BIT
            return "[BLOB]"
          end

          # Truncate long strings
          if val.length > 100
            return "#{val[0...100]}..."
          end

          # Escape pipe characters for markdown tables
          return val.gsub("|", "\\|")
        end

        val.to_s
      end

      private_class_method def self.clean_error_message(message)
        # Remove internal Ruby traces and framework noise
        message.lines.first&.strip || message.strip
      end

      # Lightweight proxy that quacks like ActiveRecord::Result for redacted output
      class ResultProxy
        attr_reader :columns, :rows

        def initialize(columns, rows)
          @columns = columns
          @rows = rows
        end
      end
    end
  end
end
