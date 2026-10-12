# rails_query runs only on a database family it can guard

Status: accepted

`rails_query` promises two guards the database itself enforces: a read-only transaction and a statement timeout. Each database server spells both differently, and some cannot give one at all, so the tool runs a statement only where it knows the spelling. A **database family** is that knowledge: one per kind of database, chosen once from the connection, and the only place a database's read-only and timeout rules live.

## Decision

- Three families: PostgreSQL (PostGIS too), MySQL (Trilogy and MariaDB too) and SQLite. Any other adapter gets a refusal that names it before anything reaches the database. Statistics answers (table sizes, row estimates, index usage) say "not available" for it instead.
- A family is claimed by the adapter's name alone, as `adapter_name` and database.yml spell it. CockroachDB's adapter subclasses PostgreSQL's, but it has no `EXPLAIN (FORMAT JSON)` and its own read-only rules, so it is refused until someone verifies them.
- The timeout per family:
  - PostgreSQL: `SET LOCAL statement_timeout` inside the read-only transaction, at one millisecond or more, since zero turns the timeout off.
  - MySQL: the session's `max_execution_time`, read first, set for the statement and restored after. The `MAX_EXECUTION_TIME` hint binds only the outermost SELECT and leaves a statement that starts with WITH or EXPLAIN with no bound, so it is not used.
  - MariaDB: the session's `max_statement_time`, read first, set for the statement and restored after. MariaDB ignores the MySQL hint and has no `max_execution_time`.
  - SQLite: a forked child with a deadline, since sqlite3-ruby holds the interpreter lock while a statement steps and nothing in the process can end it. A statement the child cannot prepare runs on the app's own connection, where a watchdog's interrupt ends one that returns rows slowly.
- What bounds each kind of statement a call sends:
  - The query and `explain: true` have `query_timeout` to themselves: `statement_timeout` on PostgreSQL, the session's statement limit with `lock_wait_timeout` on MySQL and MariaDB, the child's deadline on SQLite.
  - The reads beside the query (the schema, the PostgreSQL plan with its `pg_proc` lookup, the column trace) run in a block the family bounds the same way. They share a second `query_timeout`, and each is charged the time it ran. On SQLite they run on the app's own connection with no statement limit, and a wait on another writer ends at its busy timeout.
  - `rails_runtime_info`'s table sizes, index usage and pending migrations each run in such a block with `query_timeout` of their own.
- Stated limits of the bound:
  - SQLite cannot end one long step on the app's own connection: an interrupt lands only between two rows. That run is reported as one without a time limit.
  - PostgreSQL has no client read timeout. `statement_timeout` is the server's to keep, so a server that goes silent after it connects is not ended by the client. A leased MySQL or MariaDB connection gets a `read_timeout` of twice `query_timeout` plus 5 seconds unless its entry sets one.
  - MySQL and MariaDB take `lock_wait_timeout` in whole seconds. It is set because their statement limit does not cover `EXPLAIN` or `SHOW`, and a wait on a lock ends at `query_timeout` rounded up to the next second.
  - MySQL's statement limit holds `SELECT` only, so the gate refuses `SHOW` with a `WHERE` clause on every family.
- A timeout is recognised by `ActiveRecord::QueryAborted` (QueryCanceled, StatementTimeout) or by the database's native code. MariaDB's 1969 has no Rails class in any version. Message text is never read, so a missing column named "timeout" is reported as an SQL error.
- The statement checks before execution stay on every family. MySQL's read-only transaction lets `FOR SHARE`, `LOCK IN SHARE MODE`, `INTO @var` and `INTO OUTFILE` through, so it cannot be the only guard.
- Only PostgreSQL traces a result column to its table column, through the statement's plan, so there a statement runs only with a plan. MySQL, MariaDB and SQLite have no such trace. There a view is checked by the definition the database stores and refused when it names a secret column, and a `*` inside a subquery is refused when the statement names a table that holds one.
- A guarded read leaves an open transaction as it found it: a savepoint on PostgreSQL, and a refusal on MySQL and MariaDB, which cannot make an open transaction read-only.

## Consequences

Apps on SQL Server, Oracle or CockroachDB have no `rails_query`. On SQL Server and Oracle the `LIMIT` its row cap appends is a syntax error, so a query without its own row limit fails there. Supporting another database means adding a family with its own read-only and timeout spelling, verified against a real server.

## Alternatives not taken

- **Running other adapters on the statement checks alone**: the tool's description promises database-level guards, and a check on text is not one.
- **Classifying by class ancestry**: it would admit a database whose guards nobody has run.
- **Injecting the MySQL hint after a WITH list**: it needs a parse of the statement to find the outermost SELECT. The session variable needs none, and it bounds EXPLAIN ANALYZE too.
