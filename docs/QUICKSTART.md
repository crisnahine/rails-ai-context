<div align="center" markdown="1">

# Quickstart

**Get AI context for your Rails app in under 5 minutes.**

[Tools Reference](TOOLS.md) · [Recipes](RECIPES.md) · [Configuration](CONFIGURATION.md) · [FAQ](FAQ.md)

</div>

---

## Option A: In your Gemfile (recommended)

```bash
# 1. Add the gem
bundle add rails-ai-context --group development

# 2. Run the install generator
rails generate rails_ai_context:install
```

The generator asks two questions:

1. **Which AI tools do you use?** - Claude Code, Cursor, GitHub Copilot, OpenCode, Codex CLI, or all. There is no "none" choice: an empty answer, or one with no valid number, selects all five.
2. **What should rails-ai-context write?** - MCP config + context files (default), context files only (CLI mode), or MCP config only

The third answer is MCP-only: the server and the CLI answer in full, and your
own `CLAUDE.md`, `AGENTS.md` and rules files are left alone. Non-interactively
that is `--mcp-only`.

Three more prompts appear only when they apply:

- **Remove their generated files?** - on a re-run that drops a tool you picked before. Default: keep them. A yes removes only what the gem generated, never a rule file or a line you wrote.
- **Install a pre-commit hook that checks staged Ruby and ERB files for syntax errors?** - in a git repo that has no pre-commit hook yet. Default: no.
- **Delete them?** - in a terminal, when rule files left over from before v5.0.0 are found. Default: no.

`--defaults` skips every prompt and takes each default: all five tools, keep the files, MCP config + context files, no hook, keep legacy files. Every step is listed in [What the install generator does](GUIDE.md#what-the-install-generator-does).

That's it. Your AI tool now has live access to your schema, models, routes, controllers, views, and conventions.

> [!TIP]
> The generator is idempotent - re-running it preserves existing config and only adds new sections.

## Option B: Standalone (no Gemfile entry)

```bash
# 1. Install the gem globally
gem install rails-ai-context

# 2. Navigate to your Rails app
cd your-rails-app

# 3. Run interactive setup
rails-ai-context init

# 4. Start the MCP server
rails-ai-context serve
```

`init` asks the same two questions, and the cleanup and legacy-file prompts when they apply. It has no pre-commit hook prompt and no `--defaults` flag, and it does not create `config/initializers/rails_ai_context.rb`.

Works with every Ruby version manager (rbenv, rvm, asdf, mise, chruby, system). [Learn more about standalone mode →](STANDALONE.md)

## What just happened?

The install generator created:

| File | Purpose |
|:-----|:--------|
| `.mcp.json` / `.cursor/mcp.json` / `.vscode/mcp.json` / `opencode.json` / `.codex/config.toml` | MCP auto-discovery - your AI tool detects these on project open |
| `CLAUDE.md` + `.claude/rules/` / `.cursor/rules/` + `.cursorrules` / `.github/copilot-instructions.md` + `.github/instructions/` / `AGENTS.md` | Static context rules your AI reads |
| `.ai-context.json` | The same context as JSON (added to `.gitignore`) |
| `config/initializers/rails_ai_context.rb` | All configuration options |
| `.rails-ai-context.yml` | Your tool selection, and the config file for standalone mode |

## Verify it works

```bash
# Check AI readiness
rails ai:doctor          # In-Gemfile
rails-ai-context doctor  # Standalone

# Try a tool
rails 'ai:tool[schema]' table=users
rails 'ai:tool[model_details]' model=User
rails 'ai:tool[routes]' controller=users
```

## See it work

> [!IMPORTANT]
> These are CLI commands. When MCP is connected, your AI calls the same tools automatically - you never type these manually.

Three commands that show immediate value:

```bash
# 1. Trace a method across your entire codebase - one call
rails 'ai:tool[search_code]' pattern="your_method_name" match_type=trace

# 2. Full-stack feature analysis - models + controllers + routes + tests
rails 'ai:tool[analyze_feature]' feature=auth

# 3. Get your app's actual conventions - not generic Rails patterns
rails 'ai:tool[conventions]'
```

## What to do next

1. **Open your project** in your AI tool - MCP auto-discovery kicks in
2. **Ask your AI** to describe your User model - it will call `rails_get_model_details` instead of guessing
3. **Read [Recipes](RECIPES.md)** for real-world workflows that show the tools in action

## Quick reference

| In-Gemfile | Standalone | What it does |
|:-----------|:-----------|:------------|
| `rails ai:serve` | `rails-ai-context serve` | Start MCP server |
| `rails 'ai:tool[NAME]'` | `rails-ai-context tool NAME` | Run any tool |
| `rails ai:tool` | `rails-ai-context tool --list` | List all tools |
| `rails ai:doctor` | `rails-ai-context doctor` | Diagnostics |
| `rails ai:watch` | `rails-ai-context watch` | Auto-regenerate on change |
| `rails ai:context` | `rails-ai-context context` | Regenerate context files |

---

<div align="center" markdown="1">

**Next:** [Tools Reference →](TOOLS.md)

[Back to Home](index.md)

</div>
