<div align="center">

# rails-ai-context

**Your AI is guessing your Rails app. Every guess costs you time.**


<a href="https://claude.ai/claude-code"><img src="https://img.shields.io/badge/Claude_Code-ee8b4a?style=for-the-badge&logo=anthropic&logoColor=white" alt="Claude Code"></a>
<a href="https://cursor.com"><img src="https://img.shields.io/badge/Cursor-000000?style=for-the-badge&logo=cursor&logoColor=white" alt="Cursor"></a>
<a href="https://github.com/features/copilot"><img src="https://img.shields.io/badge/GitHub_Copilot-000000?style=for-the-badge&logo=githubcopilot&logoColor=white" alt="GitHub Copilot"></a>
<a href="https://opencode.ai"><img src="https://img.shields.io/badge/OpenCode-4285F4?style=for-the-badge&logoColor=white" alt="OpenCode"></a>
<a href="#-cli--works-everywhere"><img src="https://img.shields.io/badge/Any_Terminal-4EAA25?style=for-the-badge&logo=gnubash&logoColor=white" alt="Any Terminal"></a>



[![Gem Version](https://img.shields.io/gem/v/rails-ai-context?color=brightgreen)](https://rubygems.org/gems/rails-ai-context)
[![Downloads](https://img.shields.io/gem/dt/rails-ai-context?color=blue)](https://rubygems.org/gems/rails-ai-context)
[![CI](https://github.com/crisnahine/rails-ai-context/actions/workflows/ci.yml/badge.svg)](https://github.com/crisnahine/rails-ai-context/actions)
[![MCP Registry](https://img.shields.io/badge/MCP_Registry-listed-green)](https://registry.modelcontextprotocol.io)
[![Ruby](https://img.shields.io/badge/Ruby-3.2%20%7C%203.3%20%7C%203.4-CC342D)](https://github.com/crisnahine/rails-ai-context)
[![Rails](https://img.shields.io/badge/Rails-7.1%20%7C%207.2%20%7C%208.0-CC0000)](https://github.com/crisnahine/rails-ai-context)
[![Tests](https://img.shields.io/badge/Tests-1529%20passing-brightgreen)](https://github.com/crisnahine/rails-ai-context/actions)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

</div>



## The problem

You've seen it. Your AI:

- **Writes a migration for a column that already exists** — didn't check the schema
- **Creates a method that duplicates one in a concern** — didn't know it was there
- **Uses the wrong association name** — `user.posts` when it's `user.articles`
- **Generates tests that don't match your patterns** — factories when you use fixtures, or the reverse
- **Adds a gem you already have** — or calls an API from one you don't
- **Reads 2,000 lines of schema.rb** to answer a question about one table
- **Misses `before_action` filters from parent controllers** — then wonders why auth fails

You catch it. You fix it. You re-prompt. It breaks something else.

**That loop is the actual cost of AI coding — not the tokens, the corrections.**

<br>

## Two commands. Problem gone.

```bash
gem "rails-ai-context", group: :development
rails generate rails_ai_context:install
```

<div align="center">

![Install demo](demo.gif)

</div>

Now your AI doesn't guess — it **asks your app directly.** 39 tools that query your schema, models, routes, controllers, views, and conventions on demand. It gets the right answer the first time.

<br>

## See the difference

<div align="center">

![Trace demo](demo-trace.gif)

</div>

One call returns: definition + source code + every caller grouped by type + tests. **Replaces 4-5 sequential file reads.**

<br>

## Measured token savings

Real numbers from a production Rails app:

| Task | Without | With | Saved |
|:-----|--------:|-----:|------:|
| Get one table's columns | 1,492 tokens | 335 tokens | **77%** |
| Trace a method across codebase | 10,556 tokens | 256 tokens | **97%** |
| Understand a model | 1,754 tokens | 588 tokens | **66%** |
| Map Stimulus controllers | 9,886 tokens | 620 tokens | **94%** |
| Routes for one controller | 373 tokens | 121 tokens | **68%** |

<details>
<summary><strong>How to reproduce these numbers yourself</strong></summary>

<br>

```bash
# Schema: full file vs one table
wc -c db/schema.rb
rails 'ai:tool[schema]' table=users | wc -c

# Trace: all files AI reads vs one call
rails 'ai:tool[search_code]' pattern=your_method match_type=trace | wc -c

# Model: raw file + schema vs structured output
wc -c app/models/user.rb db/schema.rb
rails 'ai:tool[model_details]' model=User | wc -c
```

Divide bytes by 4 for rough token count. Bigger apps save more — tool output stays focused while raw files grow.

</details>

<br>

## Two ways to use it

<table>
<tr>
<td width="50%">

### MCP Server

AI calls tools directly via the protocol. Auto-discovered through `.mcp.json`.

```
rails ai:serve
```

```
→ rails_search_code(pattern: "can_cook?", match_type: "trace")
→ rails_get_schema(table: "users")
→ rails_analyze_feature(feature: "billing")
```

</td>
<td width="50%">

### CLI

Same 39 tools, no server needed. Works in any terminal, any AI tool.

```bash
rails 'ai:tool[search_code]' pattern="can_cook?" match_type=trace
rails 'ai:tool[schema]' table=users
rails 'ai:tool[analyze_feature]' feature=billing
```

</td>
</tr>
</table>

> **[Full Guide →](docs/GUIDE.md)** — every command, every parameter, every configuration option.

<br>

## Real-world examples

<details>
<summary><strong>"Add a subscription field to users"</strong></summary>

<br>

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

AI writes a correct migration, model change, and controller update on the **first attempt**.

</details>

<details>
<summary><strong>"Fix the broken cook creation flow"</strong></summary>

<br>

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

</details>

<details>
<summary><strong>"Build a new dashboard view"</strong></summary>

<br>

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

</details>

<br>

## 39 Tools

Every tool is **read-only** and returns structured, token-efficient context.

<details>
<summary><strong>Search & Trace</strong></summary>

| Tool | What it does |
|:-----|:------------|
| `search_code` | Trace: definition + source + callers + tests. Also: definition, call, class filters |
| `get_edit_context` | Method-aware code extraction with class context |

</details>

<details>
<summary><strong>Understand</strong></summary>

| Tool | What it does |
|:-----|:------------|
| `analyze_feature` | Full-stack: models + controllers + routes + services + jobs + views + tests |
| `get_context` | Composite: schema + model + controller + routes + views in one call |
| `onboard` | Narrative app walkthrough (quick/standard/full) |

</details>

<details>
<summary><strong>Schema & Models</strong></summary>

| Tool | What it does |
|:-----|:------------|
| `get_schema` | Columns with indexed/unique/encrypted/default hints |
| `get_model_details` | Associations, validations, scopes, enums, macros, delegations |
| `get_callbacks` | Callbacks in Rails execution order with source |
| `get_concern` | Concern methods + source + which models include it |

</details>

<details>
<summary><strong>Controllers & Routes</strong></summary>

| Tool | What it does |
|:-----|:------------|
| `get_controllers` | Actions + inherited filters + render map + strong params |
| `get_routes` | Code-ready helpers (`cook_path(@record)`) + required params |

</details>

<details>
<summary><strong>Views & Frontend</strong></summary>

| Tool | What it does |
|:-----|:------------|
| `get_view` | Templates with ivars, Turbo wiring, Stimulus refs, partial locals |
| `get_stimulus` | HTML data-attributes (dashes!) + targets + values + actions |
| `get_design_system` | Copy-paste HTML/ERB patterns for your actual components |
| `get_partial_interface` | What locals to pass + what methods are called on them |
| `get_turbo_map` | Broadcast → subscription wiring + mismatch warnings |
| `get_frontend_stack` | React/Vue/Svelte/Angular, Hotwire, TypeScript, package manager |

</details>

<details>
<summary><strong>Testing & Quality</strong></summary>

| Tool | What it does |
|:-----|:------------|
| `get_test_info` | Fixtures + relationships + test template matching your patterns |
| `generate_test` | Test scaffolding matching your project's patterns |
| `validate` | Syntax + semantic + Brakeman security in one call |
| `security_scan` | Brakeman static analysis — SQL injection, XSS, mass assignment |
| `performance_check` | N+1 risks, missing indexes, counter_cache, eager load candidates |

</details>

<details>
<summary><strong>App Config & Services</strong></summary>

| Tool | What it does |
|:-----|:------------|
| `get_conventions` | Auth checks, flash messages, create action template, test patterns |
| `get_config` | Database, auth framework, assets, cache, queue, Action Cable |
| `get_gems` | Notable gems with versions, categories, config file locations |
| `get_env` | Environment variables + credentials keys (not values) |
| `get_helper_methods` | App + framework helpers with view cross-references |
| `get_service_pattern` | Interface, dependencies, side effects, callers |
| `get_job_pattern` | Queue, retries, guard clauses, broadcasts, schedules |
| `get_component_catalog` | ViewComponent/Phlex: props, slots, previews, sidecar assets |

</details>

<details>
<summary><strong>Data & Debugging</strong></summary>

| Tool | What it does |
|:-----|:------------|
| `dependency_graph` | Model/service dependency graph in Mermaid or text format |
| `migration_advisor` | Migration code generation with reversibility + affected models |
| `search_docs` | Bundled topic index with weighted keyword search |
| `query` | Safe read-only SQL with timeout, row limit, column redaction |
| `read_logs` | Reverse file tail with level filtering and sensitive data redaction |
| `diagnose` | One-call error diagnosis with classification + context + git + logs |
| `review_changes` | PR/commit review with per-file context + warnings |
| `runtime_info` | Live DB pool, table sizes, pending migrations, cache stats, queue depth |
| `session_context` | Session-aware context tracking across tool calls |

</details>

> **[Full parameter docs →](docs/GUIDE.md)**

<br>

## How it works

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
│  CLAUDE.md        │ │  39 tools   │ │  Same 39 tools      │
│  .cursor/rules/   │ │  stdio/HTTP │ │  No server needed   │
│  .github/instr... │ │  .mcp.json  │ │  rails 'ai:tool[X]' │
└──────────────────┘ └────────────┘ └────────────────────┘
```

<br>

## Install

```bash
gem "rails-ai-context", group: :development
rails generate rails_ai_context:install
```

The installer asks which AI tools you use and whether you want MCP or CLI mode. That's it.

`.mcp.json` is auto-detected by Claude Code and Cursor — no manual config.

<br>

## Commands

| Command | What it does |
|:--------|:------------|
| `rails ai:context` | Generate context files for your AI tools |
| `rails 'ai:tool[NAME]'` | Run any of the 39 tools from CLI |
| `rails ai:tool` | List all available tools |
| `rails ai:serve` | Start MCP server (stdio) |
| `rails ai:doctor` | Diagnostics + AI readiness score |
| `rails ai:watch` | Auto-regenerate on file changes |

<br>

## Configuration

```ruby
# config/initializers/rails_ai_context.rb
RailsAiContext.configure do |config|
  config.ai_tools   = %i[claude cursor]   # Which AI tools to generate for
  config.tool_mode   = :mcp               # :mcp (default) or :cli
  config.preset      = :full              # :full (33 introspectors) or :standard (19)
end
```

<details>
<summary><strong>All configuration options</strong></summary>

<br>

| Option | Default | Description |
|:-------|:--------|:------------|
| `preset` | `:full` | `:full` (33 introspectors) or `:standard` (19) |
| `context_mode` | `:compact` | `:compact` (150 lines) or `:full` |
| `generate_root_files` | `true` | Set `false` for split rules only |
| `cache_ttl` | `60` | Cache TTL in seconds |
| `max_tool_response_chars` | `200_000` | Safety cap for tool responses |
| `live_reload` | `:auto` | `:auto`, `true`, or `false` |
| `custom_tools` | `[]` | Additional MCP tool classes |
| `skip_tools` | `[]` | Built-in tools to exclude |
| `excluded_models` | `[]` | Models to skip during introspection |

</details>

<br>

## Requirements

- **Ruby** >= 3.2 &nbsp;&nbsp; **Rails** >= 7.1
- **Optional:** `brakeman` for security scanning, `listen` for watch mode, `ripgrep` for fast search

<br>

---

<div align="center">

## About

Built by a Rails developer with 10+ years of production experience.<br>
1529 tests. 39 tools. 33 introspectors. Zero config.<br>
MIT licensed. [Contributions welcome.](CONTRIBUTING.md)

<br>

If this gem saves you time, consider [sponsoring the project](https://github.com/sponsors/crisnahine).

<br>

[![MIT License](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

</div>
