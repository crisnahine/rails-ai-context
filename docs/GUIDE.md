# rails-ai-context — Complete Guide

> Full documentation for [rails-ai-context](https://github.com/crisnahine/rails-ai-context).
> For a quick overview, see the [README](../README.md).

---

## Table of Contents

- [Installation](#installation)
- [Context Modes](#context-modes)
- [Generated Files](#generated-files)
- [All Commands](#all-commands)
- [MCP Tools — Full Reference](#mcp-tools--full-reference)
- [MCP Resources](#mcp-resources)
- [MCP Server Setup](#mcp-server-setup)
- [Configuration — All Options](#configuration--all-options)
- [Introspectors — Full List](#introspectors--full-list)
- [AI Assistant Setup](#ai-assistant-setup)
- [Stack Compatibility](#stack-compatibility)
- [Diagnostics](#diagnostics)
- [Watch Mode](#watch-mode)
- [Works Without a Database](#works-without-a-database)
- [Security](#security)
- [Troubleshooting](#troubleshooting)

---

## Installation

### New project

```bash
bundle add rails-ai-context
rails generate rails_ai_context:install
rails ai:context
```

This creates:
1. `config/initializers/rails_ai_context.rb` — configuration file
2. `.mcp.json` — MCP auto-discovery for Claude Code and Cursor
3. 20 context files — tailored for each AI assistant

### Existing project

```bash
# Add to Gemfile
gem "rails-ai-context"

# Install
bundle install
rails generate rails_ai_context:install

# Generate context files
rails ai:context

# Verify everything works
rails ai:doctor
```

### What the install generator does

1. Creates `.mcp.json` in project root (MCP auto-discovery)
2. Creates `config/initializers/rails_ai_context.rb` with commented defaults
3. Adds `.ai-context.json` to `.gitignore` (JSON cache — markdown files should be committed)
4. Generates all context files

---

## Context Modes

The gem has two context modes that control how much data goes into the generated files:

### Compact mode (default)

```bash
rails ai:context
```

- CLAUDE.md ≤150 lines
- .windsurfrules ≤5,800 characters
- copilot-instructions.md ≤500 lines
- Files contain a project overview + MCP tool reference
- AI uses MCP tools for detailed data on-demand
- **Best for:** all apps, especially large ones (30+ models)

### Full mode

```bash
rails ai:context:full
# or
CONTEXT_MODE=full rails ai:context
```

- Dumps everything into context files (schema, all models, all routes, etc.)
- Can produce thousands of lines for large apps
- **Best for:** small apps (<30 models) where the full dump fits in context

### Per-format with mode override

```bash
# Full dump for Claude only, compact for everything else
CONTEXT_MODE=full rails ai:context:claude

# Full dump for Cursor only
CONTEXT_MODE=full rails ai:context:cursor

# Full dump for Windsurf only (still respects 6K char limit)
CONTEXT_MODE=full rails ai:context:windsurf

# Full dump for Copilot only
CONTEXT_MODE=full rails ai:context:copilot
```

### Set mode in configuration

```ruby
# config/initializers/rails_ai_context.rb
RailsAiContext.configure do |config|
  config.context_mode = :full  # or :compact (default)
end
```

---

## Generated Files

`rails ai:context` generates **20 files** across all AI assistants:

### Claude Code (4 files)

| File | Purpose | Notes |
|------|---------|-------|
| `CLAUDE.md` | Main context file | ≤150 lines in compact mode. Claude Code reads this automatically. |
| `.claude/rules/rails-schema.md` | Database table listing | Auto-loaded by Claude Code alongside CLAUDE.md. |
| `.claude/rules/rails-models.md` | Model listing with associations | Auto-loaded by Claude Code alongside CLAUDE.md. |
| `.claude/rules/rails-mcp-tools.md` | Full MCP tool reference | Parameters, detail levels, pagination, workflow guide. |

### OpenCode (3 files)

| File | Purpose | Notes |
|------|---------|-------|
| `AGENTS.md` | Main context file | Native OpenCode format. ≤150 lines in compact mode. OpenCode also reads CLAUDE.md as fallback. |
| `app/models/AGENTS.md` | Model reference | Auto-loaded by OpenCode when reading files in `app/models/`. |
| `app/controllers/AGENTS.md` | Controller reference | Auto-loaded by OpenCode when reading files in `app/controllers/`. |

### Cursor (5 files)

| File | Purpose | Notes |
|------|---------|-------|
| `.cursor/rules/rails-project.mdc` | Project overview | `alwaysApply: true` — loaded in every conversation. |
| `.cursor/rules/rails-models.mdc` | Model reference | `globs: app/models/**/*.rb` — auto-attaches when editing models. |
| `.cursor/rules/rails-controllers.mdc` | Controller reference | `globs: app/controllers/**/*.rb` — auto-attaches when editing controllers. |
| `.cursor/rules/rails-mcp-tools.mdc` | MCP tool reference | `alwaysApply: true` — always available. |

### Windsurf (3 files)

| File | Purpose | Notes |
|------|---------|-------|
| `.windsurfrules` | Main context file | Hard-capped at 5,800 chars (Windsurf's 6K limit). Truncated silently if exceeded. |
| `.windsurf/rules/rails-context.md` | Project overview | New Windsurf rules format. |
| `.windsurf/rules/rails-mcp-tools.md` | MCP tool reference | Compact — respects 6K per-file limit. |

### GitHub Copilot (4 files)

| File | Purpose | Notes |
|------|---------|-------|
| `.github/copilot-instructions.md` | Repo-wide instructions | ≤500 lines in compact mode. |
| `.github/instructions/rails-models.instructions.md` | Model context | `applyTo: app/models/**/*.rb` — loaded when editing models. |
| `.github/instructions/rails-controllers.instructions.md` | Controller context | `applyTo: app/controllers/**/*.rb` — loaded when editing controllers. |
| `.github/instructions/rails-mcp-tools.instructions.md` | MCP tool reference | `applyTo: **/*` — loaded everywhere. |

### Generic (1 file)

| File | Purpose | Notes |
|------|---------|-------|
| `.ai-context.json` | Full structured JSON | For programmatic access or custom tooling. Added to `.gitignore`. |

### Which files to commit

Commit **all files except `.ai-context.json`** (which is gitignored). This gives your entire team AI-assisted context automatically.

---

## All Commands

### Context generation

| Command | Mode | Format | Description |
|---------|------|--------|-------------|
| `rails ai:context` | compact | all | Generate all 20 context files |
| `rails ai:context:full` | full | all | Generate all files in full mode |
| `rails ai:context:claude` | compact | Claude | CLAUDE.md + .claude/rules/ |
| `rails ai:context:opencode` | compact | OpenCode | AGENTS.md + per-directory AGENTS.md |
| `rails ai:context:cursor` | compact | Cursor | .cursor/rules/ |
| `rails ai:context:windsurf` | compact | Windsurf | .windsurfrules + .windsurf/rules/ |
| `rails ai:context:copilot` | compact | Copilot | copilot-instructions.md + .github/instructions/ |
| `rails ai:context:json` | — | JSON | .ai-context.json |
| `CONTEXT_MODE=full rails ai:context:claude` | full | Claude | Full dump for Claude only |
| `CONTEXT_MODE=full rails ai:context:cursor` | full | Cursor | Full dump for Cursor only |
| `CONTEXT_MODE=full rails ai:context:windsurf` | full | Windsurf | Full dump for Windsurf only |
| `CONTEXT_MODE=full rails ai:context:copilot` | full | Copilot | Full dump for Copilot only |

### MCP server

| Command | Transport | Description |
|---------|-----------|-------------|
| `rails ai:serve` | stdio | Start MCP server for Claude Code / Cursor. Auto-discovered via `.mcp.json`. |
| `rails ai:serve_http` | HTTP | Start MCP server at `http://127.0.0.1:6029/mcp`. For remote clients. |

### Utilities

| Command | Description |
|---------|-------------|
| `rails ai:doctor` | Run 13 diagnostic checks. Reports pass/warn/fail with fix suggestions. AI readiness score (0-100). |
| `rails ai:watch` | Watch for file changes and auto-regenerate context files. Requires `listen` gem. |
| `rails ai:inspect` | Print introspection summary to stdout. Useful for debugging. |

### Standalone CLI

The gem ships a `rails-ai-context` executable as an alternative to rake tasks. Useful for `.mcp.json` configs or when you prefer a shorter command.

```bash
rails-ai-context serve                     # Start MCP server (stdio)
rails-ai-context serve --transport http    # Start MCP server (HTTP, port 6029)
rails-ai-context serve --transport http --port 8080  # Custom port
rails-ai-context context                   # Generate all context files
rails-ai-context context --format claude   # Generate Claude files only
rails-ai-context doctor                    # Run diagnostics
rails-ai-context watch                     # Watch for changes
rails-ai-context inspect                   # Print introspection JSON
rails-ai-context version                   # Print version
rails-ai-context help                      # Show all commands
```

Must be run from your Rails app root directory (requires `config/environment.rb`).

### Legacy command

```bash
rails 'ai:context_for[claude]'   # Requires quoting in zsh
rails ai:context:claude           # Use this instead (no quoting needed)
```

---

## MCP Tools — Full Reference

All 12 tools are **read-only** and **idempotent** — they never modify your application or database.

### rails_get_schema

Returns database schema: tables, columns, indexes, foreign keys.

**Parameters:**

| Param | Type | Description |
|-------|------|-------------|
| `table` | string | Specific table name for full detail. Omit for listing. |
| `detail` | string | `summary` / `standard` (default) / `full` |
| `limit` | integer | Max tables to return. Default: 50 (summary), 15 (standard), 5 (full). |
| `offset` | integer | Skip tables for pagination. Default: 0. |
| `format` | string | `markdown` (default) / `json` |

**Examples:**

```
rails_get_schema()
  → Standard detail, first 15 tables with column names and types

rails_get_schema(detail: "summary")
  → All tables with column and index counts (up to 50)

rails_get_schema(table: "users")
  → Full detail for users table: columns, types, nullable, defaults, indexes, FKs

rails_get_schema(detail: "summary", limit: 20, offset: 40)
  → Tables 41-60 with column counts

rails_get_schema(detail: "full", format: "json")
  → Full schema as JSON (all tables)
```

### rails_get_model_details

Returns model details: associations, validations, scopes, enums, callbacks, concerns.

**Parameters:**

| Param | Type | Description |
|-------|------|-------------|
| `model` | string | Model class name (e.g. `User`). Case-insensitive. Omit for listing. |
| `detail` | string | `summary` / `standard` (default) / `full`. Ignored when model is specified. |

**Examples:**

```
rails_get_model_details()
  → Standard: all model names with association and validation counts

rails_get_model_details(detail: "summary")
  → Just model names, one per line

rails_get_model_details(model: "User")
  → Full detail: table, associations, validations, enums, scopes, callbacks, concerns, methods

rails_get_model_details(model: "user")
  → Same as above (case-insensitive)

rails_get_model_details(detail: "full")
  → All models with full association lists
```

### rails_get_routes

Returns all routes: HTTP verbs, paths, controller actions, route names.

**Parameters:**

| Param | Type | Description |
|-------|------|-------------|
| `controller` | string | Filter by controller name (e.g. `users`, `api/v1/posts`). Case-insensitive. |
| `detail` | string | `summary` / `standard` (default) / `full` |
| `limit` | integer | Max routes to return. Default: 100 (standard), 200 (full). |
| `offset` | integer | Skip routes for pagination. Default: 0. |

**Examples:**

```
rails_get_routes()
  → Standard: routes grouped by controller with verb, path, action

rails_get_routes(detail: "summary")
  → Route counts per controller with verb breakdown

rails_get_routes(controller: "users")
  → All routes for UsersController

rails_get_routes(controller: "api")
  → All routes matching "api" (partial match, case-insensitive)

rails_get_routes(detail: "full", limit: 50)
  → Full table with route names, first 50 routes

rails_get_routes(detail: "standard", limit: 20, offset: 100)
  → Routes 101-120
```

### rails_get_controllers

Returns controller details: actions, filters, strong params, concerns.

**Parameters:**

| Param | Type | Description |
|-------|------|-------------|
| `controller` | string | Specific controller name (e.g. `UsersController`). Case-insensitive. |
| `detail` | string | `summary` / `standard` (default) / `full`. Ignored when controller is specified. |

**Examples:**

```
rails_get_controllers()
  → Standard: controller names with action lists

rails_get_controllers(detail: "summary")
  → Controller names with action counts

rails_get_controllers(controller: "UsersController")
  → Full detail: parent class, actions, filters (with only/except), strong params

rails_get_controllers(detail: "full")
  → All controllers with actions, filters, and strong params
```

### rails_get_config

Returns application configuration. No parameters.

**Returns:** cache store, session store, timezone, middleware stack, initializers, credentials keys, current attributes.

```
rails_get_config()
  → Cache: redis_cache_store, Session: cookie_store, TZ: UTC, ...
```

### rails_get_test_info

Returns test infrastructure details. No parameters.

**Returns:** test framework (rspec/minitest), factories/fixtures with locations and counts, system tests, CI config, coverage tool, test helpers.

```
rails_get_test_info()
  → Framework: rspec, Factories: spec/factories (12 files), CI: .github/workflows/ci.yml, ...
```

### rails_get_gems

Returns notable gems categorized by function. No parameters.

**Returns:** 70+ recognized gems grouped by category (auth, background_jobs, admin, monitoring, search, pagination, etc.) with versions and descriptions.

```
rails_get_gems()
  → auth: devise (4.9.3), background_jobs: sidekiq (7.2.1), ...
```

### rails_get_conventions

Returns detected architecture patterns. No parameters.

**Returns:** architecture patterns (MVC, service objects, STI, etc.), directory structure with file counts, config files, detected patterns.

```
rails_get_conventions()
  → Architecture: [MVC, Service objects, Concerns], Patterns: [STI, Polymorphism], ...
```

### rails_search_code

Ripgrep-powered regex search across the codebase.

**Parameters:**

| Param | Type | Description |
|-------|------|-------------|
| `pattern` | string | **Required.** Regex pattern to search for. |
| `file_type` | string | Filter by file type (e.g. `rb`, `erb`, `js`). Alphanumeric only. |
| `max_results` | integer | Max results to return. Default: 20, max: 100. |

**Examples:**

```
rails_search_code(pattern: "has_secure_password")
  → All files containing has_secure_password

rails_search_code(pattern: "class.*Controller", file_type: "rb")
  → All Ruby files with controller class definitions

rails_search_code(pattern: "def create", file_type: "rb", max_results: 50)
  → First 50 create methods across the codebase
```

**Security:** Uses `Open3.capture2` with array arguments (no shell injection). Validates file_type. Blocks path traversal. Respects `excluded_paths` config.

### Detail Level Summary

| Level | What it returns | Default limit | Best for |
|-------|----------------|---------------|----------|
| `summary` | Names + counts | 50 | Getting the landscape, understanding what exists |
| `standard` | Names + key details | 15 | Working context, column types, action names |
| `full` | Everything | 5 | Deep inspection, indexes, FKs, constraints |

### Recommended Workflow

1. **Start with `detail:"summary"`** to see what exists
2. **Filter by name** (`table:`, `model:`, `controller:`) for the item you need
3. **Use `detail:"full"`** only when you need indexes, foreign keys, or constraints
4. **Paginate** with `limit` and `offset` for large result sets

---

## MCP Resources

In addition to tools, the gem registers static MCP resources that AI clients can read directly:

| Resource URI | Description |
|-------------|-------------|
| `rails://schema` | Full database schema (JSON) |
| `rails://routes` | All routes (JSON) |
| `rails://conventions` | Detected patterns and architecture (JSON) |
| `rails://gems` | Notable gems with categories (JSON) |
| `rails://controllers` | All controllers with actions and filters (JSON) |
| `rails://config` | Application configuration (JSON) |
| `rails://tests` | Test infrastructure details (JSON) |
| `rails://migrations` | Migration history and statistics (JSON) |
| `rails://engines` | Mounted engines with paths and descriptions (JSON) |
| `rails://models/{name}` | Per-model details (resource template) |

---

## MCP Server Setup

### MCP Registry

This server is listed on the [official MCP Registry](https://registry.modelcontextprotocol.io) as `io.github.crisnahine/rails-ai-context`.

```bash
# Search for it
curl "https://registry.modelcontextprotocol.io/v0.1/servers?search=rails-ai-context"
```

### Auto-discovery (recommended)

The install generator creates `.mcp.json` in your project root:

```json
{
  "mcpServers": {
    "rails-ai-context": {
      "command": "bundle",
      "args": ["exec", "rails", "ai:serve"]
    }
  }
}
```

**Claude Code** and **Cursor** auto-detect this file. No manual config needed — just open your project.

### Claude Code

Auto-discovered via `.mcp.json`. Or add manually:

```bash
claude mcp add rails-ai-context -- bundle exec rails ai:serve
```

### Claude Desktop

Add to `~/Library/Application Support/Claude/claude_desktop_config.json` (macOS) or `%APPDATA%\Claude\claude_desktop_config.json` (Windows):

```json
{
  "mcpServers": {
    "rails-ai-context": {
      "command": "bundle",
      "args": ["exec", "rails", "ai:serve"],
      "cwd": "/path/to/your/rails/app"
    }
  }
}
```

### Cursor

Auto-discovered via `.mcp.json`. Or add manually in **Cursor Settings > MCP**:

```json
{
  "mcpServers": {
    "rails-ai-context": {
      "command": "bundle",
      "args": ["exec", "rails", "ai:serve"],
      "cwd": "/path/to/your/rails/app"
    }
  }
}
```

### HTTP transport

For browser-based or remote AI clients:

```bash
rails ai:serve_http
# Starts at http://127.0.0.1:6029/mcp
```

Or auto-mount inside your Rails app (no separate process):

```ruby
RailsAiContext.configure do |config|
  config.auto_mount = true
  config.http_path  = "/mcp"   # default
  config.http_port  = 6029     # default
  config.http_bind  = "127.0.0.1"  # default (localhost only)
end
```

Both transports are **read-only** — they expose the same 12 tools and never modify your app.

---

## Configuration — All Options

```ruby
# config/initializers/rails_ai_context.rb
RailsAiContext.configure do |config|
  # --- Introspectors ---

  # Presets: :standard (12 core, default) or :full (all 28)
  config.preset = :standard

  # Cherry-pick on top of a preset
  config.introspectors += %i[views turbo auth api]

  # --- Context files ---

  # Context mode: :compact (default) or :full
  config.context_mode = :compact

  # Max lines for CLAUDE.md in compact mode
  config.claude_max_lines = 150

  # Output directory for context files (default: Rails.root)
  # config.output_dir = "/custom/path"

  # --- MCP tools ---

  # Max response size for tool results (safety net)
  config.max_tool_response_chars = 120_000

  # Cache TTL for introspection results (seconds)
  config.cache_ttl = 30

  # --- Exclusions ---

  # Models to skip during introspection
  config.excluded_models += %w[AdminUser InternalAuditLog]

  # Paths to exclude from code search
  config.excluded_paths += %w[vendor/bundle]

  # --- Live reload ---

  # Auto-invalidate MCP tool caches on file changes
  # :auto — enable if `listen` gem is available (default)
  # true  — enable, raise if `listen` is missing
  # false — disable entirely
  config.live_reload = :auto
  config.live_reload_debounce = 1.5  # seconds

  # --- HTTP MCP endpoint ---

  # Auto-mount Rack middleware for HTTP MCP
  config.auto_mount = false
  config.http_path  = "/mcp"
  config.http_bind  = "127.0.0.1"
  config.http_port  = 6029
end
```

### Options reference

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `preset` | Symbol | `:standard` | Introspector preset (`:standard` or `:full`) |
| `introspectors` | Array | 12 core symbols | Which introspectors to run |
| `context_mode` | Symbol | `:compact` | `:compact` or `:full` |
| `claude_max_lines` | Integer | `150` | Max lines for CLAUDE.md in compact mode |
| `max_tool_response_chars` | Integer | `120_000` | Safety cap for MCP tool responses |
| `cache_ttl` | Integer | `30` | Cache TTL in seconds for introspection results |
| `excluded_models` | Array | internal Rails models | Models to skip |
| `excluded_paths` | Array | `node_modules tmp log vendor .git` | Paths excluded from code search |
| `output_dir` | String | `nil` (Rails.root) | Where to write context files |
| `auto_mount` | Boolean | `false` | Auto-mount HTTP MCP endpoint |
| `http_path` | String | `"/mcp"` | HTTP endpoint path |
| `http_bind` | String | `"127.0.0.1"` | HTTP bind address |
| `http_port` | Integer | `6029` | HTTP server port |
| `live_reload` | Symbol/Boolean | `:auto` | `:auto`, `true`, or `false` — enable MCP live reload |
| `live_reload_debounce` | Float | `1.5` | Debounce interval in seconds for live reload |
| `server_name` | String | `"rails-ai-context"` | MCP server name |
| `generate_root_files` | Boolean | `true` | Generate root files (CLAUDE.md, .windsurfrules, etc.) — set `false` for split rules only |

### Root file generation

By default, `rails ai:context` generates root files (CLAUDE.md, AGENTS.md, .windsurfrules, etc.) alongside split rules.

**Section markers:** Generated content is wrapped in `<!-- BEGIN rails-ai-context -->` / `<!-- END rails-ai-context -->` markers. If you add custom notes above or below the markers, they will be preserved when you re-run `rails ai:context`.

**Skip root files:** If you prefer to maintain root files yourself and only want split rules (`.claude/rules/`, `.cursor/rules/`, `.windsurf/rules/`, `.github/instructions/`):

```ruby
RailsAiContext.configure do |config|
  config.generate_root_files = false
end
```

All split rules include an app overview file, so no context is lost when root files are disabled.

---

## Introspectors — Full List

### Standard preset (9 introspectors)

These run by default. Fast and cover core Rails structure.

| Introspector | What it discovers |
|-------------|-------------------|
| `schema` | Tables, columns, types, indexes, foreign keys, primary keys. Falls back to `db/schema.rb` parsing when no DB connected. |
| `models` | Associations, validations, scopes, enums, callbacks, concerns, instance methods, class methods. Source-level macros: `has_secure_password`, `encrypts`, `normalizes`, `delegate`, `serialize`, `store`, `generates_token_for`, `has_one_attached`, `has_many_attached`, `has_rich_text`, `broadcasts_to`. |
| `routes` | All routes with HTTP verbs, paths, controller actions, route names, API namespaces, mounted engines. |
| `jobs` | ActiveJob classes with queue names. Mailers with action methods. Action Cable channels. |
| `gems` | 70+ notable gems categorized: auth, background_jobs, admin, monitoring, search, pagination, forms, file_upload, testing, linting, security, api, frontend, utilities. |
| `conventions` | Architecture patterns (MVC, service objects, STI, polymorphism, etc.), directory structure with file counts, config files, detected patterns. |
| `controllers` | Actions, filters (before/after/around with only/except), strong params methods, parent class, API controller detection, concerns. |
| `tests` | Test framework (rspec/minitest), factories/fixtures with locations and counts, system tests, CI config files, coverage tool, test helpers, VCR cassettes. |
| `migrations` | Total count, schema version, pending migrations, recent migration history with detected actions (create_table, add_column, etc.), migration statistics. |

### Full preset (29 introspectors)

Includes all standard introspectors plus:

| Introspector | What it discovers |
|-------------|-------------------|
| `stimulus` | Stimulus controllers with targets, values (with types), actions, outlets, classes. Extracted from JS/TS files. |
| `views` | Layouts, templates grouped by controller, partials (per-controller and shared), helpers with methods, template engines (erb, haml, slim), view components. |
| `turbo` | Turbo Frames (IDs and files), Turbo Stream templates, model broadcasts (`broadcasts_to`, `broadcasts`). |
| `i18n` | Default locale, available locales, locale files with key counts, backend class, parse errors. |
| `config` | Cache store, session store, timezone, middleware stack, initializers, credentials keys, CurrentAttributes classes. |
| `active_storage` | Attachments (has_one_attached, has_many_attached per model), storage services, direct upload config. |
| `action_text` | Rich text fields (has_rich_text per model), Action Text installation status. |
| `auth` | Devise models with modules, Rails 8 built-in auth, has_secure_password, Pundit policies, CanCanCan, CORS config, CSP config. |
| `api` | API-only mode, API versioning (from directory structure), serializers (Jbuilder, AMS, etc.), GraphQL (types, mutations), rate limiting (Rack::Attack). |
| `rake_tasks` | Custom rake tasks in `lib/tasks/` with names, descriptions, namespaces, file paths. |
| `assets` | Asset pipeline (Propshaft/Sprockets), JS bundler (importmap/esbuild/webpack/vite), CSS framework, importmap pins, manifest files. |
| `devops` | Puma config (threads, workers, port), Procfile entries, Docker (multi-stage detection), deployment tools, health check routes. |
| `action_mailbox` | Action Mailbox mailboxes with routing patterns. |
| `seeds` | db/seeds.rb analysis (Faker usage, environment conditionals), seed files in db/seeds/, models seeded. |
| `middleware` | Custom Rack middleware in app/middleware/ with detected patterns (auth, rate limiting, tenant isolation, logging). Full middleware stack. |
| `engines` | Mounted Rails engines from routes.rb with paths and descriptions for 23+ known engines (Sidekiq::Web, Flipper::UI, PgHero, ActiveAdmin, etc.). |
| `multi_database` | Multiple databases, replicas, sharding config, model-specific `connects_to` declarations. database.yml parsing fallback. |
| `database_stats` | PostgreSQL approximate row counts via `pg_stat_user_tables`. Opt-in, requires PostgreSQL. |

### Enabling the full preset

```ruby
config.preset = :full
```

### Cherry-picking introspectors

```ruby
# Start with standard, add specific ones
config.introspectors += %i[views turbo auth api stimulus]

# Or build from scratch
config.introspectors = %i[schema models routes gems auth api]
```

---

## AI Assistant Setup

### Claude Code

**Auto-discovery:** Opens `.mcp.json` automatically. No setup needed.

**Context files loaded:**
- `CLAUDE.md` — read at conversation start
- `.claude/rules/*.md` — auto-loaded alongside CLAUDE.md

**MCP tools:** Available immediately via `.mcp.json`.

### Cursor

**Auto-discovery:** Opens `.mcp.json` automatically. No setup needed.

**Context files loaded:**
- `.cursor/rules/*.mdc` — loaded based on `alwaysApply` and `globs` settings

**MDC rule activation modes:**
| Mode | When it activates |
|------|-------------------|
| `alwaysApply: true` | Every conversation (project overview, MCP tools) |
| `globs: ["app/models/**/*.rb"]` | When editing files matching the glob pattern |
| `alwaysApply: false` + `description` | When the AI decides it's relevant based on description |

### OpenCode

**MCP config:** Add to `opencode.json`:

```json
{
  "mcp": {
    "rails-ai-context": {
      "type": "local",
      "command": ["bundle", "exec", "rails", "ai:serve"]
    }
  }
}
```

**Context files loaded:**
- `AGENTS.md` — project overview + MCP tool guide, read at conversation start
- `app/models/AGENTS.md` — model listing, auto-loaded when agent reads model files
- `app/controllers/AGENTS.md` — controller listing, auto-loaded when agent reads controller files
- Falls back to `CLAUDE.md` if no `AGENTS.md` exists

OpenCode uses **per-directory lazy-loading**: when the agent reads a file, it walks up the directory tree and auto-loads any `AGENTS.md` it finds. This is how split rules work — no globs or frontmatter needed.

**MCP tools:** Available via `opencode.json` config above.

### Windsurf

**Context files loaded:**
- `.windsurfrules` — read at conversation start (≤6,000 chars, silently truncated if exceeded)
- `.windsurf/rules/*.md` — new rules format

**Limits:**
- 6,000 characters per rule file
- 12,000 characters total (global + workspace combined)

### GitHub Copilot

**Context files loaded:**
- `.github/copilot-instructions.md` — repo-wide instructions
- `.github/instructions/*.instructions.md` — path-specific, activated by `applyTo` glob

**applyTo patterns:**
| Pattern | When it activates |
|---------|-------------------|
| `app/models/**/*.rb` | Editing model files |
| `app/controllers/**/*.rb` | Editing controller files |
| `**/*` | All files (MCP tool reference) |

---

## Stack Compatibility

| Setup | Coverage | Notes |
|-------|----------|-------|
| Rails full-stack (ERB + Hotwire) | 29/29 | All introspectors relevant |
| Rails + Inertia.js (React/Vue) | ~22/27 | Views/Turbo partially useful, backend fully covered |
| Rails API + React/Next.js SPA | ~20/27 | Schema, models, routes, API, auth, jobs — all covered |
| Rails API + mobile app | ~20/27 | Same as SPA — backend introspection is identical |
| Rails engine (mountable gem) | ~15/27 | Core introspectors (schema, models, routes, gems) work |

Frontend introspectors (views, Turbo, Stimulus, assets) degrade gracefully — they report nothing when those features aren't present.

**Tip for API-only apps:**

```ruby
# Use standard preset (already perfect for API apps)
config.preset = :standard

# Or add API-specific introspectors
config.introspectors += %i[auth api]
```

---

## Diagnostics

```bash
rails ai:doctor
```

Runs 13 checks and reports an AI readiness score (0-100):

| Check | What it verifies |
|-------|------------------|
| Schema | db/schema.rb exists and is parseable |
| Models | Model files detected in app/models/ |
| Routes | Routes are mapped |
| Gems | Gemfile.lock exists and is parseable |
| Controllers | Controller files detected |
| Views | View templates detected |
| I18n | Locale files exist |
| Tests | Test framework detected |
| Migrations | Migration files exist |
| Context files | Generated context files exist |
| MCP Server | MCP server can be built |
| Ripgrep | `rg` binary installed (optional, falls back to Ruby) |
| Live reload | `listen` gem installed (optional, enables MCP live reload) |

Each check reports **pass**, **warn**, or **fail** with fix suggestions.

---

## Watch Mode

Auto-regenerate context files when your code changes:

```bash
rails ai:watch
```

Requires the `listen` gem:

```ruby
# Gemfile
gem "listen", group: :development
```

Watches for changes in: `app/`, `config/`, `db/`, `lib/tasks/`, and regenerates only the files that changed (diff-aware, skips unchanged files).

---

## Live Reload (MCP)

When running the MCP server via `rails ai:serve`, **live reload** automatically invalidates tool caches and notifies connected AI clients when files change — so the AI always has fresh context without manual re-querying.

### How it works

1. A background thread watches `app/`, `config/`, `db/`, and `lib/tasks/` for changes
2. On change (debounced 1.5s), it checks the file fingerprint to avoid false positives
3. If files truly changed, it:
   - Clears all MCP tool caches
   - Sends `notifications/resources/list_changed` to the AI client
   - Logs a summary of what changed (e.g., "Files changed: 2 model(s), 1 controller(s)")

### Setup

Add the `listen` gem (you may already have it from Watch Mode):

```ruby
# Gemfile
gem "listen", group: :development
```

Live reload is **enabled by default** when the `listen` gem is available. No configuration needed.

### Configuration

```ruby
RailsAiContext.configure do |config|
  # :auto (default) — enable if `listen` gem is available, skip silently otherwise
  # true  — enable, raise if `listen` gem is missing
  # false — disable entirely
  config.live_reload = :auto

  # Debounce interval in seconds (default: 1.5)
  config.live_reload_debounce = 1.5
end
```

### Difference from Watch Mode

| | Watch Mode (`rails ai:watch`) | Live Reload (`rails ai:serve`) |
|---|---|---|
| **Trigger** | File changes | File changes |
| **Action** | Regenerates static context files (CLAUDE.md, etc.) | Invalidates MCP tool caches + notifies AI client |
| **Use case** | Keep committed files up to date | Keep live MCP sessions fresh |
| **Transport** | N/A (writes to disk) | stdio and HTTP |

---

## Works Without a Database

The gem gracefully degrades when no database is connected. The schema introspector parses `db/schema.rb` as text instead of querying `information_schema`.

Works in:
- CI/CD pipelines
- Claude Code sessions (no DB running)
- Docker build stages
- Read-only environments
- Any environment with source code but no running database

---

## Security

- All MCP tools are **read-only** — they never modify your application or database
- Code search uses `Open3.capture2` with array arguments — **no shell injection**
- File paths are validated against **path traversal** attacks
- Credentials and secret values are **never exposed** — only key names are introspected
- The gem makes **no outbound network requests**
- File type validation prevents arbitrary file access in code search
- `max_results` is capped at 100 to prevent resource exhaustion

---

## Troubleshooting

### MCP server not detected by Claude Code / Cursor

1. Check `.mcp.json` exists in project root
2. Verify it contains `"command": "bundle"` and `"args": ["exec", "rails", "ai:serve"]`
3. Restart Claude Code / Cursor

### Context files are too large

```ruby
# Switch to compact mode (default in v0.7+)
config.context_mode = :compact
```

### MCP tool responses are too large

```ruby
# Lower the safety cap
config.max_tool_response_chars = 60_000
```

### Schema not detected

- Ensure `db/schema.rb` exists (run `rails db:schema:dump` if needed)
- The gem works without a database — it parses schema.rb as text

### Models not detected

- Models must be in `app/models/` and inherit from `ApplicationRecord`
- Excluded models: `ApplicationRecord`, `ActiveStorage::*`, `ActionText::*`, `ActionMailbox::*`
- Add custom exclusions: `config.excluded_models += %w[InternalModel]`

### Ripgrep not found

Code search falls back to Ruby's `Dir.glob` + `File.read`. Install ripgrep for faster search:

```bash
# macOS
brew install ripgrep

# Ubuntu/Debian
sudo apt install ripgrep
```

### Watch mode not working

```bash
# Install listen gem
bundle add listen --group development

# Then run
rails ai:watch
```

### Tool responses show "not available"

The tool's introspector isn't in the active preset. Either:

```ruby
# Use full preset
config.preset = :full

# Or add the specific introspector
config.introspectors += %i[config]  # for rails_get_config
config.introspectors += %i[tests]   # for rails_get_test_info
```
