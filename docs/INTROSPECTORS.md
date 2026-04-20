<div align="center" markdown="1">

# Introspectors

**39 modules that extract structured data from your Rails application.**

[Architecture](ARCHITECTURE.md) · [Configuration](CONFIGURATION.md) · [Tools Reference](TOOLS.md) · [Security](SECURITY.md)

</div>

---

## How introspectors work

Each introspector:

1. Examines a specific aspect of your Rails app (schema, models, routes, etc.)
2. Returns a Hash with structured data (never raises — wraps errors in `{ error: msg }`)
3. Results are cached with TTL + SHA256 fingerprint invalidation
4. Runs as part of a preset (`:standard` or `:full`) or can be configured individually

## Presets

### `:full` (default) — all 39 introspectors

Best for comprehensive AI context. Covers every aspect of your app.

### `:standard` — 17 introspectors

Lightweight subset for faster generation:

```
schema, models, routes, jobs, gems, conventions, controllers,
tests, migrations, stimulus, view_templates, config, components,
turbo, auth, performance, i18n
```

### Preset comparison

```mermaid
graph LR
    subgraph standard["Standard Preset — 17 introspectors"]
        direction TB
        S1["schema"] ~~~ S2["models"] ~~~ S3["routes"]
        S4["controllers"] ~~~ S5["jobs"] ~~~ S6["gems"]
        S7["conventions"] ~~~ S8["tests"] ~~~ S9["migrations"]
        S10["stimulus"] ~~~ S11["view_templates"] ~~~ S12["config"]
        S13["components"] ~~~ S14["turbo"] ~~~ S15["auth"]
        S16["performance"] ~~~ S17["i18n"]
    end

    subgraph full_only["Full Preset adds +22"]
        direction TB
        F1["views"] ~~~ F2["database_stats"] ~~~ F3["api"]
        F4["active_storage"] ~~~ F5["action_text"] ~~~ F6["action_mailbox"]
        F7["rake_tasks"] ~~~ F8["assets"] ~~~ F9["devops"]
        F10["seeds"] ~~~ F11["middleware"] ~~~ F12["engines"]
        F13["multi_database"] ~~~ F14["frontend_frameworks"]
        F15["initializers"] ~~~ F16["autoload"] ~~~ F17["connection_pool"]
        F18["active_support"] ~~~ F19["credentials"] ~~~ F20["security"]
        F21["observability"] ~~~ F22["env"]
    end

    standard --> full_only

    style standard fill:#3498db,stroke:#2980b9,color:#fff
    style full_only fill:#9b59b6,stroke:#8e44ad,color:#fff
```

### Custom list

```ruby
RailsAiContext.configure do |config|
  config.introspectors = %i[schema models routes controllers views]
end
```

---

## All 39 introspectors

### Core

| Introspector | Key | What it extracts |
|:-------------|:----|:-----------------|
| SchemaIntrospector | `:schema` | Database tables, columns, types, indexes, defaults, encrypted hints |
| ModelIntrospector | `:models` | Associations, validations, scopes, enums, concerns (AST-based) |
| RouteIntrospector | `:routes` | Routes with helpers, HTTP methods, constraints |
| ControllerIntrospector | `:controllers` | Actions, filters, strong params, render paths |
| ViewIntrospector | `:views` | View files, layouts, partials |
| ViewTemplateIntrospector | `:view_templates` | Template content with ivars, Turbo frames, Stimulus refs |

### Models & Data

| Introspector | Key | What it extracts |
|:-------------|:----|:-----------------|
| SourceIntrospector | `:source` | Prism AST: associations, validations, scopes, enums, callbacks, macros, methods |
| MigrationIntrospector | `:migrations` | Migration files, versions, reversibility |
| SeedsIntrospector | `:seeds` | Seed file analysis |
| DatabaseStatsIntrospector | `:database_stats` | Table sizes, row counts, index stats |
| MultiDatabaseIntrospector | `:multi_database` | Multi-database configuration |

### Frontend

| Introspector | Key | What it extracts |
|:-------------|:----|:-----------------|
| StimulusIntrospector | `:stimulus` | Controllers, targets, values, actions |
| TurboIntrospector | `:turbo` | Turbo Frames, Streams, broadcasts |
| AssetPipelineIntrospector | `:assets` | Asset pipeline configuration, manifests |
| FrontendFrameworkIntrospector | `:frontend_frameworks` | React/Vue/Svelte/Angular detection |
| ComponentIntrospector | `:components` | ViewComponent/Phlex: props, slots, previews |

### Config & Infrastructure

| Introspector | Key | What it extracts |
|:-------------|:----|:-----------------|
| ConfigIntrospector | `:config` | Database, cache, queue, Action Cable config |
| GemIntrospector | `:gems` | Notable gems with versions and categories |
| ConventionIntrospector | `:conventions` | Auth patterns, flash messages, test patterns |
| I18nIntrospector | `:i18n` | Locale files, translation keys |
| MiddlewareIntrospector | `:middleware` | Rack middleware stack |
| EngineIntrospector | `:engines` | Mounted engines |
| DevopsIntrospector | `:devops` | Dockerfile, CI config, deployment |

### Jobs & Services

| Introspector | Key | What it extracts |
|:-------------|:----|:-----------------|
| JobIntrospector | `:jobs` | Background jobs: queue, retries, schedules |
| RakeTaskIntrospector | `:rake_tasks` | Custom rake tasks |

### Security & Auth

| Introspector | Key | What it extracts |
|:-------------|:----|:-----------------|
| AuthIntrospector | `:auth` | Authentication framework (Devise, etc.) |
| ApiIntrospector | `:api` | API configuration, versioning, serializers |

### Rails Features

| Introspector | Key | What it extracts |
|:-------------|:----|:-----------------|
| ActiveStorageIntrospector | `:active_storage` | Attachments, variants, services |
| ActionTextIntrospector | `:action_text` | Rich text attributes |
| ActionMailboxIntrospector | `:action_mailbox` | Mailbox routing rules |

### Analysis

| Introspector | Key | What it extracts |
|:-------------|:----|:-----------------|
| TestIntrospector | `:tests` | Test framework, file counts, coverage hints |
| PerformanceIntrospector | `:performance` | N+1 risks, missing indexes, counter_cache hints |

### Runtime & Framework Internals

These introspectors map directly onto [`RAILS_NERVOUS_SYSTEM.md`](../RAILS_NERVOUS_SYSTEM.md) sections and capture framework-level surface that `:config`, `:auth`, and `:middleware` don't.

| Introspector | Key | Nervous-system § | What it extracts |
|:-------------|:----|:---|:-----------------|
| InitializerIntrospector | `:initializers` | §2 | `Rails.application.initializers` graph: name, owner, `before:`/`after:` edges, block `source_location`, per-file `config/initializers/*.rb` summary |
| AutoloadIntrospector | `:autoload` | §3 | Zeitwerk presence, autoloaders (`:main` / `:once`) with collapsed + ignored dirs, `autoload_paths`, `eager_load_paths`, custom inflections (`acronym`, `plural`, `singular`, `irregular`) |
| ConnectionPoolIntrospector | `:connection_pool` | §10 | Per-database adapter config: pool size, `checkout_timeout`, `reaping_frequency`, `prepared_statements`, `advisory_locks`, replica flag, connection-handler roles, automatic shard selector detection |
| ActiveSupportIntrospector | `:active_support` | §17 | Concerns in `app/**/concerns/` (ActiveSupport::Concern flags, `included do`/`class_methods do` blocks), deprecators registry, MessageEncryptor/Verifier usage, TaggedLogging config, common on-load hooks, cache store options |
| CredentialsIntrospector | `:credentials` | §30 | Default + per-env encrypted files, master-key source (`env:RAILS_MASTER_KEY` vs `file:config/master.key` vs missing), `require_master_key` flag, arbitrary encrypted configs (`config/*.yml.enc`), top-level key **names only** (never values) |
| SecurityIntrospector | `:security` | §32 | `force_ssl`, SSL options (HSTS `expires`/`subdomains`/`preload`), `host_authorization` hosts, ContentSecurityPolicy directives + `report_only`, PermissionsPolicy directives, CSRF config (`protect_from_forgery`, `per_form_csrf_tokens`, `origin_check`), cookie session options, Rails 7.2+ `allow_browser` usage |
| ObservabilityIntrospector | `:observability` | §34 + §38 | `ActiveSupport::LogSubscriber.log_subscribers` catalog, AS::Notifications subscriber registry (pattern + count + sample class), `ActionDispatch::ServerTiming` middleware detection, Rails 8.1 `event_reporter` availability, log level + tags, canonical Rails event-name catalog (10 subsystems) |
| EnvIntrospector | `:env` | §36 | Catalog of 30+ Rails-related ENV vars partitioned into `set` / `unset`; safe vars (`RAILS_ENV`, `RAILS_MAX_THREADS`, etc.) return values, sensitive vars (`SECRET_KEY_BASE`, `DATABASE_URL`, `RAILS_MASTER_KEY`, etc.) return `redacted: true` only; scans `config/`/`app/`/`lib/` for app-specific `ENV["X"]` references |

---

## AST-based introspection

The **SourceIntrospector** uses Prism AST parsing for model analysis. It runs a single-pass Dispatcher that walks the AST once and feeds events to 7 listeners simultaneously:

### 7 Prism listeners

| Listener | What it detects |
|:---------|:---------------|
| AssociationsListener | `belongs_to`, `has_many`, `has_one`, `has_and_belongs_to_many` |
| ValidationsListener | `validates`, `validates_*_of`, custom `validate :method` |
| ScopesListener | `scope :name, -> { ... }` |
| EnumsListener | Rails 7+ and legacy enum syntax, prefix/suffix options |
| CallbacksListener | All AR callback types, `after_commit` with `on:` resolution |
| MacrosListener | `encrypts`, `normalizes`, `delegate`, `has_secure_password`, `serialize`, `store`, `has_one_attached`, `has_many_attached`, `has_rich_text`, `generates_token_for`, `attribute` |
| MethodsListener | `def`/`def self.`, visibility tracking, parameter extraction, `class << self` |

### Confidence tagging

Every AST result carries a confidence tag:

- **`[VERIFIED]`** — All arguments are static literals (strings, symbols, numbers). Ground truth.
- **`[INFERRED]`** — Arguments contain dynamic expressions (variables, method calls). Requires runtime verification.

```
has_many :posts                    → [VERIFIED]
has_many :posts, class_name: name  → [INFERRED]  (name is a variable)
```

### AstCache

Thread-safe parse cache using `Concurrent::Map`:

- Keyed by: file path + SHA256 content hash + mtime
- Invalidates automatically when file changes
- Shared by all AST-based introspectors
- Cleared on `reset_all_caches!` (triggered by live reload)

---

## Cache invalidation

Introspection results are cached at two levels:

1. **Introspection cache** — Full context hash, invalidated by TTL (`config.cache_ttl`, default: 60s) and fingerprint change
2. **AST cache** — Per-file parse results, invalidated by file content change (SHA256)

The **Fingerprinter** computes a composite SHA256 from all watched directories (`app/`, `config/`, `db/`, `lib/tasks/`, `Gemfile.lock`). When the fingerprint changes, the introspection cache is invalidated even if TTL hasn't expired.

**Live Reload** watches these directories and calls `reset_all_caches!` when changes are detected, then notifies connected MCP clients via `notify_resources_list_changed`.

---

<div align="center" markdown="1">

**[← Architecture](ARCHITECTURE.md)** · **[Security →](SECURITY.md)**

[Back to Home](index.md)

</div>
