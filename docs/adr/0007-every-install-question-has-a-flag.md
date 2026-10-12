# Every install question has a flag, and only --prune removes files

Status: accepted

People install the gem by pasting a prompt into their AI tool, which runs the install in its own shell. That shell has no one at the keyboard. Claude Code and Codex give a command no terminal, so a question reads end of file and takes its default; Cursor and VS Code run commands in a terminal where a question waits forever. Before this, `init` and the install generator could not pick the AI tools or the CLI setup from the command line, so an AI tool either got all five tools in the MCP setup or had to pipe numbered answers whose order shifts with the questions a given run asks.

## Decision

- Every question the install asks has a flag: `--tools` (the AI tools), `--mcp`, `--cli` or `--mcp-only` (the **setup**), `--prune` (yes to every removal question: a dropped tool's files, the gem's MCP entries on a switch to the CLI setup, the generated context files on a switch to the MCP-only setup, legacy files), `--hook` (the pre-commit hook, generator only), and `--defaults` to answer whatever no flag answered. `init` takes the same names, all but `--hook`, since it offers no hook.
- A default is what the app has. On a re-run `--defaults`, like an empty answer, keeps the recorded AI tools and setup; on a first install it is all five tools and the MCP setup. A prompt that repairs an install runs it again with `--defaults` and changes nothing it did not mean to.
- `--tools` takes the tool keys (`claude,cursor`) or `all`, never menu numbers. A number names a different tool once one is added to the menu, and a prompt pasted from an old README must not set up the wrong tool.
- Flags are read before anything is asked or written. A name that is no tool, two setup flags at once, or a flag the command does not have exits 1 with nothing changed. Rails drops a generator option it does not know, so the generator checks for them itself: a prompt pasted against an older copy then fails loudly instead of running an install nobody asked for.
- `--defaults` never removes anything: every removal question defaults to keep. Removal needs `--prune`, so a prompt that only meant "set it up again" cannot delete files.
- `uninstall` lives in the binary only, which both installs carry (`bundle exec rails-ai-context uninstall` in the Gemfile). It removes what the gem wrote and nothing the user wrote: the user's part of a shared `CLAUDE.md`, other servers in an MCP config, and a pre-commit hook changed by hand all stay. Its own config files go even when edited, and so does an HTTP entry under the gem's name, which nothing answers once the gem is gone. A `mount RailsAiContext::Engine` line is named, not edited, since routes are the app's code.

## Consequences

An install prompt is a fixed command line per scenario, and the install behaves the same in every AI tool's shell. The flags are public interface: renaming one breaks prompts already pasted into READMEs and team wikis, so a rename keeps the old name as an alias.

## Alternatives not taken

- **Reading answers from piped stdin**: the number and order of questions depends on the run (a re-run asks about dropped tools, a git repo without a hook asks about the hook), so a fixed pipe answers the wrong question.
- **An environment variable per answer**: invisible in the command line a user reviews before letting the AI tool run it.
- **`--defaults` removing dropped tools' files**: shorter prompts, but a default that deletes is the one a pasted prompt can trigger by accident.
- **A `rails destroy rails_ai_context:install` uninstall**: Rails runs a generator's steps in reverse, and this generator's steps ask questions and merge files rather than create them, so reversing them does not remove what they wrote.
