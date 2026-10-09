# A workspace's MCP entries name their app by a relative path

Status: accepted

`rails-ai-context init` run in a folder of apps (a workspace, see `CONTEXT.md`) writes one server per app into the folder's own MCP configs (#429). Those files may be committed, so each entry has to find its app on any machine, and an AI tool gives a stdio server nothing to find it with but the command line, the environment and the directory it starts the server in.

## What the tools do

Checked against each tool's documentation and source in October 2026:

| Tool | Starts the server in | Names the config's folder |
|------|----------------------|---------------------------|
| Claude Code (`.mcp.json`) | the folder it was launched in; it also reads a `.mcp.json` above that folder | no; no `cwd` key either |
| Codex CLI (`.codex/config.toml`) | its session directory | no; a `cwd` key, itself relative to the session directory |
| OpenCode (`opencode.json`) | the folder it was opened in | no; a `cwd` key only from v1.17.4, and older versions reject unknown keys |
| VS Code (`.vscode/mcp.json`) | the workspace folder | `${workspaceFolder}` |
| Cursor (`.cursor/mcp.json`) | undocumented; users report `/` or `~` | `${workspaceFolder}`, the folder holding `.cursor/` |

## Decision

- `--app-path` and an in-Gemfile app's `BUNDLE_GEMFILE` are written relative to the workspace. Where the tool names its config's folder (Cursor, VS Code: `AiTool`'s `folder_variable`), they start from that name; elsewhere they are bare relative paths, which those tools resolve against the folder they were started in. An absolute path would hold only on the machine that wrote it.
- Each app keeps its own install form: the bare binary for a standalone app, `bundle exec` for an in-Gemfile one, decided from that app's own Gemfile.lock (or its Gemfile, before the bundle is installed) rather than the process's bundle.
- A re-run writes the current set: an entry of the gem's for an app that is gone is dropped, and so is one under a name the gem gave an app that a twin's arrival renamed. An entry counts as the gem's by its name and by running `rails-ai-context serve`; a second entry named by hand for an app, or one naming an app outside the folder, is left as somebody's own.
- Each entry is `rails-ai-context-<app folder>` and announces `<app folder>-rails-ai-context`, through the `RAILS_AI_CONTEXT_SERVER_NAME` environment variable rather than a flag: an app whose bundle pins an older gem ignores an unknown variable and starts, where an unknown flag would stop it. The variable only takes the place of the default name, so a `server_name` the app configured wins. VS Code names every tool after the announced name, sanitised and cut to 13 characters, so a name that starts with the gem's would give every app's tools the same `mcp_rails-ai-cont_` prefix and leave the model unable to tell them apart. Names are capped at 30 characters (a hash keeps a longer one unique): Cursor drops a tool whose server and tool names together pass 60, Codex up to v0.100 capped `mcp__<server>__<tool>` at 64, and the longest built-in tool name is 27.

## Consequences

The entries work when the tool is started in the workspace folder, which is the setup they are written for. A tool started inside one of the apps that still reads the workspace's config (Claude Code, Codex, OpenCode) starts each server there, where a relative path misses. The binary then names the folder the path was written for instead of guessing a different app; an in-Gemfile entry fails earlier, in Bundler, before the gem runs. An app opened on its own gets its own config from `init` run inside it.

Every server in a workspace runs under the Ruby the tool resolves in the workspace folder, which a version manager picks by that folder, not by the app. `init` warns when an app declares another; a standalone app that cannot boot under it answers from the static tier, and an in-Gemfile entry may not start.

## Alternatives not taken

- **Absolute paths**: correct on one machine, wrong in every clone.
- **A `cwd` key per entry**: Claude Code has none, OpenCode's breaks its older versions, and Codex's is relative to the same directory a bare path already is.
- **Walking up for a relative `--app-path` that misses**: it would make the binary's `--app-path` mean different things in different directories, and would still leave `bundle exec` entries failing before the gem runs.
- **Re-launching an in-Gemfile app's server from inside the app** (the global binary resolving the app, then `exec`ing `bundle exec` there): it fixes the Ruby choice, but needs the binary installed outside every bundle, cannot `exec` in place on Windows, and fights Codex's environment snapshot, which pins the Ruby `init` ran under.
