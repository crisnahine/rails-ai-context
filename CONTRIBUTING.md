# Contributing to rails-ai-context

Thanks for your interest in contributing! This guide covers everything you need to get started.

## Development Setup

```bash
git clone https://github.com/crisnahine/rails-ai-context.git
cd rails-ai-context
bundle install
bundle exec rspec
bundle exec rubocop --parallel
```

The test suite uses [Combustion](https://github.com/pat/combustion) to boot a minimal Rails app in `spec/internal/`. No external database required - tests run against an in-memory SQLite database.

## Project Structure

```
lib/rails_ai_context/
├── cli/               # CLI tool runner (tool_runner.rb) - executes MCP tools from rake/Thor
├── introspectors/     # 40 introspectors (schema, models, routes, etc.)
├── tools/             # 35 MCP tools with detail levels and pagination
├── serializers/       # Per-assistant formatters + shared ToolGuideHelper
├── server.rb          # MCP server setup (stdio + HTTP)
├── live_reload.rb     # MCP live reload (file watcher + cache invalidation)
├── engine.rb          # Rails Engine for auto-integration
└── configuration.rb   # User-facing config (presets, context_mode, tool_mode, limits)
```

## Adding a New Introspector

1. Create `lib/rails_ai_context/introspectors/your_introspector.rb` (auto-loaded by Zeitwerk)
2. Subclass `Introspectors::Base` (it holds `app` and `root`) and implement `#call` → returns a Hash. Let it raise: the loop in `Introspector#call` records a failed section as `{ error: msg }` and warns
3. Register it in `lib/rails_ai_context/introspector.rb` (the `INTROSPECTOR_MAP`)
4. `extend StaticTier` and declare one: `static_tier :files_only` if `#call` runs unchanged with nothing booted, `:runtime_only` if it needs live reflection, or `:alternate_source` plus a `static_call` reading elsewhere. A mapped introspector that declares nothing fails the suite
5. If it opens a file outside the fingerprint's watched folders and extensions, declare `READS = %w[...]` (globs from the app root), or an edit to that file is not seen until a restart (see **READS** in `GLOSSARY.md`)
6. Add the key to the appropriate preset(s) in `Configuration::PRESETS` (`:full` is the default, `:standard` for core-only)
7. Write specs in `spec/lib/rails_ai_context/introspectors/your_introspector_spec.rb`

## Adding a New MCP Tool

1. Create `lib/rails_ai_context/tools/your_tool.rb` inheriting from `BaseTool` (auto-loaded by Zeitwerk)
2. Define `tool_name`, `description`, `input_schema`, and `annotations`
3. Implement `def self.call(...)` returning `text_response(string)`
4. Declare `guide_row(order:, mcp:, cli_args:, summary:)` - the generated guide is derived from it. A tool without one fails the inventory spec, and `order` must be unique and leave no gap in the sequence
5. Auto-registered - no manual list to update (BaseTool.inherited tracks it)
6. Write specs in `spec/lib/rails_ai_context/tools/your_tool_spec.rb`

## Adding a Prism Listener

Listeners extract specific concerns (associations, validations, etc.) from the AST via `Prism::Dispatcher` events.

1. Create `lib/rails_ai_context/introspectors/listeners/your_listener.rb` inheriting from `BaseListener`
2. Implement `on_call_node_enter(node)` and/or `on_def_node_enter(node)` - only the events your concern needs
3. Use `confidence_for(node)` from `BaseListener` to tag results `[VERIFIED]` or `[INFERRED]`
4. Store results in `@results` (accessed via `#results`) as plain hashes, never Prism nodes
5. Nothing to register - `ListenerRegistration` derives the events from the `on_*` methods you defined, and raises if one names an event prism never dispatches
6. Register the key/class pair in `SourceIntrospector::LISTENER_MAP` only if the listener should run on every model walk; listeners used by one introspector are passed to `SourceIntrospector.walk(path, key => Listener)` at the call site instead
7. Write specs in `spec/lib/rails_ai_context/introspectors/listeners/your_listener_spec.rb`
8. Add a row to the listener catalogue in `docs/INTROSPECTORS.md`

See existing listeners in `lib/rails_ai_context/introspectors/listeners/` for reference patterns, and `docs/INTROSPECTORS.md` for the catalogue and the AST-vs-regex rule.

## Adding a CLI Tool Interface

The `ToolRunner` (`lib/rails_ai_context/cli/tool_runner.rb`) handles CLI execution of all MCP tools. It is tested in `spec/lib/rails_ai_context/cli/tool_runner_spec.rb`. If you add a new MCP tool, it is automatically available via CLI - no extra registration needed. Tool name resolution (`schema` → `get_schema` → `rails_get_schema`) works for all tools.

## Code Style

- Follow `rubocop-rails-omakase` style (run `bundle exec rubocop`)
- Target Ruby 3.1 (the gem's floor). Ruby 3.2+ features (`Data.define`, `Regexp` `timeout:`, etc.) need a runtime-guarded fallback so 3.1 keeps working
- Support Rails 7.0 through 8.1. Guard Rails 7.1+ APIs with `respond_to?`/`defined?` so introspectors degrade cleanly on 7.0
- Every introspector returns a Hash. Let a failure raise: the loop in `Introspector#call` records it as `{ error: msg }` and warns, so no introspector wraps its own errors
- Read Ruby source with Prism or a listener. A regex kept over Ruby runs on `RubySource.code_only` or `RubySource.without_comments` text, so a comment, a string or a heredoc cannot match (the AST-vs-regex rule in `docs/INTROSPECTORS.md`)
- MCP tools return `MCP::Tool::Response` objects
- All tools must be prefixed with `rails_` and annotated as read-only

## Running Tests

```bash
bundle exec rspec              # Full test suite
bundle exec rspec spec/lib/    # Just lib specs
bundle exec rubocop --parallel # Lint check
```

### Real database servers

The suite runs on SQLite. `spec/lib/rails_ai_context/database_family/database_servers_spec.rb`
runs the PostgreSQL, MySQL and MariaDB families against real database servers, one group
per URL that is set. `spec/lib/rails_ai_context/tools/query_postgresql_spec.rb` and
`query_mysql_spec.rb` beside it run `rails_query` end to end on the same URLs.
`spec/lib/rails_ai_context/app_databases_servers_spec.rb` leases a MySQL and a MariaDB
database by name, and runs with `RAC_TEST_MYSQL_URL` and `RAC_TEST_MARIADB_URL`:

| Variable | Database server | Example |
|---|---|---|
| `RAC_TEST_PG_URL` | PostgreSQL | `postgresql://postgres:secret@127.0.0.1:5432/rac` |
| `RAC_TEST_MYSQL_URL` | MySQL, through mysql2 or Trilogy | `trilogy://root:secret@127.0.0.1:3306/rac` |
| `RAC_TEST_MARIADB_URL` | MariaDB, through mysql2 or Trilogy | `trilogy://root:secret@127.0.0.1:3307/rac` |

The URL's scheme picks the adapter. The drivers come from a separate Gemfile:

```bash
docker run -d --name rac-mysql -e MYSQL_ROOT_PASSWORD=secret -e MYSQL_DATABASE=rac -p 3306:3306 mysql:8.4
BUNDLE_GEMFILE=gemfiles/database_servers.gemfile bundle install
RAC_TEST_MYSQL_URL=trilogy://root:secret@127.0.0.1:3306/rac \
  BUNDLE_GEMFILE=gemfiles/database_servers.gemfile bundle exec rspec spec/lib/rails_ai_context/database_family/database_servers_spec.rb
```

The specs create and drop tables and views whose names start with `rac_`, and leave the `postgres_fdw` extension installed on PostgreSQL, so point them at a scratch database.
CI's `database_servers` job runs them on PostgreSQL 16 in every leg. Rails 8.0 runs two legs: MySQL 8.0 with MariaDB 10.6, and MySQL 8.4 with MariaDB 11.4. Rails 7.0 runs MySQL 8.0 with MariaDB 10.6, and Rails 8.1 runs MySQL 8.4 with MariaDB 11.4.
Rails 7.0 has no Trilogy adapter, so its leg runs PostgreSQL and mysql2 only.
The `postgresql_versions` job runs the PostgreSQL specs on PostgreSQL 13, 14, 15, 17 and 18 on Rails 8.0, since the plan checks read the plan the server prints.
The job builds mysql2 against MariaDB's client library (`libmariadb-dev`, through `BUNDLE_BUILD__MYSQL2`), which signs in to MySQL and to MariaDB. A MySQL client from 9.0 on cannot sign in to MariaDB.

### Static fixture

`spec/fixtures/static_app` is the app the static tier is exercised against, and
`spec/lib/rails_ai_context/serializers/real_shape_smoke_spec.rb` pins its model
count in three assertions (a `Models 7` match and `Models (7)` twice).

Adding or removing a fixture model means changing that spec in the same commit.

## Pull Request Process

1. Fork the repo and create your branch from `main`
2. Add tests for any new functionality
3. Ensure `bundle exec rspec` and `bundle exec rubocop` pass
4. Update CHANGELOG.md under an `## [Unreleased]` section
5. Open a PR with a clear title and description

## Releasing

`docs/RELEASING.md` is the checklist. The tag publishes, not the merge, and the
release gate wants a green E2E run for the tagged commit before it will start.

## The website

`site/` is the page at <https://crisnahine.github.io/rails-ai-context/>, and `scripts/site.rb` fills it
in from the repository: the install prompt from `docs/PROMPTS.md`, the tool list and the counts from the
registry and the introspector map, every page under `docs/` rendered with the same layout, and the
answers it shows recorded by running the gem's own binary against `site/sample_app` in the static tier.
Change the words in `site/index.html` and the facts where they live. To see it before pushing:

```bash
bundle exec ruby scripts/site.rb _site
python3 -m http.server 8000 -d _site
```

Any static file server will do, and a server it has to be: a browser loads no module script from a
`file://` page. The script writes only into a new directory or one it wrote before. A placeholder
nothing fills, a heading a quoted block has lost, a tool `docs/TOOLS.md` files under no category, a
docs page `Site::DOC_NAV` does not place, or a tool call that fails stops the build, and
`spec/site_spec.rb` names which. `.github/workflows/pages.yml` builds the site on every pull request,
since a change to the gem changes the answers on the page, and deploys it from `main`, where the
repository's Pages source has to be GitHub Actions.

The sample app is a fixture with no `config/environment.rb`, so every tool reads it without booting. A change to it changes the answers on the page, and the README quotes some of
them, so check both.

## Reporting Bugs

Open an issue at https://github.com/crisnahine/rails-ai-context/issues with:
- Ruby and Rails versions
- Gem version
- Steps to reproduce
- Expected vs actual behavior
