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

Both provide the same 45 tools and functionality.

---

## Commands

### `serve`

Start the MCP server.

```bash
rails ai:serve                                        # stdio (default)
rails ai:serve_http                                   # HTTP transport
rails-ai-context serve                                # stdio (default)
rails-ai-context serve --transport http --port 6029   # HTTP transport
```

| Option | Default | Description |
|:-------|:--------|:------------|
| `--transport` | `stdio` | `stdio` or `http` |
| `--port` | `http_port` from config, else `6029` | HTTP listen port |
| `--no-boot` | off | Skip booting the app; answer from source alone |

The server announces itself to the client as `server_name` from config, else `rails-ai-context`. The `RAILS_AI_CONTEXT_SERVER_NAME` environment variable takes the place of that default for one process; a `server_name` the app sets itself still wins. A [workspace](#init-standalone-only) entry sets the variable to put its app first, since VS Code names every tool after the announced name and keeps 13 characters of it.

### `tool`

Run any of the 45 MCP tools from the terminal.

```bash
# Rake syntax
rails 'ai:tool[schema]' table=users detail=full
rails 'ai:tool[search_code]' pattern="publishable?" match_type=trace
rails 'ai:tool[model_details]' model=User

# Thor syntax
rails-ai-context tool schema --table users --detail full
rails-ai-context tool search_code --pattern "publishable?" --match-type trace
rails-ai-context tool model_details --model User
```

| Option | Description |
|:-------|:------------|
| `--list` | List all available tools |
| `--json` | Output as JSON (`-j` after the tool name) |
| `--help` | After the tool name, print that tool's parameters. Rake: `help=true` |
| `--no-boot` | Skip booting the app; answer from source alone |

Global options may be typed before or after the command name:
`rails-ai-context --app-path /srv/app doctor` and
`rails-ai-context doctor --app-path /srv/app` run the same check.

`--app-path` names the Rails root, taken as given. Left out, every command
that reads an app finds it the way `bin/rails` and Bundler do: the working
directory if it is an app, else the nearest app root above it (a directory with
`config/application.rb`, `config/environment.rb`, or a `bin/rails` that boots an
app or an engine; never `$HOME`, `node_modules` or a gem install), else the one
app a level or two below it - looked for everywhere but `/`, `$HOME` and the
directories above it, which hold too much to search. A walk names the app it chose on stderr, as
`[rails-ai-context] using app at a/`, so `serve` keeps stdout clean. A folder
holding several apps is refused with one `--app-path` command per app, and
`tool --list` there lists the tools without an app. The chosen root is the
process's working directory for the rest of the run, so `init`, the config and
every file written land in it.
`--environment` names the `RAILS_ENV` to boot under. Left out, it resolves the
way Rails resolves its own environment: the ambient `RAILS_ENV`, then
`RACK_ENV`, then `development`, reading an empty value as unset. So an app
whose `config/boot.rb` refuses to run without the variable still gets booted
rather than answering nothing. Name it explicitly on a machine that runs more
than one environment, because the environment decides which database
configuration the booted tier reads.

After the name of a tool that declares an `environment` parameter of its own
(`env_config`), `--environment` is that tool's filter and does not set
`RAILS_ENV`: `tool env_config --environment production` lists production and
boots the app in its usual environment. Set `RAILS_ENV` through the
environment variable, or put `--environment` before the command name, to boot
in another one. Every other tool reads the flag as `RAILS_ENV`. A custom tool
that declares the parameter gets the value both ways, since its schema cannot
be read before the app boots.

#### Exit status

`tool` exits 0 when the tool answered and 1 when it could not. A required
parameter you did not pass, a flag with no value after it, a bare word where a
flag belongs, and an unknown parameter all exit 1 and say which one. So does a
refusal on policy - a path outside the app root, a sensitive file, a SQL
statement the read-only validator blocks - because the question went
unanswered.

A thing that is simply not there is an ordinary answer and exits 0: a file the
tool looked for and did not find, a search with no matches, a directory the
`--path` names that does not exist. A tool that needs a
booted app and is run with `--no-boot` (`query`, `runtime_info`) prints
`[UNAVAILABLE]` with the reason and also exits 0.

A value the schema cannot hold - `--detail bogus` where the parameter takes
`summary`, `standard` or `full`, or `--limit abc` where it takes an integer -
is warned about on stderr and the tool's own default is used. A required
parameter has no default, so a value outside its list (`--action bogus` on
`migration_advisor`) exits 1.

### The static tier and `--no-boot`

Every command that reads the app takes `--no-boot`: `tool`, `serve`, `context`,
`inspect`, `facts`, `preset`, `watch` and `init`. It skips the boot and answers
from source alone, which is what you want on a repo you have just cloned, on an
app whose boot is broken, and in CI where booting costs more than the answer.

The same tier is entered automatically when a boot fails, so you get an answer
either way. Answers that need a running app are marked `[UNAVAILABLE: ...]`
rather than guessed, and everything else is tagged `[STATIC]` instead of
`[VERIFIED]`. `docs/COMPATIBILITY.md` lists which of the 40 introspectors answer
in which tier.

`doctor` is the exception: diagnosing the boot is its job, so it refuses
`--no-boot` and still exits 1 when the app cannot start.

```bash
rails-ai-context tool model_details --no-boot # no boot, no database, no Gemfile
rails-ai-context context --no-boot            # writes CLAUDE.md from source
```

### Tool name resolution

All of these resolve to the same tool:

```bash
rails 'ai:tool[schema]'
rails 'ai:tool[get_schema]'
rails 'ai:tool[rails_get_schema]'
```

Resolution order: exact match → `rails_` prefix → `rails_get_` prefix → short name (the name with `rails_get_` or `rails_` removed).

### `context`

Generate static context files.

```bash
rails ai:context              # All configured formats
rails ai:context:claude       # Claude only
rails ai:context:cursor       # Cursor only
rails ai:context:copilot      # Copilot only
rails ai:context:opencode     # OpenCode only
rails ai:context:codex        # Codex only
rails ai:context:json         # JSON export
rails ai:context:full         # All formats, full mode

rails-ai-context context                # All
rails-ai-context context --format claude # Specific format
```

| Option | Default | Description |
|:-------|:--------|:------------|
| `--format` | all configured | `claude`, `cursor`, `copilot`, `opencode`, `codex`, `json`, `all` |

The rake tasks `ai:context`, `ai:context:<format>` and `ai:context_for` also read
`CONTEXT_MODE`: `CONTEXT_MODE=full rails ai:context` overrides `config.context_mode`
for that run. The standalone binary does not read it.

### `doctor`

Run the diagnostic checks and report an AI readiness score.

```bash
rails ai:doctor
rails-ai-context doctor
rails-ai-context doctor --strict   # exit 1 when any check fails (CI gate)
rails ai:doctor STRICT=1           # rake equivalent
```

Checks include: schema existence, pending migrations, model files, routes, MCP config validity, introspector health, ripgrep availability, Prism gem, Brakeman gem, listen gem, gitignore security, auto_mount security, schema size, view count, and more.

### `watch`

Watch for file changes and auto-regenerate context files.

```bash
rails ai:watch
rails-ai-context watch
```

Requires the `listen` gem. Watches `app/`, `config/`, `db/`, `lib/`, `rakelib/`, `test/`, `spec/`.

### `init` (standalone only)

Interactive setup for standalone mode.

```bash
rails-ai-context init
rails-ai-context init --mcp-only   # MCP config only, no context files
```

Asks which AI tools to configure and what to write: MCP config and context files, context files only (CLI mode), or MCP config only. Creates `.rails-ai-context.yml`, the MCP config files (except in CLI mode) and the context files (except with MCP config only). `--mcp-only` skips the second question.

Run inside an app, `init` sets up that app (found the way every command finds it: the [app root](#tool) above a subdirectory, or the one `--app-path` names).

Run in a folder that is no app but holds apps one or two levels down - a **workspace**, the folder an editor or agent is often opened at - it sets the folder up as a whole:

```text
work/                      <- run `rails-ai-context init` here
  .mcp.json                   one server per app: rails-ai-context-api, rails-ai-context-web
  .cursor/mcp.json ...        (every selected AI tool's MCP config, in the folder it reads)
  api/  .rails-ai-context.yml, CLAUDE.md, ...   each app keeps its own config and context files
  web/  .rails-ai-context.yml, CLAUDE.md, ...
```

The AI tools and the setup are asked once. Each app gets its own `.rails-ai-context.yml` and context files, because its server reads them from its own root; a child process generates them with the install that app's server will run. The folder's MCP configs get one server per app, because a client reads its project config from the folder it opened. Each entry is named `rails-ai-context-<app folder>` (the whole path where two apps share a folder name; a short hash where the name would pass 30 characters, since Cursor drops a tool whose server and tool names together pass 60) and points `--app-path` at its app:

```json
{
  "mcpServers": {
    "rails-ai-context-api": {
      "command": "rails-ai-context",
      "args": ["serve", "--app-path", "api"],
      "env": { "RAILS_AI_CONTEXT_SERVER_NAME": "api-rails-ai-context" }
    },
    "rails-ai-context-web": {
      "command": "bundle",
      "args": ["exec", "rails-ai-context", "serve", "--app-path", "web"],
      "env": { "BUNDLE_GEMFILE": "web/Gemfile", "RAILS_AI_CONTEXT_SERVER_NAME": "web-rails-ai-context" }
    }
  }
}
```

- **Paths stay relative**, so a committed file means the same thing on every machine. Claude Code, Codex and OpenCode start a server in the folder they were launched in, so their configs name the app from the workspace (`api`). Cursor and VS Code have a name for the folder their config sits in, `${workspaceFolder}`, so their configs name the app from it (`${workspaceFolder}/api`); Cursor does not promise a working directory.
- **The command form is each app's own**: the bare binary where the gem is not in the app's Gemfile.lock, `bundle exec` where it is, with `BUNDLE_GEMFILE` naming the Gemfile the app's bundle reads - its own (a linked one by the link's name, so its lockfile stays beside it), else the one its `config/boot.rb` names, as a monorepo's apps share one, else the one `bundle exec` run inside the app would find - since `bundle exec` started in the workspace would look for one there.
- **`RAILS_AI_CONTEXT_SERVER_NAME` puts the app first** in the name the server announces. VS Code names every tool after that name and keeps 13 characters of it, so without it every app's tools would start `rails-ai-cont`. It is a variable rather than a flag so that an app whose bundle pins an older gem ignores it and starts.
- A bare `rails-ai-context` entry left in the folder is replaced, since it would serve the folder itself, and so is an entry under a name the gem gives an app in this folder (its folder name or path) when that app's folder is gone, or the app now goes by another name because an app with the same folder name arrived. An entry named `rails-ai-context-...` that runs `rails-ai-context serve` is the gem's: dropping an AI tool removes it from that tool's config. One that runs no command, such as an HTTP entry of your own under either name, is left alone, and so is a second entry you named yourself for an app (`rails-ai-context-api-2` included), one that names its app through a variable the tool expands (`${userHome}`), and one naming an app outside the folder.
- A config that does not parse as JSON (VS Code's and OpenCode's take trailing commas), or holds comments a rewrite would drop, is left as it is, with a warning that names the entry to add by hand. An empty one is filled, and a byte order mark at the head of one stays.
- `--app-path` naming a folder of apps sets that folder up the same way; every other command lists the apps below it.
- An app whose bundle is not installed yet (a Gemfile and no lockfile) is served by this binary unless its Gemfile names the gem, or pulls gems in from other files (`eval_gemfile`, `gemspec`) that could.

Start the client in the workspace folder. A client started inside one of the apps (Claude Code, Codex and OpenCode still read a config above it) runs each workspace server from there, where the relative path misses; the server says which folder the path was written for. To open an app on its own, run `init` inside it as well. `init` warns when an app declares a Ruby other than the one the workspace runs, since every server it starts runs under that one. `doctor` inside one of the apps finds the workspace's config one or two levels up.

### `version`

```bash
rails-ai-context version
rails-ai-context --version   # or -v
```

### `inspect`

Print introspection summary as JSON.

```bash
rails-ai-context inspect
rails ai:inspect             # short text summary instead of JSON
```

### `facts`

Print a schema facts summary: tables, associations and dependencies.

```bash
rails ai:facts
rails-ai-context facts
rails-ai-context facts --no-boot
```

### `preset`

Run a named group of tools in one pass: `architecture`, `debugging` or `migration`. With no name it lists the presets.

```bash
rails-ai-context preset
rails-ai-context preset architecture
rails 'ai:preset[architecture]'
```

### `tree`

Print a tree of every command. `rails-ai-context help <command>` lists that
command's options.

```bash
rails-ai-context tree
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
| `rails ai:context:codex` | Generate Codex context |
| `rails ai:context:json` | Generate JSON export |
| `rails ai:context:full` | Generate all formats in full mode |
| `rails 'ai:context_for[claude]'` | Generate one format by name |
| `rails ai:serve` | Start MCP server (stdio) |
| `rails ai:serve_http` | Start MCP server (HTTP) |
| `rails ai:tool` | List tools or run a tool |
| `rails ai:doctor` | Run diagnostics |
| `rails ai:watch` | Watch mode |
| `rails ai:inspect` | Print introspection summary |
| `rails ai:facts` | Print schema facts summary |
| `rails 'ai:preset[name]'` | Run a preset; no name lists them |

---

## Tool argument syntax

### Rake format

```bash
rails 'ai:tool[tool_name]' key=value key2=value2
```

- Strings: `table=users`
- Booleans: `explain=true` or `explain=false`
- Enums: `detail=full`
- Arrays: `files=a.rb,b.rb`
- Spaces: `pattern="has_many :posts"`

### Thor format

```bash
rails-ai-context tool tool_name --key value --key2 value2
```

- Strings: `--table users` or `--table=users`
- Booleans: `--explain` (true) or `--no-explain` (false)
- Enums: `--detail full`
- Arrays: `--files a.rb b.rb` or `--files a.rb,b.rb`
- Spaces: `--pattern "has_many :posts"`

### JSON output

Add `--json` for machine-readable output:

```bash
rails-ai-context tool schema --table users --json
JSON=1 rails 'ai:tool[schema]' table=users
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
