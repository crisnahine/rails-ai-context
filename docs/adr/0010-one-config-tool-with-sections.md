# One config tool with sections

Status: accepted

Eleven tools each read one payload section and take no target: `rails_get_config`, `_autoload`, `_engines`, `_active_support`, `_conventions`, `_gems`, `_frontend_stack`, `_api`, `_env`, `_env_config` and `_i18n`. Every one costs a full definition in `tools/list` on every turn: together about 8,800 characters, or a fifth of what all 45 cost before this decision. A client reads that list whether or not the app's configuration is asked about.

## Decision

- `rails_get_config` takes a `section`: `app` (the default, and what the tool answered before: database, auth, assets, cache, queue, Action Cable, initializers, middleware), `gems`, `frontend`, `api`, `engines`, `conventions`, `autoload`, `active_support`, `env`, `env_config` and `i18n`. The other ten tools leave `tools/list`.
- The old names keep working wherever a name is typed:
  - the CLI resolves `gems`, `rails_get_gems`, `frontend_stack` and the rest to their section;
  - the MCP server answers a call to a retired name from its section and says which call to make instead.
- `skip_tools` naming one of the eleven old tools turns its section off; `rails_get_config` names the `app` section. A skip that hid the process environment keeps hiding it after an upgrade, and a skip that hid the overview still hides only the overview. The tool leaves `tools/list` only when every section is off.
- Each section's parameters ride on the one tool (`detail`, `category`, `offset`, `limit`, `environment`, `locale`). A parameter the asked section does not read is named in the answer, never dropped silently.
- The ten classes stay in the gem as the sections' renderers. Ruby that calls `RailsAiContext::Tools::GetGems.call` keeps working; only the MCP surface changes.

## Consequences

Removing ten tools from `tools/list` breaks a client prompt that names them, so the change ships in a major version, with migration notes. The section names are public interface from here on, like the tool names before them: renaming one keeps the old name as an alias.

## Alternatives not taken

- **Keeping the ten tools beside the new section argument**: the definitions are the cost being removed.
- **A new tool name such as `rails_get_stack`**: `rails_get_config` already answered the default section, so its callers see no change.
- **Splitting into two tools (stack and configuration)**: two definitions where one carries the same sections, and a line between the two that every reader would have to learn.
