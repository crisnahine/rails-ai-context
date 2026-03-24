# rails-ai-context

**Give AI agents a complete mental model of your Rails app — not just files, but how everything connects.**

[![Gem Version](https://img.shields.io/gem/v/rails-ai-context?color=brightgreen)](https://rubygems.org/gems/rails-ai-context)
[![MCP Registry](https://img.shields.io/badge/MCP_Registry-listed-green)](https://registry.modelcontextprotocol.io)
[![CI](https://github.com/crisnahine/rails-ai-context/actions/workflows/ci.yml/badge.svg)](https://github.com/crisnahine/rails-ai-context/actions)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

> Built by a Rails developer with 10 years of production experience. Yes, AI helped write this gem — the same way AI helps me ship features at work. I designed the architecture, made every decision, reviewed every line, and wrote 520 tests. The gem exists because I understand Rails deeply enough to know what AI agents get wrong and what context they need to get it right.

---

## The Problem

AI agents working on Rails apps operate blind. They read files one at a time but never see the full picture — how your schema connects to your models, which callbacks fire on save, what filters apply to a controller action, which Stimulus controllers exist, or what your UI conventions are.

The result: **guess-and-check coding.** The agent writes code, it breaks, it reads more files, fixes it, breaks again. Each iteration wastes tokens and erodes trust.

## The Solution

**rails-ai-context** gives your AI agent what a senior Rails developer has naturally: a structured mental model of the entire application.

```bash
bundle add rails-ai-context
rails generate rails_ai_context:install
rails ai:context
```

Three commands. Your AI now understands your schema, models, routes, controllers, views, jobs, gems, auth, Stimulus controllers, design patterns, and conventions — through the [Model Context Protocol (MCP)](https://modelcontextprotocol.io).

The install generator creates `.mcp.json` for auto-discovery — Claude Code and Cursor detect it automatically.

> **[Full Guide](docs/GUIDE.md)** — complete documentation with every command, parameter, and configuration option.

---

## What Changes

### Without rails-ai-context

The agent asks itself: *What columns does `users` have?* It reads all 2,000 lines of `schema.rb`. *What associations does `Cook` have?* It reads the model file but misses the concern that adds 12 methods. *What filters apply to `CooksController#create`?* It reads the controller but doesn't see the inherited `authenticate_user!` from the parent class. It writes code that references a nonexistent partial, permits a wrong param, and renders a Stimulus controller that doesn't exist.

**Every mistake is a wasted iteration.**

### With rails-ai-context

```
Agent: rails_get_schema(table:"users")          → 25 lines: columns, types, NOT NULL, defaults, indexes, FKs
Agent: rails_get_model_details(model:"Cook")     → associations, validations, scopes, callbacks, concern methods
Agent: rails_get_controllers(controller:"cooks", action:"create") → source code + applicable filters + strong params body
Agent: rails_validate(files:["app/models/cook.rb"], level:"rails") → catches column/route/partial errors before execution
```

**Orient → drill down → act → verify.** The first attempt is correct.

---

## Three Layers of Context

| Layer | What it provides | When it loads | Token cost |
|-------|-----------------|---------------|------------|
| **Static files** (CLAUDE.md, .cursorrules, etc.) | App overview: stack, models, gems, architecture, UI patterns, MCP tool reference | Automatically at session start | ~150 lines, zero tool calls |
| **Split rules** (.claude/rules/, .cursor/rules/) | Deep reference: full schema with column types, all model associations/scopes, controller listings | Conditionally — only when editing relevant files | Zero when not needed |
| **Live MCP tools** (16 tools) | Real-time queries: drill into any table, model, controller action, or view on demand. Semantic validation. Design system. Security scanning. | On-demand via agent tool calls | ~25-100 lines per call |

**Progressive disclosure:** the agent gets the map for free, reference guides when relevant, and live GPS when building.

---

## Real Impact: 37% Fewer Tokens, 95% Fewer Errors

| Setup | Tokens | What it knows |
|-------|--------|---------------|
| **rails-ai-context (full)** | **28,834** | 16 MCP tools + generated docs + split rules |
| rails-ai-context CLAUDE.md only | 33,106 | Generated docs + rules, no MCP tools |
| Normal Claude `/init` | 40,700 | Generic CLAUDE.md only |
| No rails-ai-context | 45,477 | Nothing — discovers everything from scratch |

```
No rails-ai-context          45,477 tk  █████████████████████████████████████████████
Normal Claude /init           40,700 tk  █████████████████████████████████████████     -11%
rails-ai-context CLAUDE.md    33,106 tk  █████████████████████████████████             -27%
rails-ai-context (full)       28,834 tk  █████████████████████████████                 -37%
```

https://github.com/user-attachments/assets/14476243-1210-4e62-9dc5-9d4aa9caef7e

> **Token savings scale with app size.** A 5-model app saves 37%. A 50-model app with auth + payments + mailers saves 60-80% — because MCP tools return only what's needed instead of reading entire files.

But token savings is the side effect. The real value:

- **Fewer iterations** — the agent understands associations, callbacks, and constraints before writing code
- **Cross-file accuracy** — semantic validation catches nonexistent partials, wrong column references, and missing routes in one call
- **Convention awareness** — the agent matches your UI patterns, test framework, and architecture style
- **No stale context** — live reload invalidates caches when files change mid-session

---

## 16 Live MCP Tools

The gem exposes **16 read-only tools** via MCP that AI clients call on-demand:

| Tool | What it returns |
|------|----------------|
| `rails_get_schema` | Tables, columns, indexes, foreign keys |
| `rails_get_model_details` | Associations, validations, scopes, enums, callbacks |
| `rails_get_routes` | HTTP verbs, paths, controller actions |
| `rails_get_controllers` | Actions, filters, strong params, concerns |
| `rails_get_config` | Cache, session, timezone, middleware, initializers |
| `rails_get_test_info` | Test framework, factories, CI config, coverage |
| `rails_get_gems` | Notable gems categorized by function |
| `rails_get_conventions` | Architecture patterns, directory structure |
| `rails_search_code` | Ripgrep-powered regex search across the codebase |
| `rails_get_view` | View templates, partials, Stimulus references |
| `rails_get_stimulus` | Stimulus controllers — targets, values, actions, outlets |
| `rails_get_edit_context` | Surgical edit helper — returns code around a match with line numbers |
| `rails_validate` | Batch syntax validation for Ruby, ERB, and JavaScript files. `level:"rails"` adds semantic checks (partials, route helpers, columns, strong params, callbacks, FK indexes, Stimulus) |
| `rails_analyze_feature` | Full-stack feature analysis — models, controllers, routes, services, jobs, views, Stimulus, tests, related models, env deps |
| `rails_get_design_system` | App design system — color palette, component patterns with real HTML examples, typography, layout, responsive breakpoints |
| `rails_security_scan` | Brakeman static security analysis — SQL injection, XSS, mass assignment. Filter by file, confidence level, specific checks |

### Smart Detail Levels

Schema, routes, models, and controllers tools support a `detail` parameter — critical for large apps:

| Level | Returns | Default limit |
|-------|---------|---------------|
| `summary` | Names + counts | 50 |
| `standard` | Names + key details *(default)* | 15 |
| `full` | Everything (indexes, FKs, constraints) | 5 |

```ruby
rails_get_schema(detail: "summary")           # → all tables with column counts
rails_get_schema(table: "users")              # → full detail for one table
rails_get_routes(controller: "users")         # → routes for one controller
rails_get_model_details(model: "User")        # → associations, validations, scopes
```

A safety net (`max_tool_response_chars`, default 120K) truncates oversized responses with hints to use filters.

---

## What Gets Generated

`rails ai:context` generates context files tailored to each AI assistant:

```
your-rails-app/
│
├── 🟣 Claude Code
│   ├── CLAUDE.md                                         ≤150 lines (compact)
│   └── .claude/rules/
│       ├── rails-context.md                              app overview
│       ├── rails-schema.md                               table listing + column types
│       ├── rails-models.md                               model listing
│       ├── rails-ui-patterns.md                          CSS/Tailwind component patterns
│       └── rails-mcp-tools.md                            full tool reference
│
├── 🟢 Cursor
│   └── .cursor/rules/
│       ├── rails-project.mdc                             alwaysApply: true
│       ├── rails-models.mdc                              globs: app/models/**
│       ├── rails-controllers.mdc                         globs: app/controllers/**
│       ├── rails-ui-patterns.mdc                         globs: app/views/**
│       └── rails-mcp-tools.mdc                           alwaysApply: true
│
├── ⚡ OpenCode
│   ├── AGENTS.md                                        native OpenCode context
│   ├── app/models/AGENTS.md                             auto-loaded when editing models
│   └── app/controllers/AGENTS.md                        auto-loaded when editing controllers
│
├── 🔵 Windsurf
│   ├── .windsurfrules                                    ≤5,800 chars (6K limit)
│   └── .windsurf/rules/
│       ├── rails-context.md                              project overview
│       ├── rails-ui-patterns.md                          CSS component patterns
│       └── rails-mcp-tools.md                            tool reference
│
├── 🟠 GitHub Copilot
│   ├── .github/copilot-instructions.md                   ≤500 lines (compact)
│   └── .github/instructions/
│       ├── rails-context.instructions.md                 applyTo: **/*
│       ├── rails-models.instructions.md                  applyTo: app/models/**
│       ├── rails-controllers.instructions.md             applyTo: app/controllers/**
│       ├── rails-ui-patterns.instructions.md             applyTo: app/views/**
│       └── rails-mcp-tools.instructions.md               applyTo: **/*
│
├── 📋 .ai-context.json                                   full JSON (programmatic)
└── .mcp.json                                             MCP auto-discovery
```

Root files (CLAUDE.md, AGENTS.md, etc.) use **section markers** — your custom content outside the markers is preserved on re-generation. Set `config.generate_root_files = false` to only generate split rules.

---

## What Your AI Learns

| Category | What's introspected |
|----------|-------------------|
| **Database** | Every table, column, index, foreign key, and migration |
| **Models** | Associations, validations, scopes, enums, callbacks, concerns, macros |
| **Routing** | Every route with HTTP verbs, paths, controller actions, API namespaces |
| **Controllers** | Actions, filters, strong params, concerns, API controllers |
| **Views** | Layouts, templates, partials, helpers, template engines, view components |
| **Frontend** | Stimulus controllers (targets, values, actions, outlets), Turbo Frames/Streams |
| **Background** | ActiveJob classes, mailers, Action Cable channels |
| **Gems** | 70+ notable gems categorized (Devise = auth, Sidekiq = jobs, Pundit = authorization) |
| **Auth** | Devise modules, Pundit policies, CanCanCan, has_secure_password, CORS, CSP |
| **API** | Serializers, GraphQL, versioning, rate limiting, API-only mode |
| **Testing** | Framework, factories/fixtures, CI config, coverage, system tests |
| **Config** | Cache store, session store, middleware, initializers, timezone |
| **DevOps** | Puma, Procfile, Docker, deployment tools, asset pipeline |
| **Architecture** | Service objects, STI, polymorphism, state machines, multi-tenancy, engines |

29 introspectors total. The `:full` preset runs 28 by default; use `:standard` for 13 core only (`database_stats` is opt-in, PostgreSQL only).

---

## MCP Server Setup

The install generator creates `.mcp.json` — **Claude Code and Cursor auto-detect it**. No manual config needed.

This server is also listed on the [official MCP Registry](https://registry.modelcontextprotocol.io) as `io.github.crisnahine/rails-ai-context`.

To start manually: `rails ai:serve`

<details>
<summary><strong>Claude Desktop setup</strong></summary>

Add to `~/Library/Application Support/Claude/claude_desktop_config.json` (macOS):

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
</details>

<details>
<summary><strong>HTTP transport (for remote clients)</strong></summary>

```bash
rails ai:serve_http  # Starts at http://127.0.0.1:6029/mcp
```

Or auto-mount inside your Rails app:

```ruby
RailsAiContext.configure do |config|
  config.auto_mount = true
  config.http_path  = "/mcp"
end
```
</details>

---

## Configuration

```ruby
# config/initializers/rails_ai_context.rb
RailsAiContext.configure do |config|
  # Presets: :full (28 introspectors, default) or :standard (13 core)
  config.preset = :full

  # Cherry-pick on top of a preset
  # config.introspectors += %i[views turbo auth api]

  # Context mode: :compact (≤150 lines, default) or :full (dump everything)
  # config.context_mode = :compact

  # Exclude models from introspection
  config.excluded_models += %w[AdminUser InternalAuditLog]

  # Exclude paths from code search
  config.excluded_paths += %w[vendor/bundle]

  # Cache TTL for MCP tool responses (seconds)
  config.cache_ttl = 30

  # Live reload: auto-invalidate MCP caches on file changes
  # :auto (default), true, or false
  # config.live_reload = :auto

  # Skip root files (CLAUDE.md, .windsurfrules, etc.) — only generate split rules
  # Lets you manage root files yourself while still getting .claude/rules/, .cursor/rules/, etc.
  # config.generate_root_files = false
end
```

<details>
<summary><strong>All configuration options</strong></summary>

| Option | Default | Description |
|--------|---------|-------------|
| **Presets & Introspectors** | | |
| `preset` | `:full` | Introspector preset (`:full` or `:standard`) |
| `introspectors` | 28 (full) | Array of introspector symbols |
| **Context Generation** | | |
| `context_mode` | `:compact` | `:compact` (≤150 lines) or `:full` (dump everything) |
| `claude_max_lines` | `150` | Max lines for CLAUDE.md in compact mode |
| `generate_root_files` | `true` | Generate root files (CLAUDE.md, etc.) — set `false` for split rules only |
| `output_dir` | `Rails.root` | Output directory for generated context files |
| **MCP Server** | | |
| `server_name` | `"rails-ai-context"` | MCP server name |
| `server_version` | gem version | MCP server version |
| `auto_mount` | `false` | Auto-mount HTTP MCP endpoint |
| `http_path` | `"/mcp"` | HTTP endpoint path |
| `http_port` | `6029` | HTTP server port |
| `http_bind` | `"127.0.0.1"` | HTTP server bind address |
| `cache_ttl` | `30` | Cache TTL in seconds |
| `max_tool_response_chars` | `120_000` | Safety cap for MCP tool responses |
| `live_reload` | `:auto` | `:auto`, `true`, or `false` — MCP live reload |
| `live_reload_debounce` | `1.5` | Debounce interval in seconds |
| **Filtering & Exclusions** | | |
| `excluded_models` | internal Rails models | Models to skip during introspection |
| `excluded_paths` | `node_modules tmp log vendor .git` | Paths excluded from code search |
| `sensitive_patterns` | `.env .env.* config/master.key config/credentials.yml.enc config/credentials/*.yml.enc *.pem *.key` | File patterns blocked from search and read tools |
| `excluded_controllers` | `DeviseController` etc. | Controller classes hidden from listings |
| `excluded_route_prefixes` | `action_mailbox/ active_storage/ rails/` etc. | Route controller prefixes hidden with app_only |
| `excluded_concerns` | Rails/Devise/framework patterns | Regex patterns for concerns to hide |
| `excluded_filters` | `verify_authenticity_token` etc. | Framework filter names hidden from controller output |
| `excluded_middleware` | standard Rack/Rails middleware | Default middleware hidden from config output |
| **File Size Limits** | | |
| `max_file_size` | `2_000_000` | Per-file read limit for tools (bytes) |
| `max_test_file_size` | `500_000` | Test file read limit (bytes) |
| `max_schema_file_size` | `10_000_000` | schema.rb / structure.sql parse limit (bytes) |
| `max_view_total_size` | `5_000_000` | Total aggregated view content for UI patterns (bytes) |
| `max_view_file_size` | `500_000` | Per-view file during aggregation (bytes) |
| `max_search_results` | `100` | Max search results per call |
| `max_validate_files` | `20` | Max files per validate call |
| **Search & Discovery** | | |
| `search_extensions` | `rb js erb yml yaml json ts tsx vue svelte haml slim` | File extensions for Ruby fallback search |
| `concern_paths` | `app/models/concerns app/controllers/concerns` | Where to look for concern source files |
| **Extensibility** | | |
| `custom_tools` | `[]` | Additional MCP tool classes to register alongside built-in tools |
</details>

---

## Commands

### Rake tasks (recommended)

| Command | Description |
|---------|-------------|
| `rails ai:context` | Generate all context files (skips unchanged) |
| `rails ai:context:full` | Generate all files in full mode (dumps everything) |
| `rails ai:context:claude` | Generate Claude Code files only |
| `rails ai:context:opencode` | Generate OpenCode files only |
| `rails ai:context:cursor` | Generate Cursor files only |
| `rails ai:context:windsurf` | Generate Windsurf files only |
| `rails ai:context:copilot` | Generate Copilot files only |
| `rails ai:context:json` | Generate JSON context file only |
| `rails ai:serve` | Start MCP server (stdio) |
| `rails ai:serve_http` | Start MCP server (HTTP) |
| `rails ai:doctor` | Run diagnostics and AI readiness score (0-100) |
| `rails ai:watch` | Auto-regenerate context files on code changes |
| `rails ai:inspect` | Print introspection summary to stdout |

### Standalone CLI

The gem also ships a `rails-ai-context` executable — an alternative to rake tasks.

| Command | Equivalent rake task |
|---------|---------------------|
| `rails-ai-context serve` | `rails ai:serve` |
| `rails-ai-context serve --transport http` | `rails ai:serve_http` |
| `rails-ai-context context` | `rails ai:context` |
| `rails-ai-context context --format claude` | `rails ai:context:claude` |
| `rails-ai-context doctor` | `rails ai:doctor` |
| `rails-ai-context watch` | `rails ai:watch` |
| `rails-ai-context inspect` | `rails ai:inspect` |
| `rails-ai-context version` | — |

Run from your Rails app root. Use `rails-ai-context help` for all options.

---

## Stack Compatibility

Works with every Rails architecture — auto-detects what's relevant:

| Setup | Coverage | Notes |
|-------|----------|-------|
| Rails full-stack (ERB + Hotwire) | 29/29 | All introspectors relevant |
| Rails + Inertia.js (React/Vue) | ~22/29 | Views/Turbo partially useful, backend fully covered |
| Rails API + React/Next.js SPA | ~20/29 | Schema, models, routes, API, auth, jobs — all covered |
| Rails API + mobile app | ~20/29 | Same as SPA — backend introspection is identical |
| Rails engine (mountable gem) | ~15/29 | Core introspectors (schema, models, routes, gems) work |

Frontend introspectors (views, Turbo, Stimulus, assets) degrade gracefully — they report nothing when those features aren't present.

---

## Works Without a Database

The gem parses `db/schema.rb` as text when no database is connected. Works in CI, Docker build stages, and Claude Code sessions without a running DB.

---

## Requirements

- Ruby >= 3.2, Rails >= 7.1
- [mcp](https://github.com/modelcontextprotocol/ruby-sdk) gem (installed automatically)
- Optional: `listen` gem for watch mode, `ripgrep` for fast code search

---

## vs. Other Ruby MCP Projects

| Project | Approach | rails-ai-context |
|---------|----------|-----------------|
| [Official Ruby SDK](https://github.com/modelcontextprotocol/ruby-sdk) | Low-level protocol library | We **use** this as our foundation |
| [fast-mcp](https://github.com/yjacquin/fast-mcp) | Generic MCP framework | We're a **product** — zero-config Rails introspection |
| [rails-mcp-server](https://github.com/maquina-app/rails-mcp-server) | Manual config (`projects.yml`) | We auto-discover everything |

---

## Contributing

```bash
git clone https://github.com/crisnahine/rails-ai-context.git
cd rails-ai-context && bundle install
bundle exec rspec       # 520 examples
bundle exec rubocop     # Lint
```

Bug reports and pull requests welcome at [github.com/crisnahine/rails-ai-context](https://github.com/crisnahine/rails-ai-context).

## Sponsorship

If rails-ai-context helps your workflow, consider [becoming a sponsor](https://github.com/sponsors/crisnahine).

## License

[MIT](LICENSE)
