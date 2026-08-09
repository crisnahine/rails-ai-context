# Context

Terms this project uses in a narrower sense than everyday English. One entry per term that has caused a naming collision or an ambiguous read.

## Environment

Overloaded. Always qualify it; never use "environment" bare in a tool name, an introspector name, or a config key.

**Process environment** - the environment variables a running app sees, plus the places they are declared (`ENV[]` call sites, `.env.example`, Dockerfile, credentials keys). Served by `rails_get_env`, read by `EnvIntrospector`.

**Environment config** - what `config/environments/*.rb` declares per environment: the assigned `config.*` keys and the values of the notable toggles. Served by `rails_get_env_config`, read by `EnvConfigIntrospector`.

**Environment** (unqualified, as data) - a single named Rails environment: development, production, staging. This is the only sense in which the bare word is allowed, and only as a value, never as a name. The `:environments` payload key means "the list of these", which is why it kept its name when the introspector was renamed.

## Static tier

The mode where the app did not boot, or `--no-boot` was passed. An introspector answers in this tier only if it defines `static_call`. Two shapes count as defining it: reading a different source (parsing `db/schema.rb` instead of querying the connection), and reading the same source a booted app would (a file-based introspector, where `static_call` is the same work under another name).
