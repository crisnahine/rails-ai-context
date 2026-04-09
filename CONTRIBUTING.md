# Contributing to rails-ai-context

Thanks for your interest in contributing! This guide covers everything you need to get started.

## Development Setup

```bash
git clone https://github.com/crisnahine/rails-ai-context.git
cd rails-ai-context
bundle install
bundle exec rspec
bundle exec rubocop --parallel
```

The test suite uses [Combustion](https://github.com/pat/combustion) to boot a minimal Rails app in `spec/internal/`. No external database required — tests run against an in-memory SQLite database.

## Project Structure

```
lib/rails_ai_context/
├── cli/               # CLI tool runner (tool_runner.rb) — executes MCP tools from rake/Thor
├── introspectors/     # 31 introspectors (schema, models, routes, etc.)
├── tools/             # 38 MCP tools with detail levels and pagination
├── serializers/       # Per-assistant formatters + shared ToolGuideHelper
├── server.rb          # MCP server setup (stdio + HTTP)
├── live_reload.rb     # MCP live reload (file watcher + cache invalidation)
├── engine.rb          # Rails Engine for auto-integration
└── configuration.rb   # User-facing config (presets, context_mode, tool_mode, limits)
```

## Adding a New Introspector

1. Create `lib/rails_ai_context/introspectors/your_introspector.rb` (auto-loaded by Zeitwerk)
2. Implement `#initialize(app)` and `#call` → returns a Hash (never raises)
3. Register it in `lib/rails_ai_context/introspector.rb` (the `INTROSPECTOR_MAP`)
4. Add the key to the appropriate preset(s) in `Configuration::PRESETS` (`:full` is the default, `:standard` for core-only)
5. Write specs in `spec/lib/rails_ai_context/your_introspector_spec.rb`

## Adding a New MCP Tool

1. Create `lib/rails_ai_context/tools/your_tool.rb` inheriting from `BaseTool` (auto-loaded by Zeitwerk)
2. Define `tool_name`, `description`, `input_schema`, and `annotations`
3. Implement `def self.call(...)` returning `text_response(string)`
4. Auto-registered — no manual list to update (BaseTool.inherited tracks it)
5. Write specs in `spec/lib/rails_ai_context/tools/your_tool_spec.rb`

## Adding a Prism Listener

Listeners extract specific concerns (associations, validations, etc.) from the AST via `Prism::Dispatcher` events.

1. Create `lib/rails_ai_context/introspectors/listeners/your_listener.rb` inheriting from `BaseListener`
2. Implement `on_call_node_enter(node)` and/or `on_def_node_enter(node)` — only the events your concern needs
3. Use `confidence_for(node)` from `BaseListener` to tag results `[VERIFIED]` or `[INFERRED]`
4. Store results in `@results` (accessed via `#results`)
5. Register the key/class pair in `SourceIntrospector::LISTENER_MAP`
6. Write specs in `spec/lib/rails_ai_context/introspectors/listeners/your_listener_spec.rb`

See existing listeners in `lib/rails_ai_context/introspectors/listeners/` for reference patterns.

## Adding a CLI Tool Interface

The `ToolRunner` (`lib/rails_ai_context/cli/tool_runner.rb`) handles CLI execution of all MCP tools. It is tested in `spec/lib/rails_ai_context/cli/tool_runner_spec.rb`. If you add a new MCP tool, it is automatically available via CLI — no extra registration needed. Tool name resolution (`schema` → `get_schema` → `rails_get_schema`) works for all tools.

## Code Style

- Follow `rubocop-rails-omakase` style (run `bundle exec rubocop`)
- Ruby 3.2+ features welcome (pattern matching, etc.)
- Every introspector must return a Hash and never raise — wrap errors in `{ error: msg }`
- MCP tools return `MCP::Tool::Response` objects
- All tools must be prefixed with `rails_` and annotated as read-only

## Running Tests

```bash
bundle exec rspec              # Full test suite
bundle exec rspec spec/lib/    # Just lib specs
bundle exec rubocop --parallel # Lint check
```

## Pull Request Process

1. Fork the repo and create your branch from `main`
2. Add tests for any new functionality
3. Ensure `bundle exec rspec` and `bundle exec rubocop` pass
4. Update CHANGELOG.md under an `## [Unreleased]` section
5. Open a PR with a clear title and description

## Reporting Bugs

Open an issue at https://github.com/crisnahine/rails-ai-context/issues with:
- Ruby and Rails versions
- Gem version
- Steps to reproduce
- Expected vs actual behavior
