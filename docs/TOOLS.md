<div align="center" markdown="1">

# MCP Tools Reference

**All 45 read-only tools, with every parameter.**

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
# MCP - AI calls automatically via protocol
# CLI - you call from terminal:
rails 'ai:tool[schema]' table=users detail=full
rails-ai-context tool schema --table users --detail full
```

Tool name resolution is flexible - all of these work:

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
| [App Config & Services](#app-config--services) | `get_api`, `get_conventions`, `get_config`, `get_gems`, `get_env`, `get_helper_methods`, `get_service_pattern`, `get_job_pattern`, `get_component_catalog`, `get_i18n`, `get_mailers`, `get_engines`, `get_autoload`, `get_active_support`, `get_env_config` |
| [Data & Debugging](#data--debugging) | `dependency_graph`, `migration_advisor`, `search_docs`, `query`, `read_logs`, `diagnose`, `review_changes`, `runtime_info`, `session_context` |

<p align="right"><a href="#table-of-contents">↑ back to top</a></p>

---

## Search & Trace

### `rails_search_code`

Search your codebase with regex, ripgrep acceleration, and sensitive file blocking. Every line returned passes through redaction, so in a file no pattern names a string literal under a secret-named key (8+ characters, unless it is clearly not a credential: a message, URL, path, placeholder, version, date, header, env or parameter name, or a translation) or in a known credential format (vendor tokens, JWTs, a PEM or PGP private key) reads as `[FILTERED]`; code, ENV lookups, ERB and placeholders are never rewritten, so the text stays usable as the text to replace. A match that falls only inside a filtered value is not returned, so a pattern cannot confirm what a secret starts with.

| Parameter | Type | Default | Description |
|:----------|:-----|:--------|:------------|
| `pattern` | string | *required* | Regex pattern to search for |
| `path` | string | - | Subdirectory or file to search (relative to Rails root); a file is searched whatever its type or ignore files say, as ripgrep does, unless it is sensitive |
| `match_type` | enum | `any` | `any`, `definition`, `class`, `call`, `trace` |
| `file_type` | string | - | Filter by extension (`rb`, `erb`, `js`, etc.) |
| `exact_match` | boolean | `false` | Literal, whole-word match. `def reblog?` does not match `def reblog` |
| `exclude_tests` | boolean | `false` | Skip test/spec directories |
| `group_by_file` | boolean | `false` | Group results by file with counts |
| `context_lines` | integer | `2` | Lines of context around each match, max 5 |
| `offset` | integer | `0` | Skip this many emitted lines |
| `limit` | integer | auto | Max lines to return; the default is sized in matches, and a limit too small for one match and its context still returns that match |

The header counts matches, not emitted lines, so below the cap it does not move with `context_lines`. When the search hits `max_search_results` (a cap on emitted lines) the header says `first N lines scanned` and marks the count `N+`: it is then the matches among the lines that were scanned, a floor rather than the total, so it falls as `context_lines` grows. `offset` and `limit` count lines, so a search with context returns more lines than matches. A limit smaller than one match's context block would hold only context, so the page starts at the next match instead and says so.

> **Trace mode** returns definition + source code + every caller grouped by type + tests - replaces 4-5 sequential file reads.

Without ripgrep on the PATH, the Ruby fallback returns the rows ripgrep would, context lines and the line cap included, from the files ripgrep would search: no hidden files, no symlinks followed, no binary files (a NUL byte in the first 64 KiB), and ignore files read with ripgrep's precedence, where the file type decides before depth: any `.rgignore`, then any `.ignore`, then any `.gitignore`, then `.git/info/exclude`, then the global excludes file, the deepest file first within a type. `.ignore` and `.rgignore` apply everywhere, including the directories above the app; the git files apply only inside a repository and only as far up as the nearest `.git` (a file for a worktree or submodule), whose `info/exclude` is the only one read. Patterns match case-sensitively.

Redaction treats a value under a secret-named key as a secret unless it is clearly something else: shorter than eight characters (four under a password-type key: `password`, `passwd`, `pass`, `pin`, `passphrase`), containing whitespace (a message; not under `passphrase`), a URL, an email address or a hostname (not under a password-type key), a URL query (`?mode=safe`) or a path (two slashes, no `+` or `=`), a placeholder (`<token>`, `${VAR}`, `%{var}`, a `{name}` slot, `xxxx`, `your-...`, `put-your-key-here`), a version (`2.4.1`, `v2`) or a date, an HTTP header name (`X-Api-Key`; not under a password-type key), an env name (capitals joined by `_`, led by `_` or `HTTP_` or naming a secret word, like `_DISCOURSE_API`), a name spelled from a secret word (`user_api_key`; not under a password-type key, where `admin_password` is the password), the key's own name (an enum's `password: 'password'`), or not ASCII. Keys ending `_url`, `_error`, `_use` and the like describe a secret rather than hold one. A call or block whose first argument names a secret holds its value too (`ENV.fetch("SECRET_KEY_BASE", "...")`, `let(:api_key) { "..." }`, `option :client_secret, default: "..."`, a `credentials.fetch` default); a ternary's `? "a" : "b"` is two values, not a key and its value. Under a name that ends in `_KEY`, `Key` or `key` without a secret word (`ALGOLIA_ADMIN_KEY`, `apiKey`), a value is filtered only when it looks like a credential: a run of 16+ characters mixing letters and digits, or a known token format; a cache or i18n key (`views/posts/1`, `users.index.title`), a storage key (`wp-content/uploads/...`), a word, a path or a header name is kept. Log lines use the same rule. An unquoted `NAME=value` with a secret-named name, in any file (shell, Dockerfile `ENV`, compose, env, code), has its value filtered unless it is `$VAR`, `${...}`, `#{...}` or ERB; the value ends at the first quote, bracket, `&`, `,`, `;` or space, so in a URL query (`?token=...&page=2`) only the value goes. A `:name=` setter symbol and a `(?<=name=` lookbehind are not assignments. In an example file (`*.example`, `*.sample`, `*.template`) a value under a secret-named key is kept only when it is plainly a placeholder: a placeholder shape above, or up to 20 characters of words with no digits (`changeme`, `your_password_here`). Locale files are filtered only for credential formats.

### `rails_get_edit_context`

Method-aware code extraction with surrounding class context. Every line returned passes through redaction, so in a file no pattern names a string literal under a secret-named key (8+ characters, unless it is clearly not a credential: a message, URL, path, placeholder, version, date, header, env or parameter name, or a translation) or in a known credential format (vendor tokens, JWTs, a PEM or PGP private key) reads as `[FILTERED]`; code, ENV lookups, ERB and placeholders are never rewritten, so the text stays usable as the text to replace.

| Parameter | Type | Default | Description |
|:----------|:-----|:--------|:------------|
| `file` | string | *required* | File path relative to Rails root |
| `method_name` | string | - | Extract a specific method |
| `line` | integer | - | Center extraction around a line number |

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

Composite context: schema + model + controller + routes + views for a resource. Views come from the directory Rails resolves for the controller; a flat-directory fallback is labelled.

| Parameter | Type | Default | Description |
|:----------|:-----|:--------|:------------|
| `resource` | string | *required* | Resource name (e.g., `users`, `Post`) |
| `action` | string | - | Specific controller action |
| `detail` | enum | `standard` | `summary`, `standard`, `full` |

### `rails_onboard`

Narrative app walkthrough for getting up to speed. It ends with the app's custom
rake tasks (Rakefile, `lib/tasks`, `rakelib`), each with its arguments,
description and file: the first 15 at `standard`, every one at `full`.

| Parameter | Type | Default | Description |
|:----------|:-----|:--------|:------------|
| `detail` | enum | `standard` | `quick`, `standard`, `full` |

<p align="right"><a href="#table-of-contents">↑ back to top</a></p>

---

## Schema & Models

### `rails_get_schema`

Database schema with column types, indexes, defaults, encrypted hints. Booted,
a table `db/schema.rb` declares and the connected database does not have is
named as a migration that has not run, and the listing header says when the
two table counts disagree.

Column hints follow the leftmost-prefix rule: `[indexed]` means some index leads
with the column, so a lookup on it alone can use one; `[unique]` means a unique
index covers the column alone; `[unique with x]` names the partners of a
composite unique index; `[in index after x]` marks a column that only trails
`x` in a plain index. An expression key is named as the expression.

| Parameter | Type | Default | Description |
|:----------|:-----|:--------|:------------|
| `table` | string | - | Specific table (omit for overview) |
| `detail` | enum | `standard` | `summary`, `standard`, `full` |

### `rails_get_model_details`

AST-parsed model internals. Every result carries `[VERIFIED]` or `[INFERRED]` confidence tag. The method list says how many of the model's methods it is showing.

| Parameter | Type | Default | Description |
|:----------|:-----|:--------|:------------|
| `model` | string | - | Model name (e.g., `User`, `Post`) |
| `detail` | enum | `standard` | `summary`, `standard`, `full` |

Returns: associations, validations, scopes, enums, callbacks, macros, methods, concerns.
What the included concerns declare is merged in, so the answer does not stop
at the model file. A concern whose file could not be read is named under
Concerns as `[UNAVAILABLE]` rather than dropped.

### `rails_get_callbacks`

Callbacks grouped by type, in Rails event order, with source code. The list
covers concern-declared callbacks too, with the body read from the concern
file, and the "From Concerns" section says which concern declared each one.
Within one type the order is the order Rails runs them: base classes first, a
concern's callbacks where its `include` line stands, then the model's own, and
a `before_` or `around_` callback with `prepend: true` first. `after_commit`
and `after_rollback` are last declared first unless the app turns on
`run_after_transaction_callbacks_in_order_defined` (`load_defaults 7.1`). A
method declared again for one type shows once, with the later declaration's
conditions, as Rails keeps it. The order is read from source in both tiers,
and dynamic dispatch is not evaluated: a callback registered through
`send(:before_save, ...)`, through a method called with `send` or defined with
`define_singleton_method`, or through a module included in `class << self` is
not read, so the list can miss it or show the definition it replaces.

| Parameter | Type | Default | Description |
|:----------|:-----|:--------|:------------|
| `model` | string | *required* | Model name |
| `detail` | enum | `standard` | `summary`, `standard`, `full` |

### `rails_get_concern`

Concern methods, source code, and which models include it. A class under
`app/models/concerns` that subclasses `ActiveModel::Validator` is listed as a
validator rather than a concern, and its users are the models that name it in
`validates_with`. The rule reads the class the file is named for, so a concern
that nests its own validator class stays a concern. Every concern is named by
the constant its file declares, so an app inflection (`sdg/tag_list.rb`
declaring `SDG::TagList`) is answered under the name the app has.

| Parameter | Type | Default | Description |
|:----------|:-----|:--------|:------------|
| `name` | string | - | Concern name (e.g., `Trackable`, `Admin::ExportControllerConcern`). Omit to list all concerns |
| `type` | string | `all` | A type the listing's headings print: `model`, `controller`, `mailer` and the rest for `app/*/concerns`; the root a concern outside every concerns directory lives in (`service`, `lib`, ...); `other` for `app/concerns` or a configured directory. A type the app does not have is answered with the types it has |
| `detail` | enum | `standard` | `summary`, `standard`, `full` |

<p align="right"><a href="#table-of-contents">↑ back to top</a></p>

---

## Controllers & Routes

### `rails_get_controllers`

Controller actions with inherited filters, render map, strong params. Includes schema hints for referenced models.

| Parameter | Type | Default | Description |
|:----------|:-----|:--------|:------------|
| `controller` | string | - | Controller name (e.g., `UsersController`) |
| `action` | string | - | Specific action |
| `detail` | enum | `standard` | `summary`, `standard`, `full` |

### `rails_get_routes`

Routes with code-ready helpers (`post_path(@record)`) and required params. A
fully qualified controller key answers with its own routes only; a short name
reaches the controller whose trailing segments it spells, and not the ones that
merely start with it. Rack apps attached with `mount`
or `match ... to:` are named with the path they answer on, when the source
spells one out.

| Parameter | Type | Default | Description |
|:----------|:-----|:--------|:------------|
| `controller` | string | - | Filter by controller |
| `detail` | enum | `standard` | `summary`, `standard`, `full` |

<p align="right"><a href="#table-of-contents">↑ back to top</a></p>

---

## Views & Frontend

### `rails_get_view`

View templates with instance variables, Turbo frames, Stimulus controllers, partial locals. Includes schema hints for detected ivars. A template directly under `app/views` is grouped as `(app/views root)`, which `path:` reaches and `controller:` does not.

| Parameter | Type | Default | Description |
|:----------|:-----|:--------|:------------|
| `controller` | string | - | Controller name |
| `action` | string | - | Specific action view |
| `detail` | enum | `standard` | `summary`, `standard`, `full` |

### `rails_get_stimulus`

Stimulus controller data-attributes (with dashes, not underscores) + targets +
values + actions + reverse view lookup. Controllers are read from `app/javascript`,
`app/frontend`, `app/webpacker`, `frontend`, `client` and `app/components`
sidecars alike, packs and in-repo engines included, and both file conventions
count (`*_controller.js` and `*.controller.ts`). Outside a JS root's own
`controllers/` directory the source has to name Stimulus, so a React component
or an AngularJS controller with the same filename is not counted. Outside
`app/javascript/controllers` the identifier the path gives is a guess, since an
app's own loader can strip a segment the path still carries, so it is checked
against the identifiers the templates and components name (`data-controller`,
targets, action descriptors, a `content_controller` helper) and corrected to
the one they use. A guess no template confirms is marked inferred, and takes
the naming rule of its directory when one is known: a loader that imports the
directory by a derived path (`import(`./dynamic/${path}.controller.ts`)`), or
two or more confirmed neighbours that all drop the directory's segment.

| Parameter | Type | Default | Description |
|:----------|:-----|:--------|:------------|
| `controller` | string | - | Stimulus controller name |
| `detail` | enum | `standard` | `summary`, `standard`, `full` |

### `rails_get_partial_interface`

What locals to pass to a partial and what methods are called on them.

| Parameter | Type | Default | Description |
|:----------|:-----|:--------|:------------|
| `partial` | string | *required* | Partial path (e.g., `users/form`); a bare name that matches several partials lists them instead of answering |
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
| `model` | string | - | Model to find tests for |
| `controller` | string | - | Controller to find tests for: its controller or request spec, then the system, feature, request and integration tests named for it or reaching its routes, each labelled by type |
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
| `files` | array | required | File paths to validate |
| `level` | enum | `syntax` | `syntax`, `rails` (rails includes the Brakeman security pass) |

### `rails_security_scan`

Brakeman static analysis: SQL injection, XSS, mass assignment, command injection.

| Parameter | Type | Default | Description |
|:----------|:-----|:--------|:------------|
| `detail` | enum | `standard` | `summary`, `standard`, `full` |

> Requires the `brakeman` gem. When it cannot be loaded, the answer says which
> case it is: brakeman is nowhere on the machine, or it is installed and the
> app's bundle does not carry it, which `--no-boot` scans around.

### `rails_performance_check`

N+1 query risks, missing indexes, missing counter_cache, eager load candidates.

| Parameter | Type | Default | Description |
|:----------|:-----|:--------|:------------|
| `detail` | enum | `standard` | `summary`, `standard`, `full` |

<p align="right"><a href="#table-of-contents">↑ back to top</a></p>

---

## App Config & Services

### `rails_get_api`

API layer: api_only mode, serialization strategy (Jbuilder, serializers), GraphQL, versioning, rate limiting, OpenAPI specs, CORS, pagination.

| Parameter | Type | Default | Description |
|:----------|:-----|:--------|:------------|
| `detail` | enum | `standard` | `summary` (one-liner), `standard` (per-area breakdown), `full` (adds OpenAPI spec paths) |

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

Notable gems with versions, categories, and config file locations. A config
location is printed only when the app has that file, and an initializer is
found under a load-order prefix too (`config/initializers/3_omniauth.rb`).

| Parameter | Type | Default | Description |
|:----------|:-----|:--------|:------------|
| `detail` | enum | `standard` | `summary`, `standard`, `full` |

### `rails_get_env`

Environment variables + credentials keys (values are never exposed). Scans `.rb`, `.rake`, ERB views and config YAML under `app`, `config` and `lib`; files matching `sensitive_patterns` (`config/database.yml`, credentials, keys) are never read, and the answer says so. A variable whose call sites pass different defaults is labelled as such rather than with one site's default; `detail:"full"` names each site's. A default is redacted by the rule a source literal gets: a credential format under any name, a URL's password, and under a secret-named variable a value that is not clearly something else, so an address, URL or hostname default prints as written.

| Parameter | Type | Default | Description |
|:----------|:-----|:--------|:------------|
| `detail` | enum | `standard` | `summary`, `standard`, `full` |

### `rails_get_helper_methods`

Application and framework helpers with view cross-references.

| Parameter | Type | Default | Description |
|:----------|:-----|:--------|:------------|
| `detail` | enum | `standard` | `summary`, `standard`, `full` |

### `rails_get_service_pattern`

Service object interface, dependencies, side effects, callers. An
ActiveInteraction's inputs include the ones it inherits, with the filters
nested inside a `hash` filter shown under it. Callers are read from every
`app/` and `lib/` tree, and on a booted app from any other directory it
autoloads, and the page says when the twenty-caller display cap or the scan's
own file ceiling left the list partial. A module under
`app/services/concerns/` is a concern rather than a service object, so
`rails_get_concern` lists it and this tool does not.

| Parameter | Type | Default | Description |
|:----------|:-----|:--------|:------------|
| `service` | string | *required* | Service class name |
| `detail` | enum | `standard` | `summary`, `standard`, `full` |

### `rails_get_job_pattern`

Background job queue, retries, guard clauses, broadcasts, schedules. Jobs are
read from `app/jobs`, `app/workers` and `app/sidekiq` alike, packs and in-repo
engines included: ActiveJob subclasses are listed as jobs and Sidekiq classes
as workers, whichever directory each one lives in. A worker carries its
`sidekiq_options`, any `sidekiq_throttle`, and the `perform` signature, and a
worker that inherits its Sidekiq mixin from a base worker is one of them. A class whose
ancestry reaches neither, but which declares `perform` - a Resque job, a PORO
enqueued by hand - is listed marked `[unknown base]`. An abstract base another
job inherits from is not counted as a job; the listing names the ones it left
out, in the sentence the service and mailer listings use, and `job:` answers
for one of them with what every job below it inherits: its queue, options,
retries, mixins, throttle and callbacks, and which jobs inherit it. `job:`
answers a worker name as well as a job name.

| Parameter | Type | Default | Description |
|:----------|:-----|:--------|:------------|
| `job` | string | - | Specific job name |
| `detail` | enum | `standard` | `summary`, `standard`, `full` |

### `rails_get_component_catalog`

ViewComponent/Phlex components: props, slots, previews, sidecar assets, usage examples. Components are read from every `app/components`, packs and in-repo engines included. The type follows the superclass chain through the app's own base classes; anything the chain cannot place is counted in the header rather than left out of it. A short name several components share is answered with the list of them and a request for the full one. A base-named component other components inherit from is named on a bases line rather than counted, and previews are read from the default directories and the ones the config sets.

| Parameter | Type | Default | Description |
|:----------|:-----|:--------|:------------|
| `component` | string | - | Specific component name |
| `detail` | enum | `standard` | `summary`, `standard`, `full` |

### `rails_get_i18n`

I18n setup: default/available locales, backend, locale files with key counts, per-locale coverage, fallbacks.

| Parameter | Type | Default | Description |
|:----------|:-----|:--------|:------------|
| `locale` | string | - | Show only this locale's files and coverage, by exact name |
| `offset` | integer | `0` | Pagination offset over locale files |
| `limit` | integer | `50` | Max locale files to return |

### `rails_get_mailers`

ActionMailer mailers: every mailer class with its delivery actions and delivery method. A mailer that declares no action of its own - one taking them from a gem base or a mixin, or one called through class methods - is listed with where its actions come from rather than left out. A base other mailers inherit from is not one: it leaves the listing, and a line above names the ones left out. Asked for by name, a base answers with what every mailer below it inherits - its layout, helpers, defaults, callbacks and mixins as the app wrote them, the methods it defines - and which mailers inherit it.

The full listing ends with the Action Mailbox mailboxes: the `routing` rules in
the order Rails tries them, the mailbox each sends to (and whether `app/mailboxes`
defines it), and each mailbox's processing callbacks.

| Parameter | Type | Default | Description |
|:----------|:-----|:--------|:------------|
| `mailer` | string | - | One mailer, by exact name |
| `offset` | integer | `0` | Pagination offset |
| `limit` | integer | `50` | Max mailers to return |

### `rails_get_engines`

What `config/routes.rb` mounts - engines and plain Rack apps alike, with known-engine descriptions, each with the path it answers on when the source spells one out - the app's own in-repo engines, plugins and modules read from the tree, each with the models the model scan filed under its path, and loaded engine classes with route/model counts.

*No parameters.*

### `rails_get_autoload`

Autoloading setup: Zeitwerk vs Classic mode, autoloaders with collapsed/ignored dirs, autoload/eager-load paths, custom inflections.

*No parameters.*

### `rails_get_active_support`

ActiveSupport surface: concerns registry, deprecators, MessageVerifier/MessageEncryptor usage, the `ActiveSupport::Notifications` events the app subscribes to (`subscribe`, `monotonic_subscribe`, and a Subscriber's `attach_to`) with file and line, read from source in both tiers, tagged logging, subscribed `on_load` hooks, cache store. Validator classes living among the concerns are counted and listed apart from them, as `rails_get_concern` does.

*No parameters.*

### `rails_get_env_config`

Per-environment configuration from `config/environments/*.rb`: notable toggles (`force_ssl`, `eager_load`, caching, log level, queue adapter, mailer delivery) and every config key each environment sets. A key assigned in more than one branch reports every value with its condition; booted, the running environment reports the value the app resolved.

| Parameter | Type | Default | Description |
|:----------|:-----|:--------|:------------|
| `environment` | string | - | One environment, by exact name (e.g. `production`) |
| `offset` | integer | `0` | Skip this many config keys per environment |
| `limit` | integer | `50` | Max config keys listed per environment |

<p align="right"><a href="#table-of-contents">↑ back to top</a></p>

---

## Data & Debugging

### `rails_dependency_graph`

Model/service dependency graph in Mermaid or text format.

| Parameter | Type | Default | Description |
|:----------|:-----|:--------|:------------|
| `model` | string | - | Center the graph on this model |
| `depth` | integer | `2` | Hops from the centre model (1-3) |
| `format` | enum | `mermaid` | `mermaid`, `text` |
| `show_cycles` | boolean | `false` | Detect and list circular dependencies |
| `show_sti` | boolean | `false` | Show Single Table Inheritance hierarchies |

Without `model` the graph is capped at 50 nodes, and says so when it cuts.

### `rails_migration_advisor`

Migration code generation with duplicate/nonexistent column warnings, reversibility flags, table name normalization. The generated class is stamped with the app's own Rails version (from the booted app, or from `Gemfile.lock` under `--no-boot`); when neither names one, the output says which version it fell back to.

| Parameter | Type | Default | Description |
|:----------|:-----|:--------|:------------|
| `action` | string | *required* | Migration action (e.g., `add_column`, `create_table`) |
| `table` | string | *required* | Table name |
| `columns` | string | - | Column definitions |
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
| `level` | enum | - | Filter: `debug`, `info`, `warn`, `error`, `fatal` |
| `search` | string | - | Keep lines matching this term. The match runs on the redacted line, so a redacted value cannot be searched for |

### `rails_diagnose`

One-call error diagnosis with classification, context, git blame, and log correlation. It does not call a method undefined when the model's method list could be missing one - a concern's, a parent's, or anything past the payload's own cap.

| Parameter | Type | Default | Description |
|:----------|:-----|:--------|:------------|
| `error` | string | *required* | Error message or class |
| `file` | string | - | File where error occurred |
| `line` | integer | - | Line number |

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

In addition to tools, AI clients can read structured data through **resource templates** - `rails-ai-context://` URIs introspected fresh on every request. Zero stale data.

| URI Pattern | Returns |
|:------------|:--------|
| `rails-ai-context://controllers/{name}` | Actions, inherited filters, strong params |
| `rails-ai-context://controllers/{name}/{action}` | Action source with applicable filters |
| `rails-ai-context://views/{path}` | View template content |
| `rails-ai-context://routes/{controller}` | Live route map for controller |
| `rails-ai-context://models/{name}` | Model details: associations, validations, schema |

The legacy `rails://models/{name}` form is still accepted.

Plus 9 static resources (schema, routes, conventions, gems, controllers, config, tests, migrations, engines).

<p align="right"><a href="#table-of-contents">↑ back to top</a></p>

---

<div align="center" markdown="1">

**[← Quickstart](QUICKSTART.md)** · **[Recipes →](RECIPES.md)**

[Back to Home](index.md)

</div>
