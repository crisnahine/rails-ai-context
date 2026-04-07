# rails-ai-context — Complete Guide

> Full documentation for [rails-ai-context](https://github.com/crisnahine/rails-ai-context).
> For a quick overview, see the [README](../README.md).
>
> **Why this gem exists:** AI coding assistants guess your Rails app. They invent columns,
> use wrong association names, miss inherited filters, and scaffold tests that don't match
> your patterns. This gem turns your running app into the source of truth — so agents query
> real schema, real associations, and real conventions on demand, and write correct code
> on the first try.

---

## Table of Contents

- [Installation](#installation)
- [Context Modes](#context-modes)
- [Generated Files](#generated-files)
- [All Commands](#all-commands)
- [CLI Tools](#cli-tools)
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

### Option A: In Gemfile

```bash
gem "rails-ai-context", group: :development
bundle install
rails generate rails_ai_context:install
rails ai:context
```

This creates:
1. `config/initializers/rails_ai_context.rb` — configuration file
2. `.rails-ai-context.yml` — standalone config (enables switching later)
3. `.mcp.json` — MCP auto-discovery for Claude Code and Cursor
4. Context files — tailored for each AI assistant

### Option B: Standalone (no Gemfile entry needed)

```bash
gem install rails-ai-context
cd your-rails-app
rails-ai-context init
```

This creates:
1. `.rails-ai-context.yml` — configuration file
2. `.mcp.json` — MCP auto-discovery (if MCP mode selected)
3. Context files — tailored for each AI assistant

No Gemfile entry, no initializer, no files in your project besides config and context.

### What the install generator does

1. Creates `.mcp.json` in project root (MCP auto-discovery)
2. Creates `config/initializers/rails_ai_context.rb` with commented defaults
3. Asks which AI tools you use (Claude, Cursor, Copilot, OpenCode)
4. Asks whether to enable MCP server (`tool_mode: :mcp`) or use CLI-only mode (`tool_mode: :cli`)
5. Adds `.ai-context.json` to `.gitignore` (JSON cache — markdown files should be committed)
6. Generates all context files

---

## Context Modes

The gem has two context modes that control how much data goes into the generated files:

### Compact mode (default)

```bash
rails ai:context
```

- CLAUDE.md ≤150 lines
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

# Full dump for Copilot only
CONTEXT_MODE=full rails ai:context:copilot
```

### Set mode in configuration

```ruby
# config/initializers/rails_ai_context.rb
if defined?(RailsAiContext)
  RailsAiContext.configure do |config|
    config.context_mode = :full # or :compact (default)
  end
end
```

---

## Generated Files

`rails ai:context` generates **29 files** across all AI assistants:

### Claude Code (5 files)

| File | Purpose | Notes |
|------|---------|-------|
| `CLAUDE.md` | Main context file | ≤150 lines in compact mode. Claude Code reads this automatically. |
| `.claude/rules/rails-schema.md` | Database table listing | Auto-loaded by Claude Code alongside CLAUDE.md. |
| `.claude/rules/rails-models.md` | Model listing with associations | Auto-loaded by Claude Code alongside CLAUDE.md. |
| `.claude/rules/rails-context.md` | Project context and conventions | Auto-loaded by Claude Code alongside CLAUDE.md. |
| `.claude/rules/rails-mcp-tools.md` | Full MCP tool reference | Parameters, detail levels, pagination, workflow guide. |

### OpenCode (3 files)

| File | Purpose | Notes |
|------|---------|-------|
| `AGENTS.md` | Main context file | Native OpenCode format. ≤150 lines in compact mode. OpenCode also reads CLAUDE.md as fallback. |
| `app/models/AGENTS.md` | Model reference | Auto-loaded by OpenCode when reading files in `app/models/`. |
| `app/controllers/AGENTS.md` | Controller reference | Auto-loaded by OpenCode when reading files in `app/controllers/`. |

### Cursor (4 files)

| File | Purpose | Notes |
|------|---------|-------|
| `.cursor/rules/rails-project.mdc` | Project overview | `alwaysApply: true` — loaded in every conversation. |
| `.cursor/rules/rails-models.mdc` | Model reference | `globs: app/models/**/*.rb` — auto-attaches when editing models. |
| `.cursor/rules/rails-controllers.mdc` | Controller reference | `globs: app/controllers/**/*.rb` — auto-attaches when editing controllers. |
| `.cursor/rules/rails-mcp-tools.mdc` | MCP tool reference | `alwaysApply: true` — always available. |

### GitHub Copilot (5 files)

| File | Purpose | Notes |
|------|---------|-------|
| `.github/copilot-instructions.md` | Repo-wide instructions | ≤500 lines in compact mode. |
| `.github/instructions/rails-models.instructions.md` | Model context | `applyTo: app/models/**/*.rb` — loaded when editing models. |
| `.github/instructions/rails-controllers.instructions.md` | Controller context | `applyTo: app/controllers/**/*.rb` — loaded when editing controllers. |
| `.github/instructions/rails-context.instructions.md` | Project context and conventions | `applyTo: **/*` — loaded everywhere. |
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
| `rails ai:context` | compact | all | Generate all 29 context files |
| `rails ai:context:full` | full | all | Generate all files in full mode |
| `rails ai:context:claude` | compact | Claude | CLAUDE.md + .claude/rules/ |
| `rails ai:context:opencode` | compact | OpenCode | AGENTS.md + per-directory AGENTS.md |
| `rails ai:context:cursor` | compact | Cursor | .cursor/rules/ |
| `rails ai:context:copilot` | compact | Copilot | copilot-instructions.md + .github/instructions/ |
| `rails ai:context:json` | — | JSON | .ai-context.json |
| `CONTEXT_MODE=full rails ai:context:claude` | full | Claude | Full dump for Claude only |
| `CONTEXT_MODE=full rails ai:context:cursor` | full | Cursor | Full dump for Cursor only |
| `CONTEXT_MODE=full rails ai:context:copilot` | full | Copilot | Full dump for Copilot only |

### CLI tools

| Command | Description |
|---------|-------------|
| `rails 'ai:tool[NAME]'` | Run any MCP tool from the CLI (e.g. `rails 'ai:tool[schema]' table=users detail=full`) |
| `rails ai:tool` | List all available tools with descriptions |
| `rails 'ai:tool[NAME]' JSON=1` | Run tool with JSON envelope output |

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

The gem ships a `rails-ai-context` executable that works **without adding the gem to your Gemfile**. Install globally with `gem install rails-ai-context`, then run from any Rails app directory.

```bash
rails-ai-context init                      # Interactive setup (creates .rails-ai-context.yml + .mcp.json)
rails-ai-context serve                     # Start MCP server (stdio)
rails-ai-context serve --transport http    # Start MCP server (HTTP, port 6029)
rails-ai-context serve --transport http --port 8080  # Custom port
rails-ai-context context                   # Generate all context files
rails-ai-context context --format claude   # Generate Claude files only
rails-ai-context tool                      # List all available tools
rails-ai-context tool schema --table users --detail full  # Run a tool
rails-ai-context tool schema --help        # Per-tool help
rails-ai-context tool schema --json        # JSON envelope output
rails-ai-context doctor                    # Run diagnostics
rails-ai-context watch                     # Watch for changes
rails-ai-context inspect                   # Print introspection JSON
rails-ai-context version                   # Print version
rails-ai-context help                      # Show all commands
```

Must be run from your Rails app root directory (requires `config/environment.rb`).

**Config:** Standalone mode reads from `.rails-ai-context.yml` (created by `init`). If no config file exists, defaults are used. If the gem is also in the Gemfile, the initializer takes precedence over the YAML file.

### Legacy command

```bash
rails 'ai:context_for[claude]'   # Requires quoting in zsh
rails ai:context:claude           # Use this instead (no quoting needed)
```

---

## CLI Tools

All 38 MCP tools can be run directly from the terminal — no MCP server or AI client needed.

### Rake

```bash
# Run a tool with arguments
rails 'ai:tool[schema]' table=users detail=full

# List all available tools
rails ai:tool

# JSON envelope output
rails 'ai:tool[schema]' table=users JSON=1
```

### Thor CLI

```bash
# Run a tool with arguments
rails-ai-context tool schema --table users --detail full

# List all tools
rails-ai-context tool

# Per-tool help (auto-generated from input_schema)
rails-ai-context tool schema --help

# JSON output
rails-ai-context tool schema --table users --json
```

### Tool name resolution

Short names are resolved automatically:

| You type | Resolves to |
|----------|-------------|
| `schema` | `rails_get_schema` |
| `get_schema` | `rails_get_schema` |
| `rails_get_schema` | `rails_get_schema` |
| `search_code` | `rails_search_code` |
| `analyze_feature` | `rails_analyze_feature` |

### tool_mode configuration

The `tool_mode` config controls how tool references appear in generated context files:

```ruby
if defined?(RailsAiContext)
  RailsAiContext.configure do |config|
    # :mcp (default) — MCP primary, CLI as fallback
    # :cli — CLI only, no MCP server needed
    config.tool_mode = :mcp
  end
end
```

- **`:mcp`** — context files show MCP tool syntax (e.g. `rails_get_schema(table: "users")`). CLI tools still available as fallback.
- **`:cli`** — context files show CLI syntax (e.g. `rails 'ai:tool[schema]' table=users`). No MCP server required.

The `tool_mode` is selected during `rails generate rails_ai_context:install`.

---

## MCP Tools — Full Reference

All 38 tools are **read-only** and **idempotent** — they never modify your application or database.

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
| `limit` | integer | Max models to return when listing. Default: 50. |
| `offset` | integer | Skip models for pagination. Default: 0. |

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
| `app_only` | boolean | Filter out internal Rails routes (Active Storage, Action Mailbox, Conductor, etc.). Default: true. |

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
| `controller` | string | Specific controller name (e.g. `UsersController`, `cooks`, `bonus/crises`). Case-insensitive, flexible format. |
| `action` | string | Specific action (e.g. `index`). Requires controller. Returns source code with applicable filters. |
| `detail` | string | `summary` / `standard` (default) / `full`. Ignored when controller is specified. |
| `limit` | integer | Max controllers to return when listing. Default: 50. |
| `offset` | integer | Skip this many controllers for pagination. Default: 0. |

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

**Returns:** cache store, session store, timezone, queue adapter, mailer settings, custom middleware (framework defaults are filtered out), notable initializers, CurrentAttributes classes.

```
rails_get_config()
  → Cache: redis_cache_store, Session: cookie_store, TZ: UTC, ...
```

### rails_get_test_info

Returns test infrastructure details. Optionally filter by model or controller to find existing tests.

**Parameters:**

| Param | Type | Description |
|-------|------|-------------|
| `model` | string | Show tests for a specific model (e.g. `User`). Also searches concern test paths (`spec/models/concerns/`, `test/models/concerns/`). |
| `controller` | string | Show tests for a specific controller (e.g. `Cooks`). |
| `detail` | string | `summary` / `standard` (default) / `full`. |

```
rails_get_test_info()
  → Framework: rspec, Factories: spec/factories (12 files), CI: .github/workflows/ci.yml

rails_get_test_info(model: "User")
  → Shows spec/models/user_spec.rb test names (summary/standard) or full source (full)
```

### rails_get_gems

Returns notable gems categorized by function.

**Parameters:**

| Param | Type | Description |
|-------|------|-------------|
| `category` | string | Filter by category: `auth`, `jobs`, `frontend`, `api`, `database`, `files`, `testing`, `deploy`, `all` (default). |

**Returns:** Notable gems grouped by category with descriptions.

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

### rails_get_stimulus

Returns Stimulus controller details: targets, values, actions, outlets, classes.

**Parameters:**

| Param | Type | Description |
|-------|------|-------------|
| `controller` | string | Specific Stimulus controller name (e.g. `hello`, `filter-form`). Case-insensitive. |
| `detail` | string | `summary` / `standard` (default) / `full` |
| `limit` | integer | Max controllers to return when listing. Default: 50. |
| `offset` | integer | Skip controllers for pagination. Default: 0. |

**Examples:**

```
rails_get_stimulus()
  → Standard: controller names with targets and actions

rails_get_stimulus(detail: "summary")
  → Names with target/action counts

rails_get_stimulus(controller: "filter-form")
  → Full detail: targets, actions, values, outlets, classes, file path

rails_get_stimulus(detail: "full")
  → All controllers with all details
```

### rails_get_view

Returns view template contents, partials, and Stimulus controller references.

**Parameters:**

| Param | Type | Description |
|-------|------|-------------|
| `controller` | string | Filter views by controller name (e.g. `cooks`, `brand_profiles`). Use `layouts` for layout files. |
| `path` | string | Specific view path relative to `app/views` (e.g. `cooks/index.html.erb`). Returns full content. |
| `detail` | string | `summary` / `standard` (default) / `full` |

**Examples:**

```
rails_get_view()
  → Standard: all view files with partial/stimulus refs

rails_get_view(controller: "cooks")
  → All templates and partials for CooksController

rails_get_view(path: "cooks/index.html.erb")
  → Full template content

rails_get_view(controller: "layouts")
  → Layout files

rails_get_view(controller: "cooks", detail: "full")
  → Full template content for all cooks views
```

### rails_get_edit_context

Returns just enough context to make a surgical Edit to a file. Returns the target area with line numbers and surrounding code.

**Parameters:**

| Param | Type | Description |
|-------|------|-------------|
| `file` | string | **Required.** File path relative to Rails root (e.g. `app/models/cook.rb`). |
| `near` | string | **Required.** What to find — a method name, keyword, or string to locate (e.g. `scope`, `def index`). |
| `context_lines` | integer | Lines of context above and below the match. Default: 5. |

**Examples:**

```
rails_get_edit_context(file: "app/models/cook.rb", near: "scope")
  → Code around the first scope with line numbers, expanded to full method

rails_get_edit_context(file: "app/controllers/cooks_controller.rb", near: "def index")
  → The index action source with surrounding context
```

### rails_validate

Validates syntax of multiple files at once (Ruby, ERB, JavaScript). Optionally runs Rails-aware semantic checks.

**Parameters:**

| Param | Type | Description |
|-------|------|-------------|
| `files` | array | **Required.** File paths relative to Rails root (e.g. `["app/models/cook.rb", "app/views/cooks/index.html.erb"]`). |
| `level` | string | `syntax` (default) — check syntax only (fast). `rails` — syntax + semantic checks (partial existence, route helpers, column references, strong params vs schema, callback methods, route-action consistency, has_many dependent, FK indexes, Stimulus controllers). |

**Examples:**

```
rails_validate(files: ["app/models/cook.rb"])
  → ✓ app/models/cook.rb — syntax OK

rails_validate(files: ["app/models/cook.rb", "app/controllers/cooks_controller.rb", "app/views/cooks/index.html.erb"])
  → Checks all three files, reports pass/fail for each

rails_validate(files: ["app/models/cook.rb"], level: "rails")
  → Syntax check + semantic warnings (e.g. validates :nonexistent_column, has_many without :dependent)

rails_validate(files: ["app/views/cooks/index.html.erb"], level: "rails")
  → Syntax check + partial existence, route helper validity, Stimulus controller existence
```

### rails_search_code

Ripgrep-powered regex search across the codebase.

**Parameters:**

| Param | Type | Description |
|-------|------|-------------|
| `pattern` | string | **Required.** Regex pattern or method name to search for. |
| `path` | string | Subdirectory to search in (e.g. `app/models`, `config`). Default: entire app. |
| `file_type` | string | Filter by file extension (e.g. `rb`, `erb`, `js`). Alphanumeric only. |
| `match_type` | string | `any` (default), `definition` (def lines), `class` (class/module lines), `call` (call sites only), `trace` (**full picture** — definition with class context + source code + internal calls + sibling methods + callers with route chain + test coverage separated). |
| `exact_match` | boolean | Match whole words only (wraps pattern in `\b` boundaries). Default: false. |
| `exclude_tests` | boolean | Exclude test/spec/features directories. Default: false. |
| `group_by_file` | boolean | Group results by file with match counts. Default: false. |
| `offset` | integer | Skip this many results for pagination. Default: 0. |
| `context_lines` | integer | Lines of context before and after each match (like grep -C). Default: 2, max: 5. |

Smart result limiting: <10 results shows all, 10-100 shows half, >100 caps at 100. Use `offset` for pagination.

**Examples:**

```
rails_search_code(pattern: "can_cook?", match_type: "trace")
  → FULL PICTURE: definition with class context + source code + internal calls
    + sibling methods + app callers with route chain + test coverage (separated)

rails_search_code(pattern: "create", match_type: "definition")
  → Only `def create` / `def self.create` lines

rails_search_code(pattern: "can_cook", match_type: "call")
  → Only call sites (excludes the definition)

rails_search_code(pattern: "Controller", match_type: "class")
  → All class/module definitions matching *Controller

rails_search_code(pattern: "has_many", group_by_file: true)
  → Results grouped by file with match counts

rails_search_code(pattern: "cook", exclude_tests: true)
  → Skip test/spec directories

rails_search_code(pattern: "activate", match_type: "definition")
  → Only `def activate` / `def self.activate` lines (skips method calls)

rails_search_code(pattern: "User", match_type: "class")
  → Only `class User` / `module User` definitions
```

**Security:** Uses `Open3.capture2` with array arguments (no shell injection). Validates file_type. Blocks path traversal. Respects `excluded_paths` and `sensitive_patterns` config.

### rails_analyze_feature

Full-stack feature analysis: models, controllers, routes, services, jobs, views, Stimulus controllers, tests, related models, concerns, callbacks, channels, mailers, and environment dependencies in one call.

**Parameters:**

| Param | Type | Description |
|-------|------|-------------|
| `feature` | string | **Required.** Feature keyword to search for (e.g. `authentication`, `User`, `payments`, `orders`). Case-insensitive partial match across models, controllers, and routes. |

**Examples:**

```
rails_analyze_feature(feature: "authentication")
  → Models, controllers, and routes matching "authentication"

rails_analyze_feature(feature: "User")
  → User model with schema columns, associations, validations, scopes;
    UsersController with actions and filters;
    all user routes with verbs and paths

rails_analyze_feature(feature: "payments")
  → Cross-cutting view: Payment model + PaymentsController + payment routes

rails_analyze_feature(feature: "orders")
  → Everything related to orders across all layers
```

**Returns:** Markdown with sections for Models (with columns, associations, validations, scopes, enums), Controllers (with actions and filters), Routes, Services (with methods), Jobs (with queue/retry), Views (with partials and Stimulus refs), Stimulus controllers (with targets/values/actions), Tests (with counts), Related models, Concerns, Callbacks, Channels, Mailers, and Environment dependencies. Each section shows match counts.

### rails_security_scan

Runs Brakeman static security analysis on the Rails app. Detects SQL injection, XSS, mass assignment, command injection, and other vulnerabilities. Requires the `brakeman` gem — returns installation instructions if not present.

**Parameters:**

| Param | Type | Description |
|-------|------|-------------|
| `files` | array | Filter results to specific files (e.g. `["app/controllers/users_controller.rb"]`). Omit to scan entire app. |
| `confidence` | string | Minimum confidence: `high`, `medium`, `weak` (default) |
| `checks` | array | Run only specific checks (e.g. `["CheckSQL", "CheckXSS"]`) |
| `detail` | string | `summary` (counts only), `standard` (file/line + message, default), `full` (+ code snippets + CWE + remediation links) |

**Examples:**

```
rails_security_scan()
  → All warnings across the entire app, sorted by confidence

rails_security_scan(files: ["app/controllers/users_controller.rb"], confidence: "high")
  → Only high-confidence warnings in the specified controller

rails_security_scan(detail: "full", checks: ["CheckSQL"])
  → Full detail with code snippets, CWE IDs, and remediation links for SQL injection only
```

**Returns:** Security warnings grouped by type with file locations, confidence levels, and messages. Full detail includes offending code snippets, CWE identifiers, and links to Brakeman documentation for each warning type.

### rails_get_concern

Get ActiveSupport::Concern details: public methods, included modules, and which models/controllers include it. Specify a name for full detail, or omit to list all concerns. Filter by type to narrow to model or controller concerns.

**Parameters:**

| Param | Type | Description |
|-------|------|-------------|
| `name` | string | Concern module name (e.g. `Searchable`, `Authenticatable`). Omit to list all concerns. |
| `type` | string | Filter by concern type: `model`, `controller`, `all` (default). |

**Examples:**

```
rails_get_concern()
  → Lists all model and controller concerns with method counts

rails_get_concern(name: "Searchable")
  → Full detail: public methods, class methods, macros, callbacks, and which models include it

rails_get_concern(type: "model")
  → Lists only model concerns from app/models/concerns/
```

**Returns:** Concern listing or full detail including file path, line count, included/extended modules, macros and DSL usage, public methods, class methods, callbacks, and a list of models or controllers that include the concern. Cross-references to related model/controller tools.

### rails_get_callbacks

Get ActiveRecord model callbacks in execution order: before/after/around for validation, save, create, update, destroy. Specify a model for one model's callbacks, or omit to see all models with their callbacks.

**Parameters:**

| Param | Type | Description |
|-------|------|-------------|
| `model` | string | Model class name (e.g. `User`, `Post`). Omit to see all models with their callbacks. |
| `detail` | string | `summary` / `standard` (default) / `full`. summary: model names + callback counts. standard: callbacks in execution order. full: callbacks with method source code. |

**Examples:**

```
rails_get_callbacks(model: "User")
  → User's callbacks in execution order: before_validation, after_validation, before_save, etc.

rails_get_callbacks(detail: "summary")
  → All models with callback counts, sorted by most callbacks

rails_get_callbacks(model: "Order", detail: "full")
  → Order's callbacks with the actual method source code for each callback
```

**Returns:** Callbacks organized in Rails execution order. Includes concern-provided callbacks. Full detail shows the Ruby source code of each callback method with line numbers.

### rails_get_helper_methods

Get Rails helper modules: method signatures, framework helpers in use, and which views call each helper. Specify a helper for full detail, or omit to list all helpers with method counts.

**Parameters:**

| Param | Type | Description |
|-------|------|-------------|
| `helper` | string | Helper module name (e.g. `ApplicationHelper`, `UsersHelper`). Omit to list all helpers. |
| `detail` | string | `summary` / `standard` (default) / `full`. summary: names + method counts. standard: names + method signatures. full: method signatures + view cross-references + framework helpers. |

**Examples:**

```
rails_get_helper_methods()
  → All helpers with method signatures (standard detail)

rails_get_helper_methods(helper: "ApplicationHelper")
  → Full detail: method signatures, included modules

rails_get_helper_methods(detail: "full")
  → All helpers with method signatures + detected framework helpers (Devise, Pagy, Turbo, etc.)
```

**Returns:** Helper module listing or full detail including file path, method signatures, included modules, and (at full detail) which views reference each helper method. Detects usage of framework helpers from Devise, Pagy, Turbo, Pundit, CanCanCan, Kaminari, SimpleForm, and others.

### rails_get_service_pattern

Analyze service objects in app/services/: patterns, interfaces, dependencies, and side effects. Specify a service for full detail, or omit to detect the common pattern and list all services.

**Parameters:**

| Param | Type | Description |
|-------|------|-------------|
| `service` | string | Service class name or filename (e.g. `CreateOrder`, `create_order`). Omit to list all services with pattern detection. |
| `detail` | string | `summary` / `standard` (default) / `full`. summary: names only. standard: names + method signatures + line counts. full: everything including side effects, error handling, and callers. |

**Examples:**

```
rails_get_service_pattern()
  → All services with detected common pattern (e.g. "initialize + call instance method")

rails_get_service_pattern(service: "CreateOrder")
  → Full detail: initialize params, public methods, dependencies, error handling, side effects, callers

rails_get_service_pattern(detail: "full")
  → All services with methods, initialize params, side effects, and rescue blocks
```

**Returns:** Service listing with common pattern detection (initialize+call, self.call, Result objects) or full detail including file path, initialize parameters, public methods, dependencies (other classes called), error handling (rescue blocks), side effects (database writes, email delivery, job enqueues, HTTP requests, Turbo broadcasts), and a list of files that call the service.

### rails_get_job_pattern

Analyze background jobs in app/jobs/: queues, retries, perform signatures, guards, and what they call. Specify a job for full detail, or omit to list all jobs with queue names and retry config.

**Parameters:**

| Param | Type | Description |
|-------|------|-------------|
| `job` | string | Job class name or filename (e.g. `SendWelcomeEmailJob`, `send_welcome_email`). Omit to list all jobs. |
| `detail` | string | `summary` / `standard` (default) / `full`. summary: names + queues. standard: names + queues + retries + what they call. full: everything including guards, broadcasts, schedules, and enqueuers. |

**Examples:**

```
rails_get_job_pattern()
  → All jobs with queue summary and retry config

rails_get_job_pattern(job: "SendWelcomeEmailJob")
  → Full detail: queue, retry config, perform signature, guard clauses, dependencies, broadcasts, schedule, side effects, enqueuers

rails_get_job_pattern(detail: "full")
  → All jobs with guards, broadcasts, side effects, and schedules
```

**Returns:** Job listing with queue breakdown or full detail including queue name, retry/discard configuration (retry_on, discard_on, Sidekiq options), perform method signature, guard clauses (early returns), dependencies (classes called), Turbo broadcasts, cron/recurring schedule (from sidekiq.yml or config files), side effects, and a list of files that enqueue the job.

### rails_get_env

Discover environment variables, external service dependencies, and credentials keys used by the app. Scans Ruby files for ENV[], .env.example, Dockerfile, external HTTP calls, and credentials keys (never values).

**Parameters:**

| Param | Type | Description |
|-------|------|-------------|
| `detail` | string | `summary` / `standard` (default) / `full`. summary: env var names only. standard: env vars grouped by source + external services. full: everything including per-file locations, Dockerfile vars, and credentials keys. |

**Examples:**

```
rails_get_env()
  → Env vars grouped by purpose (Database, Redis, AWS, etc.) + external services + credentials keys

rails_get_env(detail: "summary")
  → Env var names grouped by category

rails_get_env(detail: "full")
  → Per-file env var locations with line numbers, .env.example contents, Dockerfile ENV/ARG, external services with detection method, credentials keys, encrypted columns
```

**Returns:** Environment variables grouped by purpose (Database, Redis, AWS, Payments, Email, Monitoring, API Keys, etc.) with default values where detected. External service dependencies discovered from Gemfile gems and HTTP client calls. Credentials keys (never values). Encrypted model columns. Full detail includes per-file locations with line numbers.

### rails_get_partial_interface

Analyze a partial's interface: local variables it expects, where it's rendered from, and what methods are called on each local. Use when rendering a partial, understanding what locals to pass, or refactoring partial dependencies.

**Parameters:**

| Param | Type | Description |
|-------|------|-------------|
| `partial` | string | **Required.** Partial path relative to app/views (e.g. `shared/status_badge`, `users/form`). The leading underscore is optional. |
| `detail` | string | `summary` / `standard` (default) / `full`. summary: locals list + usage count. standard: locals + usage examples from codebase. full: locals + usage + full partial source. |

**Examples:**

```
rails_get_partial_interface(partial: "shared/status_badge")
  → Local variables, method calls on each local, and all render sites with locals passed

rails_get_partial_interface(partial: "users/form", detail: "summary")
  → Local variable names + number of render sites

rails_get_partial_interface(partial: "shared/card", detail: "full")
  → Full detail: locals, method calls, render sites with code snippets, and full partial source
```

**Returns:** Partial interface including declared locals (Rails 7.1+ magic comment), detected local variable references, method calls on each local, and render sites with file/line and locals passed. Supports underscore-prefixed and non-prefixed names. Full detail includes the complete partial source code.

### rails_get_turbo_map

Map Turbo Streams and Frames across the app: model broadcasts, channel subscriptions, frame tags, and DOM target mismatches. Filter by stream or controller name.

**Parameters:**

| Param | Type | Description |
|-------|------|-------------|
| `detail` | string | `summary` / `standard` (default) / `full`. summary: count of streams, frames, model broadcasts. standard: each stream with source to target. full: everything including inline template refs and DOM IDs. |
| `stream` | string | Filter by stream/channel name (e.g. `notifications`, `messages`). Shows only broadcasts and subscriptions for this stream. |
| `controller` | string | Filter by controller name (e.g. `messages`, `comments`). Shows Turbo usage in that controller's views and actions. |

**Examples:**

```
rails_get_turbo_map()
  → Model broadcasts, explicit broadcasts, stream subscriptions, Turbo Frames, and mismatch warnings

rails_get_turbo_map(stream: "notifications")
  → Only broadcasts and subscriptions for the "notifications" stream

rails_get_turbo_map(controller: "messages", detail: "full")
  → Full Turbo usage in messages controller with DOM IDs, stream wiring map, and mismatch warnings
```

**Returns:** Turbo Streams and Frames mapped across the app. Model broadcasts (via `broadcasts`, `broadcasts_to`, `broadcasts_refreshes`), explicit broadcasts (`broadcast_replace_to`, `broadcast_append_to`, etc.), stream subscriptions (`turbo_stream_from` in views), and Turbo Frames (`turbo_frame_tag` with IDs and src). Full detail includes a stream wiring map connecting broadcasters to subscribers, and warnings for broadcasts without subscribers or subscriptions without broadcasters.

### rails_get_context

Get cross-layer context in a single call — combines schema, model, controller, routes, views, stimulus, and tests. Use when you need full context for implementing a feature or modifying an action.

**Parameters:**

| Param | Type | Description |
|-------|------|-------------|
| `controller` | string | Controller name (e.g. `CooksController`). Returns action source, filters, strong params, routes, views. |
| `action` | string | Specific action name (e.g. `create`). Requires controller. Returns full action context. |
| `model` | string | Model name (e.g. `Cook`). Returns schema, associations, validations, scopes, callbacks, tests. |
| `feature` | string | Feature keyword (e.g. `cook`). Like analyze_feature but includes schema columns and scope bodies. |

**Examples:**

```
rails_get_context(controller: "CooksController", action: "create")
  → Controller action source + model details + routes + views — everything for that action

rails_get_context(model: "User")
  → Model details + schema columns + test file content

rails_get_context(feature: "orders")
  → Full-stack feature analysis including schema columns and scope bodies
```

**Returns:** Combined context from multiple tools in a single response. For controller+action: controller source with filters, inferred model details, matching routes, and view templates. For model: model details with associations/validations/scopes, schema columns with types, and test file content. For feature: delegates to full-stack feature analysis.

### Detail Level Summary

All tools that support `detail` use these three levels. Default limits vary by tool — schema defaults shown below:

| Level | What it returns | Schema default limit | Best for |
|-------|----------------|---------------------|----------|
| `summary` | Names + counts | 50 | Getting the landscape, understanding what exists |
| `standard` | Names + key details | 29 | Working context, column types, action names |
| `full` | Everything | 10 | Deep inspection, indexes, FKs, constraints |

Other tools default to higher limits (e.g. models/controllers/stimulus: 50 for all levels, routes: 100/200).

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

The install generator (or `rails-ai-context init`) creates `.mcp.json` in your project root:

**In-Gemfile:**
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

**Standalone:**
```json
{
  "mcpServers": {
    "rails-ai-context": {
      "command": "rails-ai-context",
      "args": ["serve"]
    }
  }
}
```

**Claude Code** and **Cursor** auto-detect this file. No manual config needed — just open your project.

### Claude Code

Auto-discovered via `.mcp.json`. Or add manually:

```bash
# In-Gemfile
claude mcp add rails-ai-context -- bundle exec rails ai:serve

# Standalone
claude mcp add rails-ai-context -- rails-ai-context serve
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

Or for standalone: replace `"command": "bundle"` / `"args": ["exec", "rails", "ai:serve"]` with `"command": "rails-ai-context"` / `"args": ["serve"]`.

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

For standalone: use `"command": "rails-ai-context"` / `"args": ["serve"]` instead.
```

### HTTP transport

For browser-based or remote AI clients:

```bash
rails ai:serve_http
# Starts at http://127.0.0.1:6029/mcp
```

Or auto-mount inside your Rails app (no separate process):

```ruby
if defined?(RailsAiContext)
  RailsAiContext.configure do |config|
    config.auto_mount = true
    config.http_path  = "/mcp"       # default
    config.http_port  = 6029          # default
    config.http_bind  = "127.0.0.1"  # default (localhost only)
  end
end
```

Both transports are **read-only** — they expose the same 38 tools and never modify your app.

---

## Configuration — All Options

```ruby
# config/initializers/rails_ai_context.rb
if defined?(RailsAiContext)
  RailsAiContext.configure do |config|
    # --- Introspectors ---

    # Presets: :full (31 introspectors, default) or :standard (17)
    config.preset = :full

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

    # Tool mode: :mcp (MCP primary + CLI fallback) or :cli (CLI only)
    config.tool_mode = :mcp

    # Max response size for tool results (safety net)
    config.max_tool_response_chars = 200_000

    # Cache TTL for introspection results (seconds)
    config.cache_ttl = 60

    # Additional MCP tool classes to register alongside built-in tools
    # config.custom_tools = [MyApp::Tools::CustomTool]

    # Exclude specific built-in tools (e.g. if you don't use Brakeman)
    # config.skip_tools = %w[rails_security_scan]

    # --- Exclusions ---

    # Models to skip during introspection
    config.excluded_models += %w[AdminUser InternalAuditLog]

    # Paths to exclude from code search
    config.excluded_paths += %w[vendor/bundle]

    # Sensitive file patterns blocked from search and read tools
    # config.sensitive_patterns += %w[config/my_secret.yml]

    # Controllers hidden from listings (e.g. Devise internals)
    # config.excluded_controllers += %w[MyInternalController]

    # Route prefixes hidden with app_only (e.g. admin frameworks)
    # config.excluded_route_prefixes += %w[admin/]

    # Regex patterns for concerns to hide from model output
    # config.excluded_concerns += [/MyInternal::/]

    # Framework filter names hidden from controller output
    # config.excluded_filters += %w[my_internal_filter]

    # Default middleware hidden from config output
    # config.excluded_middleware += %w[MyMiddleware]

    # --- File size limits ---

    # Per-file read limit for tools (default: 5MB)
    # config.max_file_size = 5_000_000

    # Test file read limit (default: 1MB)
    # config.max_test_file_size = 1_000_000

    # schema.rb / structure.sql parse limit (default: 10MB)
    # config.max_schema_file_size = 10_000_000

    # Total aggregated view content for UI patterns (default: 10MB)
    # config.max_view_total_size = 10_000_000

    # Per-view file during aggregation (default: 1MB)
    # config.max_view_file_size = 1_000_000

    # Max search results per call (default: 200)
    # config.max_search_results = 200

    # Max files per validate call (default: 50)
    # config.max_validate_files = 50

    # --- Search and file discovery ---

    # File extensions for Ruby fallback search
    # config.search_extensions = %w[rb js erb yml yaml json ts tsx vue svelte haml slim]

    # Where to look for concern source files
    # config.concern_paths = %w[app/models/concerns app/controllers/concerns]

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
end
```

### Options reference

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `preset` | Symbol | `:full` | Introspector preset (`:full` or `:standard`) |
| `introspectors` | Array | 31 (full preset) | Which introspectors to run |
| `context_mode` | Symbol | `:compact` | `:compact` or `:full` |
| `claude_max_lines` | Integer | `150` | Max lines for CLAUDE.md in compact mode |
| `max_tool_response_chars` | Integer | `200_000` | Safety cap for MCP tool responses |
| `cache_ttl` | Integer | `60` | Cache TTL in seconds for introspection results |
| `custom_tools` | Array | `[]` | Additional MCP tool classes to register alongside built-in tools |
| `skip_tools` | Array | `[]` | Built-in tool names to exclude (e.g. `%w[rails_security_scan]`) |
| `tool_mode` | Symbol | `:mcp` | `:mcp` (MCP primary + CLI fallback) or `:cli` (CLI only, no MCP server needed) |
| `ai_tools` | Array | `nil` (all) | AI tools to generate context for: `%i[claude cursor copilot opencode]`. Selected during install. |
| `excluded_models` | Array | internal Rails models | Models to skip |
| `excluded_paths` | Array | `node_modules tmp log vendor .git` | Paths excluded from code search |
| `sensitive_patterns` | Array | `.env`, `.key`, `.pem`, credentials | File patterns blocked from search and read tools |
| `output_dir` | String | `nil` (Rails.root) | Where to write context files |
| `auto_mount` | Boolean | `false` | Auto-mount HTTP MCP endpoint |
| `http_path` | String | `"/mcp"` | HTTP endpoint path |
| `http_bind` | String | `"127.0.0.1"` | HTTP bind address |
| `http_port` | Integer | `6029` | HTTP server port |
| `live_reload` | Symbol/Boolean | `:auto` | `:auto`, `true`, or `false` — enable MCP live reload |
| `live_reload_debounce` | Float | `1.5` | Debounce interval in seconds for live reload |
| `server_name` | String | `"rails-ai-context"` | MCP server name |
| `server_version` | String | gem version | MCP server version |
| `generate_root_files` | Boolean | `true` | Generate root files (CLAUDE.md, etc.) — set `false` for split rules only |
| `anti_hallucination_rules` | Boolean | `true` | Embed 6-rule Anti-Hallucination Protocol in generated context files — set `false` to skip |
| `max_file_size` | Integer | `5_000_000` | Per-file read limit for tools (5MB) |
| `max_test_file_size` | Integer | `1_000_000` | Test file read limit (1MB) |
| `max_schema_file_size` | Integer | `10_000_000` | schema.rb / structure.sql parse limit (10MB) |
| `max_view_total_size` | Integer | `10_000_000` | Total aggregated view content for UI patterns (10MB) |
| `max_view_file_size` | Integer | `1_000_000` | Per-view file during aggregation (1MB) |
| `max_search_results` | Integer | `200` | Max search results per call |
| `max_validate_files` | Integer | `50` | Max files per validate call |
| `excluded_controllers` | Array | `DeviseController`, etc. | Controller classes hidden from listings |
| `excluded_route_prefixes` | Array | `action_mailbox/`, `active_storage/`, etc. | Route controller prefixes hidden with `app_only` |
| `excluded_concerns` | Array | framework regex patterns | Regex patterns for concerns to hide from model output |
| `excluded_filters` | Array | `verify_authenticity_token`, etc. | Framework filter names hidden from controller output |
| `excluded_middleware` | Array | standard Rails middleware | Default middleware hidden from config output |
| `search_extensions` | Array | `rb js erb yml yaml json ts tsx vue svelte haml slim` | File extensions for Ruby fallback search |
| `concern_paths` | Array | `app/models/concerns app/controllers/concerns` | Where to look for concern source files |

### Root file generation

By default, `rails ai:context` generates root files (CLAUDE.md, AGENTS.md, etc.) alongside split rules.

**Section markers:** Generated content is wrapped in `<!-- BEGIN rails-ai-context -->` / `<!-- END rails-ai-context -->` markers. If you add custom notes above or below the markers, they will be preserved when you re-run `rails ai:context`.

**Skip root files:** If you prefer to maintain root files yourself and only want split rules (`.claude/rules/`, `.cursor/rules/`, `.github/instructions/`):

```ruby
if defined?(RailsAiContext)
  RailsAiContext.configure do |config|
    config.generate_root_files = false
  end
end
```

All split rules include an app overview file, so no context is lost when root files are disabled.

---

## Introspectors — Full List

### Standard preset (17 introspectors)

Core Rails structure only. Use `config.preset = :standard` for a lighter footprint.

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
| `config` | Cache store, session store, timezone, queue adapter, mailer settings, middleware stack, initializers, credentials status, CurrentAttributes classes. |
| `stimulus` | Stimulus controllers with targets, values (with types), actions, outlets, classes. Extracted from JS/TS files. |
| `view_templates` | View file contents, partial references, Stimulus data attributes, model field usage in partials. |
| `components` | ViewComponent/Phlex components: props, slots, previews, sidecar assets, usage examples. |
| `turbo` | Turbo Frames (IDs and files), Turbo Stream templates, model broadcasts (`broadcasts_to`, `broadcasts`). |
| `auth` | Devise models with modules, Rails 8 built-in auth, has_secure_password, Pundit policies, CanCanCan, CORS config, CSP config. |
| `performance` | N+1 query risks, missing counter_cache, missing FK indexes, Model.all anti-patterns, eager load candidates. |
| `i18n` | Default locale, available locales, locale files with key counts, backend class, parse errors. |

### Full preset (31 introspectors) — default

Includes all standard introspectors plus:

| Introspector | What it discovers |
|-------------|-------------------|
| `views` | Layouts, templates grouped by controller, partials (per-controller and shared), helpers with methods, template engines (erb, haml, slim), view components. |
| `active_storage` | Attachments (has_one_attached, has_many_attached per model), storage services, direct upload config. |
| `action_text` | Rich text fields (has_rich_text per model), Action Text installation status. |
| `api` | API-only mode, API versioning (from directory structure), serializers (Jbuilder, AMS, etc.), GraphQL (types, mutations), rate limiting (Rack::Attack). |
| `rake_tasks` | Custom rake tasks in `lib/tasks/` with names, descriptions, namespaces, file paths. |
| `assets` | Asset pipeline (Propshaft/Sprockets), JS bundler (importmap/esbuild/webpack/vite), CSS framework, importmap pins, manifest files. |
| `devops` | Puma config (threads, workers, port), Procfile entries, Docker (multi-stage detection), deployment tools, health check routes. |
| `action_mailbox` | Action Mailbox mailboxes with routing patterns. |
| `seeds` | db/seeds.rb analysis (Faker usage, environment conditionals), seed files in db/seeds/, models seeded. |
| `middleware` | Custom Rack middleware in app/middleware/ with detected patterns (auth, rate limiting, tenant isolation, logging). Full middleware stack. |
| `engines` | Mounted Rails engines from routes.rb with paths and descriptions for 23+ known engines (Sidekiq::Web, Flipper::UI, PgHero, ActiveAdmin, etc.). |
| `multi_database` | Multiple databases, replicas, sharding config, model-specific `connects_to` declarations. database.yml parsing fallback. |
| `frontend_frameworks` | Frontend JS framework detection (React/Vue/Svelte/Angular), mounting strategy (Inertia/react-rails), TypeScript config, state management, package manager. |
| `database_stats` | PostgreSQL approximate row counts via `pg_stat_user_tables`. Gracefully skips on non-PostgreSQL adapters. |

### Using the standard preset

```ruby
config.preset = :standard
```

### Cherry-picking introspectors

```ruby
# Start with standard, add specific ones
config.preset = :standard
config.introspectors += %i[views turbo auth api]

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

For standalone: use `"command": ["rails-ai-context", "serve"]` instead.

```json
{
  "mcp": {
    "rails-ai-context": {
      "type": "local",
      "command": ["rails-ai-context", "serve"]
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
| Rails full-stack (ERB + Hotwire) | 31/31 | All introspectors relevant |
| Rails + Inertia.js (React/Vue) | ~25/31 | Views/Turbo partially useful, backend fully covered |
| Rails API + React/Next.js SPA | ~23/31 | Schema, models, routes, API, auth, jobs — all covered |
| Rails API + mobile app | ~23/31 | Same as SPA — backend introspection is identical |
| Rails engine (mountable gem) | ~18/31 | Core introspectors (schema, models, routes, gems) work |

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
if defined?(RailsAiContext)
  RailsAiContext.configure do |config|
    # :auto (default) — enable if `listen` gem is available, skip silently otherwise
    # true  — enable, raise if `listen` gem is missing
    # false — disable entirely
    config.live_reload = :auto

    # Debounce interval in seconds (default: 1.5)
    config.live_reload_debounce = 1.5
  end
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
