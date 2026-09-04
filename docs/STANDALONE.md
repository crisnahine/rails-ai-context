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
- `.rails-ai-context.yml` - YAML configuration
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

1. **Loads only its boot shim** before the app - the binary requires the two files it needs to boot Rails, then `config/environment.rb`, and requires the gem itself only after the boot returns
2. **Restores `$LOAD_PATH`** entries that `Bundler.setup` strips (since the gem isn't in the Gemfile)
3. **YAML config** - uses `.rails-ai-context.yml` instead of a Ruby initializer

This means you get the same 45 tools, same MCP server, same context generation - without touching the project's Gemfile.

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

One config option is Ruby-only and can't be set via YAML:

- `custom_tools` - a tool class is a Ruby class reference, which a YAML file cannot name

For that one, use the initializer approach (in-Gemfile mode).

Every other option is a YAML key, `excluded_concerns` included: write the patterns as strings and each is compiled at load. A YAML list replaces the framework defaults rather than adding to them, and a string is an unanchored pattern - see [Configuration](CONFIGURATION.md#filtering).

A key the gem does not know warns on stderr and is ignored; the rest of the file still applies.

### Precedence

In standalone mode `.rails-ai-context.yml` is the only config source. The gem is not loaded while `config/initializers` runs, so a `config/initializers/rails_ai_context.rb` contributes nothing: the generated file, which guards on `defined?(RailsAiContext) && RailsAiContext.respond_to?(:configure)`, is a silent no-op, and one without that guard raises `NoMethodError` and drops the command into the static tier.

For in-Gemfile installs both sources apply and merge key by key - see [Precedence](CONFIGURATION.md#precedence).

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

Codex CLI is special - it `env_clear()`s the process before spawning MCP servers. The install generator snapshots your Ruby environment variables (PATH, GEM_HOME, GEM_PATH, GEM_ROOT, RUBY_VERSION, BUNDLE_PATH) into `.codex/config.toml` so Codex can find Ruby and gems.

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

The MCP config files are updated automatically. Both modes generate identical context files and provide the same 45 tools.

## Troubleshooting

### "Bundler::GemNotFound" on `rails-ai-context serve`

The gem's `$LOAD_PATH` restoration may have failed. Check:

```bash
gem list rails-ai-context    # Is it installed?
ruby -v                       # Right Ruby version?
```

### "YAML config not loading"

The file is read from the app root, once, at boot. Check:

1. You are in the app root, or passed `--app-path`.
2. The key is one the gem knows. An unknown key warns on stderr and is ignored; `custom_tools` is initializer-only.
3. The file is readable and parses. A directory at that path, an unreadable file or broken YAML warns on stderr and keeps the defaults.

### Commands hang

The `serve` command waits for stdio input by design. Use `doctor` or `tool --list` to verify the gem works, then let your AI tool connect to the server.

---

<div align="center" markdown="1">

**[← CLI Reference](CLI.md)** · **[Troubleshooting →](TROUBLESHOOTING.md)**

[Back to Home](index.md)

</div>
