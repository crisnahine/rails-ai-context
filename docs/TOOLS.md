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

Most lookup tools accept a **`detail`** parameter: `summary` (compact), `standard` (default), or `full` (everything). Start with summary, drill down as needed. Composite tools (`rails_get_context`, `rails_analyze_feature`) do not accept `detail`.

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
| `pattern` | string | *required* | Regex pattern to search for. With `definition` or `class`, a plain method or constant name matches literally (`valid?`), anything else as a regex (`generate_.*`) |
| `path` | string | - | Subdirectory or file to search (relative to Rails root); a file is searched whatever its type or ignore files say, as ripgrep does, unless it is sensitive |
| `match_type` | enum | `any` | `any`, `definition` (def lines whose method name contains the pattern), `class` (class/module lines whose name contains it), `call`, `trace` |
| `file_type` | string | - | Filter by extension (`rb`, `erb`, `js`, etc.) |
| `exact_match` | boolean | `false` | Literal, whole-word match. `def reblog?` does not match `def reblog` |
| `exclude_tests` | boolean | `false` | Skip test/spec directories |
| `group_by_file` | boolean | `false` | Group results by file with counts |
| `context_lines` | integer | `2` | Lines of context around each match, max 5 |
| `offset` | integer | `0` | Skip this many emitted lines |
| `limit` | integer | auto | Max lines to return; the default is sized in matches, and a limit too small for one match and its context still returns that match |

The header counts matches, not emitted lines, so below the cap it does not move with `context_lines`. The cap always holds the first match and the context before it, so a `max_search_results` below `context_lines + 1` is raised to that rather than answering "No results found". When the search hits the cap (a cap on emitted lines) the header says `first N lines scanned` and marks the count `N+`: it is then the matches among the lines that were scanned, a floor rather than the total, so it falls as `context_lines` grows. `offset` and `limit` count lines, so a search with context returns more lines than matches. A limit smaller than one match's context block would hold only context, so the page starts at the next match instead and says so.

> **Trace mode** returns definition + source code + every caller grouped by file and labelled by type + tests - replaces 4-5 sequential file reads.

Without ripgrep on the PATH, the Ruby fallback returns the rows ripgrep would, context lines and the line cap included, from the files ripgrep would search: no hidden files, no symlinks followed, no binary files (a NUL byte in the first 64 KiB), and ignore files read with ripgrep's precedence, where the file type decides before depth: any `.rgignore`, then any `.ignore`, then any `.gitignore`, then `.git/info/exclude`, then the global excludes file, the deepest file first within a type. `.ignore` and `.rgignore` apply everywhere, including the directories above the app; the git files apply only inside a repository and only as far up as the nearest `.git` (a file for a worktree or submodule), whose `info/exclude` is the only one read. Patterns match case-sensitively.

Redaction treats a value under a secret-named key as a secret unless it is clearly something else: shorter than eight characters (four under a password-type key: `password`, `passwd`, `pass`, `pin`, `passphrase`), containing whitespace (a message; not under `passphrase`), a URL, an email address or a hostname (not under a password-type key), a URL query (`?mode=safe`) or a path (two slashes, no `+` or `=`), a placeholder (`<token>`, `${VAR}`, `%{var}`, a `{name}` slot, `xxxx`, `your-...`, `put-your-key-here`), a version (`2.4.1`, `v2`) or a date, an HTTP header name (`X-Api-Key`; not under a password-type key), an env name (capitals joined by `_`, led by `_` or `HTTP_` or naming a secret word, like `_DISCOURSE_API`), a name spelled from a secret word (`user_api_key`; not under a password-type key, where `admin_password` is the password), the key's own name (an enum's `password: 'password'`), or not ASCII. Keys ending `_url`, `_error`, `_use` and the like describe a secret rather than hold one. A call or block whose first argument names a secret holds its value too (`ENV.fetch("SECRET_KEY_BASE", "...")`, `let(:api_key) { "..." }`, `option :client_secret, default: "..."`, a `credentials.fetch` default); a ternary's `? "a" : "b"` is two values, not a key and its value. Under a name that ends in `_KEY`, `Key` or `key` without a secret word (`ALGOLIA_ADMIN_KEY`, `apiKey`), a value is filtered only when it looks like a credential: a run of 16+ characters mixing letters and digits, or a known token format; a cache or i18n key (`views/posts/1`, `users.index.title`), a storage key (`wp-content/uploads/...`), a word, a path or a header name is kept. Log lines use the same rule. An unquoted `NAME=value` with a secret-named name, in any file (shell, Dockerfile `ENV`, compose, env, code), has its value filtered unless it is `$VAR`, `${...}`, `#{...}` or ERB; the value ends at the first quote, bracket, `&`, `,`, `;` or space, so in a URL query (`?token=...&page=2`) only the value goes. A `:name=` setter symbol and a `(?<=name=` lookbehind are not assignments. In an example file (`*.example`, `*.sample`, `*.template`) a value under a secret-named key is kept only when it is plainly a placeholder: a placeholder shape above, or up to 20 characters of words with no digits (`changeme`, `your_password_here`). Locale files are filtered only for credential formats.

### `rails_get_edit_context`

Method-aware code extraction with surrounding class context. Every line returned passes through redaction, so in a file no pattern names a string literal under a secret-named key (8+ characters, unless it is clearly not a credential: a message, URL, path, placeholder, version, date, header, env or parameter name, or a translation) or in a known credential format (vendor tokens, JWTs, a PEM or PGP private key) reads as `[FILTERED]`; code, ENV lookups, ERB and placeholders are never rewritten, so the text stays usable as the text to replace.

| Parameter | Type | Default | Description |
|:----------|:-----|:--------|:------------|
| `file` | string | *required* | File path relative to Rails root |
| `near` | string | *required* | What to find in the file: a method name, keyword or string (e.g. `def index`, `validates`, `STATUSES`) |
| `context_lines` | integer | `5` | Lines of context above and below the match |

<p align="right"><a href="#table-of-contents">↑ back to top</a></p>

---

## Understand

### `rails_analyze_feature`

Full-stack feature analysis: models + controllers + routes + services (with the files that call them) + admin resources + jobs and Sidekiq workers + views + tests in one call.

| Parameter | Type | Default | Description |
|:----------|:-----|:--------|:------------|
| `feature` | string | *required* | Feature name (e.g., `billing`, `auth`, `subscription`) |

### `rails_get_context`

Composite context: schema + model + controller + routes + views for a resource. Views come from the directory Rails resolves for the controller; a flat-directory fallback is labelled.

| Parameter | Type | Default | Description |
|:----------|:-----|:--------|:------------|
| `controller` | string | - | Controller name (e.g., `PostsController`) |
| `action` | string | - | Specific controller action; requires `controller` |
| `model` | string | - | Model name (e.g., `Post`) |
| `feature` | string | - | Feature keyword (e.g., `post`) |
| `include` | array | - | Extra context to add: `stimulus`, `turbo`, `services`, `jobs`, `conventions`, `helpers`, `env`, `callbacks` |

### `rails_onboard`

Narrative app walkthrough for getting up to speed. The stack line counts the
tables of every database the app's own schema dumps declare, as
`rails_get_schema` reads them; the databases Rails 8 gives Solid Queue, Solid
Cache and Solid Cable get one line, without their tables. It ends with the app's custom
rake tasks (Rakefile, `lib/tasks`, `rakelib`), each with its arguments,
description and file: the first 15 at `standard`, every one at `full`.
Then the app's own generators under `lib/generators` (the `bin/rails generate`
command and its USAGE line), the `lib/templates` files that replace a built-in
generator's template, and the Railties under `lib/` with their initializers.

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
| `limit` | integer | auto | Max tables when listing: 50 for `summary`, 25 for `standard`, 10 for `full` |
| `offset` | integer | `0` | Skip this many tables |
| `format` | enum | `markdown` | `markdown`, `json` |

### `rails_get_model_details`

AST-parsed model internals. The model heading and each scope carry a confidence tag: `[VERIFIED]` or `[INFERRED]` on a booted app, `[STATIC]` without a boot. The method list says how many of the model's methods it is showing.

| Parameter | Type | Default | Description |
|:----------|:-----|:--------|:------------|
| `model` | string | - | Model name (e.g., `User`, `Post`). Omit to list all models |
| `detail` | enum | `standard` | `summary`, `standard`, `full` |
| `limit` | integer | `50` | Max models when listing |
| `offset` | integer | `0` | Skip this many models |

Returns: associations, validations, scopes, enums, callbacks, macros, methods, concerns.
What the included concerns declare is merged in, so the answer does not stop
at the model file. A concern whose file could not be read is named under
Concerns as `[UNAVAILABLE]` rather than dropped.

### `rails_get_callbacks`

Callbacks grouped by type, in Rails event order, with source code at
`detail:"full"`. The list
covers concern-declared callbacks too, with the body read from the concern
file, and the "From Concerns" section says which concern declared each one.
Within one type the order is the order Rails runs them: base classes first, a
concern's callbacks where its `include` line stands, then the model's own, and
a `before_` or `around_` callback with `prepend: true` first. `after_commit`
and `after_rollback` are last declared first unless the app turns on
`run_after_transaction_callbacks_in_order_defined` (`load_defaults 7.1`). A
method declared again for one type shows once, with the later declaration's
conditions, as Rails keeps it. A block or a lambda is listed as
`[inline_block]`, and `detail:"full"` prints its declaration. turbo-rails'
`broadcasts`, `broadcasts_to`, `broadcasts_refreshes` and
`broadcasts_refreshes_to` are listed as the commit callbacks they declare
(`broadcasts_refreshes (turbo-rails)` under `after_create_commit`,
`after_update_commit` and `after_destroy_commit`), and `detail:"full"` names
the method each one runs. The order is read from source in both tiers,
and dynamic dispatch is not evaluated: a callback registered through
`send(:before_save, ...)`, through a method called with `send` or defined with
`define_singleton_method`, or through a module included in `class << self` is
not read, so the list can miss it or show the definition it replaces.

| Parameter | Type | Default | Description |
|:----------|:-----|:--------|:------------|
| `model` | string | - | Model name. Omit to list every model with its callbacks |
| `detail` | enum | `standard` | `summary`, `standard`, `full` |

### `rails_get_concern`

Concern methods, their source code at `detail:"full"`, and which models include it. A class under
`app/models/concerns` that subclasses `ActiveModel::Validator` is listed as a
validator rather than a concern, and its users are the models that name it in
`validates_with`. The rule reads the class the file is named for, so a concern
that nests its own validator class stays a concern. Every concern is named by
the constant its file declares, so an app inflection (`sdg/tag_list.rb`
declaring `SDG::TagList`) is answered under the name the app has.

The private methods are listed under their own heading, since an includer
gets them too, and the listing counts them apart from the public ones. The
macros an `included` block declares are listed, `helper_method` among them. An
`include` under a condition (`include Pagy::Backend if defined?(Pagy::Backend)`)
carries the condition; on a booted app it also says when the module is not
defined, so was never mixed in.

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
| `action` | string | - | Specific action; requires `controller` |
| `detail` | enum | `standard` | `summary`, `standard`, `full` |
| `limit` | integer | `50` | Max controllers when listing |
| `offset` | integer | `0` | Skip this many controllers |

### `rails_get_routes`

Routes with code-ready helpers (`post_path(@record)`) and required params. A
fully qualified controller key answers with its own routes only; a short name
reaches the controller whose trailing segments it spells, and not the ones that
merely start with it. Rack apps attached with `mount`
or `match ... to:` are named with the path they answer on, when the source
spells one out. A mounted Grape API lists its endpoints under the mount (verb,
full path, declared params), read from its classes in `app/api` and `lib/api`;
the summary counts them.

`app_only` leaves out the routes Rails' engines and gems draw on their own:
Active Storage, Action Mailbox's ingresses and its conductor, Turbo Native's
navigation routes, and Rails' development pages (`rails/info`, `rails/mailers`,
`rails/welcome`), as `config.excluded_route_prefixes` lists them. A route the
app's own route files declare is an app route, so `devise_for :users` and the
`get "up" => "rails/health#show"` health check are listed. A `controller` filter
searches every route, so `controller:"devise/sessions"` or
`controller:"active_storage/blobs"` answers whatever `app_only` says.

| Parameter | Type | Default | Description |
|:----------|:-----|:--------|:------------|
| `controller` | string | - | Filter by controller; searches every route, framework ones included |
| `detail` | enum | `standard` | `summary`, `standard`, `full` |
| `limit` | integer | auto | Max routes to return; the default depends on `detail` |
| `offset` | integer | `0` | Skip this many routes |
| `app_only` | boolean | `true` | Leave out the routes Rails' engines and gems draw on their own (see above) |

<p align="right"><a href="#table-of-contents">↑ back to top</a></p>

---

## Views & Frontend

### `rails_get_view`

View templates with instance variables, Turbo frames, Stimulus controllers, partial locals. Includes schema hints for detected ivars. A template directly under `app/views` is grouped as `(app/views root)`, which `path:` reaches and `controller:` does not.

| Parameter | Type | Default | Description |
|:----------|:-----|:--------|:------------|
| `controller` | string | - | Controller name |
| `path` | string | - | Specific view path relative to `app/views` (e.g., `posts/index.html.erb`); returns its content |
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

The change callbacks Stimulus runs itself (`countValueChanged`,
`itemTargetConnected`, `resultsOutletDisconnected`) are listed with the
lifecycle hooks, not as actions. The copy-paste markup at `full` detail wires
each action to the events the app's own templates use (`input->search#queue`),
and to no named event, so the element's default, when no template wires it; it
leaves out a method no template names that the controller calls itself, and
carries a `data-*-class` and `data-*-outlet` attribute for each class and
outlet the controller reads.

| Parameter | Type | Default | Description |
|:----------|:-----|:--------|:------------|
| `controller` | string | - | Stimulus controller name |
| `detail` | enum | `standard` | `summary`, `standard`, `full` |
| `limit` | integer | `50` | Max controllers when listing |
| `offset` | integer | `0` | Skip this many controllers |

### `rails_get_partial_interface`

What locals to pass to a partial and what methods are called on them. Render sites are `render` calls, a `partial:` passed to a Turbo Stream action (`turbo_stream.prepend`) or a broadcast (`broadcast_prepend_to` in a model, controller, job or channel), and jbuilder's `json.partial!` and `json.array! ..., partial:`. A site counts only where Rails would render this file: `_post.html.erb` gets the html, Turbo Stream and broadcast sites and `_post.json.jbuilder` the jbuilder ones, and `render "comments/form"` names comments' form, never the one beside the view. A jbuilder partial's locals are the bare names it reads; a helper, a route helper or a call with parentheses is not a local.

| Parameter | Type | Default | Description |
|:----------|:-----|:--------|:------------|
| `partial` | string | *required* | Partial path (e.g., `users/form`); a bare name that matches several partials lists them instead of answering |
| `detail` | enum | `standard` | `summary`, `standard`, `full` |

### `rails_get_turbo_map`

Turbo Stream broadcast-to-subscription wiring with mismatch warnings. Streams are compared the way Turbo names them, part by part: a record by its model, a symbol or string by its text. So `broadcast_prepend_to [product, :reviews]` (or `broadcast_prepend_to product, :reviews`) in Review, whose `product` is a belongs_to, reaches `turbo_stream_from @product, :reviews`, and `broadcasts_refreshes` reaches `turbo_stream_from @product` on update and destroy and the model's plural stream on create. In a view, `current_user` and `Current.user` name a User record. A part that names nothing the map can resolve (no model by that name, a method rather than an association) is reported as "can't tell", never as a mismatch.

| Parameter | Type | Default | Description |
|:----------|:-----|:--------|:------------|
| `detail` | enum | `standard` | `summary`, `standard`, `full` |
| `stream` | string | - | Filter by stream or channel name (e.g., `notifications`); a name no broadcast or subscription carries says so and lists the app's streams |
| `controller` | string | - | Filter by controller name (e.g., `messages`) |

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
| `model` | string | - | Model to generate a model test for (e.g., `User`) |
| `controller` | string | - | Controller to generate a request test for (e.g., `PostsController`) |
| `file` | string | - | File to generate tests for, relative to Rails root; the type is detected (a job gets a job test under test/jobs or spec/jobs) |
| `type` | enum | `unit` | `unit`, `request`, `system`. With `model` or `controller`, `system` writes a system test that visits the subject's index and show pages |

When the subject's test file exists already, the cases come anyway, addressed to that file, to add the ones it lacks. A controller behind a login filter gets a test that signs in with the app's own sign-in helper (Rails 8's `sign_in_as`, or one its suite defines) and a users fixture or factory; without one, a TODO says the requests are redirected or refused until the test signs in. Devise and Doorkeeper keep their own sign-in lines.

### `rails_validate`

Syntax + semantic + Brakeman security validation in one call.

JavaScript (`.js`, `.mjs`, `.cjs`) is parsed by `node --check` as the module system Node would load it with: the extension, else the nearest `package.json`'s `type`, else a module when CommonJS rejects only its `import`/`export` (a Stimulus controller). A failure names the line and column node reports. A file node cannot judge is listed as skipped with the reason, not as passed: JSX, or no `node` on the PATH, where only an unmatched bracket still fails.

| Parameter | Type | Default | Description |
|:----------|:-----|:--------|:------------|
| `files` | array | required | File paths to validate |
| `level` | enum | `syntax` | `syntax`, `rails` (rails includes the Brakeman security pass) |

### `rails_security_scan`

Brakeman static analysis: SQL injection, XSS, mass assignment, command injection.

| Parameter | Type | Default | Description |
|:----------|:-----|:--------|:------------|
| `files` | array | - | File paths to filter results to (omit to scan the whole app) |
| `confidence` | enum | `weak` | Minimum confidence: `high`, `medium`, `weak` (`weak` shows every warning) |
| `checks` | array | - | Run only these Brakeman checks, by class name (e.g., `CheckSQL`) |
| `detail` | enum | `standard` | `summary`, `standard`, `full` |

> Requires the `brakeman` gem. When the app's bundle does not carry it but the
> machine has it, the scan runs brakeman as its own process from outside the
> bundle and says so: the installed gem's own `bin/brakeman`, run by the app's
> Ruby, not whatever `brakeman` is on PATH. When no scan can run, the answer
> says which case it is: brakeman is nowhere on the machine, or it is
> installed and produced no report.

### `rails_performance_check`

N+1 query risks, missing indexes, missing counter_cache, eager load candidates.

An N+1 risk is an association call on a record that a loop hands out. Each
action's body and the before filters that run for it say what its instance
variables hold (`@reviews = @product.reviews.latest`, `@orders =
current_user.orders`), and its templates and the partials they render say what
walks them: `@reviews.each do |review|`, `render @reviews`, `render partial:,
collection:`, `json.array!`, or a loop record passed to a partial as a local.
A `review.user` read there is a risk; the same name anywhere else is not. The
row names the action and the view the call sits in. `high` means the query
preloads nothing, `medium` that it preloads other associations, and `low` that
it preloads this one. `.count` on an association runs a query per record even
when preloaded, so it stays `high`. `.size`, `.any?`, `.empty?` and `.none?` on
a has_many whose other side keeps a `counter_cache` read the counter column, so
they are not a risk. The inverse Rails sets on each record of
`@product.reviews` (`review.product`) is not a risk, and a branch on a local
the render passes as a literal (`show_seller: false`) is not read. ERB and
jbuilder are read; Haml and Slim templates are not, and neither are serializers.

| Parameter | Type | Default | Description |
|:----------|:-----|:--------|:------------|
| `model` | string | - | Filter results to one model |
| `category` | enum | `all` | `n_plus_one`, `counter_cache`, `indexes`, `model_all`, `eager_load`, `all` |
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

Auth checks, flash messages, create action template, test patterns, and the admin resources ActiveAdmin, Administrate, Avo, Madmin and Trestle register (with ActiveAdmin's permitted params).

*No parameters.*

### `rails_get_config`

Database config, auth framework, assets, cache, queue, Action Cable. The `use` and `map` calls in `config.ru` are listed apart from the stack, since they run before Rails.

*No parameters.*

### `rails_get_gems`

Notable gems with versions, categories, and config file locations. A config
location is printed only when the app has that file, and an initializer is
found under a load-order prefix too (`config/initializers/3_omniauth.rb`).

| Parameter | Type | Default | Description |
|:----------|:-----|:--------|:------------|
| `category` | enum | `all` | `auth`, `jobs`, `frontend`, `api`, `database`, `files`, `testing`, `deploy`, `monitoring`, `admin`, `pagination`, `search`, `forms`, `server`, `notifications`, `validation`, `utilities`, `services`, `payments`, `all` |
| `offset` | integer | `0` | Skip this many gems |
| `limit` | integer | `50` | Max gems to return |

### `rails_get_env`

Environment variables + credentials keys (values are never exposed). Scans `.rb`, `.rake`, ERB views and config YAML under `app`, `config` and `lib`, plus `config.ru`, `db/seeds.rb`, `db/seeds/` and the Ruby scripts in `bin/`. A tag on a YAML comment line is not read: ERB runs it, but what it writes goes with the comment. Config YAML matching `sensitive_patterns` (`config/database.yml`, `config/cable.yml`, `config/storage.yml` and the rest) is read only for the ENV names in its ERB tags, so a default there is listed as present and not read; credentials and keys are never read, and the answer says so. A default is read from a second argument or from a block whose one statement is a literal (`ENV.fetch("REDIS_URL") { "redis://localhost:6379/1" }`). The env Kamal's `config/deploy.yml` gives the app container is listed too: secret names only, and clear values, except one holding a URL or a key-like token, or under a secret-named variable, which shows as hidden, and one an ERB tag sets, which says so. So are the setting keys in the config gem's `config/settings.yml` and `config/settings/<env>.yml` when the bundle has the config gem, and the attributes of each `Anyway::Config` class in `config/configs` or `app/configs` with the env name it reads (`PAYMENT_API_KEY`), never their values. A variable whose call sites pass different defaults is labelled as such rather than with one site's default; `detail:"full"` names each site's. A default is redacted by the rule a source literal gets: a credential format under any name, a URL's password, and under a secret-named variable a value that is not clearly something else, so an address, URL or hostname default prints as written.

| Parameter | Type | Default | Description |
|:----------|:-----|:--------|:------------|
| `detail` | enum | `standard` | `summary`, `standard`, `full` |

### `rails_get_helper_methods`

Application and framework helpers, with view cross-references at `detail:"full"`.

| Parameter | Type | Default | Description |
|:----------|:-----|:--------|:------------|
| `helper` | string | - | Helper module name (e.g., `ApplicationHelper`). Omit to list all helpers |
| `detail` | enum | `standard` | `summary`, `standard`, `full` |
| `offset` | integer | `0` | Skip this many helpers |
| `limit` | integer | `50` | Max helpers to return |

### `rails_get_service_pattern`

Service object interface, dependencies, side effects, callers, read from
`app/services/`, `app/interactions/` and `app/interactors/`. An interactor
organizer lists the steps it runs, in order. An
ActiveInteraction's inputs include the ones it inherits, with the filters
nested inside a `hash` filter shown under it. Callers are read from every
`app/` and `lib/` tree, and on a booted app from any other directory it
autoloads, and the page says when the twenty-caller display cap or the scan's
own file ceiling left the list partial. A module under
`app/services/concerns/` is a concern rather than a service object, so
`rails_get_concern` lists it and this tool does not.

| Parameter | Type | Default | Description |
|:----------|:-----|:--------|:------------|
| `service` | string | - | Service class name or filename. Omit to list all services |
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
answers a worker name as well as a job name. A job's own page shows its
`queue_with_priority`, `enqueue_after_transaction_commit` and Solid Queue
`limits_concurrency` (its own or the nearest base's), every `retry_on` option,
Sidekiq's `sidekiq_retry_in` and `sidekiq_retries_exhausted` blocks, and its
enqueue, perform and discard callbacks as written. A job that includes
`ActiveJob::Continuable` (itself or through a base) is marked continuable, with
the steps its `perform` runs in order, each a block or a method. A model method
delayed_job's `handle_asynchronously` wraps is listed as a background method with
its options, here and on the model's `rails_get_model_details` page. The listing names the queues
`config/sidekiq.yml` declares and the queues Solid Queue's workers poll in
`config/queue.yml` (this environment's section), and names each job queue no
worker polls; that job's page says so beside its queue.

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
| `offset` | integer | `0` | Skip this many components |
| `limit` | integer | `50` | Max components to return |

### `rails_get_i18n`

I18n setup: default/available locales, backend, locale files with key counts, per-locale coverage, fallbacks.

| Parameter | Type | Default | Description |
|:----------|:-----|:--------|:------------|
| `locale` | string | - | Show only this locale's files and coverage, by exact name |
| `offset` | integer | `0` | Pagination offset over locale files |
| `limit` | integer | `50` | Max locale files to return |

### `rails_get_mailers`

ActionMailer mailers: every mailer class with its delivery actions and delivery method. A mailer that declares no action of its own - one taking them from a gem base or a mixin, or one called through class methods - is listed with where its actions come from rather than left out. A base other mailers inherit from is not one: it leaves the listing, and a line above names the ones left out. Asked for by name, a base answers with what every mailer below it inherits - its layout, helpers, defaults, callbacks and mixins as the app wrote them, the methods it defines - and which mailers inherit it.

Each mailer also shows its own `default`, `layout`, `helper` and action and
deliver callbacks as written, the template formats of each action under
`app/views/<mailer>`, and its preview class with the emails it previews (read
from `test/mailers/previews`, `spec/mailers/previews` and the
`action_mailer.preview_paths` the config adds). The full listing opens with the
queue `deliver_later` uses (ActionMailer's setting booted; the config's
statically, ActiveJob's default queue from `load_defaults` 6.1 on), the
interceptors and observers the config registers, and the preview paths.

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

Per-environment configuration from `config/environments/*.rb`: notable toggles (`force_ssl`, `eager_load`, caching, log level, queue adapter, mailer delivery) and every config key each environment sets. A key assigned in more than one branch reports every value with its condition; booted, the running environment reports the value the app resolved. An
"Every environment" block above them lists the keys `config/application.rb`
sets (`config.x` included) and, for each `config_for(:name)`, the keys
`config/name.yml` gives the running environment, `shared` merged in, names
only.

| Parameter | Type | Default | Description |
|:----------|:-----|:--------|:------------|
| `environment` | string | - | One environment, by exact name (e.g. `production`) |
| `offset` | integer | `0` | Skip this many config keys per environment |
| `limit` | integer | `50` | Max config keys listed per environment |

<p align="right"><a href="#table-of-contents">↑ back to top</a></p>

---

## Data & Debugging

### `rails_dependency_graph`

Model association graph in Mermaid or text format.

| Parameter | Type | Default | Description |
|:----------|:-----|:--------|:------------|
| `model` | string | - | Center the graph on this model |
| `depth` | integer | `2` | Hops from the centre model (1-3) |
| `format` | enum | `mermaid` | `mermaid`, `text` |
| `show_cycles` | boolean | `false` | List circular dependencies: chains of foreign keys that lead back to the model they start from, through another |
| `show_sti` | boolean | `false` | Show Single Table Inheritance hierarchies |

The graph is capped at 50 nodes, with or without `model`, and says so when it cuts.

A polymorphic `belongs_to` lists the models that implement it, the ones that declare `as:` for it. A cycle follows foreign keys, one edge per key from the table that holds it: a `belongs_to` and the `has_many` or `has_one` at its other end are one key, so two models joined both ways are not a cycle, and neither is a key to the model's own table. With `show_cycles` and no cycle, the answer says none.

### `rails_migration_advisor`

Migration code generation with duplicate/nonexistent column warnings, reversibility flags, table name normalization. The generated class is stamped with the app's own Rails version (from the booted app, or from `Gemfile.lock` under `--no-boot`); when neither names one, the output says which version it fell back to.

Before the code it warns about what the app's migrations already hold: a
file already named what the generator would name this one (`rails generate
migration` refuses that name), and a migration not yet run that already adds
the column or creates the table. It also warns about a `create_table` for a
table that exists and a `null: false` column with no default on a table with
rows (the row count is the database's estimate), and refuses a column type no
adapter knows. For `remove_column`, `rename_column` and `change_type` it lists
the lines in `app/`, `lib/` and `config/` that name the column, the code the
change breaks.

| Parameter | Type | Default | Description |
|:----------|:-----|:--------|:------------|
| `action` | enum | *required* | `add_column`, `remove_column`, `rename_column`, `add_index`, `add_association`, `change_type`, `create_table` |
| `table` | string | *required* | Table name |
| `column` | string | - | Column name; for `add_association`, the reference (`user`, `parent`) |
| `type` | string | - | Column type (e.g., `string`, `integer`, `references`); for `add_association` with `column`, the table the reference points at. A `parent` reference with no `parents` table points at its own table |
| `new_name` | string | - | New column name, for `rename_column` only |
| `options` | string | - | Extra options (e.g., `null: false, default: 0`) |

### `rails_search_docs`

Bundled topic index with weighted keyword search. Optional on-demand GitHub fetch.

| Parameter | Type | Default | Description |
|:----------|:-----|:--------|:------------|
| `query` | string | *required* | Search query |
| `source` | enum | `all` | `all`, `guides`, `stimulus`, `turbo`, `hotwire` |
| `limit` | integer | `5` | Max results to return (1-20) |
| `fetch` | boolean | `false` | Fetch the full content from GitHub (cached 24h in `tmp/`) |

### `rails_query`

Safe read-only SQL with layered security: regex validation, a PostgreSQL plan check (whole-row leaks, expanded sensitive columns and VOLATILE admin functions refused before anything runs), `SET TRANSACTION READ ONLY`, timeout, and column redaction. [Learn about the security model →](SECURITY.md)

| Parameter | Type | Default | Description |
|:----------|:-----|:--------|:------------|
| `sql` | string | *required* | SQL query. Only `SELECT`, `WITH`, `SHOW`, `EXPLAIN`, `DESCRIBE` are allowed |
| `limit` | integer | `100` | Maximum rows to return (hard cap: 1000) |
| `format` | enum | `table` | `table`, `csv` |
| `explain` | boolean | `false` | Show query plan instead of results |

> Disabled in production by default.

> Name the columns you need. A query that references a sensitive column (directly, or through an alias or expression), serialises a whole row, carries a column-alias list that renames a wildcard, uses UNION, or calls a session-effecting function is refused with a message that says why. `SELECT *` is allowed and its sensitive columns come back `[FILTERED]`. When the row limit holds rows back, the answer says so in every format.

### `rails_read_logs`

Reverse file tail with level filtering and sensitive data redaction.

| Parameter | Type | Default | Description |
|:----------|:-----|:--------|:------------|
| `file` | string | current environment's log | Log file name in `log/` (e.g., `production`, `sidekiq`); the `.log` suffix is optional. A log that links out of the app is refused and not listed |
| `lines` | integer | `50` | Number of lines, max 500. With `search`, the number of matching lines to show |
| `level` | enum | `all` | Minimum level: `DEBUG`, `INFO`, `WARN`, `ERROR`, `FATAL`, `all` |
| `search` | string | - | Keep lines matching this term, searched for in the last 4 MB of the file (about 50,000 lines of a typical Rails log); the answer says how many lines that was, and whether older ones were left unsearched. The match runs on the redacted line, so a redacted value cannot be searched for |

### `rails_diagnose`

One-call error diagnosis with classification, context, recent git changes, and log correlation. It does not call a method undefined when the model's method list could be missing one - a concern's, a parent's, or anything past the payload's own cap.

A `NoMethodError` is a nil reference only when the receiver is nil; on any other receiver it is an undefined method, and on a booted app the answer names the receiver's closest method (`totl` → `total`). An error it has no rule for names the gem or app file that defines the exception class. The error can be pasted as Ruby prints it (`NoMethodError: ...`) or as a Rails log writes it (`NoMethodError (...)`).

Log correlation reads the last megabyte of the current environment's log, the window `rails_read_logs` reads, and shows the latest entry for the error: the request that raised it (path, controller action, parameters, status, request id when the log is tagged), the error line and the first backtrace frames, redacted. It says so when the log holds no entry for the error.

| Parameter | Type | Default | Description |
|:----------|:-----|:--------|:------------|
| `error` | string | *required* | Error message or class |
| `file` | string | - | File where error occurred. A path refused on policy is named in the answer, which still diagnoses the error and comes back as an error result ([how a refusal is reported](SECURITY.md#how-a-refusal-is-reported)) |
| `line` | integer | - | Line number |
| `action` | string | - | `controller#action` (e.g., `posts#create`); adds that action's context |

### `rails_review_changes`

PR/commit review with per-file context and warnings.

| Parameter | Type | Default | Description |
|:----------|:-----|:--------|:------------|
| `ref` | string | `HEAD` | Git ref to diff against: a branch, a tag, `HEAD~3` or a commit SHA. `HEAD` reviews uncommitted changes. A ref that names no commit is refused |
| `files` | array | - | Review only these changed files (omit for all) |

### `rails_runtime_info`

Live database pool stats, table sizes, pending migrations, cache stats, queue depth.

The pool and the cache are read inside the MCP server process, and the answer says so: the pool's counts are that process's own connections, and a `MemoryStore`'s entries are its own, since each app server process holds its own. A store the processes share (Redis, Memcached, Solid Cache, a file store) is the app's. Another environment that configures a shared store is named, as where the app's cache lives there.

| Parameter | Type | Default | Description |
|:----------|:-----|:--------|:------------|
| `detail` | enum | `standard` | `summary`, `standard`, `full` |
| `section` | enum | - | One section only: `database`, `cache`, `jobs`, `connections` |

### `rails_session_context`

Session-aware context tracking across tool calls within a conversation. Pass `action` or `mark`; a call with neither is an error.

| Parameter | Type | Default | Description |
|:----------|:-----|:--------|:------------|
| `action` | enum | - | `status` (queried tools with timestamps), `summary` (short recap), `reset` (clear this conversation's record) |
| `mark` | string | - | Record a tool and its params as already queried (e.g., `get_schema:users`). The tool must be one the server has; a short name such as `schema` is taken |

Each conversation has its own record: over HTTP, one server process serves every client, and each client's `Mcp-Session-Id` keeps its calls, and its `reset`, to itself. A tool that answers by calling others (`rails_get_context`, `rails_diagnose`, `rails_review_changes`) is recorded as the one call the client made.

<p align="right"><a href="#table-of-contents">↑ back to top</a></p>

---

## Live Resources (VFS)

In addition to tools, AI clients can read structured data through **resource templates** - `rails-ai-context://` URIs introspected afresh on every request, after the app's code is reloaded for any edit.

| URI Pattern | Returns |
|:------------|:--------|
| `rails-ai-context://controllers/{name}` | Actions, inherited filters, strong params |
| `rails-ai-context://controllers/{name}/{action}` | Action source with applicable filters |
| `rails-ai-context://views/{path}` | View template content |
| `rails-ai-context://routes/{controller}` | Live route map for controller |
| `rails-ai-context://models/{name}` | Model details: associations, validations, schema |

The legacy `rails://models/{name}` form is still accepted.

A read for a name the app does not have - a model, a controller, an action, a view - fails with a JSON-RPC `-32602` error whose message gives the reason and whose `data.available` lists the names there are. So does a view over the size cap. A path refused on policy fails as `Resource not found`, without saying why.

Plus 9 static resources (schema, routes, conventions, gems, controllers, config, tests, migrations, engines).

<p align="right"><a href="#table-of-contents">↑ back to top</a></p>

---

<div align="center" markdown="1">

**[← Quickstart](QUICKSTART.md)** · **[Recipes →](RECIPES.md)**

[Back to Home](index.md)

</div>
