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
[![Tests](https://img.shields.io/badge/Tests-1668%20passing-brightgreen)](https://github.com/crisnahine/rails-ai-context/actions)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

</div>



## The problem

You've seen it. Your AI:

- **Writes a migration for a column that already exists** — didn't check the schema
- **Creates a method that duplicates one in a concern** — didn't know it was there
- **Uses the wrong association name** — `user.posts` when it's `user.articles`
- **Generates tests that don't match your patterns** — factories when you use fixtures, or the reverse
- **Adds a gem you already have** — or calls an API from one you don't
- **Misses `before_action` filters from parent controllers** — then wonders why auth fails
- **Invents a method** that isn't in your codebase — then you spend 10 minutes finding out

You catch it. You fix it. You re-prompt. It breaks something else.

**The real cost of AI coding isn't the tokens — it's the correction loop.** Every guess is a round-trip: you catch it, you fix it, you re-prompt, and something adjacent breaks. This gem kills the guessing at its source.

<br>

## Two commands. Problem gone.

```bash
gem "rails-ai-context", group: :development
rails generate rails_ai_context:install
```

### Or standalone — no Gemfile needed

```bash
gem install rails-ai-context
cd your-rails-app
rails-ai-context init     # interactive setup
rails-ai-context serve    # start MCP server
```

<div align="center">

![Install demo](demo.gif)

</div>

Now your AI doesn't guess — it **asks your app directly.** 38 tools that query your schema, models, routes, controllers, views, and conventions on demand. Model introspection uses Prism AST parsing — every result carries a `[VERIFIED]` or `[INFERRED]` confidence tag so AI knows what's ground truth and what needs runtime checking.

<br>

## See the difference

<div align="center">

![Trace demo](demo-trace.gif)

</div>

One call returns: definition + source code + every caller grouped by type + tests. **Replaces 4-5 sequential file reads.**

<br>

## What stops being wrong

Real scenarios where AI goes sideways — and what it does instead with ground truth:

| You ask AI to... | Without — AI guesses | With — AI verifies first |
|:-----|:-----|:-----|
| Add a `subscription_tier` column to users | Writes the migration, duplicates an existing column | Reads live schema, spots `subscription_status` already exists, asks before migrating |
| Call `user.posts` in a controller | Uses the guess; runtime `NoMethodError` | Resolves the actual association (`user.articles`) from the model |
| Write tests for a new model | Scaffolds with FactoryBot | Detects your fixture-based suite and matches it |
| Fix a failing create action | Misses inherited `before_action :authenticate_user!` | Returns parent-controller filters inline with the action source |
| Build a dashboard page | Invents Tailwind classes from memory | Returns your actual button/card/alert patterns, copy-paste ready |
| Trace where `can_cook?` is used | Reads 6 files sequentially, still misses callers | Single call: definition + source + every caller + tests |

<details>
<summary><strong>Verify it on your own app</strong></summary>

<br>

Run these before and after installing to see what changes in *your* codebase:

```bash
# Schema: does AI know what columns exist?
rails 'ai:tool[schema]' table=users

# Trace: find every caller of a method across the codebase
rails 'ai:tool[search_code]' pattern=your_method match_type=trace

# Model: associations, scopes, callbacks, concerns — all resolved
rails 'ai:tool[model_details]' model=User

# Controllers: action source + inherited filters + strong params in one shot
rails 'ai:tool[controllers]' controller=UsersController action=create
```

Compare what AI outputs with and without these tools wired in. The difference is measured in *corrections avoided*, not bytes saved.

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

Same 38 tools, no server needed. Works in any terminal, any AI tool.

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
# Check existing view patterns
rails 'ai:tool[view]' controller=dashboard
# → templates with ivars, Turbo frames, Stimulus controllers, partial locals

# See existing components + usage examples
rails 'ai:tool[component_catalog]' detail=standard
# → ViewComponent/Phlex props, slots, previews, sidecar assets

# Get Stimulus data-attributes
rails 'ai:tool[stimulus]' controller=chart
# → correct HTML with dashes (not underscores) + reverse view lookup
```

</details>

<br>

## 38 Tools

Every tool is **read-only** and returns data verified against your actual app — not guesses, not training data.

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
| `get_model_details` | AST-parsed associations, validations, scopes, enums, macros — each result tagged `[VERIFIED]` or `[INFERRED]` |
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

## Anti-Hallucination Protocol

Every generated context file ships with **6 rules that force AI verification** before writing code. The protocol targets the exact cognitive failures that produce confident-wrong code: statistical priors overriding observed facts, pattern completion beating verification, stale context lies.

<details>
<summary><strong>The 6 rules (shown to AI in every CLAUDE.md / .cursor/rules / .github/instructions)</strong></summary>

<br>

1. **Verify before you write.** Never reference a column, association, route, helper, method, class, partial, or gem not verified in THIS project via a tool call in THIS turn. Never invent names that "sound right."
2. **Mark every assumption.** If proceeding without verification, prefix with `[ASSUMPTION]`. Silent assumptions forbidden. "I'd need to check X first" is a preferred answer.
3. **Training data describes average Rails. This app isn't average.** When something feels "obviously" standard Rails, query anyway. Check `rails_get_conventions` + `rails_get_gems` BEFORE scaffolding.
4. **Check the inheritance chain before every edit.** Inherited `before_action` filters, concerns, includes, STI parents. Inheritance is never flat.
5. **Empty tool output is information, not permission.** "0 callers found" signals investigation, not license to proceed on guesses.
6. **Stale context lies. Re-query after writes.** Earlier tool output may be wrong after edits.

Enabled by default. Disable with `config.anti_hallucination_rules = false` if you prefer your own rules.

</details>

<br>

## How it works

```
┌─────────────────────────────────────────────────────────┐
│  Your Rails App                                          │
│  models + schema + routes + controllers + views + jobs   │
└────────────────────────┬────────────────────────────────┘
                         │ introspects (31 introspectors)
                         ▼
┌─────────────────────────────────────────────────────────┐
│  rails-ai-context                                        │
│  Prism AST parsing. Cached. Confidence-tagged results.    │
└────────┬──────────────────┬──────────────┬──────────────┘
         │                  │              │
         ▼                  ▼              ▼
┌──────────────────┐ ┌────────────┐ ┌────────────────────┐
│  Static Files     │ │  MCP Server │ │  CLI Tools          │
│  CLAUDE.md        │ │  38 tools   │ │  Same 38 tools      │
│  .cursor/rules/   │ │  stdio/HTTP │ │  No server needed   │
│  .github/instr... │ │  .mcp.json  │ │  rails 'ai:tool[X]' │
└──────────────────┘ └────────────┘ └────────────────────┘
```

<br>

## Install

**Option A — In Gemfile:**

```bash
gem "rails-ai-context", group: :development
rails generate rails_ai_context:install
```

**Option B — Standalone (no Gemfile entry needed):**

```bash
gem install rails-ai-context
cd your-rails-app
rails-ai-context init
```

Both paths ask which AI tools you use and whether you want MCP or CLI mode. `.mcp.json` is auto-detected by Claude Code and Cursor.

<br>

## Commands

| In-Gemfile | Standalone | What it does |
|:-----------|:-----------|:------------|
| `rails ai:context` | `rails-ai-context context` | Generate context files |
| `rails 'ai:tool[NAME]'` | `rails-ai-context tool NAME` | Run any of the 38 tools |
| `rails ai:tool` | `rails-ai-context tool --list` | List all available tools |
| `rails ai:serve` | `rails-ai-context serve` | Start MCP server (stdio) |
| `rails ai:doctor` | `rails-ai-context doctor` | Diagnostics + AI readiness score |
| `rails ai:watch` | `rails-ai-context watch` | Auto-regenerate on file changes |

<br>

## Configuration

```ruby
# config/initializers/rails_ai_context.rb
if defined?(RailsAiContext)
  RailsAiContext.configure do |config|
    config.ai_tools   = %i[claude cursor] # Which AI tools to generate for
    config.tool_mode  = :mcp              # :mcp (default) or :cli
    config.preset     = :full             # :full (31 introspectors) or :standard (17)
  end
end
```

<details>
<summary><strong>All configuration options</strong></summary>

<br>

| Option | Default | Description |
|:-------|:--------|:------------|
| `preset` | `:full` | `:full` (31 introspectors) or `:standard` (17) |
| `context_mode` | `:compact` | `:compact` (150 lines) or `:full` |
| `generate_root_files` | `true` | Set `false` for split rules only |
| `anti_hallucination_rules` | `true` | Embed 6-rule verification protocol in generated context files |
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
1668 tests. 38 tools. 31 introspectors. Standalone or in-Gemfile.<br>
MIT licensed. [Contributions welcome.](CONTRIBUTING.md)

<br>

If this gem saves you time, consider [sponsoring the project](https://github.com/sponsors/crisnahine).

<br>

[![MIT License](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

</div>
