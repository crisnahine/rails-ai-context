<div align="center" markdown="1">

# Security Model

**Read-only by design. Defense in depth. Every tool is non-destructive.**

[Architecture](ARCHITECTURE.md) · [Configuration](CONFIGURATION.md) · [Tools Reference](TOOLS.md) · [FAQ](FAQ.md)

</div>

---

> [!CAUTION]
> This gem is designed for **development environments**. The query tool is disabled in production by default. Sensitive files are blocked. All 45 tools are read-only.

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

- Strips comments: block (`/* */`), line (`--`), MySQL (`#` at line start)
- **Blocks write keywords**: INSERT, UPDATE, DELETE, DROP, ALTER, TRUNCATE, CREATE, GRANT, REVOKE, SET, COPY, MERGE, REPLACE
- **Blocks lock clauses**: FOR UPDATE, FOR SHARE, FOR NO KEY UPDATE
- **Blocks dangerous SHOW**: GRANTS, PROCESSLIST, BINLOG, SLAVE, MASTER, REPLICAS
- **Blocks SELECT INTO**: prevents table creation via SELECT
- **Blocks multi-statements**: multiple semicolons
- **Blocks injection patterns**: OR 1=1, OR true, OR ''='', UNION SELECT
- **Allows only**: SELECT, WITH, SHOW, EXPLAIN, DESCRIBE, DESC

### Layer 2 - Database-level read-only

After validation, the query runs inside a transaction:

| Database | Mechanism |
|:---------|:----------|
| PostgreSQL | `SET TRANSACTION READ ONLY` + `SET LOCAL statement_timeout` |
| MySQL | `SET TRANSACTION READ ONLY` + `MAX_EXECUTION_TIME` hint |
| SQLite | A read-only connection in a child process, killed at timeout |

All queries execute inside a transaction, then rollback (even if they could write, they can't).

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
- Applied as `LIMIT` clause appended to query

### Layer 4 - Sensitive column rejection

A query that names a sensitive column is **rejected before execution**, not redacted after it:

**Default redacted patterns:** `password_digest`, `encrypted_password`, `password_hash`, `reset_password_token`, `confirmation_token`, `unlock_token`, `otp_secret`, `session_data`, `secret_key`, `api_key`, `api_secret`, `access_token`, `refresh_token`, `jti`

Matching is by name, case-insensitive and word-bounded, against both the defaults above and `config.query_redacted_columns`. `SELECT password_digest AS pd FROM users` is blocked outright: post-execution redaction reads the column names the database returns, which the caller controls through aliases and expressions, so it cannot be relied on.

If one of your own columns merely looks sensitive (an `oauth_applications.secret`, say), exempt it by name:

```ruby
config.query_allowed_columns = %w[secret]
```

The exemption covers the results too: an allowed name comes back unredacted. A
column declared with `encrypts` stays `[FILTERED]` either way.

### Environment guard

> [!WARNING]
> Disabled in production by default. Only enable with `config.allow_query_in_production = true` if you understand the implications.

---

## Sensitive file blocking

The `rails_search_code` and file-reading tools block access to sensitive files:

### Default patterns

```text
.env .env.*
config/master.key
config/credentials.yml.enc config/credentials/*.yml.enc
config/database.yml config/secrets.yml
config/cable.yml config/storage.yml
config/mongoid.yml config/redis.yml
*.pem *.key *.p12 *.pfx *.jks *.keystore
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
raise unless real_path.start_with?(Rails.root.to_s)
```

The VFS (`rails-ai-context://views/{path}`) applies the same protection for view template reads.

### Frontend roots outside the app

Two directories outside `Rails.root` are read, for frontend manifests only: each
`frontend_paths` entry you configure (`../web-client`), and the JS workspace root
above the app (the nearest ancestor holding a lockfile or declaring `workspaces`,
never above the git root and never outside a git repository). Only `package.json`,
lockfiles and the presence of a bundler config (`vite.config.*` and similar) are
read there. Sensitive patterns and symlink containment apply relative to that
directory, and frontend_stack names it in its answer.

### The bundle config/boot.rb declares

An app with no lockfile of its own (an engine's `test/dummy`) has its gems in the
Gemfile its `config/boot.rb` sets as `BUNDLE_GEMFILE` (`../../Gemfile`). That
Gemfile and its lockfile (`gems.rb` and `gems.locked` alike) are read with the same
trust as the app's own `Gemfile.lock`, only when their directory is inside the app's
git repository, never above its root and never outside a repository. Nothing else in
that directory is read, and a file there that links out of it is refused.

### How a refusal is reported

A path refused on policy - outside the app, a traversal, a sensitive file - comes back as an
error result: `isError: true` over MCP, exit 1 from the CLI. A path that is simply not there
is an ordinary answer and exits 0, so a script can tell the two apart.

---

## Command injection prevention

Search tools use array-based command execution (never shell strings):

```ruby
# Safe: array form
Open3.capture2("rg", "--no-heading", pattern, "--", directory)

# Pattern injection prevented by -- separator
```

File type parameters accept only alphanumeric characters.

---

## Regex injection prevention

On Ruby 3.2 and newer, user-supplied regex patterns have a 1-second timeout:

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

When using HTTP transport (Rack middleware or McpController):

- **Default bind**: `127.0.0.1` (localhost only - not exposed to network)
- **`auto_mount` is `false` by default** - must be explicitly enabled
- **Doctor checks** fail if `auto_mount` is true in production, and report it as enabled elsewhere

The McpController uses thread-safe transport initialization with mutex synchronization.

---

## Credential handling

- `rails_get_env` returns credential **keys**, never values
- Environment variable values are not exposed
- `config/credentials/*.yml.enc` is in the sensitive patterns list

---

## Reporting vulnerabilities

Email crisjosephnahine@gmail.com. Response within 48 hours.

Supported versions: 4.0.x and later (4.2.1+ includes security hardening). See the repo root `SECURITY.md` for the full policy.

---

<div align="center" markdown="1">

**[← Introspectors](INTROSPECTORS.md)** · **[CLI Reference →](CLI.md)**

[Back to Home](index.md)

</div>
