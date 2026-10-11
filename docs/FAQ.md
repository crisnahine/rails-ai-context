<div align="center" markdown="1">

# FAQ

**Frequently asked questions about rails-ai-context.**

[Quickstart](QUICKSTART.md) · [Recipes](RECIPES.md) · [Troubleshooting](TROUBLESHOOTING.md) · [Configuration](CONFIGURATION.md)

</div>

---

## General

### What does this gem do?

It gives AI coding assistants verified, real-time access to your Rails app's structure - schema, models, routes, controllers, views, conventions, and more. Instead of guessing from training data, AI queries your actual app.

### Which AI tools are supported?

Claude Code, Cursor, GitHub Copilot, OpenCode, and Codex CLI. Each gets tailored context files and MCP auto-discovery config.

### Do I need MCP support in my AI tool?

No. The gem works three ways:
1. **MCP server** - AI calls tools via the protocol (best experience)
2. **Static files** - Generated context files (CLAUDE.md, .cursor/rules/, etc.)
3. **CLI** - Same 45 tools from the terminal, no server needed

### Is this safe for production?

The gem is designed for development environments. All tools are read-only. The query tool is disabled in production by default. Sensitive files (.env, *.key, credentials) are blocked.

### Does it work without a database?

Yes. The gem gracefully degrades - it parses `db/schema.rb` as text when no database connection is available.

---

## Installation

### Gemfile or standalone - which should I use?

**In-Gemfile** is recommended if you own the project. Gives you the install generator, rake tasks, and initializer config.

**Standalone** is for when you can't modify the Gemfile (client projects, quick exploration, CI).

### Can I switch between Gemfile and standalone?

Yes, freely. Both write the same context files and serve the same 45 tools; only the commands those files name follow the install (`rails ai:context` and `rails 'ai:tool[...]'` in the Gemfile, `rails-ai-context context` and `rails-ai-context tool ...` standalone). Re-run the install or `init` after switching: it updates the MCP config files and regenerates the context files with the new commands.

### My editor opens a folder that holds several apps. Does that work?

Yes. Run `rails-ai-context init` in that folder. It asks once, gives each app its own `.rails-ai-context.yml` and context files, and writes one MCP server per app into the folder's configs, `rails-ai-context-<app folder>`, so your AI tool sees every app and each app's tools are named after it. Start the tool in that folder: the entries name each app relative to it. See [`init`](CLI.md#init-standalone-only).

### Do I need to commit the generated files?

**Yes, commit these:**
- `.mcp.json`, `.cursor/mcp.json`, `.vscode/mcp.json`, `opencode.json` - so teammates get MCP auto-discovery
- `CLAUDE.md`, `.claude/rules/`, `.cursor/rules/`, `.cursorrules`, `.github/copilot-instructions.md`, `.github/instructions/`, `AGENTS.md` - so AI has context
- `config/initializers/rails_ai_context.rb`, `.rails-ai-context.yml` - so config is shared

**Don't commit:**
- `.ai-context.json` - auto-added to .gitignore by the install generator
- `.codex/config.toml` - it embeds this machine's Ruby PATH and GEM_HOME, so install adds it to .gitignore too and `rails ai:doctor` fails when it is not ignored

### Can I use only the MCP server?

Yes:

```bash
rails generate rails_ai_context:install --mcp-only   # or: rails-ai-context init --mcp-only
```

The MCP config is written, `config.context_files = false` is recorded, and no
`CLAUDE.md`, `AGENTS.md`, rules file or `.ai-context.json` is written or
touched. Every tool still answers over MCP and over the CLI. See
[CONFIGURATION.md](CONFIGURATION.md#mcp-only).

---

## MCP & Tools

### How do I know which tool to use?

Start with `rails_onboard` for an app overview, `rails_analyze_feature` for feature work, and `rails_search_code` with `match_type: "trace"` for code investigation. Your AI will learn to pick the right tools.

### Can I add my own tools?

Yes. See [Custom Tools](CUSTOM_TOOLS.md). Create an `MCP::Tool` subclass, register it via `config.custom_tools`, and it appears alongside the 45 built-in tools, in the generated context files' tool counts and lists too.

### Can I remove built-in tools?

Yes. Use `config.skip_tools`:

```ruby
config.skip_tools = %w[rails_security_scan rails_query]
```

The server, the CLI and the generated context files then leave them out alike, so no context file tells the AI to call a tool that answers "Unknown tool".

### What's the `detail` parameter?

Individual lookup tools accept `detail`: `summary` (compact), `standard` (default), `full` (everything). Start with summary and drill down as needed. This keeps AI context windows lean. Composite tools (`rails_get_context`, `rails_analyze_feature`) do not accept `detail` - they always return their full bundled output.

### What are `[VERIFIED]` and `[INFERRED]` tags?

Confidence tags from Prism AST parsing:
- **`[VERIFIED]`** - all arguments are static literals. This is ground truth.
- **`[INFERRED]`** - arguments contain dynamic expressions. Needs runtime verification.

### Does the query tool support all databases?

PostgreSQL, MySQL, and SQLite. Each gets database-specific safety mechanisms (read-only transactions, timeouts). See [Security](SECURITY.md).

---

## Configuration

### What's the difference between `:full` and `:standard` preset?

- **`:full`** (default) - 40 introspectors. Full context for every aspect of your app.
- **`:standard`** - 17 introspectors. Faster, covers the essentials (schema, models, routes, controllers, tests, etc.).

### What's `:compact` vs `:full` context mode?

- **`:compact`** (default) - context files capped at ~150 lines. Optimized for AI context windows.
- **`:full`** - no line cap. All introspection data included.

### Can I use YAML config with the Gemfile approach?

Yes. The file is applied first and a `configure` block wins only the keys it assigns, so a key the initializer never touches keeps the YAML value. See [Precedence](CONFIGURATION.md#precedence).

### What's `generate_root_files`?

When `true` (default), generates the root files: CLAUDE.md, AGENTS.md, .cursorrules and copilot-instructions.md. Set to `false` to only generate split rules (.claude/rules/, .cursor/rules/, etc.). `.ai-context.json` is written either way.

---

## Context Files

### What files get generated?

Depends on your `ai_tools` config. For all tools:

| AI Tool | Files |
|:--------|:------|
| Claude | CLAUDE.md, .claude/rules/*.md |
| Cursor | .cursor/rules/*.mdc AND .cursorrules (legacy fallback for chat agent) |
| Copilot | .github/copilot-instructions.md, .github/instructions/*.instructions.md |
| OpenCode | AGENTS.md, app/models/AGENTS.md, app/controllers/AGENTS.md |
| Codex | Shares AGENTS.md and OpenCode rules |

### How do I regenerate context files?

```bash
rails ai:context          # All formats
rails ai:context:claude   # Claude only
```

### Do context files update automatically?

Only if you run watch mode:

```bash
rails ai:watch
```

Otherwise, regenerate manually after significant changes.

### Can I add my own content to CLAUDE.md?

Yes. Add content outside the `<!-- BEGIN/END rails-ai-context -->` markers. The gem preserves content outside these markers during regeneration.

---

## Performance

### Is introspection slow?

Introspection results are cached with TTL (default: 60s) and fingerprint invalidation. The first call is slower; subsequent calls use cache until a watched file changes. Prism AST parsing uses a single-pass Dispatcher - all 8 listeners run in one tree walk.

### Does this affect my app's performance?

No, as long as the gem sits in the Gemfile's `:development` group, where `bundle add rails-ai-context --group development` puts it: Bundler then never loads it in production. Where the gem is loaded in production, it refuses two things there by default: `rails_query`, and MCP over HTTP from inside the app (the mounted engine and `auto_mount`). Tools execute on demand (not continuously). The MCP server is a separate process (stdio), or an HTTP endpoint that exists only when you mount it or set `auto_mount`.

### How does live reload work?

The `listen` gem watches `app/`, `config/`, `db/`, `lib/`, `rakelib/`, `test/`, `spec/`. When files change, caches are invalidated, MCP clients are notified, and the next tool call reloads the app's code before it answers; the watching thread loads none of it. Debounce interval: 1.5s (configurable).

Without `listen` (a new Rails 8 app does not bundle it), answers still follow edits: each tool call first checks those files and, when one changed, does the same reload and invalidation. The check costs a few milliseconds on a typical app and about 100 ms at 10,000 files, where calls close together share one check. With `listen` there is no per-call check, and clients are told when files change.

---

## Security

### Can tools modify my database?

No. The query tool uses `SET TRANSACTION READ ONLY` + rollback on PostgreSQL and MySQL, and a read-only connection on SQLite. Even if SQL validation were bypassed, the database layer prevents writes.

### Can tools read my .env or credentials?

No. Sensitive files (`.env*`, `*.key`, `*.pem`, `credentials.yml.enc`) are blocked by default. The pattern list is configurable.

### Is the Anti-Hallucination Protocol necessary?

It's enabled by default and targets real AI failure modes. If you prefer your own prompting rules, disable it:

```ruby
config.anti_hallucination_rules = false
```

---

## How does this compare to...

### ...a hand-written CLAUDE.md?

A manual CLAUDE.md goes stale the moment someone adds a column or changes a route. rails-ai-context reads your app live - schema, models, routes, controllers are always current. You can still add your own rules alongside the generated content. See [Recipes: Migrating](RECIPES.md#migrating-from-manual-ai-context).

### ...cursor-rules repos / awesome-cursorrules?

Community cursor rules are generic Rails patterns. rails-ai-context generates rules from *your* app - your actual schema, your associations, your conventions. Generic rules say "Rails uses `before_action`"; this gem tells AI which specific filters your `ApplicationController` applies.

### ...pasting schema.rb into the prompt?

Pasting works once, then goes stale. It also burns context window on tables AI doesn't need. The `get_schema` tool returns only the requested table, on demand, always current.

### ...Copilot Workspace / Cursor Composer / Windsurf?

Those are AI coding interfaces. This gem is a data layer that makes *any* of them better. It provides the ground truth they're missing. Works with Claude Code, Cursor, Copilot, OpenCode, and Codex simultaneously.

---

## Troubleshooting

### My AI tool doesn't see the MCP server

Run `rails ai:doctor` - it checks each configured tool's MCP config file, and whether the command it holds can start. See [Troubleshooting](TROUBLESHOOTING.md) for detailed steps.

### Tools return empty results

Check that your Rails app boots (`rails runner "puts 'ok'"`) and that schema/models exist. Run `rails ai:doctor`.

### Context files are too large

Use compact mode (default) or disable root files:

```ruby
config.context_mode = :compact
config.generate_root_files = false
```

---

<div align="center" markdown="1">

**[← Troubleshooting](TROUBLESHOOTING.md)** · **[Full Guide →](GUIDE.md)**

[Back to Home](index.md)

</div>
