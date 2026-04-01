# rails-ai-context

### Your AI is guessing. This gem makes it know.

[![Gem Version](https://img.shields.io/gem/v/rails-ai-context?color=brightgreen)](https://rubygems.org/gems/rails-ai-context)
[![Downloads](https://img.shields.io/gem/dt/rails-ai-context?color=blue)](https://rubygems.org/gems/rails-ai-context)
[![CI](https://github.com/crisnahine/rails-ai-context/actions/workflows/ci.yml/badge.svg)](https://github.com/crisnahine/rails-ai-context/actions)
[![MCP Registry](https://img.shields.io/badge/MCP_Registry-listed-green)](https://registry.modelcontextprotocol.io)
[![Ruby](https://img.shields.io/badge/Ruby-3.2%20%7C%203.3%20%7C%203.4-red)](https://github.com/crisnahine/rails-ai-context)
[![Rails](https://img.shields.io/badge/Rails-7.1%20%7C%207.2%20%7C%208.0-red)](https://github.com/crisnahine/rails-ai-context)
[![Tests](https://img.shields.io/badge/Tests-1052%20passing-brightgreen)](https://github.com/crisnahine/rails-ai-context/actions)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

**Works with:** Claude Code &bull; Cursor &bull; GitHub Copilot &bull; OpenCode &bull; Any terminal

> Built by a Rails developer with 10+ years of production experience. AI assisted — the same way it assists me shipping features at work. I designed the architecture, made every decision, reviewed every line, and wrote 1052 tests. This gem exists because I understand Rails deeply enough to know exactly what AI agents get wrong and what context they need to get it right.

```bash
gem "rails-ai-context", group: :development
rails generate rails_ai_context:install
```

That's it. Your AI now has 37 tools that understand your entire Rails app — via MCP server or CLI. Zero config.

> **[Full Guide →](docs/GUIDE.md)** — every command, every parameter, every configuration option.

---

## Two ways to use it

### MCP Server — AI calls tools directly

```
rails ai:serve
```

Your AI agent calls tools via the MCP protocol. Auto-discovered via `.mcp.json` — no manual config.

```
→ rails_search_code(pattern: "can_cook?", match_type: "trace")
→ rails_get_schema(table: "users")
→ rails_analyze_feature(feature: "billing")
```

### CLI — works everywhere, no server needed

```bash
rails 'ai:tool[search_code]' pattern="can_cook?" match_type=trace
rails 'ai:tool[schema]' table=users
rails 'ai:tool[analyze_feature]' feature=billing
```

Same 37 tools. Same output. AI agents run these as shell commands. **Works in any terminal, any AI tool, any workflow.** No MCP client required.

---

## What AI gets wrong without this

Your AI agent right now:

- **Reads all 2,000 lines of schema.rb** to find one column type
- **Misses encrypted columns** — doesn't know `gemini_api_key` is encrypted
- **Shows 25 Devise methods** as if they're your code
- **Doesn't see inherited filters** — misses `authenticate_user!` from ApplicationController
- **Uses underscores in Stimulus HTML** — `data-cook_status` instead of `data-cook-status`
- **Breaks Turbo Stream wiring** — broadcasts to channels nobody subscribes to
- **Guesses your UI patterns** — invents new button styles instead of matching yours

**Every wrong guess = a wasted iteration.** You fix it, re-run, it breaks something else.

---

## What AI knows with this

One call. Full picture.

```
rails 'ai:tool[search_code]' pattern="can_cook?" match_type=trace
```

```
# Trace: can_cook?

## Definition
app/models/concerns/plan_limitable.rb:8
  def can_cook?
    p = effective_plan
    return true if p.unlimited_cooks?
    (cooks_this_month || 0) < p.cooks_per_month
  end

## Calls internally
- unlimited_cooks?

## Called from (8 sites)
### app/controllers/cooks_controller.rb (Controller)
  24: unless current_user.can_cook?
### app/views/cooks/new.html.erb (View)
  7: <% unless current_user.can_cook? %>
### test/models/concerns/plan_limitable_test.rb (Test)
  24: assert @user.can_cook?
  29: assert_not @user.can_cook?
```

Definition + source code + every caller grouped by type + what it calls internally. **One call replaces 6 file reads.**

---

## Real-world examples

### "Add a subscription field to users"

```bash
# Step 1: Check what exists
rails 'ai:tool[schema]' table=users
# → 20 columns, types, indexes, encrypted hints, defaults

# Step 2: Understand the model
rails 'ai:tool[model_details]' model=User
# → associations, validations, scopes, enums, callbacks, Devise modules

# Step 3: See the full feature
rails 'ai:tool[analyze_feature]' feature=subscription
# → models + controllers + routes + services + jobs + views + tests in one shot
```

AI now writes a correct migration, model change, and controller update on the **first attempt**.

### "Fix the broken cook creation flow"

```bash
# Trace what happens
rails 'ai:tool[controllers]' controller=CooksController action=create
# → source code + inherited filters + strong params + render map + side effects

# Check the routes
rails 'ai:tool[routes]' controller=cooks
# → code-ready helpers (cook_path(@record)) + required params

# Validate after fixing
rails 'ai:tool[validate]' files=app/controllers/cooks_controller.rb level=rails
# → syntax + semantics + Brakeman security scan
```

### "Build a new dashboard view"

```bash
# Get the design system
rails 'ai:tool[design_system]' detail=standard
# → your actual button classes, card patterns, color palette — copy-paste ready

# Check existing view patterns
rails 'ai:tool[view]' controller=dashboard
# → templates with ivars, Turbo frames, Stimulus controllers, partial locals

# Get Stimulus data-attributes
rails 'ai:tool[stimulus]' controller=chart
# → correct HTML with dashes (not underscores) + reverse view lookup
```

---

## Measured token savings

Tested on a real Rails 8 app (5 models, 19 controllers, 95 routes):

| Task | Without gem | With gem | Saved |
|------|-------------|----------|-------|
| Trace a method across the codebase | ~9,080 tokens (read 5 files) | ~198 tokens (1 tool call) | **98%** |
| Understand a feature (schema + model + controller) | ~5,200 tokens (read 3 files) | ~1,500 tokens (2 tool calls) | **71%** |
| Check all table columns | ~2,573 tokens (read schema.rb) | ~908 tokens (1 tool call) | **65%** |

> Savings scale with app size. A 50-model app reads more files per task — tool calls stay the same size.

---

## 37 Tools

Every tool is **read-only** and returns structured, token-efficient data.

| Tool | MCP | CLI | What it does |
|------|-----|-----|-------------|
| **Search & Trace** | | | |
| `search_code` | `rails_search_code(pattern:"X", match_type:"trace")` | `rails 'ai:tool[search_code]'` | Trace: definition + source + callers + test coverage. Also: definition, call, class filters |
| `get_edit_context` | `rails_get_edit_context(file:"X", near:"Y")` | `rails 'ai:tool[edit_context]'` | Method-aware code extraction with class context |
| **Understand** | | | |
| `analyze_feature` | `rails_analyze_feature(feature:"X")` | `rails 'ai:tool[analyze_feature]'` | Full-stack: models + controllers + routes + services + jobs + views + tests |
| `get_context` | `rails_get_context(model:"X")` | `rails 'ai:tool[context]'` | Composite: schema + model + controller + routes + views in one call |
| **Schema & Models** | | | |
| `get_schema` | `rails_get_schema(table:"X")` | `rails 'ai:tool[schema]'` | Columns with indexed/unique/encrypted/default hints |
| `get_model_details` | `rails_get_model_details(model:"X")` | `rails 'ai:tool[model_details]'` | Associations, validations, scopes, enums, macros, delegations |
| `get_callbacks` | `rails_get_callbacks(model:"X")` | `rails 'ai:tool[callbacks]'` | Callbacks in Rails execution order with source |
| `get_concern` | `rails_get_concern(name:"X")` | `rails 'ai:tool[concern]'` | Concern methods + source + which models include it |
| **Controllers & Routes** | | | |
| `get_controllers` | `rails_get_controllers(controller:"X")` | `rails 'ai:tool[controllers]'` | Actions + inherited filters + render map + strong params |
| `get_routes` | `rails_get_routes(controller:"X")` | `rails 'ai:tool[routes]'` | Code-ready helpers (`cook_path(@record)`) + required params |
| **Views & Frontend** | | | |
| `get_view` | `rails_get_view(controller:"X")` | `rails 'ai:tool[view]'` | Templates with ivars, Turbo wiring, Stimulus refs, partial locals |
| `get_stimulus` | `rails_get_stimulus(controller:"X")` | `rails 'ai:tool[stimulus]'` | HTML data-attributes (dashes!) + targets + values + actions |
| `get_design_system` | `rails_get_design_system` | `rails 'ai:tool[design_system]'` | Copy-paste HTML/ERB patterns for your actual components |
| `get_partial_interface` | `rails_get_partial_interface(partial:"X")` | `rails 'ai:tool[partial_interface]'` | What locals to pass + what methods are called on them |
| `get_turbo_map` | `rails_get_turbo_map` | `rails 'ai:tool[turbo_map]'` | Broadcast → subscription wiring + mismatch warnings |
| **Testing** | | | |
| `get_test_info` | `rails_get_test_info(model:"X")` | `rails 'ai:tool[test_info]'` | Fixtures + relationships + test template matching your patterns |
| `validate` | `rails_validate(files:[...])` | `rails 'ai:tool[validate]'` | Syntax + semantic + Brakeman security in one call |
| `security_scan` | `rails_security_scan` | `rails 'ai:tool[security_scan]'` | Brakeman static analysis — SQL injection, XSS, mass assignment |
| **App Config** | | | |
| `get_conventions` | `rails_get_conventions` | `rails 'ai:tool[conventions]'` | Auth checks, flash messages, create action template, test patterns |
| `get_config` | `rails_get_config` | `rails 'ai:tool[config]'` | Database, auth framework, assets, cache, queue, Action Cable |
| `get_gems` | `rails_get_gems` | `rails 'ai:tool[gems]'` | Notable gems with versions, categories, config file locations |
| `get_env` | `rails_get_env` | `rails 'ai:tool[env]'` | Environment variables + credentials keys (not values) |
| `get_helper_methods` | `rails_get_helper_methods` | `rails 'ai:tool[helper_methods]'` | App + framework helpers with view cross-references |
| **Services & Jobs** | | | |
| `get_service_pattern` | `rails_get_service_pattern` | `rails 'ai:tool[service_pattern]'` | Interface, dependencies, side effects, callers |
| `get_job_pattern` | `rails_get_job_pattern` | `rails 'ai:tool[job_pattern]'` | Queue, retries, guard clauses, broadcasts, schedules |
| **Components & Quality** | | | |
| `get_component_catalog` | `rails_get_component_catalog` | `rails 'ai:tool[component_catalog]'` | ViewComponent/Phlex: props, slots, previews, sidecar assets, usage |
| `performance_check` | `rails_performance_check` | `rails 'ai:tool[performance_check]'` | N+1 risks, missing indexes, counter_cache, eager load candidates |
| `dependency_graph` | `rails_dependency_graph` | `rails 'ai:tool[dependency_graph]'` | Model/service dependency graph in Mermaid or text format |
| `migration_advisor` | `rails_migration_advisor` | `rails 'ai:tool[migration_advisor]'` | Migration code generation with reversibility + affected models |
| **Frontend** | | | |
| `get_frontend_stack` | `rails_get_frontend_stack` | `rails 'ai:tool[frontend_stack]'` | React/Vue/Svelte/Angular, Inertia, TypeScript, package manager |
| **Data & Debugging** | | | |
| `search_docs` | `rails_search_docs(topic:"X")` | `rails 'ai:tool[search_docs]'` | Bundled topic index with weighted keyword search, on-demand GitHub fetch |
| `query` | `rails_query(sql:"X")` | `rails 'ai:tool[query]'` | Safe read-only SQL queries with timeout, row limit, column redaction |
| `read_logs` | `rails_read_logs(level:"X")` | `rails 'ai:tool[read_logs]'` | Reverse file tail with level filtering and sensitive data redaction |

> **[Full parameter docs →](docs/GUIDE.md)**

---

## How It Works

```
┌─────────────────────────────────────────────────────────┐
│  Your Rails App                                          │
│  models + schema + routes + controllers + views + jobs   │
└────────────────────────┬────────────────────────────────┘
                         │ introspects (33 introspectors)
                         ▼
┌─────────────────────────────────────────────────────────┐
│  rails-ai-context                                        │
│  Parses everything. Caches results. Zero config.         │
└────────┬──────────────────┬──────────────┬──────────────┘
         │                  │              │
         ▼                  ▼              ▼
┌──────────────────┐ ┌────────────┐ ┌────────────────────┐
│  Static Files     │ │  MCP Server │ │  CLI Tools          │
│  CLAUDE.md        │ │  37 tools   │ │  Same 37 tools      │
│  .cursor/rules/   │ │  stdio/HTTP │ │  No server needed   │
│  .github/instr... │ │  .mcp.json  │ │  rails 'ai:tool[X]' │
└──────────────────┘ └────────────┘ └────────────────────┘
```

---

## Install

```bash
# Add to Gemfile
gem "rails-ai-context", group: :development

# Install — picks your AI tools, asks MCP or CLI mode, generates context
rails generate rails_ai_context:install

# Or generate context directly
rails ai:context
```

The install generator asks:
1. Which AI tools you use (Claude, Cursor, Copilot, OpenCode)
2. Whether you want MCP server support or CLI-only mode

MCP auto-discovery: `.mcp.json` is detected automatically by Claude Code and Cursor. No manual config.

> **[Full Guide →](docs/GUIDE.md)** — every command, parameter, and configuration option.

---

## Commands

| Command | What it does |
|---------|-------------|
| `rails ai:context` | Generate context files for your AI tools |
| `rails 'ai:tool[NAME]'` | Run any of the 37 tools from the CLI |
| `rails ai:tool` | List all available tools with short names |
| `rails ai:serve` | Start MCP server (stdio) |
| `rails ai:doctor` | Diagnostics + AI readiness score |
| `rails ai:watch` | Auto-regenerate on file changes |
| `rails ai:inspect` | Print introspection summary |

---

## Configuration

```ruby
# config/initializers/rails_ai_context.rb
RailsAiContext.configure do |config|
  # AI tools to generate context for (selected during install)
  # config.ai_tools = %i[claude cursor]

  # Tool mode: :mcp (default, MCP + CLI fallback) or :cli (CLI only)
  # config.tool_mode = :mcp

  # Presets: :full (32 introspectors, default) or :standard (14 core)
  # config.preset = :full

  # Exclude models from introspection
  # config.excluded_models += %w[AdminUser]

  # Skip specific tools
  # config.skip_tools = %w[rails_security_scan]
end
```

<details>
<summary><strong>All configuration options</strong></summary>

| Option | Default | Description |
|--------|---------|-------------|
| **Presets & Introspectors** | | |
| `preset` | `:full` | Introspector preset (`:full` or `:standard`) |
| `introspectors` | 32 (full) | Array of introspector symbols |
| **Context Generation** | | |
| `context_mode` | `:compact` | `:compact` (≤150 lines) or `:full` (dump everything) |
| `claude_max_lines` | `150` | Max lines for CLAUDE.md in compact mode |
| `generate_root_files` | `true` | Generate root files (CLAUDE.md, etc.) — set `false` for split rules only |
| `ai_tools` | `nil` (all) | AI tools to generate context for: `%i[claude cursor copilot opencode]` |
| `tool_mode` | `:mcp` | `:mcp` (MCP primary + CLI fallback) or `:cli` (CLI only, no MCP server) |
| **MCP Server** | | |
| `cache_ttl` | `60` | Cache TTL in seconds |
| `max_tool_response_chars` | `200_000` | Safety cap for MCP tool responses |
| `live_reload` | `:auto` | `:auto`, `true`, or `false` — MCP live reload |
| `auto_mount` | `false` | Auto-mount HTTP MCP endpoint |
| **File Size Limits** | | |
| `max_file_size` | `5_000_000` | Per-file read limit (bytes) |
| `max_search_results` | `200` | Max search results per call |
| `max_validate_files` | `50` | Max files per validate call |
| **Extensibility** | | |
| `custom_tools` | `[]` | Additional MCP tool classes |
| `skip_tools` | `[]` | Built-in tool names to exclude |
</details>

---

## Requirements

- Ruby >= 3.2, Rails >= 7.1
- Optional: `brakeman` for security scanning, `listen` for watch mode, `ripgrep` for fast search

---

## Contributing

```bash
git clone https://github.com/crisnahine/rails-ai-context.git
cd rails-ai-context && bundle install
bundle exec rspec       # 983 examples
bundle exec rubocop     # Lint
```

Bug reports and pull requests welcome at [github.com/crisnahine/rails-ai-context](https://github.com/crisnahine/rails-ai-context).

## Sponsorship

If rails-ai-context saves you time, consider [becoming a sponsor](https://github.com/sponsors/crisnahine).

## License

[MIT](LICENSE)
