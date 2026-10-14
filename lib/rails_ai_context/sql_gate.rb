# frozen_string_literal: true

require "set"
require "strscan"
require "timeout"

module RailsAiContext
  # Decides whether rails_query runs a statement: checks on its text, and on PostgreSQL on its plan.
  # The read-only transaction behind it is a second guard (ADR-0008).
  class SqlGate
    # sql: the comment-free text to run, or nil with the refusal. plan: the
    # PostgreSQL plan the checks read, for the result redaction to reuse.
    Verdict = Data.define(:sql, :refusal, :plan) do
      def refused?
        !refusal.nil?
      end
    end

    # The seconds a group of reads has between them. Each read is charged the time it took itself.
    class Budget
      def initialize(seconds)
        @left = seconds
      end

      def spent?
        !@left.positive?
      end

      # Runs the block with the seconds left.
      # @raise [DatabaseFamily::TimedOut] when earlier reads used them all
      def spend
        raise DatabaseFamily::TimedOut, "the reads beside the statement used the whole timeout" if spent?

        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        yield @left
      ensure
        @left -= Process.clock_gettime(Process::CLOCK_MONOTONIC) - started if started
      end
    end

    # The longest statement written by hand is far under it: 100,000 ids in an IN list are 700 KB. The checks on a
    # statement's text have text_timeout seconds to read one.
    MAX_BYTES = 1_000_000

    # The text checks ran past the time they have.
    class TextChecksTimedOut < RailsAiContext::Error; end

    # @return [String, nil] the refusal of a call that holds no statement
    def self.blank_refusal(sql)
      "SQL query is required." if sql.to_s.strip.empty?
    end

    # @return [String, nil] the refusal of a statement longer than the checks read
    def self.length_refusal(sql)
      return nil unless sql.to_s.bytesize > MAX_BYTES

      "Blocked: the statement is #{sql.bytesize} bytes long, and rails_query checks a statement of #{MAX_BYTES} bytes at most."
    end

    # REPLACE is the MySQL statement; `replace(` is the string function every
    # database has, so a REPLACE followed by an opening parenthesis is let be.
    BLOCKED_KEYWORDS = /\b(INSERT|UPDATE|DELETE|DROP|ALTER|TRUNCATE|CREATE|GRANT|REVOKE|SET|COPY|MERGE|REPLACE(?!\s*\())\b/i
    # SHOW CREATE TABLE / VIEW print a definition; every other SHOW CREATE is
    # refused by the CREATE keyword - SHOW CREATE USER prints credential hashes.
    SHOW_CREATE_DEFINITION = /\A\s*SHOW\s+CREATE\s+(?:TABLE|VIEW)\b/i
    BLOCKED_CLAUSES  = /\bFOR\s+(?:UPDATE|SHARE|NO\s+KEY\s+UPDATE|KEY\s+SHARE)\b|\bLOCK\s+IN\s+SHARE\s+MODE\b/i
    # A list keyed by family holds each name under the family that has it, so a name is refused where it can be read.

    # Other sessions' statements, replication hosts and users, and the row data a log holds.
    BLOCKED_SHOWS = { mysql: /\bSHOW\s+(?:(?:FULL|ALL)\s+)?(?:GRANTS|PROCESSLIST|BINLOG|BINARY|RELAYLOG|SLAVES?|MASTER|REPLICAS?|ENGINE|
      PROFILES?|OPEN\s+TABLES|EXPLAIN|ANALYZE|USER_STATISTICS|CLIENT_STATISTICS|WSREP_\w+)\b/ix }.freeze
    # The plan of the statement another session is running.
    CONNECTION_PLAN = { mysql: /\A\s*(?:EXPLAIN|DESCRIBE|DESC)\b.*\bFOR\s+CONNECTION\b/mi }.freeze
    # A SHOW filter runs an expression for each row, and MySQL's statement timeout holds SELECT only.
    SHOW_WHERE       = /\A\s*SHOW\b.*\bWHERE\b/mi
    MULTI_STATEMENT  = /;\s*\S/
    ALLOWED_PREFIX   = /\A\s*(SELECT|WITH|SHOW|EXPLAIN|DESCRIBE|DESC)\b/i

    # SELECT-callable functions that reach files or the network through the database process.
    # To the database they are reads, so a read-only transaction lets them through.
    BLOCKED_FUNCTIONS = {
      postgresql: /\b(
        pg_read_binary_file | pg_read_file |
        pg_ls_dir | pg_ls_logdir | pg_ls_tmpdir | pg_ls_waldir | pg_ls_archive_statusdir |
        pg_stat_file | pg_current_logfile |
        lo_import | lo_export |
        dblink[a-z_]*
      )\b/ix,
      mysql: /\b(LOAD\s+DATA | load_file)\b/ix,
      sqlite: /\b(load_extension)\b/i
    }.freeze

    # PostgreSQL functions that return a whole table as one value, its secret columns included.
    BLOCKED_DUMPS = { postgresql: /\b((?:query|table|schema|database|cursor)_to_xml(?:schema|_and_xmlschema)?)\s*\(/i }.freeze

    # Relations that hold values sampled from other tables' columns, other sessions' statements or stored
    # credentials, where no check on a column's name applies.
    BLOCKED_RELATIONS = {
      postgresql: /\b(
        pg_stats(?:_ext(?:_exprs)?)? | pg_statistic(?:_ext(?:_data)?)? | pg_largeobject |
        pg_stat_activity | pg_stat_get_activity | pg_stat_get_backend_activity |
        pg_stat_statements | pg_prepared_statements | pg_cursors |
        pg_user_mappings? | user_mapping_options | pg_subscription |
        pg_foreign_server | pg_foreign_data_wrapper | pg_foreign_table |
        pg_settings | pg_file_settings | pg_show_all_settings | pg_show_all_file_settings | pg_hba_file_rules | pg_ident_file_mappings
      )\b/ix,
      mysql: /\b(?:(column_statistics | column_stats | global_priv | processlist | performance_schema | general_log | slow_log)\b|
        information_schema[`"]?\s*\.\s*[`"]?(innodb_trx | innodb_lock\w* | innodb_ft_\w+ |
          user_statistics | client_statistics | profiling | optimizer_trace)\b)/ix,
      sqlite: /\b(sqlite_stat[134] | sqlite_stmt)\b/ix
    }.freeze

    # MySQL's own schemas, read with string literals masked. An alias cannot be told from a schema without a
    # parser, so an alias of either name is refused with them.
    SYSTEM_SCHEMAS = { mysql: /\b(sys|mysql)[`"]?\s*\./i }.freeze

    # The SQLite pragma functions that describe the schema or the database file. Every other one, and the
    # counters under it, answer for the connection that runs the statement, which is rails_query's own.
    SQLITE_FILE_PRAGMAS = %w[
      table_info table_xinfo table_list index_list index_info index_xinfo foreign_key_list foreign_key_check
      integrity_check quick_check user_version application_id schema_version page_size page_count freelist_count
      encoding auto_vacuum journal_mode compile_options pragma_list
    ].to_set.freeze
    SQLITE_COUNTER_CALL = /\b(changes|total_changes|last_insert_rowid)\s*\(/i
    # A pragma function's name, bare or quoted, as one token.
    SQLITE_PRAGMA_NAME = /\A["'`\[]?pragma_(\w+)["'`\]]?\z/i
    # The clauses after which a comma at the same depth starts another table of a FROM list.
    FROM_LIST_CLAUSES = %w[from join on].freeze
    CLAUSE_WORDS = %w[select from join on where group order having limit window values using returning set union intersect except].freeze

    # Catalogs refused when a statement names them. A view over one runs, and the plan checks hold the
    # column that carries the credential (SecretColumns::CATALOG_CREDENTIALS) as a secret column.
    BLOCKED_CATALOGS = { postgresql: /\b(#{(SecretColumns::CATALOG_CREDENTIALS.keys + %w[pg_shadow]).join("|")})\b/i }.freeze

    # PostgreSQL settings whose value can be a connection string with its password, or a command line.
    SECRET_SETTINGS = /\b(primary_conninfo|ssl_passphrase_command|archive_command|restore_command|archive_cleanup_command|recovery_end_command)\b/i
    # A call is matched with the name it reads when that name is one plain string, and with none otherwise.
    SETTING_CALL = /\bcurrent_setting\s*\((?:\s*'([^'\\]*)'\s*(?=[,)]))?/i
    PLAN_SETTING_CALL = /\bcurrent_setting\((?:'((?:''|[^'])*)'::text(?=[,)]))?/
    SHOWN_SETTING = /\A\s*SHOW\b(.*?);?\s*\z/mi

    # Checked before the SELECT INTO check, which also matches, so the refusal names the disk write.
    BLOCKED_OUTPUT = /\bINTO\s+(OUTFILE|DUMPFILE)\b/i

    # PostgreSQL functions whose session or server effect outlives a read-only
    # transaction. The plan's VOLATILE check refuses the ones not named here.
    BLOCKED_ADMIN = { postgresql: /\b(
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
    )\s*\(/ix }.freeze

    # GET_LOCK leaves a named lock on the pooled connection for a later caller to inherit, and the
    # pos_wait functions block on replication. MySQL has no volatility catalogue, so these are named.
    BLOCKED_SESSION = { mysql: /\b(
      get_lock | release_lock | release_all_locks | is_free_lock | is_used_lock |
      master_pos_wait | source_pos_wait
    )\s*\(/ix }.freeze

    # A value either one sets stays on the pooled connection, in or out of a read-only transaction.
    VARIABLE_ASSIGNMENT = { mysql: /:=/ }.freeze
    SETS_LAST_INSERT_ID = { mysql: /\blast_insert_id\s*\(\s*[^\s)]/i }.freeze

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
      pg_sequence_last_value
    ].freeze

    # Any character past ASCII is an identifier character to SQLite and MySQL, a no-break space included.
    BARE_WORD = /(?:[\p{Word}$]|[^\x00-\x7F])+/
    NUMBER = /\A(?:\d+(?:e\d+)?|0x\h+|0b[01]+)\z/i
    # Words a parenthesis can follow that name no table and no alias. MySQL, whose derived table
    # takes a bare alias and a column list, reserves each one, so none can stand for an alias there.
    NO_ALIAS = %w[
      AND AS BETWEEN CROSS DIV ELSE EXCEPT FOR FROM GROUP HAVING IN INNER INTERSECT INTO IS JOIN LATERAL LEFT LIKE LIMIT
      MOD NATURAL NOT ON OR ORDER PARTITION REGEXP RIGHT RLIKE STRAIGHT_JOIN THEN UNION USING WHEN WHERE XOR
    ].to_set.freeze
    SUBQUERY_START = %w[SELECT WITH VALUES TABLE].freeze
    # What a VALUES body may not hold if its column-alias list is to rename constants only.
    ROW_SOURCES = %w[SELECT TABLE WITH UNION EXCEPT INTERSECT].freeze

    IN_SHORTHAND = "`x IN t` is SQLite's shorthand for `x IN (SELECT * FROM t)`, and a value read through such a wildcard can be " \
      "compared past the redaction, so write the subquery with its columns named."

    # A UNION names its columns after its first SELECT, so another table's rows leave under those names.
    # INTERSECT and EXCEPT return only rows of their first SELECT, so they stay.
    SET_UNION = /\bUNION\b/i

    # A quoted span by the quote that opens it. A doubled quote stays inside the span.
    PLAIN_SPAN = { "'" => /'(?:''|[^'])*'?/m, '"' => /"(?:""|[^"])*"?/m, "`" => /`(?:``|[^`])*`?/m }.freeze
    # A backslash escapes the next character: every MySQL string, and a PostgreSQL E'...' one.
    ESCAPED_SPAN = { "'" => /'(?:\\.|''|[^'\\])*'?/m, '"' => /"(?:\\.|""|[^"\\])*"?/m }.freeze
    # The quote of an E'...' string: the E stands right before it, as a word of its own.
    E_QUOTE = /(?<=(?<![\p{Word}$]|[^\x00-\x7F])[eE])'/
    # SQLite reads [name] as an identifier.
    BRACKETED = /\[[^\]\n]*\]/
    DOLLAR_QUOTED = /(?<![\p{Word}$])\$(\p{Word}*)\$.*?\$\1\$/m
    DOLLAR_TAG = /(?<![\p{Word}$])\$\p{Word}*\$/
    UNQUOTED = /[^'"`$\/\-#*\[]+/

    # A constant in a plan expression. PostgreSQL's deparser always doubles
    # quotes and never emits an E'' string, so this matches one exactly.
    PLAN_LITERAL = /'(?:''|[^'])*'/

    # Conditions and keys, which are never a plain pass-through of a column.
    PLAN_COND_KEYS = [
      "Filter", "Index Cond", "Recheck Cond", "Hash Cond", "Merge Cond",
      "Join Filter", "One-Time Filter", "TID Cond", "Function Call",
      "Sort Key", "Group Key", "Presorted Key", "Order By", "Cache Key"
    ].freeze

    PLAN_IDENT = /(?:[A-Za-z_]\w*|"(?:""|[^"])*")/
    PASSTHROUGH_OUTPUT = /\A\(?\s*(?:#{PLAN_IDENT}\.)?#{PLAN_IDENT}\s*\)?\z/

    # SHOW reads a setting and PostgreSQL has no DESCRIBE, so these have no plan.
    # Every other statement is planned, as is whatever a leading EXPLAIN would run.
    NO_PLAN = /\A\s*(?:SHOW|DESCRIBE|DESC)\b/i
    EXPLAIN_PREFIX = /\A\s*EXPLAIN\s+(?:\([^)]*\)\s*)?(?:ANALYZE\s+)?(?:VERBOSE\s+)?/i
    # A generic plan leaves $1 unbound, so the statement under it is planned only with the option.
    GENERIC_PLAN = /\A\s*EXPLAIN\s*\([^)]*\bGENERIC_PLAN(?:\s+(true|on|1))?\s*[,)]/i
    # The handler a sampling method names is never called by the statement, and the plan prints its arguments.
    SAMPLING_METHOD = /\bTABLESAMPLE\s+(?:\w+\s*\.\s*)?\w+(?=\s*\()/i

    # A statement's text under a pointer. A lookbehind sees the text before the pointer, and where each dollar
    # tag last stands is read in one pass: a search for its closer from every opener is quadratic.
    class Scanner < StringScanner
      def initialize(text)
        super(text, fixed_anchor: true)
      end

      # The [name] at the pointer. A line with no closing bracket is read once, however many brackets open on it.
      def bracketed
        return nil if @unclosed_to && pos < @unclosed_to

        span = scan(BRACKETED)
        @unclosed_to = pos + check(/[^\]\n]*/).bytesize unless span
        span
      end

      # Whether the dollar tag at the pointer stands again after itself, to close the quote it opens.
      def closed?(tag)
        @last ||= {}.tap do |last|
          tags = StringScanner.new(string)
          last["$#{tags[1]}"] = tags.pos - 1 while tags.skip_until(/\$(?=(\p{Word}*\$))/)
        end
        @last.fetch(tag, -1) >= pos + tag.bytesize
      end
    end

    # budget: the seconds the reads the gate sends (the plan, the catalog lookups) share with the caller's other reads.
    # text_timeout: the seconds the checks on the statement's text have to themselves.
    def initialize(family:, secrets:, connection:, budget:, text_timeout: RailsAiContext.configuration.query_timeout)
      @text_timeout = text_timeout
      @family = family
      @secrets = secrets
      @connection = connection
      @budget = budget
      @backslash = family.backslash_escapes?
    end

    def check(sql)
      if (refusal = self.class.blank_refusal(sql) || self.class.length_refusal(sql))
        return refuse(refusal)
      end

      text, refusal = text_verdict(sql)
      return refuse(refusal) if refusal
      planned = @family.plan_checks? && !text.match?(NO_PLAN)
      if planned
        plan = @budget.spend { |left| @family.plan(@connection, text.sub(EXPLAIN_PREFIX, ""), timeout: left, generic: text.match?(GENERIC_PLAN)) }
      end
      if planned && plan.nil?
        return refuse("Blocked: the query is not run because its plan could not be read. On PostgreSQL " \
          "the plan shows which columns a query returns, so no query runs without one.")
      end

      refusal = plan_refusal(plan, text) || unvouched_literal_refusal(text, plan)
      refusal ? refuse(refusal) : Verdict.new(sql: text, refusal: nil, plan: plan)
    end

    # The text with its comments out and every quoted span copied whole, as the family reads them.
    def self.comment_free(sql, family, backslash: family.backslash_escapes?)
      scanner = Scanner.new(sql)
      out = +""
      executable = false

      until scanner.eos?
        if (span = quoted(scanner, family, backslash: backslash)&.last || scanner.scan(UNQUOTED))
          out << span
        elsif family.executable_comments? && scanner.scan(/\/\*!\d*/)
          # Its content stays for the checks to read: `SELECT /*!50000 LOAD_FILE(...) */`.
          executable = true
          out << " "
        elsif executable && scanner.scan(/\*\//)
          executable = false
          out << " "
        elsif comment(scanner, family)
          out << " "
        else
          out << scanner.getch
        end
      end

      out.strip
    end

    # The quoted span that opens where the scanner stands, as the family reads it: [:string or :quoted, the span], or nil.
    # brackets: whether [name] quotes a name in this text. backslash: whether one escapes the next character of a string.
    def self.quoted(scanner, family, brackets: family.sqlite?, backslash: family.backslash_escapes?)
      case scanner.peek(1)
      when "'" then [ :string, scanner.scan(backslash || scanner.check(E_QUOTE) ? ESCAPED_SPAN["'"] : PLAIN_SPAN["'"]) ]
      when '"' then [ :quoted, scanner.scan(backslash ? ESCAPED_SPAN['"'] : PLAIN_SPAN['"']) ]
      when "`" then [ :quoted, scanner.scan(PLAIN_SPAN["`"]) ]
      when "[" then brackets && (span = scanner.bracketed) ? [ :quoted, span ] : nil
      when "$"
        tag = scanner.check(DOLLAR_TAG) if family.dollar_quoting?
        [ :string, scanner.scan(DOLLAR_QUOTED) ] if tag && scanner.closed?(tag)
      end
    end

    # Skips the comment that opens where the scanner stands, as the family reads it. One that never closes runs to the end.
    # @return [Boolean] whether one opened there
    def self.comment(scanner, family)
      return !scanner.skip(family.line_comment).nil? unless scanner.skip(/\/\*/)

      depth = 1
      marks = family.nested_comments? ? /\/\*|\*\// : /\*\//
      depth += scanner.matched == "/*" ? 1 : -1 while depth.positive? && scanner.skip_until(marks)
      scanner.terminate if depth.positive?
      true
    end

    private

    def refuse(reason)
      Verdict.new(sql: nil, refusal: reason, plan: nil)
    end

    # [the comment-free text, the refusal the text checks give or nil]. The checks send nothing and hold nothing,
    # so ending them from outside leaves nothing half done.
    def text_verdict(sql)
      Timeout.timeout(@text_timeout, TextChecksTimedOut) do
        refusal = text_refusal(sql)
        next [ nil, refusal ] if refusal

        text = comment_free(sql)
        # With no backslash in it the text reads the same both ways, and the pass above decided.
        if @family.backslash_escapes? && text.include?("\\") && (refusal = without_backslash_escapes { text_refusal(text) })
          refusal = "#{refusal.delete_suffix(".")}. That is how MySQL reads the statement when the session's sql_mode holds NO_BACKSLASH_ESCAPES, " \
            "and rails_query does not read the session's mode. Write a quote inside a string doubled, so that both readings agree."
        end
        [ text, refusal ]
      end
    rescue TextChecksTimedOut
      [ nil, "Blocked: the checks on the statement's text ran longer than query_timeout (#{@text_timeout} seconds), so the statement " \
        "was not run. Send a shorter statement." ]
    end

    # MySQL reads a backslash in a string as an ordinary character under NO_BACKSLASH_ESCAPES. The block's
    # checks read the text that way.
    def without_backslash_escapes
      @backslash = false
      yield
    ensure
      @backslash = @family.backslash_escapes?
    end

    def text_refusal(sql)
      # Read on the raw text too, in case a novel comment form defeats the stripping.
      if (m = listed(BLOCKED_FUNCTIONS, sql))
        return "Blocked: dangerous function #{m[0]} (filesystem/network primitive)"
      end

      cleaned = comment_free(sql).squeeze(" ")
      # Statement checks read quote-masked text, so `LIKE '%update%'` is data. A disk write and the
      # file functions stay on the raw text: no read-only transaction stops them.
      masked = mask_quoted(cleaned)
      return "Blocked: multiple statements (no semicolons)" if masked.match?(MULTI_STATEMENT)
      # MariaDB in its MSSQL mode reads [name] as a quoted name, and no statement of this family holds a bracket otherwise.
      if @family.mysql? && masked.include?("[")
        return "Blocked: a `[` outside a string or a quoted name is not run. MariaDB reads it as the start of a quoted name when the " \
          "session's sql_mode holds MSSQL, and rails_query does not read the session's mode. Quote a name in backticks."
      end
      # PostgreSQL's read-only transaction refuses a locking read, so a literal there is data.
      # MySQL's runs FOR SHARE and LOCK IN SHARE MODE, so there the raw text decides.
      locking = @family.refuses_locking_reads? ? masked : cleaned
      return "Blocked: locking read (FOR UPDATE/SHARE or LOCK IN SHARE MODE clause)" if locking.match?(BLOCKED_CLAUSES)
      return "Blocked: sensitive SHOW command" if listed(BLOCKED_SHOWS, cleaned)
      if listed(CONNECTION_PLAN, masked)
        return "Blocked: EXPLAIN FOR CONNECTION is not run. It shows the plan of the statement another session is running."
      end
      if masked.match?(SHOW_WHERE)
        return "Blocked: SHOW with a WHERE clause is not run, because MySQL's statement timeout does not hold it. " \
          "SHOW ... LIKE runs. For any other filter, SELECT from information_schema, " \
          "for example `SELECT table_name FROM information_schema.tables WHERE table_schema = DATABASE()`."
      end
      return "Blocked: SELECT INTO OUTFILE / DUMPFILE writes to disk" if cleaned.match?(BLOCKED_OUTPUT)
      # No second statement is left by here, so an INTO after a SELECT belongs to it.
      select = masked.index(/\bSELECT\b/i)
      if select && masked.rindex(/\bINTO\b/i).to_i > select
        # After a WITH clause the INTO can be a write's own.
        write = masked[/\b(?:INSERT|MERGE|REPLACE(?!\s*\())\b(?=[^;]*\bINTO\b)/i]
        return write ? "Blocked: contains #{write}" : "Blocked: SELECT INTO creates a table"
      end

      if (m = listed(BLOCKED_FUNCTIONS, cleaned))
        return "Blocked: dangerous function #{m[0]} (filesystem/network primitive)"
      end
      if (m = listed(BLOCKED_DUMPS, cleaned))
        return dump_refusal(m[1])
      end
      # Matched again as MySQL folds a name, so a letter it reads as a plain one names the same relation.
      if (m = [ cleaned, SecretColumns.fold(cleaned) ].filter_map { |read| listed(BLOCKED_RELATIONS, read) || listed(BLOCKED_CATALOGS, read) }.first)
        return never_read_refusal(m.captures.compact.first)
      end
      if (m = listed(SYSTEM_SCHEMAS, mask_quoted(cleaned, :string)))
        text_only = ->(kind, span) { kind == :string || (span.start_with?('"') && !span.match?(/\A"\w+"\z/)) }
        return "#{never_read_refusal(m[1])} A name before a dot is read as that schema, so an alias named `#{m[1]}` needs another name." if
          listed(SYSTEM_SCHEMAS, mask_quoted(cleaned, &text_only))

        return "#{never_read_refusal(m[1])} The name stands before a dot inside double-quoted text, which MySQL reads as a name when the " \
          "session's sql_mode holds ANSI_QUOTES, and rails_query does not read the session's mode. Write the text in single quotes."
      end
      table, why = @secrets.unread_table_in(cleaned)
      return "Blocked: `#{table}` is not read: #{why}." if table
      if (state, view = connection_state(cleaned))
        return "Blocked: `#{state}`#{", which the view `#{view}` reads," if view} tells of the connection that runs it. rails_query runs a statement on a connection of its own and " \
          "sets some of that connection's values itself, so the answer would not be the app's. A pragma function that describes the " \
          "schema or the database file runs, for example `pragma_table_info`."
      end

      if (refusal = setting_refusal(cleaned))
        return refusal
      end
      if (m = listed(BLOCKED_ADMIN, cleaned))
        return "Blocked: administrative function #{m[0].sub(/\s*\(\z/, "")} has a session or server-wide " \
          "effect that a read-only transaction does not prevent. rails_query runs " \
          "read-only queries for inspection; it will not run server-control functions."
      end
      if (m = listed(BLOCKED_SESSION, cleaned))
        return "Blocked: session function #{m[0].sub(/\s*\(\z/, "")} leaves state (a named lock) on the pooled " \
          "connection after the query returns. rails_query will not run it."
      end
      if listed(VARIABLE_ASSIGNMENT, masked)
        return "Blocked: a user variable assignment (`:=`) is not run. It leaves a value on the pooled connection after the query " \
          "returns, which a read-only transaction does not stop."
      end
      if listed(SETS_LAST_INSERT_ID, cleaned)
        return "Blocked: LAST_INSERT_ID with an argument is not run. It sets a value that stays on the pooled connection after the " \
          "query returns, which a read-only transaction does not stop. LAST_INSERT_ID() with no argument runs."
      end

      tokens = tokens(cleaned)
      if renaming_alias_list?(tokens)
        return "Blocked: a column-alias list (e.g. `t(a, b, c)`) renames the columns a " \
          "wildcard returns, so secret columns would leave under harmless names. " \
          "Name the columns you want in the SELECT list instead."
      end
      if quoted_call?(tokens)
        return "Blocked: a quoted name is followed by a parenthesis, the way a function is called. rails_query reads " \
          "a function's name to decide whether it runs, so write the name without quotes."
      end

      # On PostgreSQL a literal is data, since the plan checks read the query itself. MySQL's quote
      # modes and SQLite's t.'col' identifiers could fool a masker, so there the raw text decides.
      literal_free = @family.masks_literals? ? mask_sql_literals(cleaned) : cleaned

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

      # With no plan to read, a value a subquery's wildcard returns can be compared or renamed unseen. Which
      # relation the wildcard reads is not told without a parser, so the rule is the two together.
      wildcard = subquery_wildcard(tokens) unless @family.plan_checks?
      if wildcard && (relation = @secrets.relation_named_in(names_text(tokens)))
        holds = "is not run in a statement that names `#{relation}`, which holds the secret column `#{@secrets.of_relation(relation).first}`."
        return "Blocked: `TABLE` inside a subquery #{holds} `TABLE t` reads every column of `t`, and on #{@family.name} a value read that " \
          "way can be compared or renamed past the redaction, so SELECT the columns you need in the subquery." if wildcard == :table

        return "Blocked: `IN` before a table's name #{holds} #{IN_SHORTHAND}" if wildcard == :in

        return "Blocked: a `*` inside a subquery #{holds} On #{@family.name} a value read through such a wildcard can be compared or " \
          "renamed past the redaction, so name the columns in the subquery."
      end
      if wildcard && wildcard != :table && (relation = string_naming_relation(tokens))
        return "Blocked: #{wildcard == :in ? "`IN` before a table's name" : "a `*` inside a subquery"} is not run in a statement that holds " \
          "the string '#{relation}'. SQLite reads a string as a table's name where a name can stand, and the table `#{relation}` holds the " \
          "secret column `#{@secrets.of_relation(relation).first}`. " + (wildcard == :in ? IN_SHORTHAND :
          "A value read through such a wildcard can be compared or renamed past the redaction, so name the columns in the subquery.")
      end

      # A definition is schema text, so SHOW CREATE VIEW still shows which tables a refused view reads.
      # With a plan the view is told there, by its schema and name: the text does not say which schema a name is in.
      return nil if cleaned.match?(SHOW_CREATE_DEFINITION) || @family.plan_checks?

      view, why = @secrets.refused_view_in(literal_free)
      view_refusal(view, why) if view
    end

    def view_refusal(view, why)
      "Blocked: the view `#{view}` is not queried: #{why}. A view can rename a column past the redaction " \
        "on #{@family.name}, so query the tables it reads."
    end

    # The plan names every relation a statement reads, through any view and in any schema. A view that stores
    # its rows holds what its definition read, so the rule follows that definition as it follows a statement.
    def unread_relation_refusal(plan)
      relations = plan.relations.map(&:last)
      unknown = plan.relations.reject { |_schema, relation| @secrets.knows?(relation) }.map(&:first)
      beside = ->(&reads) { @budget.spend { |left| @family.bounded(@connection, timeout: left, &reads) } }
      beside.call { @secrets.read_schemas(unknown) } if unknown.any?
      stored = relations.select { |relation| @secrets.stored_view?(relation) }
      beside.call { @secrets.reach(stored.join(" ")) } if stored.any?

      if (relation = relations.find { |name| !@secrets.knows?(name) })
        return "Blocked: `#{relation}` is not queried: its columns could not be read, so rails_query cannot tell which of them are secret."
      end

      relations.lazy.filter_map do |placed|
        why = @secrets.placed_view_refusal(placed, plan.name(placed))
        view_refusal(plan.name(placed), why) if why
      end.first
    end

    # The family's own part of a list, matched against the text.
    def listed(list, text)
      list[@family.key]&.match(text)
    end

    def never_read_refusal(name)
      "Blocked: `#{name}` is not read. It holds values sampled from other tables, other sessions' statements " \
        "or stored credentials, and rails_query cannot tell which of them are secret." \
        "#{" To read one setting, run SHOW with its name." if name.match?(/settings/i)}"
    end

    # [name, view] for the first function that tells of the connection in the statement, or in a view it reaches,
    # which SQLite runs on the same connection.
    def connection_state(cleaned)
      return nil unless @family.sqlite?

      state = connection_state_in(cleaned)
      return [ state, nil ] if state

      @secrets.view_definitions_in(cleaned).each { |view, definition| (state = connection_state_in(definition)) and return [ state, view ] }
      nil
    end

    # A counter is told by its call. A pragma function is told where it can run: called, or where a table stands
    # (after FROM, JOIN, IN, a comma of a FROM list, a parenthesis that opens one, or a schema and a dot there).
    # A name anywhere else is a column's or an alias's, which SQLite never reads as the function.
    def connection_state_in(cleaned)
      # A table of a counter's name does not hide the function, as one of a pragma function's name does.
      counter = cleaned[SQLITE_COUNTER_CALL, 1]
      return counter.downcase if counter

      list = tokens(cleaned)
      clauses = [ nil ]
      at_table = []
      table_next = false
      list.each_with_index do |(kind, text), i|
        at_table << table_next
        pragma = text.to_s[SQLITE_PRAGMA_NAME, 1]&.downcase if %i[word quoted string].include?(kind)
        name = "pragma_#{pragma}" if pragma && !SQLITE_FILE_PRAGMAS.include?(pragma)
        return name if name && (table_next || list[i + 1] == [ :punct, "(" ]) && !@secrets.knows?(name)

        word = text.downcase if kind == :word
        table_next = case [ kind, text ]
        when [ :punct, "(" ] then clauses.push(table_next == :from ? "from" : nil) && (table_next == :from && :from)
        when [ :punct, ")" ] then (clauses.pop if clauses.size > 1) && false
        when [ :punct, "," ] then FROM_LIST_CLAUSES.include?(clauses.last) && :from
        when [ :punct, "." ] then at_table[i - 1] if i.positive?
        else (%w[from join].include?(word) && :from) || (word == "in" && :in)
        end
        clauses[-1] = word if CLAUSE_WORDS.include?(word)
      end
      nil
    end

    def dump_refusal(function)
      "Blocked: function #{function} returns a whole table as one value, secret columns included. " \
        "SELECT the columns you need from the table itself."
    end

    # A setting is read by SHOW and by current_setting. SHOW has no plan, so on PostgreSQL its name is read
    # here and has to be plain: a quoted name can spell any setting.
    def setting_refusal(cleaned)
      return nil unless @family.postgresql?

      if (m = cleaned.match(SECRET_SETTINGS))
        return secret_setting_refusal(m[1])
      end

      called = cleaned.to_enum(:scan, SETTING_CALL).map { Regexp.last_match[1] }
      return unread_setting_name_refusal if called.include?(nil)

      shown = cleaned.match(SHOWN_SETTING)&.then { |m| m[1].strip }
      if shown && !shown.match?(/\A[\w. ]+\z/)
        return "Blocked: SHOW takes a setting's plain name on PostgreSQL, with no quotes around it, for example `SHOW work_mem`."
      end
      if shown&.casecmp?("ALL")
        return "Blocked: SHOW ALL is not run. It lists every setting, the ones that can hold a password among them. " \
          "SHOW one setting by its name."
      end

      secret = (called + [ shown ]).compact.find { |name| secret_setting?(name) }
      secret_setting_refusal(secret) if secret
    end

    # An app's own setting (`app.jwt_secret`) is told by its name, as a column is.
    def secret_setting?(name)
      name.match?(SECRET_SETTINGS) || name.split(/[.\s]+/).any? { |part| @secrets.secret?(part) }
    end

    def secret_setting_refusal(name)
      "Blocked: the setting `#{name}` is not read. It can hold a password, a key or a command line that carries one."
    end

    def unread_setting_name_refusal
      "Blocked: current_setting runs only with the setting's name written as one plain string, " \
        "for example `current_setting('work_mem')`, so that rails_query can read which setting it returns."
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
        "#{"#{reads}. " if source}If `#{offending}` is not secret in your app, add \"#{offending}\" to query_allowed_columns in " \
          ".rails-ai-context.yml (or in config/initializers/rails_ai_context.rb where the app bundles the gem)."
      end
      "Blocked: query references secret column `#{offending}`. " \
        "Name the columns you need; `#{offending}` is secret and never " \
        "returned, and an alias or expression over it cannot be redacted after " \
        "the query runs, so the whole query is refused. #{way_out}"
    end

    def comment_free(sql)
      self.class.comment_free(sql, @family, backslash: @backslash)
    end

    # Every quoted and dollar-quoted span blanked to spaces of the same length, so a check reads structure
    # only and positions still line up. only: the one kind to blank, :string or :quoted. With a block, the spans it picks.
    def mask_quoted(text, only = nil, &picks)
      picks ||= ->(kind, _span) { only.nil? || kind == only }
      scanner = Scanner.new(text)
      out = +""

      until scanner.eos?
        kind, span = self.class.quoted(scanner, @family, backslash: @backslash)
        out << (span.nil? ? scanner.scan(UNQUOTED) || scanner.getch : picks.call(kind, span) ? " " * span.length : span)
      end

      out
    end

    # [kind, text] for each token of comment-free text: :word (bare, a keyword or a name), :quoted (a name in
    # double quotes, backticks or brackets), :string, :number, or :punct, one character.
    def tokens(text)
      scanner = Scanner.new(text)
      found = []
      until scanner.eos?
        next if scanner.skip(/\s+/) || scanner.skip(/[uU]&(?=["'])/)

        # A bracketed name is read on every family: an alias list is told by its shape, whatever quotes its names.
        found << (self.class.quoted(scanner, @family, brackets: true, backslash: @backslash) ||
          scanner.scan(BARE_WORD)&.then { |span| [ span.match?(NUMBER) ? :number : :word, span ] } || [ :punct, scanner.getch ])
      end
      found
    end

    # PostgreSQL's string literals emptied, with the E, B, X or U& that stands before one. A quoted name stays.
    def mask_sql_literals(text)
      scanner = Scanner.new(text)
      out = +""

      until scanner.eos?
        kind, span = self.class.quoted(scanner, @family)
        if kind == :string
          out.chop! if out.end_with?("&")
          # Read as a byte: a character past ASCII ends in one from 0x80 up, and it is part of a name.
          before = out.getbyte(-2)
          out.chop! if out.end_with?(*%w[e E b B x X u U]) && !(before && (before >= 0x80 || before.chr.match?(/[\w$]/)))
          out << "''"
        else
          out << (span || scanner.scan(UNQUOTED) || scanner.getch)
        end
      end

      out
    end

    # A column-alias list renames the columns a wildcard produced, past the redaction that reads names.
    # It is told by its shape: a parenthesised list of names after a CTE's name, or after a table's alias.
    def renaming_alias_list?(tokens)
      pairs = paren_pairs(tokens)
      tokens.each_index.any? do |open|
        close = pairs[open] if tokens[open] == [ :punct, "(" ]
        kinds = name_list_kinds(tokens, open, close) if close
        kinds && (cte_list?(tokens, pairs, open, close) || alias_list?(tokens, pairs, open, close, kinds))
      end
    end

    # "(" index => its ")" index, and back.
    def paren_pairs(tokens)
      pairs = {}
      stack = []
      tokens.each_with_index do |token, i|
        if token == [ :punct, "(" ] then stack << i
        elsif token == [ :punct, ")" ] && (open = stack.pop)
          pairs[open] = i
          pairs[i] = open
        end
      end
      pairs
    end

    # The kinds of the names between the parentheses, or nil when they hold anything but names and commas.
    # A type modifier holds numbers and a record function's list holds types, so neither is one.
    def name_list_kinds(tokens, open, close)
      return nil unless (close - open).even?

      # Read in place and left at the first token that is no name: a copy for each parenthesis of a deep nest is quadratic.
      kinds = []
      (open + 1).step(close - 1, 2) do |i|
        return nil unless %i[word quoted string].include?(tokens[i][0]) && (i + 1 == close || tokens[i + 1] == [ :punct, "," ])

        kinds << tokens[i][0]
      end
      kinds.uniq
    end

    # name (a, b) AS [NOT] [MATERIALIZED] (body). SQLite takes a string for a name here.
    def cte_list?(tokens, pairs, open, close)
      return false unless open.positive? && %i[word quoted string].include?(tokens[open - 1][0]) && word?(tokens[close + 1], "AS")

      body = close + 2
      body += 1 if word?(tokens[body], "NOT")
      body += 1 if word?(tokens[body], "MATERIALIZED")
      tokens[body] == [ :punct, "(" ] && !values_only?(tokens, body, pairs[body])
    end

    # AS t (a, b) after anything, and with no AS: (subquery) t (a, b) and FROM table t (a, b).
    def alias_list?(tokens, pairs, open, close, kinds)
      return false unless open >= 2 && %i[word quoted string].include?(tokens[open - 1][0])

      before = open - 2
      if word?(tokens[before], "AS")
        source = pairs[before - 1] if before.positive? && tokens[before - 1] == [ :punct, ")" ]
        return true unless source
        return false if values_only?(tokens, source, before - 1)

        # One name after a function call names the one column the function returns.
        close - open > 2 || subquery_at?(tokens, source)
      elsif kinds.include?(:string) || !name?(tokens[open - 1])
        false
      elsif tokens[before] == [ :punct, ")" ]
        source = pairs[before]
        !source.nil? && subquery_at?(tokens, source) && !values_only?(tokens, source, before)
      else
        word?(tokens[before], "ORDINALITY") || table_at?(tokens, before)
      end
    end

    # Whether the token at `last` ends a table name in a FROM clause: [FROM|JOIN] [ONLY] schema.table [*].
    def table_at?(tokens, last)
      last -= 1 if tokens[last] == [ :punct, "*" ]
      return false unless last.positive? && name?(tokens[last])

      last -= 2 while last >= 2 && tokens[last - 1] == [ :punct, "." ] && name?(tokens[last - 2])
      last -= 1 if last.positive? && word?(tokens[last - 1], "ONLY")
      last.positive? && %w[FROM JOIN STRAIGHT_JOIN].any? { |anchor| word?(tokens[last - 1], anchor) }
    end

    def word?(token, keyword)
      !token.nil? && token[0] == :word && token[1].casecmp?(keyword)
    end

    # A quoted name, or a bare word that can name a table or an alias.
    def name?(token)
      token[0] == :quoted || (token[0] == :word && !NO_ALIAS.include?(token[1].upcase))
    end

    # A quoted name can spell any function, past every check that reads a function's name.
    def quoted_call?(tokens)
      tokens.each_index.any? do |i|
        following = i + (word?(tokens[i + 1], "UESCAPE") ? 3 : 1)
        tokens[i][0] == :quoted && tokens[following] == [ :punct, "(" ]
      end
    end

    def subquery_at?(tokens, open)
      following = tokens[open + 1]
      following == [ :punct, "(" ] || SUBQUERY_START.any? { |start| word?(following, start) }
    end

    # A list over a body of VALUES rows renames constants, so it is left alone.
    def values_only?(tokens, open, close)
      return false unless close && word?(tokens[open + 1], "VALUES")

      before = row_sources_before(tokens)
      before[close] == before[open + 2]
    end

    # How many row-source words stand before each token, so that no body is scanned for them on its own.
    def row_sources_before(tokens)
      (@row_sources ||= {}.compare_by_identity)[tokens] ||= tokens.each_with_object([ 0 ]) do |token, counts|
        counts << counts.last + (ROW_SOURCES.any? { |source| word?(token, source) } ? 1 : 0)
      end
    end

    # :star for a select-list wildcard inside parentheses, :table for `TABLE t` there off SQLite, :in for SQLite's
    # `x IN t` anywhere, else nil. `count(*)` reads no column and EXISTS returns none, so both are left alone.
    def subquery_wildcard(tokens)
      enclosing = []
      tokens.each_with_index do |token, i|
        following = tokens[i + 1]
        return :in if @family.sqlite? && word?(token, "IN") && following && following != [ :punct, "(" ]

        enclosing << i if token == [ :punct, "(" ]
        enclosing.pop if token == [ :punct, ")" ]
        next if enclosing.empty? || (enclosing.last.positive? && word?(tokens[enclosing.last - 1], "EXISTS"))

        star = token == [ :punct, "*" ] && (following.nil? || [ ",", ")" ].include?(following[1]) || word?(following, "FROM")) &&
          !(tokens[i - 1] == [ :punct, "(" ] && following == [ :punct, ")" ])
        return :star if star
        return :table if !@family.sqlite? && word?(token, "TABLE") && tokens[i - 1] != [ :punct, "." ]
      end
      nil
    end

    # The statement with each string emptied: where a string names a relation, string_naming_relation reads it.
    def names_text(tokens)
      tokens.map { |kind, text| kind == :string ? "''" : text }.join(" ")
    end

    # SQLite reads a string as a name wherever a name can stand, so a string equal to such a relation's name is one.
    def string_naming_relation(tokens)
      return nil unless @family.sqlite?

      tokens.each do |kind, text|
        name = text[1..].delete_suffix("'").gsub("''", "'") if kind == :string
        return name if name && @secrets.relation_secret?(name)
      end
      nil
    end

    def plan_refusal(top, text)
      return nil unless top

      plan = DatabaseFamily::PostgresqlPlan.new(top)
      refusal = unread_relation_refusal(plan)
      return refusal if refusal

      raw = plan.nodes.flat_map { |node| plan.expressions(node) }
      outputs = []
      conds = []
      plan.nodes.each do |node|
        outputs.concat(Array(node["Output"]).map { |e| e.to_s.gsub(PLAN_LITERAL, "''") })
        PLAN_COND_KEYS.each { |k| conds.concat(Array(node[k]).map { |e| e.to_s.gsub(PLAN_LITERAL, "''") }) }
      end
      foreign = plan.nodes.select { |node| node["Remote SQL"] }
      conds.concat(foreign.map { |node| remote_uses(node) }, local_names(foreign))
      # EXPLAIN prints no row of a VALUES list and no LIMIT, so the functions the text names are read too.
      called = function_names(raw.map { |expr| expr.gsub(PLAN_LITERAL, "''") } + [ mask_sql_literals(text).gsub(SAMPLING_METHOD, "TABLESAMPLE ") ])

      # A view reaches a relation or a function the text check did not see.
      sources = plan.nodes.flat_map { |node| node.values_at("Relation Name", "Function Name") }.compact + called.to_a
      if (name = sources.find { |source| source.match?(/\A#{BLOCKED_RELATIONS.fetch(:postgresql)}\z/) })
        return never_read_refusal(name)
      end
      if (name = called.find { |function| "#{function}(".match?(/\A#{BLOCKED_DUMPS.fetch(:postgresql)}\z/) })
        return dump_refusal(name)
      end
      settings = raw.flat_map { |expr| expr.to_enum(:scan, PLAN_SETTING_CALL).map { Regexp.last_match[1] } }
      return unread_setting_name_refusal if settings.include?(nil)
      if (name = settings.find { |setting| secret_setting?(setting) })
        return secret_setting_refusal(name)
      end
      if (rel = whole_row_leak(outputs + conds, plan.aliases))
        return "Blocked: the query serialises a whole row of `#{plan.name(rel)}`, which carries every " \
          "column including the secret ones. Name the columns you need in the SELECT list."
      end
      if (col = secret_column_in_plan(outputs, conds))
        return "Blocked: the query's plan uses the secret column `#{col}` (expanded from a " \
          "wildcard or a row reference). Name the other columns you need; `#{col}` is " \
          "never returned."
      end
      if (col = laundered_secret_column(plan))
        return "Blocked: the query passes the secret column `#{col}` through a CTE, subquery " \
          "or set operation whose output the tool cannot map to a column, so it could leave " \
          "unredacted. Name the other columns you need; `#{col}` is never returned."
      end
      if (fn = volatile_function(called))
        "Blocked: function #{fn} is VOLATILE (pg_proc.provolatile = 'v') and not on " \
          "rails_query's list of read-only VOLATILE functions, so it is not run. Some VOLATILE " \
          "functions change server or session state in ways a read-only transaction does not " \
          "stop; only those known to just read state (sizes, lock status, recovery and WAL " \
          "position, random values) are allowed."
      end
    end

    # What the statement a foreign scan sends does with a column past fetching it: its joins, conditions and sorts.
    # GROUP BY names a key by its place in the select list, so a grouped statement is read whole.
    def remote_uses(node)
      remote = node["Remote SQL"].to_s.gsub(PLAN_LITERAL, "''")
      past_select = remote.sub(/\ASELECT\b.*?\bFROM\b/m, "")
      past_select.match?(/\bGROUP\s+BY\b/i) ? remote : past_select
    end

    # The foreign columns a remote statement uses under the name their column_name option gives them, by their own
    # names. A join or an aggregate the remote server runs names its tables under "Relations".
    def local_names(foreign)
      return [] if foreign.empty?

      renamed = @budget.spend do |left|
        @family.bounded(@connection, timeout: left) do
          @connection.select_rows(
            "SELECT c.relname, a.attname, o.option_value FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid " \
            "CROSS JOIN LATERAL pg_options_to_table(a.attfdwoptions) o WHERE o.option_name = 'column_name' AND NOT a.attisdropped"
          )
        end
      end
      renamed.filter_map do |table, local, far|
        local if foreign.any? { |node| names?(node.values_at("Relation Name", "Relations").map(&:to_s), table) && names?([ remote_uses(node) ], far) }
      end
    end

    # A secret name the text check passed as a literal runs only when a plan cleared the checks,
    # so the plan backs a masker that a quote trick fooled.
    def unvouched_literal_refusal(text, plan)
      return nil unless @family.plan_checks?

      offending = @secrets.named_in(text) or return nil
      return nil if plan && @secrets.named_in(mask_sql_literals(text)).nil?

      "Blocked: query references secret column `#{offending}`. It is read as data " \
        "only when the query plan confirms it, and the plan could not be obtained, so the " \
        "query is refused. Name the columns you need; `#{offending}` is never returned."
    end

    # A whole-row `alias.*` where any relation the alias stands for holds a secret column. An alias the
    # plan does not resolve is refused when any relation in it is secret.
    def whole_row_leak(exprs, aliases)
      any_secret = aliases.values.flatten.any? { |rel| @secrets.relation_secret?(rel) }
      exprs.each do |expr|
        expr.scan(/(?:([A-Za-z_]\w*)|"((?:""|[^"])+)")\.\*/) do |bare, quoted|
          al = bare || quoted.gsub('""', '"')
          rels = aliases[al]
          secret = rels&.find { |rel| @secrets.relation_secret?(rel) }
          return secret if secret
          return al if rels.nil? && any_secret
        end
      end
      nil
    end

    # A secret column anywhere but a plain pass-through output. The text check refused any statement
    # naming one, so a name here came from a wildcard, an expanded row reference or a view.
    def secret_column_in_plan(outputs, conds)
      secret = @secrets.in_schema
      return nil if secret.empty?

      named = ->(expr) { secret.find { |col| names?([ expr ], col) } }
      conds.each { |expr| (col = named.call(expr)) and return col }
      outputs.each do |expr|
        next if expr.match?(PASSTHROUGH_OUTPUT)

        (col = named.call(expr)) and return col
      end
      nil
    end

    # A secret base column some node passes through and the top node leaves unnamed, so redaction by position cannot
    # pin it. A column handed to a node that reads by name and names it nowhere (`count(*)`) is read by nothing.
    def laundered_secret_column(plan)
      top = secret_base_columns(plan, plan.output.flatten)
      # A set operation compares every column its inputs hand up, so a row of guesses tests a secret value.
      plan.nodes.select { |node| node["Node Type"] == "SetOp" }.each do |node|
        handed = ([ node ] + Array(node["Plans"])).flat_map { |held| Array(held["Output"]) }
        (col = @secrets.in_schema.find { |name| names?(handed, name) }) and return col
      end
      plan.nodes.each do |node|
        reader = plan.reader(node)
        secret_base_columns(plan, Array(node["Output"])).each do |var|
          next if top.include?(var) || (reader && !names?(plan.expressions(reader), var.last))

          return var.last
        end
      end
      nil
    end

    def names?(exprs, column)
      pattern = SecretColumns.identifier(column)
      exprs.any? { |expr| SecretColumns.fold(expr.gsub(PLAN_LITERAL, "''")).match?(pattern) }
    end

    def secret_base_columns(plan, output)
      output.flat_map { |expr| plan.base_columns(expr) }.select { |rel, col| @secrets.of_relation(rel).include?(col) }.to_set
    end

    def function_names(exprs)
      exprs.each_with_object(Set.new) { |expr, names| expr.scan(/([A-Za-z_]\w*)\s*\(/) { |(fn)| names << fn.downcase } }
    end

    def volatile_function(called)
      names = called - PG_VOLATILE_ALLOWLIST
      return nil if names.empty?

      quoted = names.map { |n| @connection.quote(n) }.join(", ")
      @budget.spend do |left|
        @family.bounded(@connection, timeout: left) do
          @connection.select_values(
            "SELECT DISTINCT lower(proname) FROM pg_proc WHERE lower(proname) IN (#{quoted}) AND provolatile = 'v'"
          ).first
        end
      end
    end
  end
end
