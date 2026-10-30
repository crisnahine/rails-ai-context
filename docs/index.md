# rails-ai-context documentation

**35 read-only tools that give your AI coding assistant live access to your Rails app.**

Works with Claude Code, Cursor, GitHub Copilot, OpenCode and Codex CLI, over MCP or the command line.
[The website](https://crisnahine.github.io/rails-ai-context/) is the short tour; the pages below are
the reference.

## Getting started

| Guide | What it covers |
|:------|:---------------|
| **[Copy-paste prompts](PROMPTS.md)** | Paste one into your AI tool and it installs, changes, removes or uses the gem |
| **[Quickstart](QUICKSTART.md)** | Up and running in 5 minutes |
| **[AI tool setup](SETUP.md)** | Claude Code, Cursor, Copilot, OpenCode, Codex CLI, the HTTP transport, other MCP clients |
| **[Standalone mode](STANDALONE.md)** | Use without a Gemfile entry |

## Reference

| Guide | What it covers |
|:------|:---------------|
| **[Tools reference](TOOLS.md)** | All 35 tools with every parameter |
| **[Configuration](CONFIGURATION.md)** | Every option with its default |
| **[CLI reference](CLI.md)** | Commands, flags and argument syntax |
| **[Introspectors](INTROSPECTORS.md)** | All 40 introspectors and the AST engine |
| **[Complete guide](GUIDE.md)** | Every command, parameter and option in one file |

## Learn

| Guide | What it covers |
|:------|:---------------|
| **[Recipes](RECIPES.md)** | Real workflows, end to end |
| **[Custom tools](CUSTOM_TOOLS.md)** | Build and test your own tools |
| **[Architecture](ARCHITECTURE.md)** | System design and internals |
| **[FAQ](FAQ.md)** | Frequently asked questions |

## Safety and support

| Guide | What it covers |
|:------|:---------------|
| **[Security model](SECURITY.md)** | SQL safety layers and file blocking |
| **[Compatibility](COMPATIBILITY.md)** | Supported versions, operating tiers, app shape matrix |
| **[Troubleshooting](TROUBLESHOOTING.md)** | Common problems and fixes |

The decisions behind the design, each with its reason, are in [docs/adr](https://github.com/crisnahine/rails-ai-context/tree/main/docs/adr).

---

[GitHub repository](https://github.com/crisnahine/rails-ai-context) · [RubyGems](https://rubygems.org/gems/rails-ai-context) · [Changelog](../CHANGELOG.md) · [MCP Registry](https://registry.modelcontextprotocol.io)
