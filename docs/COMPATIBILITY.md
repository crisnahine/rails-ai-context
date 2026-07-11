<div align="center" markdown="1">

# Compatibility

**What's actually supported, what's actually proven, and where each claim comes from.**

[Architecture](ARCHITECTURE.md) · [Introspectors](INTROSPECTORS.md) · [Troubleshooting](TROUBLESHOOTING.md) · [FAQ](FAQ.md)

</div>

---

Every claim below cites the spec file or release that proves it. No entry in this
document is aspirational.

## Supported versions

- **Ruby:** 3.1 - 4.0 (gemspec: `required_ruby_version >= 3.1.0`, no upper cap)
- **Rails (railties):** 7.0 - 8.1 (gemspec: `railties >= 7.0, < 9.0`)
- **mcp gem:** `>= 0.8, < 2.0`
- **thor:** `>= 1.0, < 3.0`
- **prism:** `>= 0.28, < 2.0`
- **concurrent-ruby:** `>= 1.2, < 3.0`

The gemspec's `railties` bound is wider than the CI matrix: point releases inside
7.0-8.1 and any future 8.x minor satisfy Bundler's constraint without a gem
release, but only the combinations in the table below are actually exercised by
CI.

### CI matrix

Source: `.github/workflows/ci.yml`. 17 of 25 possible Ruby x Rails combinations
run (`fail-fast: false`, so one failing cell doesn't hide the rest):

| Ruby \ Rails | 7.0 | 7.1 | 7.2 | 8.0 | 8.1 |
|:---|:---:|:---:|:---:|:---:|:---:|
| 3.1 | yes | yes | yes | - | - |
| 3.2 | - | yes | yes | yes | yes |
| 3.3 | - | yes | yes | yes | yes |
| 3.4 | - | yes | yes | yes | yes |
| 4.0 | - | - | - | yes | yes |

- Rails 7.0 runs only on Ruby 3.1 (7.0 predates upstream Ruby 3.2+ support).
- Rails 8.0/8.1 run on Ruby 3.2+ (both declare `required_ruby_version >= 3.2.0`
  upstream; they never needed 3.3).
- Ruby 4.0 runs only against Rails 8.0/8.1 (7.x has no upstream Ruby 4
  support).
- RuboCop runs once inside the matrix (Ruby 3.3 / Rails 8.0) and again in a
  dedicated `lint` job pinned to Ruby 3.3.

### Rails 9

Not supported, and the two install paths fail differently:

- **In-Gemfile:** the gemspec's `railties < 9.0` constraint makes `bundle
  install`/`bundle exec` fail dependency resolution outright when the host
  app's Gemfile locks Rails 9 - the gem never loads.
- **Standalone:** the CLI pre-loads the gem into its own `GEM_HOME` before the
  host app boots, so no Bundler constraint applies. `exe/rails-ai-context`
  prints a stderr warning after a successful boot when
  `Rails::VERSION::MAJOR >= 9`, naming the installed Rails version and
  pointing at checking for a newer gem release. Introspection itself is
  untested on Rails 9 either way.

## Operating tiers

Two tiers, both reachable over the CLI and MCP (stdio and HTTP):

**RUNTIME** - the app booted. Introspectors read live Rails reflection
(ActiveRecord connections, `Rails.application.routes`, loaded classes) plus the
Prism AST layer for source-level facts (scopes, callbacks, strong params).

**STATIC** - the app didn't boot, or `--no-boot` was passed. Only introspectors
that define a `static_call` path can answer without a booted app:

| Introspector | Static source |
|:---|:---|
| `schema` | `db/schema.rb` / `db/structure.sql` / migration files |
| `migrations` | migration file list + `db/structure.sql`'s trailing `schema_migrations` insert |
| `routes` | `config/routes.rb` parsed with a dedicated Prism listener |
| `models` | `app/models/**/*.rb` (plus packs/engines/extra paths) parsed, not constantized |
| `controllers` | `app/controllers/**/*.rb` (plus packs/engines/extra paths) parsed, not constantized |

The other 34 introspectors (views, jobs, gems, turbo, i18n, active_storage,
auth, api, and the rest) have no static path and report `{ unavailable: reason
}` in this tier - by construction, not by shape: `Introspector#run_introspector`
(`lib/rails_ai_context/introspector.rb`) falls back to the same message
regardless of what triggered the static tier.

`doctor` never enters the static tier - its job is diagnosing why boot failed,
so it always requires a bootable app.

Boot failure degrades `serve`/`tool` to the static tier automatically (proven
across four boot-failure modes - raises, prints to stdout, writes via the
`STDOUT` constant, and hangs past the timeout - in
`spec/e2e/boot_resilience_spec.rb`); `--no-boot` forces it without attempting a
boot at all (`spec/e2e/static_tier_spec.rb`).

### Confidence vocabulary

Source: `lib/rails_ai_context/confidence.rb`.

| Tag | Meaning |
|:---|:---|
| `[VERIFIED]` | Runtime-confirmed value, or a static literal the AST resolves with certainty |
| `[STATIC]` | Derived from source files without a booted app - trustworthy structure, not runtime-confirmed |
| `[INFERRED]` | Heuristic: a dynamic expression, metaprogramming, or a runtime-only construct the AST can't fully resolve |
| `[UNAVAILABLE: reason]` | The data source is absent entirely |

`[VERIFIED]`/`[INFERRED]` are per-value tags applied inside the schema, model,
route, controller, and mailbox-routing introspectors as they walk the AST
(`Confidence.for_node`). `[STATIC]`/`[UNAVAILABLE]` are whole-response tags:
`[STATIC]` marks any answer that came from the static tier; `[UNAVAILABLE]`
marks a section with no static path, or (in either tier) a data source that
genuinely doesn't exist for this app.

## Shape matrix

Rows are app shapes; columns are the five introspectors with any static
reach. `n/a` means the shape doesn't change that introspector's behavior - see
the stock full-stack row for its baseline proof. Reference numbers point at
the proof list below the table.

| Shape | Schema | Models | Routes | Controllers | Views |
|:---|:---|:---|:---|:---|:---|
| Stock full-stack (`schema.rb`) | runtime + static [1] | runtime + static [1] | runtime + static [1] | runtime + static [1] | runtime only [2] |
| API-only | runtime + static [1] | runtime + static [1] | runtime + static [1] | runtime + static [1] | runtime, "not applicable" [3] |
| `structure.sql` - PostgreSQL dialect | static [4] | n/a | n/a | n/a | n/a |
| `structure.sql` - MySQL/Trilogy dialect | static [4] | n/a | n/a | n/a | n/a |
| `structure.sql` - SQLite dialect | static [4] | n/a | n/a | n/a | n/a |
| Multi-DB `solid_*` schema dumps | static, `secondary_databases` [5] | n/a | n/a | n/a | n/a |
| Packwerk `packs/` | n/a | static [5] | n/a | n/a | n/a |
| In-repo `engines/` | n/a | n/a | n/a | static [5] | n/a |
| Mongoid | `[UNAVAILABLE]`, honest signal [6] | static (fields + embeds) [6] | n/a | n/a | n/a |
| Broken-boot (any full-stack app) | static [7] | static, per-file isolation [7] | static [7] | static [5] | `[UNAVAILABLE]` [8] |
| Packs + engines under `--no-boot` | n/a | static [5] | n/a | static [5] | n/a |
| Empty/greenfield app (no scaffold) | graceful, no crash [9] | graceful, no crash [9] | graceful, no crash [9] | graceful, no crash [9] | graceful, no crash [9] |
| Massive app (500 models/tables) | no crash at scale [10] | no crash at scale [10] | no crash at scale [10] | n/a | n/a |

Proof sources:

1. `spec/e2e/in_gemfile_install_spec.rb`, `standalone_install_spec.rb`,
   `zero_config_install_spec.rb` (schema/routes/model_details/controllers tool
   invocations against the default scaffold, across all three install paths);
   real Rails 8.0 apps in the v5.14.0 release QA (`blog`, `sandbox`).
2. Non-crash coverage for every built-in tool including `get_view` in
   `spec/e2e/in_gemfile_install_spec.rb`'s full-tool sweep; output correctness
   (ivar cross-check, render-form detection, partial interfaces) verified
   against the real `blog` app in the v5.14.0 release QA.
3. Unit specs for the "not applicable" API-only messaging: `get_view_spec.rb`,
   `get_component_catalog_spec.rb`, `get_turbo_map_spec.rb`,
   `get_partial_interface_spec.rb`, `get_stimulus_spec.rb`, `get_api_spec.rb`;
   real Rails 8 `--api` app (`api_app`) in the v5.14.0 release QA.
4. `spec/lib/rails_ai_context/introspectors/schema_introspector_spec.rb`
   ("with a valid structure.sql fixture", "with a MySQL (mysqldump)
   structure.sql", "with a SQLite structure.sql"). Unit-proven only - no
   committed e2e fixture writes a `structure.sql` file. The MySQL/Trilogy
   adapter itself (live queries, not the dump format) was also run for real
   against MySQL 9.6 in the v5.14.0 release QA (`store` app,
   `schema_format = :sql`).
5. `spec/e2e/shapes_spec.rb`: "packs and engines code discovery (static
   tier)" and "multi-database schema dumps".
6. `spec/e2e/shapes_spec.rb`: "Mongoid app (bare directory, --app-path, no
   boot possible)".
7. `spec/e2e/boot_resilience_spec.rb` (four boot-failure modes: raises,
   prints to stdout, writes via the `STDOUT` constant, hangs past the
   timeout) plus `spec/e2e/static_tier_spec.rb` ("broken-boot app over the
   CLI", "broken-boot app over MCP stdio", "syntax error in one model file").
8. No introspector outside the five in the operating-tiers table defines
   `static_call` (`lib/rails_ai_context/introspectors/view_introspector.rb`
   has none); `Introspector#run_introspector` reports `{ unavailable: reason
   }` for every such section regardless of shape.
9. `spec/e2e/empty_app_spec.rb` - all 39 built-in tools swept against an app
   with no scaffold, no models, no controllers beyond
   `ApplicationController`, no routes beyond root.
10. `spec/e2e/massive_app_spec.rb` - `schema`, `model_details`, and `routes`
    (plus `context`, `onboard`, `analyze_feature`, `get_turbo_map`, `get_env`)
    sampled against 500 generated models/tables under a 180-second cap.

Postgres itself - live query safety (read-only transactions, the
`BLOCKED_FUNCTIONS` guard against `pg_read_file`/`dblink`/`COPY ... PROGRAM`,
DDL rejection) alongside schema/routes - is proven end-to-end against a real
Postgres instance in `spec/e2e/postgres_install_spec.rb`, opt-in via
`TEST_POSTGRES=1` and skipped otherwise.

## Known limits

- **Concern-style Mongoid documents in runtime results.** Mongoid documents
  are invisible to ActiveRecord reflection, so `ModelIntrospector#call` falls
  back to the same source-parsing pass used in the static tier even when the
  app is booted (`lib/rails_ai_context/introspectors/model_introspector.rb`).
  Fields or associations defined in an included concern module rather than
  directly in the document class body are not resolved, in either tier.
- **Static-tier API-only detection.** `Tools::BaseTool#api_only_app?` reads
  `app.config.api_only`. `RailsAiContext::StaticApp` exposes no `config`
  method, so this check is always false in the static tier - the "not
  applicable" messaging for view/frontend tools on API-only apps only fires
  once the app has actually booted.
- **Live multi-DB connections are not iterated, only dumps.**
  `MultiDatabaseIntrospector` (replicas, sharding, per-model connection
  assignment) has no static path and reports `[UNAVAILABLE]` in the static
  tier. Only the schema introspector's own secondary-database dump parsing
  (`db/*_schema.rb`, `db/*_structure.sql`) works without a boot.
- **Constraints and lambda routes surface as a dynamic tally, not resolved
  entries.** `RouteIntrospector#static_call` counts routes behind
  `constraints do...end` blocks, lambdas, `devise_for`, and `concern`-based
  route declarations into a `dynamic_routes` count rather than fabricating
  per-route controller/action pairs it can't actually determine from source.

<br>

---

<div align="center">

[Back to README](../README.md)

</div>
