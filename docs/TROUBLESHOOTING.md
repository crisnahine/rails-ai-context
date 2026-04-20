<div align="center" markdown="1">

# Troubleshooting

**Common issues and how to fix them.**

[Quickstart](QUICKSTART.md) · [Configuration](CONFIGURATION.md) · [AI Tool Setup](SETUP.md) · [FAQ](FAQ.md)

</div>

---

> [!TIP]
> Always start with `rails ai:doctor`. It runs 23 checks and catches most issues automatically.

## Diagnostics first

```bash
rails ai:doctor          # In-Gemfile
rails-ai-context doctor  # Standalone
```

This runs 23 checks and returns an AI readiness score (0-100). Each failed check includes a fix suggestion.

---

## Installation issues

### "Could not find gem 'rails-ai-context'"

```bash
gem install rails-ai-context
# or
bundle update rails-ai-context
```

### Generator fails with "uninitialized constant RailsAiContext"

The gem is likely in a `:development` group but you're running in another environment:

```ruby
# config/initializers/rails_ai_context.rb
if defined?(RailsAiContext)
  RailsAiContext.configure do |config|
    # ...
  end
end
```

The `if defined?` guard prevents crashes when the gem isn't loaded.

### "Permission denied" during install

File system permissions. Check that your user can write to the project directory:

```bash
ls -la .mcp.json .cursor/ .vscode/ .github/
```

---

## MCP server issues

### AI tool doesn't detect the MCP server

1. Check the config file exists:
   - Claude Code: `.mcp.json`
   - Cursor: `.cursor/mcp.json`
   - Copilot: `.vscode/mcp.json`
   - OpenCode: `opencode.json`
   - Codex: `.codex/config.toml`

2. Verify the command works:
   ```bash
   bundle exec rails ai:serve
   # Should output nothing (waiting for stdio input)
   # Ctrl+C to stop
   ```

3. Re-run the install generator:
   ```bash
   rails generate rails_ai_context:install
   ```

### "MCP server fails to start"

Check for Bundler/Ruby path issues:

```bash
which bundle
which rails
ruby -v
```

For Codex CLI specifically, the env section in `.codex/config.toml` must match your current Ruby environment. Re-run install if you changed Ruby versions.

### "Tools return empty results"

1. Check that your Rails app boots: `rails runner "puts 'ok'"`
2. Check schema exists: `ls db/schema.rb` or `ls db/structure.sql`
3. Run doctor: `rails ai:doctor`

### MCP server responds slowly

- Check `config.cache_ttl` — lower values mean more frequent re-introspection
- Check `config.preset` — `:standard` is faster than `:full`
- Large schema files (>10MB) slow down schema introspection
- Run `rails ai:doctor` — it checks schema size and view count

---

## Context file issues

### "Context files are empty or minimal"

1. Check that models exist: `ls app/models/`
2. Check that schema exists: `ls db/schema.rb`
3. Try full mode: `config.context_mode = :full`
4. Regenerate: `rails ai:context`

### "Context files don't update after code changes"

Regeneration is not automatic unless you're running watch mode:

```bash
rails ai:watch
```

Or regenerate manually:

```bash
rails ai:context
```

### "My custom content in CLAUDE.md was overwritten"

The gem uses section markers (`<!-- BEGIN/END rails-ai-context -->`) to preserve user content. Content outside these markers is preserved. If markers were removed, the gem may overwrite.

### "Generated files are too large"

Use compact mode (default):

```ruby
config.context_mode = :compact
config.claude_max_lines = 150
```

Or disable root files and use only split rules:

```ruby
config.generate_root_files = false
```

---

## Query tool issues

### "Query tool disabled in production"

By design. Override if needed:

```ruby
config.allow_query_in_production = true
```

### "Query blocked: potentially unsafe SQL"

The 4-layer SQL validator blocks write operations and injection patterns. Ensure you're only running SELECT queries.

Common false positives:
- Hash characters in strings → write the hash outside a comment position
- JSONB operators (`#>>`) → preserved correctly since v5.6.0

### "Column values show [REDACTED]"

Columns matching sensitive patterns are redacted. Configure:

```ruby
config.query_redacted_columns = %w[password_digest encrypted_password]
```

---

## Search issues

### "Search returns no results"

1. Check file extensions: `config.search_extensions` defaults to common web types
2. Check excluded paths: `config.excluded_paths` excludes `node_modules`, `tmp`, `log`, etc.
3. Check sensitive patterns: some files are blocked by design

### "ripgrep not found" warning

Install ripgrep for faster search:

```bash
# macOS
brew install ripgrep

# Ubuntu
apt install ripgrep
```

The gem falls back to Ruby regex if ripgrep isn't available. Search still works, just slower on large codebases.

---

## Standalone mode issues

### "Bundler can't find the gem"

Standalone mode pre-loads the gem before Rails boot and restores `$LOAD_PATH` entries stripped by `Bundler.setup`. If this fails:

1. Check the gem is installed: `gem list rails-ai-context`
2. Check Ruby version matches: `ruby -v`
3. Try with Gemfile entry instead of standalone

### "YAML config not loading"

YAML config (`.rails-ai-context.yml`) is skipped if an initializer runs. Check precedence:

1. Initializer (`config/initializers/rails_ai_context.rb`) — highest priority
2. YAML (`.rails-ai-context.yml`)
3. Defaults

Corrupted YAML degrades gracefully with a warning.

---

## Security scan issues

### "Brakeman not installed"

The `rails_security_scan` tool requires Brakeman:

```bash
gem install brakeman
# or
bundle add brakeman --group development
```

Without it, the tool reports "not installed" but the gem works fine otherwise.

---

## Performance issues

### "Introspection is slow"

1. Use `:standard` preset (17 introspectors vs 39)
2. Increase cache TTL: `config.cache_ttl = 300`
3. Check schema file size: `rails ai:doctor` warns if too large
4. Check view count: many views slow down view introspection

### "Live reload fires too often"

Increase the debounce:

```ruby
config.live_reload_debounce = 3.0  # seconds (default: 1.5)
```

Or disable:

```ruby
config.live_reload = false
```

---

## Getting help

1. Run `rails ai:doctor` first — it catches most issues
2. Check [GitHub issues](https://github.com/crisnahine/rails-ai-context/issues)
3. Open a new issue with doctor output and error details

---

<div align="center" markdown="1">

**[← Standalone](STANDALONE.md)** · **[FAQ →](FAQ.md)**

[Back to Home](index.md)

</div>
