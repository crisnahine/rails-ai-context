<div align="center" markdown="1">

# Troubleshooting

**Common issues and how to fix them.**

[Quickstart](QUICKSTART.md) · [Configuration](CONFIGURATION.md) · [AI Tool Setup](SETUP.md) · [FAQ](FAQ.md)

</div>

---

> [!TIP]
> Always start with `rails ai:doctor`. It checks the app, its databases, the MCP configs and the context files, and catches most issues automatically.

## Diagnostics first

```bash
rails ai:doctor          # In-Gemfile
rails-ai-context doctor  # Standalone
```

This runs every check that applies to the app ([the list](GUIDE.md#diagnostics)) and returns an AI readiness score (0-100). Each check that fails or warns includes a fix suggestion.

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
if defined?(RailsAiContext) && RailsAiContext.respond_to?(:configure)
  RailsAiContext.configure do |config|
    # ...
  end
end
```

The guard prevents crashes when the gem isn't loaded. `rails ai:doctor` warns about a guard that checks `defined?(RailsAiContext)` alone, since the constant can exist where `configure` does not.

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

2. Verify the command the config holds works:
   ```bash
   bundle exec rails-ai-context serve   # in-Gemfile
   rails-ai-context serve               # standalone
   # Should output nothing (waiting for stdio input)
   # Ctrl+C to stop
   ```

3. Re-run the install generator:
   ```bash
   rails generate rails_ai_context:install
   ```

### "Could not write .vscode/mcp.json - that tool will not auto-discover the MCP server"

The install never replaces a config it cannot write back faithfully: one that does not parse as JSON (VS Code and OpenCode accept trailing commas, which JSON does not), one holding comments that writing it back would drop, or one that is not UTF-8. The line after the warning says which, and ends with the exact entry to add, as `Add {"servers":{...}} to it by hand`. Add that entry yourself, or remove the trailing commas and comments and run the install again. `doctor` reports one that does not parse, or holds no object to merge into, a workspace's above the app included. Dropping an AI tool leaves such a file alone the same way and names the entries to remove.

### "MCP server fails to start"

`rails ai:doctor` (or `rails-ai-context doctor`) checks the command each config holds and says which one cannot start and why. The usual causes:

- `rails-ai-context is not currently included in the bundle`: the config runs `bundle exec rails-ai-context serve`, but the gem left the app's Gemfile. A standalone install runs `rails-ai-context serve`: run `rails-ai-context init` to rewrite the configs.
- The config runs `rails-ai-context serve` while the app's Gemfile.lock carries the gem: it needs a copy installed outside the bundle as well, which hands the run to the bundle's. Run `rails generate rails_ai_context:install` to write `bundle exec rails-ai-context serve`.
- `can't find executable rails-ai-context for gem rails-ai-context`: the bundle's copy of the gem lists no executable, as a `path:` copy of 5.32.2 or earlier outside a git checkout does. Point the Gemfile at a git checkout or a release.

Check for Bundler/Ruby path issues:

```bash
which bundle
which rails-ai-context
ruby -v
```

For Codex CLI specifically, the env section in `.codex/config.toml` must match your current Ruby environment. Re-run install if you changed Ruby versions.

### Answers say "Boot did not finish within 20s"

The app's boot hung, usually an initializer waiting on a service that is
down (Redis, Elasticsearch, a secrets store). A stdio server gives the boot 20
seconds, because its client stops waiting for the first answer after about 30
(Claude Code, the MCP Inspector), and then serves the static tier; every other
command gives it 60. Start the service, or, for an app that is healthy but
slow to boot, raise both limits in the server's MCP entry: the boot's with
`RAILS_AI_CONTEXT_BOOT_TIMEOUT` (seconds) in its `env`, and the client's with
its own setting (Claude Code reads `MCP_TIMEOUT`, in milliseconds). Raising
only the boot's leaves a client that gives up first. `rails ai:serve` has no
static tier, so it exits with the same message instead.

### A server set up for a folder of apps fails to start

`rails-ai-context init` run in a folder of apps writes entries that name each app relative to that folder (`--app-path shop`, and for an in-Gemfile app `BUNDLE_GEMFILE=shop/Gemfile`, or the monorepo's shared Gemfile its `config/boot.rb` names). Claude Code, Codex and OpenCode start a server in the folder they were launched in, so:

1. Start the AI tool in the folder of apps, not inside one of them. Launched inside an app, the tool still reads the folder's config above it, and the server says `--app-path shop is read from ...; it names an app from ...`. An in-Gemfile entry fails earlier, in Bundler, with a Gemfile it cannot find. To work in one app on its own, run `rails-ai-context init` inside it too.
2. Check the Ruby. Every server in the folder runs under the Ruby your version manager picks in the folder, and `init` warns about an app that declares another. `Your Ruby version is ..., but your Gemfile specified ...` from an in-Gemfile entry is that case: install the app's bundle for that Ruby, or give the app its own config with `init` inside it.

### "No Rails app found in ..., and 2 below it"

You ran a command in a folder that holds several apps. The error lists the exact command for each, with `--app-path`. To set them all up at once, run `rails-ai-context init` in that folder.

### "Tools return empty results"

1. Check that your Rails app boots: `rails runner "puts 'ok'"`
2. Check schema exists: `ls db/schema.rb` or `ls db/structure.sql`
3. Run doctor: `rails ai:doctor`

### MCP client reports a JSON parse error on the first line ("Resolving dependencies...")

RubyGems can print `Resolving dependencies...` to stdout while activating the
standalone `rails-ai-context` binary - before any gem code runs - which breaks
the pure-JSON stdio framing. This happens when gem activation needs the full
dependency resolver: typically a `GEM_PATH` that is missing part of the
dependency graph, or launching from inside another Bundler project's
directory. Fixes:

1. Launch `rails-ai-context serve` with the app root as the working directory
   (the generated MCP configs do this by default; a folder of apps' configs
   start in that folder and name the app with `--app-path`).
2. Make sure `GEM_PATH` covers the complete default gem path
   (`gem env path`), not just `gem env gemdir` - Ruby's bundled gems
   (racc, etc.) live in a separate directory.
3. In-Gemfile installs are immune: `bundle exec rails-ai-context serve`
   activates through the lockfile.

### MCP server responds slowly

- Check `config.cache_ttl` - lower values mean more frequent re-introspection
- Without the `listen` gem, each call first checks the app's files for edits, about 100 ms at 10,000 files; adding `listen` to the development group replaces that check with live reload
- Check `config.preset` - `:standard` is faster than `:full`
- Large schema files (>10MB) slow down schema introspection
- Run `rails ai:doctor` - it checks schema size and view count

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

The gem writes its section between `<!-- BEGIN rails-ai-context -->` and `<!-- END rails-ai-context -->` and replaces only what lies between them, so text above and below the markers survives every run; text inside them does not. A file with no markers at all gets the section added at the top, and its own text kept below.

If one marker goes missing, or the file holds a second pair, nothing says where the gem's section ends. The run then leaves the file as it is and reports it as `unpaired rails-ai-context marker, left as it is`. Put the lost marker back where the gem's section ends, or delete the leftover section with its markers, and the next run updates the file again.

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

### "rails_query is disabled in production"

By design. Override if needed:

```ruby
config.allow_query_in_production = true
```

### "Blocked: contains INSERT" and other "Blocked:" messages

The 4-layer SQL validator blocks write operations and injection patterns, and the message names what it hit. Ensure you're only running SELECT queries.

Common false positives:
- A blocked keyword inside a string (`WHERE note = 'please insert coin'`) → the validator matches words, not SQL structure, so the query is refused
- Hash characters → a `#` starts a comment on MySQL only, and never inside a quoted string
- JSONB operators (`#>>`) → preserved correctly since v5.6.0

### "Column values show [FILTERED]"

Columns whose names look sensitive are redacted, and a query that names one is rejected with "Blocked: query references sensitive column". Shortening `config.query_redacted_columns` does not lift either, because a built-in list applies as well. Exempt a column of your own by name:

```ruby
config.query_allowed_columns = %w[secret]
```

---

## Search issues

### "Search returns no results"

1. Check the case: the search is case-sensitive on both backends, as ripgrep is by default
2. Check excluded paths: `config.excluded_paths` excludes `node_modules`, `tmp`, `log`, `vendor`, `.git`, `doc` and `docs` directories at any depth
3. Check `config.search_extensions`: when set, it narrows the Ruby fallback to those extensions
4. Check sensitive patterns: some files are blocked by design

### "ripgrep not installed" warning

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

Standalone mode boots the app with a small shim, then restores the `$LOAD_PATH` entries `Bundler.setup` stripped and requires the gem. If this fails:

1. Check the gem is installed: `gem list rails-ai-context`
2. Check Ruby version matches: `ruby -v`
3. Try with Gemfile entry instead of standalone

### "YAML config not loading"

The file is read from the app root, once, at boot, and an initializer does not replace it: a `configure` block wins only the keys it assigns, key by key ([Precedence](CONFIGURATION.md#precedence)). In standalone mode the initializer contributes nothing at all, since the gem is not loaded while `config/initializers` runs. Check:

1. You are inside the app, or passed `--app-path`. A command run from a subdirectory reads the config of the app root it walks up to, and names it on stderr.
2. The key is one the gem knows. An unknown key warns on stderr and is ignored.
3. The file is readable and parses. Corrupted YAML degrades gracefully with a warning.

---

## Security scan issues

### "Brakeman is not installed"

The `rails_security_scan` tool requires Brakeman:

```bash
gem install brakeman
# or
bundle add brakeman --group development
```

Without it, the tool reports "not installed" but the gem works fine otherwise.

### "Installed on this machine but not in this app's bundle"

The scan runs under the app's own bundle, so a brakeman installed globally is
not on its load path. The tool falls back on its own: it runs the installed
brakeman as a separate process outside the bundle and says so under the
results. This message means that fallback produced no report either - the gem
is there and the run failed. Run `brakeman` in the app directory to see what
it hit, or add it to the Gemfile so the scan runs in-process:

```bash
bundle add brakeman --group development
```

---

## Performance issues

### "Introspection is slow"

1. Use `:standard` preset (17 introspectors vs 40)
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

1. Run `rails ai:doctor` first - it catches most issues
2. Check [GitHub issues](https://github.com/crisnahine/rails-ai-context/issues)
3. Open a new issue with doctor output and error details

---

<div align="center" markdown="1">

**[← Standalone](STANDALONE.md)** · **[FAQ →](FAQ.md)**

[Back to Home](index.md)

</div>
