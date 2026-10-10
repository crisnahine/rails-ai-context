<div align="center" markdown="1">

# rails-ai-context - Complete Guide

**The all-in-one reference. Everything in one file.**

[Quickstart](QUICKSTART.md) · [Tools](TOOLS.md) · [Recipes](RECIPES.md) · [FAQ](FAQ.md)

</div>

---

> [!NOTE]
> This is the full single-file reference. For focused guides, see the docs below. For a quick overview, see the [Home](index.md).

## Focused guides

| Guide | Description |
|:------|:------------|
| [Quickstart](QUICKSTART.md) | Get running in 5 minutes |
| [Tools Reference](TOOLS.md) | All 45 MCP tools with parameters |
| [Recipes](RECIPES.md) | Real-world workflows and examples |
| [Custom Tools](CUSTOM_TOOLS.md) | Build your own MCP tools |
| [Configuration](CONFIGURATION.md) | Every config option |
| [AI Tool Setup](SETUP.md) | Per-editor setup |
| [Architecture](ARCHITECTURE.md) | System design and internals |
| [Introspectors](INTROSPECTORS.md) | All 40 introspectors |
| [Security](SECURITY.md) | Security model and SQL safety |
| [CLI Reference](CLI.md) | All commands and argument syntax |
| [Standalone Mode](STANDALONE.md) | Use without Gemfile |
| [Troubleshooting](TROUBLESHOOTING.md) | Common issues and fixes |
| [FAQ](FAQ.md) | Frequently asked questions |

---

## Table of Contents

- [Installation](#installation)
- [Context Modes](#context-modes)
- [Generated Files](#generated-files)
- [All Commands](#all-commands)
- [CLI Tools](#cli-tools)
- [MCP Tools - Common Reference](#mcp-tools---common-reference)
- [MCP Resources](#mcp-resources)
- [MCP Server Setup](#mcp-server-setup)
- [Configuration - All Options](#configuration---all-options)
- [Introspectors - Full List](#introspectors---full-list)
- [AI Assistant Setup](#ai-assistant-setup)
- [Stack Compatibility](#stack-compatibility)
- [Diagnostics](#diagnostics)
- [Watch Mode](#watch-mode)
- [Works Without a Database](#works-without-a-database)
- [Security](#security)
- [Troubleshooting](#troubleshooting)

---

## Installation

### Option A: In Gemfile

```bash
gem "rails-ai-context", group: :development
bundle install
rails generate rails_ai_context:install
rails ai:context
```

This creates:
1. `config/initializers/rails_ai_context.rb` - configuration file
2. `.rails-ai-context.yml` - standalone config (enables switching later)
3. Per-tool MCP config files - auto-discovery for Claude Code, Cursor, Copilot, OpenCode, and Codex
4. Context files - tailored for each AI assistant

### Option B: Standalone (no Gemfile entry needed)

```bash
gem install rails-ai-context
cd your-rails-app
rails-ai-context init
```

This creates:
1. `.rails-ai-context.yml` - configuration file
2. Per-tool MCP config files - auto-discovery (if MCP mode selected)
3. Context files - tailored for each AI assistant

No Gemfile entry, no initializer, no files in your project besides config and context.

### What the install generator does

`rails generate rails_ai_context:install` runs these steps in this order. Steps 1, 2, 3, 8 and 9 can ask a question.

1. **Asks which AI tools you use.** It prints this menu, then `Enter numbers separated by commas (e.g. 1,2) or 'a' for all:`

   ```
   1. Claude Code      -> CLAUDE.md + .claude/rules/
   2. Cursor           -> .cursor/rules/ + .cursorrules (legacy fallback)
   3. GitHub Copilot   -> .github/copilot-instructions.md + .github/instructions/
   4. OpenCode         -> AGENTS.md
   5. Codex CLI        -> AGENTS.md + .codex/config.toml
   a. All of the above
   ```

   There is no "none" choice. An empty answer, or one with no valid number in it, prints `No tools selected - defaulting to all.` and selects all five.
2. **Offers to clean up tools you dropped.** Only on a re-run, and only when the last recorded selection (the `config.ai_tools` line in the initializer, else `.rails-ai-context.yml`) has a tool you did not pick this time. It lists them and asks `Remove their generated files?` with `y` (all), `n` (keep, the default) or numbers like `1,2`. A yes removes only what the gem generated: the rule files it names inside the tool's rules directory (the directory goes too when nothing else is left in it), and the block between the `rails-ai-context` markers in a root file such as `CLAUDE.md`. A rule file you wrote by hand, your own lines around the markers, a root file with no markers and a symlink are left alone. It also keeps any file a remaining tool shares (`AGENTS.md`), and takes only the `rails-ai-context` entry out of the tool's MCP config.
3. **Asks what to write**, then `Enter number (default: 1):`

   ```
   1. MCP config + context files   (default)
   2. Context files only           (CLI mode, no MCP server)
   3. MCP config only              (leaves CLAUDE.md, AGENTS.md and rules untouched)
   ```

   Choices 1 and 3 set `tool_mode` to `:mcp`, choice 2 sets it to `:cli`. Choice 3 also sets `context_files` to `false`. Any other answer counts as 1.
4. **Writes the MCP config for each selected tool** (`.mcp.json`, `.cursor/mcp.json`, `.vscode/mcp.json`, `opencode.json`, `.codex/config.toml`). Skipped for choice 2. An existing file is merged: only the `rails-ai-context` entry is added or replaced. One that does not parse as JSON (VS Code's and OpenCode's take trailing commas), or holds comments a rewrite would drop, is left as it is, with a warning that names the entry to add by hand.
5. **Creates or updates `config/initializers/rails_ai_context.rb`.** A new file gets your three answers as live lines (`config.ai_tools`, `config.tool_mode`, `config.context_files`) and every other option commented out at its default, wrapped in `if defined?(RailsAiContext) && RailsAiContext.respond_to?(:configure)`. In an existing file it rewrites those three lines, appends any config section the file lacks, adds the guard if it is missing, and leaves the rest alone.
6. **Writes `.rails-ai-context.yml`** with `ai_tools`, `tool_mode` and `context_files`. Other keys already in the file are kept.
7. **Adds lines to `.gitignore`**, if the file exists: `.ai-context.json` (not for choice 3) and `.codex/config.toml` (always, because it holds this machine's Ruby paths). A line that is already there is not added again.
8. **Asks about a pre-commit hook:** `Install a pre-commit hook that checks staged Ruby and ERB files for syntax errors? (y/N)`. Only `y` installs it. The hook runs `rails 'ai:tool[validate]'` on the staged `.rb` and `.erb` files and stops a commit whose files do not parse; the Rails-reference checks (`level=rails`) are left to the tool, as Brakeman would slow every commit. Every staged name is read whole, one with characters outside ASCII included; a name holding a comma, which the files list cannot carry, is named and left unchecked. It goes where git runs hooks (`git rev-parse --git-path hooks`), so an app checked out as a submodule, an app inside a monorepo and a repo with `core.hooksPath` set all get it where git will run it. The hook names the apps it covers and validates each one's staged files (deleted ones aside) from inside that app; installing in a second app of the same monorepo adds it to the hook, unless the hook was changed by hand, which it says, and for an app below the top of the repository the question names the repository. A hook an earlier version wrote, and nobody changed since, is brought up to date without asking again: those handed validate the files a commit deletes too, and the commit failed on them. Any other hook that runs `rails-ai-context` - one changed by hand, or a team's own that calls it among other checks - is left as it is, with a message. No hook is offered for an app the repository does not track yet (an app under a dotfiles repository at `$HOME`, say), nor into a `core.hooksPath` outside the repository, which every repository using it shares; both say why. No question is asked outside a git repository or when the hook already covers the app. When another `pre-commit` hook exists there it prints `Skipped pre-commit hook (existing hook found - add manually)` and moves on.
9. **Generates the context files** for the selected tools. Skipped for choice 3. If files that v5.0.0 stopped generating are still there (`.claude/rules/rails-ui-patterns.md`, `.claude/rules/rails-accessibility.md`, `.cursor/rules/rails-ui-patterns.mdc`, `.github/instructions/rails-ui-patterns.instructions.md`), it lists them first and asks `Delete them? [y/N]:`. Without a terminal, or under `--defaults`, it prints the `rm` command and does not ask.
10. **Prints a summary:** the files each selected tool got and the commands to run next.

Two flags change the prompts:

- `--defaults` answers every prompt with its default: all five tools, keep dropped tools' files, choice 1, no hook, keep legacy files. Piping an empty stdin does the same.
- `--mcp-only` skips the step 3 question and acts as choice 3. Steps 1, 2 and 8 still ask.

Run from a mountable engine's root, where `bin/rails` boots `test/dummy`, the install goes into the engine's root - the folder an editor is opened at, and the one every `rails-ai-context` command run there reads: the MCP configs, `.rails-ai-context.yml`, the `.gitignore` lines and the context files, which are generated from the engine's source the way its MCP server reads it there. No initializer is written, since Rails runs an engine's `config/initializers` in every app that mounts it and the gemspec ships them; one an earlier install left there is named, with a note to delete it. Step 8 offers no hook, because the engine's root has no `rails 'ai:tool[validate]'` (its rake tasks run in the dummy app, as `app:ai:*`), and the summary lists the commands that work at the engine's root, `bundle exec rails-ai-context ...`.

A team that wants no AI tool files in the repo can skip the generator. The gem needs none of its output: `rails 'ai:tool[NAME]'`, `rails ai:serve`, `rails ai:doctor` and the `rails-ai-context` binary all work on the defaults with no initializer, no `.rails-ai-context.yml` and no MCP config. `rails ai:context` is the one to leave alone in that setup, since it writes context files. To make that safe too, set `config.ai_tools = []` in an initializer: an empty list means no tool, so nothing is written and nothing is asked.

Two other entry points ask the same step 1 and step 3 questions:

- `rails-ai-context init` (standalone) asks both, then offers the step 2 and step 9 cleanups, writes `.rails-ai-context.yml`, the MCP configs and the `.gitignore` lines, and generates the context files. On an MCP-only run it skips the step 9 question, as the generator does. It never creates the initializer (in one that exists it updates `config.ai_tools`, `config.tool_mode` and `config.context_files`), never offers the pre-commit hook, and has `--mcp-only` but no `--defaults`. Run in a folder that holds several apps, it asks once and sets them all up: each app's own `.rails-ai-context.yml` and context files, and one MCP server per app in the folder's configs ([`init`](CLI.md#init-standalone-only)).
- `rails ai:context` asks step 1 only when no tool selection is recorded, and step 3 only when no `tool_mode` is recorded. It then writes `.rails-ai-context.yml`, the MCP configs and the `.gitignore` lines before generating. It does not create the initializer or offer the hook.

---

## Context Modes

The gem has two context modes that control how much data goes into the generated files:

### Compact mode (default)

```bash
rails ai:context
```

- CLAUDE.md, AGENTS.md, .cursorrules and copilot-instructions.md ≤150 non-blank
  lines (`claude_max_lines`). Over budget, the data sections are cut first; the
  title and the Commands, Warnings, Rules and Tools sections are never cut, so a
  budget smaller than they are (about 110 lines) leaves just them
- Files contain a project overview + MCP tool reference
- AI uses MCP tools for detailed data on-demand
- **Best for:** all apps, especially large ones (30+ models)

### Full mode

```bash
rails ai:context:full
# or
CONTEXT_MODE=full rails ai:context
```

- Dumps everything into the root files CLAUDE.md, AGENTS.md and copilot-instructions.md: every table with its column types, defaults, indexes and foreign keys; every model with its associations, validations, scopes, callbacks, enum values and constants; the app's own routes (the framework's are counted, not listed); Stimulus controllers; and the rest of the introspection. The split rule files and Cursor's files are the same in both modes
- Each root file ends with the same tools guide and anti-hallucination protocol the compact files carry, so OpenCode and Codex, which read AGENTS.md alone, get them too
- A plain `rails ai:context` writes compact files again unless `config.context_mode` is `:full`, so each file's last line names the command that keeps full mode: `CONTEXT_MODE=full rails ai:context`, or for a standalone install `rails-ai-context context`, which reads `context_mode` from `.rails-ai-context.yml`
- Can produce thousands of lines for large apps
- **Best for:** small apps (<30 models) where the full dump fits in context

### Per-format with mode override

```bash
# Full dump for Claude only, compact for everything else
CONTEXT_MODE=full rails ai:context:claude

# Full dump for Copilot only
CONTEXT_MODE=full rails ai:context:copilot
```

### Set mode in configuration

```ruby
# config/initializers/rails_ai_context.rb
if defined?(RailsAiContext) && RailsAiContext.respond_to?(:configure)
  RailsAiContext.configure do |config|
    config.context_mode = :full # or :compact (default)
  end
end
```

---

## Generated Files

`rails ai:context` generates **20 files** across all AI assistants:

A file whose section has nothing in it is not written. An app with no models gets no `.claude/rules/rails-models.md`, and every surface names the file and the reason so a deliberate omission is not mistaken for a failed run. `rails ai:context` and the installer print `➖  .claude/rules/rails-models.md (no models)`; the CLI and the watcher print `Not applicable: .claude/rules/rails-models.md (no models)`.

### Claude Code (6 files)

| File | Purpose | Notes |
|------|---------|-------|
| `CLAUDE.md` | Main context file | ≤150 lines in compact mode. Claude Code reads this automatically. |
| `.claude/rules/rails-schema.md` | Database table listing | Every database's tables, each database under its own heading when the app has more than one. A database of Solid Queue, Solid Cache or Solid Cable tables only, as Rails 8's queue, cache and cable are, is named in CLAUDE.md instead (`queue: Solid Queue (13 tables)`). Loaded when Claude Code opens a schema dump or a migration. |
| `.claude/rules/rails-models.md` | Model listing with associations | Auto-loaded by Claude Code alongside CLAUDE.md. |
| `.claude/rules/rails-context.md` | Project context and conventions | Auto-loaded by Claude Code alongside CLAUDE.md. |
| `.claude/rules/rails-mcp-tools.md` | Tool reference | Detail levels and the table of every tool. Loaded beside CLAUDE.md, which carries the protocol, the workflows and the rules, so they are not read twice; with `generate_root_files` off it carries them itself. |
| `.claude/rules/rails-components.md` | View component listing | Written only when the app has view components. |

### OpenCode (3 files)

| File | Purpose | Notes |
|------|---------|-------|
| `AGENTS.md` | Main context file | Native OpenCode format. ≤150 lines in compact mode. OpenCode also reads CLAUDE.md as fallback. |
| `app/models/AGENTS.md` | Model reference | Auto-loaded by OpenCode when reading files in `app/models/`. One you wrote yourself keeps its text, with the listing added between markers. |
| `app/controllers/AGENTS.md` | Controller reference | Auto-loaded by OpenCode when reading files in `app/controllers/`. One you wrote yourself keeps its text, with the listing added between markers. |

### Cursor (5 files)

| File | Purpose | Notes |
|------|---------|-------|
| `.cursor/rules/rails-project.mdc` | Project overview | `alwaysApply: true` - loaded in every conversation. |
| `.cursor/rules/rails-models.mdc` | Model reference | `globs: app/models/**/*.rb` - auto-attaches when editing models. |
| `.cursor/rules/rails-controllers.mdc` | Controller reference | `globs: app/controllers/**/*.rb` - auto-attaches when editing controllers. |
| `.cursor/rules/rails-mcp-tools.mdc` | MCP tool reference | `alwaysApply: false` - agent-requested when relevant. |
| `.cursorrules` | Legacy fallback | Read by older Cursor clients. Wrapped in markers, so hand-written content around it survives. |

### GitHub Copilot (5 files)

| File | Purpose | Notes |
|------|---------|-------|
| `.github/copilot-instructions.md` | Repo-wide instructions | ≤`claude_max_lines` (150) non-blank lines in compact mode, markers included. |
| `.github/instructions/rails-models.instructions.md` | Model context | `applyTo: app/models/**/*.rb` - loaded when editing models. |
| `.github/instructions/rails-controllers.instructions.md` | Controller context | `applyTo: app/controllers/**/*.rb` - loaded when editing controllers. |
| `.github/instructions/rails-context.instructions.md` | Project context and conventions | `applyTo: **/*` - loaded everywhere. |
| `.github/instructions/rails-mcp-tools.instructions.md` | Tool reference | `applyTo: **/*` - loaded everywhere. Detail levels and the table; the protocol and workflows are in copilot-instructions.md, or here too with `generate_root_files` off. |

### Generic (1 file)

| File | Purpose | Notes |
|------|---------|-------|
| `.ai-context.json` | Full structured JSON | For programmatic access or custom tooling. Added to `.gitignore`. |

### Which files to commit

Commit **all files except `.ai-context.json`** (which is gitignored). This gives your entire team AI-assisted context automatically.

### Telling a static file from a booted one

A run that could not boot the app, or was given `--no-boot`, reads source files
instead of a running Rails. The counts differ, so every generated file that
states them says so: a `[STATIC]` line under the header, and a
`"tier": "static"` key in `.ai-context.json`. The MCP tool references carry no
app counts, so they carry no line. A booted run says nothing extra, so an
unmarked file was generated with the app running.

---

## All Commands

### Context generation

| Command | Mode | Format | Description |
|---------|------|--------|-------------|
| `rails ai:context` | compact | all | Generate all 20 context files |
| `rails ai:context:full` | full | all | Generate all files in full mode |
| `rails ai:context:claude` | compact | Claude | CLAUDE.md + .claude/rules/ |
| `rails ai:context:opencode` | compact | OpenCode | AGENTS.md + per-directory AGENTS.md |
| `rails ai:context:codex` | compact | Codex | AGENTS.md + per-directory AGENTS.md (same files as OpenCode; `.codex/config.toml` comes from the installer or `rails ai:context`) |
| `rails ai:context:cursor` | compact | Cursor | .cursor/rules/ |
| `rails ai:context:copilot` | compact | Copilot | copilot-instructions.md + .github/instructions/ |
| `rails ai:context:json` | - | JSON | .ai-context.json |
| `CONTEXT_MODE=full rails ai:context:claude` | full | Claude | Full dump for Claude only |
| `CONTEXT_MODE=full rails ai:context:opencode` | full | OpenCode | Full dump in AGENTS.md, which Codex reads too |
| `CONTEXT_MODE=full rails ai:context:copilot` | full | Copilot | Full dump for Copilot only |

Cursor's files are the same in both modes, so `CONTEXT_MODE=full` changes nothing for `rails ai:context:cursor`.

### CLI tools

| Command | Description |
|---------|-------------|
| `rails 'ai:tool[NAME]'` | Run any MCP tool from the CLI (e.g. `rails 'ai:tool[schema]' table=users detail=full`) |
| `rails ai:tool` | List all available tools with descriptions |
| `rails 'ai:tool[NAME]' JSON=1` | Run tool with JSON envelope output |

### MCP server

| Command | Transport | Description |
|---------|-----------|-------------|
| `rails ai:serve` | stdio | Start MCP server. The generated MCP config files start the same server with `bundle exec rails-ai-context serve`. |
| `rails ai:serve_http` | HTTP | Start MCP server at `http://127.0.0.1:6029/mcp`. For remote clients. |

### Utilities

| Command | Description |
|---------|-------------|
| `rails ai:doctor` | Run the diagnostic checks that apply to the app. Reports pass/warn/fail with fix suggestions. AI readiness score (0-100). `STRICT=1` exits 1 when a check fails. |
| `rails ai:watch` | Watch for file changes and auto-regenerate context files. Requires `listen` gem. |
| `rails ai:inspect` | Print introspection summary to stdout. Useful for debugging. |
| `rails ai:facts` | Print a short schema facts summary (tables, columns, indexes, associations, dependencies). |
| `rails 'ai:preset[NAME]'` | Run a multi-tool preset: `architecture`, `debugging` or `migration`. |

### Standalone CLI

The gem ships a `rails-ai-context` executable that works **without adding the gem to your Gemfile**. Install globally with `gem install rails-ai-context`, then run from any Rails app directory.

```bash
rails-ai-context init                      # Interactive setup (creates .rails-ai-context.yml + MCP configs)
rails-ai-context serve                     # Start MCP server (stdio)
rails-ai-context serve --transport http    # Start MCP server (HTTP, port 6029)
rails-ai-context serve --transport http --port 8080  # Custom port
rails-ai-context context                   # Generate all context files
rails-ai-context context --format claude   # Generate Claude files only
rails-ai-context tool                      # List all available tools
rails-ai-context tool schema --table users --detail full  # Run a tool
rails-ai-context tool schema --help        # Per-tool help
rails-ai-context tool schema --json        # JSON envelope output
rails-ai-context doctor                    # Run diagnostics (--strict exits 1 on a failed check)
rails-ai-context watch                     # Watch for changes
rails-ai-context inspect                   # Print introspection JSON
rails-ai-context facts                     # Print schema facts summary
rails-ai-context preset architecture       # Run a multi-tool preset
rails-ai-context version                   # Print version
rails-ai-context help                      # Show all commands
```

Run it anywhere inside your Rails app, from a folder holding one app, or pass `--app-path PATH` ([how the app is found](CLI.md#tool)). Booting needs `config/environment.rb`. When the app cannot boot, or with `--no-boot`, every command except `doctor` reads the source files instead.

**Config:** Standalone mode reads from `.rails-ai-context.yml` (created by `init`), and that is its only config source - the gem is not loaded while `config/initializers` runs. If no config file exists, defaults are used. With the gem in the Gemfile the two merge key by key ([Precedence](CONFIGURATION.md#precedence)).

### Legacy command

```bash
rails 'ai:context_for[claude]'   # Requires quoting in zsh
rails ai:context:claude           # Use this instead (no quoting needed)
```

---

## CLI Tools

All 45 MCP tools can be run directly from the terminal - no MCP server or AI client needed.

### Rake

```bash
# Run a tool with arguments
rails 'ai:tool[schema]' table=users detail=full

# List all available tools
rails ai:tool

# JSON envelope output
rails 'ai:tool[schema]' table=users JSON=1
```

### Thor CLI

```bash
# Run a tool with arguments
rails-ai-context tool schema --table users --detail full

# List all tools
rails-ai-context tool

# Per-tool help (auto-generated from input_schema)
rails-ai-context tool schema --help

# JSON output
rails-ai-context tool schema --table users --json
```

### Tool name resolution

Short names are resolved automatically:

| You type | Resolves to |
|----------|-------------|
| `schema` | `rails_get_schema` |
| `get_schema` | `rails_get_schema` |
| `rails_get_schema` | `rails_get_schema` |
| `search_code` | `rails_search_code` |
| `analyze_feature` | `rails_analyze_feature` |

### tool_mode configuration

The `tool_mode` config controls how tool references appear in generated context files:

```ruby
if defined?(RailsAiContext) && RailsAiContext.respond_to?(:configure)
  RailsAiContext.configure do |config|
    # :mcp (default) - MCP primary, CLI as fallback
    # :cli - CLI only, no MCP server needed
    config.tool_mode = :mcp
  end
end
```

- **`:mcp`** - context files show MCP tool syntax (e.g. `rails_get_schema(table: "users")`). CLI tools still available as fallback.
- **`:cli`** - context files show CLI syntax (e.g. `rails 'ai:tool[schema]' table=users`). No MCP server required. Every file follows it: the root files, the split rule files and OpenCode's per-directory `AGENTS.md`, whose tools rule files then describe the CLI tools.

Every tool count and list in the generated files is the set the server serves: the built-in tools `skip_tools` leaves, plus `custom_tools`. A custom tool gets a row in the tools table with the first sentence of its description. A workflow step, rule or pointer whose tool is skipped is left out, or said without the tool (with `rails_get_context` skipped, the model workflow starts from `rails_get_model_details`), so no file sends the AI to a tool the server does not serve.

The workflow examples name the app's own most connected model, one of its controllers, a template and a partial it renders. An app with none of one gets an obvious placeholder (`YourModel`, `shared/your_partial`) rather than a name that reads like the app's.

The `tool_mode` is selected during `rails generate rails_ai_context:install`.

---

## MCP Tools - Common Reference

The 24 tools below are the ones worth reading about before you start. [Tools Reference](TOOLS.md) carries all 45 with their parameters.

Every tool is **read-only** and **idempotent** - they never modify your application or database.

### rails_get_schema

Returns database schema: tables, columns, indexes, foreign keys.

**Parameters:**

| Param | Type | Description |
|-------|------|-------------|
| `table` | string | Specific table name for full detail. Omit for listing. |
| `detail` | string | `summary` / `standard` (default) / `full` |
| `limit` | integer | Max tables to return. Default: 50 (summary), 25 (standard), 10 (full). |
| `offset` | integer | Skip tables for pagination. Default: 0. |
| `format` | string | `markdown` (default) / `json`. JSON returns the same page of tables keyed by table name, or the single table's own data when `table` is given. |

**Examples:**

```
rails_get_schema()
  → Standard detail, first 25 tables with column names and types

rails_get_schema(detail: "summary")
  → All tables with column and index counts (up to 50)

rails_get_schema(table: "users")
  → Full detail for users table: columns, types, nullable, defaults, indexes, FKs

rails_get_schema(detail: "summary", limit: 20, offset: 40)
  → Tables 41-60 with column counts

rails_get_schema(detail: "full", format: "json")
  → The same page of tables as JSON, with indexes and foreign keys
```

### rails_get_model_details

Returns model details: associations, validations, scopes, enums, callbacks, concerns. Source parsing uses Prism AST. The model heading and each scope carry a confidence tag: `[VERIFIED]` (confirmed by the booted app, or static literal arguments), `[INFERRED]` (dynamic expressions) or `[STATIC]` (read from source without a boot).

**Parameters:**

| Param | Type | Description |
|-------|------|-------------|
| `model` | string | Model class name (e.g. `User`). Case-insensitive. Omit for listing. |
| `detail` | string | `summary` / `standard` (default) / `full`. Ignored when model is specified. |
| `limit` | integer | Max models to return when listing. Default: 50. |
| `offset` | integer | Skip models for pagination. Default: 0. |

**Examples:**

```
rails_get_model_details()
  → Standard: all model names with association and validation counts

rails_get_model_details(detail: "summary")
  → Just model names, one per line

rails_get_model_details(model: "User")
  → Full detail: table, associations, validations, enums, scopes, callbacks, concerns, methods

rails_get_model_details(model: "user")
  → Same as above (case-insensitive)

rails_get_model_details(detail: "full")
  → All models with full association lists
```

### rails_get_routes

Returns all routes: HTTP verbs, paths, controller actions, route names.

**Parameters:**

| Param | Type | Description |
|-------|------|-------------|
| `controller` | string | Filter by controller name (e.g. `users`, `api/v1/posts`). Case-insensitive. |
| `detail` | string | `summary` / `standard` (default) / `full` |
| `limit` | integer | Max routes to return. Default: 150 (standard), 200 (full). |
| `offset` | integer | Skip routes for pagination. Default: 0. |
| `app_only` | boolean | Filter out internal Rails routes (Active Storage, Action Mailbox, Conductor, etc.). Default: true. |

**Examples:**

```
rails_get_routes()
  → Standard: routes grouped by controller with verb, path, action

rails_get_routes(detail: "summary")
  → Route counts per controller with verb breakdown

rails_get_routes(controller: "users")
  → All routes for UsersController

rails_get_routes(controller: "posts")
  → Also reaches a namespaced `api/v1/posts`: an exact name first, then the trailing path segments, never a substring

rails_get_routes(detail: "full", limit: 50)
  → Full table with route names, first 50 routes

rails_get_routes(detail: "standard", limit: 20, offset: 100)
  → Routes 101-120
```

### rails_get_controllers

Returns controller details: actions, filters, strong params, concerns. Automatically includes **Schema Hints** for models referenced in the controller (via Prism AST detection).

**Parameters:**

| Param | Type | Description |
|-------|------|-------------|
| `controller` | string | Specific controller name (e.g. `UsersController`, `posts`, `admin/posts`). Case-insensitive, flexible format. |
| `action` | string | Specific action (e.g. `index`). Requires controller. Returns source code with applicable filters. |
| `detail` | string | `summary` / `standard` (default) / `full`. Ignored when controller is specified. |
| `limit` | integer | Max controllers to return when listing. Default: 50. |
| `offset` | integer | Skip this many controllers for pagination. Default: 0. |

**Examples:**

```
rails_get_controllers()
  → Standard: controller names with action lists

rails_get_controllers(detail: "summary")
  → Controller names with action counts

rails_get_controllers(controller: "UsersController")
  → Full detail: parent class, actions, filters (with only/except), strong params

rails_get_controllers(detail: "full")
  → All controllers with actions, filters, and strong params
```

### rails_get_config

Returns application configuration. No parameters.

**Returns:** cache store, session store, timezone, queue adapter, mailer settings, the app's own middleware classes with their files and the rest of the stack as additions (framework defaults are filtered out), the `use` and `map` calls in `config.ru`, notable initializers, CurrentAttributes classes with the attributes they declare, their defaults and reset hooks.

```
rails_get_config()
  → Cache: redis_cache_store, Session: cookie_store, TZ: UTC, ...
```

### rails_get_test_info

Returns test infrastructure details. Optionally filter by model or controller to find existing tests.

**Parameters:**

| Param | Type | Description |
|-------|------|-------------|
| `model` | string | Show tests for a specific model (e.g. `User`). Also searches concern test paths (`spec/models/concerns/`, `test/models/concerns/`). |
| `controller` | string | Show tests for a specific controller (e.g. `Posts`). |
| `detail` | string | `summary` / `standard` (default) / `full`. |

```
rails_get_test_info()
  → Framework: rspec, Factories: spec/factories (12 files), CI: .github/workflows/ci.yml

rails_get_test_info(model: "User")
  → Shows spec/models/user_spec.rb test names (summary/standard) or full source (full)
```

### rails_get_gems

Returns notable gems categorized by function.

**Parameters:**

| Param | Type | Description |
|-------|------|-------------|
| `category` | string | Filter by category: `auth`, `jobs`, `frontend`, `api`, `database`, `files`, `testing`, `deploy`, `monitoring`, `admin`, `pagination`, `search`, `forms`, `server`, `notifications`, `validation`, `utilities`, `services`, `payments`, `all` (default). |
| `limit` | integer | Max gems to return. Default: 50. |
| `offset` | integer | Skip this many gems for pagination. Default: 0. |

**Returns:** Notable gems grouped by category with descriptions.

```
rails_get_gems()
  → Auth: devise `4.9.3`, Jobs: sidekiq `7.2.1`, ...
```

### rails_get_conventions

Returns detected architecture patterns. No parameters.

**Returns:** architecture patterns (MVC, service objects, STI, etc.), directory structure with file counts, config files, detected patterns.

```
rails_get_conventions()
  → Architecture: [MVC, Service objects, Concerns], Patterns: [STI, Polymorphism], ...
```

### rails_get_stimulus

Returns Stimulus controller details: targets, values, actions, outlets, classes.

**Parameters:**

| Param | Type | Description |
|-------|------|-------------|
| `controller` | string | Specific Stimulus controller name (e.g. `hello`, `filter-form`). Case-insensitive. |
| `detail` | string | `summary` / `standard` (default) / `full` |
| `limit` | integer | Max controllers to return when listing. Default: 50. |
| `offset` | integer | Skip controllers for pagination. Default: 0. |

**Examples:**

```
rails_get_stimulus()
  → Standard: controller names with targets and actions

rails_get_stimulus(detail: "summary")
  → Names with target/action counts

rails_get_stimulus(controller: "filter-form")
  → Full detail: targets, actions, values, outlets, classes, file path

rails_get_stimulus(detail: "full")
  → All controllers with all details
```

### rails_get_view

Returns view template contents, partials, and Stimulus controller references. In standard detail, includes **Schema Hints** for models inferred from instance variables.

**Parameters:**

| Param | Type | Description |
|-------|------|-------------|
| `controller` | string | Filter views by controller name (e.g. `posts`, `comments`). Use `layouts` for layout files. |
| `path` | string | Specific view path relative to `app/views` (e.g. `posts/index.html.erb`). Returns full content. |
| `detail` | string | `summary` / `standard` (default) / `full` |

**Examples:**

```
rails_get_view()
  → Standard: all view files with partial/stimulus refs

rails_get_view(controller: "posts")
  → All templates and partials for PostsController

rails_get_view(path: "posts/index.html.erb")
  → Full template content

rails_get_view(controller: "layouts")
  → Layout files

rails_get_view(controller: "posts", detail: "full")
  → Full template content for all posts views
```

### rails_get_edit_context

Returns just enough context to make a surgical Edit to a file. Returns the target area with line numbers and surrounding code.

**Parameters:**

| Param | Type | Description |
|-------|------|-------------|
| `file` | string | **Required.** File path relative to Rails root (e.g. `app/models/post.rb`). |
| `near` | string | **Required.** What to find - a method name, keyword, or string to locate (e.g. `scope`, `def index`). |
| `context_lines` | integer | Lines of context above and below the match. Default: 5. |

**Examples:**

```
rails_get_edit_context(file: "app/models/post.rb", near: "scope")
  → Code around the first scope with line numbers, expanded to full method

rails_get_edit_context(file: "app/controllers/posts_controller.rb", near: "def index")
  → The index action source with surrounding context
```

### rails_validate

Validates syntax of multiple files at once (Ruby, ERB, JavaScript). Optionally runs Rails-aware semantic checks. JavaScript needs `node` on the PATH; without it a file whose brackets balance is listed as skipped, not as OK.

**Parameters:**

| Param | Type | Description |
|-------|------|-------------|
| `files` | array | **Required.** File paths relative to Rails root (e.g. `["app/models/post.rb", "app/views/posts/index.html.erb"]`). |
| `level` | string | `syntax` (default) - check syntax only (fast). `rails` - syntax + semantic checks (partial existence, route helpers, column references, strong params vs schema, callback methods, route-action consistency, has_many dependent, FK indexes, Stimulus controllers). |

**Examples:**

```
rails_validate(files: ["app/models/post.rb"])
  → ✓ app/models/post.rb - syntax OK

rails_validate(files: ["app/models/post.rb", "app/controllers/posts_controller.rb", "app/views/posts/index.html.erb"])
  → Checks all three files, reports pass/fail for each

rails_validate(files: ["app/models/post.rb"], level: "rails")
  → Syntax check + semantic warnings (e.g. validates :nonexistent_column, has_many without :dependent)

rails_validate(files: ["app/views/posts/index.html.erb"], level: "rails")
  → Syntax check + partial existence, route helper validity, Stimulus controller existence
```

### rails_search_code

Ripgrep-powered regex search across the codebase.

**Parameters:**

| Param | Type | Description |
|-------|------|-------------|
| `pattern` | string | **Required.** Regex pattern or method name to search for. |
| `path` | string | Subdirectory to search in (e.g. `app/models`, `config`). Default: entire app. |
| `file_type` | string | Filter by file extension (e.g. `rb`, `erb`, `js`). Alphanumeric only. |
| `match_type` | string | `any` (default), `definition` (def lines), `class` (class/module lines), `call` (call sites only), `trace` (**full picture** - definition with class context + source code + internal calls + sibling methods + callers with route chain + test coverage separated). |
| `exact_match` | boolean | Match the pattern literally, whole-word where its edges are word characters. `def reblog?` does not match `def reblog`. Default: false. |
| `exclude_tests` | boolean | Exclude test/spec/features directories. Default: false. |
| `group_by_file` | boolean | Group results by file with match counts. Default: false. |
| `offset` | integer | Skip this many lines for pagination. Default: 0. |
| `limit` | integer | Max lines to return; the default is sized in matches. |
| `context_lines` | integer | Lines of context before and after each match (like grep -C). Default: 2, max: 5. |

Smart result limiting, sized in matches: under 10 shows all, 10-100 shows half, over 100 caps at 100. `offset` and `limit` count emitted lines, so a search with context returns more lines than matches. The header says how many matches were found, how many the page shows, and whether the line cap was reached. Once it names the cap, the count covers only the lines it scanned, so it is written `N+`.

**Examples:**

```
rails_search_code(pattern: "publishable?", match_type: "trace")
  → FULL PICTURE: definition with class context + source code + internal calls
    + sibling methods + app callers with route chain + test coverage (separated)

rails_search_code(pattern: "create", match_type: "definition")
  → Only `def create` / `def self.create` lines

rails_search_code(pattern: "publishable", match_type: "call")
  → Only call sites (excludes the definition)

rails_search_code(pattern: "Controller", match_type: "class")
  → All class/module definitions matching *Controller

rails_search_code(pattern: "has_many", group_by_file: true)
  → Results grouped by file with match counts

rails_search_code(pattern: "post", exclude_tests: true)
  → Skip test/spec directories

rails_search_code(pattern: "activate", match_type: "definition")
  → Only `def activate` / `def self.activate` lines (skips method calls)

rails_search_code(pattern: "User", match_type: "class")
  → Only `class User` / `module User` definitions
```

**Security:** Uses `Open3.capture3` with array arguments (no shell injection). Validates file_type. Blocks path traversal. Respects `excluded_paths` and `sensitive_patterns` config on both backends, and the Ruby fallback reads the ignore files ripgrep reads and ranks them the way ripgrep does: `.rgignore` over `.ignore` over `.gitignore` (each scoped to its own directory) over `.git/info/exclude` over the global excludes file, the file type deciding before depth, which breaks ties only within one type; `.ignore` and `.rgignore` apply outside a git repository too, and a directory the rules ignore is never entered. As ripgrep does, the fallback also reads the ignore files of every directory above the app, the git ones only as far up as the nearest `.git` (a file for a worktree or submodule), so an app nested in a larger repository gets that repository's rules and a repository nested in the app stops the app's `.gitignore`. Patterns match case-sensitively, symlinks are not followed, and a file with a NUL byte in its first 64 KiB is skipped unread, all as in ripgrep, so the two return the same set.

### rails_analyze_feature

Full-stack feature analysis: models, controllers, routes, services, jobs, views, Stimulus controllers, tests, related models, concerns, callbacks, channels, mailers, and environment dependencies in one call.

**Parameters:**

| Param | Type | Description |
|-------|------|-------------|
| `feature` | string | **Required.** Feature keyword to search for (e.g. `authentication`, `User`, `payments`, `orders`). Case-insensitive partial match across models, controllers, and routes. |

**Examples:**

```
rails_analyze_feature(feature: "authentication")
  → Models, controllers, and routes matching "authentication"

rails_analyze_feature(feature: "User")
  → User model with schema columns, associations, validations, scopes;
    UsersController with actions and filters;
    all user routes with verbs and paths

rails_analyze_feature(feature: "payments")
  → Cross-cutting view: Payment model + PaymentsController + payment routes

rails_analyze_feature(feature: "orders")
  → Everything related to orders across all layers
```

**Returns:** Markdown with sections for Models (with columns, associations, validations, scopes, enums), Controllers (with actions and filters), Routes, Services (with methods), Jobs (with queue/retry), Views (with partials and Stimulus refs), Stimulus controllers (with targets/values/actions), Tests (with counts), Related models, Concerns, Callbacks, Channels, Mailers, and Environment dependencies. Each section shows match counts.

### rails_security_scan

Runs Brakeman static security analysis on the Rails app. Detects SQL injection, XSS, mass assignment, command injection, and other vulnerabilities. Uses the app's `brakeman` gem, or a `brakeman` gem installed for the same Ruby when the bundle has none. Returns installation instructions when neither is there.

**Parameters:**

| Param | Type | Description |
|-------|------|-------------|
| `files` | array | Filter results to specific files (e.g. `["app/controllers/users_controller.rb"]`). Omit to scan entire app. |
| `confidence` | string | Minimum confidence: `high`, `medium`, `weak` (default) |
| `checks` | array | Run only specific checks (e.g. `["CheckSQL", "CheckXSS"]`) |
| `detail` | string | `summary` (counts only), `standard` (file/line + message, default), `full` (+ code snippets + CWE + remediation links) |

**Examples:**

```
rails_security_scan()
  → All warnings across the entire app, sorted by confidence

rails_security_scan(files: ["app/controllers/users_controller.rb"], confidence: "high")
  → Only high-confidence warnings in the specified controller

rails_security_scan(detail: "full", checks: ["CheckSQL"])
  → Full detail with code snippets, CWE IDs, and remediation links for SQL injection only
```

**Returns:** Security warnings grouped by type with file locations, confidence levels, and messages. Full detail includes offending code snippets, CWE identifiers, and links to Brakeman documentation for each warning type.

### rails_get_concern

Get ActiveSupport::Concern details: public methods, included modules, and which models/controllers include it. Specify a name for full detail, or omit to list all concerns. Filter by type to narrow to model or controller concerns.

**Parameters:**

| Param | Type | Description |
|-------|------|-------------|
| `name` | string | Concern module name (e.g. `Searchable`, `Authenticatable`). Omit to list all concerns. |
| `type` | string | Filter by concern type, the name the listing's section headings print: `model`, `controller`, `mailer`, the root a concern outside every concerns directory lives in (`service`, `lib`), `other`, or `all` (default). |
| `detail` | string | `summary` / `standard` (default) / `full`. Only read when `name` is given: `full` adds each method's source code, `summary` and `standard` both return method signatures. The listing is the same at every level. |

**Examples:**

```
rails_get_concern()
  → Lists all model and controller concerns with method counts

rails_get_concern(name: "Searchable")
  → Full detail: public methods, class methods, macros, callbacks, and which models include it

rails_get_concern(type: "model")
  → Lists only model concerns from app/models/concerns/
```

**Returns:** Concern listing or full detail including file path, line count, included/extended modules (a conditional include with its condition), macros and DSL usage (`helper_method` included), public methods, class methods, private methods, callbacks, and a list of models or controllers that include the concern. The listing counts private methods apart from public ones. Cross-references to related model/controller tools.

### rails_get_callbacks

Get ActiveRecord model callbacks grouped by type, in Rails event order: before/after/around for validation, save, create, update, destroy. Specify a model for one model's callbacks, or omit to see all models with their callbacks.

**Parameters:**

| Param | Type | Description |
|-------|------|-------------|
| `model` | string | Model class name (e.g. `User`, `Post`). Omit to see all models with their callbacks. |
| `detail` | string | `summary` / `standard` (default) / `full`. summary: model names + callback counts. standard: callbacks by type in Rails event order. full: callbacks with method source code. |

**Examples:**

```
rails_get_callbacks(model: "User")
  → User's callbacks by type, in Rails event order: before_validation, after_validation, before_save, etc.

rails_get_callbacks(detail: "summary")
  → All models with callback counts, sorted by most callbacks

rails_get_callbacks(model: "Order", detail: "full")
  → Order's callbacks with the actual method source code for each callback
```

**Returns:** Callbacks grouped by type, in Rails event order. Includes
concern-provided callbacks, with their bodies read from the concern file.
Within one type the order is the order Rails runs them, base classes first, a
`before_` or `around_` callback with `prepend: true` first, and
`after_commit`/`after_rollback` last declared first unless the app runs them in
order (`load_defaults 7.1`). A method declared again shows once with the later
declaration's conditions. A block or lambda callback shows its declaration at
`detail: "full"`, and turbo-rails' broadcast macros (`broadcasts_refreshes`,
`broadcasts_to` and the rest) are listed as the commit callbacks they declare.

### rails_get_helper_methods

Get Rails helper modules: method signatures, framework helpers in use, and which views call each helper. Specify a helper for full detail, or omit to list all helpers with method counts.

**Parameters:**

| Param | Type | Description |
|-------|------|-------------|
| `helper` | string | Helper module name (e.g. `ApplicationHelper`, `UsersHelper`). Omit to list all helpers. |
| `detail` | string | `summary` / `standard` (default) / `full`. summary: names + method counts. standard: names + method signatures. full: method signatures + view cross-references + framework helpers. |
| `limit` | integer | Max helpers to return. Default: 50. |
| `offset` | integer | Skip this many helpers for pagination. Default: 0. |

**Examples:**

```
rails_get_helper_methods()
  → All helpers with method signatures (standard detail)

rails_get_helper_methods(helper: "ApplicationHelper")
  → Full detail: method signatures, included modules

rails_get_helper_methods(detail: "full")
  → All helpers with method signatures + detected framework helpers (Devise, Pagy, Turbo, etc.)
```

**Returns:** Helper module listing or full detail including file path, method signatures, included modules, and (at full detail) which views reference each helper method. Detects usage of framework helpers from Devise, Pagy, Turbo, Pundit, CanCanCan, Kaminari, SimpleForm, and others.

### rails_get_service_pattern

Analyze service objects in app/services/, app/interactions/ and app/interactors/: patterns, interfaces, dependencies, and side effects. Specify a service for full detail, or omit to detect the common pattern and list all services.

**Parameters:**

| Param | Type | Description |
|-------|------|-------------|
| `service` | string | Service class name or filename (e.g. `CreateOrder`, `create_order`). Omit to list all services with pattern detection. |
| `detail` | string | `summary` / `standard` (default) / `full`. summary: names only. standard: names + method signatures + line counts. full: everything including side effects, error handling, and callers. |

**Examples:**

```
rails_get_service_pattern()
  → All services with detected common pattern (e.g. "initialize + call instance method")

rails_get_service_pattern(service: "CreateOrder")
  → Full detail: initialize params, public methods, dependencies, error handling, side effects, callers

rails_get_service_pattern(detail: "full")
  → All services with methods, initialize params, side effects, and rescue blocks
```

**Returns:** Service listing with common pattern detection (initialize+call, self.call, Result objects) or full detail including file path, initialize parameters, public methods, dependencies (other classes called), error handling (rescue blocks), side effects (database writes, email delivery, job enqueues, HTTP requests, Turbo broadcasts), and a list of files that call the service. A base class other services inherit from is named above the listing rather than counted as a service; asking for it by name still answers.

### rails_get_job_pattern

Analyze background jobs in app/jobs/, app/workers/ and app/sidekiq/: queues, retries, perform signatures, guards, and what they call. Specify a job for full detail, or omit to list all jobs with queue names and retry config.

**Parameters:**

| Param | Type | Description |
|-------|------|-------------|
| `job` | string | Job class name or filename (e.g. `SendWelcomeEmailJob`, `send_welcome_email`). Omit to list all jobs. |
| `detail` | string | `summary` / `standard` (default) / `full`. summary: names + queues. standard: names + queues + retries + what they call. full: everything including guards, broadcasts, schedules, and enqueuers. |

**Examples:**

```
rails_get_job_pattern()
  → All jobs with queue summary and retry config

rails_get_job_pattern(job: "SendWelcomeEmailJob")
  → Full detail: queue, retry config, perform signature, guard clauses, dependencies, broadcasts, schedule, side effects, enqueuers

rails_get_job_pattern(detail: "full")
  → All jobs with guards, broadcasts, side effects, and schedules
```

**Returns:** Job listing with queue breakdown or full detail including queue name, retry/discard configuration (retry_on, discard_on, Sidekiq options), perform method signature, guard clauses (early returns), dependencies (classes called), Turbo broadcasts, cron/recurring schedule (from sidekiq.yml or config files), side effects, and a list of files that enqueue the job.

### rails_get_env

Discover environment variables, external service dependencies, and credentials keys used by the app. Scans .rb, .rake, ERB views and config YAML for ENV[], .env.example, Dockerfile, the env Kamal's config/deploy.yml sets (secret names; clear values, except one holding a URL or a key-like token, or under a secret-named variable, which shows as hidden, and one an ERB tag sets, which says so), config gem setting keys, Anyway::Config attributes with their env names, external HTTP calls, and credentials keys (never values).

**Parameters:**

| Param | Type | Description |
|-------|------|-------------|
| `detail` | string | `summary` / `standard` (default) / `full`. summary: env var names only. standard: env vars grouped by source + external services. full: everything including per-file locations, Dockerfile vars, and credentials keys. |

**Examples:**

```
rails_get_env()
  → Env vars grouped by purpose (Database, Redis, AWS, etc.) + external services + credentials keys

rails_get_env(detail: "summary")
  → Env var names grouped by category

rails_get_env(detail: "full")
  → Per-file env var locations with line numbers, .env.example contents, Dockerfile ENV/ARG, external services with detection method, credentials keys, encrypted columns
```

**Returns:** Environment variables grouped by purpose (Database, Redis, AWS, Payments, Email, Monitoring, API Keys, etc.) with default values where detected. External service dependencies discovered from Gemfile gems and HTTP client calls. Credentials keys (never values). Encrypted model columns. Full detail includes per-file locations with line numbers.

### rails_get_partial_interface

Analyze a partial's interface: local variables it expects, where it's rendered from, and what methods are called on each local. Use when rendering a partial, understanding what locals to pass, or refactoring partial dependencies.

**Parameters:**

| Param | Type | Description |
|-------|------|-------------|
| `partial` | string | **Required.** Partial path relative to app/views (e.g. `shared/status_badge`, `users/form`). The leading underscore is optional. |
| `detail` | string | `summary` / `standard` (default) / `full`. summary: locals list + usage count. standard: locals + usage examples from codebase. full: locals + usage + full partial source. |

**Examples:**

```
rails_get_partial_interface(partial: "shared/status_badge")
  → Local variables, method calls on each local, and all render sites with locals passed

rails_get_partial_interface(partial: "users/form", detail: "summary")
  → Local variable names + number of render sites

rails_get_partial_interface(partial: "shared/card", detail: "full")
  → Full detail: locals, method calls, render sites with code snippets, and full partial source
```

**Returns:** Partial interface including declared locals (Rails 7.1+ magic comment), detected local variable references, method calls on each local, and render sites with file/line and locals passed. Supports underscore-prefixed and non-prefixed names. Full detail includes the complete partial source code.

### rails_get_turbo_map

Map Turbo Streams and Frames across the app: model broadcasts, channel subscriptions, frame tags, and DOM target mismatches. Filter by stream or controller name.

**Parameters:**

| Param | Type | Description |
|-------|------|-------------|
| `detail` | string | `summary` / `standard` (default) / `full`. summary: count of streams, frames, model broadcasts. standard: each stream with source to target. full: everything including inline template refs and DOM IDs. |
| `stream` | string | Filter by stream/channel name (e.g. `notifications`, `messages`). Shows only broadcasts and subscriptions for this stream. |
| `controller` | string | Filter by controller name (e.g. `messages`, `comments`). Shows Turbo usage in that controller's views and actions. |

**Examples:**

```
rails_get_turbo_map()
  → Model broadcasts, explicit broadcasts, stream subscriptions, Turbo Frames, and mismatch warnings

rails_get_turbo_map(stream: "notifications")
  → Only broadcasts and subscriptions for the "notifications" stream

rails_get_turbo_map(controller: "messages", detail: "full")
  → Full Turbo usage in messages controller with DOM IDs, stream wiring map, and mismatch warnings
```

**Returns:** Turbo Streams and Frames mapped across the app. Model broadcasts (via `broadcasts`, `broadcasts_to`, `broadcasts_refreshes`), explicit broadcasts (`broadcast_replace_to`, `broadcast_append_to`, etc.), stream subscriptions (`turbo_stream_from` in views), and Turbo Frames (`turbo_frame_tag` with IDs and src). Full detail includes a stream wiring map connecting broadcasters to subscribers, and warnings for broadcasts without subscribers or subscriptions without broadcasters.

### rails_get_context

Get cross-layer context in a single call - combines schema, model, controller, routes, views, stimulus, and tests. Automatically includes **Schema Hints** for models referenced in controller/view code. Use when you need full context for implementing a feature or modifying an action.

**Parameters:**

| Param | Type | Description |
|-------|------|-------------|
| `controller` | string | Controller name (e.g. `PostsController`). Returns action source, filters, strong params, routes, views. |
| `action` | string | Specific action name (e.g. `create`). Requires controller. Returns full action context. |
| `model` | string | Model name (e.g. `Post`). Returns schema, associations, validations, scopes, callbacks, tests. |
| `feature` | string | Feature keyword (e.g. `post`). Like analyze_feature but includes schema columns and scope bodies. |
| `include` | array | Extra context to append in any mode: `stimulus`, `turbo`, `services`, `jobs`, `conventions`, `helpers`, `env`, `callbacks`. |

**Examples:**

```
rails_get_context(controller: "PostsController", action: "create")
  → Controller action source + model details + routes + views - everything for that action

rails_get_context(model: "User")
  → Model details + schema columns + the names of its tests

rails_get_context(feature: "orders")
  → Full-stack feature analysis including schema columns and scope bodies
```

**Returns:** Combined context from multiple tools in a single response. For controller+action: controller source with filters, inferred model details, matching routes, and view templates. For model: model details with associations/validations/scopes, schema columns with types, and the names of the tests in its test file. For feature: delegates to full-stack feature analysis.

### Detail Level Summary

All tools that support `detail` use these three levels. Default limits vary by tool - schema defaults shown below:

| Level | What it returns | Schema default limit | Best for |
|-------|----------------|---------------------|----------|
| `summary` | Names + counts | 50 | Getting the landscape, understanding what exists |
| `standard` | Names + key details | 25 | Working context, column types, action names |
| `full` | Everything | 10 | Deep inspection, indexes, FKs, constraints |

Other tools default to higher limits (e.g. models/controllers/stimulus: 50 for all levels, routes: 150/200).

### Recommended Workflow

1. **Start with `detail:"summary"`** to see what exists
2. **Filter by name** (`table:`, `model:`, `controller:`) for the item you need
3. **Use `detail:"full"`** only when you need indexes, foreign keys, or constraints
4. **Paginate** with `limit` and `offset` for large result sets

---

## MCP Resources

In addition to tools, the gem registers static MCP resources that AI clients can read directly:

| Resource URI | Description |
|-------------|-------------|
| `rails://schema` | Full database schema (JSON) |
| `rails://routes` | All routes (JSON) |
| `rails://conventions` | Detected patterns and architecture (JSON) |
| `rails://gems` | Notable gems with categories, plus `declared_ruby_version` and which of the lockfile, Gemfile, `.ruby-version`, `.tool-versions` or a mise config file answered (JSON) |
| `rails://controllers` | All controllers with actions and filters (JSON) |
| `rails://config` | Application configuration (JSON) |
| `rails://tests` | Test infrastructure details (JSON) |
| `rails://migrations` | Migration history and statistics (JSON) |
| `rails://engines` | Mounted engines with paths and descriptions (JSON) |
| `rails-ai-context://models/{name}` | Per-model details (resource template) |

The legacy `rails://models/{name}` form is still accepted.

### Dynamic Resource Templates (VFS)

Live resources introspected afresh on every request, after the app's code is reloaded for any edit:

| Resource Template | Description |
|-------------------|-------------|
| `rails-ai-context://controllers/{name}` | Controller details with actions, filters, strong params |
| `rails-ai-context://controllers/{name}/{action}` | Specific action source code and applicable filters |
| `rails-ai-context://views/{path}` | View template content (path traversal protected) |
| `rails-ai-context://routes/{controller}` | Live route map, filtered by controller |

---

## MCP Server Setup

### MCP Registry

This server is listed on the [official MCP Registry](https://registry.modelcontextprotocol.io) as `io.github.crisnahine/rails-ai-context`.

```bash
# Search for it
curl "https://registry.modelcontextprotocol.io/v0.1/servers?search=rails-ai-context"
```

### Auto-discovery (recommended)

The install generator (or `rails-ai-context init`) creates per-tool MCP config files based on your selected AI tools:

| AI Tool | Config File | Root Key | Format |
|---------|------------|----------|--------|
| Claude Code | `.mcp.json` | `mcpServers` | JSON |
| Cursor | `.cursor/mcp.json` | `mcpServers` | JSON |
| GitHub Copilot | `.vscode/mcp.json` | `servers` | JSON |
| OpenCode | `opencode.json` | `mcp` | JSON |
| Codex CLI | `.codex/config.toml` | `[mcp_servers]` | TOML |

Each file is merge-safe - only the `rails-ai-context` entries are managed, other servers are preserved. When the gem is not in the app's `Gemfile.lock` (standalone install) the entry runs `rails-ai-context serve` with no `bundle exec`.

A folder of apps gets one entry per app instead, `rails-ai-context-<app folder>`, each pointed at its app with `--app-path` and announcing its app first through `RAILS_AI_CONTEXT_SERVER_NAME`; see [`init`](CLI.md#init-standalone-only) for the shape each AI tool gets.

**Example: `.mcp.json` (Claude Code)**
```json
{
  "mcpServers": {
    "rails-ai-context": {
      "command": "bundle",
      "args": ["exec", "rails-ai-context", "serve"]
    }
  }
}
```

**Example: `.codex/config.toml` (Codex CLI)**
```toml
[mcp_servers.rails-ai-context]
command = "bundle"
args = ["exec", "rails-ai-context", "serve"]

[mcp_servers.rails-ai-context.env]
PATH = "/home/user/.rbenv/shims:/usr/local/bin:/usr/bin"
GEM_HOME = "/home/user/.rbenv/versions/3.3.0/lib/ruby/gems/3.3.0"
```

> **Why the `[env]` section?** Codex CLI `env_clear()`s the process before spawning MCP servers, stripping Ruby version manager paths. The install generator snapshots your current Ruby environment (PATH, GEM\_HOME, GEM\_PATH, GEM\_ROOT, RUBY\_VERSION, BUNDLE\_PATH) so the MCP server can find gems regardless of version manager (rbenv, rvm, asdf, mise, chruby, or system Ruby).

Each AI tool auto-detects its own config file. No manual config needed - just open your project.

### Claude Code

Auto-discovered via `.mcp.json`. Or add manually:

```bash
# In-Gemfile
claude mcp add rails-ai-context -- bundle exec rails ai:serve

# Standalone
claude mcp add rails-ai-context -- rails-ai-context serve
```

### Claude Desktop

Add to `~/Library/Application Support/Claude/claude_desktop_config.json` (macOS) or `%APPDATA%\Claude\claude_desktop_config.json` (Windows):

```json
{
  "mcpServers": {
    "rails-ai-context": {
      "command": "bundle",
      "args": ["exec", "rails-ai-context", "serve"],
      "cwd": "/path/to/your/rails/app"
    }
  }
}
```

Or for standalone: replace `"command": "bundle"` / `"args": ["exec", "rails-ai-context", "serve"]` with `"command": "rails-ai-context"` / `"args": ["serve"]`.

### Cursor

Auto-discovered via `.cursor/mcp.json`. Or add manually in **Cursor Settings > MCP**:

```json
{
  "mcpServers": {
    "rails-ai-context": {
      "command": "bundle",
      "args": ["exec", "rails-ai-context", "serve"],
      "cwd": "/path/to/your/rails/app"
    }
  }
}
```

For standalone: use `"command": "rails-ai-context"` / `"args": ["serve"]` instead.
```

### HTTP transport

For browser-based or remote AI clients:

```bash
rails ai:serve_http
# Starts at http://127.0.0.1:6029/mcp
```

Or auto-mount inside your Rails app (no separate process):

```ruby
if defined?(RailsAiContext) && RailsAiContext.respond_to?(:configure)
  RailsAiContext.configure do |config|
    config.auto_mount = true
    config.http_path  = "/mcp"       # default
    config.http_port  = 6029          # default
    config.http_bind  = "127.0.0.1"  # default (localhost only)
  end
end
```

Both transports are **read-only** - they expose the same 45 tools and never modify your app.

### Controller Transport (Alternative)

For tighter Rails integration (authentication, routing, middleware stack), mount the engine instead of using Rack middleware:

```ruby
# config/routes.rb
mount RailsAiContext::Engine, at: "/mcp"
```

This provides a native Rails controller (`RailsAiContext::McpController`) that delegates to the Streamable HTTP transport.

---

## Configuration - All Options

```ruby
# config/initializers/rails_ai_context.rb
if defined?(RailsAiContext) && RailsAiContext.respond_to?(:configure)
  RailsAiContext.configure do |config|
    # --- Introspectors ---

    # Presets: :full (40 introspectors, default) or :standard (17)
    config.preset = :full

    # Cherry-pick on top of a preset
    config.introspectors += %i[views turbo auth api]

    # --- Context files ---

    # Context mode: :compact (default) or :full
    config.context_mode = :compact

    # Max lines for CLAUDE.md in compact mode
    config.claude_max_lines = 150

    # Output directory for context files (default: Rails.root)
    # config.output_dir = "/custom/path"

    # --- MCP tools ---

    # Tool mode: :mcp (MCP primary + CLI fallback) or :cli (CLI only)
    config.tool_mode = :mcp

    # Max response size for tool results (safety net)
    config.max_tool_response_chars = 200_000

    # Cache TTL for introspection results (seconds)
    config.cache_ttl = 60

    # Additional MCP tool classes to register alongside built-in tools
    # config.custom_tools = [MyApp::Tools::CustomTool]

    # Exclude specific built-in tools (e.g. if you don't use Brakeman)
    # config.skip_tools = %w[rails_security_scan]

    # --- Exclusions ---

    # Models to skip during introspection
    config.excluded_models += %w[AdminUser InternalAuditLog]

    # Paths to exclude from code search
    config.excluded_paths += %w[vendor/bundle]

    # Sensitive file patterns blocked from search and read tools
    # config.sensitive_patterns += %w[config/my_secret.yml]

    # Controllers hidden from listings (e.g. Devise internals)
    # config.excluded_controllers += %w[MyInternalController]

    # Route prefixes hidden with app_only (e.g. admin frameworks)
    # config.excluded_route_prefixes += %w[admin/]

    # Framework association names hidden from model output (ActiveStorage, ActionText, etc.)
    # config.excluded_association_names += %w[my_custom_framework_assoc]

    # Regex patterns for concerns to hide from model output
    # config.excluded_concerns += [/MyInternal::/]

    # Framework filter names hidden from controller output
    # config.excluded_filters += %w[my_internal_filter]

    # Default middleware hidden from config output
    # config.excluded_middleware += %w[MyMiddleware]

    # --- File size limits ---

    # Per-file read limit for tools (default: 5MB)
    # config.max_file_size = 5_000_000

    # Test file read limit (default: 1MB)
    # config.max_test_file_size = 1_000_000

    # schema.rb / structure.sql parse limit (default: 10MB)
    # config.max_schema_file_size = 10_000_000

    # app/views size the doctor warns past - not a read cap (default: 10MB)
    # config.max_view_total_size = 10_000_000

    # Accepted and stored; no check reads it (default: 1MB)
    # config.max_view_file_size = 1_000_000

    # Max search results per call (default: 200)
    # config.max_search_results = 200

    # Max files per validate call (default: 50)
    # config.max_validate_files = 50

    # --- Search and file discovery ---

    # Narrow the Ruby fallback to these extensions (unset: every file, as ripgrep)
    # config.search_extensions = %w[rb js erb yml yaml json ts tsx vue svelte haml slim]

    # Where to look for concern source files. Left unset, every
    # app/concerns and app/*/concerns directory is discovered. Setting this replaces
    # that list, so it can narrow as well as reach outside app/.
    # config.concern_paths = %w[app/models/concerns lib/concerns]

    # --- Live reload ---

    # Auto-invalidate MCP tool caches on file changes
    # :auto - enable if `listen` gem is available (default)
    # true  - enable, raise if `listen` is missing
    # false - disable entirely
    config.live_reload = :auto
    config.live_reload_debounce = 1.5  # seconds

    # --- HTTP MCP endpoint ---

    # Auto-mount Rack middleware for HTTP MCP
    config.auto_mount = false
    config.http_path  = "/mcp"
    config.http_bind  = "127.0.0.1"
    config.http_port  = 6029
  end
end
```

### Options reference

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `preset` | Symbol | `:full` | Introspector preset (`:full` or `:standard`) |
| `introspectors` | Array | 40 (full preset) | Which introspectors to run |
| `context_mode` | Symbol | `:compact` | `:compact` or `:full` |
| `claude_max_lines` | Integer | `150` | Budget for the non-blank lines of a compact context file's gem-managed block, the `<!-- BEGIN/END rails-ai-context -->` markers included. Over budget, the data sections (Stack, Key models, Gems, Architecture) are cut first, down to none; the title and the Commands, Warnings, Rules and Tools sections are never cut, so they set the smallest file a budget can give (about 110 lines with the anti-hallucination protocol) |
| `max_tool_response_chars` | Integer | `200_000` | Safety cap for MCP tool responses and resource payloads |
| `cache_ttl` | Integer | `60` | Cache TTL in seconds for introspection results |
| `custom_tools` | Array | `[]` | Additional MCP tool classes to register alongside built-in tools |
| `skip_tools` | Array | `[]` | Built-in tool names to exclude (e.g. `%w[rails_security_scan]`) |
| `tool_mode` | Symbol | `:mcp` | `:mcp` (MCP primary + CLI fallback) or `:cli` (CLI only, no MCP server needed) |
| `ai_tools` | Array | `nil` (all) | AI tools to generate context for: `%i[claude cursor copilot opencode codex]`. Selected during install. |
| `excluded_models` | Array | internal Rails models | Models to skip |
| `excluded_paths` | Array | `node_modules tmp log vendor .git doc docs` | Paths excluded from code search |
| `sensitive_patterns` | Array | `.env`, `.key`, `.pem`, credentials | File patterns blocked from search and read tools |
| `output_dir` | String | `nil` (Rails.root) | Where to write context files. OpenCode's `app/models/AGENTS.md` and `app/controllers/AGENTS.md` are written only where that directory exists under it |
| `auto_mount` | Boolean | `false` | Auto-mount HTTP MCP endpoint |
| `http_path` | String | `"/mcp"` | HTTP endpoint path |
| `http_bind` | String | `"127.0.0.1"` | HTTP bind address |
| `http_port` | Integer | `6029` | HTTP server port |
| `live_reload` | Symbol/Boolean | `:auto` | `:auto`, `true`, or `false` - enable MCP live reload |
| `live_reload_debounce` | Float | `1.5` | Debounce interval in seconds for live reload |
| `server_name` | String | `"rails-ai-context"` | The MCP server name the server announces. When it is left at the default, the `RAILS_AI_CONTEXT_SERVER_NAME` environment variable takes its place for one process, which is how a workspace's entries announce their app |
| `server_version` | String | gem version | MCP server version. Read-only, there is no setter |
| `generate_root_files` | Boolean | `true` | Set `false` to generate split rules only: no CLAUDE.md, AGENTS.md, .cursorrules or copilot-instructions.md (`.ai-context.json` is still written) |
| `anti_hallucination_rules` | Boolean | `true` | Embed 6-rule Anti-Hallucination Protocol in generated context files - set `false` to skip |
| `hydration_enabled` | Boolean | `true` | Inject schema hints into controller/view tool responses |
| `hydration_max_hints` | Integer | `5` | Max schema hints per tool response |
| `max_file_size` | Integer | `5_000_000` | Per-file read limit for tools (5MB) |
| `max_test_file_size` | Integer | `1_000_000` | Test file read limit (1MB) |
| `max_schema_file_size` | Integer | `10_000_000` | schema.rb / structure.sql parse limit (10MB) |
| `max_view_total_size` | Integer | `10_000_000` | Doctor threshold: app/views above this warns (10MB). Not a read cap |
| `max_view_file_size` | Integer | `1_000_000` | Accepted and stored; no check reads it (1MB). Not a read cap |
| `max_search_results` | Integer | `200` | Max lines a search may emit per call, matches and context together |
| `max_validate_files` | Integer | `50` | Max files per validate call |
| `excluded_controllers` | Array | `DeviseController`, etc. | Controller classes hidden from listings |
| `excluded_route_prefixes` | Array | `action_mailbox/`, `active_storage/`, etc. | Route controller prefixes hidden with `app_only` |
| `excluded_association_names` | Array | 7 framework associations | Framework association names hidden from model output |
| `excluded_concerns` | Array of Regex or String | framework regex patterns | Patterns for concerns to hide. A YAML list replaces the framework defaults; the initializer's `+=` adds to them |
| `excluded_filters` | Array | `verify_authenticity_token`, etc. | Framework filter names hidden from controller output |
| `excluded_middleware` | Array | standard Rails middleware | Default middleware hidden from config output |
| `search_extensions` | Array | `nil` | Narrows the Ruby fallback to these extensions. Unset, it searches every non-hidden, non-binary file, as ripgrep does |
| `concern_paths` | Array | `nil` (discovers `app/concerns` and `app/*/concerns`) | Where to look for concern source files. Setting it replaces discovery |
| `context_files` | Boolean | `true` | Set `false` for an MCP-only install: no CLAUDE.md, AGENTS.md, rules files or `.ai-context.json` are written |
| `frontend_paths` | Array | `nil` (auto-detected) | Frontend directories, e.g. `["app/frontend", "../web-client"]`. One outside the app root is read for manifests only |
| `extra_app_paths` | Array | `[]` | More app-root-relative directories that hold Rails app code. Each one's `app/models`, `app/controllers` and `app/views` are scanned |
| `query_timeout` | Integer | `5` | `rails_query` statement timeout in seconds |
| `query_row_limit` | Integer | `100` | Max rows `rails_query` returns (1 to 1000) |
| `query_redacted_columns` | Array | `password_digest`, `encrypted_password`, tokens, etc. | Column names `rails_query` refuses: a query naming one is rejected before it runs, and a returned column of that name comes back `[FILTERED]` |
| `query_allowed_columns` | Array | `[]` | Column names to exempt from the built-in sensitive list |
| `allow_query_in_production` | Boolean | `false` | Allow `rails_query` in production |
| `log_lines` | Integer | `50` | Default number of lines `rails_read_logs` tails |
| `instrumentation_include_arguments` | Boolean | `false` | Forward raw tool arguments in `ActiveSupport::Notifications` events |

### Root file generation

By default, `rails ai:context` generates root files (CLAUDE.md, AGENTS.md, etc.) alongside split rules.

**Section markers:** Generated content is wrapped in `<!-- BEGIN rails-ai-context -->` / `<!-- END rails-ai-context -->` markers. If you add custom notes above or below the markers, they will be preserved when you re-run `rails ai:context`.

**Skip root files:** If you prefer to maintain root files yourself and only want split rules (`.claude/rules/`, `.cursor/rules/`, `.github/instructions/`):

```ruby
if defined?(RailsAiContext) && RailsAiContext.respond_to?(:configure)
  RailsAiContext.configure do |config|
    config.generate_root_files = false
  end
end
```

The Claude Code, Cursor and Copilot rule sets each keep an app overview file (`rails-context.md`, `rails-project.mdc`, `rails-context.instructions.md`). The Claude Code one leaves out gems, architecture, services and jobs, which it expects in CLAUDE.md. OpenCode and Codex have no overview outside AGENTS.md: their split files hold only the model and controller listings.

---

## Introspectors - Full List

### Standard preset (17 introspectors)

Core Rails structure only. Use `config.preset = :standard` for a lighter footprint.

| Introspector | What it discovers |
|-------------|-------------------|
| `schema` | Tables, columns, types, indexes, foreign keys, primary keys. Falls back to `db/schema.rb` parsing when no DB connected. |
| `models` | Associations, validations, scopes, enums, callbacks, concerns, instance methods, class methods. Source-level macros via Prism AST (single-pass, 8 listeners): `has_secure_password`, `encrypts`, `normalizes`, `delegate`, `serialize`, `store`, `generates_token_for`, `has_one_attached`, `has_many_attached`, `has_rich_text`, `broadcasts`, `broadcasts_to`, `broadcasts_refreshes`, `broadcasts_refreshes_to`. Every result tagged `[VERIFIED]` or `[INFERRED]`. |
| `routes` | All routes with HTTP verbs, paths, controller actions, route names, API namespaces, mounted engines. |
| `jobs` | ActiveJob classes with queue names. Mailers with action methods. Action Cable channels. |
| `gems` | 127 notable gems categorized: auth, jobs, frontend, api, database, files, testing, deploy, monitoring, admin, pagination, search, forms, server, notifications, validation, utilities, services, payments. |
| `conventions` | Architecture patterns (MVC, service objects, STI, polymorphism, etc.), directory structure with file counts, config files, detected patterns. |
| `controllers` | Actions, filters (before/after/around with only/except), strong params methods, parent class, API controller detection, concerns. |
| `tests` | Test framework (rspec/minitest), factories/fixtures with locations and counts, system tests, CI config files, coverage tool, test helpers, VCR cassettes. |
| `migrations` | Total count, schema version, pending migrations, recent migration history with detected actions (create_table, add_column, etc.), migration statistics. |
| `config` | Cache store, session store, timezone, queue adapter, mailer settings, middleware stack, initializers, credentials status, CurrentAttributes classes. |
| `stimulus` | Stimulus controllers with targets, values (with types), actions, outlets, classes. Extracted from JS/TS files. |
| `view_templates` | View file contents, partial references, Stimulus data attributes, model field usage in partials. |
| `components` | ViewComponent/Phlex components: props, slots, previews, sidecar assets, usage examples. |
| `turbo` | Turbo Frames (IDs and files), Turbo Stream templates, model broadcasts (`broadcasts_to`, `broadcasts`). |
| `auth` | Devise models with modules, Rails 8 built-in auth, has_secure_password, policy classes in app/policies (named Pundit only when the app bundles it), an Ability class (named CanCanCan only when the app bundles it), CORS config, CSP config. |
| `performance` | N+1 query risks, missing counter_cache, missing FK indexes, Model.all anti-patterns, eager load candidates. |
| `i18n` | Default locale, available locales, locale files with key counts, backend class, parse errors. |

### Full preset (40 introspectors) - default

Includes all standard introspectors plus:

| Introspector | What it discovers |
|-------------|-------------------|
| `views` | Layouts, templates grouped by controller, partials (per-controller and shared), helpers with methods, template engines (erb, haml, slim), view components. |
| `active_storage` | Attachments (has_one_attached, has_many_attached per model), storage services, direct upload config. |
| `action_text` | Rich text fields (has_rich_text per model), Action Text installation status. |
| `api` | API-only mode, API versioning (from directory structure), serializers (Jbuilder, AMS, etc.), GraphQL (types, mutations), rate limiting (Rack::Attack). |
| `rake_tasks` | Custom rake tasks from the Rakefile, `lib/tasks/` and `rakelib/` (names, arguments, descriptions, namespaces, file paths); the app's generators under `lib/generators`, `lib/templates` overrides and the Railties under `lib/`. |
| `assets` | Asset pipeline (Propshaft/Sprockets), JS bundler (importmap/esbuild/webpack/vite), CSS framework, importmap pins, manifest files. |
| `devops` | Puma config (threads, workers, port), Procfile entries, Docker (multi-stage detection), deployment tools, health check routes. |
| `action_mailbox` | Action Mailbox mailboxes with routing patterns. |
| `seeds` | db/seeds.rb analysis (Faker usage, environment conditionals), seed files in db/seeds/, models seeded. |
| `middleware` | Custom Rack middleware in app/middleware/ and lib/middleware/ with detected patterns (auth, rate limiting, tenant isolation, logging), what the app's config inserts, moves or removes, and the full middleware stack. |
| `engines` | Mounted Rails engines from routes.rb with paths and descriptions for 23 known engines (Sidekiq::Web, Flipper::UI, PgHero, ActiveAdmin, etc.). |
| `env_config` | Per-environment config files (`config/environments/*.rb`): notable toggles (`force_ssl`, `eager_load`, caching, log level, queue adapter, mailer delivery) with URI credentials redacted, assigned config keys, plus the keys `config/application.rb` sets for every environment and the keys each `config_for` YAML file gives. |
| `multi_database` | Multiple databases, replicas, sharding config, model-specific `connects_to` declarations. database.yml parsing fallback. |
| `frontend_frameworks` | Frontend JS framework detection (React/Vue/Svelte/Angular), mounting strategy (Inertia/react-rails), TypeScript config, state management, package manager. |
| `database_stats` | PostgreSQL approximate row counts via `pg_stat_user_tables`. Gracefully skips on non-PostgreSQL adapters. |
| `initializers` | The `Rails.application.initializers` graph (name, owner, `before:`/`after:` edges) and a per-file summary of `config/initializers/*.rb`. |
| `autoload` | Zeitwerk autoloaders with collapsed and ignored dirs, `autoload_paths`, `eager_load_paths`, custom inflections. |
| `connection_pool` | Per-database adapter config: pool size, `checkout_timeout`, `reaping_frequency`, `prepared_statements`, replica flag, connection-handler roles. |
| `active_support` | Concerns in `app/**/concerns/`, deprecators, MessageEncryptor/Verifier usage, notification subscriptions, on-load hooks, cache store options. |
| `credentials` | Encrypted credentials files (default and per-environment), where the master key comes from, top-level key names only (never values). |
| `security` | `force_ssl` and SSL options, host authorization, Content Security Policy and Permissions Policy directives, CSRF config, cookie session options. |
| `observability` | Log subscribers, `ActiveSupport::Notifications` subscribers, `ServerTiming` middleware, log level and tags. |
| `env` | Rails-related ENV vars split into set and unset (sensitive ones are redacted), plus the app's own `ENV["X"]` references. |

### Using the standard preset

```ruby
config.preset = :standard
```

### Cherry-picking introspectors

```ruby
# Start with standard, add specific ones
config.preset = :standard
config.introspectors += %i[views turbo auth api]

# Or build from scratch
config.introspectors = %i[schema models routes gems auth api]
```

---

## AI Assistant Setup

### Claude Code

**Auto-discovery:** Opens `.mcp.json` automatically. No setup needed.

**Context files loaded:**
- `CLAUDE.md` - read at conversation start
- `.claude/rules/*.md` - auto-loaded alongside CLAUDE.md (schema, models, and components rules use `paths:` frontmatter for conditional loading)

**MCP tools:** Available immediately via `.mcp.json`.

### Cursor

**Auto-discovery:** Opens `.cursor/mcp.json` automatically. No setup needed.

**Context files loaded:**
- `.cursor/rules/*.mdc` - loaded based on `alwaysApply` and `globs` settings

**MDC rule activation modes:**
| Mode | When it activates |
|------|-------------------|
| `alwaysApply: true` | Every conversation (project overview) |
| `globs: ["app/models/**/*.rb"]` | When editing files matching the glob pattern |
| `alwaysApply: false` + `description` | Agent-requested - loaded when AI decides it's relevant (MCP tools rule) |

### OpenCode

**Auto-discovery:** `opencode.json` is auto-generated by the install generator. Or add manually:

```json
{
  "mcp": {
    "rails-ai-context": {
      "type": "local",
      "command": ["bundle", "exec", "rails-ai-context", "serve"]
    }
  }
}
```

For standalone: use `"command": ["rails-ai-context", "serve"]` instead.

```json
{
  "mcp": {
    "rails-ai-context": {
      "type": "local",
      "command": ["rails-ai-context", "serve"]
    }
  }
}
```

**Context files loaded:**
- `AGENTS.md` - project overview + MCP tool guide, read at conversation start
- `app/models/AGENTS.md` - model listing, auto-loaded when agent reads model files
- `app/controllers/AGENTS.md` - controller listing, auto-loaded when agent reads controller files
- Falls back to `CLAUDE.md` if no `AGENTS.md` exists

OpenCode uses **per-directory lazy-loading**: when the agent reads a file, it walks up the directory tree and auto-loads any `AGENTS.md` it finds. This is how split rules work - no globs or frontmatter needed.

**MCP tools:** Available via `opencode.json` (auto-generated or manual config above).

### GitHub Copilot

**Auto-discovery:** `.vscode/mcp.json` is auto-generated by the install generator.

**Context files loaded:**
- `.github/copilot-instructions.md` - repo-wide instructions
- `.github/instructions/*.instructions.md` - path-specific, activated by `applyTo` glob (with `name:` and `description:` frontmatter)

**applyTo patterns:**
| Pattern | When it activates |
|---------|-------------------|
| `app/models/**/*.rb` | Editing model files |
| `app/controllers/**/*.rb` | Editing controller files |
| `**/*` | All files (MCP tool reference) |

### Codex CLI

**Auto-discovery:** `.codex/config.toml` is auto-generated by the install generator, including an `[env]` subsection that snapshots your Ruby environment for sandbox compatibility.

**Context files loaded:**
- `AGENTS.md` - project overview + MCP tool guide (shared with OpenCode)
- `app/models/AGENTS.md` - model listing, auto-loaded when agent reads model files
- `app/controllers/AGENTS.md` - controller listing, auto-loaded when agent reads controller files

**MCP tools:** Available via `.codex/config.toml`.

---

## Stack Compatibility

| Setup | Coverage | Notes |
|-------|----------|-------|
| Rails full-stack (ERB + Hotwire) | 40/40 | All introspectors relevant |
| Rails + Inertia.js (React/Vue) | Backend ones | Views/Turbo partially useful, backend fully covered |
| Rails API + React/Next.js SPA | Backend ones | Schema, models, routes, API, auth, jobs - all covered |
| Rails API + mobile app | Backend ones | Same as SPA - backend introspection is identical |
| Rails engine (mountable gem) | Core ones | Core introspectors (schema, models, routes, gems) work |

All 40 introspectors run on every setup with the default `:full` preset. The gem keeps no per-setup count: frontend introspectors (views, Turbo, Stimulus, assets) degrade gracefully - they report nothing when those features aren't present.

**Tip for API-only apps:**

```ruby
# Use standard preset (it already has auth)
config.preset = :standard

# And add the API introspector, which standard leaves out
config.introspectors += %i[api]
```

---

## Diagnostics

```bash
rails ai:doctor
```

Runs the checks below and reports an AI readiness score (0-100). A check that does not apply to the app prints no row:

| Check | What it verifies |
|-------|------------------|
| Schema | A schema dump file exists |
| Pending migrations | No migration is pending in any database the app migrates, each read through its own connection as `db:migrate:status` reads it (fails when one is) |
| Database | Shown in place of Pending migrations when a database the app migrates does not exist (fix: `bin/rails db:prepare`) or its server does not answer (fails) |
| Models | Model files detected where the tools read them: `app/models`, packs and in-repo engines, and in an engine's `test/dummy` the engine's own |
| Routes | `config/routes.rb` exists |
| Gems | The app's lockfile exists, or the one its `config/boot.rb` names (a monorepo's shared bundle, an engine's for its `test/dummy`) |
| Controllers | Controller files detected, read as Models are |
| Views | Files exist where the tools read views: `app/views`, packs, and in an engine's `test/dummy` the engine's |
| Tests | A test suite is found: the app's, or in an engine's `test/dummy` the engine's |
| Migrations | Migration files exist, counted over every database the app migrates, and in an engine's `test/dummy` the engine's own |
| Context files | Generated context files exist where `config.output_dir` puts them, and a context run would leave them as they are. A file a run would rewrite, because an older version of the gem wrote it or the app changed under it, is named; a file that is only older than the code is not. No row on an MCP-only install |
| Initializer guard | Shown only when `config/initializers/rails_ai_context.rb` has no guard, or guards on `defined?(RailsAiContext)` alone |
| MCP configs | Each selected tool's MCP config file exists, parses, and holds a rails-ai-context server whose command can start: `bundle exec` only where the app's lockfile carries the gem and the bundle's copy has its executable, the `rails-ai-context` binary only where it is on PATH, and a warning when a config runs that binary in an app whose bundle carries the gem. The command is looked up, never run. Skipped in CLI-only mode |
| Codex env snapshot | The `PATH` saved in `.codex/config.toml` (the app's, or a folder of apps' above it) still reaches each server's command, and a saved `GEM_HOME` still exists. Only when Codex is selected |
| MCP server | MCP server can be built, with an `mcp` gem this gem supports (warns, as the boot does, when the app's bundle pins one outside that range) |
| Introspector health | Every configured introspector returns data |
| Preset coverage | The preset covers the features the app has |
| ripgrep | `rg` binary installed (optional, falls back to Ruby) |
| Prism parser | Prism is available for AST-based validation, at a version this gem supports (warns, as the boot does, when the app's bundle pins one below it) |
| Brakeman | Brakeman is available for `rails_security_scan` (optional) |
| Live reload | `listen` gem installed (optional, enables MCP live reload) |
| MCP stdio hygiene | On a standalone install, or where a config starts the `rails-ai-context` binary itself, gem activation prints nothing on stdout |
| Secrets in .gitignore | Secret files that exist are gitignored: `config/master.key`, `config/credentials/*.key`, every `.env` file, `config/application.yml`, the Codex config and SSH and cloud credentials (fails when one is not). `config/database.yml`, `cable.yml`, `storage.yml` and the like warn only when they hold a password, token or key as a literal value. The encrypted `credentials.yml.enc` is committed by design and never reported |
| MCP auto_mount | `auto_mount` is not on in production |
| Schema file size | The schema file is under 80% of `max_schema_file_size` |
| View aggregation size | `app/views` templates total under 80% of `max_view_total_size` |

Each check reports **pass**, **warn**, or **fail** with fix suggestions.

---

## Watch Mode

Auto-regenerate context files when your code changes:

```bash
rails ai:watch
```

Requires the `listen` gem:

```ruby
# Gemfile
gem "listen", group: :development
```

Watches for changes in: `app/`, `config/`, `db/`, `lib/`, `rakelib/`, `test/`, `spec/`, plus the app directories of packs, in-repo engines and `extra_app_paths`, and regenerates only the files that changed (diff-aware, skips unchanged files).

---

## Live Reload (MCP)

When running the MCP server via `rails ai:serve`, **live reload** automatically invalidates tool caches and notifies connected AI clients when files change - so the AI always has fresh context without manual re-querying.

Without the `listen` gem, which a new Rails 8 app does not bundle, answers still follow edits: each tool call first checks the watched files (a few milliseconds on a typical app, about 100 ms at 10,000 files, where calls close together share one check) and, when one changed, reloads the app's code and drops the caches. What `listen` adds is the notification to the client, and no per-call check.

### How it works

1. A background thread watches `app/`, `config/`, `db/`, `lib/`, `rakelib/`, `test/` and `spec/` (plus the app directories of packs, in-repo engines and `extra_app_paths`) for changes
2. On change (debounced 1.5s), it checks the file fingerprint to avoid false positives
3. If files truly changed, it:
   - Clears all MCP tool caches
   - Sends `notifications/resources/list_changed` to the AI client
   - Logs a summary of what changed (e.g., "Files changed: 2 models, 1 controller.")

### Setup

Add the `listen` gem (you may already have it from Watch Mode):

```ruby
# Gemfile
gem "listen", group: :development
```

Live reload is **enabled by default** when the `listen` gem is available. No configuration needed.

### Configuration

```ruby
if defined?(RailsAiContext) && RailsAiContext.respond_to?(:configure)
  RailsAiContext.configure do |config|
    # :auto (default) - enable if `listen` gem is available, otherwise skip with one line on stderr
    # true  - enable, raise if `listen` gem is missing
    # false - disable entirely
    config.live_reload = :auto

    # Debounce interval in seconds (default: 1.5)
    config.live_reload_debounce = 1.5
  end
end
```

### Difference from Watch Mode

| | Watch Mode (`rails ai:watch`) | Live Reload (`rails ai:serve`) |
|---|---|---|
| **Trigger** | File changes | File changes |
| **Action** | Regenerates static context files (CLAUDE.md, etc.) | Invalidates MCP tool caches + notifies AI client |
| **Use case** | Keep committed files up to date | Keep live MCP sessions fresh |
| **Transport** | N/A (writes to disk) | stdio and HTTP |

---

## Works Without a Database

The gem gracefully degrades when no database is connected. The schema introspector parses `db/schema.rb` as text instead of querying `information_schema`.

Works in:
- CI/CD pipelines
- Claude Code sessions (no DB running)
- Docker build stages
- Read-only environments
- Any environment with source code but no running database

---

## Security

- All MCP tools are **read-only** - they never modify your application or database
- Code search uses `Open3.capture3` with array arguments - **no shell injection**
- File paths are validated against **path traversal** attacks
- Credentials and secret values are **never exposed** - only key names are introspected
- The gem makes **no outbound network requests**
- File type validation prevents arbitrary file access in code search
- Search output is capped at `max_search_results` lines (default 200) to prevent resource exhaustion

---

## Troubleshooting

### MCP server not detected by your AI tool

1. Run `rails ai:doctor` - it checks per-tool MCP config files
2. Verify the correct config file exists for your tool (`.mcp.json`, `.cursor/mcp.json`, `.vscode/mcp.json`, `opencode.json`, `.codex/config.toml`) in the folder the tool opened: the app, or the folder of apps `init` set up
3. Re-run install (`rails generate rails_ai_context:install` or `rails-ai-context init`) to regenerate configs
4. Restart your AI tool

### Context files are too large

```ruby
# Switch to compact mode (default in v0.7+)
config.context_mode = :compact
```

### MCP tool responses are too large

```ruby
# Lower the safety cap
config.max_tool_response_chars = 60_000
```

### Schema not detected

- Ensure `db/schema.rb` exists (run `rails db:schema:dump` if needed)
- The gem works without a database - it parses schema.rb as text

### Models not detected

- Models must descend from `ActiveRecord::Base`, through `ApplicationRecord` or any other base class. Without a boot they must also sit in a model directory (`app/models/`, or a pack's or engine's)
- Excluded models: `ApplicationRecord`, `ActiveStorage::*`, `ActionText::*`, `ActionMailbox::*`
- Add custom exclusions: `config.excluded_models += %w[InternalModel]`

### Ripgrep not found

Code search falls back to Ruby's `Dir.glob` + `File.read`. Install ripgrep for faster search:

```bash
# macOS
brew install ripgrep

# Ubuntu/Debian
sudo apt install ripgrep
```

### Watch mode not working

```bash
# Install listen gem
bundle add listen --group development

# Then run
rails ai:watch
```

### Tool responses show "not available"

The tool's introspector isn't in the active preset. Either:

```ruby
# Use full preset
config.preset = :full

# Or add the specific introspector
config.introspectors += %i[config]  # for rails_get_config
config.introspectors += %i[tests]   # for rails_get_test_info
```
