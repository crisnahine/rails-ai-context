# rails_query runs only on a database family it can guard

Status: accepted

`rails_query` promises two guards the database itself enforces: a read-only transaction and a statement timeout. Each engine spells both differently, and some cannot give one at all, so the tool runs a statement only where it knows the spelling. A **database family** is that knowledge: one per engine kind, chosen once from the connection, and the only place an engine's read-only and timeout rules live.

## Decision

- Three families: PostgreSQL (PostGIS too), MySQL (Trilogy and MariaDB too) and SQLite. Any other engine gets a refusal that names its adapter before anything reaches the database. Statistics answers (table sizes, row estimates, index usage) say "not available" for it instead.
- A family is claimed by the adapter's name, as `adapter_name` and database.yml spell it, never by class ancestry. CockroachDB's adapter subclasses PostgreSQL's, but it has no `EXPLAIN (FORMAT JSON)` and its own read-only rules, so it is refused until someone verifies them.
- The timeout per family:
  - PostgreSQL: `SET LOCAL statement_timeout` inside the read-only transaction.
  - MySQL: the session's `max_execution_time`, read first, set for the statement and restored after. The `MAX_EXECUTION_TIME` hint binds only the outermost SELECT, so a statement that starts with WITH or EXPLAIN ran unbounded.
  - MariaDB: `SET STATEMENT max_statement_time = N FOR <statement>`. MariaDB ignores the MySQL hint and has no `max_execution_time`.
  - SQLite: a forked child with a deadline, since sqlite3-ruby cannot interrupt a statement.
- A timeout is recognised by `ActiveRecord::QueryAborted` (QueryCanceled, StatementTimeout) or by the engine's native code. MariaDB's 1969 has no Rails class in any version. Message text is never read: a missing column named "timeout" is an error, not a timeout.
- The read-only transaction is not the only guard. MySQL's lets `FOR SHARE`, `LOCK IN SHARE MODE`, `INTO @var` and `INTO OUTFILE` through, so the statement checks before execution stay, on every family.

## Consequences

Apps on SQL Server, Oracle or CockroachDB lose `rails_query`; on SQL Server and Oracle it never ran a statement correctly anyway, since its row cap appends `LIMIT`. Supporting a new engine means adding a family with its own read-only and timeout spelling, verified against the real engine, not widening a name match.

## Alternatives not taken

- **Running other engines on the statement checks alone**: the tool's description promises database-level guards, and a check on text is not one.
- **Classifying by class ancestry**: it would admit an engine whose guards nobody has run.
- **Injecting the MySQL hint after a WITH list**: it needs a parse of the statement to find the outermost SELECT. The session variable needs none, and it bounds EXPLAIN ANALYZE too.
