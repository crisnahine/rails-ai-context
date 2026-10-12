<div align="center" markdown="1">

# Security Model

**Read-only by design. Defense in depth. Every tool is non-destructive.**

[Architecture](ARCHITECTURE.md) · [Configuration](CONFIGURATION.md) · [Tools Reference](TOOLS.md) · [FAQ](FAQ.md)

</div>

---

> [!CAUTION]
> This gem is designed for **development environments**. The query tool, and MCP over HTTP from inside the app, are disabled in production by default. Sensitive files are blocked. All 35 tools are read-only.

## Design principles

1. **Read-only by design** - All 35 tools are annotated as non-destructive in the MCP protocol
2. **Defense in depth** - Multiple security layers, not single points of failure
3. **Sensitive data blocking** - Configurable patterns prevent access to secrets
4. **Offline by default** - No network calls except optional `rails_search_docs` with `fetch: true`
5. **Graceful degradation** - Missing optional dependencies don't expose errors or state

---

## SQL query safety (4 layers)

The `rails_query` tool uses a 4-layer security model:

```mermaid
flowchart LR
    Q[SQL Query] --> L1{Layer 1\nSQL gate}
    L1 -->|"Blocked:\nINSERT, DROP,\nUNION SELECT..."| R1[Rejected]
    L1 -->|SELECT only| L2{Layer 2\nDatabase Read-Only}
    L2 -->|"SET TRANSACTION\nREAD ONLY\n+ timeout"| L3{Layer 3\nRow Limit}
    L3 -->|"Cap: 1000 rows\nDefault: 100"| L4{Layer 4\nSecret Columns}
    L4 -->|"names password_digest,\napi_key, ..."| R1
    L4 -->|"no secret column"| OK[Safe Result]

    style R1 fill:#e74c3c,stroke:#c0392b,color:#fff
    style OK fill:#27ae60,stroke:#1e8449,color:#fff
    style L1 fill:#e67e22,stroke:#d35400,color:#fff
    style L2 fill:#f39c12,stroke:#e67e22,color:#fff
    style L3 fill:#3498db,stroke:#2980b9,color:#fff
    style L4 fill:#9b59b6,stroke:#8e44ad,color:#fff
```

### Layer 1 - The SQL gate: statement checks

Before any query reaches the database, the SQL gate (`RailsAiContext::SqlGate`) reads it once and answers either the text to run or a refusal with the reason. It holds every check in this layer and, on PostgreSQL, the plan checks of Layer 1b. Comments and quotes are read the way the connection's database family reads them:

- Strips comments: block (`/* */`), line (`--`), and on MySQL `#`. A comment marker inside a quoted string or identifier is data and stays. The query that runs is this stripped text, so nothing the checks did not read reaches the database. Dollar quoting (`$tag$ ... $tag$`) is a string on PostgreSQL only. SQLite and MySQL have none, so there the text between two such marks is read as code
- **Blocks write keywords**: INSERT, UPDATE, DELETE, DROP, ALTER, TRUNCATE, CREATE, GRANT, REVOKE, SET, COPY, MERGE, REPLACE. The keyword check (and the `SELECT ... INTO` table-creation check) reads **quote-masked text**, so a keyword inside a string literal is data: `... WHERE notes LIKE '%update%'` and `... = 'put into box'` are reads. `REPLACE` is matched only as the statement; the string function `replace(col, a, b)` every database has (a `REPLACE` immediately followed by `(`) is allowed. `SHOW CREATE TABLE` / `SHOW CREATE VIEW` are allowed despite the `CREATE` (see below)
- **Blocks lock clauses**: FOR UPDATE, FOR SHARE, FOR NO KEY UPDATE, FOR KEY SHARE and LOCK IN SHARE MODE, with whatever follows them (NOWAIT, SKIP LOCKED, OF, WAIT). On PostgreSQL the clause is read on quote-masked text, so `LIKE '%ready for update%'` is data: its read-only transaction refuses a locking read anyway. MySQL's read-only transaction lets `FOR SHARE` and `LOCK IN SHARE MODE` through, so there and on SQLite the raw text decides
- **Blocks SHOW forms that tell of other sessions, replication and logs**: `SHOW GRANTS`, `SHOW PROCESSLIST` and `SHOW FULL PROCESSLIST`, `SHOW BINLOG`, `SHOW BINARY LOGS` and `SHOW BINARY LOG STATUS`, `SHOW RELAYLOG EVENTS`, the `SHOW SLAVE` and `SHOW SLAVES` forms, `SHOW MASTER`, the `SHOW REPLICA` and `SHOW REPLICAS` forms, `SHOW ALL SLAVES STATUS` and `SHOW ALL REPLICAS STATUS`, `SHOW ENGINE ... STATUS`, `SHOW PROFILE` and `SHOW PROFILES`, `SHOW OPEN TABLES`, `SHOW EXPLAIN FOR` and `SHOW ANALYZE FOR`, `SHOW USER_STATISTICS`, `SHOW CLIENT_STATISTICS` and the `SHOW WSREP_` forms. `EXPLAIN FOR CONNECTION`, which on MySQL and MariaDB shows the plan of the statement another session is running, is refused with them, also as `DESCRIBE` or `DESC`, with a `FORMAT`, and inside a version comment. The answer is "Blocked: sensitive SHOW command". They are matched on the raw text, so the words inside a string literal are refused too
- **Blocks SHOW with a WHERE clause**, on every family. MySQL's statement timeout holds `SELECT` only, so a `SHOW ... WHERE` filter would run past `query_timeout`. `SHOW ... LIKE` runs. The answer names the query to use: "Blocked: SHOW with a WHERE clause is not run, because MySQL's statement timeout does not hold it. SHOW ... LIKE runs. For any other filter, SELECT from information_schema, for example `SELECT table_name FROM information_schema.tables WHERE table_schema = DATABASE()`."
- **Blocks SELECT INTO**: prevents table creation via SELECT. `INTO OUTFILE` / `INTO DUMPFILE` disk writes, and the file and network functions below, stay matched on the **raw (unmasked) text**. No read-only transaction stops a server-side file write, so one named inside a string literal is refused on every database family
- **Blocks file and network functions**: `pg_read_file`, `pg_read_binary_file`, `pg_ls_dir`, `pg_stat_file`, `lo_import`, `lo_export`, `dblink*`, `LOAD DATA`, `LOAD_FILE`, `load_extension` and their relatives, checked before and after comment stripping
- **Blocks functions that return a whole table as one value**: PostgreSQL's `table_to_xml`, `query_to_xml`, `cursor_to_xml`, `schema_to_xml`, `database_to_xml` and their `_to_xmlschema` and `_to_xml_and_xmlschema` relatives. Such a value carries every column of the table, its secret columns included, under a name no column check reads. The name with `(` after it is refused on the raw text: "Blocked: function <name> returns a whole table as one value, secret columns included. SELECT the columns you need from the table itself."
- **Blocks relations and settings that hold sampled values, other sessions' statements or stored credentials**: no check on a column's name applies to what they hold, so they are not read at all. "Relations and settings that are never read" below lists them by database
- **Blocks a function called by a quoted name**: a quoted name can spell any function, past every check in this list that reads a function's name. A name in double quotes, backticks or brackets with `(` after it is refused on every family, a `U&"..."` name with `UESCAPE` included. The answer is "Blocked: a quoted name is followed by a parenthesis, the way a function is called. rails_query reads a function's name to decide whether it runs, so write the name without quotes." A quoted column inside a call (`count("id")`) and a quoted table before `USING (...)` run
- **Blocks session-effecting / administrative functions**: a read-only transaction does not stop these, and their effect lingers on the pooled connection, so a call is matched on the raw text: the name with `(` after it is refused, inside a string literal too. A bare name inside a literal is data. PostgreSQL: `pg_terminate_backend`, `pg_cancel_backend`, `pg_reload_conf`, `pg_stat_reset*`, `pg_switch_wal`, `pg_create_restore_point`, replication-slot and -origin functions, `pg_logical_emit_message`, `pg_advisory_lock*`, `set_config`, `pg_notify`, `txid_current` and their relatives; MySQL: `GET_LOCK`, `RELEASE_LOCK`, `RELEASE_ALL_LOCKS`, `IS_FREE_LOCK`, `IS_USED_LOCK`, `MASTER_POS_WAIT`, `SOURCE_POS_WAIT`. This name list is the first layer; on PostgreSQL the plan's VOLATILE-function check (below) closes the rest of the family
- **Blocks column-alias lists**: a list such as `t(a, b, c)` renames the columns a wildcard returns, which would carry secret columns out under harmless names. The gate reads the list by its shape, on every family and in every spelling of a name (bare, double-quoted, backticked, bracketed, non-ASCII). The shapes are a parenthesised list of names after a CTE's name and before `AS`, `AS MATERIALIZED` or `AS NOT MATERIALIZED`; after `AS alias`; after the alias of a subquery written with no `AS`; and after a table's alias in a FROM clause. A type modifier (`numeric(10,2)`, `varchar(255)`), a record-function list (`AS t(a int, b text)`), a `JOIN ... USING (x, y)` list and a row comparison (`WHERE (a, b) IN (...)`) are no alias list and run. One name after a function call (`generate_series(1, 5) AS g(n)`) names the one column the function returns, so it runs. One name after a subquery is refused. A list whose body is a `VALUES` clause (`(VALUES (1,'a')) AS v(id, name)`, `WITH v(id, name) AS (VALUES ...)`) renames constants only, so it is allowed unless the body also holds a `SELECT`, a `TABLE`, a `WITH` or a set operation. A secret name written inside the `VALUES` rows is still caught by the name check. The answer is "Blocked: a column-alias list (e.g. `t(a, b, c)`) renames the columns a wildcard returns, so secret columns would leave under harmless names. Name the columns you want in the SELECT list instead."
- **Blocks multi-statements**: a semicolon with anything after it, read on quote-masked text so a `;` inside a string literal or a `DO $$ ... ; ... $$` block body is not mistaken for a second statement (a `DO` block is then refused plainly as a disallowed statement)
- **Refuses any UNION**: a UNION takes its column names from its first SELECT, so another table's rows - a wildcard's columns included - would come out under those names, past the redaction that reads names. Every spelling is refused (`UNION`, `UNION ALL`, `UNION DISTINCT`, a parenthesised `UNION (SELECT ...)`), recursive CTEs with it; `INTERSECT` and `EXCEPT` return only their first SELECT's rows and stay. On PostgreSQL a "union" inside a string literal is data
- **Blocks secret column references**: see Layer 4 - a query whose text names a secret column, directly or through an alias or expression, is refused before execution
- **Blocks a `*` inside a subquery over a secret column, on MySQL, MariaDB and SQLite**: see Layer 4
- **Allows only**: SELECT, WITH, SHOW, EXPLAIN, DESCRIBE, DESC. `SHOW CREATE TABLE` and `SHOW CREATE VIEW` are allowed so schema can be inspected; every other `SHOW CREATE` (`USER`, whose output includes credential hashes, `DATABASE`, `FUNCTION`, ...) keeps its `CREATE` and is refused. A returned definition is passed through secret redaction before it is shown, so a credential embedded in it - a FEDERATED table's `CONNECTION='mysql://user:pass@host/db'` - comes back as `mysql://[FILTERED]@host/db`

### Layer 1b - The SQL gate: PostgreSQL plan checks (planning only)

The textual layer cannot see a whole-row serialisation (`SELECT row_to_json(u.*) FROM users u`) or an admin function introduced through a view, because no secret column name appears in the query. On PostgreSQL, before the query runs, the tool plans it with `EXPLAIN (VERBOSE, FORMAT JSON)` inside the same read-only transaction - planning only, nothing executes, a VOLATILE function included (the planner does not fold one). The plan is refused when it:

- reads one of the relations or functions Layer 1 refuses by name (`pg_stats`, `pg_stat_activity`, `pg_settings` and the rest), which a view or an escaped name can reach where the text check saw nothing;
- calls a function that returns a whole table as one value, or reads a setting that can hold a password (`current_setting` with a refused name, or with a name the plan does not show as one constant);
- holds a **whole-row reference** (`alias.*`) to a relation that has a secret column - this closes `row_to_json(u)`, `to_json(u)`, `u::text`, `array_agg(u)`, `json_agg(u)`, `hstore(u)`, `concat(u.*)`, `string_agg(u::text, ...)`, a bare `SELECT u`, and the same through a view, subquery or CTE;
- **uses a secret column** anywhere but as a plain pass-through output - a `ROW(u.*)` the planner expanded into named columns, or a `WHERE` / `ORDER BY` oracle, an ordinal `ORDER BY 3` over a wildcard included;
- **passes a secret column** through an intermediate the plan's top node does not name - a `MATERIALIZED` CTE, a subquery scan, or a set operation (`INTERSECT` / `EXCEPT`) - so its value would reach a result column that the output-provenance redaction (Layer 4) cannot pin. These are refused, since no redaction could reach them. A column that a scan hands to an aggregate or a join is counted only when that node names it, so `count(*)` over a table with a secret column runs;
- names any **VOLATILE function** (`pg_proc.provolatile = 'v'`) outside a short read-only allowlist. `pg_proc` marks a function VOLATILE when its answer may change within one statement, which is as true of a reader of live server state as of a writer, so VOLATILE alone does not mean "changes state". The allowlist holds only built-in C functions that write nothing: value generators (`random`, `clock_timestamp`, `gen_random_uuid`, `timeofday`, `uuid_generate_v4`, and `pg_sleep*`, which the statement timeout bounds); the size readers (`pg_total_relation_size`, `pg_relation_size`, `pg_table_size`, `pg_indexes_size`, `pg_database_size`, `pg_tablespace_size`); the lock-table snapshot readers (`pg_lock_status` - what the `pg_locks` view reads - `pg_blocking_pids`, `pg_safe_snapshot_blocking_pids`); and the recovery / WAL-position readers (`pg_is_in_recovery`, `pg_is_wal_replay_paused`, `pg_get_wal_replay_pause_state`, `pg_current_wal_lsn`, `pg_current_wal_insert_lsn`, `pg_current_wal_flush_lsn`, `pg_last_wal_receive_lsn`, `pg_last_wal_replay_lsn`, `pg_last_xact_replay_timestamp`). The functions the statement's text names are checked beside those the plan prints, since a plan prints no row of a `VALUES` list and no `LIMIT` expression. Anything else VOLATILE is not run, and the refusal says plainly that the function is VOLATILE and outside the read-only list. This closes the admin-function family without a name list that has to grow with every PostgreSQL release.

Every statement except `SHOW` is planned, and an `EXPLAIN` is planned as the statement it explains. A statement whose plan cannot be read does not run: when planning times out the answer is the timeout, when planning fails it is the SQL error, and when the server returns no plan the statement is refused.

A whole-row read of a relation with no secret column (`row_to_json(posts.*)`) is allowed. Before these checks scan a plan expression, its string constants are masked (PostgreSQL's deparser always doubles quotes and never emits an `E''` string, so a constant is matched exactly), so a secret word inside a `'%key%'::text` filter or a literal argument is not mistaken for a column or a function.

A subquery or a join over a table that holds a secret column runs when it reads none of them. A scan under an aggregate or a join hands up every column of its table, and the plan check counts a secret column only when the aggregate or the join names it. So `SELECT (SELECT count(*) FROM users) AS n`, `count(id)`, `max(id)` and `EXISTS (SELECT 1 FROM users)` run, while `max(api_token)`, `count(api_token)`, `string_agg(api_token, ',')`, `row_to_json(users)`, a whole row and `count(users)` are refused.

#### Relations and settings that are never read

A statement that names one of these is refused on the raw text, so the name is refused inside a string literal too. Names are folded the way MySQL folds them before they are matched. The answer is "Blocked: `<name>` is not read. It holds values sampled from other tables, other sessions' statements or stored credentials, and rails_query cannot tell which of them are secret." For a relation or function that lists settings it ends " To read one setting, run SHOW with its name."

| Database | Never read | What it holds |
|:---------|:-----------|:--------------|
| PostgreSQL | `pg_stats`, `pg_stats_ext`, `pg_stats_ext_exprs`, `pg_statistic`, `pg_statistic_ext`, `pg_statistic_ext_data`, `pg_largeobject` | values sampled or copied from tables |
| PostgreSQL | `pg_stat_activity` and the functions it reads through (`pg_stat_get_activity`, `pg_stat_get_backend_activity`), `pg_stat_statements`, `pg_prepared_statements`, `pg_cursors` | other sessions' and earlier statements |
| PostgreSQL | `pg_authid`, `pg_shadow`, `pg_db_role_setting` | password hashes, and the settings stored for a role or a database |
| PostgreSQL | `pg_user_mapping`, `pg_user_mappings`, `information_schema.user_mapping_options`, `pg_subscription`, `pg_foreign_server`, `pg_foreign_data_wrapper`, `pg_foreign_table` | connection options, which can carry a password |
| PostgreSQL | `pg_settings`, `pg_show_all_settings()`, `pg_show_all_file_settings()`, `pg_hba_file_rules`, `pg_ident_file_mappings` | every setting, and the authentication files |
| MySQL and MariaDB | anything under a `mysql.` or `sys.` prefix, `performance_schema`, `global_priv` | accounts and their password hashes, other sessions' statements |
| MySQL and MariaDB | `processlist`, `general_log`, `slow_log`, and in `information_schema`: `INNODB_TRX`, `INNODB_LOCKS`, `INNODB_LOCK_WAITS`, the `INNODB_FT_` tables, `USER_STATISTICS`, `CLIENT_STATISTICS`, `PROFILING`, `OPTIMIZER_TRACE` | other sessions' statements, locked rows, indexed words |
| MySQL and MariaDB | `column_statistics`, `column_stats` | values sampled from tables |
| SQLite | `sqlite_stat1`, `sqlite_stat3`, `sqlite_stat4` | values sampled from indexes |

The names are matched as whole words on every family, so an app table or alias that carries one (`slow_log`, an alias `mysql` before a dot) cannot be queried. The `information_schema` names in the MySQL row are matched only under that schema, so an app's own `user_statistics` table runs. `pg_file_settings` is refused with the file functions.

On PostgreSQL the plan is checked for the same names, as relations and as functions, so a view over one is refused: `information_schema.user_mappings`, `information_schema.foreign_servers` and `pg_stat_subscription` are refused that way. `pg_authid`, `pg_shadow` and `pg_db_role_setting` are the exception. A view over them runs, and their `rolpassword` and `setconfig` columns are secret columns: `pg_roles`, `pg_user` and `information_schema.schemata` run, `SELECT rolconfig FROM pg_roles` comes back `[FILTERED]`, and an expression over either column is refused.

PostgreSQL settings are read one at a time, and the ones that can hold a secret are refused:

- `primary_conninfo`, `ssl_passphrase_command`, `archive_command`, `restore_command`, `archive_cleanup_command` and `recovery_end_command` are refused through `SHOW` and through `current_setting`. So is a setting whose own name reads as a secret by the rule of Layer 4, such as `app.jwt_secret`. The answer is "Blocked: the setting `<name>` is not read. It can hold a password, a key or a command line that carries one." The six names are refused wherever they stand in a statement, inside a string literal too, on every family
- `SHOW ALL` is refused on PostgreSQL: "Blocked: SHOW ALL is not run. It lists every setting, the ones that can hold a password among them. SHOW one setting by its name."
- `SHOW` has no plan, so on PostgreSQL its name has to be plain: "Blocked: SHOW takes a setting's plain name on PostgreSQL, with no quotes around it, for example `SHOW work_mem`." `SHOW TIME ZONE` and `SHOW TRANSACTION ISOLATION LEVEL` run
- `current_setting` is refused unless its first argument is one plain string, in the text and in the plan: "Blocked: current_setting runs only with the setting's name written as one plain string, for example `current_setting('work_mem')`, so that rails_query can read which setting it returns."

Stated limits:

- **A function whose name needs quotes cannot be called.** A mixed-case function on PostgreSQL is one. Its name cannot be written without quotes, and a quoted name before a parenthesis is refused.
- **MySQL and MariaDB variables still run.** `SHOW VARIABLES`, `@@name` and MariaDB's `information_schema.GLOBAL_VARIABLES`, `SYSTEM_VARIABLES` and `SESSION_VARIABLES` are read as written.
- **Relations of third-party PostgreSQL extensions are not named.** Beyond `pg_stat_statements`, an extension's relation that holds statement text or sampled values is not in the list.

### Layer 2 - Database-level read-only

After validation, the query runs through its database family, which knows how its database spells a read-only transaction and a statement timeout:

| Family | Mechanism | A timeout arrives as |
|:-------|:----------|:---------------------|
| PostgreSQL (and PostGIS) | `SET TRANSACTION READ ONLY` + `SET LOCAL statement_timeout` | `ActiveRecord::QueryCanceled` |
| MySQL (mysql2 and Trilogy) | `SET TRANSACTION READ ONLY` + the session's `max_execution_time`, read first, set for the statement and put back afterwards, also when the statement fails | `ActiveRecord::StatementTimeout` (3024), sometimes `QueryCanceled` (1317) |
| MariaDB | `SET TRANSACTION READ ONLY` + the session's `max_statement_time`, read first, set for the statement and put back afterwards (MariaDB has no `max_execution_time` and ignores MySQL's hint) | native code 1969 |
| SQLite | A read-only connection in a child process, killed at timeout | the gem's own timeout |

What bounds each statement a `rails_query` call sends:

| Statement | PostgreSQL | MySQL and MariaDB | SQLite |
|:----------|:-----------|:------------------|:-------|
| The query, and `explain: true` | `statement_timeout`, a wait on a lock included | the session's statement limit, and `lock_wait_timeout` for a wait on a lock | the child process's deadline |
| The reads beside it: the schema read behind the secret column rule, and on PostgreSQL the plan, its `pg_proc` lookup and the column trace | `statement_timeout`, a wait on a lock included | the session's statement limit, and `lock_wait_timeout` for a wait on a lock | no statement limit; a wait on another writer ends at the connection's busy timeout |

The query has `query_timeout` to itself. The reads beside it share a second `query_timeout`, and each is charged the time it ran, so the statements of a call take about twice `query_timeout` at most. A read that runs out of that time is the call's timeout answer. Building the app's context, which a cold call does first, is charged to neither. The schema read is three statements at most whatever the number of tables.

Stated limits of the time bound:

- **MySQL and MariaDB lock waits are whole seconds.** Their statement limit does not cover `EXPLAIN` or `SHOW`, so the session's `lock_wait_timeout` is set too and put back afterwards. It takes whole seconds, so a wait on a lock ends at `query_timeout` rounded up to the next second.
- **SQLite's reads beside the query have no statement limit.** They run on the app's own connection, where a wait on another writer ends at that connection's busy timeout (`timeout` in `config/database.yml`; with none, a busy database fails at once).
- **A SQLite statement on the app's own connection cannot be ended in the middle of one long step.** The paragraph on that path below says when a statement runs there.
- **PostgreSQL has no client read timeout.** `statement_timeout` is the server's to keep. A PostgreSQL server that goes silent after it connects is not ended by the client.

A database leased by name connects with the `connect_timeout` of its `config/database.yml` entry, or `query_timeout` rounded up to whole seconds when the entry sets none, so a server that never answers the connection ends the call. On MySQL and MariaDB such a connection also gets a `read_timeout` of twice `query_timeout` plus 5 seconds unless its entry sets one, so a server that goes silent after the handshake ends the call. On PostgreSQL `connect_timeout` is the only client bound. Taking the lease down does not replace the outcome of the call: its connections are thrown away and its pool removed, and an error there is not raised. The primary uses the app's own pool and its settings.

The MySQL session variable bounds a statement that starts with `WITH` or `EXPLAIN ANALYZE` too; the `MAX_EXECUTION_TIME` hint binds only the outermost `SELECT`, so it is not used. `query_timeout` is a positive number, and PostgreSQL, MySQL and MariaDB bound a value under a millisecond at one millisecond. A timeout is read from the error's class or the database's native code alone, so an SQL error whose message names a column called `timeout` is reported as an SQL error. A wait that PostgreSQL's own `lock_timeout` ended is answered as the timeout. A connection the server dropped is no timeout: on Rails 7.1 and later the answer is an error that starts "The <name> database stopped answering during the query:".

On PostgreSQL and MySQL the query executes inside a transaction, then rolls back (even if it could write, it can't). MySQL's read-only transaction still lets `FOR SHARE`, `LOCK IN SHARE MODE` and `INTO` through, so the Layer 1 checks stay on every family.

On a connection that is already inside a transaction (a tool called from a transactional test, a mounted server inside a request's transaction) the guard leaves that transaction as it found it. PostgreSQL guards inside a savepoint, so the outer transaction stays writable. MySQL and MariaDB cannot make an open transaction read-only, so the statement is not sent and the answer is "Query failed: MySQL cannot make a transaction that is already open read-only, so the statement was not sent. Run it outside the transaction." SQLite runs the statement in its child process and leaves the transaction alone.

An adapter with no family (SQL Server, Oracle, CockroachDB and any other) is refused: `rails_query` answers with the adapter's name and sends no statement, because it cannot give that database a read-only transaction and a timeout it has verified. The family is read from the database's configuration, so the refusal comes before any connection is opened or verified. CockroachDB's adapter is built on PostgreSQL's, but the adapter's name alone chooses the family, so it is refused too.

A SQLite database whose file is not there is refused by name before anything
connects, with or without a `database` argument, since connecting would create
the file. The answer names `bin/rails db:prepare`.

A SQLite statement runs on the app's own connection, under `PRAGMA query_only = ON`,
in three cases: an in-memory database, a platform without `fork`, and a statement
the child process could not prepare. The third is a statement that needs a
function, virtual-table module, collation, temporary table or encryption key only
the app's own connection has. That case is told from which step failed in the
child, and the error's text is not read. A statement the child prepared and that
fails while it runs is answered with its SQL error and is not run again. On the
app's own connection a statement that returns rows slowly ends at `query_timeout`
with the timeout answer. One long step cannot be ended there: the sqlite3 driver
holds the interpreter lock while a statement steps, and an interrupt lands only
between two rows. So the table and EXPLAIN answers of such a run say it ran
without a time limit. CSV output stays plain data.

On sqlite3 1.x a query fails at its timeout, with the statement-timeout error,
when another connection in the same process held an exclusive lock on a
rollback-journal database as it started (`BEGIN EXCLUSIVE`): the child
inherits that lock record and it never clears. A lock held
by another process is waited on as usual, and an open write transaction or any
lock in WAL mode does not block it.

### Layer 3 - Row limit

- Default: 100 rows
- Configurable: `config.query_row_limit` (hard cap: 1000)
- Applied as a `LIMIT` clause appended to the query, which fetches **one row past the cap** (`cap + 1`): a `LIMIT` or `FETCH FIRST` that ends the query is rewritten to `min(n, cap + 1)`, and one inside a subquery is left as written. `LIMIT ALL`, `LIMIT NULL` and a negative limit mean no limit, so they are rewritten to `cap + 1`
- The rows that come back are cut to the cap, so the answer holds it whatever the database made of the text
- The note that rows were held back is added **only when more than the cap came back** - the extra row proves the cap actually cut the answer - then the extra row is dropped. A result that exactly fills the cap (every row fit) gets no note. The note reads `100 rows shown; the query returned more (the row limit of 100; pass limit: up to 1000 to see more).` and rides every format; in CSV it sits after a blank line, outside the comma block, so a parser still reads clean rows
- CSV output with no rows is the header row alone

### Layer 4 - Secret column rejection

A query that names a secret column is **rejected before execution**, and a secret column's values are redacted where a `SELECT *` returns them. One rule (`RailsAiContext::SecretColumns`) decides what is secret, used by the pre-execution refusal, the PostgreSQL plan check and result redaction alike. A column is secret when it is:

- in `config.query_redacted_columns`, or the fixed built-in list;
- an `encrypts` column of one of your models;
- a name the heuristic catches: it ends in `password`, `secret`, `token`, `key`, `digest` or `hash`, or contains `password`, `secret`, `token` or `nonce`, or is `iv` or ends in `_iv`;
- a name the shared log and config redaction treats as secret (`passwd`, `salt`, `credentials`, `pepper`, `signing_key` and the rest of its secret words), so a word added there is secret here too;
- a generated column whose expression reads a secret column (described further down)

minus anything in `config.query_allowed_columns`. An `encrypts` column is the exception: it is a secret column whatever that list holds. A query that names it is refused, the refusal says the allowed list does not release it, and its values stay `[FILTERED]`.

**Default redacted patterns:** `password_digest`, `encrypted_password`, `password_hash`, `reset_password_token`, `confirmation_token`, `unlock_token`, `otp_secret`, `session_data`, `secret_key`, `api_key`, `api_secret`, `access_token`, `refresh_token`, `jti`. Those are the defaults of `config.query_redacted_columns`. The fixed built-in list adds `password_reset_token`, `remember_token`, `secret`, `private_key`, `authentication_string`, `rolpassword` and `setconfig`. The last three are where MySQL and PostgreSQL keep password hashes and stored settings.

The pre-execution refusal matches on two things, as whole identifiers. Names are folded the way the databases compare them: lowercase, with MySQL's reading of a dotted capital I as `i`.

- **the fixed names above**, on every family whether or not they are real columns;
- **every real column of your schema that the rule flags** - read from the connection the query runs on, so a database named with `database` is checked against its own columns. This catches an app-specific column the heuristic flags (`api_token`, `auth_token`) through any alias or expression. Rails' own bookkeeping tables (`ar_internal_metadata`, `schema_migrations`) are left out: their columns hold no secrets, and `ar_internal_metadata.key` ends in "key", so counting it would refuse every query whose text held the word "key".

The schema read fails closed. When the columns of the database cannot be read, no query runs on it and the answer is "The columns of the <name> database could not be read, so its secret columns cannot be told and no query runs on it." Only the primary falls back to the cached context's schema, and it is refused the same way when that has no tables either.

So `SELECT password_digest AS pd FROM users`, `SELECT upper(api_token) FROM users` and `SELECT (SELECT api_token FROM users LIMIT 1) AS leaked` are all refused: post-execution redaction reads the output column names, which the caller controls through aliases and expressions, so it cannot be relied on. The refusal starts "Blocked: query references secret column `api_token`." and says how to release a name that holds no secret. A table or alias that merely contains a secret word (a `tokens` table) does not trip the check - only a real column name does. `SELECT *` stays allowed, and its secret columns are redacted in the result.

A secret word inside a **string literal** - a `LIKE '%secret%'` pattern, a JSON key `->>'token'` - is data. On PostgreSQL the check runs on literal-masked text, and the plan layer (Layer 1b) then has to vouch: a query that passed only because a name sat inside a literal runs only when its plan was obtained and cleared every check, so a masker fooled by a quote trick (`standard_conforming_strings` off, an `E''` string) is not the only guard. A statement with no plan to read, such as `SHOW`, keeps the raw-text refusal. On MySQL, MariaDB and SQLite the match stays on raw text with no masking, because a quote's meaning there depends on server modes (`NO_BACKSLASH_ESCAPES`, `ANSI_QUOTES`) or a dotted single-quoted name is an identifier (`t.'col'`).

If one of your own columns merely looks secret (an `oauth_applications.secret`, say), exempt it by name:

```ruby
config.query_allowed_columns = %w[secret]
```

Results are redacted as well: a returned column comes back as `[FILTERED]` when the rule flags its **output name**, and on PostgreSQL when its origin is a secret base column - either by **provenance** (`PG::Result#ftable` / `#ftablecol`, mapped to the base column) or by the **plan's top-node `Output`**, whose i-th expression is result column i. The plan path catches a view (or inlined CTE/subquery/join) that renamed a secret column to a harmless name: `CREATE VIEW user_tokens AS SELECT id, api_token AS t FROM users; SELECT t FROM user_tokens` returns `t` as `[FILTERED]`. A quoted mixed-case secret column (`"Salt"`) is filtered in place the same way. A result column whose table's column names cannot be read is filtered when that table holds a secret column. When the table cannot be told either, it is filtered when any table holds one. On SQLite a second result column of the same name comes back as `name:1`, and the rule reads that name without its suffix. `SHOW`, `DESCRIBE` and `EXPLAIN` output skips column-name redaction; the one exception is `SHOW CREATE TABLE` / `SHOW CREATE VIEW`, whose definition text is run through the shared secret redaction so a credential embedded in it is filtered.

MySQL, MariaDB and SQLite trace no result column to its table column, so there two more refusals stand in for the plan checks:

- **A view is checked by its definition.** A statement that names a view is refused when the view's definition names a secret column, when the view is built on such a view, when it lists every column (`*`) of a table that holds a secret column, or when its definition cannot be read on a database that holds secret columns. The definition is read with its comments taken out, so a secret column's name inside a comment refuses nothing, and a view's name is matched as an identifier whatever characters it holds. The refusal names the view and the reason, such as "its definition names the secret column `api_token`", and the tables the view reads can be queried instead. `SHOW CREATE VIEW` still prints the definition.
- **A `*` inside a subquery is refused when the statement names a table that holds a secret column.** With no plan to read, a value the wildcard returns could be compared or renamed unseen. The answer is "Blocked: a `*` inside a subquery reads every column of `<table>`, which holds the secret column `<column>`. On <family> a value read that way can be compared or renamed past the redaction, so name the columns in the subquery." A CTE body, a derived table and MySQL's `(TABLE t)` all count. `EXISTS (SELECT * ...)` returns no column and `count(*)` reads none, so both run.

Stated limits on MySQL, MariaDB and SQLite, where no plan is read: `SELECT * FROM t INTERSECT SELECT <a guessed row>` (and `EXCEPT`) tells whether a whole row equals the guess, and an ordinal `ORDER BY 3` over a wildcard tells the order of a secret column's values. Neither returns a value: the secret columns of the rows that come back are `[FILTERED]`. PostgreSQL refuses both by the plan.

On every family a generated column whose expression reads a secret column is a secret column itself: a statement that names it is refused and its values come back `[FILTERED]`. SQLite stores no expression per column, so there every generated column of a table is a secret column once any expression in the table's definition reads one. `config.query_allowed_columns` releases a generated column, or a column a view reads, by name, unless it reads an `encrypts` column.

A stored procedure or function is a stated limit: its body is not read, so a value it returns is filtered by its output name only.

The exemption covers the results too: an allowed name comes back unredacted. A
column declared with `encrypts` is refused by name and stays `[FILTERED]` either
way: an encrypted-at-rest attribute is not meant to be read back raw.

### Environment guard

> [!WARNING]
> Disabled in production by default. Only enable with `config.allow_query_in_production = true` if you understand the implications.

---

## Sensitive file blocking

The `rails_search_code` and file-reading tools block access to sensitive files:

### Default patterns

```text
.env .env.* *.env .envrc
config/master.key
config/credentials.yml.enc config/credentials/*.yml.enc
config/database.yml config/secrets*.yml config/secrets*.yml.enc
config/application.yml
config/settings.local.yml config/settings/*.local.yml
config/cable.yml config/storage.yml
config/mongoid.yml config/redis.yml
*.pem *.key *.p8 *.p12 *.pfx *.jks *.keystore
**/id_rsa **/id_ed25519 **/id_ecdsa **/id_dsa
.ssh/* .aws/credentials .aws/config .netrc .pgpass .my.cnf
```

A placeholder whose name ends in `.example`, `.sample`, `.template` or
`.dist` (`.env.example`) is committed to be read, so a basename glob such as
`.env.*` does not block it. A pattern that names it exactly, with no glob
characters, still does, and so does a path pattern (one with a `/`, such as
`.ssh/*`), which covers everything under it.

### AI context file exclusions

Search also excludes generated AI context files to prevent circular references:

```
CLAUDE.md, .claude/, .mcp.json
.cursor/, .cursorrules
.github/copilot-instructions.md, .github/instructions/, .vscode/mcp.json
AGENTS.md, opencode.json
.codex/
.ai-context.json
```

### Configuration

```ruby
config.sensitive_patterns = %w[.env* *.key *.pem credentials.yml.enc]
```

---

## Path traversal protection

All file-reading operations validate paths against `Rails.root`:

```ruby
real_path = File.realpath(requested_path)
root = File.realpath(Rails.root.to_s)
raise unless real_path == root || real_path.start_with?(root + File::SEPARATOR)
```

A path may also resolve into a directory the app links in from its own git repository, as
described under "Links in and out of the app" below. The VFS
(`rails-ai-context://views/{path}`) applies the same protection for view template reads.

### Links in and out of the app

A symlink inside the app is followed when it leads into the app root, or into the engine its
`test/dummy` runs in, and a directory link is also followed when it leads anywhere inside the
git work tree that holds the app. A monorepo's shared package linked into `packs/` or
`app/javascript/controllers` is read as the app's own, under the path the app gives it
(`packs/billing/app/models/invoice.rb`). A file reached through such a directory is read only
when its real path stays inside the app or inside that directory. Outside a git repository
nothing marks where the project ends, so only links that stay inside the app root are
followed. A link to anywhere else, a home directory included, is not followed: the file is
neither listed nor read. A link that resolves nowhere is not listed either.

The walks over app code follow a linked-in directory where Rails does: the trees Zeitwerk
autoloads (models, controllers, jobs, mailers, channels, helpers, components, concerns,
policies and the rest of `app/`, packs and in-repo engines included), the view resolver's
templates and layouts, and the JavaScript roots a bundler reads. A file Rails finds with a
glob of its own is found the way that glob finds it, entering no linked directory below where
it starts: initializers, locale and environment files, migrations, seeds, rake tasks, test
files and mailer previews. Among those, a linked file is read only when it stays inside the
app.

A tool handed a path that leads out of the app refuses it, and so does a tool that resolves a
name to one file - a log, a partial, a concern - when that file leads out; see "How a refusal
is reported" below. A tool that answers from what the walks found, such as
`rails_get_stimulus`, never lists a file a link carries out, and asked for that controller by
name answers that it is not there. A path into a linked-in directory is accepted wherever a
path is (`packs/billing/app/models/invoice.rb`), and the sensitive patterns are matched
against the file's name inside that directory as well as the app's. `rails_search_code`
searches the linked-in directories too.

Booted, a class Rails loaded through a link out of the app is still described from what
reflection answers, such as a job's queue name; only its file goes unread.
`rails_security_scan` hands the app to Brakeman, which reads it by its own rules.

### Frontend roots outside the app

Two directories outside `Rails.root` are read, for frontend manifests only: each
`frontend_paths` entry you configure (`../web-client`), and the JS workspace root
above the app (the nearest ancestor holding a lockfile or declaring `workspaces`,
never above the git root and never outside a git repository). Only `package.json`,
lockfiles and the presence of a bundler config (`vite.config.*` and similar) are
read there, plus a configured entry's `tsconfig.json` and the configs it extends
inside that same directory. Sensitive patterns and symlink containment apply relative to that
directory, and the `frontend` section of `rails_get_config` names it in its answer.

### The bundle config/boot.rb declares

An app with no lockfile of its own (an engine's `test/dummy`) has its gems in the
Gemfile its `config/boot.rb` sets as `BUNDLE_GEMFILE` (`../../Gemfile`). That
Gemfile and its lockfile (`gems.rb` and `gems.locked` alike) are read with the same
trust as the app's own `Gemfile.lock`, only when their directory is inside the app's
git repository, never above its root and never outside a repository. Besides those two,
only a file that Gemfile names with `eval_gemfile` inside that directory, and the `lib/`
of a path gem the lockfile names inside the repository (the engine's own `remote: .`),
are read. A file there that links out of the directory is refused.

### The engine an app's test/dummy runs in

Booted from an engine's `test/dummy`, the engine whose root holds the app root (a loaded
`Rails::Engine`, never this gem) is the project's own source: its `app/` code, its
`app/views` layouts and templates, and, when the dummy keeps no `test/` or `spec/` of its
own, its test suite are read. Paths into it are printed relative to the app root
(`../../app/models/...`), and symlink containment applies relative to the engine root.
Without booting, only the test suite is read this way, and only from the directory of the
bundle `config/boot.rb` declares (read under the rule above) when it holds a `*.gemspec`
and contains the app root.

### How a refusal is reported

A path refused on policy - outside the app, a traversal, a sensitive file - comes back as an
error result: `isError: true` over MCP, exit 1 from the CLI, and the text starts with
`Path not allowed: <path>`, followed by `(sensitive file)` when the name is the reason. A
path that is simply not there is an ordinary answer and exits 0, so a script can tell the two
apart. `rails_validate`, which answers for several files at once, says `Path not allowed` on
the refused file's own line; a file it cannot validate, refused or missing, fails the
validation, so that answer is an error result either way.

The same holds for a name a tool turns into a file: a log (`rails_read_logs file:`), a partial
(`rails_get_partial_interface partial:`) or a concern (`rails_get_concern name:`) whose file
links out of the app is refused, not reported missing. A list of what a tool can read, such
as the available logs or partials, leaves out every entry it would refuse. `rails_diagnose` still diagnoses the error it is given when the `file:` it is
pointed at is refused, says so, and returns the whole answer as an error result.

---

## Command injection prevention

Search tools use array-based command execution (never shell strings):

```ruby
# Safe: array form
Open3.capture3("rg", "--no-heading", "--", pattern, directory)

# Pattern injection prevented by -- separator
```

File type parameters accept only alphanumeric characters.

An argument git would read as an option never reaches it: `rails_review_changes`
resolves its `ref` to a commit first (`git rev-parse --verify <ref>^{commit}`)
and hands git that commit's SHA. A ref that starts with a dash is refused, so
`--output=<path>` cannot make `git diff` write a file.

---

## Regex injection prevention

On Ruby 3.2 and newer, user-supplied regex patterns have a 1-second timeout (2 seconds in the Ruby search fallback):

```ruby
Regexp.new(pattern, timeout: 1)
```

Complex patterns that would cause catastrophic backtracking raise `RegexpError` instead of hanging.

> [!WARNING]
> `Regexp.timeout` does not exist on Ruby 3.1, which this gem still supports. There the timeout is skipped, and a pattern crafted to backtrack catastrophically can hang the process serving the tool. If you expose `rails_search_code` to input you do not control, run it on Ruby 3.2 or newer.

---

## Safe file reading

`SafeFile.read` provides drop-in safety for all file reads:

- Size limit enforcement (`config.max_file_size`, default: 5 MB)
- Returns `nil` on any failure (no exceptions leak)
- UTF-8 encoding with invalid/undefined byte replacement
- Handles: ENOENT, EACCES, EISDIR, ENAMETOOLONG, SystemCallError

---

## Redaction

Everything that leaves your app through this gem - log lines, query rows, environment values, config source slices - passes through one redaction module before anything else can touch it. Redacting and shortening are a single operation there, so a long credential cannot be cut apart in a way that hides it from the pattern that would have caught it.

What gets redacted:

- Passwords, tokens, secrets and API keys, wherever they are named
- The same in the app's own source a tool or resource shows: a method body, a template, a test file, a scan's code line, a change's diff (where a file on `sensitive_patterns` shows none of its lines)
- Credentials embedded in URIs (`redis://user:pass@host`)
- Email addresses in log lines, in any script (`jürgen@example.com`, `anna@münchen.de`)
- Values assigned to secret-named settings in initializers

### Markers

Redacted values carry one of two markers, and only these two:

| Marker | Means |
|--------|-------|
| `[FILTERED]` | A value was removed because it is or may be a secret |
| `[EMAIL]` | An email address was removed |

Marker presence and this vocabulary are part of the output contract (see below) - you can pattern-match on them.

---

## Output contract

**Contract, safe to depend on:**

- Tool names and their input schemas
- The presence of a redaction marker wherever a value was removed
- The `[FILTERED]` / `[EMAIL]` marker vocabulary

**Incidental, expected to change between releases:**

- Response text, headings and formatting
- Refusal and unavailability wording
- Row and section ordering

Pin your assertions to the first list. When something in the second list changes in a way that could break a pinned assertion, the CHANGELOG says so.

---

## Migration safety

The `rails_migration_advisor` tool validates input:

- Table and column names must be safe identifiers
- Warns about duplicate columns
- Warns about nonexistent tables
- Checks reversibility

---

## MCP HTTP transport

No HTTP entry point authenticates a client: every tool answers whoever reaches the endpoint.

**Inside the app** - the mounted engine and `auto_mount` - the endpoint is on your app's own web server, so it is as reachable as the app is. In every environment but development and test - production, and a staging app the network reaches the same way - both refuse every request with a 403 and a JSON-RPC error that says how to opt in, and log the refusal once. `config.allow_http_in_production = true` lets them answer there. Set it only with the endpoint behind your app's authentication, such as a routes constraint around the mount. `auto_mount` answers before routing, so nothing in the app can guard it, and doctor's "MCP HTTP endpoint" check fails that pair. With the option on and the engine, it warns.

Both answer the hosts the app's `config.hosts` allows, judged by Rails' own HostAuthorization with its `host_authorization` exclusions, as every other route of the app is: `myapp.localhost` and any IP address in development, the app's own names in production, every host when `config.hosts` is empty. A host it does not allow, such as a DNS rebinding attacker's domain, gets 403 "Forbidden: Invalid Host header", and a browser's request from another origin gets 403 "Forbidden: Invalid Origin header". The MCP SDK's own check, which answers only `127.0.0.1`, `::1` and `localhost`, is off for these two.

**The standalone server** - `rails-ai-context serve --transport http` and `rails ai:serve_http` - is its own process and binds `127.0.0.1` by default. `http_bind` can open it to the network, still with no authentication. The MCP SDK answers only requests whose `Host` header is `127.0.0.1`, `::1` or `localhost`, which stops a DNS rebinding attack from a browser but not a client that sends `Host: localhost` itself; a client that addresses the machine by IP or name gets 403 "Invalid Host header". So a non-loopback bind suits a container whose port is published to the host, where the client still connects to `localhost`. The server says so on stderr when it starts. On an MCP SDK too old to check the `Host` header, every tool answers whoever reaches the port.

`auto_mount` is `false` by default, and the engine exists only where you mount it. Mount it guarded, `if defined?(RailsAiContext::Engine)`, so the routes file still loads where the gem is not installed.

The engine builds one transport per process, under a mutex, outside the controller class, and the app's code reloader never replaces that class, so a session lasts across edits in development.

---

## Credential handling

- `rails_get_config(section:"env")` returns credential **keys** and no values
- The process's environment variable values are never read. A default written in code, and a placeholder from `.env.example`, `.env.sample` or `.env.template`, is shown after redaction
- `config/credentials/*.yml.enc` is in the sensitive patterns list

---

## Reporting vulnerabilities

Email crisjosephnahine@gmail.com. Response within 48 hours.

Supported versions: only the latest 5.x release gets security fixes. See the repo root `SECURITY.md` for the full policy.

---

<div align="center" markdown="1">

**[← Introspectors](INTROSPECTORS.md)** · **[CLI Reference →](CLI.md)**

[Back to Home](index.md)

</div>
