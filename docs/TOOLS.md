<div align="center" markdown="1">

# MCP Tools Reference

**All 38 read-only tools, with every parameter.**

[Quickstart](QUICKSTART.md) · [Recipes](RECIPES.md) · [Custom Tools](CUSTOM_TOOLS.md) · [CLI Reference](CLI.md)

</div>

---

## Table of Contents

- [Calling tools](#calling-tools)
- [Quick navigation](#quick-navigation)
- [Search & Trace](#search--trace)
- [Understand](#understand)
- [Schema & Models](#schema--models)
- [Controllers & Routes](#controllers--routes)
- [Views & Frontend](#views--frontend)
- [Testing & Quality](#testing--quality)
- [App Config & Services](#app-config--services)
- [Data & Debugging](#data--debugging)
- [Live Resources (VFS)](#live-resources-vfs)

---

## Calling tools

```bash
# MCP — AI calls automatically via protocol
# CLI — you call from terminal:
rails 'ai:tool[schema]' table=users detail=full
rails-ai-context tool schema --table users --detail full
```

Tool name resolution is flexible — all of these work:

| You type | Resolves to |
|:---------|:------------|
| `schema` | `rails_get_schema` |
| `get_schema` | `rails_get_schema` |
| `rails_get_schema` | `rails_get_schema` |

Individual lookup tools accept a **`detail`** parameter: `summary` (compact), `standard` (default), or `full` (everything). Start with summary, drill down as needed. Composite tools (`rails_get_context`, `rails_analyze_feature`) do not accept `detail`.

<p align="right"><a href="#table-of-contents">↑ back to top</a></p>

---

## Quick navigation

| Category | Tools |
|:---------|:------|
| [Search & Trace](#search--trace) | `search_code`, `get_edit_context` |
| [Understand](#understand) | `analyze_feature`, `get_context`, `onboard` |
| [Schema & Models](#schema--models) | `get_schema`, `get_model_details`, `get_callbacks`, `get_concern` |
| [Controllers & Routes](#controllers--routes) | `get_controllers`, `get_routes` |
| [Views & Frontend](#views--frontend) | `get_view`, `get_stimulus`, `get_partial_interface`, `get_turbo_map`, `get_frontend_stack` |
| [Testing & Quality](#testing--quality) | `get_test_info`, `generate_test`, `validate`, `security_scan`, `performance_check` |
| [App Config & Services](#app-config--services) | `get_conventions`, `get_config`, `get_gems`, `get_env`, `get_helper_methods`, `get_service_pattern`, `get_job_pattern`, `get_component_catalog` |
| [Data & Debugging](#data--debugging) | `dependency_graph`, `migration_advisor`, `search_docs`, `query`, `read_logs`, `diagnose`, `review_changes`, `runtime_info`, `session_context` |

<p align="right"><a href="#table-of-contents">↑ back to top</a></p>

---

## Search & Trace

### `rails_search_code`

Search your codebase with regex, ripgrep acceleration, and sensitive file blocking.

| Parameter | Type | Default | Description |
|:----------|:-----|:--------|:------------|
| `pattern` | string | *required* | Regex pattern to search for |
| `path` | string | — | Subdirectory to search in (relative to Rails root) |
| `match_type` | enum | `any` | `any`, `definition`, `class`, `call`, `trace` |
| `file_type` | string | — | Filter by extension (`rb`, `erb`, `js`, etc.) |
| `exact_match` | boolean | `false` | Word boundary matching |
| `exclude_tests` | boolean | `false` | Skip test/spec directories |
| `group_by_file` | boolean | `false` | Group results by file with counts |

> **Trace mode** returns definition + source code + every caller grouped by type + tests — replaces 4-5 sequential file reads.

### `rails_get_edit_context`

Method-aware code extraction with surrounding class context.

| Parameter | Type | Default | Description |
|:----------|:-----|:--------|:------------|
| `file` | string | *required* | File path relative to Rails root |
| `method_name` | string | — | Extract a specific method |
| `line` | integer | — | Center extraction around a line number |

<p align="right"><a href="#table-of-contents">↑ back to top</a></p>

---

## Understand

### `rails_analyze_feature`

Full-stack feature analysis: models + controllers + routes + services + jobs + views + tests in one call.

| Parameter | Type | Default | Description |
|:----------|:-----|:--------|:------------|
| `feature` | string | *required* | Feature name (e.g., `billing`, `auth`, `subscription`) |
| `detail` | enum | `standard` | `summary`, `standard`, `full` |

### `rails_get_context`

Composite context: schema + model + controller + routes + views for a resource.

| Parameter | Type | Default | Description |
|:----------|:-----|:--------|:------------|
| `resource` | string | *required* | Resource name (e.g., `users`, `Post`) |
| `action` | string | — | Specific controller action |
| `detail` | enum | `standard` | `summary`, `standard`, `full` |

### `rails_onboard`

Narrative app walkthrough for getting up to speed.

| Parameter | Type | Default | Description |
|:----------|:-----|:--------|:------------|
| `detail` | enum | `standard` | `quick`, `standard`, `full` |

<p align="right"><a href="#table-of-contents">↑ back to top</a></p>

---

## Schema & Models

### `rails_get_schema`

Database schema with column types, indexes, defaults, encrypted hints.

| Parameter | Type | Default | Description |
|:----------|:-----|:--------|:------------|
| `table` | string | — | Specific table (omit for overview) |
| `detail` | enum | `standard` | `summary`, `standard`, `full` |

### `rails_get_model_details`

AST-parsed model internals. Every result carries `[VERIFIED]` or `[INFERRED]` confidence tag.

| Parameter | Type | Default | Description |
|:----------|:-----|:--------|:------------|
| `model` | string | — | Model name (e.g., `User`, `Post`) |
| `detail` | enum | `standard` | `summary`, `standard`, `full` |

Returns: associations, validations, scopes, enums, callbacks, macros, methods, concerns.

### `rails_get_callbacks`

All callbacks in Rails execution order with source code.

| Parameter | Type | Default | Description |
|:----------|:-----|:--------|:------------|
| `model` | string | *required* | Model name |
| `detail` | enum | `standard` | `summary`, `standard`, `full` |

### `rails_get_concern`

Concern methods, source code, and which models include it.

| Parameter | Type | Default | Description |
|:----------|:-----|:--------|:------------|
| `concern` | string | *required* | Concern name (e.g., `Trackable`, `Searchable`) |
| `detail` | enum | `standard` | `summary`, `standard`, `full` |

<p align="right"><a href="#table-of-contents">↑ back to top</a></p>

---

## Controllers & Routes

### `rails_get_controllers`

Controller actions with inherited filters, render map, strong params. Includes schema hints for referenced models.

| Parameter | Type | Default | Description |
|:----------|:-----|:--------|:------------|
| `controller` | string | — | Controller name (e.g., `UsersController`) |
| `action` | string | — | Specific action |
| `detail` | enum | `standard` | `summary`, `standard`, `full` |

### `rails_get_routes`

Routes with code-ready helpers (`post_path(@record)`) and required params.

| Parameter | Type | Default | Description |
|:----------|:-----|:--------|:------------|
| `controller` | string | — | Filter by controller |
| `detail` | enum | `standard` | `summary`, `standard`, `full` |

<p align="right"><a href="#table-of-contents">↑ back to top</a></p>

---

## Views & Frontend

### `rails_get_view`

View templates with instance variables, Turbo frames, Stimulus controllers, partial locals. Includes schema hints for detected ivars.

| Parameter | Type | Default | Description |
|:----------|:-----|:--------|:------------|
| `controller` | string | — | Controller name |
| `action` | string | — | Specific action view |
| `detail` | enum | `standard` | `summary`, `standard`, `full` |

### `rails_get_stimulus`

Stimulus controller data-attributes (with dashes, not underscores) + targets + values + actions + reverse view lookup.

| Parameter | Type | Default | Description |
|:----------|:-----|:--------|:------------|
| `controller` | string | — | Stimulus controller name |
| `detail` | enum | `standard` | `summary`, `standard`, `full` |

### `rails_get_partial_interface`

What locals to pass to a partial and what methods are called on them.

| Parameter | Type | Default | Description |
|:----------|:-----|:--------|:------------|
| `partial` | string | *required* | Partial path (e.g., `users/form`) |
| `detail` | enum | `standard` | `summary`, `standard`, `full` |

### `rails_get_turbo_map`

Turbo Stream broadcast-to-subscription wiring with mismatch warnings.

| Parameter | Type | Default | Description |
|:----------|:-----|:--------|:------------|
| `detail` | enum | `standard` | `summary`, `standard`, `full` |

### `rails_get_frontend_stack`

Auto-detects React/Vue/Svelte/Angular, Hotwire, TypeScript, Vite/Shakapacker, package manager, monorepo layout.

| Parameter | Type | Default | Description |
|:----------|:-----|:--------|:------------|
| `detail` | enum | `standard` | `summary`, `standard`, `full` |

<p align="right"><a href="#table-of-contents">↑ back to top</a></p>

---

## Testing & Quality

### `rails_get_test_info`

Test fixtures, relationships, and template matching your project's patterns.

| Parameter | Type | Default | Description |
|:----------|:-----|:--------|:------------|
| `model` | string | — | Model to find tests for |
| `detail` | enum | `standard` | `summary`, `standard`, `full` |

### `rails_generate_test`

Test scaffolding that matches your project's patterns (fixtures vs factories, RSpec vs Minitest).

| Parameter | Type | Default | Description |
|:----------|:-----|:--------|:------------|
| `file` | string | *required* | File to generate tests for |
| `detail` | enum | `standard` | `summary`, `standard`, `full` |

### `rails_validate`

Syntax + semantic + Brakeman security validation in one call.

| Parameter | Type | Default | Description |
|:----------|:-----|:--------|:------------|
| `files` | string | — | Comma-separated file paths |
| `level` | enum | `syntax` | `syntax`, `rails`, `security` |

### `rails_security_scan`

Brakeman static analysis: SQL injection, XSS, mass assignment, command injection.

| Parameter | Type | Default | Description |
|:----------|:-----|:--------|:------------|
| `detail` | enum | `standard` | `summary`, `standard`, `full` |

> Requires the `brakeman` gem. Gracefully reports "not installed" if missing.

### `rails_performance_check`

N+1 query risks, missing indexes, missing counter_cache, eager load candidates.

| Parameter | Type | Default | Description |
|:----------|:-----|:--------|:------------|
| `detail` | enum | `standard` | `summary`, `standard`, `full` |

<p align="right"><a href="#table-of-contents">↑ back to top</a></p>

---

## App Config & Services

### `rails_get_conventions`

Auth checks, flash messages, create action template, test patterns.

| Parameter | Type | Default | Description |
|:----------|:-----|:--------|:------------|
| `detail` | enum | `standard` | `summary`, `standard`, `full` |

### `rails_get_config`

Database config, auth framework, assets, cache, queue, Action Cable.

| Parameter | Type | Default | Description |
|:----------|:-----|:--------|:------------|
| `detail` | enum | `standard` | `summary`, `standard`, `full` |

### `rails_get_gems`

Notable gems with versions, categories, and config file locations.

| Parameter | Type | Default | Description |
|:----------|:-----|:--------|:------------|
| `detail` | enum | `standard` | `summary`, `standard`, `full` |

### `rails_get_env`

Environment variables + credentials keys (values are never exposed).

| Parameter | Type | Default | Description |
|:----------|:-----|:--------|:------------|
| `detail` | enum | `standard` | `summary`, `standard`, `full` |

### `rails_get_helper_methods`

Application and framework helpers with view cross-references.

| Parameter | Type | Default | Description |
|:----------|:-----|:--------|:------------|
| `detail` | enum | `standard` | `summary`, `standard`, `full` |

### `rails_get_service_pattern`

Service object interface, dependencies, side effects, callers.

| Parameter | Type | Default | Description |
|:----------|:-----|:--------|:------------|
| `service` | string | *required* | Service class name |
| `detail` | enum | `standard` | `summary`, `standard`, `full` |

### `rails_get_job_pattern`

Background job queue, retries, guard clauses, broadcasts, schedules.

| Parameter | Type | Default | Description |
|:----------|:-----|:--------|:------------|
| `job` | string | — | Specific job name |
| `detail` | enum | `standard` | `summary`, `standard`, `full` |

### `rails_get_component_catalog`

ViewComponent/Phlex components: props, slots, previews, sidecar assets, usage examples.

| Parameter | Type | Default | Description |
|:----------|:-----|:--------|:------------|
| `component` | string | — | Specific component name |
| `detail` | enum | `standard` | `summary`, `standard`, `full` |

<p align="right"><a href="#table-of-contents">↑ back to top</a></p>

---

## Data & Debugging

### `rails_dependency_graph`

Model/service dependency graph in Mermaid or text format.

| Parameter | Type | Default | Description |
|:----------|:-----|:--------|:------------|
| `root` | string | — | Starting node |
| `format` | enum | `text` | `text`, `mermaid` |
| `detail` | enum | `standard` | `summary`, `standard`, `full` |

### `rails_migration_advisor`

Migration code generation with duplicate/nonexistent column warnings, reversibility flags, table name normalization.

| Parameter | Type | Default | Description |
|:----------|:-----|:--------|:------------|
| `action` | string | *required* | Migration action (e.g., `add_column`, `create_table`) |
| `table` | string | *required* | Table name |
| `columns` | string | — | Column definitions |
| `detail` | enum | `standard` | `summary`, `standard`, `full` |

### `rails_search_docs`

Bundled topic index with weighted keyword search. Optional on-demand GitHub fetch.

| Parameter | Type | Default | Description |
|:----------|:-----|:--------|:------------|
| `query` | string | *required* | Search query |
| `fetch` | boolean | `false` | Fetch from GitHub if not found locally |

### `rails_query`

Safe read-only SQL with 4-layer security: regex validation, `SET TRANSACTION READ ONLY`, timeout, column redaction. [Learn about the security model →](SECURITY.md)

| Parameter | Type | Default | Description |
|:----------|:-----|:--------|:------------|
| `sql` | string | *required* | SQL query (SELECT only) |
| `limit` | integer | `100` | Maximum rows to return (hard cap: 1000) |
| `format` | enum | `table` | `table`, `csv` |
| `explain` | boolean | `false` | Show query plan instead of results |

> Disabled in production by default.

### `rails_read_logs`

Reverse file tail with level filtering and sensitive data redaction.

| Parameter | Type | Default | Description |
|:----------|:-----|:--------|:------------|
| `file` | string | `development.log` | Log file name |
| `lines` | integer | `50` | Number of lines |
| `level` | enum | — | Filter: `debug`, `info`, `warn`, `error`, `fatal` |

### `rails_diagnose`

One-call error diagnosis with classification, context, git blame, and log correlation.

| Parameter | Type | Default | Description |
|:----------|:-----|:--------|:------------|
| `error` | string | *required* | Error message or class |
| `file` | string | — | File where error occurred |
| `line` | integer | — | Line number |

### `rails_review_changes`

PR/commit review with per-file context and warnings.

| Parameter | Type | Default | Description |
|:----------|:-----|:--------|:------------|
| `ref` | string | `HEAD` | Git ref to review |
| `detail` | enum | `standard` | `summary`, `standard`, `full` |

### `rails_runtime_info`

Live database pool stats, table sizes, pending migrations, cache stats, queue depth.

| Parameter | Type | Default | Description |
|:----------|:-----|:--------|:------------|
| `detail` | enum | `standard` | `summary`, `standard`, `full` |

### `rails_session_context`

Session-aware context tracking across tool calls within a conversation.

| Parameter | Type | Default | Description |
|:----------|:-----|:--------|:------------|
| `detail` | enum | `standard` | `summary`, `standard`, `full` |

<p align="right"><a href="#table-of-contents">↑ back to top</a></p>

---

## Live Resources (VFS)

In addition to tools, AI clients can read structured data through **resource templates** — `rails-ai-context://` URIs introspected fresh on every request. Zero stale data.

| URI Pattern | Returns |
|:------------|:--------|
| `rails-ai-context://controllers/{name}` | Actions, inherited filters, strong params |
| `rails-ai-context://controllers/{name}/{action}` | Action source with applicable filters |
| `rails-ai-context://views/{path}` | View template content |
| `rails-ai-context://routes/{controller}` | Live route map for controller |
| `rails://models/{name}` | Model details: associations, validations, schema |

Plus 9 static resources (schema, routes, conventions, gems, controllers, config, tests, migrations, engines).

<p align="right"><a href="#table-of-contents">↑ back to top</a></p>

---

<div align="center" markdown="1">

**[← Quickstart](QUICKSTART.md)** · **[Recipes →](RECIPES.md)**

[Back to Home](index.md)

</div>
