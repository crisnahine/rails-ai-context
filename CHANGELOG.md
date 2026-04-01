# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [4.3.0] — 2026-04-01

### Added
- **`rails_onboard`** — narrative app walkthrough (quick/standard/full) for new developers and AI agents: stack, data model, authentication, key flows, jobs, frontend, testing, getting started
- **`rails_generate_test`** — generates test scaffolding matching project patterns: detects framework (RSpec/Minitest), factories vs fixtures, assertion style, Devise helpers; covers validations, associations, scopes, enums, request specs with routes
- **`rails_diagnose`** — one-call error diagnosis: parses error → classifies (nil_reference, record_not_found, validation_failure, routing, strong_params, schema_mismatch) → gathers controller/model/schema context → shows recent git changes → pulls error logs → suggests fix
- **`rails_review_changes`** — PR/commit review context: classifies changed files, pulls per-file context (model → schema, controller → routes, migration → affected models), detects warnings (missing indexes, removed validations, no test changes)
- **Improved AI instructions** — workflow sequencing (step-by-step tool call order), `detail` parameter guidance, anti-patterns section, `get_context` promoted as power tool, app-specific footer rules from conventions introspector
- **Compact tool name list** — root files (CLAUDE.md, AGENTS.md) now include all 37 tool names in a dense format that fits within the 150-line compact mode limit

### Changed
- Tool count: 33 → 37
- Test count: 1016 → 1052
- Root file render order: commands and rules before tool guide to prevent truncation
- Cursor rules description: fixed stale "25 tools" → "37 tools"

## [4.2.3] — 2026-04-01

### Fixed
- **Unicode output** — `rails_get_context` ivar cross-check now renders actual Unicode symbols (✓✗⚠) instead of literal `\u2713` escape sequences
- **Scope name rendering** — all 6 serializers (claude, cursor, copilot, opencode, claude_rules, copilot_instructions) now extract scope names from hash-style scope data instead of dumping raw `{:name=>"active", :body=>"..."}` into output
- **Scope exclusion** — `ModelIntrospector#extract_public_class_methods` now correctly extracts scope names from hash-style scope data so scopes are properly excluded from the class methods listing
- **Pending migrations check** — `Doctor#check_pending_migrations` now uses `MigrationContext#pending_migrations` on Rails 7.1+ instead of the deprecated `ActiveRecord::Migrator.new` API (silently returned nil on modern Rails)
- **SQLite query timeout** — `rails_query` now uses `set_progress_handler` for real statement timeout enforcement on SQLite instead of `busy_timeout` (which only controls lock-wait, not query execution time)
- **ripgrep caching** — `SearchCode.ripgrep_available?` now caches `false` results, avoiding repeated `which rg` system calls on every search when ripgrep is not installed
- **Controller action extraction** — `SearchCode#extract_controller_actions_from_matches` now correctly captures RESTful action names instead of always appending `nil` (was using `match?` which doesn't set `$1`, plus overly broad `[a-z_]+` regex)

### Changed
- Test count: 1003 → 1016

## [4.2.2] — 2026-04-01

### Fixed
- **Vite config detection** — framework plugin detection now checks `.mts`, `.mjs`, `.cts`, `.cjs` extensions in addition to `.ts` and `.js`
- **Component catalog ERB** — no-props no-slots components now generate inline `<%= render Foo.new %>` instead of misleading `do...end` block
- **Custom tools validation** — invalid entries in `config.custom_tools` are now filtered with a clear warning instead of crashing the MCP server with a cryptic `NoMethodError`

### Changed
- Test count: 998 → 1003

## [4.2.1] — 2026-03-31

### Fixed
- **Security: SQL comment stripping** — `rails_query` now strips MySQL-style `#` comments in addition to `--` and `/* */`
- **Security: Regex injection** — PerformanceIntrospector now uses `Regexp.escape` on all interpolated model/association names to prevent regex injection
- **Security: SearchDocs error memoization** — transient index load failures (JSON parse errors, missing file) are no longer cached permanently; subsequent calls retry instead of returning stale errors
- **Security: ReadLogs file parameter** — null byte sanitization + `File.basename` enforcement prevents path traversal via directory separators in file names
- **Security: ReadLogs redaction** — added `cookie`, `session_id`, and `_session` patterns to sensitive data redaction
- **Security: SearchDocs fetch size** — 2MB cap on fetched documentation content prevents memory exhaustion from oversized HTTP responses
- **Security: MigrationAdvisor input validation** — table and column names now validated as safe identifiers; special characters rejected with clear error messages
- **Cache: Fingerprinter watched paths** — added `app/components` to WATCHED_DIRS, `package.json` and `tsconfig.json` to WATCHED_FILES; component catalog and frontend stack tools now invalidate on relevant file changes
- **Schema: static parse skipped tables** — `parse_schema_rb` no longer leaves `current_table` pointing at a skipped table (`schema_migrations`, `ar_internal_metadata`), preventing potential nil access on subsequent column lines
- **Query: CSV newline escaping** — CSV format output now properly quotes cell values containing newlines and carriage returns
- **DependencyGraph: Mermaid node IDs** — model names starting with digits now get an `M` prefix to produce valid Mermaid syntax

### Changed
- Test count: 983 → 998

## [4.2.0] — 2026-03-26

### Added
- New `rails_search_docs` tool: bundled topic index with weighted keyword search, on-demand GitHub fetch for Rails documentation
- New `rails_query` tool: safe read-only SQL queries with defense-in-depth (regex pre-filter + SET TRANSACTION READ ONLY + configurable timeout + row limit + column redaction)
- New `rails_read_logs` tool: reverse file tail with level filtering (debug/info/warn/error/fatal) and sensitive data redaction
- New config options: `query_timeout` (default timeout for SQL queries), `query_row_limit` (max rows returned), `query_redacted_columns` (columns to mask in query results), `allow_query_in_production` (safety gate, default false), `log_lines` (default number of log lines to read)

### Changed
- Tool count: 30 → 33
- Test count: 893 → 983

## [4.1.0] — 2026-03-29

### Added
- New `rails_get_frontend_stack` tool: detects React/Vue/Svelte/Angular, Inertia/react-rails mounting, state management, TypeScript config, monorepo layout, package manager
- New `FrontendFrameworkIntrospector`: parses package.json (JSON.parse with BOM-safe reading), config/vite.json, config/shakapacker.yml, tsconfig.json
- Frontend framework detection covers patterns 3 (hybrid SPA), 4 (API+SPA), and 7 (Turbo Native)
- API introspector: OpenAPI/Swagger spec detection, CORS config parsing, API codegen tool detection (openapi-typescript, graphql-codegen, orval)
- Auth introspector: JWT strategy (devise-jwt, Doorkeeper config), HTTP token auth detection
- Turbo introspector: Turbo Native detection (turbo_native_app?, native navigation patterns, native conditionals in views)
- Gem introspector: 6 new notable gems (devise-jwt, rswag-api, rswag-ui, grape-swagger, apipie-rails, hotwire-native-rails)
- Optional config: `frontend_paths`, `mobile_paths` (auto-detected if nil, user override for edge cases)
- Install generator: re-install now updates `ai_tools` and `tool_mode` selections, adds missing config sections without removing existing settings
- Install generator: prompts to remove generated files when AI tools are deselected (per-tool chooser)
- `rails ai:context:cursor` (and other format tasks) now auto-adds the format to `config.ai_tools`
- CLI tool_runner: warns on invalid enum values instead of silent fallback

### Fixed
- `analyze_feature` crash on nil/empty input — now returns helpful prompt
- `analyze_feature` with nonexistent feature — returns clean "no match" instead of scaffolded empty sections
- `migration_advisor` crash on empty/invalid action — now validates with "Did you mean?" suggestions
- `migration_advisor` generates broken SQL with empty table/column — now validates required params
- `migration_advisor` doesn't normalize table names — "Cook" now auto-resolves to "cooks"
- `migration_advisor` no duplicate column/index detection — now warns on existing columns, indexes, and FKs
- `migration_advisor` no nonexistent column detection — now warns on remove/rename/change_type/add_index for missing columns
- `edit_context` "File not found" with no hint — now suggests full path with "Did you mean?"
- `performance_check` model filter fails for multi-word models — "BrandProfile" now resolves to "brand_profiles"
- `performance_check` unknown model silently ignored — now returns "not found" with suggestions
- `turbo_map` stream filter misses dynamic broadcasts — multi-line call handling + snippet fallback + fuzzy prefix matching
- `turbo_map` controller filter misses job broadcasts — now includes broadcasts matching filtered subscriptions' streams
- `security_scan` wrong check name examples — added CHECK_ALIASES mapping (CheckXSS → CheckCrossSiteScripting, sql → CheckSQL, etc.)
- `search_code` unknown match_type silently ignored — now returns error with valid values
- `validate` unknown level silently ignored — now returns error with valid values
- `get_view` no "Did you mean?" on wrong controller — now uses `find_closest_match`
- `get_context` plural model name ("Cooks") produces mixed output — now normalizes via singularize/classify, fails fast when not found
- `component_catalog` specific component returns generic "no components" — now acknowledges the input
- `stimulus` doesn't strip `_controller` suffix — now auto-strips for lookup
- `controller_introspector_spec` rate_limit test crashes on Rails 7.1 — split into source-parsing test (no class loading)

### Changed
- Full preset: 31 → 32 introspectors (added :frontend_frameworks)
- Tool count: 29 → 30
- Test count: 817 → 893
- Install generator always writes `config.ai_tools` and `config.tool_mode` uncommented for re-install detection

## [4.0.0] — 2026-03-26

### Added

- 4 new MCP tools: `rails_get_component_catalog`, `rails_performance_check`, `rails_dependency_graph`, `rails_migration_advisor`
- 3 new introspectors: ComponentIntrospector (ViewComponent/Phlex), AccessibilityIntrospector (ARIA/a11y), PerformanceIntrospector (N+1/indexes)
- ViewComponent/Phlex component catalog: props, slots, previews, sidecar assets, usage examples
- Accessibility scanning: ARIA attributes, semantic HTML, screen reader text, alt text, landmark roles, accessibility score
- Performance analysis: N+1 query risks, missing counter_cache, missing FK indexes, Model.all anti-patterns, eager load candidates
- Dependency graph generation in Mermaid or text format
- Migration code generation with reversibility warnings and affected model detection
- Component and accessibility split rules for Claude, Cursor, Copilot, and OpenCode
- Stimulus cross-controller composition detection
- Stimulus import graph and complexity metrics
- Turbo 8 morph meta and permanent element detection
- Turbo Drive configuration scanning (data-turbo-*, preload)
- Form builder detection (form_with, simple_form, formtastic)
- Semantic HTML element counting
- DaisyUI theme and component detection
- Font loading strategy detection (@font-face, Google Fonts, system fonts)
- CSS @layer and PostCSS plugin detection
- Convention fingerprint with SolidQueue/SolidCache/SolidCable awareness
- Dynamic directory detection in app/
- Controller rate_limit and rescue_from extraction
- Model encryption, normalizes, and generates_token_for details
- Schema check constraints, enum types, and generated columns
- Factory trait extraction and test count by category
- Expanded NOTABLE_GEMS list (30+ new gems including dry-rb, Solid stack)
- Job retry_on/discard_on and perform argument extraction

### Changed

- Standard preset: 13 → 14 introspectors (added :components)
- Full preset: 28 → 31 introspectors (added :components, :accessibility, :performance)
- Tool count: 25 → 29
- Test count: 681 → 806 examples
- Combustion test app expanded with Stimulus controllers, ViewComponents, accessible views, factories

## [3.1.0] - 2026-03-26

### Fixed

- **Consistent input normalization across all tools** — AI agents and humans can now use any casing or format and tools resolve correctly:
  - `model=brand_profile` (snake_case) now resolves to `BrandProfile` via `.underscore` comparison in `get_model_details`.
  - `table=Cook` (model name) now resolves to `cooks` table via `.underscore.pluralize` normalization in `get_schema`.
  - `controller=CooksController` now works in `get_view` and `get_routes` — both strip `Controller`/`_controller` suffix consistently, matching `get_controllers` behavior.
  - `controller=cooks_controller` no longer leaves a trailing underscore in route matching.
  - `stimulus=CookStatus` (PascalCase) now resolves to `cook_status` via `.underscore` conversion in `get_stimulus`.
  - `partial=_status_badge` (underscore-prefixed, no directory) now searches recursively across all view directories in `get_partial_interface`.
  - `model=cooks` (plural) now tries `.singularize` for test file lookup in `get_test_info`.
- **Smarter fuzzy matching** — `BaseTool.find_closest_match` now prefers shortest substring match (so `Cook` suggests `cooks`, not `cook_comments`) and supports underscore/classify variant matching.
- **File path suggestions in validate** — `files=["cook.rb"]` now suggests `app/models/cook.rb` when the file isn't found at the given path.
- **Empty parameter validation** — `edit_context` now returns friendly messages for empty `file` or `near` parameters instead of hard errors.

## [3.0.0] - 2026-03-26

### Removed

- **Windsurf support dropped** — removed `WindsurfSerializer`, `WindsurfRulesSerializer`, `.windsurfrules` generation, and `.windsurf/rules/` split rules. v2.0.5 is the last version with Windsurf support. If you need Windsurf context files, pin `gem "rails-ai-context", "~> 2.0"` in your Gemfile.

### Added

- **CLI tool support** — all 25 MCP tools can now be run from the terminal: `rails 'ai:tool[schema]' table=users detail=full`. Also via Thor CLI: `rails-ai-context tool schema --table users`. `rails ai:tool` lists all tools. `--help` shows per-tool help auto-generated from input_schema. `--json` / `JSON=1` for JSON envelope. Tool name resolution: `schema` → `get_schema` → `rails_get_schema`.
- **`tool_mode` config** — `:mcp` (default, MCP primary + CLI fallback) or `:cli` (CLI only, no MCP server needed). Selected during install and first `rails ai:context` run.
- **ToolRunner** — `lib/rails_ai_context/cli/tool_runner.rb` handles CLI tool execution: arg parsing, type coercion from input_schema, required param validation, enum checking, fuzzy tool name suggestions on typos.
- **ToolGuideHelper** — shared serializer module renders tool reference sections with MCP or CLI syntax based on `tool_mode`, with MANDATORY enforcement + CLI escape hatch. 3-column tool table (MCP | CLI | description).
- **Copilot `excludeAgent`** — MCP tools instruction file uses `excludeAgent: "code-review"` (code review can't invoke MCP tools, saves 4K char budget).
- **`.mcp.json` auto-create** — `rails ai:context` automatically creates `.mcp.json` when `tool_mode` is `:mcp` and the file doesn't exist. Existing apps upgrading to v3.0.0 get it without re-running the install generator.
- **Full config initializer** — generated initializer documents every configuration option organized by section (AI Tools, Introspection, Models & Filtering, MCP Server, File Size Limits, Extensibility, Security, Search).
- **Cursor MDC compliance spec** — 26 tests validating MDC format: frontmatter fields, rule types, glob syntax, line limits.
- **Copilot compliance spec** — 25 tests validating instruction format: applyTo, excludeAgent, file naming, content quality.

### Changed

- Serializer count reduced from 6 to 5 (Claude, Cursor, Copilot, OpenCode, JSON).
- Install generator renumbered (4 AI tool options instead of 5) + MCP opt-in step.
- Cursor glob-based rules no longer combine `globs` + `description` (pure Type 2 auto-attach per Cursor best practices).
- MCP tool instructions use MANDATORY enforcement with CLI escape hatch — AI agents use tools when available, fall back to CLI or file reading when not.
- All CLI examples use zsh-safe quoting: `rails 'ai:tool[X]'` (brackets are glob patterns in zsh).
- README rewritten with real-world workflow examples, categorized tool table, MCP vs CLI showcase.

## [2.0.5] - 2026-03-25

### Changed

- **Task-based MCP tool instructions** — all 6 serializers (Claude, Cursor, Copilot, Windsurf, OpenCode) rewritten from tool-first to task-first: "What are you trying to do?" → exact tool call. 7 task categories: understand a feature, trace a method, add a field, fix a controller, build a view, write tests, find code. Every AI agent now understands which tool to use for any task.
- **Concern detail:"full" bug fix** — `\b` after `?`/`!` prevented 13 of 15 method bodies from being extracted. All methods now show source code.

## [2.0.4] - 2026-03-25

### Added

- **Orphaned table detection** — `get_schema` standard mode flags tables with no ActiveRecord model: "⚠ Orphaned tables: content_calendars, cook_comments"
- **Concern method source code** — `get_concern(name:"X", detail:"full")` shows method bodies inline, same pattern as callbacks tool.
- **analyze_feature: inherited filters** — shows `authenticate_user! (from ApplicationController)` in controller section.
- **analyze_feature: code-ready route helpers** — `cook_path(@record)`, `cooks_path` inline with routes.
- **analyze_feature: service test gaps** — checks services for missing test files, not just models/controllers/jobs.
- **All 6 serializers updated** — Claude, Cursor, Copilot, Windsurf, OpenCode all document trace mode, concern source, orphaned tables, inherited filters.

## [2.0.3] - 2026-03-25

### Added

- **Trace mode 100%** — `match_type:"trace"` now shows 7 sections: definition with class/module context, source code, internal calls, sibling methods (same file), app callers with route chain hints, and test coverage (separated from app code). Zero follow-up calls needed.
- **README rewrite** — neuro marketing techniques: loss aversion hook, measured token savings table, trace output inline, architecture diagram. 456→261 lines.

## [2.0.2] - 2026-03-25

### Added

- **`match_type:"trace"` in search_code** — full method picture in one call: definition + source code + all callers grouped by type (Controller/Model/View/Job/Service/Test) + internal calls. The game changer for code navigation.
- **`match_type:"call"`** — find call sites only, excluding definitions.
- **Smart result limiting** — <10 shows all, 10-100 shows half, >100 caps at 100. Pagination via `offset:` param.
- **`exclude_tests:true`** — skip test/spec/features directories in search results.
- **`group_by_file:true`** — group search results by file with match counts.
- **Inline cross-references** — schema shows model name + association count per table, routes show controller filters inline, views use pipe-separated metadata.
- **Test template generation** — `get_test_info(detail:"standard")` includes a copy-paste test template matching the app's patterns (Minitest/RSpec, Devise sign_in, fixtures).
- **Interactive AI tool selection** — install generator and `rails ai:context` prompt users to select which AI tools they use (Claude, Cursor, Copilot, Windsurf, OpenCode). Selection saved to `config.ai_tools`.
- **Brakeman in validate** — `rails_validate(level:"rails")` now runs Brakeman security checks inline alongside syntax and semantic checks.

### Fixed

- **Documentation audit** — fixed max_tool_response_chars reference (120K→200K), added missing search_code params to GUIDE, added config.ai_tools to config reference.

## [2.0.1] - 2026-03-25

### Fixed

- **MCP-first mandatory workflow in all serializers** — all 6 serializer outputs (Claude, Cursor, Copilot, Windsurf, OpenCode) now use "MANDATORY, Use Before Read" language with structured workflow, anti-patterns table, and "Do NOT Bypass" rules. AI agents are explicitly instructed to never read reference files directly.
- **27 type-safety bugs in serializers** — fixed `.keys` called on Array values (same pattern as #14) across `design_system_helper.rb`, `get_design_system.rb`, `markdown_serializer.rb`, and `stack_overview_helper.rb`.
- **Strong params JSONB check** — no longer skips the entire check when JSONB columns exist. Plain-word params allowed (could be JSON keys), `_id` params still validated.
- **Strong params test skip on Ruby < 3.3** — test now skips gracefully when Prism is unavailable, matching the tool's own degradation.
- **Issue #14** — `multi_db[:databases].keys` crash on Array fixed.
- **Search code NON_CODE_GLOBS** — excludes lock files, docs, CI configs, generated context from all searches.

## [2.0.0] - 2026-03-24

### Added

- **9 new MCP tools (16→25)** — `rails_get_concern` (concern methods + includers), `rails_get_callbacks` (execution order + source), `rails_get_helper_methods` (app + framework helpers + view refs), `rails_get_service_pattern` (interface, deps, side effects), `rails_get_job_pattern` (queue, retries, guards, broadcasts), `rails_get_env` (env vars, credentials keys, external services), `rails_get_partial_interface` (locals contract + usage), `rails_get_turbo_map` (stream/frame wiring + mismatch warnings), `rails_get_context` (composite cross-layer tool).
- **Phase 1 improvements** — scope definitions include lambda body, controller actions show instance variables + private methods called inline, Stimulus shows HTML data-attributes + reverse view lookup.
- **3 new validation rules** — instance variable consistency (view uses @foo but controller never sets it), Turbo Stream channel matching (broadcast without subscriber), respond_to template existence.
- **`rails_security_scan` tool** — Brakeman static security analysis via MCP. Detects SQL injection, XSS, mass assignment, and more. Optional dependency — returns install instructions if Brakeman isn't present. Supports file filtering, confidence levels (high/medium/weak), specific check selection, and three detail levels (summary/standard/full).
- **`config.skip_tools`** — users can now exclude specific built-in tools: `config.skip_tools = %w[rails_security_scan]`. Defaults to empty (all 25 tools active).
- **Schema index hints** — `get_schema` standard detail now shows `[indexed]`/`[unique]` on columns, saving a round-trip to full detail.
- **Enum backing types** — `get_model_details` now shows integer vs string backing: `status: pending(0), active(1) [integer]`.
- **Search context lines default 2** — `search_code` now returns 2 lines of context by default (was 0). Eliminates follow-up calls for context.
- **`match_type` parameter for search** — `search_code` supports `match_type:"definition"` (only `def` lines) and `match_type:"class"` (only `class`/`module` lines).
- **Controller respond_to formats** — `get_controllers` surfaces `respond_to` formats (html, json) already collected by introspector.
- **Config database/auth/assets detection** — `get_config` now shows database adapter, auth framework (Devise/Rodauth/etc), and assets stack (Tailwind/esbuild/etc).
- **Frontend stack detection** — `get_conventions` detects frontend dependencies from package.json (Tailwind, React, TypeScript, Turbo, etc).
- **Validate fix suggestions** — semantic warnings now include actionable fix hints (migration commands, `dependent:` options, index commands).
- **Prism fallback indicator** — `validate` reports when Prism is unavailable so agents know semantic checks may be skipped.
- **Factory attributes/traits** — `get_test_info` full detail parses factory files to show attributes and traits, not just names.
- **Partial render locals** — `get_view` standard detail shows what locals each partial receives based on render call scanning.
- **Edit context header** — `get_edit_context` shows enclosing class/method name in response header.
- **Gem config location hints** — `get_gems` shows config file paths for 17 common gems (Devise, Sidekiq, Pundit, etc).
- **Stimulus lifecycle detection** — `get_stimulus` detects connect/disconnect/initialize lifecycle methods.
- **Route params inline** — `get_routes` standard detail shows required params: `[id]`, `[user_id, id]`.
- **Feature test coverage gaps** — `analyze_feature` reports which models/controllers/jobs lack test files.
- **Model macros surfaced** — `get_model_details` now shows `has_secure_password`, `encrypts`, `normalizes`, `generates_token_for`, `serialize`, `store`, `broadcasts`, attachments — all previously collected but hidden.
- **Model delegations and constants** — `get_model_details` shows `delegate :x, to: :y` and constants like `STATUSES = %w[pending completed]`.
- **Association FK column hints** — `get_model_details` shows `(fk: user_id)` on belongs_to associations.
- **Schema model references** — `get_schema` full detail shows which ActiveRecord models reference each table.
- **Schema column comments** — `get_schema` full detail shows database column comments when present.
- **Action Cable adapter detection** — `get_config` detects Action Cable adapter from cable.yml.
- **Gem version display** — `get_gems` shows version numbers from Gemfile.lock.
- **Package manager detection** — `get_conventions` detects npm/yarn/pnpm/bun from lock files.
- **Exact match search** — `search_code` supports `exact_match:true` for whole-word matching with `\b` boundaries.
- **Scaled defaults for big apps** — increased `max_tool_response_chars` (120K→200K), `max_search_results` (100→200), `max_validate_files` (20→50), `cache_ttl` (30→60s), `max_file_size` (2MB→5MB), `max_test_file_size` (500KB→1MB), `max_view_total_size` (5MB→10MB), `max_view_file_size` (500KB→1MB). Schema standard pagination 15→25, full 5→10. Methods shown per model 15→25. Routes standard 100→150.
- **AI-optimal tool ordering** — schema standard sorts tables by column count (complex first), model listing sorts by association count (central models first). Stops AI from missing important tables/models buried alphabetically.
- **Cross-reference navigation hints** — schema single-table suggests `rails_get_model_details`, model detail suggests `rails_get_controllers` + `rails_get_schema` + `rails_analyze_feature`, controller detail suggests `rails_get_routes` + `rails_get_view`. Reduces AI round-trips.
- **Schema adapter in summary** — `get_schema` summary shows database adapter (postgresql/mysql/sqlite3) so AI knows query syntax immediately.
- **App size detection** — `BaseTool.app_size` returns `:small`/`:medium`/`:large` based on model/table count for auto-tuning.
- **Doctor checks for Prism and Brakeman** — `rails ai:doctor` now reports availability of Prism parser and Brakeman security scanner.

### Fixed

- **JS fallback validator false-positives** — escaped backslashes before string-closing quotes (`"path\\"`) no longer cause false bracket mismatch errors. Replaced `prev_char` check with proper `escaped` toggle flag.

## [1.3.1] - 2026-03-23

### Fixed

- **Documentation audit** — updated tool count from 14 to 15 across README, GUIDE, CONTRIBUTING, server.json. Added `rails_get_design_system` documentation section to GUIDE.md. Updated SECURITY.md supported versions. Fixed spec count in CLAUDE.md. Added `rails_get_design_system` to README tool table. Updated `rails_analyze_feature` description to reflect full-stack discovery (services, jobs, views, Stimulus, tests, related models, env deps).
- **analyze_feature crash on complex models** — added type guards (`is_a?(Hash)`, `is_a?(Array)`) to all data access points preventing `no implicit conversion of Symbol into Integer` errors on models with many associations or complex data.

## [1.3.0] - 2026-03-23

### Added

- **Full-stack `analyze_feature` tool** — now discovers services (AF1), jobs with queue/retry config (AF2), views with partial/Stimulus refs (AF3), Stimulus controllers with targets/values/actions (AF4), test files with counts (AF5), related models via associations (AF6), concern tracing (AF12), callback chains (AF13), channels (AF10), mailers (AF11), and environment variable dependencies (AF9). One call returns the complete feature picture.
- **Modal pattern extraction** (DS1) — detects overlay (`fixed inset-0 bg-black/50`) and modal card patterns
- **List item pattern extraction** (DS5) — detects repeating card/item patterns from views
- **Shared partials with descriptions** (DS7) — scans `app/views/shared/` and infers purpose (flash, navbar, status badge, loading, modal, etc.)
- **"When to use what" decision guide** (DS8) — explicit rules: primary button for CTAs, danger for destructive, when to use shared partials
- **Bootstrap component extraction** (DS13-DS15) — detects `btn-primary`, `card`, `modal`, `form-control`, `badge`, `alert`, `nav` patterns from Bootstrap apps
- **Tailwind `@apply` directive parsing** (DS16) — extracts named component classes from CSS `@apply` rules
- **DaisyUI/Flowbite/Headless UI detection** (DS17) — reports Tailwind plugin libraries from package.json
- **Animation/transition inventory** (DS19) — extracts `transition-*`, `duration-*`, `animate-*`, `ease-*` patterns
- **Smarter JSONB strong params check** (V1) — only skips params matching JSON column names, validates the rest
- **Route-action fix suggestions** (V2) — suggests "add `def action; end`" when route exists but action is missing

### Fixed

- **`self` filtered from class methods** (B2/MD1) — no longer appears in model class method lists
- **Rules serializer methods cap raised to 20** (RS1) — uses introspector's pre-filtered methods directly instead of redundant re-filtering
- **oklch token noise filtered** (DS21) — complex color values (oklch, calc, var) hidden from summary, only shown in `detail:"full"`

## [1.2.1] - 2026-03-23

### Fixed

- **New models now discovered via filesystem fallback** — when `ActiveRecord::Base.descendants` misses a newly created model, the introspector scans `app/models/*.rb` and constantizes them. Fixes model invisibility until MCP restart.
- **Devise meta-methods no longer fill class/instance method caps** — filtered 40+ Devise-generated methods (authentication_keys=, email_regexp=, password_required?, etc.). Source-defined methods now prioritized over reflection-discovered ones.
- **Controller `unless:`/`if:` conditions now extracted** — filters like `before_action :authenticate_user!, unless: :devise_controller?` now show the condition. Previously silently dropped.
- **Empty string defaults shown as `""`** — schema tool now renders `""` instead of a blank cell for empty string defaults. AI can distinguish "no default" from "empty string default".
- **Implicit belongs_to validations labeled** — `presence on user` from `belongs_to :user` now shows `_(implicit from belongs_to)_` and filters phantom `(message: required)` options.
- **Array columns shown as `type[]`** in generated rules — `string` columns with `array: true` now render as `string[]` in schema rules.
- **External ID columns no longer hidden** — columns like `paymongo_checkout_id` and `stripe_payment_id` are now shown in schema rules. Only conventional Rails FK columns (matching a table name) are filtered.
- **Column defaults shown in generated rules** — columns with non-nil defaults now show `(=value)` inline.
- **`analyze_feature` matches models by table name and underscore form** — `feature:"share"` now finds `CookShare` (via `cook_shares` table and `cook_share` underscore form), not just exact model name substring.

## [1.2.0] - 2026-03-23

### Added

- **Design system extraction** — ViewTemplateIntrospector now extracts canonical page examples (real HTML/ERB snippets from actual views), full color palette with semantic roles (primary/danger/success/warning), typography scale (sizes, weights, heading styles), layout patterns (containers, grids, spacing scale), responsive breakpoint usage, interactive state patterns (hover/focus/active/disabled), dark mode detection, and icon system identification.
- **New MCP tool: `rails_get_design_system`** — dedicated tool (15th) returns the app's design system: color palette, component patterns with real HTML examples, typography, layout conventions, responsive breakpoints. Supports `detail` parameter (summary/standard/full). Total MCP tools: 15.
- **DesignSystemHelper serializer module** — replaces flat component listings with actionable design guidance across all output formats (Claude, Cursor, Windsurf, Copilot, OpenCode). Shows components with semantic roles, canonical page examples in split rules, and explicit design rules.
- **DesignTokenIntrospector semantic categorization** — tokens now grouped into colors/typography/spacing/sizing/borders/shadows. Enhanced Tailwind v3 parsing for fontSize, spacing, borderRadius, and screens.

### Changed

- **"UI Patterns" section renamed to "Design System"** — richer content with color palette, typography, components, spacing conventions, interactive states, and design rules.
- **Design tokens consumed for the first time** — `context[:design_tokens]` data was previously extracted but never rendered. Now merged into design system output in all serializers and the new MCP tool.

## [1.1.1] - 2026-03-23

### Added

- **Full-preset stack overview in all serializers** — compact mode now surfaces summary lines for auth, Hotwire/Turbo, API, I18n, ActiveStorage, ActionText, assets, engines, and multi-database in generated context files (CLAUDE.md, AGENTS.md, .windsurfrules, and all split rules). Previously this data was only available via MCP tools.
- **`rails_analyze_feature` in all tool reference sections** — the 14th tool (added in v1.0.0) was missing from serializer output. Now listed in all generated files across Claude, Cursor, Windsurf, Copilot, and OpenCode formats.

### Fixed

- **Tool count corrected from 13 to 14** across all serializers to reflect `rails_analyze_feature` added in v1.0.0.

## [1.1.0] - 2026-03-23

### Changed

- **Default preset changed to `:full`** — all 28 introspectors now run by default, giving AI assistants richer context out of the box. Introspectors that don't find relevant data return empty hashes with zero overhead. Use `config.preset = :standard` for the previous 13-core default.

## [1.0.0] - 2026-03-23

### Added

- **New composite tool: `rails_analyze_feature`** — one call returns schema + models + controllers + routes for a feature area (e.g., `rails_analyze_feature(feature:"authentication")`). Total MCP tools: 14.
- **Custom tool registration API** — `config.custom_tools << MyCompany::PolicyCheckTool` lets teams extend the MCP server with their own tools.
- **Structured error responses with fuzzy suggestions** — `not_found_response` helper in BaseTool with "Did you mean?" fuzzy matching (substring + prefix) and `recovery_action` hints. Applied to schema, models, controllers, and stimulus lookups. AI agents self-correct on first retry.
- **Cache keys on paginated responses** — every paginated response includes `cache_key` from fingerprint so agents detect stale data between page fetches. Applied to schema, models, controllers, and stimulus pagination.

### Changed

- **LLM-optimized tool descriptions (all 14 tools)** — every description now follows "what it does / Use when: / key params" format so AI agents pick the right tool on first try.

## [0.15.10] - 2026-03-23

### Changed

- **Gemspec description rewritten** — repositioned from feature list to value proposition: mental model, semantic validation, cross-file error detection.

## [0.15.9] - 2026-03-23

### Added

- **Deep diagnostic checks in `rails ai:doctor`** — upgraded from 13 shallow file-existence checks to 20 deep checks: pending migrations, context file freshness, .mcp.json validation, introspector health (dry-runs each one), preset coverage (detects features not in preset), .env/.master.key gitignore check, auto_mount production warning, schema/view size vs limits.

## [0.15.8] - 2026-03-23

### Added

- **Semantic validation (`level:"rails"`)** — `rails_validate` now supports `level:"rails"` for deep semantic checks beyond syntax: partial existence, route helper validity, column references vs schema, strong params vs schema columns, callback method existence, route-action consistency, `has_many` dependent options, missing FK indexes, and Stimulus controller file existence.

## [0.15.7] - 2026-03-22

### Improved

- **Hybrid filter extraction** — controller filters now use reflection for complete names (handles inheritance + skips), with source parsing from the inheritance chain for only/except constraints.
- **Callback source fallback** — when reflection returns nothing (e.g. CI), falls back to parsing callback declarations from model source files.
- **ERB validation accuracy** — in-process compilation with `<%=` → `<%` pre-processing and yield wrapper eliminates false positives from block-form helpers.
- **Schema static parser** — now extracts `null: false`, `default:`, `array: true` from schema.rb columns, and parses `add_foreign_key` declarations.
- **Array column display** — schema tool shows PostgreSQL array types as `string[]`, `integer[]`, etc.
- **Concern test lookup** — `rails_get_test_info(model:"PlanLimitable")` searches concern test paths.
- **Controller flexible matching** — underscore-based normalization handles CamelCase, snake_case, and slash notation consistently.

## [0.15.6] - 2026-03-22

### Added

- **7 new configurable options** — `excluded_controllers`, `excluded_route_prefixes`, `excluded_concerns`, `excluded_filters`, `excluded_middleware`, `search_extensions`, `concern_paths` for stack-specific customization.
- **Configurable file size limits** — `max_file_size`, `max_test_file_size`, `max_schema_file_size`, `max_view_total_size`, `max_view_file_size`, `max_search_results`, `max_validate_files` all exposed via `Configuration`.
- **Class methods in model detail** — `rails_get_model_details` now shows class methods section.
- **Custom validate methods** — `validate :method_name` calls extracted from source and shown in model detail.

### Fixed

- **Schema defaults always visible** — Null and Default columns always shown (NOT NULL marked bold). Previous token-saving logic accidentally hid critical migration data.
- **Optional associations** — `belongs_to` with `optional: true` now shows `[optional]` flag.
- **Concern methods inline** — shows public methods from concern source files (e.g. `PlanLimitable — can_cook?, increment_cook_count!`).
- **MCP tool error messages** — all tools now show available values on error/not-found for AI self-correction.

## [0.15.5] - 2026-03-22

### Fixed

- **ERB validation** — now catches missing `<% end %>` by compiling ERB to Ruby then syntax-checking the result (was only checking ERB tag syntax).
- **Controller namespace format** — accepts both `Bonus::CrisesController` and `bonus/crises` (cross-tool consistency).
- **Layouts discoverable** — `controller:"layouts"` now works in view tool.
- **Validate error detail** — Ruby shows up to 5 error lines, JS shows 3 (was truncated to 1).
- **Invalid/empty regex** — early validation with clear error messages instead of silent fail.
- **Route count accuracy** — shows filtered count when `app_only:true`, not unfiltered total.
- **Namespace test lookup** — supports `bonus/crises` format and flat test directories.
- **Empty inputs** — `near:""` in edit_context and `pattern:""` in search return helpful errors.

## [0.15.4] - 2026-03-22

### Fixed

- **View subfolder paths** — listings now show full relative paths (`bonus/brand_profiles/index.html.erb`) instead of just basenames.
- **Controller flexible matching** — `"cooks"`, `"CooksController"`, `"cookscontroller"` all resolve (matches other tools' forgiving lookup).
- **View path traversal** — explicit `..` and absolute path rejection before any filesystem operation.
- **Schema case-insensitive** — table lookup now case-insensitive (matches models/routes/etc.).
- **limit:0 silent empty** — uses default instead of returning empty results.
- **offset past end** — shows "Use `offset:0` to start over" instead of empty response.
- **Search ordering** — deterministic results via `--sort=path` on ripgrep.
- **Generated context prepended** — `<!-- BEGIN rails-ai-context -->` section now placed at top of existing files (AI reads top-to-bottom, may truncate at token limits).

### Added

- **Pagination on models, controllers, stimulus** — `limit`/`offset` params (default 50) with "end of results" hints. Prevents token bombs on large apps.

## [0.15.3] - 2026-03-22

### Fixed

- **Schema `add_index` column parsing** — option keys (e.g. `unique`, `name`) were being picked up as column names (PR #12).
- **Windsurf test command** — extracted `TestCommandDetection` shared module; Windsurf now shows specific test command instead of generic "Run tests after changes".

### Changed

- **Documentation** — updated all docs (README, CLAUDE.md, GUIDE.md, SECURITY.md, CHANGELOG, server.json, install generator) to match v0.15.x codebase. Fixed spec counts, file counts, preset counts, config options, and supported versions.

## [0.15.2] - 2026-03-22

### Fixed

- **Test command detection** — Serializers now use detected test framework (minitest → `rails test`, rspec → `bundle exec rspec`) instead of hardcoding `bundle exec rspec`. Default is `rails test` (the Rails default). Contributed by @curi (PR #13).

## [0.15.1] - 2026-03-22

### Fixed

- **Copilot serializer** — Show all model associations (not capped at 3), use human-readable architecture/pattern labels.
- **OpenCode rules serializer** — Filter framework controllers (Devise) from AGENTS.md output, show all associations, match `before_action` with `!`/`?` suffixes.

## [0.15.0] - 2026-03-22

### Security

- **Sensitive file blocking** — `search_code` and `get_edit_context` now block access to `.env*`, `*.key`, `*.pem`, `config/master.key`, `config/credentials.yml.enc`. Configurable via `config.sensitive_patterns`.
- **Credentials key names redacted** — Replaced `credentials_keys` (exposed names like `stripe_secret_key`) with `credentials_configured` boolean. No more information disclosure via JSON output or MCP resources.
- **View content size cap** — `collect_all_view_content` capped at 5MB total / 500KB per file to prevent memory exhaustion.
- **Schema file size limits** — 10MB limit on `schema.rb`/`structure.sql` parsing. Cached `schema.rb` reads to avoid re-reading per table.

### Added

- **Token optimization (~1,500-2,700 tokens/session saved)**:
  - Filter framework filters (`verify_authenticity_token`, etc.) from controller output
  - Filter framework/gem concerns (`Devise::*`, `Turbo::*`, `*::Generated*`) from models
  - Combine duplicate PUT/PATCH routes into single `PATCH|PUT` entry
  - Only show Nullable/Default columns when they have meaningful values
  - Drop gem version numbers from default output
  - Single HTML naming hint for Stimulus (not per-controller)
  - Only show non-default middleware and initializers in config
  - Group sibling controllers/routes with identical structure
  - Compress repeated Tailwind classes in view full output
  - Strip inline SVGs from view content
  - Separate active vs lifecycle-only Stimulus controllers

### Fixed

- **Controller staleness** — Source-file parsing for actions/filters instead of Ruby reflection. Filesystem discovery for new controllers not yet loaded as classes.
- **Schema `t.index` format** — Parse indexes inside `create_table` blocks (not just `add_index` outside).
- **Stimulus nested values** — Brace-depth counting for single-line `{ active: { type: String, default: "overview" } }`.
- **Stimulus phantom `type:Number`** — Exclude `type`/`default` as value names (JS keywords, not Stimulus values).
- **Search context_lines** — Use `--field-context-separator=:` for ripgrep `-C` output compatibility.
- **Schema defaults** — Supplement live DB nil defaults with values from `schema.rb`.
- **Config missing data** — Added `queue_adapter` and `mailer` settings to config introspector and tool.
- **View garbled fields** — Only extract from `@variable.field` patterns (not arbitrary method chains).
- **View shared partials** — `controller:"shared"` now finds partials in `app/views/shared/`.
- **View full detail** — Lists available controllers when no controller specified.
- **Edit context hint** — "Also found" only shown for matches outside the context window.
- **Model file structure** — Compressed to single-line format.
- **Strong params body** — Action detail now shows the actual `permit(...)` call.
- **AR-generated methods** — Filter `build_*`, `*_ids=`, etc. from model instance methods.

## [0.14.0] - 2026-03-20

### Fixed

- **Schema 0 indexes** — Fixed composite index parsing in schema.rb (regex didn't match array syntax) and structure.sql (`.first` only took first column). Both single and composite indexes now extracted correctly.
- **Stale routes after editing routes.rb** — Route introspector now calls `routes_reloader.execute_if_updated` to force Rails to reload routes before extraction.
- **Config "not available"** — Added `:config` to `:standard` preset. Was `:full` only, so default users never saw config data.
- **Stimulus values lost name** — Fixed parsing for both simple (`name: Type`) and complex (`name: { type: Type, default: val }`) formats. Now shows `max: Number (default: 3)`.
- **Model concerns noise** — Filtered out internal Rails modules (ActiveRecord::, ActiveModel::, Kernel, JSON::, etc.) from concerns list.

### Added

- **Route helpers in standard detail** — `rails_get_routes(detail: "standard")` now includes route helper names alongside paths.
- **`app_only` filter for routes** — `rails_get_routes(app_only: true)` (default) hides internal Rails routes (Active Storage, Action Mailbox, Conductor).
- **Search context lines** — `rails_search_code(context_lines: 2)` adds surrounding lines to matches (passes `-C` to ripgrep).
- **Stimulus dash/underscore normalization** — Both `weekly-chart` and `weekly_chart` work for controller lookup. Output shows HTML `data-controller` attribute.
- **Model public method signatures** — `rails_get_model_details(model: "Cook")` shows method names with params from source, stopping at private boundary.

## [0.13.1] - 2026-03-20

### Changed

- **View summary** — now shows partials used by each view.
- **Model details** — shows method signatures (name + parameters) instead of just method names.
- Removed unused demo files; fixed GUIDE.md preset tables.

## [0.13.0] - 2026-03-20

### Added

- **`rails_validate` MCP tool** — batch syntax validation for Ruby, ERB, and JavaScript files. Replaces separate `ruby -c`, ERB check, and `node -c` calls. Returns pass/fail for each file with error details. Uses `Open3.capture2e` (no shell execution). Falls back to brace-matching when Node.js is unavailable.
- **Model constants extraction** — introspects `STATUSES = %w[...]` style constants and includes them in model context.
- **Global before_actions in controller rules** — OpenCode AGENTS.md now shows ApplicationController before_actions.
- **Service objects and jobs listed** — OpenCode controller AGENTS.md now lists service objects and background jobs.
- **Validate spec** — 8 tests covering happy path, syntax errors, path traversal, MAX_FILES, unsupported types.

### Security

- **Validate tool uses Open3 array form** — no shell execution for `ruby -c`, ERB compilation, or `node -c`. Fixed critical shell quoting bug in ERB validation that caused it to always fail.
- **File size limit** on JavaScript fallback validation (2MB).
- **`which node` check uses array form** — `system("which", "node")` instead of shell string.

### Fixed

- ERB validation was broken due to shell quoting bug (backticks + nested quotes). Replaced with `Open3.capture2e("ruby", "-e", script, ARGV[0])`.
- Rubocop offenses in validate.rb (18 spacing issues auto-corrected).

## [0.12.0] - 2026-03-20

### Added

- **Design Token Introspector** — auto-detects CSS framework and extracts tokens from Tailwind v3/v4, Bootstrap/Sass, plain CSS custom properties, Webpacker-era stylesheets, and ViewComponent sidecar CSS. Tested across 8 CSS setups. Added to standard preset.
- **`rails_get_edit_context` MCP tool** — purpose-built for surgical edits. Returns code around a match point with line numbers. Replaces the Read + Edit workflow with a single call.
- **Line numbers in action source** — `rails_get_controllers(action: "index")` now returns start/end line numbers for targeted editing.
- **Model file structure** — `rails_get_model_details(model: "Cook")` now returns line ranges for each section (associations, validations, scopes, etc.).

### Changed

- **MCP instructions updated** — "Use MCP for reference files (schema, routes, tests). Read directly if you'll edit." Prevents unnecessary double-reads.
- **UI pattern extractor rewritten** — semantic labels (primary/secondary/danger), deduplication, 12+ component types, color scheme + radius + form layout extraction, framework-agnostic.
- **Schema rules include column types** — `status:string, intake:jsonb` instead of just names. Also shows foreign keys, indexes, and enum values.
- **View standard detail enhanced** — shows partial fields, helper methods, and shared partials.

### Security

- **File.realpath symlink protection** on all file-reading tools (get_view, get_edit_context, get_test_info, search_code).
- **File size limits** — 2MB on controllers/models/views, 500KB on test files.
- **Ripgrep flag injection prevention** — `--` separator before user pattern.
- **Nil guards** on all component rendering across 10 serializers.
- **Non-greedy regex** — ReDoS prevention in card/input/label pattern matching.
- **UTF-8 encoding safety** — all File.read calls handle binary/non-UTF-8 files gracefully.

### Fixed

- Off-by-one in model structure section line ranges.
- Stimulus sort crash on nil controller name.
- Secondary button picking up disabled states (`cursor-not-allowed`).
- Progress bars misclassified as badges.
- Input detection picking up alert divs instead of actual inputs.

## [0.11.0] - 2026-03-20

### Added

- **UI pattern extraction** — scans all views for repeated CSS class patterns. Detects buttons, cards, inputs, labels, badges, links, headings, flashes, alerts. Added to ALL serializers (root files + split rules for Claude, Cursor, Windsurf, Copilot, OpenCode).
- **View partial structure** — `rails_get_view(detail: "standard")` shows model fields and helper methods used by each partial.
- **Schema column names** — `.claude/rules/rails-schema.md` shows key column names with types, foreign keys, indexes, and enum values. Keeps polymorphic `_type`, STI `type`, and soft-delete `deleted_at` columns.

## [0.10.2] - 2026-03-20

### Security

- **ReDoS protection** — added regex timeout and converted greedy quantifiers to non-greedy across all pattern matching.
- **File size limits** — added size caps on parsed files to prevent memory exhaustion from oversized inputs.

## [0.10.1] - 2026-03-19

### Changed

- Patch release for RubyGems republish (no code changes).

## [0.10.0] - 2026-03-19

### Added

- **`rails_get_view` MCP tool** — get view template contents, partials, Stimulus references. Filter by controller or specific path. Supports summary/standard/full detail levels. Eliminates reading 490+ lines of view files per task. ([#7](https://github.com/crisnahine/rails-ai-context/issues/7))
- **`rails_get_stimulus` MCP tool** — get Stimulus controller details (targets, values, actions, outlets, classes). Filter by controller name. Wraps existing StimulusIntrospector. ([#8](https://github.com/crisnahine/rails-ai-context/issues/8))
- **`rails_get_controllers` `action` parameter** — returns actual action source code + applicable filters instead of the entire controller file. Saves ~1,400 tokens per call. ([#9](https://github.com/crisnahine/rails-ai-context/issues/9))
- **`rails_get_test_info` enhanced** — now supports `detail` levels (summary/standard/full), `model` and `controller` params to find existing tests, fixture/factory names, test helper setup. ([#10](https://github.com/crisnahine/rails-ai-context/issues/10))
- **ViewTemplateIntrospector** — new introspector that reads view file contents and extracts partial references and Stimulus data attributes.
- **Stimulus and view_templates in standard preset** — both introspectors now in `:standard` preset (11 introspectors, was 10).

## [0.9.0] - 2026-03-19

### Added

- **`config.generate_root_files` option** — when set to `false`, skips generating root-level context files (CLAUDE.md, AGENTS.md, .windsurfrules, copilot-instructions.md, .ai-context.json) while still generating all split rules (.claude/rules/, .cursor/rules/, .windsurf/rules/, .github/instructions/). Defaults to `true`.
- **Section markers on root files** — generated content in CLAUDE.md, AGENTS.md, .windsurfrules, and copilot-instructions.md is now wrapped in `<!-- BEGIN rails-ai-context -->` / `<!-- END rails-ai-context -->` markers. User content outside the markers is preserved on re-generation. Existing files without markers get the marked section appended.
- **App overview split rules** — new `rails-context.md` in `.claude/rules/` and `rails-context.instructions.md` in `.github/instructions/` provide a compact app overview (stack, models, routes, gems, architecture) so context is available even when root files are disabled.

### Changed

- **Removed `.cursorrules` root file** — Cursor officially deprecated `.cursorrules` in favor of `.cursor/rules/`. The `:cursor` format now generates only `.cursor/rules/*.mdc` split rules. The `rails-project.mdc` split rule (with `alwaysApply: true`) already provides the project overview.
- **License changed from AGPL-3.0 to MIT** — removes the copyleft blocker for SaaS and commercial projects.

## [0.8.5] - 2026-03-19

### Fixed

- **Thread-safe shared tool cache** — `BaseTool.cached_context` now uses a Mutex-protected shared cache across all 9 tool subclasses. Previously, each subclass cached independently (up to 9 redundant introspections after invalidation) and had no synchronization for multi-threaded servers like Puma. ([#2](https://github.com/crisnahine/rails-ai-context/issues/2))
- **SearchCode ripgrep total result cap** — `rg --max-count N` limits matches per file, not total. A search with `max_results: 5` against a large codebase could return hundreds of results. Now capped with `.first(max_results)` after parsing, matching the Ruby fallback behavior. ([#3](https://github.com/crisnahine/rails-ai-context/issues/3))
- **JobIntrospector Proc queue fallback** — when a Proc-based `queue_name` raises during introspection, the queue now falls back to `"default"` instead of producing garbage like `"#<Proc:0x00007f...>"`. ([#4](https://github.com/crisnahine/rails-ai-context/issues/4))
- **CLI `version` command crash** — `rails-ai-context version` crashed with `LoadError` due to wrong `require_relative` path (`../rails_ai_context/version` instead of `../lib/rails_ai_context/version`). ([#5](https://github.com/crisnahine/rails-ai-context/issues/5))

### Documentation

- **Standalone CLI documented** — the `rails-ai-context` executable (serve, context, inspect, watch, doctor, version) is now documented in README, GUIDE, and CLAUDE.md.

## [0.8.4] - 2026-03-19

### Added

- **`structure.sql` support** — the schema introspector now parses `db/structure.sql` when no `db/schema.rb` exists and no database connection is available. Extracts tables, columns (with SQL type normalization), indexes, and foreign keys from PostgreSQL dump format. Prefers `schema.rb` when both exist.
- **Fingerprinter watches `db/structure.sql`** — file changes to `structure.sql` now trigger cache invalidation and live reload.

## [0.8.3] - 2026-03-19

### Changed

- **License published to RubyGems** — v0.8.2 changed the license from MIT to AGPL-3.0 but the gem was not republished. This release ensures the AGPL-3.0 license is reflected on RubyGems.

## [0.8.2] - 2026-03-19

### Changed

- **License** — changed from MIT to AGPL-3.0 to protect against unauthorized clones and ensure derivative works remain open source.
- **CI: auto-publish to MCP Registry** — the release workflow now automatically publishes to the MCP Registry via `mcp-publisher` with GitHub OIDC auth. No manual `mcp-publisher login` + `publish` needed.

## [0.8.1] - 2026-03-19

### Added

- **OpenCode support** — generates `AGENTS.md` (native OpenCode context file) plus per-directory `app/models/AGENTS.md` and `app/controllers/AGENTS.md` that OpenCode auto-loads when reading files in those directories. Falls back to `CLAUDE.md` when no `AGENTS.md` exists. New command: `rails ai:context:opencode`.

### Fixed

- **Live reload LoadError in HTTP mode** — when `live_reload = true` and the `listen` gem was missing, the `start_http` method's rescue block (for rackup fallback) swallowed the live reload error, producing a confusing rack error instead of the correct "listen gem required" message. The rescue is now scoped to the rackup require only.
- **Dangling @live_reload reference** — `@live_reload` was assigned before `start` was called. If `start` raised LoadError, the instance variable pointed to a non-functional object. Now only assigned after successful start.

## [0.8.0] - 2026-03-19

### Added

- **MCP Live Reload** — when running `rails ai:serve`, file changes automatically invalidate tool caches and send MCP notifications (`notifications/resources/list_changed`) to connected AI clients. The AI's context stays fresh without manual re-querying. Requires the `listen` gem (enabled by default when available). Configurable via `config.live_reload` (`:auto`, `true`, `false`) and `config.live_reload_debounce` (default: 1.5s).
- **Live reload doctor check** — `rails ai:doctor` now warns when the `listen` gem is not installed.

## [0.7.1] - 2026-03-19

### Added

- **Full MCP tool reference in all context files** — every generated file (CLAUDE.md, .cursorrules, .windsurfrules, copilot-instructions.md) now includes complete tool documentation with parameters, detail levels, pagination examples, and usage workflow. Dedicated `rails-mcp-tools` split rule files added for Claude, Cursor, Windsurf, and Copilot.
- **MCP Registry listing** — published to the [official MCP Registry](https://registry.modelcontextprotocol.io) as `io.github.crisnahine/rails-ai-context` via mcpb package type.

### Fixed

- **Schema version parsing** — versions with underscores (e.g. `2024_01_15_123456`) were truncated to the first digit group. Now captures the full version string.
- **Documentation** — updated README (detail levels, pagination, generated file tree, config options), SECURITY.md (supported versions), CONTRIBUTING.md (project structure), gemspec (post-install message), demo_script.sh (all 17 generated files).

## [0.7.0] - 2026-03-19

### Added

- **Detail levels on MCP tools** — `detail:"summary"`, `detail:"standard"` (default), `detail:"full"` on `rails_get_schema`, `rails_get_routes`, `rails_get_model_details`, `rails_get_controllers`. AI calls summary first, then drills down. Based on Anthropic's recommended MCP pattern.
- **Pagination** — `limit` and `offset` parameters on schema and routes tools for apps with hundreds of tables/routes.
- **Response size safety net** — Configurable hard cap (`max_tool_response_chars`, default 120K) on tool responses. Truncated responses include hints to use filters.
- **Compact CLAUDE.md** — New `:compact` context mode (default) generates ≤150 lines per Claude Code's official recommendation. Contains stack overview, key models, and MCP tool usage guide.
- **Full mode preserved** — `config.context_mode = :full` retains the existing full-dump behavior. Also available via `rails ai:context:full` or `CONTEXT_MODE=full`.
- **`.claude/rules/` generation** — Generates quick-reference files in `.claude/rules/` for schema and models. Auto-loaded by Claude Code alongside CLAUDE.md.
- **Cursor MDC rules** — Generates `.cursor/rules/*.mdc` files with YAML frontmatter (globs, alwaysApply). Project overview is always-on; model/controller rules auto-attach when working in matching directories. Legacy `.cursorrules` kept for backward compatibility.
- **Windsurf 6K compliance** — `.windsurfrules` is now hard-capped at 5,800 characters (within Windsurf's 6,000 char limit). Generates `.windsurf/rules/*.md` for the new rules format.
- **Copilot path-specific instructions** — Generates `.github/instructions/*.instructions.md` with `applyTo` frontmatter for model and controller contexts. Main `copilot-instructions.md` respects compact mode (≤500 lines).
- **`rails ai:context:full` task** — Dedicated rake task for full context dump.
- **Configurable limits** — `claude_max_lines` (default: 150), `max_tool_response_chars` (default: 120K).

### Changed

- Default `context_mode` is now `:compact` (was implicitly `:full`). Existing behavior available via `config.context_mode = :full`.
- Tools default to `detail:"standard"` which returns bounded results, not unlimited.
- All tools return pagination hints when results are truncated.
- `.windsurfrules` now uses dedicated `WindsurfSerializer` instead of sharing `RulesSerializer` with Cursor.

## [0.6.0] - 2026-03-18

### Added

- **Migrations introspector** — Discovers migration files, pending migrations, recent history, schema version, and migration statistics. Works without DB connection.
- **Seeds introspector** — Analyzes db/seeds.rb structure, discovers seed files in db/seeds/, detects which models are seeded, and identifies patterns (Faker, environment conditionals, find_or_create_by).
- **Middleware introspector** — Discovers custom Rack middleware in app/middleware/, detects patterns (auth, rate limiting, tenant isolation, logging), and categorizes the full middleware stack.
- **Engine introspector** — Discovers mounted Rails engines from routes.rb with paths and descriptions for 23+ known engines (Sidekiq::Web, Flipper::UI, PgHero, ActiveAdmin, etc.).
- **Multi-database introspector** — Discovers multiple databases, replicas, sharding config, and model-specific `connects_to` declarations. Works with database.yml parsing fallback.
- **2 new MCP resources** — `rails://migrations`, `rails://engines`
- **Migrations added to :standard preset** — AI tools now see migration context by default
- **Doctor check** — New `check_migrations` diagnostic
- **Fingerprinter** — Now watches `db/migrate/`, `app/middleware/`, and `config/database.yml`

### Changed

- Default `:standard` preset expanded from 8 to 9 introspectors (added `:migrations`)
- Default `:full` preset expanded from 21 to 26 introspectors
- Doctor checks expanded from 11 to 12
- Static MCP resources expanded from 7 to 9

## [0.5.2] - 2026-03-18

### Fixed

- **MCP tool nil crash** — All 9 MCP tools now handle missing introspector data gracefully instead of crashing with `NoMethodError` when the introspector is not in the active preset (e.g. `rails_get_config` with `:standard` preset)
- **Zeitwerk dependency** — Changed from open-ended `>= 2.6` to pessimistic `~> 2.6` per RubyGems best practices
- **Documentation** — Updated CONTRIBUTING.md, CHANGELOG.md, and CLAUDE.md to reflect Zeitwerk autoloading, introspector presets, and `.mcp.json` auto-discovery changes

## [0.5.1] - 2026-03-18

### Fixed

- Documentation updates and animated demo GIF added to README.
- Zeitwerk autoloading fixes for edge cases.

## [0.5.0] - 2026-03-18

### Added

- **Introspector presets** — `:standard` (8 core introspectors, fast) and `:full` (all 21, thorough) via `config.preset = :standard`
- **`.mcp.json` auto-discovery** — Install generator creates `.mcp.json` so Claude Code and Cursor auto-detect the MCP server with zero manual config
- **Zeitwerk autoloading** — Replaced 47 `require_relative` calls with Zeitwerk for faster boot and conventional file loading
- **Automated release workflow** — GitHub Actions publishes to RubyGems via trusted publishing when a version tag is pushed
- **Version consistency check** — Release workflow verifies git tag matches `version.rb` before publishing
- **Auto GitHub Release** — Release notes extracted from CHANGELOG.md automatically
- **Dependabot** — Weekly automated dependency and GitHub Actions updates
- **README demo GIF** — Animated terminal recording showing install, doctor, and context generation
- **SECURITY.md** — Security policy with supported versions and reporting process
- **CODE_OF_CONDUCT.md** — Contributor Covenant v2.1
- **GitHub repo topics** — Added discoverability keywords (rails, mcp, ai, etc.)

### Changed

- Default introspectors reduced from 21 to 8 (`:standard` preset) for faster boot; use `config.preset = :full` for all 21
- New files auto-loaded by Zeitwerk — no manual `require_relative` needed when adding introspectors or tools

## [0.4.0] - 2026-03-18

### Added

- **14 new introspectors** — Controllers, Views, Turbo/Hotwire, I18n, Config, Active Storage, Action Text, Auth, API, Tests, Rake Tasks, Asset Pipeline, DevOps, Action Mailbox
- **3 new MCP tools** — `rails_get_controllers`, `rails_get_config`, `rails_get_test_info`
- **3 new MCP resources** — `rails://controllers`, `rails://config`, `rails://tests`
- **Model introspector enhancements** — Extracts `has_secure_password`, `encrypts`, `normalizes`, `delegate`, `serialize`, `store`, `generates_token_for`, `has_one_attached`, `has_many_attached`, `has_rich_text`, `broadcasts_to` via source parsing
- **Stimulus introspector enhancements** — Extracts `outlets` and `classes` from controllers
- **Gem introspector enhancements** — 30+ new notable gems: monitoring (Sentry, Datadog, New Relic, Skylight), admin (ActiveAdmin, Administrate, Avo), pagination (Pagy, Kaminari), search (Ransack, pg_search, Searchkick), forms (SimpleForm), utilities (Faraday, Flipper, Bullet, Rack::Attack), and more
- **Convention detector enhancements** — Detects concerns, validators, policies, serializers, notifiers, Phlex, PWA, encrypted attributes, normalizations
- **Markdown serializer sections** — All 14 new introspector sections rendered in generated context files
- **Doctor enhancements** — 4 new checks: controllers, views, i18n, tests (11 total)
- **Fingerprinter expansion** — Watches `app/controllers`, `app/views`, `app/jobs`, `app/mailers`, `app/channels`, `app/javascript/controllers`, `config/initializers`, `lib/tasks`; glob now covers `.rb`, `.rake`, `.js`, `.ts`, `.erb`, `.haml`, `.slim`, `.yml`

### Fixed

- **YAML parsing** — `YAML.load_file` calls now pass `permitted_classes: [Symbol], aliases: true` for Psych 4 (Ruby 3.1+) compatibility
- **Rake task parser** — Fixed `@last_desc` instance variable leaking between files; fixed namespace tracking with indent-based stack
- **Vite detection** — Changed `File.exist?("vite.config")` to `Dir.glob("vite.config.*")` to match `.js`/`.ts`/`.mjs` extensions
- **Health check regex** — Added word boundaries to avoid false positives on substrings (e.g. "groups" matching "up")
- **Multi-attribute macros** — `normalizes :email, :name` now captures all attributes, not just the first
- **Stimulus action regex** — Requires `method(args) {` pattern to avoid matching control flow keywords
- **Controller respond_to** — Simplified format extraction to avoid nested `end` keyword issues
- **GetRoutes nil guard** — Added `|| {}` fallback for `by_controller` to prevent crash on partial introspection data
- **GetSchema nil guard** — Added `|| {}` fallback for `schema[:tables]` to prevent crash on partial schema data
- **View layout discovery** — Added `File.file?` filter to exclude directories from layout listing
- **Fingerprinter glob** — Changed from `**/*.rb` to multi-extension glob to detect changes in `.rake`, `.js`, `.ts`, `.erb` files

### Changed

- Default introspectors expanded from 7 to 21
- MCP tools expanded from 6 to 9
- Static MCP resources expanded from 4 to 7
- Doctor checks expanded from 7 to 11
- Test suite expanded from 149 to 247 examples with exact value assertions

## [0.3.0] - 2026-03-18

### Added

- **Cache invalidation** — TTL + file fingerprinting for MCP tool cache (replaces permanent `||=` cache)
- **MCP Resources** — Static resources (`rails://schema`, `rails://routes`, `rails://conventions`, `rails://gems`) and resource template (`rails://models/{name}`)
- **Per-assistant serializers** — Claude gets behavioral rules, Cursor/Windsurf get compact rules, Copilot gets task-oriented GFM
- **Stimulus introspector** — Extracts Stimulus controller targets, values, and actions from JS/TS files
- **Database stats introspector** — Opt-in PostgreSQL approximate row counts via `pg_stat_user_tables`
- **Auto-mount HTTP middleware** — Rack middleware for MCP endpoint when `config.auto_mount = true`
- **Diff-aware regeneration** — Context file generation skips unchanged files
- **`rails ai:doctor`** — Diagnostic command with AI readiness score (0-100)
- **`rails ai:watch`** — File watcher that auto-regenerates context files on change (requires `listen` gem)

### Fixed

- **Shell injection in SearchCode** — Replaced backtick execution with `Open3.capture2` array form; added file_type validation, max_results cap, and path traversal protection
- **Scope extraction** — Fixed broken `model.methods.grep(/^_scope_/)` by parsing source files for `scope :name` declarations
- **Route introspector** — Fixed `route.internal?` compatibility with Rails 8.1

### Changed

- `generate_context` now returns `{ written: [], skipped: [] }` instead of flat array
- Default introspectors now include `:stimulus`

## [0.2.0] - 2026-03-18

### Added

- Named rake tasks (`ai:context:claude`, `ai:context:cursor`, etc.) that work without quoting in zsh
- AI assistant summary table printed after `ai:context` and `ai:inspect`
- `ENV["FORMAT"]` fallback for `ai:context_for` task
- Format validation in `ContextFileSerializer` — unknown formats now raise `ArgumentError` with valid options

### Fixed

- `rails ai:context_for[claude]` failing in zsh due to bracket glob interpretation
- Double introspection in `ai:context` and `ai:context_for` tasks (removed unused `RailsAiContext.introspect` calls)

## [0.1.0] - 2026-03-18

### Added

- Initial release
- Schema introspection (live DB + static schema.rb fallback)
- Model introspection (associations, validations, scopes, enums, callbacks, concerns)
- Route introspection (HTTP verbs, paths, controller actions, API namespaces)
- Job introspection (ActiveJob, mailers, Action Cable channels)
- Gem analysis (40+ notable gems mapped to categories with explanations)
- Convention detection (architecture style, design patterns, directory structure)
- 6 MCP tools: `rails_get_schema`, `rails_get_routes`, `rails_get_model_details`, `rails_get_gems`, `rails_search_code`, `rails_get_conventions`
- Context file generation: CLAUDE.md, .cursorrules, .windsurfrules, .github/copilot-instructions.md, JSON
- Rails Engine with Railtie auto-setup
- Install generator (`rails generate rails_ai_context:install`)
- Rake tasks: `ai:context`, `ai:serve`, `ai:serve_http`, `ai:inspect`
- CLI executable: `rails-ai-context serve|context|inspect`
- Stdio + Streamable HTTP transport support via official mcp SDK
- CI matrix: Ruby 3.2/3.3/3.4 × Rails 7.1/7.2/8.0
