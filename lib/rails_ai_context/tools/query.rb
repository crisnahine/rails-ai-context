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
          },
          explain: {
            type: "boolean",
            description: "Run EXPLAIN on the query. Returns execution plan analysis instead of data. SELECT only."
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

      # SQL injection tautology patterns: OR 1=1, OR true, OR ''='', UNION SELECT, etc.
      TAUTOLOGY_PATTERNS = [
        /\bOR\s+1\s*=\s*1\b/i,
        /\bOR\s+true\b/i,
        /\bOR\s+'[^']*'\s*=\s*'[^']*'/i,
        /\bOR\s+"[^"]*"\s*=\s*"[^"]*"/i,
        /\bOR\s+\d+\s*=\s*\d+/i,
        /\bUNION\s+(ALL\s+)?SELECT\b/i
      ].freeze

      HARD_ROW_CAP = 1000

      def self.call(sql: nil, limit: nil, format: "table", explain: false, server_context: nil, **_extra)
        set_call_params(sql: sql&.truncate(60))
        # ── Environment guard ───────────────────────────────────────
        unless config.allow_query_in_production || !Rails.env.production?
          return text_response(
            "rails_query is disabled in production for data privacy. " \
            "Set config.allow_query_in_production = true to override."
          )
        end

        # ── ActiveRecord guard (api-only apps) ──────────────────────
        # Must come BEFORE any code that rescues ActiveRecord::* — Ruby
        # resolves rescue class constants at raise time, and `rescue
        # ActiveRecord::ConnectionNotEstablished` crashes with NameError
        # on apps where ActiveRecord is not loaded (e.g.
        # `rails new --api --skip-active-record`).
        unless defined?(ActiveRecord::Base)
          return text_response(
            "Database queries are unavailable: ActiveRecord is not loaded in this app. " \
            "This happens on API-only apps created with `rails new --api --skip-active-record`. " \
            "rails_query requires a database connection to function."
          )
        end

        # ── Layer 1: SQL validation ─────────────────────────────────
        valid, error = validate_sql(sql)
        return text_response(error) unless valid

        # ── EXPLAIN mode ────────────────────────────────────────────
        if explain
          return execute_explain(sql.strip, config.query_timeout)
        end

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
      rescue ActiveRecord::ConnectionNotEstablished, ActiveRecord::NoDatabaseError => e
        text_response("Database unavailable: #{clean_error_message(e.message)}\n\n**Troubleshooting:**\n- Check `config/database.yml` for correct host/port/credentials\n- Try `RAILS_ENV=test` if the development DB is remote\n- Run `bin/rails db:create` if the database doesn't exist yet")
      rescue ActiveRecord::StatementInvalid => e
        if e.message.match?(/timeout|statement_timeout|MAX_EXECUTION_TIME/i)
          text_response("Query exceeded #{config.query_timeout} second timeout. Simplify the query or add indexes.")
        elsif e.message.match?(/could not find|does not exist|Unknown database/i)
          text_response("Database not found: #{clean_error_message(e.message)}\n\n**Troubleshooting:**\n- Run `bin/rails db:create` to create the database\n- Check `config/database.yml` for the correct database name\n- Try `RAILS_ENV=test` if the development DB is remote")
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
          .gsub(/^\s*#[^\n]*/m, " ")   # MySQL-style comments: # at line start only
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

        # Check for SQL injection tautology patterns (OR 1=1, UNION SELECT, etc.)
        tautology = TAUTOLOGY_PATTERNS.find { |p| cleaned.match?(p) }
        return [ false, "Blocked: SQL injection pattern detected (#{cleaned[tautology]})" ] if tautology

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

      # ── EXPLAIN execution ────────────────────────────────────────────
      private_class_method def self.execute_explain(sql, timeout)
        cleaned = strip_sql_comments(sql)
        unless cleaned.match?(/\A\s*(SELECT|WITH)\b/i)
          return text_response("EXPLAIN only supports SELECT queries.")
        end

        conn = ActiveRecord::Base.connection
        adapter = conn.adapter_name.downcase

        explain_sql, parser = case adapter
        when /postgresql/
          [ "EXPLAIN (FORMAT JSON, ANALYZE) #{sql}", :parse_pg_explain ]
        when /mysql/
          [ "EXPLAIN #{sql}", :parse_mysql_explain ]
        when /sqlite/
          [ "EXPLAIN QUERY PLAN #{sql}", :parse_sqlite_explain ]
        else
          [ "EXPLAIN #{sql}", :parse_generic_explain ]
        end

        result = conn.select_all(explain_sql)
        parsed = send(parser, result)

        lines = [ "# EXPLAIN Analysis", "" ]
        lines << "**Query:** `#{sql.truncate(120)}`"
        lines << ""

        # Summary
        if parsed[:scan_types]&.any?
          lines << "## Scan Summary"
          parsed[:scan_types].each do |scan|
            lines << "- **#{scan[:table] || "?"}**: #{scan[:type]}#{scan[:index] ? " using #{scan[:index]}" : ""}"
          end
          lines << ""
        end

        # Warnings
        if parsed[:warnings]&.any?
          lines << "## Warnings"
          parsed[:warnings].each { |w| lines << "- #{w}" }
          lines << ""
        end

        # Raw plan
        lines << "## Raw Plan"
        lines << "```"
        lines << parsed[:raw]
        lines << "```"

        text_response(lines.join("\n"))
      rescue ActiveRecord::StatementInvalid => e
        text_response("EXPLAIN failed: #{clean_error_message(e.message)}")
      end

      private_class_method def self.parse_sqlite_explain(result)
        scans = []
        warnings = []
        raw_lines = []

        result.rows.each do |row|
          # SQLite EXPLAIN QUERY PLAN columns: id, parent, notused, detail
          detail = row.last.to_s
          raw_lines << detail

          if detail.match?(/SCAN\b/i)
            table = detail.match(/SCAN\s+(?:TABLE\s+)?(\w+)/i)&.captures&.first
            scan_type = detail.match?(/USING.*INDEX/i) ? "index scan" : "full table scan"
            index = detail.match(/USING.*INDEX\s+(\w+)/i)&.captures&.first
            scans << { table: table, type: scan_type, index: index }
            warnings << "Full table scan on #{table}" if scan_type == "full table scan" && table
          elsif detail.match?(/SEARCH\b/i)
            table = detail.match(/SEARCH\s+(?:TABLE\s+)?(\w+)/i)&.captures&.first
            index = detail.match(/USING.*INDEX\s+(\w+)/i)&.captures&.first
            scans << { table: table, type: "index search", index: index }
          end
        end

        { scan_types: scans, warnings: warnings, raw: raw_lines.join("\n") }
      end

      private_class_method def self.parse_pg_explain(result)
        scans = []
        warnings = []

        raw = result.rows.map { |r| r.first.to_s }.join("\n")

        # PostgreSQL JSON format returns plan as JSON
        begin
          plan_data = JSON.parse(raw)
          if plan_data.is_a?(Array) && plan_data.first.is_a?(Hash)
            plan = plan_data.first["Plan"]
            extract_pg_nodes(plan, scans, warnings) if plan
          end
        rescue JSON::ParserError
          # Non-JSON EXPLAIN format — fall through to raw output
        end

        { scan_types: scans, warnings: warnings, raw: raw }
      end

      private_class_method def self.extract_pg_nodes(node, scans, warnings)
        return unless node.is_a?(Hash)

        node_type = node["Node Type"].to_s
        table = node["Relation Name"]
        index = node["Index Name"]
        rows = node["Actual Rows"] || node["Plan Rows"]

        if node_type.include?("Seq Scan")
          scans << { table: table, type: "sequential scan", index: nil }
          warnings << "Sequential scan on #{table} (#{rows} rows)" if rows.to_i > 1000
        elsif node_type.include?("Index")
          scans << { table: table, type: node_type.downcase, index: index }
        end

        (node["Plans"] || []).each { |child| extract_pg_nodes(child, scans, warnings) }
      end

      private_class_method def self.parse_mysql_explain(result)
        scans = []
        warnings = []
        raw_lines = []

        result.rows.each do |row|
          cols = result.columns.zip(row).to_h
          raw_lines << cols.map { |k, v| "#{k}: #{v}" }.join(", ")

          table = cols["table"]
          scan_type = cols["type"]
          key = cols["key"]
          rows = cols["rows"].to_i
          extra = cols["Extra"].to_s

          type_label = case scan_type
          when "ALL" then "full table scan"
          when "index" then "full index scan"
          when "range" then "index range scan"
          when "ref", "eq_ref" then "index lookup"
          when "const", "system" then "constant lookup"
          else scan_type.to_s
          end

          scans << { table: table, type: type_label, index: key }
          warnings << "Full table scan on #{table} (#{rows} rows)" if scan_type == "ALL" && rows > 1000
          warnings << "Using filesort on #{table}" if extra.include?("filesort")
          warnings << "Using temporary table on #{table}" if extra.include?("temporary")
        end

        { scan_types: scans, warnings: warnings, raw: raw_lines.join("\n") }
      end

      private_class_method def self.parse_generic_explain(result)
        raw = result.rows.map { |r| r.join(" | ") }.join("\n")
        { scan_types: [], warnings: [], raw: raw }
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

        # Auto-redact columns declared with `encrypts` in models
        models_data = cached_context&.dig(:models)
        if models_data.is_a?(Hash)
          models_data.each_value do |data|
            next unless data.is_a?(Hash)
            (data[:encrypts] || []).each { |col| redacted_cols << col.to_s.downcase }
          end
        end
        columns = result.columns
        rows = result.rows

        # Match both real column names and aliases that end with sensitive suffixes
        sensitive_suffixes = %w[password secret token key digest hash].freeze
        redacted_indices = columns.each_with_index.filter_map { |col, i|
          col_down = col.downcase
          i if redacted_cols.include?(col_down) ||
               sensitive_suffixes.any? { |suffix| col_down.end_with?(suffix) || col_down.include?("password") || col_down.include?("secret") || col_down.include?("token") }
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
