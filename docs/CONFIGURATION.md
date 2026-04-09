<div align="center" markdown="1">

# Configuration

**Every option, every default, every validation rule.**

[Quickstart](QUICKSTART.md) · [Custom Tools](CUSTOM_TOOLS.md) · [AI Tool Setup](SETUP.md) · [FAQ](FAQ.md)

</div>

---

## Configuration methods

### Ruby initializer (recommended for in-Gemfile)

```ruby
# config/initializers/rails_ai_context.rb
if defined?(RailsAiContext)
  RailsAiContext.configure do |config|
    config.ai_tools  = %i[claude cursor copilot opencode codex]
    config.tool_mode = :mcp
    config.preset    = :full
  end
end
```

### YAML config (recommended for standalone)

```yaml
# .rails-ai-context.yml
ai_tools:
  - claude
  - cursor
tool_mode: mcp
preset: full
```

### Precedence

> [!IMPORTANT]
> Initializer > YAML > Defaults. If the initializer runs, YAML is skipped entirely. Corrupted YAML degrades gracefully with a warning.

---

## All options

### AI Tools & Mode

| Option | Type | Default | Description |
|:-------|:-----|:--------|:------------|
| `ai_tools` | Array of symbols | `[:claude]` | Which AI tools to generate context for. Options: `:claude`, `:cursor`, `:copilot`, `:opencode`, `:codex` |
| `tool_mode` | Symbol | `:mcp` | `:mcp` (MCP server primary, CLI fallback) or `:cli` (CLI only, no MCP server) |

### Introspection

| Option | Type | Default | Description |
|:-------|:-----|:--------|:------------|
| `preset` | Symbol | `:full` | `:full` (31 introspectors) or `:standard` (17 introspectors) |
| `context_mode` | Symbol | `:compact` | `:compact` (context files capped at ~150 lines) or `:full` (no line cap) |
| `introspectors` | Array of symbols | (from preset) | Override the introspector list directly |
| `generate_root_files` | Boolean | `true` | Set `false` to generate split rules only, no root CLAUDE.md/AGENTS.md |
| `anti_hallucination_rules` | Boolean | `true` | Embed 6-rule verification protocol in generated context files |
| `claude_max_lines` | Integer | `150` | Max lines for compact context files |

### MCP Server

| Option | Type | Default | Validation | Description |
|:-------|:-----|:--------|:-----------|:------------|
| `server_name` | String | `"rails-ai-context"` | — | MCP server name |
| `cache_ttl` | Integer | `60` | Must be positive | Cache time-to-live in seconds |
| `max_tool_response_chars` | Integer | `200_000` | Must be positive | Safety cap for tool response length |
| `live_reload` | Symbol/Boolean | `:auto` | — | `:auto` (uses `listen` gem if available), `true`, or `false` |
| `live_reload_debounce` | Float | `1.5` | — | Seconds to wait before processing file changes |
| `auto_mount` | Boolean | `false` | — | Auto-mount Rack middleware for HTTP transport |
| `http_path` | String | `"/mcp"` | — | HTTP endpoint path |
| `http_bind` | String | `"127.0.0.1"` | — | HTTP bind address |
| `http_port` | Integer | `6029` | 1–65535 | HTTP listen port |

### Cross-Tool Hydration

| Option | Type | Default | Description |
|:-------|:-----|:--------|:------------|
| `hydration_enabled` | Boolean | `true` | Auto-inject schema hints into controller/view tool responses |
| `hydration_max_hints` | Integer | `5` | Maximum schema hints per tool response |

### Filtering

| Option | Type | Default | Description |
|:-------|:-----|:--------|:------------|
| `excluded_models` | Array | 8 framework models | Models to skip during introspection |
| `excluded_controllers` | Array | 2 framework controllers | Controllers to skip |
| `excluded_route_prefixes` | Array | 6 framework prefixes | Route prefixes to skip |
| `excluded_filters` | Array | 3 framework filters | Controller filters to skip |
| `excluded_middleware` | Array | 24 framework middleware | Middleware to skip in listing |
| `excluded_paths` | Array | `["node_modules", "tmp", "log", "vendor", ".git", "doc", "docs"]` | Paths excluded from search |
| `excluded_association_names` | Array | 7 framework associations | Association names to hide from model output |
| `excluded_concerns` | Array of Regex | Framework concerns | Concerns to skip (supports regex) |

### File Size Limits

| Option | Type | Default | Description |
|:-------|:-----|:--------|:------------|
| `max_file_size` | Integer | `5_000_000` (5 MB) | General file read limit |
| `max_test_file_size` | Integer | `1_000_000` (1 MB) | Test file read limit |
| `max_schema_file_size` | Integer | `10_000_000` (10 MB) | Schema file read limit |
| `max_view_total_size` | Integer | `10_000_000` (10 MB) | Total view file size limit |
| `max_view_file_size` | Integer | `1_000_000` (1 MB) | Single view file limit |

### Search

| Option | Type | Default | Description |
|:-------|:-----|:--------|:------------|
| `max_search_results` | Integer | `200` | Maximum search results |
| `max_validate_files` | Integer | `50` | Maximum files for validation |
| `search_extensions` | Array | `["rb", "js", "erb", "yml", "yaml", "json", "ts", "tsx", "vue", "svelte", "haml", "slim"]` | File extensions to search |
| `concern_paths` | Array | `["app/models/concerns", "app/controllers/concerns"]` | Paths to scan for concerns |
| `frontend_paths` | Array | `nil` (auto-detect) | Override frontend file paths |

### Database Query Safety

| Option | Type | Default | Validation | Description |
|:-------|:-----|:--------|:-----------|:------------|
| `query_timeout` | Integer | `5` | — | SQL query timeout in seconds |
| `query_row_limit` | Integer | `100` | 1–1000 | Maximum rows returned |
| `query_redacted_columns` | Array | 10+ patterns | — | Column names/suffixes to redact |
| `allow_query_in_production` | Boolean | `false` | — | Allow `rails_query` tool in production |

### Logs

| Option | Type | Default | Description |
|:-------|:-----|:--------|:------------|
| `log_lines` | Integer | `50` | Default log lines to return |

### Security

| Option | Type | Default | Description |
|:-------|:-----|:--------|:------------|
| `sensitive_patterns` | Array | 8 patterns | File patterns blocked from search/read (`.env*`, `*.key`, `*.pem`, `credentials.yml.enc`, etc.) |

### Extensibility

| Option | Type | Default | Description |
|:-------|:-----|:--------|:------------|
| `custom_tools` | Array | `[]` | Additional MCP::Tool classes to register |
| `skip_tools` | Array | `[]` | Built-in tool names to exclude (e.g., `%w[rails_security_scan]`) |

### Output

| Option | Type | Default | Description |
|:-------|:-----|:--------|:------------|
| `output_dir` | String | Rails.root | Directory for generated context files |

---

## Presets

### `:full` (default) — 31 introspectors

All available introspectors. Best for comprehensive context.

### `:standard` — 17 introspectors

Lightweight subset for faster generation:

`schema`, `models`, `routes`, `jobs`, `gems`, `conventions`, `controllers`, `tests`, `migrations`, `stimulus`, `view_templates`, `config`, `components`, `turbo`, `auth`, `performance`, `i18n`

---

## Generated files by AI tool

| AI Tool | Root File | Split Rules | MCP Config |
|:--------|:----------|:------------|:-----------|
| Claude Code | `CLAUDE.md` | `.claude/rules/*.md` | `.mcp.json` |
| Cursor | — | `.cursor/rules/*.mdc` | `.cursor/mcp.json` |
| GitHub Copilot | `.github/copilot-instructions.md` | `.github/instructions/*.instructions.md` | `.vscode/mcp.json` |
| OpenCode | `AGENTS.md` | `app/*/AGENTS.md` | `opencode.json` |
| Codex CLI | (shares `AGENTS.md`) | (shares OpenCode rules) | `.codex/config.toml` |

---

## Examples

### Minimal config

```ruby
RailsAiContext.configure do |config|
  config.ai_tools = %i[claude]
end
```

### Full config

```ruby
RailsAiContext.configure do |config|
  # AI tools
  config.ai_tools  = %i[claude cursor copilot opencode codex]
  config.tool_mode = :mcp

  # Introspection
  config.preset       = :full
  config.context_mode = :compact

  # MCP Server
  config.cache_ttl              = 120
  config.max_tool_response_chars = 300_000
  config.live_reload            = true
  config.http_port              = 6029

  # Hydration
  config.hydration_enabled   = true
  config.hydration_max_hints = 5

  # Query safety
  config.query_timeout  = 10
  config.query_row_limit = 200
  config.allow_query_in_production = false

  # Extensibility
  config.custom_tools = [MyCustomTool]
  config.skip_tools   = %w[rails_security_scan]

  # Filtering
  config.excluded_models = %w[ApplicationRecord SolidQueue::Job]
end
```

---

<div align="center" markdown="1">

**[← Custom Tools](CUSTOM_TOOLS.md)** · **[AI Tool Setup →](SETUP.md)**

[Back to Home](index.md)

</div>
