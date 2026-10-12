# Take dbhub's shapes, not dbhub

Status: accepted

bytebase/dbhub is a database MCP server: one connector per engine, named sources, a single read-only policy, and two tools by default. The 2026-10 architecture review read this gem through it and asked whether `rails_query` should hand its work to dbhub outright.

## Decision

- `rails_query` stays the gem's own. dbhub needs Node 22.5 or later, while this gem is pure Ruby. dbhub connects by DSN; `rails_query` runs on the app's own connection, so database.yml, SSL settings, SQLite extensions and app-registered functions all apply. dbhub returns column values unredacted, and the **secret column** rule is this tool's main safety property. The production guard and the static-tier refusal would also go.
- The shapes come over:
  - one adapter per **database family** (dbhub's connector), ADR-0008;
  - one list of **App databases** with the primary first (dbhub's named sources);
  - one module deciding what a statement may do (dbhub's access policy): the **SQL gate**, with the **secret column** rule beside it;
  - one answer to which tools are served;
  - a short default tool list, through **config sections** (ADR-0010).
- A non-primary database is reached through a `database` argument on the tools that run SQL, never through a tool per database. dbhub registers `execute_sql_<source>` per source, but here that adds tool definitions to every turn and goes stale when database.yml changes under a running server.

## Consequences

A user who needs write access, or a database the Rails app does not own, can run dbhub beside this gem; the two do not overlap in what they promise.

## Alternatives not taken

- **dbhub as rails_query's backend**: see above. Every reason is a property the tool documents.
- **dbhub's two-tool default**: the answers here are computed (callback order, strong params lineage, filter chains). A bare search tool would hand that work back to the model.
- **Tool annotations derived from an access policy**: there is no write mode here, so a constant read-only hint is correct.
