# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [5.9.1] — 2026-04-20

### Fixed — `GetConcern` missed plural concern names (#78)

Thanks to [@johan--](https://github.com/johan--) for the report and fix.

`rails_get_concern`'s includer search built its include-pattern regex via `String#classify`, which singularizes its input. Concerns with intentionally plural module names — `WorksheetImports`, `PaperTrailEvents`, `SoftDeletables`, etc. — got demodulized to `WorksheetImport` and the `include WorksheetImports` line in the model never matched. The tool reported no includers even when the concern was in use.

Switched to `String#camelize`, which normalizes case (so lowercase input like `plan_limitable` → `PlanLimitable` still works) **without** singularizing. This also restores consistency with the three other `.camelize` calls already used in `get_concern.rb` for the same "file basename / module name → class name" conversion. Covered by a new spec in `get_concern_spec.rb` that exercises the plural-name case end-to-end.

### Fixed — internal invariant compliance

- **`validate.rb` now routes all Prism parses through `AstCache`.** The Ruby syntax validator was calling `Prism.parse_file` directly and the ERB + semantic-visitor paths `Prism.parse` on string input, bypassing the cache entirely for the first and violating the "all Prism parses must flow through `RailsAiContext::AstCache`" invariant (`.results/3-identify-architecture.json:33`) for all three. Now uses `AstCache.parse(path)` for on-disk sources (picking up the existing size-cap + content-hash caching) and `AstCache.parse_string(source)` for synthetic strings. Note: `AstCache.parse` enforces a 5 MB `MAX_PARSE_SIZE` cap; Ruby files above that size fall through the existing `rescue` to the `ruby -c` subprocess validator, which returns errors but not Prism warnings — a graceful degradation that affects only pathologically large source files.
- **`Listeners::BaseListener` uses `Confidence::INFERRED` constant.** Replaced three hardcoded `"[INFERRED]"` literals in `extract_first_symbol`, `extract_key`, and `extract_value` with `RailsAiContext::Confidence::INFERRED`. Value is identical; constant reference prevents drift if the marker string is ever versioned.
- **Diagnostic `$stderr.puts` in `rescue` blocks now `ENV["DEBUG"]`-gated.** 12 previously-unconditional stderr writes across `tools/diagnose.rb` (5), `tools/review_changes.rb` (4), and `serializers/stack_overview_helper.rb` (3) were logging under normal operation whenever an optional context-enrichment step failed. These were never visible to most users but polluted stderr in MCP/CLI logs. Now silent unless `DEBUG=1`, matching the convention used everywhere else in the gem.

### Added

- **Prism-discipline regression spec** (`spec/lib/rails_ai_context/ast_cache_discipline_spec.rb`). Scans every `lib/**/*.rb` file (excluding `ast_cache.rb`) for direct `Prism.parse` / `Prism.parse_file` / `Prism.parse_string` calls and fails if any are found. Prevents re-introduction of the bypass that `validate.rb` had.

## [5.9.0] — 2026-04-16

### Fixed — Cursor chat agent didn't detect rules

Real user report during release QA: the Cursor IDE's chat agent didn't pick up rules written only as `.cursor/rules/*.mdc`, even when the rule declared `alwaysApply: true`. Cursor has **two** rule systems and the chat-agent composition path still consults the legacy `.cursorrules` file in many current builds.

`CursorRulesSerializer` now writes **both**: `.cursor/rules/*.mdc` (newer format with frontmatter / glob scoping / agent-requested triggers) AND a plain-text `.cursorrules` at the project root (legacy fallback, parsed verbatim by every Cursor build). Newer clients read the mdc files; older / chat-mode clients read `.cursorrules`. No behavior change for users who already relied on the mdc format.

The `.cursorrules` content goes through the **same** `CompactSerializerHelper#render_compact_rules` pipeline as `CLAUDE.md`, so both files convey identical project context — header, stack overview, key models, gems, architecture, commands, rules, and the MCP tool guide. Drift between the two files is no longer possible short of a manual divergence (regression spec enforces parity).

`.cursorrules` is **wrapped in `<!-- BEGIN/END rails-ai-context -->` markers** via the new `SectionMarkerWriter` module — same convention as `CLAUDE.md`, `AGENTS.md`, and `.github/copilot-instructions.md`. Pre-existing user content above or below the marker block survives every `rails ai:context` regeneration. Three regression specs cover the three branches: no-file → write markers; existing-without-markers → prepend gem block; existing-with-markers → replace only the gem block.

`FORMAT_PATHS[:cursor]` in the install generator now includes `.cursorrules` so re-install cleanup covers both files when a user removes Cursor from their selection. Regression specs added in `cursor_rules_serializer_spec.rb` and `in_gemfile_install_spec.rb` (e2e) verify both files are produced and the legacy file is plain text without frontmatter.

### Fixed — Round 3 follow-ups (post-quad-agent review)

- **`safe_glob_realpath` rescue widened.** Previously rescued only `Errno::ENOENT` and `Errno::EACCES`. Circular symlink chains (think `node_modules/@scope/*` cycles or developer-crafted loops) raise `Errno::ELOOP`; path components exceeding `NAME_MAX` raise `Errno::ENAMETOOLONG`. Both now rescued — return `nil` to skip the entry — preserving the CLAUDE.md invariant that every introspector wraps errors.

- **Install generator `CONFIG_SECTIONS` gained 3 sections.** Several user-facing config options existed in `Configuration::YAML_KEYS` but had no commented-out template line in the generated `config/initializers/rails_ai_context.rb`. Added "Database Query Tool" (`query_timeout`, `query_row_limit`, `query_redacted_columns`, `allow_query_in_production`), "Log Reading" (`log_lines`), and "Hydration" (`hydration_enabled`, `hydration_max_hints`) sections so in-Gemfile installs surface every supported knob.

### Added

- **`preset` command** — composite multi-tool workflows from CLI and rake. `rails ai:preset[architecture]` runs `analyze_feature` + `dependency_graph` + `performance_check` in one call. Also: `debugging` (logs + review + validate) and `migration` (schema + migration_advisor + validate). Available via both `rails-ai-context preset architecture` and `rails 'ai:preset[architecture]'`.

- **`facts` command** — concise schema facts summary. `rails ai:facts` / `rails-ai-context facts` prints tables with column/index/FK counts, model associations, key dependencies, and architecture patterns. Single command replaces 3+ MCP tool calls for quick context loading.

- **Validation pre-commit hook** — optional during `rails generate rails_ai_context:install`. Prompts to install a `.git/hooks/pre-commit` hook that runs `rails ai:tool[validate]` on staged `.rb` and `.erb` files. Catches hallucinated columns and schema drift before commit. Respects existing hooks and `--no-verify`.

### Added — E2E harness (`spec/e2e/`)

Real `rails new` → install → exercise → teardown against a fresh Rails application in a tmpdir. Covers the three install paths documented in CLAUDE.md #36, every CLI tool, the install generator, all 5 AI-client config files, and the MCP JSON-RPC protocol over both stdio and HTTP transports. Excluded from the default `rspec` run — opt-in via `E2E=1` or the new rake tasks.

- **`spec/e2e/in_gemfile_install_spec.rb`** — Path A (Gemfile entry + `rails generate rails_ai_context:install`). Verifies generator idempotency, per-AI-client config file validity, every built-in tool callable via both `bin/rails ai:tool[name]` and `bundle exec rails-ai-context tool name`, plus the `version`/`doctor`/`inspect` subcommands.

- **`spec/e2e/standalone_install_spec.rb`** — Path B (`gem install rails-ai-context` into an isolated GEM_HOME, no Gemfile entry, then `rails-ai-context init`). Verifies the Bundler-stripped `$LOAD_PATH` restoration logic described in CLAUDE.md #33 actually works on a real app.

- **`spec/e2e/zero_config_install_spec.rb`** — Path C (gem install, no init, no generator). Verifies the CLI works from pure defaults against any Rails app without any project-side setup.

- **`spec/e2e/mcp_stdio_protocol_spec.rb`** — spawns `rails-ai-context serve` as a subprocess and walks the full JSON-RPC 2.0 handshake: `initialize` → `notifications/initialized` → `tools/list` → `tools/call`. Verifies every registered built-in tool is advertised in `tools/list` with a rails_-prefixed name, description, and inputSchema.

- **`spec/e2e/mcp_http_protocol_spec.rb`** — spawns `rails-ai-context serve --transport http` on a random free port and sends `Net::HTTP` POST requests with JSON-RPC payloads. Verifies the HTTP transport returns the same tool registry and tool-call responses as stdio. Handles the Streamable HTTP requirements: `Accept: application/json, text/event-stream` header + `Mcp-Session-Id` round-trip from initialize.

- **`spec/e2e/empty_app_spec.rb`** — every built-in tool must handle a Rails app with no scaffolds, no models, no custom routes. Catches "tool crashes when introspecting an empty greenfield app" — the moment a developer is most likely to install rails-ai-context.

- **`spec/e2e/tool_edge_cases_spec.rb`** — malformed CLI inputs: unknown tool name, unknown parameter, missing required parameter, oversized string (10 KB), invalid enum value, fuzzy-match recovery, nonexistent target. Each case must produce structured user-facing errors, never an unhandled exception or signal.

- **`spec/e2e/concurrent_mcp_spec.rb`** — two parallel `rails-ai-context serve` subprocesses against the same Rails app. Verifies independent initialize responses, identical tool registries, and that simultaneous `tools/call` invocations don't cross-talk (response id matches request id per client).

- **`spec/e2e/postgres_install_spec.rb`** — Postgres adapter coverage for the `rails_query` tool's adapter-specific code paths: `SET TRANSACTION READ ONLY`, `BLOCKED_FUNCTIONS` regex against `pg_read_file`, `dblink`, `COPY ... PROGRAM`, and DDL rejection. Skipped locally unless `TEST_POSTGRES=1`; runs unconditionally in CI which spins up a Postgres 16 service container.

- **`spec/e2e/massive_app_spec.rb`** — 1500-model stress test. Programmatically generates a single migration with 1500 `create_table` statements and 1500 corresponding `ApplicationRecord` subclass files (rails-g-scaffold × 1500 would take 30+ min; direct file writes take seconds). Runs representative tools (`schema`, `model_details`, `routes`, `context`, `onboard`, `analyze_feature`, `get_turbo_map`, `get_env`) against the massive fixture and asserts: no signal, exit < 2, stdout non-empty, response size < 2 MB (tools must truncate — uncapped output overwhelms AI client context). Also verifies `rails_get_schema --table thing_0750s` finds a table in the middle of the range, proving schema introspection walks beyond the first page.

Rake tasks: `bundle exec rake e2e` (full), `rake e2e:in_gemfile`, `rake e2e:standalone`, `rake e2e:zero_config`, `rake e2e:mcp`.

CI: `.github/workflows/e2e.yml` runs on push to main + workflow_dispatch (separate from `ci.yml` so the 30-min job doesn't fail-stop the per-commit matrix). Matrix covers Ruby 3.3 + 3.4 across Rails 7.1, 7.2, 8.0, 8.1, and includes a Postgres 16 service container so the SQL-query and adapter-specific code paths are exercised on every push.

### Fixed — Security Hardening (Round 3)

Pre-release audit of **every** `Dir.glob` call site across the 38 tools. The 5-rule file-read pattern documented in CLAUDE.md was enforced on caller-supplied paths, but glob-sourced paths were reading file content without the same hardening. A symlink pre-planted inside `app/services/`, `app/jobs/`, `app/helpers/`, `app/models/`, `app/controllers/`, `app/views/`, or `app/` (pointing at `config/master.key`) would have leaked secret contents through tool output.

- **`BaseTool.safe_glob_realpath` + `BaseTool.safe_glob`** added as shared helpers. Every glob-sourced file read now passes through this filter: realpath + separator-aware containment + `sensitive_file?` recheck on the realpath. Broken symlinks, sibling-directory bypasses, and sensitive-pattern matches return `nil` and are skipped.

- **`get_service_pattern`, `get_job_pattern`, `get_helper_methods`** — glob+read on `app/services/`, `app/jobs/`, `app/helpers/` plus nested `find_callers` / `find_enqueuers` / `find_view_references` / `detect_framework_helpers`. All hardened.

- **`analyze_feature`** — 10 glob sites across `discover_services`, `discover_jobs`, `discover_views`, `discover_tests`, `discover_test_gaps`, `discover_channels`, `discover_mailers`, `discover_env_dependencies`. All hardened.

- **`get_conventions`** — glob+read on controllers (convention detection), services (listing), locales, controllers (UI-language detection), tests (pattern detection). All hardened.

- **`get_turbo_map`** — glob+read on models, controllers/services/jobs/channels, and two view scans. All hardened.

- **`get_env`** — glob+read on `app/config/lib` for ENV scans, `app/` for HTTP-client detection, and `app/config/lib` for prefix-matched ENV vars. All hardened. Removed redundant pre-realpath `sensitive_file?` now that `safe_glob` checks post-realpath.

- **`get_test_info`** — glob+read on `test/**/*_test.rb` for Devise detection, `test/fixtures` and `spec/fixtures` for fixture parsing. Hardened.

- **`generate_test`** — glob+read on `spec/**/*_spec.rb` or `test/**/*_test.rb` for pattern detection. Hardened.

- **`get_stimulus`** — glob+read on `app/views/**/*.{erb,html.erb}` for `data-controller` usage. Hardened.

- **`onboard`** — glob of `app/services/` for service name extraction (basename only). Hardened for consistency even though no content is read.

- **`search_code`** (ruby-fallback path) — the pre-realpath `sensitive_file?` check did not catch a symlink `app/models/innocent.rb → config/master.key` because the relative path looked safe. Now goes through `safe_glob` which rechecks on the realpath.

- **`job_introspector.rb:205`** — bare `rescue` (catching `Exception`, including `Interrupt`/`SystemExit`) replaced with project-standard `rescue => e` + DEBUG logging guard.

- **14 new regression specs** covering every newly-hardened tool with a symlink-to-master.key PoC + 5 edge cases for the `safe_glob_realpath` helper (sibling bypass, broken symlinks, sensitive realpath, separator awareness, in-tree passthrough).

### Fixed — Security Hardening (Round 2)

Eleven additional vulnerabilities and defense-in-depth gaps found by multi-round adversarial code review. All discovered post-v5.8.1 — **users on 5.8.x should upgrade**.

- **MySQL executable-comment bypass of `BLOCKED_FUNCTIONS`.** `strip_sql_comments` stripped `/*! ... */` (MySQL version-conditional comments) along with regular block comments. MySQL *executes* content inside `/*! ... */`, so `SELECT /*!50000 LOAD_FILE('/etc/passwd') */ AS x` passed all validation. **Fix:** unwraps executable comments (preserves inner content for checker visibility) before the block-comment strip. Belt-and-suspenders: also runs `BLOCKED_FUNCTIONS` against the raw SQL before any stripping.

- **`execute_explain` bypassed READ ONLY transaction and statement timeout.** The EXPLAIN path called `conn.select_all(explain_sql)` directly instead of routing through `execute_postgresql`/`execute_mysql`/`execute_sqlite`. PostgreSQL `EXPLAIN (FORMAT JSON, ANALYZE)` actually executes the query plan — an attacker could hold a DB connection indefinitely and bypass the read-only guard. **Fix:** routes through adapter-specific safety wrappers.

- **`read_logs` C1 sibling-directory bypass.** Bare `real.start_with?(File.realpath(root))` matched `/var/app/myapp_evil` against `/var/app/myapp`. **Fix:** separator-aware containment (`real == base || real.start_with?(base + File::SEPARATOR)`).

- **`read_logs` TOCTOU window.** Resolved the realpath for the containment check, then opened the original `path` for reading. Symlink swap between check and open leaked arbitrary files. **Fix:** returns and reads from the realpath.

- **`read_logs` missing post-realpath sensitive recheck.** A symlink `log/credentials.log -> ../config/master.key` resolves to a path still under Rails.root, passing containment. Without `sensitive_file?` on the realpath, `tail_file` read the secret. **Fix:** added post-realpath `sensitive_file?` recheck.

- **VFS `resolve_view` existence-oracle side channel.** `File.exist?` ran before `sensitive_file?`, so two distinct error messages ("View not found" vs "sensitive file") revealed whether `.env` / `master.key` existed inside `app/views/`. **Fix:** early `sensitive_file?` check before any filesystem stat.

- **`get_partial_interface` existence-oracle side channel.** `candidates.find { |c| File.exist?(c) }` stat'd candidates before any sensitive check on the caller-supplied `partial` string. Same oracle as the VFS fix. **Fix:** early `sensitive_file?` check in `call`.

- **`get_view` `list_layouts` missing all security rules.** Iterated `Dir.glob` results with no realpath containment, no sensitive recheck, and no size gate. A symlink `layouts/leak.key -> ../../config/master.key` leaked secrets in the `full` detail branch. **Fix:** full 5-rule file-reading pattern per file.

- **`get_view` `read_view_content` missing all security rules.** Called `SafeFile.read` after a bare `File.exist?` with no containment, no sensitive recheck, and no size cap. **Fix:** full 5-rule file-reading pattern with `max_file_size` gate.

- **`get_concern` `show_concern` path traversal.** `name.underscore` does not sanitize `../`, so `name: "../../config/initializers/devise"` read arbitrary `.rb` files under Rails.root. The proposed fix in the IDOR variant would have been a security downgrade. **Fix:** early traversal/null-byte/absolute-path rejection, early `sensitive_file?`, per-candidate realpath + separator containment, post-realpath sensitive recheck.

- **`get_concern` `list_concerns` symlink escape.** `Dir.glob` results passed to `SafeFile.read` with no realpath containment or sensitive recheck. **Fix:** per-file 5-rule pattern.

### Changed

- All documentation examples, tool descriptions, code comments, and test fixtures now use generic Rails terminology (`PostsController`, `publishable?`, `posts/index.html.erb`) instead of app-specific references. Affects README, GUIDE, CLI, RECIPES docs, tool_guide_helper serializer, 6 MCP tool description strings, CHANGELOG, demo scripts, and 3 spec files.

## [5.8.1] — 2026-04-15

### Fixed — Security Hardening

Four exploitable vulnerabilities across `rails_query`, the VFS URI dispatcher, and the instrumentation bridge, plus six defense-in-depth hardening issues. All discovered by security and deep code-review passes conducted during v5.8.1 pre-release verification. None were known at the v5.8.0 release — **users should upgrade immediately**.

- **SQL column-aliasing redaction bypass (exploitable).** Post-execution redaction in `rails_query` operated on `result.columns` (the DB-returned column names), which the caller controls via aliases and expressions. `SELECT password_digest AS x FROM users` returned raw bcrypt hashes. Same for `SELECT substring(password_digest, 1, 60) FROM users` (column named `substring`), `SELECT md5(session_data) FROM sessions`, `SELECT CASE WHEN id > 0 THEN password_digest END FROM users`, and subqueries that re-project the sensitive column. **Fix:** moved enforcement to pre-execution in `validate_sql`. Any query that textually references a column name in `config.query_redacted_columns` OR the hard-coded `SENSITIVE_COLUMN_SUFFIXES` list (password_digest, encrypted_password, password_hash, reset_password_token, api_key, refresh_token, otp_secret, session_data, secret_key, private_key, etc.) is now rejected. Users with a legitimately non-sensitive column matching one of these names can subtract from `config.query_redacted_columns` in an initializer. **8 bypass scenarios covered by new specs.**

- **Arbitrary filesystem read via database functions (exploitable).** `rails_query` did not block PostgreSQL's `pg_read_file`, `pg_read_binary_file`, `pg_ls_dir`, `pg_stat_file`, `lo_import`/`lo_export`, `dblink`, MySQL's `LOAD_FILE`, `SELECT ... INTO OUTFILE/DUMPFILE`, or SQLite's `load_extension`. These are SELECT-callable (so they pass the `BLOCKED_KEYWORDS` scanner and `SET TRANSACTION READ ONLY`) but give the caller a filesystem and shared-library-load primitive — completely bypassing the gem's `sensitive_patterns` allowlist by pivoting through the database process. PoC: `SELECT pg_read_file('/etc/passwd')`, `SELECT pg_read_file('config/master.key')`. **Fix:** added a `BLOCKED_FUNCTIONS` regex and `BLOCKED_OUTPUT` pattern that reject any query referencing these built-ins. **10 function-specific specs added.**

- **`sensitive_patterns` default list expanded.** The v5.8.0 default list covered `.env`, `.env.*`, `config/master.key`, `config/credentials*.yml.enc`, `*.pem`, `*.key` but missed common secret locations. v5.8.1 adds `config/database.yml`, `config/secrets.yml`, `config/cable.yml`, `config/storage.yml`, `config/mongoid.yml`, `config/redis.yml`, `*.p12`, `*.pfx`, `*.jks`, `*.keystore`, `**/id_rsa`, `**/id_ed25519`, `**/id_ecdsa`, `**/id_dsa`, `.ssh/*`, `.aws/credentials`, `.aws/config`, `.netrc`, `.pgpass`, `.my.cnf`.

- **`get_edit_context` now re-checks `sensitive_file?` after realpath resolution.** The initial check ran on the caller-supplied string; a symlink inside `app/models/` pointing at `config/master.key` previously passed the basename check and fell through to `File.read`. The post-realpath check blocks this.

- **`validate` now enforces `sensitive_file?`.** The validate tool had no sensitive-file check at all. Even though its output is limited to error messages (not raw content), it still leaked file existence/size and ran readers on secret files. Now denied with an `access denied (sensitive file)` error.

- **`BaseTool.sensitive_file?` has direct spec coverage for the first time.** The security boundary behind every file-accepting tool had zero direct tests in v5.8.0 — 36 new specs added covering the Rails secret locations, the v5.8.1 expanded pattern list, private keys and certificates, case-insensitivity, basename-only matching, and custom pattern configurations.

- **VFS `resolve_view` sibling-directory path traversal (exploitable).** The `rails-ai-context://views/{path}` URI resolver used bare `String#start_with?` on the realpath without a `File::SEPARATOR` suffix check. `/app/views_spec/secret.erb` matched `/app/views` as a prefix, so a symlink inside `app/views/` pointing at a sibling directory escaped containment and returned arbitrary file content. **Fix:** changed the containment check to `real == base || real.start_with?(base + File::SEPARATOR)`. Also added a `sensitive_file?` realpath check mirroring the v5.8.1 `get_edit_context` fix, so `.env`/`.key` symlinks inside `app/views/` are rejected. **2 new regression specs covering both PoCs.**

- **Instrumentation bridge leaks raw tool arguments to ActiveSupport::Notifications subscribers (exploitable).** `Instrumentation.callback` forwarded the MCP SDK's full data hash to `ActiveSupport::Notifications.instrument`. The SDK's `add_instrumentation_data(tool_name:, tool_arguments:)` includes raw tool inputs — so every Rails observability subscriber (Datadog, Scout, New Relic, custom loggers) received `rails_query`'s raw SQL, `rails_get_env`'s env var names, and `rails_read_logs`'s search patterns unredacted. The response-side redaction each of those tools carefully implements did nothing for the request side. **Fix:** introduced `Instrumentation::SAFE_KEYS` (`method`, `tool_name`, `duration`, `error`, `resource_uri`, `prompt_name`) — only those fields are forwarded. Users who need arguments in observability can set `config.instrumentation_include_arguments = true` in an initializer (taking on the redaction obligation). **3 new regression specs.**

- **Instrumentation subscriber failures could crash tool calls (exploitable).** The MCP SDK's `instrument_call` invokes our callback from an `ensure` block. Any exception raised inside the callback (e.g. a custom subscriber bug, a Datadog client losing connection) would propagate out of `ensure` and overwrite the tool's actual return value — effectively failing every tool call whenever any subscriber was broken. **Fix:** wrapped the `Notifications.instrument` call in a `rescue => e` block. Subscriber failures now log to stderr under `DEBUG=1` instead of corrupting tool responses. **1 new regression spec.**

- **`analyze_feature` caps per-directory file scans at 500 files.** `discover_services`, `discover_jobs`, and `discover_views` previously ran unbounded `Dir.glob` + `SafeFile.read` on every match, which on large monorepos could read thousands of files per call. Matches the existing cap used by `discover_tests`. Tool output notes when the cap was hit so the AI agent knows to narrow its feature keyword.

### Added — Configuration

- **`config.instrumentation_include_arguments`** (default `false`) — controls whether raw tool arguments are forwarded to `ActiveSupport::Notifications` subscribers. See the Security Hardening note above for the opt-in risk.

### Performance — Hot-Path Optimization

- **`cached_context` TTL short-circuit.** The hot path of every tool call ran `Fingerprinter.changed?` on every hit, which walks every `*.{rb,rake,js,ts,erb,haml,slim,yml}` file in `WATCHED_DIRS` plus (for path:-installed users) every file in the gem's own lib/ tree — doing an `mtime` stat per file. Measured at ~12ms per call in dev-mode path installs, ~0.5ms in production. Since LiveReload fires `reset_all_caches!` on actual file-change events, stale-cache risk during a short TTL window is already covered. **Fix:** skip the fingerprint check entirely when within the TTL window. When TTL expires, re-fingerprint; if unchanged, bump the timestamp and reuse the cached context (avoiding a 31-introspector re-run).

- **Fingerprinter gem-lib scan memoized.** For users who install the gem via `path:` (common for gem contributors, monorepos, the standalone dev workflow), the fingerprinter was walking 123 gem-lib files on every tool call. Memoized at class level with a `reset_gem_lib_fingerprint!` hook that `BaseTool.reset_cache!` and LiveReload invoke.

- **Measured result:** `cached_context` hot-path benchmark dropped from **11.77ms to 0.199ms** per call — a **~59x speedup** on dev-mode path installs. In-Gemfile / production users see a smaller but still meaningful improvement (0.77ms → 0.199ms).

### Fixed — schema.rb empty-file wrinkle

- `SchemaIntrospector#static_schema_parse` returned `{ error: "No db/schema.rb, db/structure.sql, or migrations found" }` when `db/schema.rb` existed but contained zero `create_table` calls (common on freshly-created Rails apps between `db:create` and the first migration). Now returns `{ total_tables: 0, tables: {}, note: "Schema file exists but is empty — no migrations have been run yet..." }`.

### Changed — CI release matrix synced to PR matrix

- `.github/workflows/release.yml` test matrix was still on the old Ruby `3.2/3.3/3.4` × Rails `7.1/7.2/8.0` grid even though `ci.yml` was expanded to cover Ruby 4.0 and Rails 8.1 in v5.8.0. Now synced — release-time testing matches PR-time testing across all 12 combos, including the #69 reporter's environment (Ruby 4.0.2 + Rails 8.1.3).

### Fixed — Pre-release review pass (rounds 2–3)

Five additional issues found during multi-round cold-eyes security and correctness review after the initial hardening pass.

- **`search_code` sibling-directory path traversal.** `rails_search_code`'s `path` parameter used `real_search.start_with?(real_root)` without a `File::SEPARATOR` suffix — the same bypass class as the original VFS C1 bug. A Rails root of `/app/myapp` would accept a search path whose realpath is `/app/myapp_evil`. **Fix:** changed to `real_search == real_root || real_search.start_with?(real_root + File::SEPARATOR)`. Spec added.

- **Instrumentation callback: `data[:method]` extraction outside `begin/rescue`.** Two lines before the `begin` block (`method = data[:method]` and `event_name = ...`) were not covered by the rescue. A non-Hash `data` argument from the MCP SDK would raise `NoMethodError` which would propagate into the SDK's `ensure` context and overwrite the tool's return value. **Fix:** moved `begin` to wrap the full lambda body after the early-exit guard.

- **`get_partial_interface` TOCTOU gap (residual from initial hardening).** `resolve_partial_path` performed the `File.realpath` security check internally but returned the original glob `found` path to the caller. The caller then called `File.size(found)` and `safe_read(found)` — creating a sub-millisecond race window where a symlink swap could read from a path that bypassed the check. **Fix:** `resolve_partial_path` now returns `real_found`. All file operations in the caller use the pre-checked realpath.

- **`validate` tool passed pre-realpath path to validators.** `validate_ruby`, `validate_erb`, `validate_javascript`, and `check_rails_semantics` all received `full_path` (pre-realpath) after the security check resolved `real`. **Fix:** all four now receive `Pathname.new(real)`.

- **`rails_query` `LOAD DATA INFILE` not explicitly blocked.** Added `LOAD\s+DATA` to `BLOCKED_FUNCTIONS`. Belt-and-suspenders: `ALLOWED_PREFIX` already blocks it at statement level, but the explicit entry makes intent self-documenting. Two specs added (`LOAD DATA INFILE` and `LOAD DATA LOCAL INFILE`).

### Test coverage

- **2004 examples, 0 failures** (was 1928 in v5.8.0, +76 new regression tests across the security + hardening + empty-schema + VFS + instrumentation + review-pass fixes).

## [5.8.0] — 2026-04-14

### Added — Modern Rails Coverage Pass

Five targeted gaps in modern Rails introspection, identified by an audit of the introspectors against current Rails 7/8 patterns. Net result: the gem now surfaces what AI agents need to know about Rails 8 built-in auth, Solid Errors, async query usage, strong_migrations safety, and Action Cable channel detail.

- **Rails 8 built-in auth depth.** `auth_introspector#detect_authentication` previously detected `bin/rails generate authentication` only as a boolean. Now returns a hash with the Authentication concern path, the Sessions/Passwords controller paths, and a per-controller list of `allow_unauthenticated_access` filters with their `only:`/`except:` scope. Each declaration in a file yields its own entry (a controller with both `only:` and `except:` is captured fully, not collapsed to the first match), and trailing line comments are stripped from the captured scope. AI agents can answer "which controllers are public?" in one tool call.
- **Solid Errors gem detection.** Added `solid_errors` (Rails 8 database-backed error tracking, by @fractaledmind) to `gem_introspector.rb`'s `NOTABLE_GEMS` map under the `:monitoring` category. Was the only Solid-* gem missing from the list (`solid_queue`, `solid_cache`, `solid_cable` were already covered). `solid_health` is NOT a real published gem — Rails 8 ships a built-in `/up` healthcheck endpoint with no gem needed.
- **Async query pattern detection.** `convention_introspector#detect_patterns` now adds `async_queries` to the patterns array when it finds `load_async` or any of the `async_count`/`async_sum`/`async_minimum`/`async_maximum`/`async_average`/`async_pluck`/`async_ids`/`async_exists`/`async_find_by`/`async_find`/`async_first`/`async_last`/`async_take` calls in `app/controllers`, `app/services`, `app/jobs`, or `app/models`. Comment-only references (e.g. `# TODO: bring back load_async`) are skipped to avoid false positives. AI agents can recognize the perf optimization is in use without re-scanning.
- **Strong Migrations integration.** `migration_advisor` now emits a `## Strong Migrations Warnings` section when the `strong_migrations` gem is in `Gemfile.lock`. Catalog covers the most common breaking-change patterns: `remove_column` (needs `safety_assured` + `ignored_columns` first), `rename_column` (unsafe under load, two-step pattern), `change_column` type change (table rewrite), `add_index` without `algorithm: :concurrently` (Postgres write lock), `add_foreign_key` without `validate: false` (lock validation), and `add_column` with `null: false` but no default (table rewrite). Each warning includes the safer pattern. Fires only when the gem is detected — zero noise for projects that don't use it.
- **Action Cable channel detail.** `job_introspector#extract_channels` was returning `{ name, stream_methods }` only. Enriched to also extract `identified_by` attributes, `stream_from`/`stream_for` targets, `periodically` timers with their full intervals (including lambdas like `every: -> { current_user.interval }`), RPC action methods (excluding subscribed/unsubscribed/stream_*), and the source file path. **`get_job_pattern` now renders an "Action Cable Channels" section with all of these fields**, so AI agents calling the tool actually see the data instead of just the channel name. Also added `eager_load_channels!` to `JobIntrospector` so the channel set is populated in development mode (where `config.eager_load = false` and `ActionCable::Channel::Base.descendants` is otherwise empty until a client subscribes).

### Changed — CI matrix expanded to cover Ruby 4.0 + Rails 8.1

- Added Ruby `4.0` and Rails `8.1` to the GitHub Actions test matrix. Net jobs: 12 (was 8). Excludes the unsupported combinations: Ruby 3.2 × Rails 8.x (Rails 8 needs 3.3+) and Ruby 4.0 × Rails 7.x (Rails 7 has no Ruby 4 support). Verified locally that the full spec suite passes on Ruby 4.0.2 + Rails 8.1.3 (the environment in #69) — 1925 examples, 0 failures, rubocop clean across all 282 source files.

### Fixed — Standalone Install Path Crashed Inside Bundler-Backed Rails Apps

- **`rails-ai-context` installed via `gem install` (standalone path) crashed on every tool call** when run inside a Rails app that has its own `Gemfile`. Root cause: `boot_rails!` in `exe/rails-ai-context` calls `require config/environment.rb` which runs `Bundler.setup`, which strips `Gem.loaded_specs` to only the app's Gemfile-resolved gems. The MCP SDK reads `Gem.loaded_specs["json-schema"].full_gem_path` at tool-call time (`mcp/tool/schema.rb:45`) — but `json-schema` is a transitive dep of `mcp`, not in the app's Gemfile, so the lookup nils and crashes with `NoMethodError: undefined method 'full_gem_path' for nil`.
- **Fix:** added `restore_standalone_gem_specs` to `exe/rails-ai-context` which re-registers `mcp`, `json-schema`, and a couple of their transitive deps in `Gem.loaded_specs` after `Bundler.setup` runs. No-op in in-Gemfile mode (the specs are already registered). This was a pre-existing bug that was discovered during v5.8.0 pre-release E2E verification — affected v5.4.0 onward.

### Fixed — MCP Tool Responses Rejected by Strict Clients (#69)

- **Removed default `output_schema` from all 38 tools.** Since v5.4.0, `BaseTool.inherited` automatically assigned a `DEFAULT_OUTPUT_SCHEMA` to every tool. The schema described the response wire envelope (`{content: [...]}`) rather than app-level structured data, and tools never returned matching `structured_content`. Per MCP spec, when a tool declares `outputSchema`, it MUST return `structuredContent` matching it. Strict MCP clients (e.g. Copilot CLI) reject responses that don't, with `MCP error -32600: Tool ... has an output schema but did not return structured content`. Lenient clients (Claude Code, Cursor) silently ignored the missing field, which is why the bug went unnoticed since v5.4.0.
- **Why this happened.** The MCP Ruby SDK does not enforce `output_schema` server-side (no `validate_result` call in `MCP::Server`), so the test suite passed end-to-end. Validation happens client-side, and only strict clients caught it. Reported by @pardeyke.
- **What changed.** Deleted `DEFAULT_OUTPUT_SCHEMA` constant and the `inherited` hook line that set it (`lib/rails_ai_context/tools/base_tool.rb`). Tools now ship with no `outputSchema` by default — matching what they actually return (text-only). Individual tools can still declare their own `output_schema` via the MCP::Tool DSL, provided they also return matching `structured_content`.
- **Regression spec added.** `spec/lib/rails_ai_context/tools_spec.rb` now asserts (a) no tool advertises a default `outputSchema`, and (b) any tool that *does* declare one must also have `structured_content:` in its source — preventing the v5.4.0 misuse from sneaking back in.
- **Future enhancement.** Per-tool structured output (returning parseable JSON alongside the Markdown text via `structured_content:`) is a future feature for tools where it adds value (`get_schema`, `get_routes`, etc.). Out of scope for this patch.

### Added — Framework Association Noise Filter

- **`excluded_association_names` config option** — filters framework-generated associations (ActiveStorage, ActionText, ActionMailbox, Noticed) from model introspection output. 7 association names excluded by default. Configurable via initializer (`config.excluded_association_names += %w[...]`) or YAML. Closes #57.

## [5.7.1] — 2026-04-09

### Changed — SLOP Cleanup

Internal code quality improvements — no API changes, no new features.

- **Extract `safe_read`, `max_file_size`, `sensitive_file?` to BaseTool** — removed 16 duplicate one-liner methods across 8 tool files (get_env, get_job_pattern, get_service_pattern, get_turbo_map, get_partial_interface, get_view, get_edit_context, get_model_details, search_code)
- **Extract `FullSerializerBehavior` module** — deduplicated identical `footer` and `architecture_summary` methods from FullClaudeSerializer and FullOpencodeSerializer
- **Derive `tools_name_list` from `TOOL_ROWS`** — replaced hardcoded 38-tool name array with derivation from single source of truth in ToolGuideHelper
- **Fix `notable_gems_list` bypass** — copilot_instructions_serializer and markdown_serializer now use the triple-fallback helper instead of raw hash access
- **Narrow bare `rescue` to `rescue StandardError`** — 4 sites in get_config and i18n_introspector no longer catch `SignalException`/`NoMemoryError`
- **Delete dead `SENSITIVE_PATTERNS = nil` constant** — vestigial from get_edit_context

## [5.7.0] — 2026-04-09

### Quickstart — Two commands. Problem gone.

```bash
gem "rails-ai-context", group: :development
rails generate rails_ai_context:install
```

### Fixed — Bug Fixes from Codebase Audit

6 bug fixes discovered via automated codebase audit (bug-finder, code-reviewer, doc-consistency-checker agents).

- **AnalyzeFeature service/mailer method extraction** (HIGH) — `\A` (start-of-string) anchor in `scan` regex replaced with `^` (start-of-line). Services and mailers now correctly list all methods instead of always returning empty arrays.

- **SearchCode exact_match + definition double-escaping** (HIGH) — Word boundaries (`\b`) were applied before `Regexp.escape`, producing unmatchable regex when combining `exact_match: true` with `match_type: "definition"` or `"class"`. Boundaries now applied per-match_type after escaping.

- **MigrationAdvisor empty string column bypass** (MEDIUM) — Empty string `""` column names bypassed the "column required" validation (Ruby truthiness). Now normalized via `.presence` so empty strings become `nil` and are caught.

- **GetConcern class method block tracking** — Regex no longer matches `def self.method` as a `class_methods do` block entry, preventing instance methods after `def self.` from being incorrectly skipped.

- **AstCache eviction comment accuracy** — Comment corrected from "evicts oldest entries" to "arbitrary selection" since `Concurrent::Map` has no ordering guarantee.

- **SECURITY.md supported versions** — Added missing 5.6.x row to supported versions table.

- **CONFIGURATION.md preset count** — Fixed stale `:standard` preset count from 13 to 17.

## [5.6.0] — 2026-04-09

### Added — Auto-Registration, TestHelper & Bug Fixes

Developer experience improvements inspired by action_mcp patterns, plus 5 security/correctness bug fixes.

- **Auto-registration via `inherited` hook** — Tools are now auto-discovered from `BaseTool` subclasses. No manual list to maintain — drop a file in `tools/` and it's registered. `Server.builtin_tools` is the new public API. Thread-safe via `@registry_mutex` with deadlock-free design (const_get runs outside mutex to avoid recursive locking from inherited). `Server::TOOLS` preserved as deprecated `const_missing` shim for backwards compatibility.

- **`abstract!` pattern** — `BaseTool.abstract!` excludes a class from the registry. `BaseTool` itself is abstract. Subclasses are concrete by default.

- **TestHelper module** (`lib/rails_ai_context/test_helper.rb`) — Reusable test helper for custom_tools users. Methods: `execute_tool` (by name, short name, or class), `execute_tool_with_error`, `assert_tool_findable`, `assert_tool_response_includes`, `assert_tool_response_excludes`, `extract_response_text`. Works with both RSpec and Minitest. Supports fuzzy name resolution (`schema` → `rails_get_schema`).

### Fixed

- **SQL comment stripping validation bypass** (HIGH) — `#` comment stripping now restricted to line-start only, preventing validation bypass via hash characters in string literals. PostgreSQL JSONB operators (`#>>`) preserved.

- **SHARED_CACHE read outside mutex** (MEDIUM) — `redact_results` now uses `cached_context` for thread-safe access to encrypted column data.

- **McpController double-checked locking** (MEDIUM) — Removed unsynchronized read outside mutex, fixing unsafe pattern on non-GVL Rubies (JRuby/TruffleRuby).

- **PG EXPLAIN parser bare rescue** (LOW) — Changed from `rescue` to `rescue JSON::ParserError`, preventing silent swallowing of bugs in `extract_pg_nodes`.

- **GetConcern `class_methods` block closing** (LOW) — Indent-based tracking to detect the closing `end`, so `def self.` methods after the block are no longer lost.

- **Query spec graceful degradation** — Replaced permanently-pending spec (sqlite3 2.x removed `set_progress_handler`) with a spec that verifies queries execute correctly without it.

## [5.5.0] — 2026-04-08

### Added — Universal MCP Auto-Discovery & Per-Tool Context Optimization (#51-#56)

Every AI tool now gets its own MCP config file — auto-detected on project open. No manual setup needed for any supported tool.

- **McpConfigGenerator** (`lib/rails_ai_context/mcp_config_generator.rb`) — Shared infrastructure for per-tool MCP config generation. Writes `.mcp.json` (Claude Code), `.cursor/mcp.json` (Cursor), `.vscode/mcp.json` (GitHub Copilot), `opencode.json` (OpenCode), `.codex/config.toml` (Codex CLI). Merge-safe — only manages the `rails-ai-context` entry, preserves other servers. Supports standalone mode and CLI skip.

- **Codex CLI support** (#51) — 5th supported AI tool. Reuses `AGENTS.md` (shared with OpenCode) and `OpencodeRulesSerializer` for directory-level split rules. Config via `.codex/config.toml` (TOML format) with `[mcp_servers.rails-ai-context.env]` subsection that snapshots Ruby environment variables at install time — required because Codex CLI `env_clear()`s the process before spawning MCP servers. Works with all Ruby version managers (rbenv, rvm, asdf, mise, chruby, system). Added to all 3 install paths (generator, CLI, rake), doctor checks, and search exclusions.

- **Cursor improvements** (#52) — `.cursor/mcp.json` auto-generated for MCP auto-discovery. MCP tools rule changed from `alwaysApply: true` to `alwaysApply: false` with descriptive text for agent-requested (Type 3) loading.

- **OpenCode improvements** (#53) — `opencode.json` auto-generated for MCP auto-discovery.

- **Claude Code improvements** (#54) — `paths:` YAML frontmatter added to `.claude/rules/` schema, models, and components rules for conditional loading. Context and mcp-tools rules remain unconditional.

- **Copilot improvements** (#55) — `.vscode/mcp.json` auto-generated for MCP auto-discovery. `name:` and `description:` YAML frontmatter added to all `.github/instructions/` files. Updated `excludeAgent` spec to validate `code-review`, `coding-agent`, and `workspace` per GitHub Copilot docs.

- **All 3 install paths updated** — Install generator, standalone CLI (`rails-ai-context init`), and rake task (`rails ai:setup`) all delegate to McpConfigGenerator. Codex added as option "5" in interactive tool selection.

- **Doctor expanded** — `check_mcp_json` now validates per-tool MCP configs based on configured `ai_tools` (JSON parse validation + TOML existence check).

- **Search exclusions** — `.codex/`, `.vscode/mcp.json`, `opencode.json` added to `search_code` tool exclusions.

## [5.4.0] — 2026-04-08

### Added — Phase 3: Dynamic VFS & Live Resource Architecture (Ground Truth Engine Blueprint #39)

Live Virtual File System replaces static resource handling. Every MCP resource is introspected fresh on every request — zero stale data.

- **VFS URI Dispatcher** (`lib/rails_ai_context/vfs.rb`) — Pattern-matched routing for `rails-ai-context://` URIs. Resolves models, controllers, controller actions, views, and routes. Each call introspects fresh. Path traversal protection for view reads.

- **4 new MCP Resource Templates:**
  - `rails-ai-context://controllers/{name}` — controller details with actions, filters, strong params
  - `rails-ai-context://controllers/{name}/{action}` — action source code and applicable filters
  - `rails-ai-context://views/{path}` — view template content (path traversal protected)
  - `rails-ai-context://routes/{controller}` — live route map filtered by controller name

- **MCP Controller** (`app/controllers/rails_ai_context/mcp_controller.rb`) — Native Rails controller for Streamable HTTP transport. Alternative to Rack middleware — integrates with Rails routing, authentication, and middleware stack. Mount via `mount RailsAiContext::Engine, at: "/mcp"`.

- **output_schema on all 38 tools** — Default `MCP::Tool::OutputSchema` set via `BaseTool.inherited` hook. Every tool now declares its output format in the MCP protocol. Individual tools can override with custom schemas.

- **Instrumentation** (`lib/rails_ai_context/instrumentation.rb`) — Bridges MCP gem instrumentation to `ActiveSupport::Notifications`. Events: `rails_ai_context.tools.call`, `rails_ai_context.resources.read`, etc. Subscribe with standard Rails notification patterns.

- **Server instructions** — MCP server now includes `instructions:` field describing the ground truth engine capabilities.

- **Enhanced LiveReload** — Full cache sweep on file changes via `reset_all_caches!` (includes AST, tool, and fingerprint caches).

- **82 new specs** covering VFS resolution (models, controllers, actions, views, routes), instrumentation callback, McpController (thread safety, delegation, subclass isolation), resource templates (5 total), output_schema on all 38 tools, and server configuration.

## [5.3.0] — 2026-04-07

### Added — Phase 2: Cross-Tool Semantic Hydration (Ground Truth Engine Blueprint #38)

Controller and view tools now automatically inject schema hints for referenced models, eliminating the need for follow-up tool calls.

- **SchemaHint** (`lib/rails_ai_context/schema_hint.rb`) — Immutable `Data.define` value object carrying model ground truth: table, columns, associations, validations, primary key, and `[VERIFIED]`/`[INFERRED]` confidence tag.

- **HydrationResult** — Wraps hints + warnings for downstream formatting.

- **SchemaHintBuilder** (`lib/rails_ai_context/hydrators/schema_hint_builder.rb`) — Resolves model names to `SchemaHint` objects from cached introspection context. Case-insensitive lookup, batch builder with configurable cap.

- **HydrationFormatter** (`lib/rails_ai_context/hydrators/hydration_formatter.rb`) — Renders `SchemaHint` objects as compact Markdown `## Schema Hints` sections with columns (capped at 10), associations, and validations.

- **ControllerHydrator** (`lib/rails_ai_context/hydrators/controller_hydrator.rb`) — Parses controller source via Prism AST to detect model references (constant receivers, `params.require` keys, ivar writes), then builds schema hints.

- **ViewHydrator** (`lib/rails_ai_context/hydrators/view_hydrator.rb`) — Maps instance variable names to models by convention (`@post` → `Post`, `@posts` → `Post`). Filters framework ivars (page, query, flash, etc.).

- **ModelReferenceListener** (`lib/rails_ai_context/introspectors/listeners/model_reference_listener.rb`) — Prism Dispatcher listener for controller-specific model detection. Not registered in `LISTENER_MAP` — used standalone by `ControllerHydrator`.

- **Tool integrations:**
  - `GetControllers` — schema hints injected into both action source and controller overview
  - `GetContext` — hydrates combined controller+view ivars in action context mode
  - `GetView` — hydrates instance variables from view templates in standard detail

- **Configuration:** `hydration_enabled` (default: true), `hydration_max_hints` (default: 5). Both YAML-configurable.

- **65 new specs** covering SchemaHint, HydrationResult, SchemaHintBuilder, HydrationFormatter, ModelReferenceListener, ControllerHydrator, ViewHydrator, tool-level hydration integration (GetControllers, GetView), and configuration (defaults, YAML loading, max_hints propagation).

## [5.2.0] — 2026-04-07

### Added — Phase 1: Prism AST Foundation (Ground Truth Engine Blueprint #36)

System-wide AST migration replacing all regex-based Ruby source parsing with Prism AST visitors. This is the foundation layer for the Ground Truth Engine transformation (#37).

- **AstCache** (`lib/rails_ai_context/ast_cache.rb`) — Thread-safe Prism parse cache backed by `Concurrent::Map`. Keyed by path + SHA256 content hash + mtime. Invalidates automatically on file change. Shared by all AST-based introspectors.

- **VERIFIED/INFERRED confidence contract** — `Confidence.for_node(node)` determines whether an AST node's arguments are all static literals (`[VERIFIED]`) or contain dynamic expressions (`[INFERRED]`). Called from listeners via `BaseListener#confidence_for(node)`. Every source-level introspection result now carries a confidence tag.

- **7 Prism Listener classes** (`lib/rails_ai_context/introspectors/listeners/`):
  - `AssociationsListener` — `belongs_to`, `has_many`, `has_one`, `has_and_belongs_to_many`
  - `ValidationsListener` — `validates`, `validates_*_of`, custom `validate :method`
  - `ScopesListener` — `scope :name, -> { ... }`
  - `EnumsListener` — Rails 7+ and legacy enum syntax with prefix/suffix options
  - `CallbacksListener` — all AR callback types including `after_commit` with `on:` resolution
  - `MacrosListener` — `encrypts`, `normalizes`, `delegate`, `has_secure_password`, `serialize`, `store`, `has_one_attached`, `has_many_attached`, `has_rich_text`, `generates_token_for`, `attribute` API
  - `MethodsListener` — `def`/`def self.` with visibility tracking, parameter extraction, `class << self` support

- **SourceIntrospector** (`lib/rails_ai_context/introspectors/source_introspector.rb`) — Single-pass Prism Dispatcher that walks the AST once and feeds events to all 7 listeners simultaneously. Available as `SourceIntrospector.call(path)` for file-based introspection or `SourceIntrospector.from_source(string)` for in-memory parsing.

- **73 new specs** covering AstCache, SourceIntrospector integration, and all 7 listener classes with edge cases (multi-line associations, legacy enums, visibility tracking, parameter extraction).

### Changed

- **ModelIntrospector** rewritten to use AST-based source parsing via `SourceIntrospector` instead of regex. Reflection-based extraction (associations via AR, validations via AR, enums via AR) preserved where it provides runtime accuracy. All `source.scan(...)`, `source.each_line`, and `line.match?(...)` patterns in model introspection eliminated.

- **Install generator** now wraps `config/initializers/rails_ai_context.rb` in `if defined?(RailsAiContext)` so apps with the gem in `group :development` only don't crash in test/production. Re-install upgrades existing unguarded initializers and preserves indentation. All README and GUIDE initializer examples updated to the guarded form (#35).

### Dependencies

- Added `prism >= 0.28` (stdlib in Ruby 3.3+, gem for 3.2)
- Added `concurrent-ruby >= 1.2` (thread-safe AST cache; already transitive via Rails)

### Why

Regex-based Ruby source parsing was the #3 critical finding in the architecture audit: it breaks on heredocs, multi-line DSL calls, `class << self` blocks, and metaprogrammed constructs. Prism AST provides 100% syntax-level accuracy. The single-pass Dispatcher pattern means parsing a 500-line model file runs all 7 listeners in one tree walk — no repeated I/O or re-parsing. The confidence tagging gives AI agents explicit signal about what data is ground truth vs. what requires runtime verification.

## [5.1.0] — 2026-04-06

### Fixed

Accuracy fixes across 8 introspectors, eliminating false positives and capturing previously-missed signals. No public API changes; all 38 MCP tools retain their contracts.

- **ApiIntrospector** — pagination detection (`detect_pagination`) was substring-matching Gemfile.lock content, producing false positives on gems that merely contain the strategy name: `happypagy`, `kaminari-i18n`, transitive `pagy` dependencies. Now uses anchored lockfile regex (`^    pagy \(`) that only matches direct top-level dependencies. Same fix applied to `kaminari`, `will_paginate`, and `graphql-pro` detection.
- **DevOpsIntrospector** — health-check detection (`detect_health_check`) used an unanchored word regex (`\b(?:health|up|ping|status)\b`) that matched comments, controller names, and any line containing those words. Tightened to match only quoted route strings (`"/up"`, `"/healthz"`, `"/liveness"`, etc.) or the `rails_health_check` symbol. Also newly detects `/readiness`, `/alive`, and `/healthz` routes.
- **PerformanceIntrospector** — schema parsing (`parse_indexed_columns`) tracked table context with a boolean-ish `current_table` variable but never cleared it on `end` lines, so `add_index` statements after a `create_table` block matched both the inner block branch AND the outer branch, producing duplicate index entries. This polluted `missing_fk_indexes` analysis. Fixed via explicit `inside_create_table` state flag with block boundary detection. Also added `m` (multiline) flag to specific-association preload regex so `.includes(...)` calls spanning multiple lines are matched.
- **I18nIntrospector** — `count_keys_for_locale` only read `config/locales/{locale}.yml`, missing nested locale files that are the Rails convention for gem-added translations: `config/locales/devise.en.yml`, `config/locales/en/users.yml`, `config/locales/admin/en.yml`. New `find_locale_paths` method globs all YAML under `config/locales/**/*` and selects files whose basename equals the locale, ends with `.{locale}`, or lives under a `{locale}/` subfolder. In typical Rails apps this captures 2-10x more translation keys than the previous single-file read, making `translation_coverage` percentages meaningful.
- **JobIntrospector** — when a job class declared `queue_as ->(job) { ... }`, `job.queue_name` returned a Proc that was then called with no arguments, crashing or returning stale values. Now returns `"dynamic"` when queue is a Proc, matching the job's actual runtime behavior (queue is resolved per-invocation).
- **ModelIntrospector** — source-parsed class methods in `extract_source_class_methods` emitted a spurious `"self"` entry because `def self.foo` matched both the `def self.(\w+)` branch AND the generic `def (\w+)` branch inside `class << self` tracking. Restructured as `if/elsif` so each `def` line matches exactly one pattern. Also anchored `class << self` detection with `\b` to avoid partial-word matches.
- **RouteIntrospector** — `call` method could raise if `Rails.application.routes` was not yet loaded or a sub-method failed mid-extraction. Added a top-level rescue that returns `{ error: msg }`, matching the error contract used by every other introspector.
- **SeedsIntrospector** — `has_ordering` regex (`load.*order|require.*order|seeds.*\d+`) matched unrelated code like `require 'order'` or `seeds 001` in comments. Tightened to match actual ordering patterns: `Dir[...*.rb].sort`, `load "seeds/NN_foo.rb"`, `require_relative "seeds/NN_foo"`.

### Performance

- **ConventionIntrospector** — `gem_present?` was reading `Gemfile.lock` from disk 15 times per introspection pass (once per notable gem check). Memoized into a single read: **-93% I/O** (15 reads → 1 read). ~60% faster on typical apps.
- **ComponentIntrospector** — `build_summary` called `extract_components` again after `call` already computed it, doubling the filesystem walk and component parsing work. Now passes the result through: **-50% work**. ~50% faster.
- **GemIntrospector** — `categorize_gems(specs)` internally called `detect_notable_gems(specs)` after `call` had already called it, duplicating gem-list iteration and category lookup. Now accepts the notable-gem result directly: **-50% work**.
- **ActiveStorageIntrospector** — `uses_direct_uploads?` globbed `**/*` across `app/views` + `app/javascript`, reading every binary, image, font, and asset in those trees. Scoped to 9 relevant extensions (`erb,haml,slim,js,ts,jsx,tsx,mjs,rb`), avoiding wasteful I/O on irrelevant files.
- **Total**: ~14% cumulative speedup across all 12 modified introspectors on a medium-sized Rails app (23.66ms → 20.33ms).

### Why

Introspector output feeds every MCP tool response, every context file, and every rule file this gem generates. Silent inaccuracies (false-positive pagination detection, missed locale files, phantom duplicate indexes) compound: AI assistants make decisions based on this data, and incorrect data produces incorrect code suggestions. These fixes tighten the accuracy floor without changing any public interface.

## [5.0.0] — 2026-04-05

### Removed (BREAKING)

This release removes the Design & Styling surface and the Accessibility rule surface. When AI assistants consumed pre-digested design/styling context (color palettes, Tailwind class strings, canonical HTML/ERB snippets), they produced poor UI/UX output by blindly copying class strings instead of understanding visual hierarchy. The accessibility surface was asymmetric (Claude-only static rule file, no live MCP tool) and provided generic best-practice rules that didn't earn their keep.

**Design system:**
- **Removed `rails_get_design_system` MCP tool** — tool count is now **38** (was 39). Tool class `RailsAiContext::Tools::GetDesignSystem` deleted.
- **Removed `:design_tokens` introspector** — class `RailsAiContext::Introspectors::DesignTokensIntrospector` deleted.
- **Removed `ui_patterns`, `canonical_examples`, `shared_partials` keys** from `ViewTemplateIntrospector` output. The introspector now returns only `templates` and `partials`.
- **Removed `DesignSystemHelper` serializer module** — module `RailsAiContext::Serializers::DesignSystemHelper` deleted. Consumers no longer receive UI Patterns sections in rule files or compact output.
- **Removed `"design"` option** from the `include:` parameter of `rails_get_context`. Valid options are now: `schema`, `models`, `routes`, `gems`, `conventions`.

**Accessibility:**
- **Removed `:accessibility` introspector** — class `RailsAiContext::Introspectors::AccessibilityIntrospector` deleted. `ctx[:accessibility]` no longer populated.
- **Removed `discover_accessibility` cross-cut** from `rails_analyze_feature`. The tool no longer emits a `## Accessibility` section with per-feature a11y findings.
- **Removed Accessibility line** from root-file Stack Overview (no more "Accessibility: Good/OK/Needs work" label).

**Preset counts:** `:full` is now **31** (was 33); `:standard` is now **17** (was 19). Both lost `:design_tokens` and `:accessibility`.

**Legacy rule files no longer generated:**
- `.claude/rules/rails-ui-patterns.md`
- `.cursor/rules/rails-ui-patterns.mdc`
- `.github/instructions/rails-ui-patterns.instructions.md`
- `.claude/rules/rails-accessibility.md`

### Migration notes

- **Legacy files are NOT auto-deleted.** On first run after upgrade (via `rake ai:context`, `rails-ai-context context`, install generator, or watcher), the gem detects stale `rails-ui-patterns.*` and `rails-accessibility.md` files and prompts interactively in TTY sessions, or warns (non-destructive) in non-TTY sessions. Answer `y` to remove, or delete the files manually.
- **If you depended on `rails_get_design_system`**, replace with `rails_get_component_catalog` (component-based) or read view files directly with `rails_read_file` / `rails_search_code`.
- **If you depended on `include: "design"`** in `rails_get_context`, remove that option.
- **If you depended on `ctx[:accessibility]`** (custom tools / serializers), that key is gone. Use standard a11y linters (axe-core, lighthouse) in your test suite instead.
- **The "Build or modify a view" workflow** in tool guides now starts with `rails_get_component_catalog` instead of `rails_get_design_system`.

### Why

AI assistants that consume pre-digested summaries produce worse output than AI that reads actual source files. For design systems, class-string copying defeats the mental model required for cohesive visual hierarchy. For accessibility, generic rules ("add alt text") are universal knowledge that AI already has — the static counts didn't add actionable context, and the asymmetric distribution (Claude-only rule file, no live tool) was incoherent with the gem's charter. The gem's charter is ground truth for Rails structure (schema, associations, routes, controllers) — design-system and accessibility summaries were adjacent to that charter and actively counterproductive or inert.

## [4.7.0] — 2026-04-05

### Added
- **Anti-Hallucination Protocol** — 6-rule verification section embedded in every generated context file (CLAUDE.md, AGENTS.md, .claude/rules/, .cursor/rules/, .github/instructions/, copilot-instructions.md). Targets specific AI failure modes: statistical priors overriding observed facts, pattern completion beating verification, inheritance blindness, empty-output-as-permission, stale-context-lies. Rules force AI to verify column/association/route/method/gem names before writing, mark assumptions with `[ASSUMPTION]` prefix, check inheritance chains, and re-query after writes. Enabled by default via new `config.anti_hallucination_rules` option (boolean, default: `true`). Set `false` to skip.

### Changed
- **Repositioning: ground truth, not token savings** — the gem's mission is now explicit about what it actually does: stop AI from guessing your Rails app. Token savings are a side-effect, not the product. Updated README headline, "What stops being wrong" section (replaces "Measured token savings"), gemspec summary/description, server.json MCP registry description, docs/GUIDE.md intro, and the tools guide embedded in every generated CLAUDE.md/AGENTS.md/.cursor/rules. The core pitch: AI queries your running app for real schema, real associations, real filters — and writes correct code on the first try instead of iterating through corrections.

## [4.6.0] — 2026-04-04

### Added
- **Integration test suite** — 3 purpose-built Rails 8 apps exercising every gem feature end-to-end:
  - `full_app` — comprehensive app (38 gems, 14 models, 15 controllers, 26 views, 5 jobs, 3 mailers, multi-database, ViewComponent, Stimulus, STI, polymorphic, AASM, PaperTrail, FriendlyId, encrypted attributes, CurrentAttributes, Flipper feature flags, Sentry monitoring, Pundit auth, Ransack search, Dry-rb, acts_as_tenant, Docker, Kamal, GitHub Actions CI, RSpec + FactoryBot)
  - `api_app` — API-only app (Products/Orders/OrderItems, namespaced API v1 routes, CLI tool_mode)
  - `minimal_app` — bare minimum app (single model, graceful degradation testing)
- **Master test runner** (`test_apps/run_all_tests.sh`) — validates Doctor, context generation, all 33 introspectors, all 39 MCP tools, Rake tasks, MCP server startup, and app-specific pattern detection across all 3 apps (222 tests)
- All 3 test apps achieve **100/100 AI Readiness Score**

### Fixed
- **Standalone CLI `full_gem_path` crash** — `Gem.loaded_specs.delete_if { |_, spec| !spec.default_gem? }` in the exe file cleared gem specs needed by MCP SDK at runtime (`json-schema` gem's `full_gem_path` returned nil). Added `!ENV["BUNDLE_BIN_PATH"]` guard so cleanup only runs in true standalone mode, not under `bundle exec`. This bug affected ALL `rails-ai-context tool` commands in standalone mode.

### Changed
- Test count: 1621 RSpec examples + 222 integration tests across 3 apps

## [4.5.2] — 2026-04-04

### Added
- **Strong params permit list extraction** — Controller introspector now parses `params.require(:x).permit(...)` calls, returning structured hashes with `requires`, `permits`, `nested`, `arrays`, and `unrestricted` fields. Handles multi-line chains, hash rocket syntax, and `params.permit!` detection
- **N+1 risk levels** — PerformanceCheck now classifies N+1 risks as `[HIGH]` (no preloading), `[MEDIUM]` (partial preloading), or `[low]` (already preloaded). Detects loop patterns in controller actions, recognizes `.includes`/`.eager_load`/`.preload`, and reports per-action context
- **DependencyGraph polymorphic/through/cycles/STI** — `show_cycles` param detects circular dependencies via DFS. `show_sti` param groups STI hierarchies. Polymorphic associations resolve concrete types. Through associations render as two-hop edges. Mermaid: dashed arrows for polymorphic, double arrows for through, dotted for STI
- **Query EXPLAIN support** — New `explain` boolean param wraps SELECT in adapter-specific EXPLAIN (PostgreSQL JSON ANALYZE, MySQL EXPLAIN, SQLite EXPLAIN QUERY PLAN). Parses scan types, indexes, and warnings. Skips row limits for metadata output
- **GetConfig Rails API integration** — Assets detection now uses FrontendFrameworkIntrospector data instead of regex-parsing package.json. Action Cable uses Rails config API with YAML fallback. New Active Storage service and Action Mailer delivery method detection
- **Standardized pagination** — `BaseTool.paginate(items, offset:, limit:, default_limit:)` returns `{ items:, hint:, total:, offset:, limit: }`. Adopted across 7 tools: GetControllers, GetModelDetails, GetRoutes, SearchCode, GetGems, GetHelperMethods, GetComponentCatalog. New `offset`/`limit` params added to GetGems, GetHelperMethods, GetComponentCatalog, SearchCode
- `RailsAiContext::SafeFile` module — safe file reading with configurable size limits, encoding handling, and error suppression
- `RailsAiContext::MarkdownEscape` module — escapes markdown special characters in dynamic content interpolated into headings and prose
- **Provider API key redaction** — ReadLogs now redacts Stripe, SendGrid, Slack, GitHub, GitLab, and npm token patterns

### Fixed
- **Middleware crash protection** — MCP HTTP middleware now rescues exceptions and returns a proper JSON-RPC 2.0 error (`-32603 Internal error`) instead of crashing the Rails request pipeline
- **File read size limits** — Replaced 150+ unguarded `File.read` calls across all introspectors and tools with `SafeFile.read` to prevent OOM on oversized files
- **Cache race condition** — `BaseTool.cached_context` now returns a `deep_dup` of the shared cache, preventing concurrent MCP requests from mutating shared data structures
- **Silent failure warnings** — Introspector failures now propagate as `_warnings` to serializer output; AI clients see a `## Warnings` section listing which sections were unavailable and why
- **Markdown escaping** — Dynamic content in generated markdown is now escaped to prevent formatting corruption from special characters
- **GetConcern nil crash** — Added nil guard for `SafeFile.read` return value
- **GenerateTest type coercion** — Fixed `max + 1` crash when `maximum:` validation stored as string
- **Standalone Bundler conflict** — Resolved gem activation conflict in standalone mode
- **CLI error messages** — Clean error messages for all CLI error paths
- **Rake/init parity** — `rake ai:context` and `init` command now match generator output

### Refactored
- **SLOP audit: ~640 lines removed** — comprehensive audit eliminating superfluous abstractions, dead code, and duplicated patterns
- **CompactSerializerHelper** — extracted shared logic from ClaudeSerializer and OpencodeSerializer, eliminating ~75% duplication
- **StackOverviewHelper consolidation** — moved `project_root`, `detect_service_files`, `detect_job_files`, `detect_before_actions`, `scope_names`, `notable_gems_list`, `arch_labels_hash`, `pattern_labels_hash`, `write_rule_files` into shared module, replacing 30+ duplicate copies across 6 serializers
- **Atomic file writes** — `write_rule_files` uses temp file + rename for crash-safe context file generation
- **ConventionDetector → ConventionIntrospector** — renamed for naming consistency with all 33 other introspectors
- **MarkdownEscape inlined** — single-use module inlined into MarkdownSerializer as private method
- **RulesSerializer deleted** — dead code never called by ContextFileSerializer
- **BaseTool cleanup** — removed dead `auto_compress`, `app_size`, `session_queried?` methods
- **IntrospectionError deleted** — exception class never raised anywhere
- **mobile_paths config removed** — config option never read by any introspector, tool, or serializer
- **server_version** — changed from attr_accessor to method delegating to `VERSION` constant
- **Configuration constants** — extracted `DEFAULT_EXCLUDED_FILTERS`, `DEFAULT_EXCLUDED_MIDDLEWARE`, `DEFAULT_EXCLUDED_CONCERNS` as frozen constants
- **Detail spec consolidation** — merged 5 detail spec files into their base spec counterparts
- **Orphaned spec cleanup** — removed `gem_introspector_spec.rb` duplicate (canonical spec already exists under introspectors/)

### Changed
- Test count: 1621 examples (consolidated from 1658 — no coverage lost, only duplicate/orphaned specs removed)

## [4.4.0] — 2026-04-03

### Added
- **33 introspector enhancements** — every introspector upgraded with new detection capabilities:
  - **SchemaIntrospector**: expression indexes, column comments in static parse, `change_column_default`/`change_column_null` in migration replay
  - **ModelIntrospector**: STI hierarchy detection (parent/children/type column), `attribute` API, enum `_prefix:`/`_suffix:`, `after_commit on:` parsing, inline `private def` exclusion
  - **RouteIntrospector**: route parameter extraction, root route detection, RESTful action flag
  - **JobIntrospector**: SolidQueue recurring job config, Sidekiq config (concurrency/queues), job callbacks (`before_perform`, `around_enqueue`, etc.)
  - **GemIntrospector**: path/git gems from Gemfile, gem group extraction (dev/test/prod)
  - **ConventionDetector**: multi-tenant (Apartment/ActsAsTenant), feature flags (Flipper/LaunchDarkly), error monitoring (Sentry/Bugsnag/Honeybadger), event-driven (Kafka/RabbitMQ/SNS), Zeitwerk detection, STI with type column verification
  - **ControllerIntrospector**: `rate_limit` parsed into structured data (to/within/only), inline `private def` exclusion
  - **StimulusIntrospector**: lifecycle hooks (connect/disconnect/initialize), outlet controller type mapping, action bindings from views (`data-action` parsing)
  - **ViewIntrospector**: `yield`/`content_for` extraction from layouts, conditional layout detection with only/except
  - **TurboIntrospector**: stream action semantics (append/update/remove counts), frame `src` URL extraction
  - **I18nIntrospector**: locale fallback chain detection, locale coverage % per locale
  - **ConfigIntrospector**: cache store options, error monitoring gem detection, job processor config (Sidekiq queues/concurrency)
  - **ActiveStorageIntrospector**: attachment validations (content_type/size), variant definitions
  - **ActionTextIntrospector**: Trix editor customization detection (toolbar/attachment/events)
  - **AuthIntrospector**: OmniAuth provider detection, Devise settings (timeout/lockout/password_length)
  - **ApiIntrospector**: GraphQL resolvers/subscriptions/dataloaders, API pagination strategy detection
  - **TestIntrospector**: shared examples/contexts detection, database cleaner strategy
  - **RakeTaskIntrospector**: task dependencies (`=> :prerequisite`), task arguments (`[:arg1, :arg2]`)
  - **AssetPipelineIntrospector**: Bun bundler, Foundation CSS, PostCSS standalone detection
  - **DevOpsIntrospector**: Fly.io/Render/Railway deployment detection, `docker-compose.yaml` support
  - **ActionMailboxIntrospector**: mailbox callback detection (before/after/around_processing)
  - **MigrationIntrospector**: `change_column_default`, `change_column_null`, `add_check_constraint` action detection
  - **SeedsIntrospector**: CSV loader detection, seed ordering detection
  - **MiddlewareIntrospector**: middleware added via initializers (`config.middleware.use/insert_before`)
  - **EngineIntrospector**: route count + model count inside discovered engines
  - **MultiDatabaseIntrospector**: shard names/keys/count from `connects_to`, improved YAML parsing for nested multi-db configs
  - **ComponentIntrospector**: `**kwargs` splat prop detection
  - **AccessibilityIntrospector**: heading hierarchy (h1-h6), skip link detection, `aria-live` regions, form input analysis (required/types)
  - **PerformanceIntrospector**: polymorphic association compound index detection (`[type, id]`)
  - **FrontendFrameworkIntrospector**: API client detection (Axios/Apollo/SWR/etc.), component library detection (MUI/Radix/shadcn/etc.)
  - **DatabaseStatsIntrospector**: MySQL + SQLite support (was PostgreSQL-only), PostgreSQL dead row counts
  - **ViewTemplateIntrospector**: slot reference detection
  - **DesignTokenIntrospector**: Tailwind arbitrary value extraction

### Fixed
- **Security: SQLite SQL injection** — `database_stats_introspector` used string interpolation for table names in COUNT queries; now uses `conn.quote_table_name`
- **Security: query column redaction bypass** — `SELECT password AS pwd` bypassed redaction; now also matches columns ending in `password`, `secret`, `token`, `key`, `digest`, `hash`
- **Security: log redaction gaps** — added AWS access key (`AKIA...`), JWT token (`eyJ...`), and SSH/TLS private key header patterns
- **Security: HTTP bind wildcard** — non-loopback warning now catches `0.0.0.0` and `::` (was only checking 3 specific addresses)
- **Thread safety: `app_size()` race condition** — `SHARED_CACHE[:context]` read without mutex; now wrapped in `SHARED_CACHE[:mutex].synchronize`
- **Crash: nil callback filter** — `model_introspector` `cb.filter.to_s` crashed on nil filters; added `cb.filter.nil?` guard
- **Crash: fingerprinter TOCTOU** — `File.mtime` after `File.exist?` could raise `Errno::ENOENT` if file deleted between calls; added rescue
- **Crash: tool_runner bounds** — `args[i+1]` access without bounds check; added `i + 1 < args.size` guard
- **Bug: server logs wrong tool list** — logged all 39 `TOOLS` instead of filtered `active_tools` after `skip_tools`; now shows correct count and names
- **Bug: STI false positive** — convention detector flagged `Admin < User` as STI even without `type` column; now verifies parent's table has `type` column via schema.rb
- **Bug: resources bare raise** — `raise "Unknown resource"` changed to `raise RailsAiContext::Error`
- **Config validation** — `http_port` (1-65535), `cache_ttl` (> 0), `max_tool_response_chars` (> 0), `query_row_limit` (1-1000) now validated on assignment

### Changed
- Test count: 1529 (unchanged — all new features tested via integration test against sample app)

## [4.3.3] — 2026-04-02

### Fixed
- **100 bare rescue statements across 46 files** — all replaced with `rescue => e` + conditional debug logging (`$stderr.puts ... if ENV["DEBUG"]`); errors are now visible instead of silently swallowed
- **database_stats introspector orphaned** — `DatabaseStatsIntrospector` was unreachable (not in any preset); added to `:full` preset (32 → 33 introspectors)
- **CHANGELOG date errors** — v4.0.0 corrected from 2026-03-26 to 2026-03-27, v4.2.0 from 2026-03-26 to 2026-03-30 (verified against git commit timestamps)
- **CHANGELOG missing v3.0.1 entry** — added (RubyGems republish, no code changes)
- **CHANGELOG date separator inconsistency** — normalized all 61 version entries to em dash (`—`)
- **Documentation preset counts** — CLAUDE.md, README, GUIDE all corrected: `:full` 32→33, `:standard` 14→19 (turbo, auth, accessibility, performance, i18n were added in v4.3.1 but docs not updated)
- **GUIDE.md standard preset table** — added 5 missing introspectors (turbo, auth, accessibility, performance, i18n) to match `configuration.rb`

### Changed
- Full preset: 32 → 33 introspectors (added :database_stats)

## [4.3.2] — 2026-04-02

### Fixed
- **review_changes undefined variable** — `changed_tests` (NameError at runtime) replaced with correct `test_files` variable in `detect_warnings`
- **N+1 introspector O(n*m*k) view scan** — `detect_n_plus_one` now pre-loads all view file contents once via `preload_view_contents` instead of re-globbing per model+association pair
- **atomic write collision** — temp filenames now include `SecureRandom.hex(4)` suffix to prevent concurrent process collisions on the same file
- **bare rescue; end across 7 serializers + 2 tools** — all 16 occurrences replaced with `rescue => e` + stderr logging so errors are visible instead of silently swallowed

### Changed
- Test count: 1176 → 1529 (+353 new tests)
- 26 new spec files covering previously untested tools, serializer helpers, introspectors, and infrastructure (server, engine, resources, watcher)

## [4.3.1] — 2026-04-02

### Fixed
- **performance_check false positives** — now parses `t.index` inside `create_table` blocks (was only parsing `add_index` outside blocks, missing inline indexes)
- **review_changes overflow** — capped at 20 files with 30 diff lines each; remaining files listed without diff to prevent 200K+ char responses
- **get_context ivar cross-check** — now follows `render :other_template` references (create rendering :new on failure no longer shows false positives)
- **generate_test setup block** — always generates `setup do` with factory/fixture/inline fallback; minitest tests no longer reference undefined instance variables
- **session_context auto-tracking** — `text_response()` now auto-records every tool call; `session_context(action:"status")` shows what was queried without manual `mark:` calls
- **search_code AI file exclusion** — excludes CLAUDE.md, AGENTS.md, .claude/, .cursor/, .cursorrules, .github/copilot-instructions.md, .ai-context.json from results
- **diagnose output truncation** — per-section size limits (3K chars each) + total output cap (20K) prevent overflow
- **diagnose NameError classification** — `NameError: uninitialized constant` now correctly classified as `:name_error`, not `:nil_reference`
- **diagnose specific inference** — identifies nil receivers, missing `authenticate_user!`, and `set_*` before_actions from code context
- **onboard purpose inference** — quick mode now infers app purpose from models, jobs, services, gems (e.g., "news aggregation app with RSS, YouTube, Reddit ingestion")
- **onboard adapter resolution** — resolves `static_parse` adapter name from config or gems instead of showing internal implementation detail
- **security_scan transparency** — "no warnings" response now lists which check categories were run (e.g., "SQL injection, XSS, mass assignment")
- **read_logs filename filter** — `available_log_files` now rejects filenames with non-standard characters
- **Phlex view support** — get_view detects Phlex views (.rb), extracts component renders and helper calls
- **Component introspector Phlex** — discovers Phlex components alongside ViewComponent
- **Schema introspector array columns** — detects PostgreSQL `array: true` columns from schema.rb
- **search_code regex injection** — `definition` and `class` match types now escape user input with `Regexp.escape` (previously raw interpolation could crash with metacharacters like `(`, `[`, `{`)
- **sensitive file bypass on macOS** — all 3 `sensitive_file?` implementations now use `FNM_CASEFOLD` flag; `.ENV`, `Master.Key`, `.PEM` variants no longer bypass the block on case-insensitive filesystems
- **doctor silent exception swallowing** — `rescue nil` replaced with `rescue StandardError` + stderr logging; broken health checks are now reported instead of silently skipped
- **context file race condition** — `write_plain` and `write_with_markers` now use atomic write (temp file + rename) to prevent partial writes from concurrent generators
- **performance_introspector O(n*m) scan** — `detect_model_all_in_controllers` now builds a single combined regex instead of scanning each controller once per model
- **HTTP transport non-loopback warning** — MCP server now logs a warning when `http_bind` is set to a non-loopback address (no authentication on the HTTP transport)

### Added
- **`rails_runtime_info`** — live runtime state: DB connection pool, table sizes (PG/MySQL/SQLite), pending migrations, cache stats (Redis hit rate + memory), Sidekiq queue depth, job adapter detection
- **`rails_session_context`** — session-aware context tracking with auto-recording; `action:"status"` shows what tools were called, `action:"summary"` for compressed recap, `action:"reset"` to clear
- **`auto_compress` helper** — BaseTool method that auto-downgrades detail when response approaches 85% of max chars
- **`not_found_response` dedup** — no longer suggests the exact same string the user typed
- **get_frontend_stack Hotwire** — reports Stimulus controllers, Turbo config, importmap pins for Hotwire/importmap apps (not just React/Vue)
- **get_component_catalog guidance** — returns actionable message for partial-based apps: "Use get_partial_interface or get_view"
- **get_context feature enrichment** — `feature:` mode now also searches controllers and services by name when analyze_feature misses them
- **Fingerprinter gem development** — includes gem lib/ directory mtime when using path gem (local dev cache invalidation)

### Changed
- Tool count: 37 → 39
- Test count: 1052 → 1170
- Standard preset now includes turbo, auth, accessibility, performance, i18n (was 14 introspectors, now 19)

## [4.3.0] — 2026-04-01

### Added
- **`rails_onboard`** — narrative app walkthrough (quick/standard/full)
- **`rails_generate_test`** — test scaffolding matching project patterns
- **`rails_diagnose`** — one-call error diagnosis with classification + context + git + logs
- **`rails_review_changes`** — PR/commit review with per-file context + warnings
- **Improved AI instructions** — workflow sequencing, detail guidance, anti-patterns, get_context as power tool

### Changed
- Tool count: 33 → 37
- Test count: 1016 → 1052

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

## [4.2.0] — 2026-03-30

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
- `migration_advisor` doesn't normalize table names — "Post" now auto-resolves to "posts"
- `migration_advisor` no duplicate column/index detection — now warns on existing columns, indexes, and FKs
- `migration_advisor` no nonexistent column detection — now warns on remove/rename/change_type/add_index for missing columns
- `edit_context` "File not found" with no hint — now suggests full path with "Did you mean?"
- `performance_check` model filter fails for multi-word models — "UserProfile" now resolves to "user_profiles"
- `performance_check` unknown model silently ignored — now returns "not found" with suggestions
- `turbo_map` stream filter misses dynamic broadcasts — multi-line call handling + snippet fallback + fuzzy prefix matching
- `turbo_map` controller filter misses job broadcasts — now includes broadcasts matching filtered subscriptions' streams
- `security_scan` wrong check name examples — added CHECK_ALIASES mapping (CheckXSS → CheckCrossSiteScripting, sql → CheckSQL, etc.)
- `search_code` unknown match_type silently ignored — now returns error with valid values
- `validate` unknown level silently ignored — now returns error with valid values
- `get_view` no "Did you mean?" on wrong controller — now uses `find_closest_match`
- `get_context` plural model name ("Posts") produces mixed output — now normalizes via singularize/classify, fails fast when not found
- `component_catalog` specific component returns generic "no components" — now acknowledges the input
- `stimulus` doesn't strip `_controller` suffix — now auto-strips for lookup
- `controller_introspector_spec` rate_limit test crashes on Rails 7.1 — split into source-parsing test (no class loading)

### Changed
- Full preset: 31 → 32 introspectors (added :frontend_frameworks)
- Tool count: 29 → 30
- Test count: 817 → 893
- Install generator always writes `config.ai_tools` and `config.tool_mode` uncommented for re-install detection

## [4.0.0] — 2026-03-27

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

## [3.1.0] — 2026-03-26

### Fixed

- **Consistent input normalization across all tools** — AI agents and humans can now use any casing or format and tools resolve correctly:
  - `model=user_profile` (snake_case) now resolves to `UserProfile` via `.underscore` comparison in `get_model_details`.
  - `table=Post` (model name) now resolves to `posts` table via `.underscore.pluralize` normalization in `get_schema`.
  - `controller=PostsController` now works in `get_view` and `get_routes` — both strip `Controller`/`_controller` suffix consistently, matching `get_controllers` behavior.
  - `controller=posts_controller` no longer leaves a trailing underscore in route matching.
  - `stimulus=PostStatus` (PascalCase) now resolves to `post_status` via `.underscore` conversion in `get_stimulus`.
  - `partial=_status_badge` (underscore-prefixed, no directory) now searches recursively across all view directories in `get_partial_interface`.
  - `model=posts` (plural) now tries `.singularize` for test file lookup in `get_test_info`.
- **Smarter fuzzy matching** — `BaseTool.find_closest_match` now prefers shortest substring match (so `Post` suggests `posts`, not `post_comments`) and supports underscore/classify variant matching.
- **File path suggestions in validate** — `files=["post.rb"]` now suggests `app/models/post.rb` when the file isn't found at the given path.
- **Empty parameter validation** — `edit_context` now returns friendly messages for empty `file` or `near` parameters instead of hard errors.

## [3.0.1] — 2026-03-26

### Changed
- Patch for RubyGems publish — no code changes from v3.0.0.

## [3.0.0] — 2026-03-26

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

## [2.0.5] — 2026-03-25

### Changed

- **Task-based MCP tool instructions** — all 6 serializers (Claude, Cursor, Copilot, Windsurf, OpenCode) rewritten from tool-first to task-first: "What are you trying to do?" → exact tool call. 7 task categories: understand a feature, trace a method, add a field, fix a controller, build a view, write tests, find code. Every AI agent now understands which tool to use for any task.
- **Concern detail:"full" bug fix** — `\b` after `?`/`!` prevented 13 of 15 method bodies from being extracted. All methods now show source code.

## [2.0.4] — 2026-03-25

### Added

- **Orphaned table detection** — `get_schema` standard mode flags tables with no ActiveRecord model: "⚠ Orphaned tables: content_calendars, post_comments"
- **Concern method source code** — `get_concern(name:"X", detail:"full")` shows method bodies inline, same pattern as callbacks tool.
- **analyze_feature: inherited filters** — shows `authenticate_user! (from ApplicationController)` in controller section.
- **analyze_feature: code-ready route helpers** — `post_path(@record)`, `posts_path` inline with routes.
- **analyze_feature: service test gaps** — checks services for missing test files, not just models/controllers/jobs.
- **All 6 serializers updated** — Claude, Cursor, Copilot, Windsurf, OpenCode all document trace mode, concern source, orphaned tables, inherited filters.

## [2.0.3] — 2026-03-25

### Added

- **Trace mode 100%** — `match_type:"trace"` now shows 7 sections: definition with class/module context, source code, internal calls, sibling methods (same file), app callers with route chain hints, and test coverage (separated from app code). Zero follow-up calls needed.
- **README rewrite** — neuro marketing techniques: loss aversion hook, measured token savings table, trace output inline, architecture diagram. 456→261 lines.

## [2.0.2] — 2026-03-25

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

## [2.0.1] — 2026-03-25

### Fixed

- **MCP-first mandatory workflow in all serializers** — all 6 serializer outputs (Claude, Cursor, Copilot, Windsurf, OpenCode) now use "MANDATORY, Use Before Read" language with structured workflow, anti-patterns table, and "Do NOT Bypass" rules. AI agents are explicitly instructed to never read reference files directly.
- **27 type-safety bugs in serializers** — fixed `.keys` called on Array values (same pattern as #14) across `design_system_helper.rb`, `get_design_system.rb`, `markdown_serializer.rb`, and `stack_overview_helper.rb`.
- **Strong params JSONB check** — no longer skips the entire check when JSONB columns exist. Plain-word params allowed (could be JSON keys), `_id` params still validated.
- **Strong params test skip on Ruby < 3.3** — test now skips gracefully when Prism is unavailable, matching the tool's own degradation.
- **Issue #14** — `multi_db[:databases].keys` crash on Array fixed.
- **Search code NON_CODE_GLOBS** — excludes lock files, docs, CI configs, generated context from all searches.

## [2.0.0] — 2026-03-24

### Added

- **9 new MCP tools (16→25)** — `rails_get_concern` (concern methods + includers), `rails_get_callbacks` (execution order + source), `rails_get_helper_methods` (app + framework helpers + view refs), `rails_get_service_pattern` (interface, deps, side effects), `rails_get_job_pattern` (queue, retries, guards, broadcasts), `rails_get_env` (env vars, credentials keys, external services), `rails_get_partial_interface` (locals contract + usage), `rails_get_turbo_map` (stream/frame wiring + mismatch warnings), `rails_get_context` (composite cross-layer tool).
- **Phase 1 improvements** — scope definitions include lambda body, controller actions show instance variables + private methods called inline, Stimulus shows HTML data-attributes + reverse view lookup.
- **3 new validation rules** — instance variable consistency (view uses @foo but controller never sets it), Turbo Stream channel matching (broadcast without subscriber), respond_to template existence.
- **`rails_security_scan` tool** — Brakeman static security analysis via MCP. Detects SQL injection, XSS, mass assignment, and more. Optional dependency — returns install instructions if Brakeman isn't present. Supports file filtering, confidence levels (high/medium/weak), specific check selection, and three detail levels (summary/standard/full).
- **`config.skip_tools`** — users can now exclude specific built-in tools: `config.skip_tools = %w[rails_security_scan]`. Defaults to empty (all 39 tools active).
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

## [1.3.1] — 2026-03-23

### Fixed

- **Documentation audit** — updated tool count from 14 to 15 across README, GUIDE, CONTRIBUTING, server.json. Added `rails_get_design_system` documentation section to GUIDE.md. Updated SECURITY.md supported versions. Fixed spec count in CLAUDE.md. Added `rails_get_design_system` to README tool table. Updated `rails_analyze_feature` description to reflect full-stack discovery (services, jobs, views, Stimulus, tests, related models, env deps).
- **analyze_feature crash on complex models** — added type guards (`is_a?(Hash)`, `is_a?(Array)`) to all data access points preventing `no implicit conversion of Symbol into Integer` errors on models with many associations or complex data.

## [1.3.0] — 2026-03-23

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

## [1.2.1] — 2026-03-23

### Fixed

- **New models now discovered via filesystem fallback** — when `ActiveRecord::Base.descendants` misses a newly created model, the introspector scans `app/models/*.rb` and constantizes them. Fixes model invisibility until MCP restart.
- **Devise meta-methods no longer fill class/instance method caps** — filtered 40+ Devise-generated methods (authentication_keys=, email_regexp=, password_required?, etc.). Source-defined methods now prioritized over reflection-discovered ones.
- **Controller `unless:`/`if:` conditions now extracted** — filters like `before_action :authenticate_user!, unless: :devise_controller?` now show the condition. Previously silently dropped.
- **Empty string defaults shown as `""`** — schema tool now renders `""` instead of a blank cell for empty string defaults. AI can distinguish "no default" from "empty string default".
- **Implicit belongs_to validations labeled** — `presence on user` from `belongs_to :user` now shows `_(implicit from belongs_to)_` and filters phantom `(message: required)` options.
- **Array columns shown as `type[]`** in generated rules — `string` columns with `array: true` now render as `string[]` in schema rules.
- **External ID columns no longer hidden** — columns like `stripe_checkout_id` and `stripe_payment_id` are now shown in schema rules. Only conventional Rails FK columns (matching a table name) are filtered.
- **Column defaults shown in generated rules** — columns with non-nil defaults now show `(=value)` inline.
- **`analyze_feature` matches models by table name and underscore form** — `feature:"share"` now finds `PostShare` (via `post_shares` table and `post_share` underscore form), not just exact model name substring.

## [1.2.0] — 2026-03-23

### Added

- **Design system extraction** — ViewTemplateIntrospector now extracts canonical page examples (real HTML/ERB snippets from actual views), full color palette with semantic roles (primary/danger/success/warning), typography scale (sizes, weights, heading styles), layout patterns (containers, grids, spacing scale), responsive breakpoint usage, interactive state patterns (hover/focus/active/disabled), dark mode detection, and icon system identification.
- **New MCP tool: `rails_get_design_system`** — dedicated tool (15th) returns the app's design system: color palette, component patterns with real HTML examples, typography, layout conventions, responsive breakpoints. Supports `detail` parameter (summary/standard/full). Total MCP tools: 15.
- **DesignSystemHelper serializer module** — replaces flat component listings with actionable design guidance across all output formats (Claude, Cursor, Windsurf, Copilot, OpenCode). Shows components with semantic roles, canonical page examples in split rules, and explicit design rules.
- **DesignTokenIntrospector semantic categorization** — tokens now grouped into colors/typography/spacing/sizing/borders/shadows. Enhanced Tailwind v3 parsing for fontSize, spacing, borderRadius, and screens.

### Changed

- **"UI Patterns" section renamed to "Design System"** — richer content with color palette, typography, components, spacing conventions, interactive states, and design rules.
- **Design tokens consumed for the first time** — `context[:design_tokens]` data was previously extracted but never rendered. Now merged into design system output in all serializers and the new MCP tool.

## [1.1.1] — 2026-03-23

### Added

- **Full-preset stack overview in all serializers** — compact mode now surfaces summary lines for auth, Hotwire/Turbo, API, I18n, ActiveStorage, ActionText, assets, engines, and multi-database in generated context files (CLAUDE.md, AGENTS.md, .windsurfrules, and all split rules). Previously this data was only available via MCP tools.
- **`rails_analyze_feature` in all tool reference sections** — the 14th tool (added in v1.0.0) was missing from serializer output. Now listed in all generated files across Claude, Cursor, Windsurf, Copilot, and OpenCode formats.

### Fixed

- **Tool count corrected from 13 to 14** across all serializers to reflect `rails_analyze_feature` added in v1.0.0.

## [1.1.0] — 2026-03-23

### Changed

- **Default preset changed to `:full`** — all 28 introspectors now run by default, giving AI assistants richer context out of the box. Introspectors that don't find relevant data return empty hashes with zero overhead. Use `config.preset = :standard` for the previous 13-core default.

## [1.0.0] — 2026-03-23

### Added

- **New composite tool: `rails_analyze_feature`** — one call returns schema + models + controllers + routes for a feature area (e.g., `rails_analyze_feature(feature:"authentication")`). Total MCP tools: 14.
- **Custom tool registration API** — `config.custom_tools << MyCompany::PolicyCheckTool` lets teams extend the MCP server with their own tools.
- **Structured error responses with fuzzy suggestions** — `not_found_response` helper in BaseTool with "Did you mean?" fuzzy matching (substring + prefix) and `recovery_action` hints. Applied to schema, models, controllers, and stimulus lookups. AI agents self-correct on first retry.
- **Cache keys on paginated responses** — every paginated response includes `cache_key` from fingerprint so agents detect stale data between page fetches. Applied to schema, models, controllers, and stimulus pagination.

### Changed

- **LLM-optimized tool descriptions (all 14 tools)** — every description now follows "what it does / Use when: / key params" format so AI agents pick the right tool on first try.

## [0.15.10] — 2026-03-23

### Changed

- **Gemspec description rewritten** — repositioned from feature list to value proposition: mental model, semantic validation, cross-file error detection.

## [0.15.9] — 2026-03-23

### Added

- **Deep diagnostic checks in `rails ai:doctor`** — upgraded from 13 shallow file-existence checks to 20 deep checks: pending migrations, context file freshness, .mcp.json validation, introspector health (dry-runs each one), preset coverage (detects features not in preset), .env/.master.key gitignore check, auto_mount production warning, schema/view size vs limits.

## [0.15.8] — 2026-03-23

### Added

- **Semantic validation (`level:"rails"`)** — `rails_validate` now supports `level:"rails"` for deep semantic checks beyond syntax: partial existence, route helper validity, column references vs schema, strong params vs schema columns, callback method existence, route-action consistency, `has_many` dependent options, missing FK indexes, and Stimulus controller file existence.

## [0.15.7] — 2026-03-22

### Improved

- **Hybrid filter extraction** — controller filters now use reflection for complete names (handles inheritance + skips), with source parsing from the inheritance chain for only/except constraints.
- **Callback source fallback** — when reflection returns nothing (e.g. CI), falls back to parsing callback declarations from model source files.
- **ERB validation accuracy** — in-process compilation with `<%=` → `<%` pre-processing and yield wrapper eliminates false positives from block-form helpers.
- **Schema static parser** — now extracts `null: false`, `default:`, `array: true` from schema.rb columns, and parses `add_foreign_key` declarations.
- **Array column display** — schema tool shows PostgreSQL array types as `string[]`, `integer[]`, etc.
- **Concern test lookup** — `rails_get_test_info(model:"PlanLimitable")` searches concern test paths.
- **Controller flexible matching** — underscore-based normalization handles CamelCase, snake_case, and slash notation consistently.

## [0.15.6] — 2026-03-22

### Added

- **7 new configurable options** — `excluded_controllers`, `excluded_route_prefixes`, `excluded_concerns`, `excluded_filters`, `excluded_middleware`, `search_extensions`, `concern_paths` for stack-specific customization.
- **Configurable file size limits** — `max_file_size`, `max_test_file_size`, `max_schema_file_size`, `max_view_total_size`, `max_view_file_size`, `max_search_results`, `max_validate_files` all exposed via `Configuration`.
- **Class methods in model detail** — `rails_get_model_details` now shows class methods section.
- **Custom validate methods** — `validate :method_name` calls extracted from source and shown in model detail.

### Fixed

- **Schema defaults always visible** — Null and Default columns always shown (NOT NULL marked bold). Previous token-saving logic accidentally hid critical migration data.
- **Optional associations** — `belongs_to` with `optional: true` now shows `[optional]` flag.
- **Concern methods inline** — shows public methods from concern source files (e.g. `Publishable — publishable?, publish!`).
- **MCP tool error messages** — all tools now show available values on error/not-found for AI self-correction.

## [0.15.5] — 2026-03-22

### Fixed

- **ERB validation** — now catches missing `<% end %>` by compiling ERB to Ruby then syntax-checking the result (was only checking ERB tag syntax).
- **Controller namespace format** — accepts both `Bonus::CrisesController` and `bonus/crises` (cross-tool consistency).
- **Layouts discoverable** — `controller:"layouts"` now works in view tool.
- **Validate error detail** — Ruby shows up to 5 error lines, JS shows 3 (was truncated to 1).
- **Invalid/empty regex** — early validation with clear error messages instead of silent fail.
- **Route count accuracy** — shows filtered count when `app_only:true`, not unfiltered total.
- **Namespace test lookup** — supports `bonus/crises` format and flat test directories.
- **Empty inputs** — `near:""` in edit_context and `pattern:""` in search return helpful errors.

## [0.15.4] — 2026-03-22

### Fixed

- **View subfolder paths** — listings now show full relative paths (`admin/comments/index.html.erb`) instead of just basenames.
- **Controller flexible matching** — `"posts"`, `"PostsController"`, `"postscontroller"` all resolve (matches other tools' forgiving lookup).
- **View path traversal** — explicit `..` and absolute path rejection before any filesystem operation.
- **Schema case-insensitive** — table lookup now case-insensitive (matches models/routes/etc.).
- **limit:0 silent empty** — uses default instead of returning empty results.
- **offset past end** — shows "Use `offset:0` to start over" instead of empty response.
- **Search ordering** — deterministic results via `--sort=path` on ripgrep.
- **Generated context prepended** — `<!-- BEGIN rails-ai-context -->` section now placed at top of existing files (AI reads top-to-bottom, may truncate at token limits).

### Added

- **Pagination on models, controllers, stimulus** — `limit`/`offset` params (default 50) with "end of results" hints. Prevents token bombs on large apps.

## [0.15.3] — 2026-03-22

### Fixed

- **Schema `add_index` column parsing** — option keys (e.g. `unique`, `name`) were being picked up as column names (PR #12).
- **Windsurf test command** — extracted `TestCommandDetection` shared module; Windsurf now shows specific test command instead of generic "Run tests after changes".

### Changed

- **Documentation** — updated all docs (README, CLAUDE.md, GUIDE.md, SECURITY.md, CHANGELOG, server.json, install generator) to match v0.15.x codebase. Fixed spec counts, file counts, preset counts, config options, and supported versions.

## [0.15.2] — 2026-03-22

### Fixed

- **Test command detection** — Serializers now use detected test framework (minitest → `rails test`, rspec → `bundle exec rspec`) instead of hardcoding `bundle exec rspec`. Default is `rails test` (the Rails default). Contributed by @curi (PR #13).

## [0.15.1] — 2026-03-22

### Fixed

- **Copilot serializer** — Show all model associations (not capped at 3), use human-readable architecture/pattern labels.
- **OpenCode rules serializer** — Filter framework controllers (Devise) from AGENTS.md output, show all associations, match `before_action` with `!`/`?` suffixes.

## [0.15.0] — 2026-03-22

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

## [0.14.0] — 2026-03-20

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
- **Model public method signatures** — `rails_get_model_details(model: "Post")` shows method names with params from source, stopping at private boundary.

## [0.13.1] — 2026-03-20

### Changed

- **View summary** — now shows partials used by each view.
- **Model details** — shows method signatures (name + parameters) instead of just method names.
- Removed unused demo files; fixed GUIDE.md preset tables.

## [0.13.0] — 2026-03-20

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

## [0.12.0] — 2026-03-20

### Added

- **Design Token Introspector** — auto-detects CSS framework and extracts tokens from Tailwind v3/v4, Bootstrap/Sass, plain CSS custom properties, Webpacker-era stylesheets, and ViewComponent sidecar CSS. Tested across 8 CSS setups. Added to standard preset.
- **`rails_get_edit_context` MCP tool** — purpose-built for surgical edits. Returns code around a match point with line numbers. Replaces the Read + Edit workflow with a single call.
- **Line numbers in action source** — `rails_get_controllers(action: "index")` now returns start/end line numbers for targeted editing.
- **Model file structure** — `rails_get_model_details(model: "Post")` now returns line ranges for each section (associations, validations, scopes, etc.).

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

## [0.11.0] — 2026-03-20

### Added

- **UI pattern extraction** — scans all views for repeated CSS class patterns. Detects buttons, cards, inputs, labels, badges, links, headings, flashes, alerts. Added to ALL serializers (root files + split rules for Claude, Cursor, Windsurf, Copilot, OpenCode).
- **View partial structure** — `rails_get_view(detail: "standard")` shows model fields and helper methods used by each partial.
- **Schema column names** — `.claude/rules/rails-schema.md` shows key column names with types, foreign keys, indexes, and enum values. Keeps polymorphic `_type`, STI `type`, and soft-delete `deleted_at` columns.

## [0.10.2] — 2026-03-20

### Security

- **ReDoS protection** — added regex timeout and converted greedy quantifiers to non-greedy across all pattern matching.
- **File size limits** — added size caps on parsed files to prevent memory exhaustion from oversized inputs.

## [0.10.1] — 2026-03-19

### Changed

- Patch release for RubyGems republish (no code changes).

## [0.10.0] — 2026-03-19

### Added

- **`rails_get_view` MCP tool** — get view template contents, partials, Stimulus references. Filter by controller or specific path. Supports summary/standard/full detail levels. Eliminates reading 490+ lines of view files per task. ([#7](https://github.com/crisnahine/rails-ai-context/issues/7))
- **`rails_get_stimulus` MCP tool** — get Stimulus controller details (targets, values, actions, outlets, classes). Filter by controller name. Wraps existing StimulusIntrospector. ([#8](https://github.com/crisnahine/rails-ai-context/issues/8))
- **`rails_get_controllers` `action` parameter** — returns actual action source code + applicable filters instead of the entire controller file. Saves ~1,400 tokens per call. ([#9](https://github.com/crisnahine/rails-ai-context/issues/9))
- **`rails_get_test_info` enhanced** — now supports `detail` levels (summary/standard/full), `model` and `controller` params to find existing tests, fixture/factory names, test helper setup. ([#10](https://github.com/crisnahine/rails-ai-context/issues/10))
- **ViewTemplateIntrospector** — new introspector that reads view file contents and extracts partial references and Stimulus data attributes.
- **Stimulus and view_templates in standard preset** — both introspectors now in `:standard` preset (11 introspectors, was 10).

## [0.9.0] — 2026-03-19

### Added

- **`config.generate_root_files` option** — when set to `false`, skips generating root-level context files (CLAUDE.md, AGENTS.md, .windsurfrules, copilot-instructions.md, .ai-context.json) while still generating all split rules (.claude/rules/, .cursor/rules/, .windsurf/rules/, .github/instructions/). Defaults to `true`.
- **Section markers on root files** — generated content in CLAUDE.md, AGENTS.md, .windsurfrules, and copilot-instructions.md is now wrapped in `<!-- BEGIN rails-ai-context -->` / `<!-- END rails-ai-context -->` markers. User content outside the markers is preserved on re-generation. Existing files without markers get the marked section appended.
- **App overview split rules** — new `rails-context.md` in `.claude/rules/` and `rails-context.instructions.md` in `.github/instructions/` provide a compact app overview (stack, models, routes, gems, architecture) so context is available even when root files are disabled.

### Changed

- **Removed `.cursorrules` root file** — Cursor officially deprecated `.cursorrules` in favor of `.cursor/rules/`. The `:cursor` format now generates only `.cursor/rules/*.mdc` split rules. The `rails-project.mdc` split rule (with `alwaysApply: true`) already provides the project overview.
- **License changed from AGPL-3.0 to MIT** — removes the copyleft blocker for SaaS and commercial projects.

## [0.8.5] — 2026-03-19

### Fixed

- **Thread-safe shared tool cache** — `BaseTool.cached_context` now uses a Mutex-protected shared cache across all 9 tool subclasses. Previously, each subclass cached independently (up to 9 redundant introspections after invalidation) and had no synchronization for multi-threaded servers like Puma. ([#2](https://github.com/crisnahine/rails-ai-context/issues/2))
- **SearchCode ripgrep total result cap** — `rg --max-count N` limits matches per file, not total. A search with `max_results: 5` against a large codebase could return hundreds of results. Now capped with `.first(max_results)` after parsing, matching the Ruby fallback behavior. ([#3](https://github.com/crisnahine/rails-ai-context/issues/3))
- **JobIntrospector Proc queue fallback** — when a Proc-based `queue_name` raises during introspection, the queue now falls back to `"default"` instead of producing garbage like `"#<Proc:0x00007f...>"`. ([#4](https://github.com/crisnahine/rails-ai-context/issues/4))
- **CLI `version` command crash** — `rails-ai-context version` crashed with `LoadError` due to wrong `require_relative` path (`../rails_ai_context/version` instead of `../lib/rails_ai_context/version`). ([#5](https://github.com/crisnahine/rails-ai-context/issues/5))

### Documentation

- **Standalone CLI documented** — the `rails-ai-context` executable (serve, context, inspect, watch, doctor, version) is now documented in README, GUIDE, and CLAUDE.md.

## [0.8.4] — 2026-03-19

### Added

- **`structure.sql` support** — the schema introspector now parses `db/structure.sql` when no `db/schema.rb` exists and no database connection is available. Extracts tables, columns (with SQL type normalization), indexes, and foreign keys from PostgreSQL dump format. Prefers `schema.rb` when both exist.
- **Fingerprinter watches `db/structure.sql`** — file changes to `structure.sql` now trigger cache invalidation and live reload.

## [0.8.3] — 2026-03-19

### Changed

- **License published to RubyGems** — v0.8.2 changed the license from MIT to AGPL-3.0 but the gem was not republished. This release ensures the AGPL-3.0 license is reflected on RubyGems.

## [0.8.2] — 2026-03-19

### Changed

- **License** — changed from MIT to AGPL-3.0 to protect against unauthorized clones and ensure derivative works remain open source.
- **CI: auto-publish to MCP Registry** — the release workflow now automatically publishes to the MCP Registry via `mcp-publisher` with GitHub OIDC auth. No manual `mcp-publisher login` + `publish` needed.

## [0.8.1] — 2026-03-19

### Added

- **OpenCode support** — generates `AGENTS.md` (native OpenCode context file) plus per-directory `app/models/AGENTS.md` and `app/controllers/AGENTS.md` that OpenCode auto-loads when reading files in those directories. Falls back to `CLAUDE.md` when no `AGENTS.md` exists. New command: `rails ai:context:opencode`.

### Fixed

- **Live reload LoadError in HTTP mode** — when `live_reload = true` and the `listen` gem was missing, the `start_http` method's rescue block (for rackup fallback) swallowed the live reload error, producing a confusing rack error instead of the correct "listen gem required" message. The rescue is now scoped to the rackup require only.
- **Dangling @live_reload reference** — `@live_reload` was assigned before `start` was called. If `start` raised LoadError, the instance variable pointed to a non-functional object. Now only assigned after successful start.

## [0.8.0] — 2026-03-19

### Added

- **MCP Live Reload** — when running `rails ai:serve`, file changes automatically invalidate tool caches and send MCP notifications (`notifications/resources/list_changed`) to connected AI clients. The AI's context stays fresh without manual re-querying. Requires the `listen` gem (enabled by default when available). Configurable via `config.live_reload` (`:auto`, `true`, `false`) and `config.live_reload_debounce` (default: 1.5s).
- **Live reload doctor check** — `rails ai:doctor` now warns when the `listen` gem is not installed.

## [0.7.1] — 2026-03-19

### Added

- **Full MCP tool reference in all context files** — every generated file (CLAUDE.md, .cursorrules, .windsurfrules, copilot-instructions.md) now includes complete tool documentation with parameters, detail levels, pagination examples, and usage workflow. Dedicated `rails-mcp-tools` split rule files added for Claude, Cursor, Windsurf, and Copilot.
- **MCP Registry listing** — published to the [official MCP Registry](https://registry.modelcontextprotocol.io) as `io.github.crisnahine/rails-ai-context` via mcpb package type.

### Fixed

- **Schema version parsing** — versions with underscores (e.g. `2024_01_15_123456`) were truncated to the first digit group. Now captures the full version string.
- **Documentation** — updated README (detail levels, pagination, generated file tree, config options), SECURITY.md (supported versions), CONTRIBUTING.md (project structure), gemspec (post-install message), demo_script.sh (all 17 generated files).

## [0.7.0] — 2026-03-19

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

## [0.6.0] — 2026-03-18

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

## [0.5.2] — 2026-03-18

### Fixed

- **MCP tool nil crash** — All 9 MCP tools now handle missing introspector data gracefully instead of crashing with `NoMethodError` when the introspector is not in the active preset (e.g. `rails_get_config` with `:standard` preset)
- **Zeitwerk dependency** — Changed from open-ended `>= 2.6` to pessimistic `~> 2.6` per RubyGems best practices
- **Documentation** — Updated CONTRIBUTING.md, CHANGELOG.md, and CLAUDE.md to reflect Zeitwerk autoloading, introspector presets, and `.mcp.json` auto-discovery changes

## [0.5.1] — 2026-03-18

### Fixed

- Documentation updates and animated demo GIF added to README.
- Zeitwerk autoloading fixes for edge cases.

## [0.5.0] — 2026-03-18

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

## [0.4.0] — 2026-03-18

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

## [0.3.0] — 2026-03-18

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

## [0.2.0] — 2026-03-18

### Added

- Named rake tasks (`ai:context:claude`, `ai:context:cursor`, etc.) that work without quoting in zsh
- AI assistant summary table printed after `ai:context` and `ai:inspect`
- `ENV["FORMAT"]` fallback for `ai:context_for` task
- Format validation in `ContextFileSerializer` — unknown formats now raise `ArgumentError` with valid options

### Fixed

- `rails ai:context_for[claude]` failing in zsh due to bracket glob interpretation
- Double introspection in `ai:context` and `ai:context_for` tasks (removed unused `RailsAiContext.introspect` calls)

## [0.1.0] — 2026-03-18

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
