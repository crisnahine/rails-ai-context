# Context

Terms this project uses in a narrower sense than everyday English. One entry per term that has caused a naming collision or an ambiguous read.

## Environment

Overloaded. Always qualify it; never use "environment" bare in a tool name, an introspector name, or a config key.

**Process environment** - the environment variables a running app sees, plus the places they are declared (`ENV[]` call sites, `.env.example`, Dockerfile, credentials keys). Served by `rails_get_env`, read by `EnvIntrospector`.

**Environment config** - what `config/environments/*.rb` declares per environment: the assigned `config.*` keys and the values of the notable toggles. Served by `rails_get_env_config`, read by `EnvConfigIntrospector`.

**Environment** (unqualified, as data) - a single named Rails environment: development, production, staging. This is the only sense in which the bare word is allowed, and only as a value, never as a name. The `:environments` payload key means "the list of these", which is why it kept its name when the introspector was renamed.

## AI tool

The assistant a user points at their app: claude, cursor, copilot, opencode, codex. What the gem generates for one is its **context files** (`CLAUDE.md`, `.cursor/rules/*.mdc`, and so on).

Avoid "format" for either sense - claude is not a file format, and the word collides with real formatting elsewhere in the code. The public config key `ai_tools` already uses the canonical term.

`Install::AiTool` is the one table of what each means: name, context files, MCP config shape, legacy leftovers. `Install::SelectionRecord` owns which ones the user picked - written to YAML always and to the initializer line inside a Rails app, read initializer-first because that is the file a user hand-edits.

## Static tier

The mode where the app did not boot, or `--no-boot` was passed. What an introspector answers here is what it declared, never what a runtime check happened to detect. Every introspector in `INTROSPECTOR_MAP` extends `StaticTier` and names one of three kinds:

**files-only** - `call` runs unchanged against the static app handle, because it only ever read files. Most of the map.

**alternate-source** - `static_call` answers from a different source than `call` does: `db/schema.rb` instead of the connection, `config/routes.rb` instead of the route set.

**runtime-only** - needs `app.config`, `app.routes` or a live database, and refuses honestly.

An undeclared introspector fails the suite, and every files-only declaration is proven against `spec/fixtures/static_app` with nothing booted. Declaring files-only while defining `static_call` (or the reverse) is also a spec failure.
