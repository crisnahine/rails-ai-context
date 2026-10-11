# frozen_string_literal: true

require "strscan"

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
          }
        },
        required: [ "sql" ]
      )

      guide_row(
        order: 32,
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

      # ── Layer 1: SQL validation ─────────────────────────────────────
      # REPLACE is the MySQL statement; `replace(` is the string function every
      # database has, so a REPLACE followed by an opening parenthesis is let be.
      BLOCKED_KEYWORDS = /\b(INSERT|UPDATE|DELETE|DROP|ALTER|TRUNCATE|CREATE|GRANT|REVOKE|SET|COPY|MERGE|REPLACE(?!\s*\())\b/i
      # SHOW CREATE TABLE / VIEW print a definition; every other SHOW CREATE is
      # refused by the CREATE keyword - SHOW CREATE USER prints credential hashes.
      SHOW_CREATE_DEFINITION = /\A\s*SHOW\s+CREATE\s+(?:TABLE|VIEW)\b/i
      BLOCKED_CLAUSES  = /\bFOR\s+(UPDATE|SHARE|NO\s+KEY\s+UPDATE)\b/i
      BLOCKED_SHOWS    = /\bSHOW\s+(GRANTS|PROCESSLIST|BINLOG|SLAVE|MASTER|REPLICAS)\b/i
      SELECT_INTO      = /\bSELECT\b[^;]*\bINTO\b/i
      MULTI_STATEMENT  = /;\s*\S/
      ALLOWED_PREFIX   = /\A\s*(SELECT|WITH|SHOW|EXPLAIN|DESCRIBE|DESC)\b/i

      # SELECT-callable functions that give the caller a filesystem / network
      # exfiltration primitive even though the query is technically a SELECT.
      # These pass `SET TRANSACTION READ ONLY` because they're reads from the
      # DB engine's perspective, but they bypass the gem's `sensitive_patterns`
      # file allowlist entirely by pivoting through the database process.
      #
      # Postgres: pg_read_file / pg_read_binary_file / pg_ls_dir / pg_stat_file
      #           (file read), lo_import / lo_export (large-object I/O),
      #           dblink* (cross-db exfiltration).
      # MySQL:    LOAD_FILE (scalar file read outside SELECT INTO contexts).
      # SQLite:   load_extension (shared-library load - disabled by default
      #           but harden in defense).
      #
      # COPY ... TO PROGRAM is not one of these: COPY is not a SELECT, so the
      # statement keyword blocker rejects it before this runs.
      BLOCKED_FUNCTIONS = /\b(
        pg_read_binary_file | pg_read_file |
        pg_ls_dir | pg_ls_logdir | pg_ls_tmpdir | pg_ls_waldir | pg_ls_archive_statusdir |
        pg_stat_file | pg_file_settings | pg_current_logfile |
        lo_import | lo_export |
        dblink[a-z_]* |
        LOAD\s+DATA |
        load_file | load_extension
      )\b/ix

      # Checked before SELECT_INTO, which also matches, so the refusal names the disk write.
      BLOCKED_OUTPUT = /\bINTO\s+(OUTFILE|DUMPFILE)\b/i

      # Session-effecting / administrative PostgreSQL functions. A query is a
      # read from the engine's point of view, so SET TRANSACTION READ ONLY lets
      # these run and keep their effect on the pooled connection: a backend is
      # terminated, a config rotated, a stat reset, a WAL/restore/replication
      # control fired, a logical message emitted, a session advisory lock left
      # held. This is the FIRST layer, a fast name blocklist; the PostgreSQL
      # plan's VOLATILE-function check (pg_proc.provolatile) is the robust layer
      # that closes the rest of the family without an ever-growing list.
      BLOCKED_PG_ADMIN = /\b(
        pg_terminate_backend | pg_cancel_backend |
        pg_reload_conf | pg_rotate_logfile[a-z_]* |
        pg_stat_reset[a-z_]* |
        pg_switch_wal | pg_switch_xlog | pg_create_restore_point |
        pg_create_(?:physical|logical)_replication_slot | pg_drop_replication_slot |
        pg_replication_origin_[a-z_]* | pg_logical_emit_message |
        pg_advisory_lock[a-z_]* | pg_advisory_unlock[a-z_]* |
        pg_advisory_xact_lock[a-z_]* | pg_try_advisory_lock[a-z_]* |
        pg_promote | pg_wal_replay_pause | pg_wal_replay_resume |
        pg_xlog_replay_pause | pg_xlog_replay_resume |
        pg_notify | set_config | txid_current[a-z_]* | pg_current_xact_id[a-z_]* |
        pg_import_system_collations
      )\s*\(/ix

      # Session-effecting MySQL/MariaDB functions. GET_LOCK leaves a named lock
      # held on the pooled connection after the query returns, which a later
      # caller inherits; RELEASE_* and the IS_* probes drive the same session
      # lock table. source/master_pos_wait block on replication. MySQL has no
      # cheap volatility catalogue like pg_proc, so these are a name blocklist.
      BLOCKED_MYSQL_SESSION = /\b(
        get_lock | release_lock | release_all_locks | is_free_lock | is_used_lock |
        master_pos_wait | source_pos_wait
      )\s*\(/ix

      # VOLATILE functions known to only read. pg_proc marks a function VOLATILE
      # when its answer may change within one statement, which is as true of a
      # reader of live server state as of a writer, so VOLATILE alone does not
      # mean "changes state". Each one here is a built-in C function that writes
      # nothing (every one is also proparallel 's', parallel safe):
      #   * values: random, clock_timestamp, gen_random_uuid, timeofday,
      #     uuid_generate_v4; pg_sleep* only waits, and the statement timeout
      #     bounds it.
      #   * sizes (dbsize.c): stat() the relation, database or tablespace files;
      #     the most they take is a transaction-scoped AccessShareLock, released
      #     when the read-only transaction rolls back.
      #   * lock status (lockfuncs.c): a snapshot of the shared lock table -
      #     pg_lock_status is what the pg_locks view reads.
      #   * recovery and WAL position (xlogfuncs.c): read shared-memory
      #     positions and flags; pg_current_wal_* only reports where WAL is.
      # pg_stat_activity is not here: pg_stat_get_activity is STABLE, so it was
      # never refused. Everything else the plan reports as VOLATILE is refused.
      PG_VOLATILE_ALLOWLIST = %w[
        random clock_timestamp gen_random_uuid timeofday uuid_generate_v4
        pg_sleep pg_sleep_for pg_sleep_until
        pg_total_relation_size pg_relation_size pg_table_size pg_indexes_size
        pg_database_size pg_tablespace_size
        pg_lock_status pg_blocking_pids pg_safe_snapshot_blocking_pids
        pg_is_in_recovery pg_is_wal_replay_paused pg_get_wal_replay_pause_state
        pg_current_wal_lsn pg_current_wal_insert_lsn pg_current_wal_flush_lsn
        pg_last_wal_receive_lsn pg_last_wal_replay_lsn pg_last_xact_replay_timestamp
      ].freeze

      # A column-alias list renames the columns a wildcard produced, so the
      # names redaction reads no longer name the sensitive columns underneath.
      # These refuse one on a CTE or a FROM item (derived table or table alias).
      # The list is BARE identifiers only: a type modifier (numeric(10,2),
      # varchar(255)) carries digits, and a record-returning function's list
      # (json_to_recordset(...) AS t(a int, b text)) carries types, so neither
      # matches; a single-column alias (generate_series(...) AS g(n)) is not a
      # rename of several columns and is left alone. A list on a VALUES body
      # (`(VALUES (1,'a')) AS v(id, name)`, `WITH v(id, name) AS (VALUES ...)`)
      # renames no table column - VALUES has none - so it is left alone too;
      # see renaming_alias_list?.
      ALIAS_IDENT     = /[A-Za-z_]\w*/
      ALIAS_IDENT_LIST = /#{ALIAS_IDENT}(?:\s*,\s*#{ALIAS_IDENT})+/
      # CTE column list: name(a, b, ...) AS (
      CTE_ALIAS_LIST = /#{ALIAS_IDENT}\s*\(\s*#{ALIAS_IDENT_LIST}\s*\)\s*AS\s*\(/i
      # Derived-table / explicit alias: ... AS alias(a, b, ...)
      DERIVED_ALIAS_LIST = /\bAS\s+#{ALIAS_IDENT}\s*\(\s*#{ALIAS_IDENT_LIST}\s*\)/i
      # Table alias without AS: FROM/JOIN table alias(a, b, ...)
      TABLE_ALIAS_LIST = /\b(?:FROM|JOIN)\s+#{ALIAS_IDENT}(?:\.#{ALIAS_IDENT})?\s+#{ALIAS_IDENT}\s*\(\s*#{ALIAS_IDENT_LIST}\s*\)/i
      COLUMN_ALIAS_LIST = Regexp.union(CTE_ALIAS_LIST, DERIVED_ALIAS_LIST, TABLE_ALIAS_LIST)

      # Defense against the column-aliasing redaction bypass:
      #
      #   SELECT password_digest AS x FROM users       -- bypasses result.columns redaction
      #   SELECT substring(password_digest, 1, 60) ... -- column name becomes "substring"
      #   SELECT md5(session_data) FROM sessions       -- column name becomes "md5"
      #
      # Post-execution redaction operates on the column names the DB returns,
      # which the caller controls via aliases and expressions. The only
      # defense that works is to reject queries that TEXTUALLY reference
      # any sensitive column, before execution. This list is frozen, so an app
      # whose own column merely looks sensitive exempts it by name through
      # `config.query_allowed_columns`.
      SENSITIVE_COLUMN_SUFFIXES = %w[
        password_digest password_hash encrypted_password
        password_reset_token confirmation_token unlock_token
        remember_token reset_password_token api_key api_secret
        access_token refresh_token jti otp_secret session_data
        secret_key secret private_key
      ].freeze

      # SQL injection tautology patterns: OR 1=1, OR true, OR ''='', etc.
      TAUTOLOGY_PATTERNS = [
        /\bOR\s+1\s*=\s*1\b/i,
        /\bOR\s+true\b/i,
        /\bOR\s+'[^']*'\s*=\s*'[^']*'/i,
        /\bOR\s+"[^"]*"\s*=\s*"[^"]*"/i,
        /\bOR\s+\d+\s*=\s*\d+/i
      ].freeze

      # A UNION takes its column names from its first SELECT, so rows of
      # another table - a wildcard's columns included - come out under those
      # names, past the redaction that reads them. Any UNION is refused, in
      # every spelling: `UNION ALL`, `UNION DISTINCT`, and the parenthesised
      # `UNION (SELECT ...)` MySQL 8 and MariaDB take, which the narrower
      # pattern this replaces let through. INTERSECT and EXCEPT return only
      # rows of their first SELECT, so they stay.
      SET_UNION = /\bUNION\b/i

      HARD_ROW_CAP = 1000

      # Trilogy is Rails 8's default MySQL adapter (`adapter_name` reports
      # "Trilogy", not "Mysql2") - every dispatch that branches on adapter
      # name to apply the MySQL safety/parsing path must match both, or
      # Trilogy apps silently fall through to the "unknown adapter" path
      # with no READ ONLY transaction and no statement timeout.
      MYSQL_ADAPTER = /mysql|trilogy/i

      # activerecord-postgis-adapter reports "PostGIS" for what is a PostgreSQL connection.
      POSTGRES_ADAPTER = /postg/i

      # SHOW/DESCRIBE/EXPLAIN return schema metadata (a table's column list,
      # an EXPLAIN plan), never application data rows. Two consequences:
      #   1. They're inherently bounded - appending `LIMIT n` to them is
      #      invalid syntax on MySQL/Postgres and the query fails outright,
      #      even though these statements are explicitly advertised as allowed.
      #   2. Column-name-based redaction doesn't apply to them - MySQL's
      #      DESCRIBE returns a literal column named "Key" (PRI/UNI/MUL/empty)
      #      that isn't actual secret data but matches the generic
      #      sensitive-suffix heuristic (ends_with "key") used for real result
      #      sets, so it would otherwise be redacted into uselessness.
      SCHEMA_METADATA_PREFIX = /\A\s*(SHOW|DESCRIBE|DESC|EXPLAIN)\b/i

      # The session record is echoed back to the model; a full query body can
      # carry literals from the app's own data, so keep only enough to
      # recognise the call.
      def self.session_params(kwargs)
        params = super
        params.key?(:sql) ? params.merge(sql: params[:sql].to_s.truncate(60)) : params
      end

      def self.call(sql: nil, limit: nil, format: "table", explain: false, server_context: nil, **_extra)
        if (refusal = static_tier_refusal("Running SQL queries"))
          return refusal
        end

        # ── Environment guard ───────────────────────────────────────
        unless config.allow_query_in_production || rails_env_name != "production"
          return text_response(
            "rails_query is disabled in production for data privacy. " \
            "Set config.allow_query_in_production = true to override."
          )
        end

        # ── ActiveRecord guard (api-only apps) ──────────────────────
        # Must come BEFORE any code that rescues ActiveRecord::* - Ruby
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
        mysql = mysql_dialect?
        postgres = postgres_adapter?
        valid, error = validate_sql(sql, mysql: mysql, postgres: postgres)
        return error_response(error) unless valid

        # Run the text the validator read, never the raw input: whatever the
        # scanner and the database disagree on, nothing unread reaches the database.
        sql = comment_free(sql, mysql: mysql)

        # ── Layer 1b: PostgreSQL semantic check (planning only) ─────
        # EXPLAIN (VERBOSE, FORMAT JSON) in a read-only transaction plans the
        # query without running it, so whole-row serialisation, an expanded
        # sensitive column and a VOLATILE admin function are caught before any
        # execution - the normal path and the EXPLAIN path alike.
        if (refusal = postgresql_plan_refusal(sql, config.query_timeout))
          return error_response(refusal)
        end

        # A sensitive name that survived validation only because it sat inside a
        # literal (masked on PostgreSQL) is allowed only if the plan was obtained
        # and passed every check above - so a masker fooled by a quote trick can
        # never be the only gate. No plan (planning failed) keeps the raw refusal.
        if (refusal = unvouched_literal_refusal(sql, postgres))
          return error_response(refusal)
        end

        # ── EXPLAIN mode ────────────────────────────────────────────
        if explain
          return execute_explain(sql, config.query_timeout)
        end

        # Resolve row limit
        row_limit = limit ? [ limit.to_i, HARD_ROW_CAP ].min : config.query_row_limit
        row_limit = [ row_limit, 1 ].max
        timeout_seconds = config.query_timeout

        # ── Layers 2-3: Execute with DB-level safety + row limit ────
        result = execute_safely(sql, row_limit, timeout_seconds)

        # ── Layer 4: Redact sensitive columns ───────────────────────
        # Skip for SHOW/DESCRIBE/EXPLAIN - see SCHEMA_METADATA_PREFIX.
        schema_metadata = sql.match?(SCHEMA_METADATA_PREFIX)
        provenance = schema_metadata ? [] : provenance_sensitive_indices(sql) | plan_output_sensitive_indices(sql, result)
        redacted = if sql.match?(SHOW_CREATE_DEFINITION)
          redact_definition(result)
        elsif schema_metadata
          result
        else
          redact_results(result, provenance)
        end

        # ── Format output ───────────────────────────────────────────
        # The truncation note rides every format (for CSV, after a blank line so
        # a parser still reads the block); the unbounded-SQLite note stays off
        # CSV, which is meant to be plain data.
        cut = !schema_metadata && result.respond_to?(:truncated) && result.truncated
        truncation = cut ? truncation_note([ row_limit, HARD_ROW_CAP ].min, format) : ""
        output = case format
        when "csv"
          format_csv(redacted) + truncation
        else
          format_table(redacted) + truncation + unbounded_note(result)
        end

        text_response(output)
      rescue ActiveRecord::ConnectionNotEstablished, ActiveRecord::NoDatabaseError => e
        text_response("Database unavailable: #{clean_error_message(e.message)}\n\n**Troubleshooting:**\n- Check `config/database.yml` for correct host/port/credentials\n- Try `RAILS_ENV=test` if the development DB is remote\n- Run `bin/rails db:create` if the database doesn't exist yet")
      rescue ActiveRecord::StatementInvalid => e
        if e.message.match?(/timeout|statement_timeout|MAX_EXECUTION_TIME|max_statement_time|maximum statement execution time exceeded/i)
          text_response("Query exceeded #{config.query_timeout} second timeout. Simplify the query or add indexes.")
        # Only a missing DATABASE. Postgres words a missing column and a
        # missing table the same way ("... does not exist"), and matching
        # that shape answered a real SQL error with `db:create` advice and
        # exit 0. `ActiveRecord::NoDatabaseError` is rescued above, so this
        # only catches adapters that raise the plain StatementInvalid.
        elsif e.message.match?(/database "[^"]*" does not exist|could not find (?:your )?database|Unknown database/i)
          text_response("Database not found: #{clean_error_message(e.message)}\n\n**Troubleshooting:**\n- Run `bin/rails db:create` to create the database\n- Check `config/database.yml` for the correct database name\n- Try `RAILS_ENV=test` if the development DB is remote")
        else
          # Genuine execution failure (unknown column, bad table, syntax
          # error) - flag as an error result so MCP clients and the CLI
          # (exit 1) treat it as failed. Guidance about a database that is
          # not there stays informational above: the question is answerable,
          # just not now.
          error_response("SQL error: #{clean_error_message(e.message)}")
        end
      rescue => e
        error_response("Query failed: #{clean_error_message(e.message)}")
      end

      # ── SQL comment stripping ───────────────────────────────────────
      def self.strip_sql_comments(sql, mysql: false)
        comment_free(sql, mysql: mysql).squeeze(" ")
      end

      QUOTED = /'[^']*'?|"[^"]*"?|`[^`]*`?/m
      # A backslash escapes the next character: every MySQL string, and a PostgreSQL E'...' one.
      ESCAPED_STRING = /'(?:\\.|[^'\\])*'?/m
      MYSQL_QUOTED = /#{ESCAPED_STRING}|"(?:\\.|[^"\\])*"?|`[^`]*`?/m
      DOLLAR_QUOTED = /(?<![\p{Word}$])\$(\p{Word}*)\$.*?\$\1\$/m
      UNQUOTED = /[^'"`$\/\-#*]+/

      # Comments out, everything else as written: this is the text that runs.
      # A quoted span is copied whole, so a comment marker inside one is data.
      # Only MySQL has a hash comment, a `--` that needs a space after it, and
      # `/*! ... */` content it runs. PostgreSQL has dollar quoting.
      def self.comment_free(sql, mysql: false)
        # fixed_anchor, so the dollar quote's lookbehind sees the text before the pointer.
        scanner = StringScanner.new(sql, fixed_anchor: true)
        line_comment = mysql ? /--(?=\s|\z)[^\n]*|#[^\n]*/ : /--[^\n]*/
        out = +""
        executable = false

        until scanner.eos?
          quoted = if mysql then MYSQL_QUOTED
          elsif out.match?(/(?<![\p{Word}$])[eE]\z/) && scanner.check(/'/) then ESCAPED_STRING
          else QUOTED
          end

          if (span = scanner.scan(quoted) || (!mysql && scanner.scan(DOLLAR_QUOTED)) || scanner.scan(UNQUOTED))
            out << span
          elsif mysql && scanner.scan(/\/\*!\d*/)
            # Its content stays in the text for the checks to read, e.g. the
            # `LOAD_FILE` in `SELECT /*!50000 LOAD_FILE('/etc/passwd') */`.
            executable = true
            out << " "
          elsif executable && scanner.scan(/\*\//)
            executable = false
            out << " "
          elsif scanner.scan(/\/\*.*?(?:\*\/|\z)/m) || scanner.scan(line_comment)
            out << " "
          else
            out << scanner.getch
          end
        end

        out.strip
      end

      # Comment-free text with every quoted and dollar-quoted span blanked to
      # spaces of the same length, so a check reads structure only. A `;` or a
      # keyword inside a string literal or a `$$ ... $$` body is data, not a
      # second statement: it is the `;` in a `DO $$ ... ; ... $$` block that
      # made the multi-statement check refuse one for the wrong reason.
      def self.mask_quoted(text, mysql: false)
        scanner = StringScanner.new(text, fixed_anchor: true)
        out = +""

        until scanner.eos?
          quoted = if mysql then MYSQL_QUOTED
          elsif out.match?(/(?<![\p{Word}$])[eE]\z/) && scanner.check(/'/) then ESCAPED_STRING
          else QUOTED
          end

          if (span = scanner.scan(quoted) || (!mysql && scanner.scan(DOLLAR_QUOTED)))
            out << (" " * span.length)
          elsif (span = scanner.scan(UNQUOTED))
            out << span
          else
            out << scanner.getch
          end
        end

        out
      end

      # Whether the SQL carries a column-alias list that renames a table's
      # columns. A list on a VALUES body renames nothing a table holds, so it is
      # left alone; a sensitive name inside the VALUES rows is still refused by
      # the textual check. The lists are matched on the text as written, as
      # before; parentheses are balanced on quote-masked text (same length, same
      # positions), so one inside a literal does not move a body's bounds.
      private_class_method def self.renaming_alias_list?(cleaned, mysql: false)
        return true if cleaned.match?(TABLE_ALIAS_LIST)

        masked = mask_quoted(cleaned, mysql: mysql)
        # A CTE's list: the pattern ends on the "(" that opens its body.
        cleaned.scan(CTE_ALIAS_LIST) do
          return true unless values_body_at?(masked, Regexp.last_match.end(0))
        end
        # A derived table's list: its body is the parenthesis before AS.
        cleaned.scan(DERIVED_ALIAS_LIST) do
          open = derived_table_open(masked, Regexp.last_match.begin(0))
          return true unless open && values_body_at?(masked, open + 1)
        end
        false
      end

      private_class_method def self.values_body_at?(masked, position)
        masked[position..].to_s.match?(/\A\s*VALUES\b/i)
      end

      # The index of the "(" that opens the parenthesised FROM item ending just
      # before `as_position`, or nil when no ")" stands there.
      private_class_method def self.derived_table_open(masked, as_position)
        close = as_position - 1
        close -= 1 while close >= 0 && masked[close].match?(/\s/)
        return nil unless close >= 0 && masked[close] == ")"

        depth = 0
        close.downto(0) do |i|
          depth += 1 if masked[i] == ")"
          depth -= 1 if masked[i] == "("
          return i if depth.zero?
        end
        nil
      end

      private_class_method def self.mysql_dialect?
        ActiveRecord::Base.connection_db_config.adapter.to_s.match?(MYSQL_ADAPTER)
      rescue ActiveRecord::ActiveRecordError
        false
      end

      # ── SQL validation (Layer 1) ────────────────────────────────────
      # `postgres:` relaxes the sensitive-column check so a name inside a string
      # literal ('%secret%', a JSON key) is read as data, not a column - safe on
      # PostgreSQL because its plan layer (Layer 1b) re-checks and must vouch.
      # MySQL, SQLite and unknown adapters keep raw-text matching, with no
      # masking: MySQL's NO_BACKSLASH_ESCAPES and ANSI_QUOTES modes change what a
      # quote means, and SQLite reads a single-quoted name after a dot (t.'col')
      # as an identifier, so a masker there could be fooled into hiding one.
      def self.validate_sql(sql, mysql: false, postgres: false)
        return [ false, "SQL query is required." ] if sql.nil? || sql.strip.empty?

        # Belt-and-suspenders: run BLOCKED_FUNCTIONS against the RAW sql before
        # stripping comments. If the unwrap logic in comment_free is ever
        # defeated by a novel MySQL comment variant, this still catches the
        # dangerous primitives (pg_read_file, LOAD_FILE, dblink, ...).
        if (m = sql.match(BLOCKED_FUNCTIONS))
          return [ false, "Blocked: dangerous function #{m[0]} (filesystem/network primitive)" ]
        end

        cleaned = strip_sql_comments(sql, mysql: mysql)

        # Check multi-statement and clause patterns first - they provide more
        # specific error messages than the generic keyword blocker. The
        # semicolon is read on quote-masked text, so one inside a string literal
        # or a `$$ ... $$` block body is not mistaken for a second statement.
        #
        # The statement-keyword checks (SELECT INTO, the write keywords) read the
        # same quote-masked text, so `LIKE '%update%'` or `'put into box'` is
        # data. That is safe: ALLOWED_PREFIX still requires a read statement, and
        # the read-only transaction (PostgreSQL, MySQL) or read-only connection
        # (SQLite) stops any write a mis-masked literal could hide. A disk write
        # (INTO OUTFILE/DUMPFILE) and the file/network functions stay on the raw
        # text: no read-only transaction stops a server-side file write.
        masked = mask_quoted(cleaned, mysql: mysql)
        return [ false, "Blocked: multiple statements (no semicolons)" ] if masked.match?(MULTI_STATEMENT)
        return [ false, "Blocked: FOR UPDATE/SHARE clause" ] if cleaned.match?(BLOCKED_CLAUSES)
        return [ false, "Blocked: sensitive SHOW command" ] if cleaned.match?(BLOCKED_SHOWS)
        return [ false, "Blocked: SELECT INTO OUTFILE / DUMPFILE writes to disk" ] if cleaned.match?(BLOCKED_OUTPUT)
        return [ false, "Blocked: SELECT INTO creates a table" ] if masked.match?(SELECT_INTO)

        # Block database functions that give a filesystem/network primitive.
        # pg_read_file, lo_import, dblink, LOAD_FILE, load_extension, etc.
        # These pass SET TRANSACTION READ ONLY but bypass sensitive_patterns.
        if (m = cleaned.match(BLOCKED_FUNCTIONS))
          return [ false, "Blocked: dangerous function #{m[0]} (filesystem/network primitive)" ]
        end

        # Session-effecting admin / lock functions run under READ ONLY and keep
        # their effect on the pooled connection. The name blocklist is the first
        # layer; PostgreSQL's plan VOLATILE-function check is the robust one.
        if (m = cleaned.match(BLOCKED_PG_ADMIN))
          fn = m[0].sub(/\s*\(\z/, "")
          return [ false,
            "Blocked: administrative function #{fn} has a session or server-wide " \
            "effect that a read-only transaction does not prevent. rails_query runs " \
            "read-only queries for inspection; it will not run server-control functions." ]
        end
        if (m = cleaned.match(BLOCKED_MYSQL_SESSION))
          fn = m[0].sub(/\s*\(\z/, "")
          return [ false,
            "Blocked: session function #{fn} leaves state (a named lock) on the pooled " \
            "connection after the query returns. rails_query will not run it." ]
        end

        # A CTE or FROM-item column-alias list renames a wildcard's columns,
        # which would carry the sensitive values out under harmless names. One
        # on a VALUES body renames no table column and is left alone.
        if renaming_alias_list?(cleaned, mysql: mysql)
          return [ false,
            "Blocked: a column-alias list (e.g. `t(a, b, c)`) renames the columns a " \
            "wildcard returns, so sensitive columns would leave under harmless names. " \
            "Name the columns you want in the SELECT list instead." ]
        end

        # On PostgreSQL a "union" inside a string literal is data; its plan
        # layer reads the query itself. Elsewhere the raw text decides.
        if (postgres ? mask_sql_literals(cleaned) : cleaned).match?(SET_UNION)
          return [ false,
            "Blocked: UNION is not run. A UNION takes its column names from its first SELECT, " \
            "so rows of another table would come out under those names, past the redaction that " \
            "reads them. Query each table on its own; a recursive CTE needs UNION, so it is not run either." ]
        end

        # Check for SQL injection tautology patterns (OR 1=1, OR true, etc.)
        tautology = TAUTOLOGY_PATTERNS.find { |p| cleaned.match?(p) }
        return [ false, "Blocked: SQL injection pattern detected (#{cleaned[tautology]})" ] if tautology

        # Check blocked keywords before the allowed-prefix fallback so that
        # INSERT/UPDATE/DELETE/DROP etc. get a specific "Blocked" error
        # rather than the generic "Only SELECT... allowed" message. Read on the
        # quote-masked text; SHOW CREATE TABLE / VIEW drop their CREATE first.
        if (m = masked.sub(SHOW_CREATE_DEFINITION, "SHOW").match(BLOCKED_KEYWORDS))
          return [ false, "Blocked: contains #{m[0]}" ]
        end

        return [ false, "Only SELECT, WITH, SHOW, EXPLAIN, DESCRIBE allowed" ] unless cleaned.match?(ALLOWED_PREFIX)

        # Column-aliasing redaction bypass defense: reject any query that
        # textually references a sensitive column name. Post-execution redaction
        # reads the output column names, which an alias or an expression renames,
        # so it cannot survive `SELECT password_digest AS x` or `upper(api_token)`.
        # On PostgreSQL the match runs on literal-masked text; `.call` then makes
        # the plan vouch for anything that passed only because of that masking.
        if (offending = references_sensitive_column?(postgres ? mask_sql_literals(cleaned) : cleaned))
          return [ false,
            "Blocked: query references sensitive column `#{offending}`. " \
            "Name the columns you need; `#{offending}` is sensitive and never " \
            "returned, and an alias or expression over it cannot be redacted after " \
            "the query runs, so the whole query is refused. If `#{offending}` is not " \
            "sensitive in your app, add \"#{offending}\" to config.query_allowed_columns " \
            "in an initializer." ]
        end

        [ true, nil ]
      end

      # PostgreSQL string literals masked to an empty pair, so a sensitive word
      # inside one (a `'%secret%'` pattern, a JSON key `->>'token'`) is read as
      # data, not a column name. Dollar quotes first, then single quotes with any
      # PG prefix (`E` escapes a backslash; `U&`, `B`, `X`). A double-quoted
      # identifier is never touched. This is good enough for the textual layer;
      # the plan layer, whose deparser output does not depend on
      # standard_conforming_strings, is the final authority (see .call).
      # A double-quoted identifier is matched so it is skipped whole: a quote
      # inside one (`AS "a'b"`) would otherwise open a literal that swallows
      # the SQL after it.
      PG_TEXT_LITERAL = /
        (?<ident>"(?:""|[^"])*")
        | \$(?<tag>(?:[A-Za-z_]\w*)?)\$.*?\$\k<tag>\$
        | [eE]'(?:\\.|''|[^'])*'
        | (?:[uU]&|[bBxX])?'(?:''|[^'])*'
      /mx
      def self.mask_sql_literals(text)
        text.gsub(PG_TEXT_LITERAL) { Regexp.last_match[:ident] || "''" }
      end

      # Returns the first sensitive column name the SQL names, or nil. Two rules,
      # one predicate (sensitive_column?):
      #   * a fixed name list - config.query_redacted_columns and
      #     SENSITIVE_COLUMN_SUFFIXES - matched on every adapter whether or not
      #     the name is a real column, so the oracle holds with no connection;
      #   * every REAL column of the app's schema that the predicate flags
      #     (an `api_token` the heuristic catches, an `encrypts` column), so an
      #     app-specific sensitive column is caught through an alias or an
      #     expression too.
      # The match is case-insensitive and word-bounded, so a table or alias that
      # merely contains "token" does not trip it - only a real column name does.
      def self.references_sensitive_column?(cleaned_sql)
        down = cleaned_sql.downcase
        blocked_column_names.each do |col|
          next if col.empty?
          return col if down.match?(/\b#{Regexp.escape(col)}\b/)
        end
        nil
      end

      # The names the textual pre-check refuses: the fixed list, plus the real
      # sensitive columns of the schema, minus the app's allowed columns.
      private_class_method def self.blocked_column_names
        fixed = Array(config.query_redacted_columns).map { |c| c.to_s.downcase } +
                SENSITIVE_COLUMN_SUFFIXES.map(&:downcase)
        (fixed + schema_sensitive_columns.to_a).uniq - allowed_columns.to_a
      end

      # The real columns of the live schema the sensitivity rule flags. Read from
      # the connection (cached per run), falling back to the cached context, so a
      # column caught only by the result heuristic (`api_token`, `auth_token`) is
      # refused through any alias or expression before the query runs.
      private_class_method def self.schema_sensitive_columns
        real_column_names.select { |name| sensitive_column?(name) }
      end

      # Rails' own bookkeeping tables, on every adapter. Their columns
      # (schema_migrations.version, ar_internal_metadata.key/value) are never
      # secrets, and ar_internal_metadata.key ends in "key", so leaving them in
      # the sensitive-column set refused every query whose text held the word
      # "key" - a column, a JSON key, a `LIKE '%key%'`. A `SELECT *` from one
      # still goes through output-name redaction, as before.
      BOOKKEEPING_TABLES = %w[ar_internal_metadata schema_migrations].freeze

      private_class_method def self.bookkeeping_table?(name)
        BOOKKEEPING_TABLES.include?(name.to_s.downcase)
      end

      # Every real column name of the app's schema, downcased. The live
      # connection first (its own schema cache), the cached introspection as a
      # fallback. Memoised for the run; nothing here raising fails the query.
      private_class_method def self.real_column_names
        RailsAiContext::RunCache.fetch([ :query_real_columns ]) do
          columns_from_connection || columns_from_context || Set.new
        end
      end

      private_class_method def self.columns_from_connection
        conn = ActiveRecord::Base.connection
        names = Set.new
        conn.tables.each do |t|
          next if bookkeeping_table?(t)
          conn.columns(t).each { |c| names << c.name.to_s.downcase }
        end
        names
      rescue StandardError
        nil
      end

      private_class_method def self.columns_from_context
        tables = cached_context&.dig(:schema, :tables)
        return nil unless tables.is_a?(Hash)

        names = Set.new
        tables.each do |table, data|
          next if bookkeeping_table?(table)
          Array(data.is_a?(Hash) && data[:columns]).each do |col|
            name = col.is_a?(Hash) ? col[:name] : col
            names << name.to_s.downcase if name
          end
        end
        names
      rescue StandardError
        nil
      end

      # One sensitivity rule, read by the textual pre-check, the PostgreSQL plan
      # check and result redaction alike: a column is sensitive when it is a
      # configured or built-in redacted name, an `encrypts` column, or matches
      # the result heuristic - unless the app allows it by name.
      def self.sensitive_column?(name)
        down = name.to_s.downcase
        return false if down.empty? || allowed_columns.include?(down)

        redacted_name_set.include?(down) ||
          encrypted_column_set.include?(down) ||
          sensitive_by_heuristic?(down)
      end

      # Ends with a secret-ish suffix, or carries one of the broad secret words.
      # The same heuristic result redaction has always used on output names.
      SENSITIVE_SUFFIXES = %w[password secret token key digest hash].freeze
      private_class_method def self.sensitive_by_heuristic?(down)
        down.end_with?(*SENSITIVE_SUFFIXES) || down.match?(/password|secret|token/)
      end

      private_class_method def self.redacted_name_set
        (Array(config.query_redacted_columns).map { |c| c.to_s.downcase } +
          SENSITIVE_COLUMN_SUFFIXES.map(&:downcase)).to_set
      end

      # Columns an `encrypts` declaration covers, from the cached introspection.
      private_class_method def self.encrypted_column_set
        set = Set.new
        models = cached_context&.dig(:models)
        if models.is_a?(Hash)
          models.each_value do |data|
            next unless data.is_a?(Hash)
            Array(data[:encrypts]).each { |col| set << col.to_s.downcase }
          end
        end
        set
      end

      # An app whose own column merely looks sensitive (oauth_applications.secret)
      # exempts it by name, from the pre-query check and from result redaction alike.
      private_class_method def self.allowed_columns
        Array(config.query_allowed_columns).to_set { |c| c.to_s.downcase }
      end

      # ── Database-level execution (Layer 2) ──────────────────────────
      private_class_method def self.execute_safely(sql, row_limit, timeout_seconds)
        conn = ActiveRecord::Base.connection
        adapter = conn.adapter_name.downcase

        limited_sql = apply_row_limit(sql, row_limit)

        cap_rows(run_guarded(conn, adapter, limited_sql, timeout_seconds), sql, row_limit)
      end

      # EXPLAIN goes through the adapter wrappers too (READ ONLY, timeout): EXPLAIN ANALYZE runs
      # the plan, so `explain: true` must not hold a connection past query_timeout.
      private_class_method def self.run_guarded(conn, adapter, sql, timeout)
        case adapter
        when POSTGRES_ADAPTER
          execute_postgresql(conn, sql, timeout)
        when MYSQL_ADAPTER
          execute_mysql(conn, sql, timeout)
        when /sqlite/
          execute_sqlite(conn, sql, timeout)
        else
          # Unknown adapter -- rely on Layer 1 regex validation only
          conn.select_all(sql)
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
        # Per-query timeout. MySQL honours the MAX_EXECUTION_TIME optimizer hint;
        # MariaDB ignores it (a long query would run unbounded, holding the
        # connection), so there the statement is bounded with MariaDB's own
        # `SET STATEMENT max_statement_time = <seconds> FOR <query>`, which scopes
        # the limit to this one statement and needs no restore on the pool.
        bounded_sql = if mariadb_server?(conn)
          "SET STATEMENT max_statement_time=#{[ timeout.to_f, 0.001 ].max} FOR #{sql}"
        elsif sql.match?(/\ASELECT/i)
          sql.sub(/\ASELECT/i, "SELECT /*+ MAX_EXECUTION_TIME(#{(timeout * 1000).to_i}) */")
        else
          sql
        end

        # The SET must run BEFORE the transaction opens: Rails materializes
        # the lazy BEGIN ahead of the first in-block statement, and MySQL
        # rejects changing transaction characteristics mid-transaction
        # (error 1568). Without GLOBAL/SESSION scope the SET applies only to
        # the next transaction, which the block below immediately consumes,
        # so the read-only characteristic cannot leak onto the pooled
        # connection. (#89)
        result = nil
        conn.execute("SET TRANSACTION READ ONLY")
        conn.transaction do
          result = conn.select_all(bounded_sql)
          raise ActiveRecord::Rollback
        end
        result
      end

      # MariaDB and MySQL share the mysql2/trilogy adapters but bound a query
      # differently; the adapter answers `mariadb?` on Rails 7.1+, and the
      # server version string is the fallback.
      private_class_method def self.mariadb_server?(conn)
        return conn.mariadb? if conn.respond_to?(:mariadb?)

        conn.select_value("SELECT VERSION()").to_s.include?("MariaDB")
      rescue StandardError
        false
      end

      # sqlite3-ruby cannot interrupt a running statement, so a killable child runs it instead.
      private_class_method def self.execute_sqlite(conn, sql, timeout)
        if (path = sqlite_fork_path(conn))
          begin
            return execute_sqlite_in_child(conn, path, sql, timeout)
          rescue ActiveRecord::StatementInvalid => e
            raise unless e.message.match?(SQLITE_APP_CONNECTION_ONLY)
          end
        end

        result = nil
        begin
          conn.execute("PRAGMA query_only = ON")
          result = conn.select_all(sql)
        ensure
          conn.execute("PRAGMA query_only = OFF")
        end
        ResultProxy.new(result.columns, result.rows, true)
      end

      # Errors from state only the app's own connection has: registered functions,
      # virtual table modules, collations, an encryption key.
      SQLITE_APP_CONNECTION_ONLY = /no such (?:function|module|collation)|file is not a database/i

      # A row-capped result is far below this; a larger prefix is a corrupt one.
      SQLITE_MAX_RESULT_BYTES = 1 << 30

      private_class_method def self.read_before(reader, size, deadline)
        data = "".b
        while data.bytesize < size
          left = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          raise ActiveRecord::StatementInvalid, "SQLite query exceeded the statement timeout" unless left.positive? && IO.select([ reader ], nil, nil, left)

          chunk = reader.read_nonblock([ size - data.bytesize, 1 << 16 ].min, exception: false)
          raise ActiveRecord::StatementInvalid, "the SQLite query process exited without a result" if chunk.nil?

          data << chunk unless chunk == :wait_readable
        end
        data
      end

      # nil for an in-memory or temporary database, or where there is no fork.
      private_class_method def self.sqlite_fork_path(conn)
        return nil unless Process.respond_to?(:fork)

        path = conn.raw_connection.filename("main").to_s
        path unless path.empty?
      end

      private_class_method def self.execute_sqlite_in_child(conn, path, sql, timeout)
        parent = Process.pid
        extensions = Array(conn.pool.db_config.configuration_hash[:extensions]).map { |ext| (ext.is_a?(String) && ext.safe_constantize) || ext }
        # sqlite3 2.x warns in every child that inherits a writable handle; Rails 8 silences it the same way.
        SQLite3::ForkSafety.suppress_warnings! if defined?(SQLite3::ForkSafety)

        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
        reader, writer = IO.pipe.each(&:binmode)
        pid = fork { answer_in_child(reader, writer, path, sql, timeout, extensions) }
        writer.close
        read_child_result(reader, deadline)
      ensure
        # Also reached in a child whose fork hooks raised: it must not carry on as a second server.
        exit!(1) if parent && Process.pid != parent
        reader&.close
        writer&.close
        reap_child(pid) if pid
      end

      # Writes the length-prefixed result and exits without the parent's at_exit hooks.
      private_class_method def self.answer_in_child(reader, writer, path, sql, timeout, extensions)
        reader.close
        payload = begin
          db = SQLite3::Database.new(path, readonly: true, extensions: extensions)
          db.busy_timeout = (timeout * 1000).to_i
          stmt = db.prepare(sql)
          [ :ok, stmt.columns, stmt.to_a ]
        rescue => e
          [ :error, "#{e.class}: #{e.message}" ]
        end
        bytes = Marshal.dump(payload)
        writer.write([ bytes.bytesize ].pack("Q>"), bytes)
      ensure
        exit!(0)
      end

      # Read by length, not to EOF: any other process forked meanwhile holds a copy of the writer.
      private_class_method def self.read_child_result(reader, deadline)
        size = read_before(reader, 8, deadline).unpack1("Q>")
        status, *rest = begin
          raise ArgumentError, "result length out of range" if size > SQLITE_MAX_RESULT_BYTES

          Marshal.load(read_before(reader, size, deadline))
        rescue ArgumentError, TypeError
          raise ActiveRecord::StatementInvalid, "the SQLite query process exited without a result"
        end
        raise ActiveRecord::StatementInvalid, rest.first if status == :error

        ActiveRecord::Result.new(*rest)
      end

      # KILL: TERM cannot land while `step` holds the GVL, and would run inherited at_exit hooks.
      # Runs in an ensure, so it rescues everything: nothing here may replace the query's own error.
      private_class_method def self.reap_child(pid)
        Process.kill(:KILL, pid) rescue nil
        Process.wait(pid) rescue nil
      end

      private_class_method def self.unbounded_note(result)
        result.is_a?(ResultProxy) && result.unbounded ? UNBOUNDED_SQLITE_NOTE : ""
      end

      # Says, in every format, that the row cap held rows back, so a reader (or a
      # parser) is not told a partial answer is the whole one. For CSV it sits
      # after a blank line, outside the comma block.
      private_class_method def self.truncation_note(cap, format)
        detail = if cap >= HARD_ROW_CAP
          "the 1000-row hard cap"
        else
          "the row limit of #{cap}; pass limit: up to 1000 to see more"
        end
        note = "#{cap} rows shown; the query returned more (#{detail})."
        format == "csv" ? "\n\n#{note}" : "\n\n_#{note}_"
      end

      # ── Layer 1b: PostgreSQL semantic analysis ──────────────────────
      # Plans the query inside a read-only transaction with EXPLAIN (VERBOSE,
      # FORMAT JSON) - planning only, nothing runs, not even a VOLATILE admin
      # function (the planner does not fold one). Refuses three things the
      # textual layer cannot see: a whole-row reference (`alias.*`) to a relation
      # that has a sensitive column; a sensitive column used anywhere but as a
      # plain pass-through output (a ROW(tbl.*) the planner expanded, a WHERE
      # oracle); and any VOLATILE function outside the harmless allowlist.
      private_class_method def self.postgresql_plan_refusal(sql, timeout)
        return nil unless postgres_adapter?

        plan = pg_plan(sql, timeout)
        return nil unless plan

        nodes = []
        collect_plan_nodes(plan, nodes)
        aliases = plan_alias_map(nodes)
        exprs = plan_expressions(nodes)

        if (rel = whole_row_leak(exprs, aliases))
          return "Blocked: the query serialises a whole row of `#{rel}`, which carries every " \
            "column including the sensitive ones. Name the columns you need in the SELECT list."
        end
        if (col = sensitive_column_in_plan(exprs))
          return "Blocked: the query's plan uses the sensitive column `#{col}` (expanded from a " \
            "wildcard or a row reference). Name the non-sensitive columns you need; `#{col}` is " \
            "never returned."
        end
        # A sensitive column the plan reads as a plain pass-through but hides
        # behind an intermediate (a MATERIALIZED CTE, a subquery scan, a set
        # operation), so its value reaches a result column the top node does
        # not name. The top-Output redaction below cannot pin it, so refuse.
        if (col = laundered_sensitive_column(plan, nodes, aliases))
          return "Blocked: the query passes the sensitive column `#{col}` through a CTE, subquery " \
            "or set operation whose output the tool cannot map to a column, so it could leave " \
            "unredacted. Name the non-sensitive columns you need; `#{col}` is never returned."
        end
        if (fn = volatile_function_in_plan(exprs))
          return "Blocked: function #{fn} is VOLATILE (pg_proc.provolatile = 'v') and not on " \
            "rails_query's list of read-only VOLATILE functions, so it is not run. Some VOLATILE " \
            "functions change server or session state in ways a read-only transaction does not " \
            "stop; only those known to just read state (sizes, lock status, recovery and WAL " \
            "position, random values) are allowed."
        end
        nil
      rescue StandardError
        # Planning failed (syntax the executor will also reject, a permission
        # error): let normal execution raise the real error. The name blocklist
        # in validate_sql already stopped the known admin functions.
        nil
      end

      # The plan-vouch. On PostgreSQL a sensitive name that appears only inside a
      # string literal passed the textual check (masked), so the query may run
      # only if the plan was actually obtained - which means the plan layer above
      # read the query and raised nothing. If planning did not happen, the
      # literal masker is the only thing that let the name through, and it can be
      # fooled by a quote trick (standard_conforming_strings off, an E-string),
      # so the raw-text refusal stands.
      private_class_method def self.unvouched_literal_refusal(sql, postgres)
        return nil unless postgres

        offending = references_sensitive_column?(sql) or return nil
        # A real identifier (still there after masking) is validate_sql's to
        # refuse; reaching here with one would mean masking let it slip - refuse.
        return nil if references_sensitive_column?(mask_sql_literals(sql)).nil? &&
                      pg_plan(sql, config.query_timeout)

        "Blocked: query references sensitive column `#{offending}`. It is read as data " \
          "only when the query plan confirms it, and the plan could not be obtained, so the " \
          "query is refused. Name the columns you need; `#{offending}` is never returned."
      end

      # The query's JSON plan from EXPLAIN (VERBOSE) - run once per tool call,
      # shared by the refusal checks and the output-provenance redaction.
      private_class_method def self.pg_plan(sql, timeout)
        target = strip_leading_explain(sql)
        return nil unless target.match?(/\A\s*(SELECT|WITH)\b/i)

        RailsAiContext::RunCache.fetch([ :pg_plan, target ]) { explain_plan(target, timeout) }
      end

      # Run EXPLAIN in its own read-only transaction and parse the JSON plan.
      private_class_method def self.explain_plan(sql, timeout)
        conn = ActiveRecord::Base.connection
        json = nil
        conn.transaction do
          conn.execute("SET TRANSACTION READ ONLY")
          conn.execute("SET LOCAL statement_timeout = '#{(timeout * 1000).to_i}'")
          row = conn.select_all("EXPLAIN (VERBOSE, FORMAT JSON) #{sql}").rows.first
          json = row&.first
          raise ActiveRecord::Rollback
        end
        data = JSON.parse(json.to_s)
        data.is_a?(Array) ? data.first&.dig("Plan") : nil
      rescue ActiveRecord::StatementInvalid
        nil
      end

      # Result-column indices whose top-node Output expression is a plain Var of
      # a sensitive base column - a view/CTE/subquery that renamed the column, so
      # redaction by output name would miss it. The top Output is positional: its
      # i-th expression is result column i, with any trailing sort/group key past
      # the result width. PostgreSQL only; nothing here raising fails the query.
      private_class_method def self.plan_output_sensitive_indices(sql, result)
        return [] unless postgres_adapter?

        plan = pg_plan(sql, config.query_timeout)
        output = plan && plan["Output"]
        return [] unless output.is_a?(Array)

        nodes = []
        collect_plan_nodes(plan, nodes)
        aliases = plan_alias_map(nodes)
        width = result.columns.length
        (0...[ width, output.length ].min).select do |i|
          rel, col = base_var(output[i], aliases)
          rel && relation_has_sensitive_column?(rel, col)
        end
      rescue StandardError
        []
      end

      # A plain, qualified Var `rel.col` resolved to its base relation, or nil.
      # A quoted or spaced alias (a set-operation's "*SELECT* 1") never matches,
      # so only a real relation's column is read as a base Var.
      BASE_VAR = /\A"?([A-Za-z_]\w*)"?\.([A-Za-z_]\w*)\z/
      private_class_method def self.base_var(expr, aliases)
        m = expr.to_s.strip.match(BASE_VAR) or return nil
        rel = aliases[m[1].downcase]
        rel ? [ rel, m[2].downcase ] : nil
      end

      private_class_method def self.relation_has_sensitive_column?(relation, column)
        Array(relation_sensitive_columns[relation]).include?(column)
      end

      # The sensitive base column (if any) the plan reads as a plain pass-through
      # Var in some node but NOT in the top node's Output, so the top-Output
      # redaction cannot reach it. Returns the bare column name, or nil.
      private_class_method def self.laundered_sensitive_column(plan, nodes, aliases)
        top = sensitive_base_vars(Array(plan["Output"]), aliases)
        nodes.each do |node|
          sensitive_base_vars(Array(node["Output"]), aliases).each do |var|
            return var.split(".").last unless top.include?(var)
          end
        end
        nil
      end

      # The "rel.col" of each Output entry that is a plain Var of a sensitive
      # base column.
      private_class_method def self.sensitive_base_vars(output, aliases)
        output.filter_map do |expr|
          rel, col = base_var(expr, aliases)
          "#{rel}.#{col}" if rel && relation_has_sensitive_column?(rel, col)
        end.to_set
      end

      # Strip a leading EXPLAIN [ (opts) | ANALYZE | VERBOSE ... ] so the
      # semantic check reads the statement a raw EXPLAIN would run - an
      # EXPLAIN ANALYZE that would otherwise execute the body.
      private_class_method def self.strip_leading_explain(sql)
        sql.sub(/\A\s*EXPLAIN\s+(?:\([^)]*\)\s*|ANALYZE\s+|VERBOSE\s+)*/i, "")
      end

      private_class_method def self.collect_plan_nodes(node, acc)
        return unless node.is_a?(Hash)
        acc << node
        Array(node["Plans"]).each { |child| collect_plan_nodes(child, acc) }
      end

      # alias (downcased) => relation name (downcased). The alias defaults to the
      # relation name when the query gave none, which is how `users.*` resolves.
      private_class_method def self.plan_alias_map(nodes)
        map = {}
        nodes.each do |node|
          rel = node["Relation Name"]
          next unless rel
          name = (node["Alias"] || rel).to_s.downcase
          map[name] = rel.to_s.downcase
        end
        map
      end

      # Every expression string a node carries: the projected Output entries
      # kept apart (they may be plain pass-throughs) from the conditions, keys
      # and function calls, which never are.
      PLAN_COND_KEYS = [
        "Filter", "Index Cond", "Recheck Cond", "Hash Cond", "Merge Cond",
        "Join Filter", "One-Time Filter", "TID Cond", "Function Call",
        "Sort Key", "Group Key", "Presorted Key", "Order By", "Cache Key"
      ].freeze
      private_class_method def self.plan_expressions(nodes)
        outputs = []
        conds = []
        nodes.each do |node|
          outputs.concat(Array(node["Output"]).map { |e| mask_plan_literals(e) })
          PLAN_COND_KEYS.each { |k| conds.concat(Array(node[k]).map { |e| mask_plan_literals(e) }) }
        end
        { outputs: outputs, conds: conds, all: outputs + conds }
      end

      # A constant in a plan expression masked to an empty pair, so a sensitive
      # word inside one (`'%key%'::text` in a Filter, a `'...'` argument) is not
      # read as a column or a function name. PostgreSQL's deparser always doubles
      # quotes and never emits an E'' string, so this pattern matches a literal
      # exactly whatever standard_conforming_strings is; a double-quoted
      # identifier is never touched. The scanners (whole_row_leak,
      # sensitive_column_in_plan, volatile_function_in_plan) read the masked text.
      PLAN_LITERAL = /'(?:''|[^'])*'/
      private_class_method def self.mask_plan_literals(expr)
        expr.to_s.gsub(PLAN_LITERAL, "''")
      end

      # A whole-row `alias.*` reference to a relation that holds a sensitive
      # column. An unresolved alias is refused only when some relation in the
      # plan is sensitive, so a whole-row read of a non-sensitive table is fine.
      private_class_method def self.whole_row_leak(exprs, aliases)
        any_sensitive = aliases.values.any? { |rel| sensitive_relation?(rel) }
        exprs[:all].each do |expr|
          expr.to_s.scan(/([A-Za-z_]\w*)\.\*/) do |(al)|
            rel = aliases[al.downcase]
            return rel if rel && sensitive_relation?(rel)
            return (rel || al) if rel.nil? && any_sensitive
          end
        end
        nil
      end

      # A sensitive column name in the plan that is not a plain pass-through
      # output. The textual layer has already refused any query whose own text
      # names a sensitive column, so a name here came from a wildcard, a row
      # reference the planner expanded, or a view - never from a column the
      # caller asked for by name.
      private_class_method def self.sensitive_column_in_plan(exprs)
        sensitive = schema_sensitive_columns.to_a
        return nil if sensitive.empty?

        # Conditions and keys are never a pass-through: any sensitive name is a leak (or an oracle).
        exprs[:conds].each do |expr|
          sensitive.each { |col| return col if expr.to_s.downcase.match?(/\b#{Regexp.escape(col)}\b/) }
        end
        # An Output entry is allowed when it is exactly a bare column reference
        # (a plain SELECT * column, redacted later by name/provenance).
        exprs[:outputs].each do |expr|
          next if passthrough_output?(expr)
          sensitive.each { |col| return col if expr.to_s.downcase.match?(/\b#{Regexp.escape(col)}\b/) }
        end
        nil
      end

      PASSTHROUGH_OUTPUT = /\A\(?\s*(?:[A-Za-z_]\w*\.)?[A-Za-z_]\w*\s*\)?\z/
      private_class_method def self.passthrough_output?(expr)
        expr.to_s.match?(PASSTHROUGH_OUTPUT)
      end

      # A VOLATILE function (pg_proc.provolatile = 'v') named anywhere in the
      # plan, outside the harmless allowlist. This closes the admin-function
      # family - pg_terminate_backend, pg_advisory_lock, set_config and the rest -
      # without an ever-growing name list.
      private_class_method def self.volatile_function_in_plan(exprs)
        names = Set.new
        exprs[:all].each do |expr|
          expr.to_s.scan(/([A-Za-z_]\w*)\s*\(/) { |(fn)| names << fn.downcase }
        end
        names.subtract(PG_VOLATILE_ALLOWLIST)
        return nil if names.empty?

        conn = ActiveRecord::Base.connection
        quoted = names.map { |n| conn.quote(n) }.join(", ")
        volatile = conn.select_values(
          "SELECT DISTINCT lower(proname) FROM pg_proc " \
          "WHERE lower(proname) IN (#{quoted}) AND provolatile = 'v'"
        )
        volatile.first
      end

      private_class_method def self.sensitive_relation?(relation)
        relation_sensitive_columns.key?(relation.to_s.downcase)
      end

      # relation name (downcased) => its sensitive column names, for relations
      # that have at least one. Live connection first, cached context as a
      # fallback, memoised for the run.
      private_class_method def self.relation_sensitive_columns
        RailsAiContext::RunCache.fetch([ :query_relation_sensitive ]) do
          by_relation = relation_columns
          by_relation.each_with_object({}) do |(rel, cols), acc|
            flagged = cols.select { |c| sensitive_column?(c) }
            acc[rel] = flagged unless flagged.empty?
          end
        end
      end

      private_class_method def self.relation_columns
        from_connection_relation_columns || from_context_relation_columns || {}
      end

      private_class_method def self.from_connection_relation_columns
        conn = ActiveRecord::Base.connection
        conn.tables.each_with_object({}) do |t, acc|
          next if bookkeeping_table?(t)
          acc[t.to_s.downcase] = conn.columns(t).map { |c| c.name.to_s.downcase }
        end
      rescue StandardError
        nil
      end

      private_class_method def self.from_context_relation_columns
        tables = cached_context&.dig(:schema, :tables)
        return nil unless tables.is_a?(Hash)

        tables.each_with_object({}) do |(name, data), acc|
          next if bookkeeping_table?(name)
          cols = Array(data.is_a?(Hash) && data[:columns]).map do |col|
            (col.is_a?(Hash) ? col[:name] : col).to_s.downcase
          end
          acc[name.to_s.downcase] = cols
        end
      rescue StandardError
        nil
      end

      private_class_method def self.postgres_adapter?
        ActiveRecord::Base.connection.adapter_name.to_s.match?(POSTGRES_ADAPTER)
      rescue StandardError
        false
      end

      # Output columns whose provenance (PG::Result#ftable / #ftablecol) traces
      # to a sensitive base column, so a renamed sensitive column is redacted
      # whatever its output name. Describe-only (no execution); PostgreSQL only.
      private_class_method def self.provenance_sensitive_indices(sql)
        return [] unless postgres_adapter?

        conn = ActiveRecord::Base.connection
        raw = conn.raw_connection
        stmt = "rac_prov_#{Process.pid}_#{rand(1 << 30)}"
        begin
          raw.prepare(stmt, sql)
          desc = raw.describe_prepared(stmt)
        ensure
          raw.exec("DEALLOCATE #{stmt}") rescue nil
        end

        oid_columns = {}
        indices = []
        desc.nfields.times do |i|
          oid = desc.ftable(i)
          col = desc.ftablecol(i)
          next if oid.nil? || oid.to_i.zero? || col.to_i.zero?

          names = (oid_columns[oid] ||= attribute_names_for(conn, oid))
          name = names[col.to_i]
          indices << i if name && sensitive_column?(name)
        end
        indices
      rescue StandardError
        []
      end

      # attnum => column name for one relation oid.
      private_class_method def self.attribute_names_for(conn, oid)
        rows = conn.select_rows(
          "SELECT attnum, attname FROM pg_attribute " \
          "WHERE attrelid = #{oid.to_i} AND attnum > 0 AND NOT attisdropped"
        )
        rows.each_with_object({}) { |(num, name), acc| acc[num.to_i] = name.to_s }
      rescue StandardError
        {}
      end

      # ── EXPLAIN execution ────────────────────────────────────────────
      private_class_method def self.execute_explain(sql, timeout)
        unless sql.match?(/\A\s*(SELECT|WITH)\b/i)
          return text_response("EXPLAIN only supports SELECT queries.")
        end

        conn = ActiveRecord::Base.connection
        adapter = conn.adapter_name.downcase

        explain_sql, parser = case adapter
        when POSTGRES_ADAPTER
          [ "EXPLAIN (FORMAT JSON, ANALYZE) #{sql}", :parse_pg_explain ]
        when MYSQL_ADAPTER
          # MySQL 8.3+ and 9.x default explain_format to TREE, which
          # parse_mysql_explain can't read (it expects the classic
          # table/type/key/rows/Extra columns). Force TRADITIONAL explicitly
          # so parsing works regardless of the server's default.
          [ "EXPLAIN FORMAT=TRADITIONAL #{sql}", :parse_mysql_explain ]
        when /sqlite/
          [ "EXPLAIN QUERY PLAN #{sql}", :parse_sqlite_explain ]
        else
          [ "EXPLAIN #{sql}", :parse_generic_explain ]
        end

        result = run_guarded(conn, adapter, explain_sql, timeout)
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

        text_response(lines.join("\n") + unbounded_note(result))
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
          # Non-JSON EXPLAIN format - fall through to raw output
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
      # The query's own limit ends the statement. A LIMIT anywhere else belongs
      # to a subquery or a string literal and is left as written.
      TRAILING_LIMIT = /\bLIMIT\s+(?:(\d+)\s*,\s*)?(\d+)(\s+OFFSET\s+\d+)?\s*;?\s*\z/i
      TRAILING_FETCH = /\bFETCH\s+(FIRST|NEXT)\s+(\d+)(\s+ROWS?\s+ONLY)\s*;?\s*\z/i

      # The text asks for one row past the cap, so the answer can tell a result
      # that fit from one the cap cut (cap_rows drops the extra row). A query's
      # own smaller LIMIT is left as written: then nothing was held back.
      private_class_method def self.apply_row_limit(sql, limit)
        return sql if sql.match?(SCHEMA_METADATA_PREFIX)

        fetch = [ limit, HARD_ROW_CAP ].min + 1

        if sql.match?(TRAILING_LIMIT)
          sql.sub(TRAILING_LIMIT) { "LIMIT #{"#{$1}, " if $1}#{[ $2.to_i, fetch ].min}#{$3}" }
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
      # Redact a column by the one sensitivity rule applied to its OUTPUT name,
      # plus any index flagged by provenance (PostgreSQL maps the output column
      # to its base column, so a sensitive column reaches [FILTERED] whatever
      # name it was given). The name rule keeps the apps-only exemption via
      # sensitive_column?, which subtracts config.query_allowed_columns.
      private_class_method def self.redact_results(result, provenance_indices = [])
        columns = result.columns
        rows = result.rows

        # An `encrypts` column is filtered even when the app allows its name:
        # an encrypted-at-rest attribute is never meant to be read back raw.
        encrypted = encrypted_column_set

        redacted_indices = columns.each_index.select do |i|
          provenance_indices.include?(i) ||
            encrypted.include?(columns[i].to_s.downcase) ||
            sensitive_column?(columns[i])
        end

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

      # Quacks like ActiveRecord::Result for redacted output, for a SQLite query
      # that ran in-process with no time limit, or for a result the row cap cut.
      ResultProxy = Struct.new(:columns, :rows, :unbounded, :truncated)
      UNBOUNDED_SQLITE_NOTE = "\n\n_This SQLite query ran without a time limit: query_timeout needs a file-backed database, " \
        "a platform with fork, and nothing that only the app's own connection has._"
    end
  end
end
