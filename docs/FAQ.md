<div align="center">

# FAQ

**Frequently asked questions about rails-ai-context.**

[Quickstart](QUICKSTART.md) · [Recipes](RECIPES.md) · [Troubleshooting](TROUBLESHOOTING.md) · [Configuration](CONFIGURATION.md)

</div>

---

## General

### What does this gem do?

It gives AI coding assistants verified, real-time access to your Rails app's structure — schema, models, routes, controllers, views, conventions, and more. Instead of guessing from training data, AI queries your actual app.

### Which AI tools are supported?

Claude Code, Cursor, GitHub Copilot, OpenCode, and Codex CLI. Each gets tailored context files and MCP auto-discovery config.

### Do I need MCP support in my AI tool?

No. The gem works three ways:
1. **MCP server** — AI calls tools via the protocol (best experience)
2. **Static files** — Generated context files (CLAUDE.md, .cursor/rules/, etc.)
3. **CLI** — Same 38 tools from the terminal, no server needed

### Is this safe for production?

The gem is designed for development environments. All tools are read-only. The query tool is disabled in production by default. Sensitive files (.env, *.key, credentials) are blocked.

### Does it work without a database?

Yes. The gem gracefully degrades — it parses `db/schema.rb` as text when no database connection is available.

---

## Installation

### Gemfile or standalone — which should I use?

**In-Gemfile** is recommended if you own the project. Gives you the install generator, rake tasks, and initializer config.

**Standalone** is for when you can't modify the Gemfile (client projects, quick exploration, CI).

### Can I switch between Gemfile and standalone?

Yes, freely. Both generate identical context files and provide the same 38 tools. Just re-run the install/init to update MCP config files.

### Do I need to commit the generated files?

**Yes, commit these:**
- `.mcp.json`, `.cursor/mcp.json`, `.vscode/mcp.json`, `opencode.json`, `.codex/config.toml` — so teammates get MCP auto-discovery
- `CLAUDE.md`, `.cursor/rules/`, `.github/instructions/`, `AGENTS.md` — so AI has context
- `config/initializers/rails_ai_context.rb`, `.rails-ai-context.yml` — so config is shared

**Don't commit:**
- `.ai-context.json` — auto-added to .gitignore by the install generator

---

## MCP & Tools

### How do I know which tool to use?

Start with `rails_onboard` for an app overview, `rails_analyze_feature` for feature work, and `rails_search_code` with `match_type: "trace"` for code investigation. Your AI will learn to pick the right tools.

### Can I add my own tools?

Yes. See [Custom Tools](CUSTOM_TOOLS.md). Create an `MCP::Tool` subclass, register it via `config.custom_tools`, and it appears alongside the 38 built-in tools.

### Can I remove built-in tools?

Yes. Use `config.skip_tools`:

```ruby
config.skip_tools = %w[rails_security_scan rails_query]
```

### What's the `detail` parameter?

Most tools accept `detail`: `summary` (compact), `standard` (default), `full` (everything). Start with summary and drill down as needed. This keeps AI context windows lean.

### What are `[VERIFIED]` and `[INFERRED]` tags?

Confidence tags from Prism AST parsing:
- **`[VERIFIED]`** — all arguments are static literals. This is ground truth.
- **`[INFERRED]`** — arguments contain dynamic expressions. Needs runtime verification.

### Does the query tool support all databases?

PostgreSQL, MySQL, and SQLite. Each gets database-specific safety mechanisms (read-only transactions, timeouts). See [Security](SECURITY.md).

---

## Configuration

### What's the difference between `:full` and `:standard` preset?

- **`:full`** (default) — 31 introspectors. Comprehensive context for every aspect of your app.
- **`:standard`** — 17 introspectors. Faster, covers the essentials (schema, models, routes, controllers, tests, etc.).

### What's `:compact` vs `:full` context mode?

- **`:compact`** (default) — context files capped at ~150 lines. Optimized for AI context windows.
- **`:full`** — no line cap. All introspection data included.

### Can I use YAML config with the Gemfile approach?

Yes, but the initializer takes priority. If `config/initializers/rails_ai_context.rb` exists and runs, `.rails-ai-context.yml` is skipped.

### What's `generate_root_files`?

When `true` (default), generates root files like CLAUDE.md, AGENTS.md. Set to `false` to only generate split rules (.claude/rules/, .cursor/rules/, etc.).

---

## Context Files

### What files get generated?

Depends on your `ai_tools` config. For all tools:

| AI Tool | Files |
|:--------|:------|
| Claude | CLAUDE.md, .claude/rules/*.md |
| Cursor | .cursor/rules/*.mdc |
| Copilot | .github/copilot-instructions.md, .github/instructions/*.instructions.md |
| OpenCode | AGENTS.md, app/*/AGENTS.md |
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

Introspection results are cached with TTL (default: 60s) and fingerprint invalidation. The first call is slower; subsequent calls use cache. Prism AST parsing uses a single-pass Dispatcher — all 7 listeners run in one tree walk.

### Does this affect my app's performance?

No. The gem only runs in development. Tools execute on demand (not continuously). The MCP server is a separate process (stdio) or a development-only endpoint (HTTP).

### How does live reload work?

The `listen` gem watches `app/`, `config/`, `db/`, `lib/tasks/`. When files change, caches are invalidated and MCP clients are notified. Debounce interval: 1.5s (configurable).

---

## Security

### Can tools modify my database?

No. The query tool uses `SET TRANSACTION READ ONLY` + rollback. Even if SQL validation were bypassed, the database layer prevents writes.

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

A manual CLAUDE.md goes stale the moment someone adds a column or changes a route. rails-ai-context reads your app live — schema, models, routes, controllers are always current. You can still add your own rules alongside the generated content. See [Recipes: Migrating](RECIPES.md#migrating-from-manual-ai-context).

### ...cursor-rules repos / awesome-cursorrules?

Community cursor rules are generic Rails patterns. rails-ai-context generates rules from *your* app — your actual schema, your associations, your conventions. Generic rules say "Rails uses `before_action`"; this gem tells AI which specific filters your `ApplicationController` applies.

### ...pasting schema.rb into the prompt?

Pasting works once, then goes stale. It also burns context window on tables AI doesn't need. The `get_schema` tool returns only the requested table, on demand, always current.

### ...Copilot Workspace / Cursor Composer / Windsurf?

Those are AI coding interfaces. This gem is a data layer that makes *any* of them better. It provides the ground truth they're missing. Works with Claude Code, Cursor, Copilot, OpenCode, and Codex simultaneously.

---

## Troubleshooting

### My AI tool doesn't see the MCP server

Run `rails ai:doctor` — it checks MCP config files for all configured tools. See [Troubleshooting](TROUBLESHOOTING.md) for detailed steps.

### Tools return empty results

Check that your Rails app boots (`rails runner "puts 'ok'"`) and that schema/models exist. Run `rails ai:doctor`.

### Context files are too large

Use compact mode (default) or disable root files:

```ruby
config.context_mode = :compact
config.generate_root_files = false
```

---

<div align="center">

**[← Troubleshooting](TROUBLESHOOTING.md)** · **[Full Guide →](GUIDE.md)**

[Back to README](../README.md)

</div>
