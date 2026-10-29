<div align="center" markdown="1">

# Troubleshooting

**Common issues and how to fix them.**

[Quickstart](QUICKSTART.md) · [Configuration](CONFIGURATION.md) · [AI Tool Setup](SETUP.md) · [FAQ](FAQ.md)

</div>

---

> [!TIP]
> Always start with `rails ai:doctor`. It checks the app, its databases, the MCP configs and the context files, and catches most issues automatically.

## Diagnostics first

```bash
rails ai:doctor          # In-Gemfile
rails-ai-context doctor  # Standalone
```

This runs every check that applies to the app ([the list](GUIDE.md#diagnostics)) and returns an AI readiness score (0-100). Each check that fails or warns includes a fix suggestion.

---

## Installation issues

### The install hangs in my AI tool's terminal

It is waiting for an answer nobody can type. Cursor and VS Code run an agent's commands in a terminal, where a question waits forever. Give every answer as a flag:

```bash
bundle exec rails generate rails_ai_context:install --tools claude --defaults   # in-Gemfile
rails-ai-context init --tools claude --defaults                         # standalone
```

Add `--mcp`, `--cli` or `--mcp-only` to pick the setup, and `--prune` to remove a dropped tool's files. The [copy-paste prompts](PROMPTS.md) already do this.

### "--tools ... is not an AI tool"

`--tools` takes names, never menu numbers: `claude`, `cursor`, `copilot`, `opencode`, `codex`, comma-separated, or `all`. Nothing was written; run it again with the names.

### "Could not find gem 'rails-ai-context'"

```bash
gem install rails-ai-context
# or
bundle update rails-ai-context
```

### Generator fails with "uninitialized constant RailsAiContext"

The gem is likely in a `:development` group but you're running in another environment:

```ruby
# config/initializers/rails_ai_context.rb
if defined?(RailsAiContext) && RailsAiContext.respond_to?(:configure)
  RailsAiContext.configure do |config|
    # ...
  end
end
```

The guard prevents crashes when the gem isn't loaded. `rails ai:doctor` warns about a guard that checks `defined?(RailsAiContext)` alone, since the constant can exist where `configure` does not.

### "Permission denied" during install

File system permissions. Check that your user can write to the project directory:

```bash
ls -la .mcp.json .cursor/ .vscode/ .github/
```

---

## MCP server issues

### AI tool doesn't detect the MCP server

1. Take the tool's own step. Each AI tool holds a project's MCP server back until you do, and the install's summary names it under "Next step". [AI tool setup](SETUP.md#verify-mcp-is-connected) has the step and the check for every tool.

2. Check the config file exists:
   - Claude Code: `.mcp.json`
   - Cursor: `.cursor/mcp.json`
   - Copilot: `.vscode/mcp.json`
   - OpenCode: `opencode.json`
   - Codex: `.codex/config.toml`

3. Verify the command the config holds works:
   ```bash
   bundle exec rails-ai-context serve   # in-Gemfile
   rails-ai-context serve               # standalone
   # Should output nothing (waiting for stdio input)
   # Ctrl+C to stop
   ```

4. Re-run the install with your current choices (the ones in `.rails-ai-context.yml`); it keeps what exists and adds what is missing:
   ```bash
   bundle exec rails generate rails_ai_context:install --defaults   # in-Gemfile
   rails-ai-context init --defaults                                 # standalone
   ```
   Or paste the [Fix it](PROMPTS.md#fix-it) prompt and let your AI tool do it.

### "Could not write .vscode/mcp.json - that tool will not auto-discover the MCP server"

The install never replaces a config it cannot write back faithfully: one that does not parse as JSON, one holding comments that writing it back would drop, or one that is not UTF-8. Trailing commas, which VS Code and OpenCode accept, are read the way they read them under json 2.9 or later; an older json refuses them, as JSON does. The line after the warning says which, and ends with the exact entry to add, as `Add {"servers":{...}} to it by hand`. Add that entry yourself, or remove the comments (and, under an older json, the trailing commas) and run the install again. `doctor` names the same entry for a file whose comments keep the install out, rather than sending you back to the install, and asks for one that is not UTF-8 to be saved as UTF-8 first.

Claude Code reads `.mcp.json` with a plain JSON parser, and loads no server from a file holding a comment or a trailing comma ("MCP config is not a valid JSON"); Cursor's `.cursor/mcp.json` is held to plain JSON too. Either one is reported as `Claude Code cannot read it: it holds a trailing comma, which JSON does not allow`, by the install and by `doctor`, however current the entry in it. Make the file plain JSON and run the install again. `doctor` reports one that does not parse, or holds no object to merge into, a workspace's above the app included. Dropping an AI tool leaves such a file alone the same way and names the entries to remove.

### Codex: "TOML parse error ... duplicate key"

Codex refuses a `config.toml` that declares a server twice. An earlier install could write a second `[mcp_servers.rails-ai-context]` table beside the server spelled another way: a quoted name (`[mcp_servers."rails-ai-context"]`), an inline table under `[mcp_servers]`, or dotted keys. `doctor` names such a file. Two tables are merged into one when the install runs again; for an inline table or dotted keys, delete one of the two by hand.

The install now finds the server however its name is quoted and replaces its table where it stands. An entry of the gem's written as an inline table or with dotted keys is left as it is, with a warning, as is a file whose `mcp_servers` is one inline table: write it as a `[mcp_servers.rails-ai-context]` table, or delete it, and the next run keeps it current. `doctor` gives that same edit for any problem in such an entry that only a rewrite fixes, a stale env snapshot included.

### Codex: "stream did not contain valid UTF-8"

Codex reads `config.toml` as TOML, which is UTF-8, and loads nothing from a file holding a byte that is not - one in a comment included. The install still writes its table into such a file, keeping every byte around it, and says `Codex CLI cannot read it: it is not UTF-8, which TOML is`; `doctor` fails it in the same words. Save the file as UTF-8.

### "MCP server fails to start"

`rails ai:doctor` (or `rails-ai-context doctor`) checks the command each config holds and says which one cannot start and why. The usual causes:

- `rails-ai-context is not currently included in the bundle`: the config runs `bundle exec rails-ai-context serve`, but the gem left the app's Gemfile. A standalone install runs `rails-ai-context serve`: run `rails-ai-context init` to rewrite the configs.
- The config runs `rails-ai-context serve` while the app's Gemfile.lock carries the gem: it needs a copy installed outside the bundle as well, which hands the run to the bundle's. Run `rails generate rails_ai_context:install` to write `bundle exec rails-ai-context serve`.
- `can't find executable rails-ai-context for gem rails-ai-context`: the bundle's copy of the gem lists no executable, as a `path:` copy of 5.32.2 or earlier outside a git checkout does. Point the Gemfile at a git checkout or a release.
- On Windows, a config that runs `bundle` or `rails-ai-context` itself rather than through `cmd /c`: those are batch files there, which Claude Code, Codex and the other clients that start a server without a shell do not run (`doctor` warns about it). Run the install again; on Windows it writes `cmd /c bundle exec rails-ai-context serve`.
- On macOS or Linux, a config that runs `cmd /c ...`: it was written on Windows, and there is no `cmd` here (`doctor` fails it). Run the install again on this machine, and keep the MCP configs out of git if the team works on both.
- The Claude Code plugin's server connects with no tools: it tells the session why (no gem for its Ruby, an older one, a Ruby too old, no app, or an app the gem cannot serve) and what to run; `claude --debug` shows the same line as its stderr. With a gem older than 5.38.0 a folder of several apps gets this too; from 5.38.0 the server serves each of them.
- The Claude Code plugin started in a folder of several apps answers a call with "`app` names the Rails app to answer for, one of: ...": every tool takes `app`, the app's name from that list, which the session-start rules also give. A call whose app's server stops answers with that server's last lines, the same lines `claude --debug` shows; fix what they name, and the app's next call starts its server again. A call to a tool that app's own server does not have names the app and its rails-ai-context version, and one whose Ruby has no copy of the gem names that Ruby and the `gem install` to run with it.
- The Claude Code plugin's server is listed as failed in `/mcp`, and `claude --debug` shows a `Bundler::GemNotFound` trace in its stderr: Claude Code was started from `bundle exec`, or from a shell holding the `RUBYOPT` or `BUNDLER_SETUP` it sets, for a bundle not installed for the plugin's Ruby, which fails before the plugin runs. Start Claude Code outside `bundle exec`, or unset those two where a shell profile sets them. After a failed start Claude Code skips the server in new sessions for about 15 minutes, so reconnect it in `/mcp` once the cause is fixed.

Check for Bundler/Ruby path issues:

```bash
which bundle
which rails-ai-context
ruby -v
```

For Codex CLI specifically, the env section in `.codex/config.toml` must match your current Ruby environment. Re-run install if you changed Ruby versions.

### Answers say "Boot did not finish within 20s"

The app's boot hung, usually an initializer waiting on a service that is
down (Redis, Elasticsearch, a secrets store). A stdio server gives the boot 20
seconds, because its client stops waiting for the first answer after about 30
(Claude Code, the MCP Inspector), and then serves the static tier; every other
command gives it 60. Start the service, or, for an app that is healthy but
slow to boot, raise both limits in the server's MCP entry: the boot's with
`RAILS_AI_CONTEXT_BOOT_TIMEOUT` (seconds) in its `env`, and the client's with
its own setting (Claude Code reads `MCP_TIMEOUT`, in milliseconds). Raising
only the boot's leaves a client that gives up first. The Claude Code plugin's
entry is the plugin's own: set both in Claude Code's settings `env` (user,
project or local) or in the shell that starts Claude Code. `rails ai:serve`
has no static tier, so it exits with the same message instead.

### A server set up for a folder of apps fails to start

`rails-ai-context init` run in a folder of apps writes entries that name each app relative to that folder (`--app-path shop`, and for an in-Gemfile app `BUNDLE_GEMFILE=shop/Gemfile`, or the monorepo's shared Gemfile its `config/boot.rb` names). Claude Code, Codex and OpenCode start a server in the folder they were launched in, so:

1. Start the AI tool in the folder of apps, not inside one of them. Launched inside an app, the tool still reads the folder's config above it, and the server says `--app-path shop is read from ...; it names an app from ...`. An in-Gemfile entry fails earlier, in Bundler, with a Gemfile it cannot find. To work in one app on its own, run `rails-ai-context init` inside it too.
2. Check the Ruby. Every server in the folder runs under the Ruby your version manager picks in the folder, and `init` warns about an app that declares another. `Your Ruby version is ..., but your Gemfile specified ...` from an in-Gemfile entry is that case: install the app's bundle for that Ruby, or give the app its own config with `init` inside it.

### "No Rails app found in ..., and 2 below it"

You ran a command in a folder that holds several apps. The error lists the exact command for each, with `--app-path`. To set them all up at once, run `rails-ai-context init` in that folder.

### "Tools return empty results"

1. Check that your Rails app boots: `rails runner "puts 'ok'"`
2. Check schema exists: `ls db/schema.rb` or `ls db/structure.sql`
3. Run doctor: `rails ai:doctor`

### MCP client reports a JSON parse error on the first line ("Resolving dependencies...")

RubyGems can print `Resolving dependencies...` to stdout while activating the
standalone `rails-ai-context` binary - before any gem code runs - which breaks
the pure-JSON stdio framing. This happens when gem activation needs the full
dependency resolver: typically a `GEM_PATH` that is missing part of the
dependency graph, or launching from inside another Bundler project's
directory. Fixes:

1. Launch `rails-ai-context serve` with the app root as the working directory
   (the generated MCP configs do this by default; a folder of apps' configs
   start in that folder and name the app with `--app-path`).
2. Make sure `GEM_PATH` covers the complete default gem path
   (`gem env path`), not just `gem env gemdir` - Ruby's bundled gems
   (racc, etc.) live in a separate directory.
3. In-Gemfile installs are immune: `bundle exec rails-ai-context serve`
   activates through the lockfile.

### MCP server responds slowly

- Check `config.cache_ttl` - lower values mean more frequent re-introspection
- Without the `listen` gem, each call first checks the app's files for edits, about 100 ms at 10,000 files; adding `listen` to the development group replaces that check with live reload
- Check `config.preset` - `:standard` is faster than `:full`
- Large schema files (>10MB) slow down schema introspection
- Run `rails ai:doctor` - it checks schema size and view count

### The stdio server stops with "MCP stdio connection closed: stdio frame exceeds 4194304 bytes"

The MCP SDK reads one JSON-RPC message per line and refuses a line of 4 MiB or more. The server answers the client with a JSON-RPC `-32600` error, prints the reason on stderr and exits 1. The message is too large for any client to need; look for a tool argument the client filled with a whole file.

### HTTP answers an HTML error page while a migration is pending

In development Rails answers every request with its pending-migration page, and the mounted engine is a route like any other. Run the migration, or use `auto_mount`, stdio or the standalone server, which all answer ahead of that check; `rails_runtime_info` lists the pending migrations.

### HTTP answers 403 "Forbidden: Invalid Host header"

The standalone server (`serve --transport http`, `rails ai:serve_http`) answers only requests whose `Host` header is `127.0.0.1`, `::1` or `localhost`, as the MCP SDK does, to stop DNS rebinding. A client that reaches it by the machine's IP or hostname is refused, whatever `http_bind` says. Connect to `localhost`: through a published container port, or an SSH tunnel (`ssh -L 6029:localhost:6029 your-host`).

The mounted engine and `auto_mount` answer the hosts the app's `config.hosts` allows, as the rest of the app does. Add the name the client uses to `config.hosts`, the way you would for any other route.

### HTTP answers 403 "does not serve MCP over HTTP in production"

The mounted engine and `auto_mount` refuse every request outside development and test (production, staging) unless the app sets `config.allow_http_in_production = true`. Set it only with the endpoint behind your app's authentication; see [Security](SECURITY.md#mcp-http-transport).

---

## Context file issues

### "Context files are empty or minimal"

1. Check that models exist: `ls app/models/`
2. Check that schema exists: `ls db/schema.rb`
3. Try full mode: `config.context_mode = :full`
4. Regenerate: `rails ai:context`

### "Context files don't update after code changes"

Regeneration is not automatic unless you're running watch mode:

```bash
rails ai:watch
```

Or regenerate manually:

```bash
rails ai:context
```

### "My custom content in CLAUDE.md was overwritten"

The gem writes its section between `<!-- BEGIN rails-ai-context -->` and `<!-- END rails-ai-context -->` and replaces only what lies between them, so text above and below the markers survives every run; text inside them does not. A file with no markers at all gets the section added at the top, and its own text kept below.

The per-directory `app/models/AGENTS.md` and `app/controllers/AGENTS.md` that OpenCode and Codex read follow the same rule. One the gem generated whole carries `> Auto-generated by rails-ai-context. Do not edit manually.` and is rewritten whole; one you wrote yourself keeps its text, and the listing goes between the markers above it.

If one marker goes missing, or the file holds a second pair, nothing says where the gem's section ends. The run then leaves the file as it is and reports it as `unpaired rails-ai-context marker, left as it is`. Put the lost marker back where the gem's section ends, or delete the leftover section with its markers, and the next run updates the file again.

### "Generated files are too large"

Use compact mode (default), and lower `claude_max_lines` for a shorter root file:

```ruby
config.context_mode = :compact
config.claude_max_lines = 100
```

Every file already has a byte budget: 12,000 bytes for the compact root file, 24,000 in full mode, 8,000 for a rule file. A file over it loses data from the bottom, and the tools answer the rest. The root file goes no lower than about 70 lines, since its title, rules and tools guide stay whole.

Turning root files off (`config.generate_root_files = false`) does not shrink what Claude Code and Copilot load: the overview and the whole tools guide move into rules files they load in every session.

---

## Query tool issues

### "rails_query is disabled in production"

By design. The answer is an error response: `isError` over MCP and exit 1 from the CLI. Override if needed:

```ruby
config.allow_query_in_production = true
```

### "Blocked: contains INSERT" and other "Blocked:" messages

The SQL gate refuses write statements, file and admin functions and secret column names, and the message names what it hit. Only read statements run: SELECT, WITH, SHOW, EXPLAIN and DESCRIBE.

What a string literal holds decides some of these:
- A write keyword or a semicolon inside a string (`WHERE note = 'please insert coin'`, `'a; b'`) is data on every database, and the query runs
- A write after a `WITH` clause (`WITH ... INSERT INTO ...`) is named as that write: "Blocked: contains INSERT"
- A secret column's name, `FOR UPDATE` / `FOR SHARE` or `UNION` inside a string is data on PostgreSQL only. On MySQL, MariaDB and SQLite the raw text decides and the query is refused, since no later check there would catch a quote the masking misread
- `INTO OUTFILE` / `INTO DUMPFILE` is refused wherever it stands, inside a string too, on every database
- A file or network function (`pg_read_file`, `LOAD_FILE`), a refused `SHOW` form (`SHOW GRANTS`) and a relation that is not read (`pg_stats`, `slow_log`) are refused wherever they stand, inside a string too, each on the database that has it. `slow_log` is refused on MySQL and MariaDB, and `pg_stats` on PostgreSQL
- A session or administrative function (`pg_terminate_backend` on PostgreSQL, `GET_LOCK` on MySQL and MariaDB) is refused wherever its call stands, so `'pg_terminate_backend(1)'` inside a string is refused too. Its bare name inside a string is data
- A `#` starts a comment on MySQL only, and only outside a quoted string
- A JSONB operator (`#>>`) runs as written (since v5.6.0)

### "Blocked: a `*` inside a subquery", "Blocked: `TABLE` inside a subquery" and "Blocked: the view ... is not queried"

MySQL, MariaDB and SQLite trace no result column back to its table column, so these shapes are refused there when a secret column is in reach:

- A `*` inside a subquery, a CTE body included, when the statement names a table that holds a secret column. The message names that table and the column. The rule tests the two facts together and does not tell which table the wildcard reads, so the statement is refused also when the wildcard is over another table. Name the columns in the subquery: `WITH x AS (SELECT id, email FROM users) SELECT * FROM x`. On MySQL and MariaDB `(TABLE t)` counts as a wildcard: select the columns you need. `EXISTS (SELECT * ...)` and `count(*)` run
- On SQLite, `IN` before a table's name (`WHERE id IN users`), when the statement names a table that holds a secret column. It is SQLite's shorthand for `IN (SELECT * FROM users)`. Write the subquery with its columns named: `WHERE id IN (SELECT id FROM users)`
- On SQLite, either of those two in a statement that holds a string equal to such a table's name (`WHERE role = 'users'`). SQLite reads a string as a table's name where a name can stand, and the rule cannot tell that use from plain data. The message says "in a statement that holds the string 'users'". Name the columns in the subquery, or compare with another value
- A view whose definition names a secret column, or has a wildcard and names a table that holds one. Query the tables the view reads. When the column holds no secret, exempt it by name as [Column values show [FILTERED]](#column-values-show-filtered) says

On PostgreSQL a plain view runs and its secret columns come back `[FILTERED]`. A materialized view whose definition names a secret column gets the view message, since its stored rows cannot be traced to a table column. Query the tables it was built from.

### "Blocked: ... is not read: it is a shadow table", "it is a virtual table that holds the secret column" and "it returns the database file's raw pages"

On SQLite `rails_query` reads no table that holds another table's rows or words under other names:

- `sqlite_dbpage`, `sqlite_dbdata` and `sqlite_dbptr` return the database file's pages, with every stored value in them
- A shadow table (`docs_content`, `docs_data`) holds what a virtual table stores, under other column names. The message names the virtual table to query
- A virtual table that holds a secret column is refused whole, since a search or a function over it reads a column by its position. Keep the secret column out of the virtual table, or query the table it was copied from
- An `fts5vocab` or `fts4aux` table over such a table lists its words, so it is refused too
- A virtual table whose definition names a refused view, or a table that is not read, holds their rows or words. The message says "its definition names" and what it names

A view over one of these is refused with "its definition names `<table>`, which is not read". The name is refused inside a string too.

### "Blocked: `pragma_foreign_keys` tells of the connection that runs it"

On SQLite `rails_query` runs a statement on a connection of its own, so a value that belongs to a connection would not be the app's. The pragma functions that describe the schema or the database file run: `pragma_table_info`, `pragma_index_list`, `pragma_foreign_key_list`, `pragma_integrity_check`, `pragma_page_count` and the others [SECURITY.md](SECURITY.md#layer-1---the-sql-gate-statement-checks) lists. Every other `pragma_*` function is refused, and so are `changes()`, `total_changes()` and `last_insert_rowid()`. Read those on the app's own connection, in `bin/rails runner` or the console. A column whose own name starts with `pragma_` runs. Its name is refused only where SQLite would read the function: called, or where a table stands.

### "Blocked: the statement is ... bytes long"

`rails_query` checks a statement of 1,000,000 bytes at most. Send a shorter one: split a long `IN` list, or join against a table that holds the ids.

### "Blocked: the checks on the statement's text ran longer than query_timeout"

The checks that read a statement's text have `query_timeout` to themselves and give up when they pass it. The statement was not sent to the database. The schema read that comes before the checks was. Send a shorter statement.

### "Blocked: ... is not queried: its columns could not be read" and "leads through more databases than rails_query follows"

The secret column rule reads the columns of every schema and database a statement reaches. A relation whose columns it cannot read is not queried, so give the account read access to the catalogue of that schema, or query a relation it can read. A view the statement names is followed through the databases or schemas its definition names, three reads deep. A statement that names a view that leads deeper is not run, and the message names the view: query the tables it reads. A statement that does not name that view runs.

### "Blocked: SHOW with a WHERE clause is not run"

MySQL's statement timeout does not hold a `SHOW` filter, so it is refused on every database. `SHOW ... LIKE` runs. For any other filter select from `information_schema`: `SELECT table_name FROM information_schema.tables WHERE table_schema = DATABASE()`.

### "Blocked: `pg_stat_activity` is not read"

`rails_query` reads no relation that holds values sampled from other tables, other sessions' statements or stored credentials. On PostgreSQL those are `pg_stats`, `pg_stat_activity`, `pg_authid`, `pg_settings` and their like. On MySQL and MariaDB they are `information_schema.processlist`, `performance_schema`, `sys` and the whole `mysql` schema among others. On SQLite they are the `sqlite_stat` tables and `sqlite_stmt`. [SECURITY.md](SECURITY.md#relations-and-settings-that-are-never-read) lists every name. Use the database's own client for those. Each name is refused on the database that has it, so an app table named `slow_log` is refused on MySQL and MariaDB. For `pg_settings` the message ends "To read one setting, run SHOW with its name."

### "A name before a dot is read as that schema, so an alias named `sys` needs another name"

On MySQL and MariaDB `mysql.` and `sys.` are read as those schemas wherever they stand outside a single-quoted string. An alias cannot be told from a schema, so `FROM users sys ... sys.id` is refused. Give the alias another name. The sentence ends every refusal over `mysql.` or `sys.` outside double-quoted text, so a real `FROM mysql.user` gets it too, with `mysql` as the name. A double-quoted string that holds `mysql.` or `sys.` is refused too, with a sentence of its own: MySQL reads double-quoted text as a name when the session's sql_mode holds `ANSI_QUOTES`. Write it in single quotes.

### "That is how MySQL reads the statement when the session's sql_mode holds NO_BACKSLASH_ESCAPES"

On MySQL and MariaDB a backslash in a string is an escape, unless the session's sql_mode holds `NO_BACKSLASH_ESCAPES`. `rails_query` does not read the session's mode, so it checks the statement under both readings and refuses it when either one does. This message ends a refusal that the second reading alone gives: with `\'` read as a backslash and the end of the string, the text after it is code. Write a quote inside a string doubled (`'it''s'`), so that both readings agree.

### "Blocked: a `[` outside a string or a quoted name is not run"

On MySQL and MariaDB a square bracket outside a string or a quoted name is refused. MariaDB reads `[name]` as a quoted name when the session's sql_mode holds `MSSQL`, and `rails_query` does not read the session's mode, so its checks could read such a statement another way than the server does. Quote a name in backticks: `` `name` ``. A `[` inside a string, such as a JSON path (`'$[0]'`), runs. One case apart: a string that holds a backslash before a quote (`'O\'Brien'`) is read a second way that ends it at that quote, and a `[` which that reading leaves outside a string is refused. Write the quote doubled (`'O''Brien'`).

### "Blocked: a user variable assignment (`:=`) is not run"

On MySQL and MariaDB `SELECT @n := @n + 1` leaves `@n` set on the app's pooled connection after the query returns, and a read-only transaction does not stop that. To number rows, use a window function, which MySQL 8 and MariaDB 10.2 and later have: `SELECT ROW_NUMBER() OVER (ORDER BY id) AS n, title FROM posts`. A `:=` inside a string or a quoted name runs, unless a backslash before a quote in the statement leaves it outside a string in the second reading of a backslash: write that quote doubled.

### "Blocked: LAST_INSERT_ID with an argument is not run"

On MySQL and MariaDB `LAST_INSERT_ID(<value>)` sets the value the next `LAST_INSERT_ID()` returns, and it stays on the app's pooled connection after the query returns. `LAST_INSERT_ID()` with no argument runs. The call is refused wherever it stands, inside a string too.

### "Blocked: a column-alias list" on a statement that has none

One name in parentheses after `GLOB`, `MATCH` or `OVER` that follows a subquery has the shape of a column-alias list, so `WHERE (SELECT title FROM post_titles LIMIT 1) GLOB (title)` and `sum((SELECT 1)) OVER (w)` are refused. Write the name with no parentheses (`GLOB title`), or write the window inline (`OVER (ORDER BY id)`).

### "Blocked: UNION is not run" on a statement with no UNION

A quoted name that spells the word is refused, as in `SELECT 1 AS "union"`. Give the alias another name. On PostgreSQL the word inside a string is data.

### "Blocked: the setting ... is not read", "Blocked: SHOW ALL is not run" and "Blocked: SHOW takes a setting's plain name on PostgreSQL"

On PostgreSQL `rails_query` reads one setting at a time, by its plain name: `SHOW work_mem`. `SHOW ALL` and a quoted name (`SHOW "work_mem"`) are refused. Six settings can hold a password or a command line that carries one and are refused: `primary_conninfo`, `ssl_passphrase_command`, `archive_command`, `restore_command`, `archive_cleanup_command` and `recovery_end_command`. So is a setting whose own name reads as a secret, such as `app.jwt_secret`.

### "Blocked: current_setting runs only with the setting's name written as one plain string"

Write the name as one string: `current_setting('work_mem')`. A name built by an expression, read from a column or written as an `E''` or dollar-quoted string is refused, since the gate could not read which setting comes back.

### "Blocked: a quoted name is followed by a parenthesis"

A function called by a quoted name (`"upper"('x')`, `` `sleep`(0) ``) is refused on every database, since the checks read a function's name to decide whether it runs. Write the name without quotes. A function whose name needs quotes, such as a mixed-case one on PostgreSQL, cannot be called through `rails_query`.

### "Blocked: EXPLAIN FOR CONNECTION is not run"

On MySQL and MariaDB `EXPLAIN FOR CONNECTION` shows the plan of the statement another session is running, so it is refused. `EXPLAIN` of a statement of your own runs.

### "The columns of the <name> database could not be read"

The secret column rule reads the database's columns before any query runs. When that read fails and, for the primary, the cached schema holds no tables either, no query runs on that database. The read is a few statements whatever the number of tables, six at most, so an account that cannot read the catalogue cannot use `rails_query`.

### "The database is locked by another connection, so the query did not run"

Another connection holds a lock on the SQLite database, such as a write transaction left open in a console. Nothing ran. End that transaction and run the query again. The query waits on a lock for 80% of `query_timeout` before it answers this. A lock met while the connection opens, as on the CLI or on a server's first call, gets the same answer. A query that holds its read lock and then runs past `query_timeout` answers the timeout, also when a writer asks for the lock while it runs.

### "This SQLite query ran without a time limit"

On SQLite `rails_query` runs a statement in a process of its own, which it ends at `query_timeout`. That process cannot see what the app's own connection alone holds. So the statement runs on the app's connection, with this note, on an in-memory database, on a platform without `fork`, inside an open transaction, and when it needs a table, a function, a module, a collation or an encryption key only that connection has. While the connection holds a temp object or an attachment, it runs there too when it names a temp object, the `temp` schema, `sqlite_temp_master` or an attached database, or calls a pragma function (`pragma_table_info(...)`, `pragma_table_list` and the rest) or `dbstat`. A name is matched anywhere in the statement, in any letter case and inside a string too. A statement that returns rows slowly still ends a few rows after `query_timeout`. One long step cannot be ended there.

### "The reads rails_query makes before a statement ... took the whole <N> second timeout"

Before a statement runs, `rails_query` reads the columns of the schema and, on PostgreSQL, the statement's plan. Those reads share one `query_timeout`, and here they used all of it, so the statement was not run. A table another session has locked is the usual cause. Run the query again when the lock is gone, or raise `config.query_timeout`. "The statement ran, and the read that traces its result columns ..." is the same limit met after the statement: its rows are not shown.

### "Column values show [FILTERED]"

Columns whose names look secret are redacted, and a query that names one is rejected with "Blocked: query references secret column `x`." followed by what to do. Shortening `config.query_redacted_columns` does not lift either, because a built-in list applies as well. Exempt a column of your own by name:

```ruby
config.query_allowed_columns = %w[secret]
```

On a standalone install, where no initializer runs, put the name under `query_allowed_columns:` in `.rails-ai-context.yml`.

---

## Search issues

### "Search returns no results"

1. Check the case: the search is case-sensitive on both backends, as ripgrep is by default
2. Check excluded paths: `config.excluded_paths` excludes `node_modules`, `tmp`, `log`, `vendor`, `.git`, `doc` and `docs` directories at any depth
3. Check `config.search_extensions`: when set, it narrows the Ruby fallback to those extensions
4. Check sensitive patterns: some files are blocked by design

### "ripgrep not installed" warning

Install ripgrep for faster search:

```bash
# macOS
brew install ripgrep

# Ubuntu
apt install ripgrep

# Windows
winget install BurntSushi.ripgrep.MSVC
```

The gem falls back to Ruby regex if ripgrep isn't available. Search still works, just slower on large codebases.

---

## Standalone mode issues

### "Bundler can't find the gem"

Standalone mode boots the app with a small shim, then restores the `$LOAD_PATH` entries `Bundler.setup` stripped and requires the gem. If this fails:

1. Check the gem is installed: `gem list rails-ai-context`
2. Check Ruby version matches: `ruby -v`
3. Try with Gemfile entry instead of standalone

### "YAML config not loading"

The file is read from the app root, once, at boot, and an initializer does not replace it: a `configure` block wins only the keys it assigns, key by key ([Precedence](CONFIGURATION.md#precedence)). In standalone mode the initializer contributes nothing at all, since the gem is not loaded while `config/initializers` runs. Check:

1. You are inside the app, or passed `--app-path`. A command run from a subdirectory reads the config of the app root it walks up to, and names it on stderr.
2. The key is one the gem knows. An unknown key warns on stderr and is ignored.
3. The file holds `key: value` settings. A file that holds a bare string, a list or a number is ignored with "WARNING: <path>: the file holds no `key: value` settings. Ignored."
4. The file is readable and parses. Corrupted YAML degrades gracefully with a warning.

---

## Security scan issues

### "Brakeman is not installed"

The `rails_security_scan` tool requires Brakeman:

```bash
gem install brakeman
# or
bundle add brakeman --group development
```

Without it, the tool reports "not installed" but the gem works fine otherwise.

### "Installed on this machine but not in this app's bundle"

The scan runs under the app's own bundle, so a brakeman installed globally is
not on its load path. The tool falls back on its own: it runs the installed
gem's `bin/brakeman` with the app's Ruby, as a separate process outside the
bundle, and says so under the results. This message means that fallback
produced no report either - the gem is there and the run failed. `rails
ai:doctor` runs the same script's `--version` and names what it printed. Run
`brakeman` in the app directory to see what it hit, or add it to the Gemfile
so the scan runs in-process:

```bash
bundle add brakeman --group development
```

---

## Performance issues

### "Introspection is slow"

1. Use `:standard` preset (17 introspectors vs 40)
2. Increase cache TTL: `config.cache_ttl = 300`
3. Check schema file size: `rails ai:doctor` warns if too large
4. Check view count: many views slow down view introspection

### "Live reload fires too often"

Increase the debounce:

```ruby
config.live_reload_debounce = 3.0  # seconds (default: 1.5)
```

Or disable:

```ruby
config.live_reload = false
```

---

## Getting help

1. Run `rails ai:doctor` first - it catches most issues
2. Check [GitHub issues](https://github.com/crisnahine/rails-ai-context/issues)
3. Open a new issue with doctor output and error details

---

<div align="center" markdown="1">

**[← Standalone](STANDALONE.md)** · **[FAQ →](FAQ.md)**

[Back to Home](index.md)

</div>
