<div align="center" markdown="1">

# Security Model

**Read-only by design. Defense in depth. Every tool is non-destructive.**

[Architecture](ARCHITECTURE.md) · [Configuration](CONFIGURATION.md) · [Tools Reference](TOOLS.md) · [FAQ](FAQ.md)

</div>

---

> [!CAUTION]
> This gem is designed for **development environments**. The query tool, and MCP over HTTP from inside the app, are disabled in production by default. Sensitive files are blocked. All 45 tools are read-only.

## Design principles

1. **Read-only by design** - All 45 tools are annotated as non-destructive in the MCP protocol
2. **Defense in depth** - Multiple security layers, not single points of failure
3. **Sensitive data blocking** - Configurable patterns prevent access to secrets
4. **Offline by default** - No network calls except optional `rails_search_docs` with `fetch: true`
5. **Graceful degradation** - Missing optional dependencies don't expose errors or state

---

## SQL query safety (4 layers)

The `rails_query` tool uses a 4-layer security model:

```mermaid
flowchart LR
    Q[SQL Query] --> L1{Layer 1\nRegex Validation}
    L1 -->|"Blocked:\nINSERT, DROP,\nUNION SELECT..."| R1[Rejected]
    L1 -->|SELECT only| L2{Layer 2\nDatabase Read-Only}
    L2 -->|"SET TRANSACTION\nREAD ONLY\n+ timeout"| L3{Layer 3\nRow Limit}
    L3 -->|"Cap: 1000 rows\nDefault: 100"| L4{Layer 4\nSensitive Columns}
    L4 -->|"names password_digest,\napi_key, ..."| R1
    L4 -->|"no sensitive column"| OK[Safe Result]

    style R1 fill:#e74c3c,stroke:#c0392b,color:#fff
    style OK fill:#27ae60,stroke:#1e8449,color:#fff
    style L1 fill:#e67e22,stroke:#d35400,color:#fff
    style L2 fill:#f39c12,stroke:#e67e22,color:#fff
    style L3 fill:#3498db,stroke:#2980b9,color:#fff
    style L4 fill:#9b59b6,stroke:#8e44ad,color:#fff
```

### Layer 1 - SQL validation (regex-based)

Before any query reaches the database:

- Strips comments: block (`/* */`), line (`--`), and on MySQL `#`. A comment marker inside a quoted string or identifier is data and stays. The query that runs is this stripped text, never the raw input, so nothing the checks did not read reaches the database
- **Blocks write keywords**: INSERT, UPDATE, DELETE, DROP, ALTER, TRUNCATE, CREATE, GRANT, REVOKE, SET, COPY, MERGE, REPLACE
- **Blocks lock clauses**: FOR UPDATE, FOR SHARE, FOR NO KEY UPDATE
- **Blocks dangerous SHOW**: GRANTS, PROCESSLIST, BINLOG, SLAVE, MASTER, REPLICAS
- **Blocks SELECT INTO**: prevents table creation via SELECT, and `INTO OUTFILE` / `INTO DUMPFILE` writes to disk
- **Blocks file and network functions**: `pg_read_file`, `pg_read_binary_file`, `pg_ls_dir`, `pg_stat_file`, `lo_import`, `lo_export`, `dblink*`, `LOAD DATA`, `LOAD_FILE`, `load_extension` and their relatives, checked before and after comment stripping
- **Blocks session-effecting / administrative functions**: a read-only transaction does not stop these, and their effect lingers on the pooled connection. PostgreSQL: `pg_terminate_backend`, `pg_cancel_backend`, `pg_reload_conf`, `pg_stat_reset*`, `pg_switch_wal`, `pg_create_restore_point`, replication-slot and -origin functions, `pg_logical_emit_message`, `pg_advisory_lock*`, `set_config`, `pg_notify`, `txid_current` and their relatives; MySQL: `GET_LOCK`, `RELEASE_LOCK`, `RELEASE_ALL_LOCKS`, `IS_FREE_LOCK`, `IS_USED_LOCK`. This name list is the first layer; on PostgreSQL the plan's VOLATILE-function check (below) closes the rest of the family
- **Blocks column-alias lists**: a CTE or FROM-item list such as `t(a, b, c)` renames the columns a wildcard returns, which would carry sensitive columns out under harmless names. A type modifier (`numeric(10,2)`, `varchar(255)`), a record-function list (`AS t(a int, b text)`) and a single-column alias are left alone
- **Blocks multi-statements**: multiple semicolons, read on quote-masked text so a `;` inside a string literal or a `DO $$ … ; … $$` block body is not mistaken for a second statement (a `DO` block is then refused plainly as a disallowed statement, not for the wrong reason)
- **Blocks injection patterns**: OR 1=1, OR true, OR ''=''
- **Refuses any UNION**: a UNION takes its column names from its first SELECT, so another table's rows - a wildcard's columns included - would come out under those names, past the redaction that reads names. Every spelling is refused (`UNION`, `UNION ALL`, `UNION DISTINCT`, a parenthesised `UNION (SELECT ...)`), recursive CTEs with it; `INTERSECT` and `EXCEPT` return only their first SELECT's rows and stay. On PostgreSQL a "union" inside a string literal is data
- **Blocks sensitive column references**: see Layer 4 - a query whose text names a sensitive column, directly or through an alias or expression, is refused before execution
- **Allows only**: SELECT, WITH, SHOW, EXPLAIN, DESCRIBE, DESC

### Layer 1b - PostgreSQL semantic analysis (planning only)

The textual layer cannot see a whole-row serialisation (`SELECT row_to_json(u.*) FROM users u`) or an admin function introduced through a view, because no sensitive column name appears in the query. On PostgreSQL, before the query runs, the tool plans it with `EXPLAIN (VERBOSE, FORMAT JSON)` inside the same read-only transaction - planning only, nothing executes, not even a VOLATILE function (the planner does not fold one). The plan is refused when it:

- holds a **whole-row reference** (`alias.*`) to a relation that has a sensitive column - this closes `row_to_json(u)`, `to_json(u)`, `u::text`, `array_agg(u)`, `json_agg(u)`, `hstore(u)`, `concat(u.*)`, `string_agg(u::text, …)`, a bare `SELECT u`, and the same through a view, subquery or CTE;
- **uses a sensitive column** anywhere but as a plain pass-through output - a `ROW(u.*)` the planner expanded into named columns, or a `WHERE` / `ORDER BY` oracle;
- **launders a sensitive column** through an intermediate the plan's top node does not name - a `MATERIALIZED` CTE, a subquery scan, or a set operation (`INTERSECT` / `EXCEPT`) - so its value would reach a result column that the output-provenance redaction (Layer 4) cannot pin. These are refused rather than redacted;
- names any **VOLATILE function** (`pg_proc.provolatile = 'v'`) outside a short harmless allowlist (`random`, `clock_timestamp`, `gen_random_uuid`, `timeofday`, `pg_sleep`). This is how the admin-function family is closed robustly, rather than by an ever-growing name list.

A whole-row read of a relation with no sensitive column (`row_to_json(posts.*)`) is allowed. Before these checks scan a plan expression, its string constants are masked (PostgreSQL's deparser always doubles quotes and never emits an `E''` string, so a constant is matched exactly), so a sensitive word inside a `'%key%'::text` filter or a literal argument is not mistaken for a column or a function.

### Layer 2 - Database-level read-only

After validation, the query runs inside a transaction:

| Database | Mechanism |
|:---------|:----------|
| PostgreSQL | `SET TRANSACTION READ ONLY` + `SET LOCAL statement_timeout` |
| MySQL | `SET TRANSACTION READ ONLY` + `MAX_EXECUTION_TIME` hint |
| MariaDB | `SET TRANSACTION READ ONLY` + `SET STATEMENT max_statement_time = <seconds> FOR <query>` (MariaDB ignores MySQL's hint, so a long query would otherwise run unbounded) |
| SQLite | A read-only connection in a child process, killed at timeout |

On PostgreSQL and MySQL the query executes inside a transaction, then rolls back (even if it could write, it can't). Any other adapter has no database-level guard: the query runs with Layer 1 validation and the row limit only.

A SQLite query runs in-process under `PRAGMA query_only = ON`, with no time
limit, for an in-memory database, on a platform without `fork`, or when it
needs a function, virtual-table module, collation or encryption key only the
app's own connection has. The table and EXPLAIN answers then say so; CSV output
stays plain data.

On sqlite3 1.x a query fails at its timeout, with the statement-timeout error,
when another connection in the same process held an exclusive lock on a
rollback-journal database as it started (`BEGIN EXCLUSIVE`): the child
inherits that lock record and it never clears. A lock held
by another process is waited on as usual, and an open write transaction or any
lock in WAL mode does not block it.

### Layer 3 - Row limit

- Default: 100 rows
- Configurable: `config.query_row_limit` (hard cap: 1000)
- Applied as a `LIMIT` clause appended to the query. A `LIMIT` or `FETCH FIRST` that ends the query is lowered to the cap, and one inside a subquery is left as written
- The rows that come back are cut to the cap too, so the answer holds it whatever the database made of the text
- When the cap holds rows back, the answer says so in every format - a note such as `100 rows shown; the query returned at least this many (the row limit of 100; pass limit: up to 1000 to see more)`, so a partial result is never mistaken for the whole one. In CSV output the note sits after a blank line, outside the comma block, so a parser still reads clean rows

### Layer 4 - Sensitive column rejection

A query that names a sensitive column is **rejected before execution**, not redacted after it. One rule decides what is sensitive, used by the pre-execution refusal, the PostgreSQL plan check and result redaction alike. A column is sensitive when it is:

- in `config.query_redacted_columns`, or the fixed built-in list;
- an `encrypts` column of one of your models;
- a name the heuristic catches: it ends in `password`, `secret`, `token`, `key`, `digest` or `hash`, or contains `password`, `secret` or `token`

minus anything in `config.query_allowed_columns`.

**Default redacted patterns:** `password_digest`, `encrypted_password`, `password_hash`, `reset_password_token`, `confirmation_token`, `unlock_token`, `otp_secret`, `session_data`, `secret_key`, `api_key`, `api_secret`, `access_token`, `refresh_token`, `jti`. Those are the defaults of `config.query_redacted_columns`. The fixed built-in list adds `password_reset_token`, `remember_token`, `secret` and `private_key`.

The pre-execution refusal matches on two things, case-insensitive and word-bounded:

- **the fixed names above**, on every adapter whether or not they are real columns, so the check holds even with no connection;
- **every real column of your schema that the rule flags** - read from the live connection, falling back to the cached schema. This catches an app-specific column the heuristic flags (`api_token`, `auth_token`) through any alias or expression, not only an exact configured name. Rails' own bookkeeping tables (`ar_internal_metadata`, `schema_migrations`) are left out: their columns are never secrets, and `ar_internal_metadata.key` ends in "key", so counting it refused every query whose text held the word "key".

So `SELECT password_digest AS pd FROM users`, `SELECT upper(api_token) FROM users` and `SELECT (SELECT api_token FROM users LIMIT 1) AS leaked` are all refused: post-execution redaction reads the output column names, which the caller controls through aliases and expressions, so it cannot be relied on. A table or alias that merely contains a sensitive word (a `tokens` table) does not trip the check - only a real column name does. `SELECT *` stays allowed, and its sensitive columns are redacted in the result.

A sensitive word inside a **string literal** - a `LIKE '%secret%'` pattern, a JSON key `->>'token'` - is data, not a column reference. On PostgreSQL the check runs on literal-masked text, and the plan layer (Layer 1b) then has to vouch: a query that passed only because a name sat inside a literal runs only when its plan was obtained and cleared every check, so a masker fooled by a quote trick (`standard_conforming_strings` off, an `E''` string) can never be the only gate - if planning fails, the raw-text refusal stands. On MySQL, MariaDB and SQLite the match stays on raw text with no masking, because a quote's meaning there depends on server modes (`NO_BACKSLASH_ESCAPES`, `ANSI_QUOTES`) or a dotted single-quoted name is an identifier (`t.'col'`).

If one of your own columns merely looks sensitive (an `oauth_applications.secret`, say), exempt it by name:

```ruby
config.query_allowed_columns = %w[secret]
```

Results are redacted as well: a returned column comes back as `[FILTERED]` when the sensitivity rule flags its **output name**, and on PostgreSQL when its origin is a sensitive base column - either by **provenance** (`PG::Result#ftable` / `#ftablecol`, mapped to the base column) or by the **plan's top-node `Output`**, whose i-th expression is result column i. The plan path catches a view (or inlined CTE/subquery/join) that renamed a sensitive column to a harmless name: `CREATE VIEW user_tokens AS SELECT id, api_token AS t FROM users; SELECT t FROM user_tokens` returns `t` as `[FILTERED]`. `SHOW`, `DESCRIBE` and `EXPLAIN` output is not redacted.

The exemption covers the results too: an allowed name comes back unredacted. A
column declared with `encrypts` stays `[FILTERED]` either way - an encrypted-at-rest
attribute is never meant to be read back raw.

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

The VFS (`rails-ai-context://views/{path}`) applies the same protection for view template reads.

### Links out of the app

A file the gem finds on its own, by walking the app or by asking Ruby where a loaded class
came from, is read only when its real path is inside the app root, or inside a directory the
app links in from elsewhere, such as a pack symlinked into `packs/`. A symlink from inside the
app to anywhere else is not followed: the file is neither listed nor read. A tool asked for it
by name answers as if it were not there; one handed its path refuses it, as described under
"How a refusal is reported" below. This covers templates and layouts, Stimulus controllers and
other JavaScript, locale files, environment files, seeds, and the Ruby source of models,
controllers, jobs, mailers, channels, helpers, components and concerns.

Booted, a class Rails loaded through such a link is still described from what reflection
answers, such as a job's queue name; only its file goes unread. `rails_security_scan` hands
the app to Brakeman, which reads it by its own rules.

### Frontend roots outside the app

Two directories outside `Rails.root` are read, for frontend manifests only: each
`frontend_paths` entry you configure (`../web-client`), and the JS workspace root
above the app (the nearest ancestor holding a lockfile or declaring `workspaces`,
never above the git root and never outside a git repository). Only `package.json`,
lockfiles and the presence of a bundler config (`vite.config.*` and similar) are
read there, plus a configured entry's `tsconfig.json` and the configs it extends
inside that same directory. Sensitive patterns and symlink containment apply relative to that
directory, and frontend_stack names it in its answer.

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
`Path not allowed`. A path that is simply not there is an ordinary answer and exits 0, so a
script can tell the two apart.

The same holds for a name a tool turns into a file: a log (`rails_read_logs file:`), a partial
(`rails_get_partial_interface partial:`) or a concern (`rails_get_concern name:`) whose file
links out of the app is refused, not reported missing. A list of what a tool can read, such
as the available logs or partials, leaves out every entry it would refuse. `rails_diagnose`
still diagnoses the error it is given when the `file:` it is pointed at is refused, says so,
and returns the whole answer as an error result.

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
- Credentials embedded in URIs (`redis://user:pass@host`)
- Email addresses in log lines
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

**The standalone server** - `rails-ai-context serve --transport http` and `rails ai:serve_http` - is its own process and binds `127.0.0.1` by default. `http_bind` can open it to the network, still with no authentication. The MCP SDK answers only requests whose `Host` header is `127.0.0.1`, `::1` or `localhost`, which stops a DNS rebinding attack from a browser but not a client that sends `Host: localhost` itself; a client that addresses the machine by IP or name gets 403 "Invalid Host header". So a non-loopback bind suits a container whose port is published to the host, where the client still connects to `localhost`. The server says so on stderr when it starts. On an MCP SDK too old to check the `Host` header, every tool answers whoever reaches the port.

`auto_mount` is `false` by default, and the engine exists only where you mount it. Mount it guarded, `if defined?(RailsAiContext::Engine)`, so the routes file still loads where the gem is not installed.

The McpController uses thread-safe transport initialization with mutex synchronization.

---

## Credential handling

- `rails_get_env` returns credential **keys**, never values
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
