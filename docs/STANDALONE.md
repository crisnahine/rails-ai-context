<div align="center" markdown="1">

# Standalone Mode

**Use rails-ai-context without adding it to your Gemfile.**

[Quickstart](QUICKSTART.md) · [CLI Reference](CLI.md) · [Configuration](CONFIGURATION.md) · [Troubleshooting](TROUBLESHOOTING.md)

</div>

---

## Install

```bash
gem install rails-ai-context
```

## Setup

```bash
cd your-rails-app
rails-ai-context init
```

Interactive setup asks:
1. Which AI tools? (Claude, Cursor, Copilot, OpenCode, Codex, or all)
2. MCP or CLI mode?

Creates:
- `.rails-ai-context.yml` — YAML configuration
- MCP config files for selected AI tools
- Context files for selected AI tools

## Usage

```bash
rails-ai-context serve              # Start MCP server (stdio)
rails-ai-context serve --transport http --port 6029  # HTTP transport
rails-ai-context tool schema --table users           # Run a tool
rails-ai-context tool --list        # List all tools
rails-ai-context context            # Generate context files
rails-ai-context doctor             # Run diagnostics
rails-ai-context watch              # Auto-regenerate on changes
rails-ai-context version            # Show version
```

## How standalone mode works

1. **Pre-loads the gem** before Rails boots — the CLI loads `rails-ai-context` before `Bundler.setup`
2. **Restores `$LOAD_PATH`** entries that `Bundler.setup` strips (since the gem isn't in the Gemfile)
3. **YAML config** — uses `.rails-ai-context.yml` instead of a Ruby initializer

This means you get the same 38 tools, same MCP server, same context generation — without touching the project's Gemfile.

## Configuration via YAML

```yaml
# .rails-ai-context.yml
ai_tools:
  - claude
  - cursor
tool_mode: mcp
preset: full
context_mode: compact

# MCP Server
cache_ttl: 60
max_tool_response_chars: 200000
http_port: 6029

# Query safety
query_timeout: 5
query_row_limit: 100
allow_query_in_production: false

# Filtering
excluded_models:
  - ApplicationRecord
excluded_association_names:
  - active_storage_attachments
  - active_storage_blobs
excluded_paths:
  - node_modules
  - tmp
  - log

# Skip tools
skip_tools:
  - rails_security_scan
```

### YAML limitations

Two config options are Ruby-only and can't be set via YAML:

- `custom_tools` — requires Ruby class references
- `excluded_concerns` — requires Regex objects

For these, use the initializer approach (in-Gemfile mode).

### Precedence

If both exist, the initializer takes priority over YAML:

1. `config/initializers/rails_ai_context.rb` (highest)
2. `.rails-ai-context.yml`
3. Defaults

## Ruby version manager compatibility

Standalone mode works with all Ruby version managers:

| Manager | Supported |
|:--------|:----------|
| rbenv | Yes |
| rvm | Yes |
| asdf | Yes |
| mise | Yes |
| chruby | Yes |
| System Ruby | Yes |

### Codex CLI env snapshot

Codex CLI is special — it `env_clear()`s the process before spawning MCP servers. The install generator snapshots your Ruby environment variables (PATH, GEM_HOME, GEM_PATH, GEM_ROOT, RUBY_VERSION, BUNDLE_PATH) into `.codex/config.toml` so Codex can find Ruby and gems.

If you switch Ruby versions, re-run `rails-ai-context init` to update the snapshot.

## Switching between standalone and in-Gemfile

You can switch freely:

```bash
# To switch to in-Gemfile:
bundle add rails-ai-context --group development
rails generate rails_ai_context:install

# To switch to standalone:
bundle remove rails-ai-context
rails-ai-context init
```

The MCP config files are updated automatically. Both modes generate identical context files and provide the same 38 tools.

## Troubleshooting

### "Bundler::GemNotFound" on `rails-ai-context serve`

The gem's `$LOAD_PATH` restoration may have failed. Check:

```bash
gem list rails-ai-context    # Is it installed?
ruby -v                       # Right Ruby version?
```

### "YAML config not loading"

Check that no initializer exists — if `config/initializers/rails_ai_context.rb` runs, YAML is skipped.

### Commands hang

The `serve` command waits for stdio input by design. Use `doctor` or `tool --list` to verify the gem works, then let your AI tool connect to the server.

---

<div align="center" markdown="1">

**[← CLI Reference](CLI.md)** · **[Troubleshooting →](TROUBLESHOOTING.md)**

[Back to Home](index.md)

</div>
