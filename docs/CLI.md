<div align="center" markdown="1">

# CLI Reference

**All commands available from the terminal.**

[Quickstart](QUICKSTART.md) · [Tools Reference](TOOLS.md) · [Standalone](STANDALONE.md) · [Configuration](CONFIGURATION.md)

</div>

---

## Two CLI interfaces

| Context | Command prefix | Example |
|:--------|:---------------|:--------|
| In-Gemfile (Rake) | `rails ai:` | `rails 'ai:tool[schema]' table=users` |
| Standalone (Thor) | `rails-ai-context` | `rails-ai-context tool schema --table users` |

Both provide the same 38 tools and functionality.

---

## Commands

### `serve`

Start the MCP server.

```bash
rails ai:serve                                        # stdio (default)
rails-ai-context serve                                # stdio (default)
rails-ai-context serve --transport http --port 6029   # HTTP transport
```

| Option | Default | Description |
|:-------|:--------|:------------|
| `--transport` | `stdio` | `stdio` or `http` |
| `--port` | `6029` | HTTP listen port |

### `tool`

Run any of the 38 MCP tools from the terminal.

```bash
# Rake syntax
rails 'ai:tool[schema]' table=users detail=full
rails 'ai:tool[search_code]' pattern="can_cook?" match_type=trace
rails 'ai:tool[model_details]' model=User

# Thor syntax
rails-ai-context tool schema --table users --detail full
rails-ai-context tool search_code --pattern "can_cook?" --match-type trace
rails-ai-context tool model_details --model User
```

| Option | Description |
|:-------|:------------|
| `--list` | List all available tools |
| `--json` | Output as JSON |

### Tool name resolution

All of these resolve to the same tool:

```bash
rails 'ai:tool[schema]'
rails 'ai:tool[get_schema]'
rails 'ai:tool[rails_get_schema]'
```

Resolution order: exact match → `rails_` prefix → `rails_get_` prefix → `get_` prefix.

### `context`

Generate static context files.

```bash
rails ai:context              # All configured formats
rails ai:context:claude       # Claude only
rails ai:context:cursor       # Cursor only
rails ai:context:copilot      # Copilot only
rails ai:context:opencode     # OpenCode only
rails ai:context:json         # JSON export

rails-ai-context context                # All
rails-ai-context context --format claude # Specific format
```

| Option | Default | Description |
|:-------|:--------|:------------|
| `--format` | all configured | `claude`, `cursor`, `copilot`, `opencode`, `codex`, `json`, `all` |

### `doctor`

Run 23 diagnostic checks and report AI readiness score.

```bash
rails ai:doctor
rails-ai-context doctor
```

Checks include: schema existence, pending migrations, model files, routes, MCP config validity, introspector health, ripgrep availability, Prism gem, Brakeman gem, listen gem, gitignore security, auto_mount security, schema size, view count, and more.

### `watch`

Watch for file changes and auto-regenerate context files.

```bash
rails ai:watch
rails-ai-context watch
```

Requires the `listen` gem. Watches `app/`, `config/`, `db/`, `lib/tasks/`.

### `init` (standalone only)

Interactive setup for standalone mode.

```bash
rails-ai-context init
```

Asks which AI tools to configure and whether to use MCP or CLI mode. Creates `.rails-ai-context.yml` and MCP config files.

### `version`

```bash
rails-ai-context version
```

### `inspect`

Print introspection summary as JSON.

```bash
rails-ai-context inspect
```

---

## Rake tasks (in-Gemfile only)

| Task | Description |
|:-----|:------------|
| `rails ai:context` | Generate context for all configured formats |
| `rails ai:context:claude` | Generate Claude context |
| `rails ai:context:cursor` | Generate Cursor context |
| `rails ai:context:copilot` | Generate Copilot context |
| `rails ai:context:opencode` | Generate OpenCode context |
| `rails ai:context:json` | Generate JSON export |
| `rails ai:serve` | Start MCP server (stdio) |
| `rails ai:tool` | List tools or run a tool |
| `rails ai:doctor` | Run diagnostics |
| `rails ai:watch` | Watch mode |
| `rails ai:setup` | Interactive setup (alternative to generator) |

---

## Tool argument syntax

### Rake format

```bash
rails 'ai:tool[tool_name]' key=value key2=value2
```

- Strings: `table=users`
- Booleans: `explain=true` or `explain=false`
- Enums: `detail=full`
- Spaces: `pattern="has_many :posts"`

### Thor format

```bash
rails-ai-context tool tool_name --key value --key2 value2
```

- Strings: `--table users` or `--table=users`
- Booleans: `--explain` (true) or `--no-explain` (false)
- Enums: `--detail full`
- Spaces: `--pattern "has_many :posts"`

### JSON output

Add `--json` for machine-readable output:

```bash
rails-ai-context tool schema --table users --json
```

---

## Common workflows

### Quick schema check

```bash
rails 'ai:tool[schema]' table=users
```

### Trace a method

```bash
rails 'ai:tool[search_code]' pattern="process_payment" match_type=trace
```

### Full feature analysis

```bash
rails 'ai:tool[analyze_feature]' feature=billing
```

### Check AI readiness

```bash
rails ai:doctor
```

### Regenerate after changes

```bash
rails ai:context
```

---

<div align="center" markdown="1">

**[← Security](SECURITY.md)** · **[Standalone Mode →](STANDALONE.md)**

[Back to Home](index.md)

</div>
