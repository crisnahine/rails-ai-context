# frozen_string_literal: true

require "set"
require "strscan"

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

      # Runs the block with the seconds left.
      # @raise [DatabaseFamily::TimedOut] when earlier reads used them all
      def spend
        raise DatabaseFamily::TimedOut, "the reads beside the statement used the whole timeout" unless @left.positive?

        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        yield @left
      ensure
        @left -= Process.clock_gettime(Process::CLOCK_MONOTONIC) - started if started
      end
    end

    # REPLACE is the MySQL statement; `replace(` is the string function every
    # database has, so a REPLACE followed by an opening parenthesis is let be.
    BLOCKED_KEYWORDS = /\b(INSERT|UPDATE|DELETE|DROP|ALTER|TRUNCATE|CREATE|GRANT|REVOKE|SET|COPY|MERGE|REPLACE(?!\s*\())\b/i
    # SHOW CREATE TABLE / VIEW print a definition; every other SHOW CREATE is
    # refused by the CREATE keyword - SHOW CREATE USER prints credential hashes.
    SHOW_CREATE_DEFINITION = /\A\s*SHOW\s+CREATE\s+(?:TABLE|VIEW)\b/i
    BLOCKED_CLAUSES  = /\bFOR\s+(?:UPDATE|SHARE|NO\s+KEY\s+UPDATE|KEY\s+SHARE)\b|\bLOCK\s+IN\s+SHARE\s+MODE\b/i
    # Other sessions' statements, replication hosts and users, and the row data a log holds.
    BLOCKED_SHOWS    = /\bSHOW\s+(?:(?:FULL|ALL)\s+)?(?:GRANTS|PROCESSLIST|BINLOG|BINARY|RELAYLOG|SLAVES?|MASTER|REPLICAS?|ENGINE|
      PROFILES?|OPEN\s+TABLES|EXPLAIN|ANALYZE|USER_STATISTICS|CLIENT_STATISTICS|WSREP_\w+)\b/ix
    # A SHOW filter runs an expression for each row, and MySQL's statement timeout holds SELECT only.
    SHOW_WHERE       = /\A\s*SHOW\b.*\bWHERE\b/mi
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

    # PostgreSQL functions that return a whole table as one value, its secret columns included.
    BLOCKED_DUMPS = /\b((?:query|table|schema|database|cursor)_to_xml(?:schema|_and_xmlschema)?)\s*\(/i

    # Relations that hold values sampled from other tables' columns, other sessions' statements or stored
    # credentials, where no check on a column's name applies.
    BLOCKED_RELATIONS = /\b(?:(
      pg_stats(?:_ext(?:_exprs)?)? | pg_statistic(?:_ext(?:_data)?)? | pg_largeobject |
      pg_stat_activity | pg_stat_get_activity | pg_stat_get_backend_activity |
      pg_stat_statements | pg_prepared_statements | pg_cursors |
      sqlite_stat[134] | column_statistics | column_stats | global_priv |
      processlist | performance_schema | general_log | slow_log
    )\b|(sys)`?\s*\.)/ix

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

    # A UNION names its columns after its first SELECT, so another table's rows leave under those names.
    # INTERSECT and EXCEPT return only rows of their first SELECT, so they stay.
    SET_UNION = /\bUNION\b/i

    QUOTED = /'[^']*'?|"[^"]*"?|`[^`]*`?/m
    # SQLite reads [name] as an identifier.
    BRACKETED = /\[[^\]\n]*\]/
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

    PLAN_IDENT = /(?:[A-Za-z_]\w*|"(?:""|[^"])*")/
    PASSTHROUGH_OUTPUT = /\A\(?\s*(?:#{PLAN_IDENT}\.)?#{PLAN_IDENT}\s*\)?\z/

    # SHOW reads a setting and PostgreSQL has no DESCRIBE, so these have no plan.
    # Every other statement is planned, as is whatever a leading EXPLAIN would run.
    NO_PLAN = /\A\s*(?:SHOW|DESCRIBE|DESC)\b/i
    EXPLAIN_PREFIX = /\A\s*EXPLAIN\s+(?:\([^)]*\)\s*)?(?:ANALYZE\s+)?(?:VERBOSE\s+)?/i

    # family decides the lexing and whether the plan checks run. budget is the seconds the reads the
    # gate sends (the plan, the pg_proc lookup) share with the caller's other reads.
    def initialize(family:, secrets:, connection:, budget:)
      @family = family
      @secrets = secrets
      @connection = connection
      @budget = budget
    end

    def check(sql)
      return refuse("SQL query is required.") if sql.nil? || sql.strip.empty?

      if (refusal = text_refusal(sql))
        return refuse(refusal)
      end

      text = comment_free(sql)
      planned = @family.plan_checks? && !text.match?(NO_PLAN)
      plan = @budget.spend { |left| @family.plan(@connection, text.sub(EXPLAIN_PREFIX, ""), timeout: left) } if planned
      if planned && plan.nil?
        return refuse("Blocked: the query is not run because its plan could not be read. On PostgreSQL " \
          "the plan shows which columns a query returns, so no query runs without one.")
      end

      refusal = plan_refusal(plan) || unvouched_literal_refusal(text, plan)
      refusal ? refuse(refusal) : Verdict.new(sql: text, refusal: nil, plan: plan)
    end

    # The text with its comments out and every quoted span copied whole, as the family reads them.
    def self.comment_free(sql, family)
      # fixed_anchor, so the dollar quote's lookbehind sees the text before the pointer.
      scanner = StringScanner.new(sql, fixed_anchor: true)
      out = +""
      executable = false

      until scanner.eos?
        if (span = scanner.scan(quoted_at(out, scanner, family)) || (family.dollar_quoting? && scanner.scan(DOLLAR_QUOTED)) || scanner.scan(UNQUOTED))
          out << span
        elsif family.executable_comments? && scanner.scan(/\/\*!\d*/)
          # Its content stays for the checks to read: `SELECT /*!50000 LOAD_FILE(...) */`.
          executable = true
          out << " "
        elsif executable && scanner.scan(/\*\//)
          executable = false
          out << " "
        elsif scanner.scan(/\/\*.*?(?:\*\/|\z)/m) || scanner.scan(family.line_comment)
          out << " "
        else
          out << scanner.getch
        end
      end

      out.strip
    end

    def self.quoted_at(out, scanner, family)
      if family.backslash_escapes? then MYSQL_QUOTED
      elsif out.match?(/(?<![\p{Word}$])[eE]\z/) && scanner.check(/'/) then ESCAPED_STRING
      else QUOTED
      end
    end

    private

    def refuse(reason)
      Verdict.new(sql: nil, refusal: reason, plan: nil)
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
      locking = @family.refuses_locking_reads? ? masked : cleaned
      return "Blocked: locking read (FOR UPDATE/SHARE or LOCK IN SHARE MODE clause)" if locking.match?(BLOCKED_CLAUSES)
      return "Blocked: sensitive SHOW command" if cleaned.match?(BLOCKED_SHOWS)
      if masked.match?(SHOW_WHERE)
        return "Blocked: SHOW with a WHERE clause is not run, because MySQL's statement timeout does not hold it. " \
          "SHOW ... LIKE runs. For any other filter, SELECT from information_schema, " \
          "for example `SELECT table_name FROM information_schema.tables WHERE table_schema = DATABASE()`."
      end
      return "Blocked: SELECT INTO OUTFILE / DUMPFILE writes to disk" if cleaned.match?(BLOCKED_OUTPUT)
      return "Blocked: SELECT INTO creates a table" if masked.match?(SELECT_INTO)

      if (m = cleaned.match(BLOCKED_FUNCTIONS))
        return "Blocked: dangerous function #{m[0]} (filesystem/network primitive)"
      end
      if (m = cleaned.match(BLOCKED_DUMPS))
        return "Blocked: function #{m[1]} returns a whole table as one value, secret columns included. " \
          "SELECT the columns you need from the table itself."
      end
      if (m = cleaned.match(BLOCKED_RELATIONS))
        return unfollowed_relation_refusal(m[1] || m[2])
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

      tokens = tokens(cleaned)
      if renaming_alias_list?(tokens)
        return "Blocked: a column-alias list (e.g. `t(a, b, c)`) renames the columns a " \
          "wildcard returns, so secret columns would leave under harmless names. " \
          "Name the columns you want in the SELECT list instead."
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

      # With no plan to read, a value a subquery's wildcard returns can be compared or renamed unseen.
      if !@family.plan_checks? && subquery_wildcard?(tokens) && (relation = @secrets.relation_named_in(cleaned))
        return "Blocked: a `*` inside a subquery reads every column of `#{relation}`, which holds the secret column " \
          "`#{@secrets.of_relation(relation).first}`. On #{@family.name} a value read that way can be compared or " \
          "renamed past the redaction, so name the columns in the subquery."
      end

      # A definition is schema text, so SHOW CREATE VIEW still shows which tables a refused view reads.
      view, why = @secrets.refused_view_in(literal_free) unless cleaned.match?(SHOW_CREATE_DEFINITION)
      return nil unless view

      "Blocked: the view `#{view}` is not queried: #{why}. A view can rename a column past the redaction " \
        "on #{@family.name}, so query the tables it reads."
    end

    def unfollowed_relation_refusal(name)
      "Blocked: `#{name}` is not read. It holds values sampled from other tables, other sessions' statements " \
        "or stored credentials, and rails_query cannot tell which of them are secret."
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
        "#{"#{reads}. " if source}If `#{offending}` is not secret in your app, add \"#{offending}\" to " \
          "config.query_allowed_columns in an initializer."
      end
      "Blocked: query references secret column `#{offending}`. " \
        "Name the columns you need; `#{offending}` is secret and never " \
        "returned, and an alias or expression over it cannot be redacted after " \
        "the query runs, so the whole query is refused. #{way_out}"
    end

    def comment_free(sql)
      self.class.comment_free(sql, @family)
    end

    # Every quoted and dollar-quoted span blanked to spaces of the same
    # length, so a check reads structure only and positions still line up.
    def mask_quoted(text)
      scanner = StringScanner.new(text, fixed_anchor: true)
      out = +""

      until scanner.eos?
        if (span = scanner.scan(self.class.quoted_at(out, scanner, @family)) || (@family.dollar_quoting? && scanner.scan(DOLLAR_QUOTED)))
          out << (" " * span.length)
        elsif (span = scanner.scan(UNQUOTED))
          out << span
        else
          out << scanner.getch
        end
      end

      out
    end

    # [kind, text] for each token of comment-free text: :word (bare, a keyword or a name), :quoted (a name in
    # double quotes, backticks or brackets), :string, :number, or :punct, one character.
    def tokens(text)
      scanner = StringScanner.new(text, fixed_anchor: true)
      found = []
      word_end = nil
      until scanner.eos?
        next if scanner.skip(/\s+/) || scanner.skip(/[uU]&(?=["'])/)

        open = scanner.peek(1)
        if [ "'", '"', "`" ].include?(open)
          # PostgreSQL's E'...' takes backslash escapes: the E is the word that ends where the quote opens.
          after_e = found.last&.then { |kind, word| kind == :word && word.casecmp?("e") } && word_end == scanner.pos
          found << [ open == "'" ? :string : :quoted, quoted_span(scanner, open, after_e) ]
        elsif (span = scanner.scan(BRACKETED)) then found << [ :quoted, span ]
        elsif @family.dollar_quoting? && (span = scanner.scan(DOLLAR_QUOTED)) then found << [ :string, span ]
        elsif (span = scanner.scan(BARE_WORD))
          found << [ span.match?(NUMBER) ? :number : :word, span ]
          word_end = scanner.pos
        else found << [ :punct, scanner.getch ]
        end
      end
      found
    end

    # One quoted token. A doubled quote inside it scans as a second span right after the first.
    def quoted_span(scanner, open, after_e)
      escaped = open != "`" && (@family.backslash_escapes? || (open == "'" && after_e))
      pattern = escaped ? /#{open}(?:\\.|[^#{open}\\])*#{open}?/m : /#{open}[^#{open}]*#{open}?/m
      span = scanner.scan(pattern)
      span << scanner.scan(pattern) while span.length > 1 && span.end_with?(open) && scanner.peek(1) == open
      span
    end

    def mask_sql_literals(text)
      text.gsub(PG_TEXT_LITERAL) { Regexp.last_match[:ident] || "''" }
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
      inner = tokens[(open + 1)...close]
      return nil unless inner.size.odd?
      return nil unless inner.each_slice(2).all? { |name, comma| %i[word quoted string].include?(name[0]) && [ nil, [ :punct, "," ] ].include?(comma) }

      inner.each_slice(2).map { |name, _| name[0] }.uniq
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

    def subquery_at?(tokens, open)
      following = tokens[open + 1]
      following == [ :punct, "(" ] || SUBQUERY_START.any? { |start| word?(following, start) }
    end

    # A list over a body of VALUES rows renames constants, so it is left alone.
    def values_only?(tokens, open, close)
      return false unless close && word?(tokens[open + 1], "VALUES")

      tokens[(open + 2)...close].none? { |token| ROW_SOURCES.any? { |source| word?(token, source) } }
    end

    # A select-list wildcard, or MySQL's `TABLE t`, inside parentheses. `count(*)` reads no column and
    # EXISTS returns none, so both are left alone.
    def subquery_wildcard?(tokens)
      enclosing = []
      tokens.each_with_index.any? do |token, i|
        enclosing << i if token == [ :punct, "(" ]
        enclosing.pop if token == [ :punct, ")" ]
        next false if enclosing.empty? || (enclosing.last.positive? && word?(tokens[enclosing.last - 1], "EXISTS"))

        following = tokens[i + 1]
        star = token == [ :punct, "*" ] && (following.nil? || [ ",", ")" ].include?(following[1]) || word?(following, "FROM")) &&
          !(tokens[i - 1] == [ :punct, "(" ] && following == [ :punct, ")" ])
        star || (word?(token, "TABLE") && tokens[i - 1] != [ :punct, "." ])
      end
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

      # A view or an escaped name reaches one the text check did not see.
      sources = plan.nodes.flat_map { |node| node.values_at("Relation Name", "Function Name") }.compact
      if (name = sources.find { |source| source.match?(/\A#{BLOCKED_RELATIONS}\z/) })
        return unfollowed_relation_refusal(name)
      end
      if (rel = whole_row_leak(outputs + conds, plan.aliases))
        return "Blocked: the query serialises a whole row of `#{rel}`, which carries every " \
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
      return nil unless @family.plan_checks?

      offending = @secrets.named_in(text) or return nil
      return nil if plan && @secrets.named_in(mask_sql_literals(text)).nil?

      "Blocked: query references secret column `#{offending}`. It is read as data " \
        "only when the query plan confirms it, and the plan could not be obtained, so the " \
        "query is refused. Name the columns you need; `#{offending}` is never returned."
    end

    # A whole-row `alias.*` of a relation with a secret column. An alias the
    # plan does not resolve is refused when any relation in it is secret.
    def whole_row_leak(exprs, aliases)
      any_secret = aliases.values.any? { |rel| @secrets.relation_secret?(rel) }
      exprs.each do |expr|
        expr.scan(/(?:([A-Za-z_]\w*)|"((?:""|[^"])+)")\.\*/) do |bare, quoted|
          al = bare || quoted.gsub('""', '"')
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

      named = ->(expr) { secret.find { |col| names?([ expr ], col) } }
      conds.each { |expr| (col = named.call(expr)) and return col }
      outputs.each do |expr|
        next if expr.match?(PASSTHROUGH_OUTPUT)

        (col = named.call(expr)) and return col
      end
      nil
    end

    # A secret base column some node passes through and the top node leaves unnamed (a MATERIALIZED
    # CTE, a subquery scan, a set operation), where redaction by position cannot pin it. A column
    # handed to a node that reads by name and names it nowhere (`count(*)`) is read by nothing.
    def laundered_secret_column(plan)
      top = secret_base_columns(plan, plan.output)
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
