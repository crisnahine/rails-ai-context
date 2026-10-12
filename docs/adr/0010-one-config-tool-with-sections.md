# One config tool with sections

Status: accepted

Eleven tools each read one payload section and take no target: `rails_get_config`, `_autoload`, `_engines`, `_active_support`, `_conventions`, `_gems`, `_frontend_stack`, `_api`, `_env`, `_env_config` and `_i18n`. Every one costs a full definition in `tools/list` on every turn: together about 8,800 characters, or a fifth of what all 45 cost before this decision. A client reads that list whether or not the app's configuration is asked about.

## Decision

- `rails_get_config` takes a `section`: `app` (the default, and what the tool answered before: database, auth, assets, cache, queue, Action Cable, initializers, middleware), `gems`, `frontend`, `api`, `engines`, `conventions`, `autoload`, `active_support`, `env`, `env_config` and `i18n`. The other ten tools leave `tools/list`.
- The old names keep working wherever a name is typed:
  - the CLI resolves `gems`, `rails_get_gems`, `frontend_stack` and the rest to their section;
  - the MCP server answers a call to a retired name from its section and says which call to make instead, with the arguments that section reads.
- `skip_tools` naming one of the ten retired tools turns its section off, and `rails_get_config` turns off the `app` section. A skip that hid the process environment keeps hiding it after an upgrade, and a skip that hid the overview still hides only the overview. The tool leaves `tools/list` only when every section is off.
- With `app` off there is no default, so `section` is required: the published schema and the description say so, and a call with none is answered with the sections that are on.
- A custom tool named `rails_get_config` takes the built-in's place when `skip_tools` lists that name, as a custom tool takes any skipped built-in's. The ten sections go with the built-in, and a retired name is then an unknown tool.
- A custom tool that reuses a retired name is served as its own tool. The gem's own hints still mean the built-in section.
- Each section's parameters ride on the one tool (`detail`, `category`, `offset`, `limit`, `environment`, `locale`). A parameter the asked section does not read is named in the answer as ignored.
- The ten classes stay in the gem as the sections' renderers. Ruby that calls `RailsAiContext::Tools::GetGems.call` keeps working; only the MCP surface changes.

## Consequences

The change ships in 5.35.1, with migration notes. That number was the maintainer's choice, made outside the rule in `docs/RELEASING.md` step 1, which rules out a patch number for a release with an Added entry or a Changed entry a consumer can observe. What makes it tenable is that every retired name still answers on the CLI and over MCP, with a line naming the new call, so a prompt or a script that names one keeps working.

The removal shows wherever tool names are listed or reported. `tools/list` and `tool --list` hold 35 names. The CLI's `--json` output reports `rails_get_config` for a retired name. `Tools::BaseTool.registered_tools` no longer lists the ten classes. The session context records a section call under the new name.

The section names are public interface from here on, like the tool names before them: renaming one keeps the old name as an alias.

## Alternatives not taken

- **Keeping the ten tools beside the new section argument**: the definitions are the cost being removed.
- **A new tool name such as `rails_get_stack`**: `rails_get_config` already answered the default section, so its callers see no change.
- **Splitting into two tools (stack and configuration)**: two definitions where one carries the same sections, and a line between the two that every reader would have to learn.
