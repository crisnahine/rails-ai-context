# frozen_string_literal: true

require "set"
require "strscan"

module RailsAiContext
  # Decides whether rails_query runs a statement: checks on its text, and on PostgreSQL on its plan.
  # The read-only transaction behind it is a second guard (ADR-0008).
  class SqlGate
    # sql: the comment-free text to run, or nil with the refusal. plan: the
    # PostgreSQL plan the checks read, for the result redaction to reuse.
    Verdict = Struct.new(:sql, :refusal, :plan) do
      def refused?
        !refusal.nil?
      end
    end

    # REPLACE is the MySQL statement; `replace(` is the string function every
    # database has, so a REPLACE followed by an opening parenthesis is let be.
    BLOCKED_KEYWORDS = /\b(INSERT|UPDATE|DELETE|DROP|ALTER|TRUNCATE|CREATE|GRANT|REVOKE|SET|COPY|MERGE|REPLACE(?!\s*\())\b/i
    # SHOW CREATE TABLE / VIEW print a definition; every other SHOW CREATE is
    # refused by the CREATE keyword - SHOW CREATE USER prints credential hashes.
    SHOW_CREATE_DEFINITION = /\A\s*SHOW\s+CREATE\s+(?:TABLE|VIEW)\b/i
    BLOCKED_CLAUSES  = /\bFOR\s+(?:UPDATE|SHARE|NO\s+KEY\s+UPDATE|KEY\s+SHARE)\b|\bLOCK\s+IN\s+SHARE\s+MODE\b/i
    BLOCKED_SHOWS    = /\bSHOW\s+(GRANTS|PROCESSLIST|BINLOG|SLAVE|MASTER|REPLICAS)\b/i
    SELECT_INTO      = /\bSELECT\b[^;]*\bINTO\b/i
    MULTI_STATEMENT  = /;\s*\S/
    ALLOWED_PREFIX   = /\A\s*(SELECT|WITH|SHOW|EXPLAIN|DESCRIBE|DESC)\b/i

    # SELECT-callable functions that reach files or the network through the database process.
    # To the database they are reads, so a read-only transaction lets them through.
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

    # PostgreSQL functions whose session or server effect outlives a read-only
    # transaction. The plan's VOLATILE check refuses the ones not named here.
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

    # GET_LOCK leaves a named lock on the pooled connection for a later caller to inherit, and the
    # pos_wait functions block on replication. MySQL has no volatility catalogue, so these are named.
    BLOCKED_MYSQL_SESSION = /\b(
      get_lock | release_lock | release_all_locks | is_free_lock | is_used_lock |
      master_pos_wait | source_pos_wait
    )\s*\(/ix

    # VOLATILE built-ins that only read: pg_proc marks a reader of live server
    # state VOLATILE too. Any other VOLATILE function in the plan is refused.
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

    # A column-alias list renames the columns a wildcard produced, past the redaction that reads names.
    # Bare identifiers only: a type modifier carries digits and a record function's list carries types.
    ALIAS_IDENT     = /[A-Za-z_]\w*/
    ALIAS_IDENT_LIST = /#{ALIAS_IDENT}(?:\s*,\s*#{ALIAS_IDENT})+/
    CTE_ALIAS_LIST = /#{ALIAS_IDENT}\s*\(\s*#{ALIAS_IDENT_LIST}\s*\)\s*AS\s*\(/i
    DERIVED_ALIAS_LIST = /\bAS\s+#{ALIAS_IDENT}\s*\(\s*#{ALIAS_IDENT_LIST}\s*\)/i
    TABLE_ALIAS_LIST = /\b(?:FROM|JOIN)\s+#{ALIAS_IDENT}(?:\.#{ALIAS_IDENT})?\s+#{ALIAS_IDENT}\s*\(\s*#{ALIAS_IDENT_LIST}\s*\)/i

    # A UNION names its columns after its first SELECT, so another table's rows leave under those names.
    # INTERSECT and EXCEPT return only rows of their first SELECT, so they stay.
    SET_UNION = /\bUNION\b/i

    QUOTED = /'[^']*'?|"[^"]*"?|`[^`]*`?/m
    # A backslash escapes the next character: every MySQL string, and a PostgreSQL E'...' one.
    ESCAPED_STRING = /'(?:\\.|[^'\\])*'?/m
    MYSQL_QUOTED = /#{ESCAPED_STRING}|"(?:\\.|[^"\\])*"?|`[^`]*`?/m
    DOLLAR_QUOTED = /(?<![\p{Word}$])\$(\p{Word}*)\$.*?\$\1\$/m
    UNQUOTED = /[^'"`$\/\-#*]+/

    # PostgreSQL string literals, matched so they can be emptied. A double-quoted identifier is
    # matched so it is skipped whole: a quote inside one (`AS "a'b"`) would open a literal.
    PG_TEXT_LITERAL = /
      (?<ident>"(?:""|[^"])*")
      | \$(?<tag>(?:[A-Za-z_]\w*)?)\$.*?\$\k<tag>\$
      | [eE]'(?:\\.|''|[^'])*'
      | (?:[uU]&|[bBxX])?'(?:''|[^'])*'
    /mx

    # A constant in a plan expression. PostgreSQL's deparser always doubles
    # quotes and never emits an E'' string, so this matches one exactly.
    PLAN_LITERAL = /'(?:''|[^'])*'/

    # Conditions and keys, which are never a plain pass-through of a column.
    PLAN_COND_KEYS = [
      "Filter", "Index Cond", "Recheck Cond", "Hash Cond", "Merge Cond",
      "Join Filter", "One-Time Filter", "TID Cond", "Function Call",
      "Sort Key", "Group Key", "Presorted Key", "Order By", "Cache Key"
    ].freeze

    PASSTHROUGH_OUTPUT = /\A\(?\s*(?:[A-Za-z_]\w*\.)?[A-Za-z_]\w*\s*\)?\z/

    # SHOW reads a setting and PostgreSQL has no DESCRIBE, so these have no plan.
    # Every other statement is planned, as is whatever a leading EXPLAIN would run.
    NO_PLAN = /\A\s*(?:SHOW|DESCRIBE|DESC)\b/i
    EXPLAIN_PREFIX = /\A\s*EXPLAIN\s+(?:\([^)]*\)\s*)?(?:ANALYZE\s+)?(?:VERBOSE\s+)?/i

    # family decides the lexing and whether the plan checks run. timeout is the seconds every read
    # the gate sends has between them: the plan and the pg_proc lookup.
    def initialize(family:, secrets:, connection:, timeout:)
      @mysql = family.mysql?
      @postgres = family.postgresql?
      @family = family
      @secrets = secrets
      @connection = connection
      @deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    end

    # @return [Verdict]
    def check(sql)
      return refuse("SQL query is required.") if sql.nil? || sql.strip.empty?

      if (refusal = text_refusal(sql))
        return refuse(refusal)
      end

      text = comment_free(sql)
      planned = @postgres && !text.match?(NO_PLAN)
      plan = @family.plan(@connection, text.sub(EXPLAIN_PREFIX, ""), timeout: time_left) if planned
      if planned && plan.nil?
        return refuse("Blocked: the query is not run because its plan could not be read. On PostgreSQL " \
          "the plan shows which columns a query returns, so no query runs without one.")
      end

      refusal = plan_refusal(plan) || unvouched_literal_refusal(text, plan)
      refusal ? refuse(refusal) : Verdict.new(text, nil, plan)
    end

    private

    def refuse(reason)
      Verdict.new(nil, reason, nil)
    end

    def text_refusal(sql)
      # Read on the raw text too, in case a novel comment form defeats the stripping.
      if (m = sql.match(BLOCKED_FUNCTIONS))
        return "Blocked: dangerous function #{m[0]} (filesystem/network primitive)"
      end

      cleaned = comment_free(sql).squeeze(" ")
      # Statement checks read quote-masked text, so `LIKE '%update%'` is data. A disk write and the
      # file functions stay on the raw text: no read-only transaction stops them.
      masked = mask_quoted(cleaned)
      return "Blocked: multiple statements (no semicolons)" if masked.match?(MULTI_STATEMENT)
      # PostgreSQL's read-only transaction refuses a locking read, so a literal there is data.
      # MySQL's runs FOR SHARE and LOCK IN SHARE MODE, so there the raw text decides.
      return "Blocked: locking read (FOR UPDATE/SHARE or LOCK IN SHARE MODE clause)" if (@postgres ? masked : cleaned).match?(BLOCKED_CLAUSES)
      return "Blocked: sensitive SHOW command" if cleaned.match?(BLOCKED_SHOWS)
      return "Blocked: SELECT INTO OUTFILE / DUMPFILE writes to disk" if cleaned.match?(BLOCKED_OUTPUT)
      return "Blocked: SELECT INTO creates a table" if masked.match?(SELECT_INTO)

      if (m = cleaned.match(BLOCKED_FUNCTIONS))
        return "Blocked: dangerous function #{m[0]} (filesystem/network primitive)"
      end
      if (m = cleaned.match(BLOCKED_PG_ADMIN))
        return "Blocked: administrative function #{m[0].sub(/\s*\(\z/, "")} has a session or server-wide " \
          "effect that a read-only transaction does not prevent. rails_query runs " \
          "read-only queries for inspection; it will not run server-control functions."
      end
      if (m = cleaned.match(BLOCKED_MYSQL_SESSION))
        return "Blocked: session function #{m[0].sub(/\s*\(\z/, "")} leaves state (a named lock) on the pooled " \
          "connection after the query returns. rails_query will not run it."
      end

      if renaming_alias_list?(cleaned, masked)
        return "Blocked: a column-alias list (e.g. `t(a, b, c)`) renames the columns a " \
          "wildcard returns, so sensitive columns would leave under harmless names. " \
          "Name the columns you want in the SELECT list instead."
      end

      # On PostgreSQL a literal is data, since the plan checks read the query itself. MySQL's quote
      # modes and SQLite's t.'col' identifiers could fool a masker, so there the raw text decides.
      literal_free = @postgres ? mask_sql_literals(cleaned) : cleaned

      if literal_free.match?(SET_UNION)
        return "Blocked: UNION is not run. A UNION takes its column names from its first SELECT, " \
          "so rows of another table would come out under those names, past the redaction that " \
          "reads them. Query each table on its own; a recursive CTE needs UNION, so it is not run either."
      end

      if (m = masked.sub(SHOW_CREATE_DEFINITION, "SHOW").match(BLOCKED_KEYWORDS))
        return "Blocked: contains #{m[0]}"
      end

      return "Only SELECT, WITH, SHOW, EXPLAIN, DESCRIBE allowed" unless cleaned.match?(ALLOWED_PREFIX)

      if (offending = @secrets.named_in(literal_free))
        return secret_column_refusal(offending)
      end

      # A definition is schema text, so SHOW CREATE VIEW still shows which tables a refused view reads.
      view, why = @secrets.refused_view_in(literal_free) unless cleaned.match?(SHOW_CREATE_DEFINITION)
      return nil unless view

      "Blocked: the view `#{view}` is not queried: #{why}. A view can rename a column past the redaction " \
        "on #{@family.name}, so query the tables it reads."
    end

    # An alias or an expression renames a column past the redaction that
    # reads output names, so a statement naming a secret column is refused whole.
    def secret_column_refusal(offending)
      source = @secrets.generated_from(offending)
      reads = "`#{offending}` is a generated column that reads `#{source}`" if source
      way_out = if @secrets.encrypted?(offending)
        if source
          "#{reads}, an `encrypts` value, so config.query_allowed_columns does not release it."
        else
          "A model declares `#{offending}` with `encrypts`, so config.query_allowed_columns does not release it."
        end
      else
        "#{"#{reads}. " if source}If `#{offending}` is not sensitive in your app, add \"#{offending}\" to " \
          "config.query_allowed_columns in an initializer."
      end
      "Blocked: query references sensitive column `#{offending}`. " \
        "Name the columns you need; `#{offending}` is sensitive and never " \
        "returned, and an alias or expression over it cannot be redacted after " \
        "the query runs, so the whole query is refused. #{way_out}"
    end

    # The text that runs: comments out, a quoted span copied whole. Only MySQL has a hash comment,
    # a `--` that needs a space after it and `/*! ... */` content it runs; PostgreSQL has dollar quoting.
    def comment_free(sql)
      # fixed_anchor, so the dollar quote's lookbehind sees the text before the pointer.
      scanner = StringScanner.new(sql, fixed_anchor: true)
      line_comment = @mysql ? /--(?=\s|\z)[^\n]*|#[^\n]*/ : /--[^\n]*/
      out = +""
      executable = false

      until scanner.eos?
        if (span = scanner.scan(quoted_at(out, scanner)) || (!@mysql && scanner.scan(DOLLAR_QUOTED)) || scanner.scan(UNQUOTED))
          out << span
        elsif @mysql && scanner.scan(/\/\*!\d*/)
          # Its content stays for the checks to read: `SELECT /*!50000 LOAD_FILE(...) */`.
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

    # Every quoted and dollar-quoted span blanked to spaces of the same
    # length, so a check reads structure only and positions still line up.
    def mask_quoted(text)
      scanner = StringScanner.new(text, fixed_anchor: true)
      out = +""

      until scanner.eos?
        if (span = scanner.scan(quoted_at(out, scanner)) || (!@mysql && scanner.scan(DOLLAR_QUOTED)))
          out << (" " * span.length)
        elsif (span = scanner.scan(UNQUOTED))
          out << span
        else
          out << scanner.getch
        end
      end

      out
    end

    def quoted_at(out, scanner)
      if @mysql then MYSQL_QUOTED
      elsif out.match?(/(?<![\p{Word}$])[eE]\z/) && scanner.check(/'/) then ESCAPED_STRING
      else QUOTED
      end
    end

    def mask_sql_literals(text)
      text.gsub(PG_TEXT_LITERAL) { Regexp.last_match[:ident] || "''" }
    end

    # A list on a VALUES body renames no table column, so it is left alone. Parentheses are
    # balanced on the masked text, where one inside a literal cannot move a body's bounds.
    def renaming_alias_list?(cleaned, masked)
      return true if cleaned.match?(TABLE_ALIAS_LIST)

      cleaned.scan(CTE_ALIAS_LIST) do
        return true unless values_body_at?(masked, Regexp.last_match.end(0))
      end
      cleaned.scan(DERIVED_ALIAS_LIST) do
        open = derived_table_open(masked, Regexp.last_match.begin(0))
        return true unless open && values_body_at?(masked, open + 1)
      end
      false
    end

    def values_body_at?(masked, position)
      masked[position..].to_s.match?(/\A\s*VALUES\b/i)
    end

    # The index of the "(" that opens the parenthesised FROM item ending just
    # before `as_position`, or nil when no ")" stands there.
    def derived_table_open(masked, as_position)
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

    def plan_refusal(top)
      return nil unless top

      plan = DatabaseFamily::PostgresqlPlan.new(top)
      outputs = []
      conds = []
      plan.nodes.each do |node|
        outputs.concat(Array(node["Output"]).map { |e| e.to_s.gsub(PLAN_LITERAL, "''") })
        PLAN_COND_KEYS.each { |k| conds.concat(Array(node[k]).map { |e| e.to_s.gsub(PLAN_LITERAL, "''") }) }
      end

      if (rel = whole_row_leak(outputs + conds, plan.aliases))
        return "Blocked: the query serialises a whole row of `#{rel}`, which carries every " \
          "column including the sensitive ones. Name the columns you need in the SELECT list."
      end
      if (col = secret_column_in_plan(outputs, conds))
        return "Blocked: the query's plan uses the sensitive column `#{col}` (expanded from a " \
          "wildcard or a row reference). Name the non-sensitive columns you need; `#{col}` is " \
          "never returned."
      end
      if (col = laundered_secret_column(plan))
        return "Blocked: the query passes the sensitive column `#{col}` through a CTE, subquery " \
          "or set operation whose output the tool cannot map to a column, so it could leave " \
          "unredacted. Name the non-sensitive columns you need; `#{col}` is never returned."
      end
      if (fn = volatile_function(outputs + conds))
        "Blocked: function #{fn} is VOLATILE (pg_proc.provolatile = 'v') and not on " \
          "rails_query's list of read-only VOLATILE functions, so it is not run. Some VOLATILE " \
          "functions change server or session state in ways a read-only transaction does not " \
          "stop; only those known to just read state (sizes, lock status, recovery and WAL " \
          "position, random values) are allowed."
      end
    end

    # A secret name the text check passed as a literal runs only when a plan cleared the checks,
    # so the plan backs a masker that a quote trick fooled.
    def unvouched_literal_refusal(text, plan)
      return nil unless @postgres

      offending = @secrets.named_in(text) or return nil
      return nil if plan && @secrets.named_in(mask_sql_literals(text)).nil?

      "Blocked: query references sensitive column `#{offending}`. It is read as data " \
        "only when the query plan confirms it, and the plan could not be obtained, so the " \
        "query is refused. Name the columns you need; `#{offending}` is never returned."
    end

    # A whole-row `alias.*` of a relation with a secret column. An alias the
    # plan does not resolve is refused when any relation in it is secret.
    def whole_row_leak(exprs, aliases)
      any_secret = aliases.values.any? { |rel| @secrets.relation_secret?(rel) }
      exprs.each do |expr|
        expr.scan(/([A-Za-z_]\w*)\.\*/) do |(al)|
          rel = aliases[al.downcase]
          return rel if rel && @secrets.relation_secret?(rel)
          return (rel || al) if rel.nil? && any_secret
        end
      end
      nil
    end

    # A secret column anywhere but a plain pass-through output. The text check refused any statement
    # naming one, so a name here came from a wildcard, an expanded row reference or a view.
    def secret_column_in_plan(outputs, conds)
      secret = @secrets.in_schema
      return nil if secret.empty?

      named = ->(expr) { secret.find { |col| expr.downcase.match?(/\b#{Regexp.escape(col)}\b/) } }
      conds.each { |expr| (col = named.call(expr)) and return col }
      outputs.each do |expr|
        next if expr.match?(PASSTHROUGH_OUTPUT)

        (col = named.call(expr)) and return col
      end
      nil
    end

    # A secret base column some node passes through and the top node leaves unnamed (a MATERIALIZED
    # CTE, a subquery scan, a set operation), where redaction by position cannot pin it.
    def laundered_secret_column(plan)
      top = secret_base_columns(plan, plan.output)
      plan.nodes.each do |node|
        secret_base_columns(plan, Array(node["Output"])).each do |var|
          return var.last unless top.include?(var)
        end
      end
      nil
    end

    def secret_base_columns(plan, output)
      output.filter_map do |expr|
        rel, col = plan.base_column(expr)
        [ rel, col ] if rel && @secrets.of_relation(rel).include?(col)
      end.to_set
    end

    def volatile_function(exprs)
      names = Set.new
      exprs.each { |expr| expr.scan(/([A-Za-z_]\w*)\s*\(/) { |(fn)| names << fn.downcase } }
      names.subtract(PG_VOLATILE_ALLOWLIST)
      return nil if names.empty?

      quoted = names.map { |n| @connection.quote(n) }.join(", ")
      @family.bounded(@connection, timeout: time_left) do
        @connection.select_values(
          "SELECT DISTINCT lower(proname) FROM pg_proc WHERE lower(proname) IN (#{quoted}) AND provolatile = 'v'"
        ).first
      end
    end

    def time_left
      left = @deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
      raise DatabaseFamily::TimedOut, "the reads before the statement used the whole timeout" unless left.positive?

      left
    end
  end
end
