<div align="center" markdown="1">

# Copy-paste prompts

**Paste one into your AI tool. It installs, changes, removes or starts using rails-ai-context for you.**

[Quickstart](QUICKSTART.md) · [AI tool setup](SETUP.md) · [CLI reference](CLI.md) · [Troubleshooting](TROUBLESHOOTING.md)

</div>

---

Open your AI tool (Claude Code, Cursor, GitHub Copilot, OpenCode or Codex CLI) at the root of your Rails app, copy the prompt for your case, and paste it. Every prompt runs a fixed set of commands and gives each answer as a flag. The install asks nothing the AI tool can't answer, and it works the same in every tool.

Each prompt finds out which AI tool it is running in and sets up that one. To set up several at once, use [For a whole team](#for-a-whole-team-every-ai-tool).

## Pick your prompt

| You want | Prompt |
|:---|:---|
| The usual setup. Not sure? Pick this | [Install (recommended)](#install-recommended) |
| No change to the Gemfile | [Install without touching the Gemfile](#install-without-touching-the-gemfile) |
| No MCP server, the AI tool runs shell commands | [CLI only](#cli-only-no-mcp-server) |
| MCP, but keep my own `CLAUDE.md` / `AGENTS.md` | [MCP only](#mcp-only-keep-my-own-context-files) |
| Every AI tool, for a team | [For a whole team](#for-a-whole-team-every-ai-tool) |
| An editor opened at a folder of several apps | [A folder of apps](#a-folder-of-apps) |
| Nothing committed to the repo | [Private setup](#private-setup-nothing-committed) |
| Try it first, write nothing | [Try it without installing](#try-it-without-installing) |
| MCP over HTTP inside the running app | [MCP over HTTP](#mcp-over-http) |
| Ruby runs in a Docker container | [Ruby runs in Docker](#ruby-runs-in-docker) |
| Claude Desktop, Windsurf, Zed, JetBrains or another MCP client | [Another MCP client](#another-mcp-client) |
| Add or drop an AI tool, switch setups | [Change the setup](#change-the-setup) |
| Move between the Gemfile and standalone | [Switch install type](#switch-between-gemfile-and-standalone) |
| A newer version | [Upgrade](#upgrade) |
| Something is off | [Fix it](#fix-it) |
| Take it all out | [Uninstall](#uninstall) |
| Put it to work | [Prompts for daily work](#prompts-for-daily-work) |

Each install also works when the app can't boot (no database, missing ENV vars): the prompt falls back to the standalone `init`, and the tools answer from the source files.

---

## Install

### Install (recommended)

In the Gemfile's development group, MCP server plus context files for the AI tool you're in.

```text
Install the rails-ai-context gem in this Rails app so you can read its schema, models, routes and code through its tools instead of guessing.

1. Run `ruby -v` and `bundle exec rails -v`. rails-ai-context needs Ruby 3.1+ and Rails 7.0+. If either is older, stop and tell me.
2. Pick TOOL, the key for the AI tool you are: claude (Claude Code), cursor (Cursor), copilot (GitHub Copilot in VS Code), opencode (OpenCode), codex (Codex CLI). If you are another AI tool, stop and tell me to use the "Another MCP client" prompt instead.
3. Run `bundle add rails-ai-context --group development --version '>= 5.35.0'`. If the Gemfile already lists it, run `bundle update rails-ai-context --conservative` instead. Then run `bundle exec rails-ai-context version`: it must print 5.35.0 or newer, the first version with the flags used below. If it is older, the Gemfile pins it: change its rails-ai-context line to `gem "rails-ai-context", ">= 5.35.0", group: :development` and run `bundle update rails-ai-context --conservative`. If Bundler refuses (a frozen or deployment bundle), run `gem install rails-ai-context -v '>= 5.35.0'` instead and use `rails-ai-context init --tools TOOL --defaults` in step 4.
4. Run `bundle exec rails generate rails_ai_context:install --tools TOOL --defaults`. If it fails because the app can't boot, run `bundle exec rails-ai-context init --tools TOOL --defaults` instead; that one reads the source files when the app won't start.
5. Run `bundle exec rails-ai-context tool onboard` (or `rails-ai-context tool onboard` if you used gem install) and check it describes this app.
6. Tell me which files changed, then the "Next step" lines the install printed for TOOL, word for word. I have to do that step before your rails-ai-context MCP tools appear.
```

### Install without touching the Gemfile

The gem lives in your Ruby, not in the app's bundle. Same MCP server and context files.

```text
Install rails-ai-context for this Rails app without changing the Gemfile or Gemfile.lock.

1. Run `ruby -v`. rails-ai-context needs Ruby 3.1+. If it is older, stop and tell me.
2. Pick TOOL, the key for the AI tool you are: claude (Claude Code), cursor (Cursor), copilot (GitHub Copilot in VS Code), opencode (OpenCode), codex (Codex CLI). If you are another AI tool, stop and tell me to use the "Another MCP client" prompt instead.
3. Run `gem install rails-ai-context -v '>= 5.35.0'`. It installs into the Ruby this directory uses (rbenv, rvm, asdf, mise and chruby all pick it by directory), so run it here.
4. Run `rails-ai-context init --tools TOOL --defaults`.
5. Run `rails-ai-context tool onboard` and check it describes this app.
6. Run `git status` and confirm Gemfile and Gemfile.lock are unchanged.
7. Tell me which files changed, then the "Next step" lines the install printed for TOOL, word for word.
```

### CLI only (no MCP server)

Context files that tell the AI tool to run the tools as shell commands. Nothing to start or approve.

```text
Set up rails-ai-context in this Rails app in the CLI setup: no MCP server. You will run its tools as shell commands, and the context files it writes tell you how.

1. Run `ruby -v` and `bundle exec rails -v`. rails-ai-context needs Ruby 3.1+ and Rails 7.0+. If either is older, stop and tell me.
2. Pick TOOL, the key for the AI tool you are: claude (Claude Code), cursor (Cursor), copilot (GitHub Copilot in VS Code), opencode (OpenCode), codex (Codex CLI). If you are another AI tool, stop and tell me to use the "Another MCP client" prompt instead.
3. If I said not to change the Gemfile, or `bundle add` refuses: run `gem install rails-ai-context -v '>= 5.35.0'`, then `rails-ai-context init --tools TOOL --cli --defaults`, and skip to step 6.
4. Run `bundle add rails-ai-context --group development --version '>= 5.35.0'`. If the Gemfile already lists it, run `bundle update rails-ai-context --conservative` instead. Then run `bundle exec rails-ai-context version`: it must print 5.35.0 or newer, the first version with the flags used below. If it is older, the Gemfile pins it: change its rails-ai-context line to `gem "rails-ai-context", ">= 5.35.0", group: :development` and run `bundle update rails-ai-context --conservative`.
5. Run `bundle exec rails generate rails_ai_context:install --tools TOOL --cli --defaults`. If it fails because the app can't boot, run `bundle exec rails-ai-context init --tools TOOL --cli --defaults` instead.
6. Confirm no MCP config was written for TOOL (.mcp.json, .cursor/mcp.json, .vscode/mcp.json, .github/mcp.json, opencode.json or .codex/config.toml should not name rails-ai-context).
7. Run the tool list (`bundle exec rails-ai-context tool --list`, or `rails-ai-context tool --list` after gem install), then run `onboard` the same way and summarise this app in five lines.
8. From now on, before you write code that names a table, column, association, route or method, check it with these commands.
```

### MCP only (keep my own context files)

The MCP server and nothing else. Your `CLAUDE.md`, `AGENTS.md`, `.cursorrules` and rules folders stay exactly as they are.

```text
Set up the rails-ai-context MCP server for this Rails app, MCP config only. Do not create or change CLAUDE.md, AGENTS.md, .cursorrules, .cursor/rules, .claude/rules or .github instructions.

1. Run `ruby -v` and `bundle exec rails -v`. rails-ai-context needs Ruby 3.1+ and Rails 7.0+. If either is older, stop and tell me.
2. Pick TOOL, the key for the AI tool you are: claude (Claude Code), cursor (Cursor), copilot (GitHub Copilot in VS Code), opencode (OpenCode), codex (Codex CLI). If you are another AI tool, stop and tell me to use the "Another MCP client" prompt instead.
3. If I said not to change the Gemfile, or `bundle add` refuses: run `gem install rails-ai-context -v '>= 5.35.0'`, then `rails-ai-context init --tools TOOL --mcp-only --defaults`, and skip to step 6.
4. Run `bundle add rails-ai-context --group development --version '>= 5.35.0'`. If the Gemfile already lists it, run `bundle update rails-ai-context --conservative` instead. Then run `bundle exec rails-ai-context version`: it must print 5.35.0 or newer, the first version with the flags used below. If it is older, the Gemfile pins it: change its rails-ai-context line to `gem "rails-ai-context", ">= 5.35.0", group: :development` and run `bundle update rails-ai-context --conservative`.
5. Run `bundle exec rails generate rails_ai_context:install --tools TOOL --mcp-only --defaults`. If it fails because the app can't boot, run `bundle exec rails-ai-context init --tools TOOL --mcp-only --defaults` instead.
6. Run `git status` and confirm none of the context files above changed.
7. Tell me which files changed, then the "Next step" lines the install printed for TOOL, word for word.
```

### For a whole team (every AI tool)

All five AI tools, so whoever opens the repo gets the tools in theirs.

```text
Install rails-ai-context in this Rails app for every supported AI tool (Claude Code, Cursor, GitHub Copilot, OpenCode and Codex CLI), so the whole team gets it.

1. Run `ruby -v` and `bundle exec rails -v`. rails-ai-context needs Ruby 3.1+ and Rails 7.0+. If either is older, stop and tell me.
2. Run `bundle add rails-ai-context --group development --version '>= 5.35.0'`. If the Gemfile already lists it, run `bundle update rails-ai-context --conservative` instead. Then run `bundle exec rails-ai-context version`: it must print 5.35.0 or newer, the first version with the flags used below. If it is older, the Gemfile pins it: change its rails-ai-context line to `gem "rails-ai-context", ">= 5.35.0", group: :development` and run `bundle update rails-ai-context --conservative`.
3. Run `bundle exec rails generate rails_ai_context:install --tools all --defaults`. If it fails because the app can't boot, run `bundle exec rails-ai-context init --tools all --defaults` instead.
4. Run `bundle exec rails-ai-context tool onboard` and check it describes this app. Every generated file is meant to be committed.
5. Write me a short commit message for the change, and list the "Next step" lines the install printed for each AI tool, so I can paste them into the team channel.
```

### A folder of apps

For an editor or agent opened at a folder that holds several Rails apps (`work/shop`, `work/admin`). Each app gets its own context files; the folder's MCP configs get one server per app.

```text
This folder is not a Rails app; it holds several. Set up rails-ai-context for all of them from here.

1. Pick TOOL, the key for the AI tool you are: claude (Claude Code), cursor (Cursor), copilot (GitHub Copilot in VS Code), opencode (OpenCode), codex (Codex CLI). If you are another AI tool, stop and tell me to use the "Another MCP client" prompt instead.
2. Run `gem install rails-ai-context -v '>= 5.35.0'` here.
3. Run `rails-ai-context init --tools TOOL --defaults` in this folder, not inside an app. It lists the apps it found and sets up each one.
4. Read the output. If it warns that an app declares another Ruby version, tell me which app.
5. For each app it set up, run `rails-ai-context --app-path APP tool onboard` (APP is the app's path from here) and check it answers.
6. Tell me which files changed, then the "Next step" lines the install printed for TOOL, word for word. Remind me to always start you from this folder, since the MCP entries name each app by its path from here.
```

### Private setup (nothing committed)

Everything works on your machine, and `git status` stays clean. Uses `.git/info/exclude`, which git never commits.

```text
Set up rails-ai-context for me only in this Rails app: nothing it writes may show up in `git status`, and the Gemfile must not change.

1. Run `ruby -v`. rails-ai-context needs Ruby 3.1+. If it is older, stop and tell me.
2. Pick TOOL, the key for the AI tool you are: claude (Claude Code), cursor (Cursor), copilot (GitHub Copilot in VS Code), opencode (OpenCode), codex (Codex CLI). If you are another AI tool, stop and tell me to use the "Another MCP client" prompt instead.
3. Run `git status --porcelain` and remember its output.
4. Run `gem install rails-ai-context -v '>= 5.35.0'`, then `rails-ai-context init --tools TOOL --defaults`.
5. Run `git status --porcelain --untracked-files=all` again. Restore every tracked file that now shows as modified or deleted and did not in step 3 with `git checkout -- PATH` (.gitignore is one when the repo has it). If one of them is a context file the repo already had (CLAUDE.md, AGENTS.md, .cursorrules or .github/copilot-instructions.md), also add the line `generate_root_files: false` to .rails-ai-context.yml and run `rails-ai-context context`: the gem then writes its rules into its own rules files instead of that one. Then run `git status --porcelain --untracked-files=all` once more (restoring .gitignore makes files it ignored show up) and add every path that is new compared with step 3 to .git/info/exclude, one per line (create the file if it is missing).
6. Run `git status --porcelain` once more and confirm it matches step 3.
7. Tell me the "Next step" lines the install printed for TOOL, word for word.
```

### Try it without installing

No files written, nothing to undo. You see what your AI tool would get.

```text
Show me what rails-ai-context knows about this Rails app, without setting anything up. Do not create or change any file in this repository.

1. Run `ruby -v`. rails-ai-context needs Ruby 3.1+. If it is older, stop and tell me.
2. Run `gem install rails-ai-context -v '>= 5.35.0'` (it installs into my Ruby, not this repo).
3. Run each of these and keep the output short:
   rails-ai-context tool onboard
   rails-ai-context tool schema --detail summary
   rails-ai-context tool routes --detail summary
   rails-ai-context tool conventions
4. If a command says the app could not boot, add --no-boot to it and run it again: the tools then read the source files.
5. Run `git status --porcelain` and confirm it is empty or unchanged.
6. Give me a 10-line summary of this app built only from that output, and tell me which setup fits it: the usual install, no Gemfile change, CLI only, MCP only, every AI tool for a team, or a folder of apps.
```

### MCP over HTTP

The MCP server mounted inside the app, for a client that connects by URL. Development and test only unless you opt in.

```text
Serve rails-ai-context over HTTP from inside this Rails app.

1. Run `ruby -v` and `bundle exec rails -v`. rails-ai-context needs Ruby 3.1+ and Rails 7.0+. If either is older, stop and tell me.
2. Pick TOOL, the key for the AI tool you are: claude (Claude Code), cursor (Cursor), copilot (GitHub Copilot in VS Code), opencode (OpenCode), codex (Codex CLI). If you are another AI tool, stop and tell me to use the "Another MCP client" prompt instead.
3. Run `bundle add rails-ai-context --group development --version '>= 5.35.0'` (if the Gemfile already lists it, `bundle update rails-ai-context --conservative` instead). Then run `bundle exec rails-ai-context version`: it must print 5.35.0 or newer, the first version with the flags used below. If it is older, the Gemfile pins it: change its rails-ai-context line to `gem "rails-ai-context", ">= 5.35.0", group: :development` and run `bundle update rails-ai-context --conservative`. Then run `bundle exec rails generate rails_ai_context:install --tools TOOL --defaults`.
4. Add this line inside the `Rails.application.routes.draw` block of config/routes.rb, exactly as written, including the `if`:
   mount RailsAiContext::Engine, at: "/mcp" if defined?(RailsAiContext::Engine)
   The `if` keeps production booting, where the development group is not installed.
5. In TOOL's MCP config file, replace the command entry named rails-ai-context with a URL entry: for .mcp.json `{"type": "http", "url": "http://localhost:3000/mcp"}` under mcpServers (Claude Code skips a URL entry without the type), for .cursor/mcp.json `{"url": "http://localhost:3000/mcp"}` under mcpServers, for .vscode/mcp.json `{"type": "http", "url": "http://localhost:3000/mcp"}` under servers. Use the port the app's server runs on. For opencode.json use `{"type": "remote", "url": "http://localhost:3000/mcp"}` under mcp. For Codex CLI, keep the command entry: it starts the server itself.
6. Start the app (`bundle exec rails server`) in the background, then run `curl -s -i -X POST http://localhost:3000/mcp -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"check","version":"1"}}}'`. It should answer `200 OK` with an `mcp-session-id` header and a `serverInfo` result. Stop the server you started when done.
7. Tell me to keep the app running while I use you, and the "Next step" lines the install printed for TOOL.
```

### Ruby runs in Docker

Ruby and the gems live in a container, and your AI tool runs on your machine. The MCP server runs inside the container, started through `docker exec`.

```text
Set up rails-ai-context for this Rails app, which runs in a Docker container. Ruby and the gems live in the container, not on this machine, so run every Ruby, Bundler and Rails command inside it.

1. Work out how to run a command in the app's container; call that prefix RUN. With Docker Compose (a compose.yaml or docker-compose.yml here), find the service that runs Rails, start it with `docker compose up -d SERVICE`, and RUN is `docker compose exec -T SERVICE`. With a plain container, find it in `docker ps`, and RUN is `docker exec -i CONTAINER`. Write RUN out in full in every command below rather than keeping it in a shell variable. If neither works, stop and tell me.
2. Run `RUN ruby -v` and `RUN bundle exec rails -v`. rails-ai-context needs Ruby 3.1+ and Rails 7.0+. If either is older, stop and tell me.
3. Pick TOOL, the key for the AI tool you are: claude (Claude Code), cursor (Cursor), copilot (GitHub Copilot in VS Code), opencode (OpenCode), codex (Codex CLI). If you are another AI tool, stop and tell me to use the "Another MCP client" prompt instead.
4. Run `RUN bundle add rails-ai-context --group development --version '>= 5.35.0'`. If the Gemfile already lists it, run `RUN bundle update rails-ai-context --conservative` instead. Then `RUN bundle exec rails-ai-context version` must print 5.35.0 or newer; if it is older, the Gemfile pins it: change its rails-ai-context line to `gem "rails-ai-context", ">= 5.35.0", group: :development` and run the update again. Check that Gemfile and Gemfile.lock changed in this folder too. If they did not, the image copies the code in at build time instead of mounting this folder, and this setup cannot work: stop and tell me.
5. Run `RUN bundle exec rails generate rails_ai_context:install --tools TOOL --defaults`.
6. The MCP config it wrote starts `bundle exec rails-ai-context serve`, which only works inside the container. Change the rails-ai-context entry in TOOL's MCP config so its command runs there: the command is `docker` and the args are RUN's words after `docker` followed by `bundle exec rails-ai-context serve` (for example `["exec", "-i", "my-app-web-1", "bundle", "exec", "rails-ai-context", "serve"]`). For copilot, change it in both .vscode/mcp.json and .github/mcp.json. In opencode.json the command is one array that starts with "docker". In .codex/config.toml set `command = "docker"` and the same `args`. Keep Compose's `-T` and plain Docker's `-i`, and never add a lowercase `-t`: a terminal mangles the MCP messages.
7. Check the new command by hand: pipe `{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"check","version":"1"}}}` into it on this machine and confirm it prints a JSON result with a serverInfo.
8. Whenever you run a rails-ai-context command yourself, run it as `RUN bundle exec rails-ai-context tool NAME`.
9. Tell me which files changed and the "Next step" lines the install printed for TOOL. Remind me that the container must be running before I start you. The install keeps an entry whose command it did not write, so the Docker entry stays through later installs and context runs.
```

### Another MCP client

For a client the gem writes no config file for: Claude Desktop, Windsurf, Zed, a JetBrains IDE. Such a client starts servers from its own folder, so the entry names everything by its full path.

```text
Set up rails-ai-context for an MCP client it writes no config file for: <name the client, e.g. Claude Desktop, Windsurf, Zed, a JetBrains IDE>.

1. Run `ruby -v`. rails-ai-context needs Ruby 3.1+. If it is older, stop and tell me.
2. If the Gemfile lists rails-ai-context, run `bundle update rails-ai-context --conservative` and use `bundle exec rails-ai-context` as the command in step 3. Otherwise run `gem install rails-ai-context -v '>= 5.35.0'` and use `rails-ai-context`.
3. Run `rails-ai-context mcp-entry` (or `bundle exec rails-ai-context mcp-entry`). It prints a server entry with absolute paths, the Ruby to run and the environment it needs, so it starts from whatever folder the client uses. If it says mcp-entry is an unknown command, the version is older than 5.35.0: run `gem install rails-ai-context -v '>= 5.35.0'` and then `rails-ai-context mcp-entry`, which still prints the app's `bundle exec` entry when the Gemfile lists the gem.
4. Find the client's MCP config file. Claude Desktop keeps it at ~/Library/Application Support/Claude/claude_desktop_config.json on macOS and %APPDATA%\Claude\claude_desktop_config.json on Windows; for another client, look up where its MCP servers are configured. Merge the printed rails-ai-context entry into it under the key that client uses for servers (most use mcpServers), keeping every other server. If the file does not exist, create it with the printed JSON.
5. Start the entry once yourself to check it: run its command and args with its env from your home folder, pipe in `{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"check","version":"1"}}}`, and confirm it prints a JSON result with a serverInfo.
6. Tell me to restart the client and look for rails-ai-context in its MCP server list. If this app moves folder or changes Ruby version, run this prompt again.
```

---

## Change it

### Change the setup

Add or drop an AI tool, or move between the three setups. Dropped tools' generated files are removed; anything you wrote stays.

```text
Change how rails-ai-context is set up in this Rails app. What I want: <describe it, e.g. "add Cursor", "drop Copilot", "switch to CLI only", "MCP only, keep my CLAUDE.md", "back to MCP + context files", "add the pre-commit hook">.

If the rails-ai-context entry in my MCP config runs `docker` (this app's Ruby lives in a container), run every Ruby, Bundler and Rails command below inside that container, prefixed the way the entry's args are, and after any install command put the entry's docker command back.

1. If the Gemfile lists rails-ai-context, run `bundle exec rails-ai-context version`; it must print 5.35.0 or newer, the first version with the flags used below. If it is older, run `bundle update rails-ai-context --conservative`, and if it is still older, the Gemfile pins it: change its rails-ai-context line to `gem "rails-ai-context", ">= 5.35.0", group: :development` and run the update again. If the Gemfile does not list it, `rails-ai-context version` must print 5.35.0 or newer; if it is older, run `gem install rails-ai-context -v '>= 5.35.0'`.
2. Read .rails-ai-context.yml (in a folder of apps, any app's: each keeps its own, and they match). `ai_tools` is the current list of AI tools; `tool_mode: cli` means CLI only; `context_files: false` means MCP only; otherwise it is MCP plus context files.
3. Work out the new tool list (keys: claude, cursor, copilot, opencode, codex) and the new setup flag: `--mcp` for MCP plus context files, `--cli` for CLI only, `--mcp-only` for MCP only, or none to keep the current setup.
4. If the Gemfile lists rails-ai-context, run `bundle exec rails generate rails_ai_context:install --tools NEWLIST SETUPFLAG --prune --defaults`. Otherwise run `rails-ai-context init --tools NEWLIST SETUPFLAG --prune --defaults`. NEWLIST is comma-separated. Add `--hook` to the generator command if I asked for the pre-commit hook that checks staged files; a standalone install (`init`) has no hook, so tell me if that is what I have, and if the repository already has a pre-commit hook of its own the install leaves it and says so: tell me that too. `--prune` removes the generated files of any tool dropped from the list, the MCP entries when switching to CLI only, and the generated context files when switching to MCP only; it never removes lines I wrote.
5. If .git/info/exclude lists rails-ai-context files (a private setup), add every new path this change created to it, and restore .gitignore with `git checkout -- .gitignore` if the change touched it.
6. Run `git status` and tell me what was added and what was removed.
7. If a tool was added or the setup now uses MCP, tell me the "Next step" lines the install printed, word for word.
```

### Switch between Gemfile and standalone

```text
Move rails-ai-context in this Rails app <from the Gemfile to standalone | from standalone into the Gemfile>, keeping the same AI tools and setup.

1. Gemfile to standalone: run `gem install rails-ai-context -v '>= 5.35.0'`, then `bundle remove rails-ai-context`, then `rails-ai-context init --defaults`. On a re-run `--defaults` keeps the AI tools and setup already recorded. config/initializers/rails_ai_context.rb does nothing without the gem in the bundle; delete it once you have copied any setting I changed in it into .rails-ai-context.yml (same key names; `custom_tools` has no YAML form, so tell me if it is set).
2. Standalone to Gemfile: run `bundle add rails-ai-context --group development --version '>= 5.35.0'`, then `bundle exec rails-ai-context version`; it must print 5.35.0 or newer, since older versions read `--defaults` as every AI tool. If it is older, the Gemfile pins it: change its rails-ai-context line to `gem "rails-ai-context", ">= 5.35.0", group: :development` and run `bundle update rails-ai-context --conservative`. Then run `bundle exec rails generate rails_ai_context:install --defaults`.
3. Check that every MCP config naming rails-ai-context now starts it the new way: `bundle exec rails-ai-context serve` in the Gemfile, plain `rails-ai-context serve` standalone.
4. Tell me what changed, and that I must restart you to pick up the new MCP command.
```

### Upgrade

```text
Upgrade rails-ai-context in this Rails app and refresh everything it generated. If the rails-ai-context entry in my MCP config runs `docker` (this app's Ruby lives in a container), run every Ruby, Bundler and Rails command below inside that container, prefixed the way the entry's args are, and after any install command put the entry's docker command back.

1. Note the current version: `bundle exec rails-ai-context version` if the Gemfile lists it, else `rails-ai-context version`.
2. Gemfile: run `bundle update rails-ai-context --conservative`, then `bundle exec rails-ai-context version`. If it is older than 5.35.0, the Gemfile pins it: change its rails-ai-context line to `gem "rails-ai-context", ">= 5.35.0", group: :development` and run the update again; older versions read `--defaults` below as every AI tool. Then run `bundle exec rails generate rails_ai_context:install --defaults`. Standalone: `gem update rails-ai-context`, then `rails-ai-context init --defaults`. On a re-run `--defaults` keeps the recorded AI tools and setup, and the install brings the MCP configs and context files up to the new version.
3. Run the version command again.
4. Find the gem's CHANGELOG.md (`gem contents rails-ai-context | grep CHANGELOG`, or under `bundle info rails-ai-context --path`) and summarise the entries between the old and new versions in plain words, flagging anything marked as a change I must act on.
5. Run doctor (`bundle exec rails ai:doctor` or `rails-ai-context doctor`) and report any failing check.
6. Tell me to restart you so the new MCP server version starts.
```

### Fix it

```text
rails-ai-context isn't working right in this Rails app. Find out why and fix it. If the rails-ai-context entry in my MCP config runs `docker` (this app's Ruby lives in a container), run every Ruby, Bundler and Rails command below inside that container, prefixed the way the entry's args are, and after any install command put the entry's docker command back.

1. Check the version: `bundle exec rails-ai-context version` if the Gemfile lists rails-ai-context, else `rails-ai-context version`. If it is older than 5.35.0, upgrade first (`bundle update rails-ai-context --conservative`, or `gem install rails-ai-context -v '>= 5.35.0'`) and check the version again: older versions read `--defaults` in step 5 as every AI tool. If the Gemfile pins it below 5.35.0, change its rails-ai-context line to `gem "rails-ai-context", ">= 5.35.0", group: :development` and run the update again.
2. Run doctor: `bundle exec rails ai:doctor` if the Gemfile lists the gem, else `rails-ai-context doctor`. Read every failing or warning check and do what each one says.
3. If doctor itself cannot run because the app won't boot, run `bundle exec rails-ai-context tool onboard --no-boot` (or without bundle exec when standalone) to confirm the tools still answer from source, and tell me what stops the boot.
4. If my MCP tools are missing, open the MCP config file of the AI tool you are (Claude Code .mcp.json, Cursor .cursor/mcp.json, GitHub Copilot .vscode/mcp.json and .github/mcp.json, OpenCode opencode.json, Codex CLI .codex/config.toml) and check it has a rails-ai-context entry. Run that entry's command and args by hand with `--help` added at the end, for example `bundle exec rails-ai-context serve --help`, and check it prints the serve usage. With the Claude Code plugin (rails-ai-context@rails-ai-context enabled in .claude/settings.json, .claude/settings.local.json or my user settings, or doctor names the plugin) there is no entry: where its server has no tools, its instructions in your context say why and what to run; where /mcp lists it as failed, ask me to start `claude --debug` and read that server's stderr. `ruby -S gem list rails-ai-context` run here shows the versions the `ruby` Claude Code starts has.
5. If doctor named a missing or broken MCP config, missing context files, or a Codex entry with Ruby paths an earlier release saved, repair the install by running it again: `bundle exec rails generate rails_ai_context:install --defaults` if the Gemfile lists the gem, otherwise `rails-ai-context init --defaults`. On a re-run `--defaults` keeps the recorded AI tools and setup, keeps what exists and adds what is missing. For Codex CLI it also replaces an entry that saved this machine's Ruby paths with one that passes them from the shell.
6. Tell me what was wrong, what you changed, and the "Next step" lines the install printed if I need to do one.
```

### Uninstall

Removes everything the gem wrote and nothing you wrote: your part of a shared `CLAUDE.md` stays, other servers in an MCP config stay, a pre-commit hook you edited stays.

```text
Remove rails-ai-context from this Rails app completely. If the rails-ai-context entry in my MCP config runs `docker` (this app's Ruby lives in a container), run steps 1 and 3 inside that container, prefixed the way the entry's args are.

1. Run `bundle exec rails-ai-context uninstall` if the Gemfile lists rails-ai-context, else `rails-ai-context uninstall`. If the command is missing or unknown, run `gem install rails-ai-context -v '>= 5.35.0'` and then `rails-ai-context uninstall`. If its output names the Claude Code plugin, run the commands it names for it; if it does not, but rails-ai-context@rails-ai-context is enabled in .claude/settings.json, .claude/settings.local.json or my user settings, run `claude plugin disable rails-ai-context@rails-ai-context --scope local` here.
2. If its output names a config/routes.rb line that mounts RailsAiContext::Engine, delete that line.
3. If the Gemfile lists rails-ai-context, run `bundle remove rails-ai-context`.
4. If .git/info/exclude lists rails-ai-context files (a private setup), delete those lines. If I added a rails-ai-context entry to another MCP client's own config (Claude Desktop, Windsurf, Zed and the like), remove that entry there too.
5. Run `git status` and `grep -rn "rails-ai-context\|rails_ai_context\|RailsAiContext" --exclude-dir=.git --exclude-dir=node_modules --exclude-dir=tmp --exclude-dir=log .` and show me anything left. Leave lines I wrote; ask me about anything you are unsure of.
6. Tell me to restart you so the MCP server stops.
```

---

## Prompts for daily work

These work in any setup. With MCP connected the AI tool calls the `rails_*` tools; in the CLI setup it runs the same tools as shell commands (`bundle exec rails-ai-context tool NAME`, or `rails-ai-context tool NAME` standalone). The tool names below are the CLI short names; the MCP name adds `rails_` and, for most, `get_` (`schema` is `rails_get_schema`).

### Learn this app

```text
Get to know this Rails app before we change anything. Use rails-ai-context: the rails_* MCP tools if you have them, otherwise run `bundle exec rails-ai-context tool NAME` (or `rails-ai-context tool NAME` without bundle exec if the Gemfile doesn't list the gem).

Run onboard, then conventions, then schema with detail summary and routes with detail summary. Tell me in under 20 lines: what the app does, its main models and how they relate, how requests are authenticated, the test framework and how tests are written, and anything unusual you noticed. Name only things the tools showed you.
```

### Ground rules for this session

For an MCP-only or CLI setup, where no context file carries these rules.

```text
For the rest of this session, use rails-ai-context as your source of truth about this Rails app: the rails_* MCP tools if you have them, otherwise `bundle exec rails-ai-context tool NAME` (or `rails-ai-context tool NAME` without bundle exec).

1. Before writing code that names a column, association, route, helper, method, class, partial or gem, confirm it with a tool call in this turn.
2. Before editing a method, run search_code with match_type trace on it to see its definition, callers and tests.
3. Before editing a controller action, run controllers for it to see inherited filters and strong params.
4. Mark anything you did not confirm with [ASSUMPTION].
5. Treat empty output as a finding to investigate, not a green light.
6. After you write files, query again: earlier answers are stale.
Reply "ok" and wait for my first task.
```

### Add a feature safely

```text
I want to add: <describe the feature>.

Use rails-ai-context (rails_* MCP tools, or `bundle exec rails-ai-context tool NAME` in a shell) before writing anything:
1. analyze_feature for the area this touches.
2. schema for every table involved, and model_details for every model involved.
3. migration_advisor for any column or table change, so we don't duplicate a column that exists under another name.
4. conventions, so the code matches this app's patterns.
Then show me a short plan naming the exact files, columns and associations, all confirmed by those calls. Wait for my OK before editing.
```

### Trace and change a method

```text
I want to change <method or constant name>.

Run rails-ai-context's search_code with pattern set to that name and match_type trace (rails_search_code over MCP, or `bundle exec rails-ai-context tool search_code --pattern NAME --match-type trace` in a shell). Show me its definition, every caller grouped by file, and the tests that cover it. Then tell me what would break if its signature or return value changed, before you edit anything.
```

### Fix a bug

```text
This is broken: <paste the error, failing test or wrong behaviour>.

Use rails-ai-context's diagnose tool with that error first (rails_diagnose over MCP, or `bundle exec rails-ai-context tool diagnose --error "..."` in a shell), then read_logs for recent errors, then controllers or model_details for the code it points at. Tell me the root cause with the file and line, and the smallest fix. Write a failing test first if the app has a test suite, then fix it.
```

### Write tests the way this app does

```text
Write tests for <file, class or feature>.

First run rails-ai-context's test_info (rails_get_test_info, or `bundle exec rails-ai-context tool test_info`) to see the framework, fixtures or factories, and helpers this app uses. Then run generate_test for the target. Write the tests in the same style as the existing ones, run them, and show me the result.
```

### Check my changes before I commit

```text
Review my uncommitted changes with rails-ai-context before I commit.

Run review_changes, then validate on every changed Ruby, ERB and JavaScript file, then security_scan (rails_* MCP tools, or `bundle exec rails-ai-context tool NAME` in a shell; security_scan needs the brakeman gem and says so if it is missing). List real problems first with file and line, then anything worth a second look. Don't change code until I say which ones to fix.
```

---

## How the prompts stay safe to paste

- **Every answer is a flag.** `--tools`, `--mcp`, `--cli`, `--mcp-only`, `--prune` and `--defaults` answer each question the install would ask, so nothing waits on a keyboard. `--defaults` answers whatever no flag did.
- **A bad flag changes nothing.** A misspelled tool name, or `--cli` with `--mcp-only`, stops the install before it writes a file.
- **Only `--prune` deletes.** Running an install prompt twice is safe: it keeps what exists and adds what is missing. Removing a dropped tool's files takes `--prune`, and even then a file you wrote, or your lines in a shared one, stay.
- **Your own context files are fenced.** In a `CLAUDE.md` or `AGENTS.md` you wrote, the gem only touches the block between its `<!-- BEGIN rails-ai-context -->` and `<!-- END rails-ai-context -->` markers.
- **Tool names never change meaning.** `--tools` takes names (`claude`, `cursor`), never menu numbers, so a prompt saved today still picks the same tool after a release adds one.

Every flag is in the [CLI reference](CLI.md#init-standalone-only) and [What the install generator does](GUIDE.md#what-the-install-generator-does).

---

<div align="center" markdown="1">

**[← Quickstart](QUICKSTART.md)** · **[AI tool setup →](SETUP.md)**

[Back to Home](index.md)

</div>
