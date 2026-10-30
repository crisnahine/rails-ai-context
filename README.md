<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/assets/logo-dark.svg">
    <img src="docs/assets/logo-light.svg" alt="rails-ai-context: ground truth for your coding agent" width="480">
  </picture>
</p>

<h3 align="center">Your coding agent guesses your Rails app. Let it ask.</h3>

<p align="center">
  rails-ai-context turns your Rails app into the source of truth for Claude Code, Cursor, GitHub Copilot,
  OpenCode and Codex CLI: 35 read-only tools answer from the schema, the models, the routes, the controllers
  and the views, over MCP or in any terminal, and still answer when the app cannot boot.
</p>

<p align="center">
  <a href="https://rubygems.org/gems/rails-ai-context"><img src="https://img.shields.io/gem/v/rails-ai-context?color=b4132c&label=gem" alt="Gem version"></a>
  <a href="https://rubygems.org/gems/rails-ai-context"><img src="https://img.shields.io/gem/dt/rails-ai-context?color=b4132c&label=downloads" alt="Downloads"></a>
  <a href="https://github.com/crisnahine/rails-ai-context/actions/workflows/ci.yml"><img src="https://github.com/crisnahine/rails-ai-context/actions/workflows/ci.yml/badge.svg?branch=main" alt="CI status"></a>
  <a href="docs/COMPATIBILITY.md"><img src="https://img.shields.io/badge/Ruby-3.1_to_4.0-b4132c" alt="Ruby 3.1 to 4.0"></a>
  <a href="docs/COMPATIBILITY.md"><img src="https://img.shields.io/badge/Rails-7.0_to_8.1-b4132c" alt="Rails 7.0 to 8.1"></a>
  <a href="LICENSE"><img src="https://img.shields.io/github/license/crisnahine/rails-ai-context?color=b4132c" alt="MIT license"></a>
  <a href="https://registry.modelcontextprotocol.io"><img src="https://img.shields.io/badge/MCP_Registry-listed-b4132c" alt="Listed in the MCP Registry"></a>
</p>

<p align="center">
  <a href="https://crisnahine.github.io/rails-ai-context/">Website</a> ·
  <a href="#try-it-in-your-rails-app">Quick start</a> ·
  <a href="#what-it-does">What it does</a> ·
  <a href="#a-closer-look">A closer look</a> ·
  <a href="#how-it-works">How it works</a> ·
  <a href="docs/TOOLS.md">Tools reference</a> ·
  <a href="CONTRIBUTING.md">Contributing</a>
</p>

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/assets/session-dark.svg">
    <img src="docs/assets/session-light.svg" alt="One session with rails-ai-context, each line from a real answer recorded against the sample app in this repository. It asks about a table: the users table's role column is an integer, not null, default 0, and index_users_on_email is unique. Before it calls an association: User has_many articles, dependent destroy, foreign key author_id. Before it writes an action: the before filter authenticate_user! comes from ApplicationController and is skipped on index and show. Before it writes a test: rspec, factories in spec/factories, 3 files, with the traits in_review and published. It traces a method: 4 call sites, among them article_publisher.rb, a service, with the line return false unless @article.publishable?. When the app cannot boot: a STATIC line says the answer serves static analysis and runtime-only data is marked UNAVAILABLE. Over MCP in Claude Code, Cursor, GitHub Copilot, OpenCode and Codex CLI, or as rails-ai-context tool NAME in any terminal." width="860">
  </picture>
</p>

## Contents

- [What it does](#what-it-does)
- [Try it in your Rails app](#try-it-in-your-rails-app)
- [A closer look](#a-closer-look): the schema, the model, the inherited filters, the trace, the app that cannot boot, the six rules
- [The tools](#the-tools)
- [How it works](#how-it-works)
- [What it costs](#what-it-costs)
- [Questions you should ask first](#questions-you-should-ask-first)
- [What it will not do](#what-it-will-not-do)
- [Install options and configuration](#install-options-and-configuration)
- [Troubleshooting](#troubleshooting)
- [Development](#development)
- [Contributing and security](#contributing-and-security)
- [Learn more](#learn-more)

## What it does

An assistant writing Rails code knows what an average Rails app looks like. Yours has its own columns,
associations, filters and test setup, and the assistant starts every session with none of that. It
writes a migration for a column that exists, calls `user.posts` when the association is `user.articles`,
scaffolds FactoryBot into a fixture suite, and misses the `before_action` a parent controller adds. You
catch it, fix it, re-prompt, and something next to it breaks.

rails-ai-context gives the assistant 35 tools that read the app itself, over MCP from the AI tool or
from the command line. Every answer is read from the app, says how sure it is, and ends with a hint for
the next call.

| When | What the assistant gets | A real line from an answer |
|---|---|---|
| It asks about a table | Columns with types, nulls and defaults, the indexes, the model on the table | `index_users_on_email` on (email) (unique) |
| Before it calls an association | Associations with their options, validations including the implicit ones, enums, scopes, callbacks, concerns | `has_many` **articles** dependent: destroy (foreign_key: :author_id, inverse_of: :author) |
| Before it writes an action | The actions, every filter with where it was inherited from, strong parameters, the layout | `before` **authenticate_user!** _(from ApplicationController)_ (skipped on: index, show) |
| Before it writes a test | The framework, where the factories or fixtures live, their traits, a template in the app's style | **Factories:** spec/factories (3 files) |
| It traces a method | The definition and source, what it calls, every caller grouped by file and kind, the tests | app/services/article_publisher.rb (Service) → 11: return false unless @article.publishable? |
| When the app cannot boot | The same tools, from `config/routes.rb`, the schema dump and the source, saying so | [STATIC] Static mode. Serving static analysis; runtime-only data is marked [UNAVAILABLE] |

Each line comes from [the sample app in this repository](https://github.com/crisnahine/rails-ai-context/tree/main/site/sample_app), a blog with Devise, an admin
namespace, a JSON API, a Sidekiq job and a FactoryBot suite. The website records the whole answers
every time it is built, by running the gem at that commit: [crisnahine.github.io/rails-ai-context](https://crisnahine.github.io/rails-ai-context/#answers).

The install writes the files each AI tool reads, so the assistant knows the tools exist and how to ask:
the MCP config, one root context file with six anti-hallucination rules, and rules that load when a
model, a controller or a migration is open. The tools are read-only, the SQL tool runs inside a
read-only transaction, and files that hold secrets are never served.

## Try it in your Rails app

Open your AI tool at the root of your Rails app and paste this. It installs the gem, sets up the AI
tool you are in, checks the result and tells you the one step left.

<!-- BEGIN install-prompt: kept identical to "Install (recommended)" in docs/PROMPTS.md by spec -->
```text
Install the rails-ai-context gem in this Rails app so you can read its schema, models, routes and code through its tools instead of guessing.

1. Run `ruby -v` and `bundle exec rails -v`. rails-ai-context needs Ruby 3.1+ and Rails 7.0+. If either is older, stop and tell me.
2. Pick TOOL, the key for the AI tool you are: claude (Claude Code), cursor (Cursor), copilot (GitHub Copilot in VS Code), opencode (OpenCode), codex (Codex CLI). If you are another AI tool, stop and tell me to use the "Another MCP client" prompt instead.
3. Run `bundle add rails-ai-context --group development --version '>= 5.35.0'`. If the Gemfile already lists it, run `bundle update rails-ai-context --conservative` instead. Then run `bundle exec rails-ai-context version`: it must print 5.35.0 or newer, the first version with the flags used below. If it is older, the Gemfile pins it: change its rails-ai-context line to `gem "rails-ai-context", ">= 5.35.0", group: :development` and run `bundle update rails-ai-context --conservative`. If Bundler refuses (a frozen or deployment bundle), run `gem install rails-ai-context -v '>= 5.35.0'` instead and use `rails-ai-context init --tools TOOL --defaults` in step 4.
4. Run `bundle exec rails generate rails_ai_context:install --tools TOOL --defaults`. If it fails because the app can't boot, run `bundle exec rails-ai-context init --tools TOOL --defaults` instead; that one reads the source files when the app won't start.
5. Run `bundle exec rails-ai-context tool onboard` (or `rails-ai-context tool onboard` if you used gem install) and check it describes this app.
6. Tell me which files changed, then the "Next step" lines the install printed for TOOL, word for word. I have to do that step before your rails-ai-context MCP tools appear.
```
<!-- END install-prompt -->

Rather type it yourself? In the Gemfile:

```bash
bundle add rails-ai-context --group development
bin/rails generate rails_ai_context:install --tools claude --defaults
```

Standalone, with no Gemfile change:

```bash
gem install rails-ai-context
rails-ai-context init --tools claude --defaults
```

As a Claude Code plugin, which adds the MCP server and gives each session the six rules, and writes no
context files. It runs the installed gem, so install that first:

```bash
claude plugin install rails-ai-context --marketplace crisnahine/rails-ai-context --scope project
```

`--tools` takes `claude`, `cursor`, `copilot`, `opencode`, `codex` or `all`. Without `--defaults` the
generator asks which AI tools you use and what to write. Re-running is safe: it keeps what you have,
adds what is missing, and in a `CLAUDE.md` you wrote it touches only the block between its
`<!-- BEGIN/END rails-ai-context -->` markers.

You need Ruby 3.1 or newer and Rails 7.0 to 8.1, on Linux, macOS or Windows. Optional:
`brakeman` for `security_scan`, `listen` for `watch`, `ripgrep` for a faster `search_code`.

### Then one step in your AI tool

Every AI tool holds a new project MCP server back until you say yes. The install prints the step for
each tool you picked:

| Claude Code | Cursor | GitHub Copilot | OpenCode | Codex CLI |
|:---|:---|:---|:---|:---|
| New session in the app's folder, approve `rails-ai-context`. Check with `/mcp` | Restart, turn it on under MCP in Customize | Trust the workspace, send a chat message. Check with "MCP: List Servers" | Restart in the app's folder. Check with `opencode mcp list` | Trust the project, start a new session. Check with `/mcp` |

Then ask something only your app knows, such as *"what columns does the users table have?"*, and watch
it call `rails_get_schema` instead of guessing. [Every other setup has a prompt](docs/PROMPTS.md): no
Gemfile change, CLI only, MCP only, a whole team, a folder of apps, nothing committed, MCP over HTTP,
Ruby in Docker, another MCP client.

## A closer look

Every block below is the gem's own output for the sample app, read without booting it, trimmed where
it says so. The website shows each one whole, recorded at the commit it was built from.

### The schema, with the model on it

```text
$ rails-ai-context --app-path site/sample_app tool schema --table users --no-boot
## Table: users

**Models:** User
**Primary key:** id

| Column | Type | Null | Default |
|--------|------|------|---------|
| id | bigint | **NO** |  |
| email | string | **NO** | "" |
| encrypted_password | string | **NO** | "" |
| name | string | yes |  |
| role | integer | **NO** | 0 |
| active | boolean | **NO** | true |
| api_token | string | yes |  |

### Indexes
- `index_users_on_api_token` on (api_token) (unique)
- `index_users_on_email` on (email) (unique)

_Next: `rails_get_model_details(model:"User")` for associations, validations, scopes._
```

Trimmed to seven of its twelve columns. With the app booted, the columns come from the database
connection; here they come from `db/schema.rb`, and `db/structure.sql` or the migrations would do.

### Before it calls an association

```text
$ rails-ai-context --app-path site/sample_app tool model_details --model Article --no-boot
# Article [STATIC]

**Table:** `articles`
**File:** `app/models/article.rb` (32 lines)
**Structure:** class definition(1-1) → includes(2-3) → associations(4-6) → macros(7-8) → validations(9-12) → callbacks(13-15) → scopes(16-18) → instance methods(19-22) → private(23-24) → instance methods(25-32)

## Associations
- `belongs_to` **author** (class: User) (inverse_of: :articles) (fk: author_id)
- `has_many` **comments** dependent: destroy

## Validations
- `presence` on author _(implicit from belongs_to)_
- `presence` on title
- `length` on title (maximum: 120)
- `presence` on slug
- `uniqueness` on slug
- `presence` on body (if: :published?)

## Enums
- `status`: draft(0), in_review(1), published(2) [integer]

## Scopes
- `recent` → order(published_at: :desc, created_at: :desc) [STATIC]
- `by_author` → where(author: user) [STATIC]
- `published` → where(status: :published).where.not(published_at: nil) [STATIC]

## Callbacks
- `before_validation`: :assign_slug (on: :create)
- `after_commit (on: :update)`: :notify_author (if: :saved_change_to_status?)

## Concerns
- **Publishable** - publishable?, publish!
```

The model is read with the Prism parser. A scope with a literal body is `[VERIFIED]`, one built at
runtime is `[INFERRED]`, and in the static tier every record is capped at `[STATIC]`, since no record
can claim more than the tier that carries it. The columns section is trimmed out above; the `published`
scope comes from the `Publishable` concern, and the answer says which concern brought which methods.

### Before it writes an action

```text
$ rails-ai-context --app-path site/sample_app tool controllers --controller admin/articles --no-boot
# Admin::ArticlesController

**Parent:** `Admin::BaseController`
**Layout:** `admin` (declared in Admin::BaseController)

## Actions
- `index`
- `publish`
- `show`

## Filters
- `before` **authenticate_user!** _(from ApplicationController)_
- `before` **require_admin** _(from Admin::BaseController)_
- `before` **set_article** (only: show, publish)
```

Every filter that applies, with where it was inherited from, so the assistant never misses the
`authenticate_user!` two classes up. The schema hints for the models the controller touches follow in
the full answer.

### Tracing a method

```text
$ rails-ai-context --app-path site/sample_app tool search_code --pattern 'publishable?' --match_type trace --no-boot
# Trace: `publishable?`

## Definition
**app/models/concerns/publishable.rb:8** in `module Publishable`
```ruby
  def publishable?
    in_review? && body.present? && author.active?
  end
```

## Called from (4 sites)
### app/controllers/admin/articles_controller.rb (Controller) → `POST /admin/articles/:id/publish`
  13: if @article.publishable?
### app/models/concerns/publishable.rb (Model)
  13: raise ArgumentError, "#{self.class.name} #{id} is not ready to publish" unless publishable?
### app/services/article_publisher.rb (Service)
  11: return false unless @article.publishable?
### lib/tasks/articles.rake (Other)
  5: PublishArticleJob.perform_later(article) if article.publishable?

## Tested by (1 reference)
- `spec/models/article_spec.rb` (1 reference)
```

One call in place of a file-by-file search: the definition, what it calls, its siblings, every caller
grouped by file and labelled by kind, with the route a controller caller answers, and the tests. The
"Calls internally" and "Sibling methods" sections are trimmed out above.

### When the app cannot boot

The app-reading commands try a full boot for live reflection. When the boot fails, from a missing
environment variable, an unreachable service or a broken initializer, they answer from the static
tier instead of dying: routes from `config/routes.rb`, the schema from `db/schema.rb`,
`db/structure.sql` or the migrations, models and controllers from their source. Every answer ends
with a tier line, a section that needs a booted app says `[UNAVAILABLE]` with the reason, and
`--no-boot` asks for that tier outright:

```text
_[STATIC] Static mode (static mode requested with --no-boot). Serving static analysis; runtime-only data is marked [UNAVAILABLE]. Run `bundle exec rails-ai-context --app-path site/sample_app doctor` for details._
```

32 of the 40 introspectors answer here. Each declares which of three kinds it is: it reads files only,
it needs live reflection, or it answers from another source such as the schema dump. What a tier can
say is a declaration, so an answer never guesses at what it could not read
([ADR-0002](docs/adr/0002-static-tier-declared-not-detected.md)). The routes engines and gems draw at
boot, and an association a gem adds at boot, are not listed, and the answer says so.

### The six rules

The root context file carries six rules the assistant reads before writing code. That file is
`AGENTS.md`, which Cursor, OpenCode and Codex read and `CLAUDE.md` imports, or `CLAUDE.md` itself when
none of those three is chosen; Copilot reads its own copy in `.github/copilot-instructions.md`.

1. Verify before you write. Never reference a column, association, route, helper, method, class, partial or gem that a tool call in this turn did not confirm.
2. Mark every assumption with `[ASSUMPTION]`. "I'd need to check X first" is a good answer.
3. Training data describes average Rails. This app isn't average. When something feels obviously standard, query anyway.
4. Check the inheritance chain before every edit: inherited filters, concerns, includes, STI parents.
5. Empty tool output is information. "0 callers found" means investigate, it does not mean proceed.
6. Stale context lies. Re-query after writes.

On by default. Turn off with `config.anti_hallucination_rules = false` if you prefer your own. In an
MCP-only or CLI setup, the [ground rules prompt](docs/PROMPTS.md#ground-rules-for-this-session) gives
the assistant the same rules for one session.

## The tools

Every tool is read-only and answers from your app. Over MCP each name carries a `rails_` prefix
(`rails_get_schema`). From the CLI the short name works: `schema`, `get_schema` and `rails_get_schema`
all resolve. About half take `detail=summary|standard|full`.

| Category | Tools |
|:---|:---|
| Search and trace | `search_code`, `get_edit_context` |
| Understand | `analyze_feature`, `get_context`, `onboard` |
| Schema and models | `get_schema`, `get_model_details`, `get_callbacks`, `get_concern` |
| Controllers and routes | `get_controllers`, `get_routes` |
| Views and frontend | `get_view`, `get_stimulus`, `get_partial_interface`, `get_turbo_map` |
| Testing and quality | `get_test_info`, `generate_test`, `validate`, `security_scan`, `performance_check` |
| App config and services | `get_config` (sections: app, gems, frontend, api, engines, conventions, autoload, active_support, env, env_config, i18n), `get_helper_methods`, `get_service_pattern`, `get_job_pattern`, `get_component_catalog`, `get_mailers` |
| Data and debugging | `dependency_graph`, `migration_advisor`, `search_docs`, `query`, `read_logs`, `diagnose`, `review_changes`, `runtime_info`, `session_context` |

Four worth knowing on day one:

- **`search_code` with `match_type=trace`** returns the definition, the source, every caller grouped by file and labelled by kind, and the tests, in one call.
- **`get_controllers`** returns the action source with inherited filters, strong params and the render map.
- **`get_model_details`** returns associations, validations, scopes, enums and macros from the AST, each tagged `[VERIFIED]` or `[INFERRED]`.
- **`query`** runs read-only SQL inside a read-only transaction, with a timeout, a row limit and column redaction.

Parameters for all 35 are in the [tools reference](docs/TOOLS.md); worked examples in
[recipes](docs/RECIPES.md). MCP clients can also read five resource templates, such as
`rails-ai-context://models/{name}` and `rails-ai-context://controllers/{name}/{action}`, and nine
static resources, such as `rails://schema` and `rails://routes`.

## How it works

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/assets/pipeline-dark.svg">
    <img src="docs/assets/pipeline-light.svg" alt="Two columns. What a tool call does: the call arrives over MCP or from the command line, the registry resolves it among 35 auto-registered tools, 40 introspectors read the app with live reflection when it boots and from the routes file, the schema dump and the source when it does not, Prism parses each file once into a cache keyed by content and one walk feeds every listener, each record is tagged VERIFIED, INFERRED or STATIC and the result is cached with a fingerprint of the app, and the answer is composed with schema hints, a cut at the response budget, a tier line and a hint for the next call. What the install writes: the MCP config each chosen tool reads, one root context file that AGENTS.md carries and CLAUDE.md imports with a copy for Copilot, rules that load where they apply, six anti-hallucination rules, its own configuration, and nothing you wrote." width="860">
  </picture>
</p>

40 introspectors read the app, one per kind of fact: the schema, the models, the routes, the
controllers, the views, the jobs, the gems, the conventions and so on. Each returns a hash and is
registered under a key, so a preset is a list of keys: `:full` runs all 40 and `:standard` runs 17.

The models and the controllers are read with Prism, Ruby's own parser. Each file is parsed once into a
cache keyed by its content, and a single walk over the tree feeds every listener at the same time:
associations, validations, scopes, enums, callbacks, macros, strong parameters. A listener tags each
record by how it was read: `[VERIFIED]` for a literal, `[INFERRED]` for an expression that only runs at
runtime. Introspection is cached with a fingerprint of the app's files, so an edit to a model is seen
on the next call without a restart.

A tool composes its answer from that context, hydrates it with schema hints for the models it
touches, cuts it at the response budget, and ends it with a tier line and a hint for the next call.
Three transports reach the same registry: MCP over stdio, MCP over HTTP mounted inside the app, and
the command line with no server at all.

[Architecture](docs/ARCHITECTURE.md) has the modules and the request lifecycle,
[Introspectors](docs/INTROSPECTORS.md) the catalogue of listeners and the rule for what is read from
the AST, and [the ADRs](https://github.com/crisnahine/rails-ai-context/tree/main/docs/adr) the decisions with their reasons.

## What it costs

It is free and MIT licensed. What you pay is tokens, and only when the assistant asks:

- **A tool answer** is a few hundred to a few thousand tokens, sized by its `detail` level and cut at
  `max_tool_response_chars`. Start with `summary` and drill down.
- **The root context file** is held to 12,000 bytes in its default compact mode, and a rule file to
  8,000, since they share the agent's context with your own instructions.
- **The last line of every answer**, which asks the assistant to offer you an issue when the gem itself
  answered wrong, costs about 40 tokens. `config.report_issue_line = false` leaves it out.

## Questions you should ask first

**Does it send my code anywhere?** No. The tools run on your machine, in your app's process or in a
child of it. Two things go online: `search_docs` fetches Rails guides from GitHub when called with
`fetch: true`, and the standalone binary asks rubygems.org for the latest version at most once a day,
in a child process that sends nothing about the app. `RAILS_AI_CONTEXT_NO_UPDATE_CHECK=1` turns that
off, and it is off in CI.

**Can it read my secrets?** Files that hold them are never served: `.env`, `config/master.key`,
`credentials.yml.enc`, `config/database.yml`, keys and certificates, on a list you can extend. Logs
are redacted before they leave the process, `get_config` shows credential key names without values,
and `query` never returns an encrypted column. [Security](docs/SECURITY.md) has every layer.

**Can it change my database?** No. Every tool is read-only. `query` allows `SELECT`, `WITH`, `SHOW`,
`EXPLAIN` and `DESCRIBE`, runs inside a read-only transaction with a statement timeout, caps the rows,
redacts secret columns, and on PostgreSQL plans the statement first and refuses a plan that reaches a
secret column by another name.

**What does it write into my repository?** The MCP config for each AI tool you picked, one root
context file with a copy for Copilot, rules files per tool, its own config and two `.gitignore` lines.
A re-run keeps your lines and adds what is missing; `uninstall` takes back only what it wrote. A team
that wants no AI files in the repo can skip the install: the tools work with none of it.

**Is the HTTP endpoint safe?** Mounted inside the app it inherits your routing, auth and middleware.
Outside development and test it refuses every request with a 403 unless you set
`config.allow_http_in_production = true`, since it has no authentication of its own.

**Which AI tools?** Claude Code, Cursor, GitHub Copilot, OpenCode and Codex CLI get context files and
MCP config written for them. Any other MCP client, such as Claude Desktop, Windsurf, Zed or a JetBrains
IDE, gets an entry from `rails-ai-context mcp-entry`. A tool with no MCP at all gets the CLI setup,
where the context files name the shell commands.

## What it will not do

- **Write to your app or your database.** It reads. The assistant still decides what to do with the
  facts, and the six rules ask it to verify before writing; nothing enforces that.
- **Say more than it read.** Without a boot, 32 of 40 introspectors answer and the rest say
  `[UNAVAILABLE]`. `query`, `runtime_info` and `doctor` need a booted app, and `query` a database.
- **Support Rails 9.** The gemspec caps `railties` below 9.0, and the standalone binary warns when it
  boots one. [Compatibility](docs/COMPATIBILITY.md) has the CI matrix: 17 Ruby and Rails pairs on
  Linux, plus macOS and Windows legs.
- **Fork on Windows.** `query` on SQLite runs without its time limit there, and the MCP configs start
  the server through `cmd /c`, since a gem's executables on Windows are batch files.

## Install options and configuration

Three setups, picked at install time with a flag, or afterwards with the
[change the setup](docs/PROMPTS.md#change-the-setup) prompt:

| Setup | Writes | Flag | Good for |
|:---|:---|:---|:---|
| **MCP + context files** | MCP config and context files | `--mcp` (the default) | Most apps |
| **CLI only** | Context files that name shell commands | `--cli` | Tools without MCP, or no server to approve |
| **MCP only** | MCP config only | `--mcp-only` | Teams that keep their own `CLAUDE.md` / `AGENTS.md` |

**MCP over stdio** is the default. Each AI tool gets its own config file (`.mcp.json`,
`.cursor/mcp.json`, `.vscode/mcp.json`, `opencode.json`, `.codex/config.toml`) that starts
`bundle exec rails-ai-context serve`, or `rails-ai-context serve` standalone. **MCP over HTTP** mounts
the server inside your app:

```ruby
# config/routes.rb
mount RailsAiContext::Engine, at: "/mcp" if defined?(RailsAiContext::Engine)
```

The `if` keeps the routes file loading where the gem is not installed, as in production, where Bundler
skips the development group. There is also a standalone HTTP process:
`rails-ai-context serve --transport http --port 6029`. **The CLI** runs the same 35 tools with no server:

```bash
bin/rails 'ai:tool[search_code]' pattern="publishable?" match_type=trace
rails-ai-context tool schema --table users --detail full
```

The commands, in the Gemfile and standalone:

| In the Gemfile | Standalone | What it does |
|:---|:---|:---|
| `bin/rails generate rails_ai_context:install` | `rails-ai-context init` | Set up (both take `--tools`, `--mcp`, `--cli`, `--mcp-only`, `--prune`, `--defaults`) |
| `bin/rails ai:serve` | `rails-ai-context serve` | Start the MCP server (stdio) |
| `bin/rails ai:serve_http` | `rails-ai-context serve --transport http` | Start the MCP server (HTTP) |
| `bin/rails 'ai:tool[NAME]'` | `rails-ai-context tool NAME` | Run one tool |
| `bin/rails ai:tool` | `rails-ai-context tool --list` | List the tools |
| `bin/rails ai:context` | `rails-ai-context context` | Regenerate the context files |
| `bin/rails ai:doctor` | `rails-ai-context doctor` | Diagnostics and a readiness score |
| `bin/rails ai:watch` | `rails-ai-context watch` | Regenerate on file change |
| `bin/rails 'ai:preset[NAME]'` | `rails-ai-context preset NAME` | Run a multi-tool preset (`architecture`, `debugging`, `migration`) |
| `bundle exec rails-ai-context uninstall` | `rails-ai-context uninstall` | Remove what the gem wrote, keep what you wrote |
| `bundle exec rails-ai-context mcp-entry` | `rails-ai-context mcp-entry` | Print an MCP entry for Claude Desktop, Windsurf, Zed and other clients |

The binary finds the app the way `bin/rails` does, so it runs from any subdirectory. Flags shared by
the app-reading commands: `--app-path PATH` to target another directory, `--environment ENV` to set
`RAILS_ENV`, and `--no-boot` to answer from source. The full list is in the [CLI reference](docs/CLI.md).

Configuration lives in an initializer in a Gemfile install, and in `.rails-ai-context.yml` with the
same keys standalone. Every option with its default is in [Configuration](docs/CONFIGURATION.md):

```ruby
# config/initializers/rails_ai_context.rb
if defined?(RailsAiContext) && RailsAiContext.respond_to?(:configure)
  RailsAiContext.configure do |config|
    config.ai_tools  = %i[claude cursor]   # which AI tools to generate for
    config.tool_mode = :mcp                # :mcp (default) or :cli
    config.preset    = :full               # :full (40 introspectors) or :standard (17)
  end
end
```

<details>
<summary><b>Custom tools</b></summary>

<br>

Register your own tools next to the built-in ones:

```ruby
# app/mcp_tools/rails_get_business_metrics.rb
class RailsGetBusinessMetrics < MCP::Tool
  tool_name "rails_get_business_metrics"
  description "Key business metrics for this app"
  input_schema(properties: { period: { type: "string" } })

  def self.call(period: "week", server_context: nil)
    MCP::Tool::Response.new([{ type: "text", text: "Users this #{period}: #{User.recent.count}" }])
  end
end

# config/initializers/rails_ai_context.rb
config.custom_tools = ["RailsGetBusinessMetrics"]
```

Test them with the bundled helper (RSpec or Minitest):

```ruby
include RailsAiContext::TestHelper

response = execute_tool("business_metrics", period: "month")
assert_tool_response_includes(response, "Users")
```

See [Custom tools](docs/CUSTOM_TOOLS.md).

</details>

<details>
<summary><b>Observability</b></summary>

<br>

Every MCP call fires an `ActiveSupport::Notifications` event:

```ruby
ActiveSupport::Notifications.subscribe("rails_ai_context.tools.call") do |event|
  ms = (event.payload[:duration].to_f * 1000).round
  Rails.logger.info "[MCP] #{event.payload[:tool_name]} #{ms}ms"
end
```

</details>

To take it out again:

```bash
bundle exec rails-ai-context uninstall && bundle remove rails-ai-context   # in the Gemfile
rails-ai-context uninstall                                                 # standalone
```

It removes the context files, the MCP entries, its config, its `.gitignore` lines and its pre-commit
hook, and keeps what you wrote: your lines in `CLAUDE.md`, other servers in an MCP config, a hook you
edited. Or paste the [uninstall prompt](docs/PROMPTS.md#uninstall).

## Troubleshooting

`bundle exec rails-ai-context doctor` (or `bin/rails ai:doctor`) boots the app, checks every file the
install wrote, the MCP configs and the plugins, and prints a readiness score with what to fix. It needs
a bootable app, since diagnosing the boot is its job. The [fix it prompt](docs/PROMPTS.md#fix-it)
hands the same checks to the assistant, and [Troubleshooting](docs/TROUBLESHOOTING.md) has the
problems people hit most: a server the AI tool never lists, a boot that fails, a Windows path, a
bundle that resolves the wrong Rails.

## Development

```bash
git clone https://github.com/crisnahine/rails-ai-context.git
cd rails-ai-context
bundle install
bundle exec rspec              # the suite, on an in-memory SQLite app under spec/internal
bundle exec rubocop --parallel # rubocop-rails-omakase style
bundle exec rake e2e           # fresh Rails apps per install path; minutes, needs PostgreSQL for one spec
```

The website is `site/`, filled in by `scripts/site.rb` from the repository: the install prompt from
`docs/PROMPTS.md`, the tool list from the registry, every `docs/` page rendered beside it, and the
answers recorded by running the gem against `site/sample_app`. To see it before pushing:

```bash
bundle exec ruby scripts/site.rb _site
python3 -m http.server 8000 -d _site
```

`.github/workflows/pages.yml` builds it on a pull request that touches the site or the docs, and
deploys it from `main`. [CONTRIBUTING.md](CONTRIBUTING.md) has the layout of `lib/`, how to add an
introspector, a tool or a Prism listener, and how to run the specs against real database servers.

## Contributing and security

Pull requests are welcome; [CONTRIBUTING.md](CONTRIBUTING.md) has the process, and the
[code of conduct](CODE_OF_CONDUCT.md) applies to everyone taking part. Bugs go to
[the issue tracker](https://github.com/crisnahine/rails-ai-context/issues) with the Ruby, Rails and gem
versions and the steps to reproduce. A security problem goes by email, the way [SECURITY.md](SECURITY.md)
says, and never in a public issue. Only the latest 5.x release gets security fixes.

## Learn more

| | |
|:---|:---|
| [The website](https://crisnahine.github.io/rails-ai-context/) | The short tour, with every answer recorded at the commit it was built from |
| [Copy-paste prompts](docs/PROMPTS.md) | Let your AI tool install, change, remove or use the gem |
| [Quickstart](docs/QUICKSTART.md) | Up and running in 5 minutes |
| [AI tool setup](docs/SETUP.md) | Claude Code, Cursor, Copilot, OpenCode, Codex CLI, HTTP transport |
| [Guide](docs/GUIDE.md) | Every command, parameter and option |
| [Tools reference](docs/TOOLS.md) | All 35 tools with every parameter |
| [Recipes](docs/RECIPES.md) | Real workflows, end to end |
| [CLI reference](docs/CLI.md) | Commands, flags and argument syntax |
| [Standalone](docs/STANDALONE.md) | Use without a Gemfile entry |
| [Configuration](docs/CONFIGURATION.md) | Every option with its default |
| [Custom tools](docs/CUSTOM_TOOLS.md) | Build and test your own tools |
| [Architecture](docs/ARCHITECTURE.md) | System design and internals |
| [Introspectors](docs/INTROSPECTORS.md) | All 40 introspectors and the AST engine |
| [Security](docs/SECURITY.md) | SQL safety layers and file blocking |
| [Compatibility](docs/COMPATIBILITY.md) | Supported versions, operating tiers, app shape matrix |
| [Troubleshooting](docs/TROUBLESHOOTING.md) | Common problems and fixes |
| [FAQ](docs/FAQ.md) | Frequently asked questions |
| [CHANGELOG.md](CHANGELOG.md) | Every release, newest first |

If it saves you a correction loop, [star it on GitHub](https://github.com/crisnahine/rails-ai-context),
and if it saves you time, consider [sponsoring the project](https://github.com/sponsors/crisnahine).
