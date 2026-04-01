# frozen_string_literal: true

module RailsAiContext
  module Serializers
    # Shared helper for rendering the tool reference section in context files.
    # Reads config.tool_mode to generate MCP syntax, CLI syntax, or both.
    module ToolGuideHelper
      # Returns the tool invocation example for a given tool call.
      # MCP: rails_analyze_feature(feature:"cook")
      # CLI: rails 'ai:tool[analyze_feature]' feature=cook
      def tool_call(mcp_call, cli_call)
        case tool_mode
        when :cli
          "→ `#{cli_call}`"
        when :mcp
          "→ MCP: `#{mcp_call}`\n→ CLI: `#{cli_call}`"
        else
          "→ `#{mcp_call}`"
        end
      end

      def tool_mode
        RailsAiContext.configuration.tool_mode
      end

      def tools_header
        "## Tools (37) — MANDATORY, Use Before Read"
      end

      def tools_intro
        case tool_mode
        when :cli
          [
            "This project has 37 introspection tools. **MANDATORY — use these instead of reading files.**",
            "They return only relevant, structured data and save tokens. Read files ONLY when you are about to Edit them.",
            ""
          ]
        else
          [
            "This project has 37 MCP tools via `rails ai:serve` (configured in `.mcp.json`).",
            "**MANDATORY — use these instead of reading files.** They return structured data and save tokens.",
            "Read files ONLY when you are about to Edit them.",
            "If MCP tools are not connected, use CLI fallback: `#{cli_cmd("TOOL_NAME", "param=value")}`",
            ""
          ]
        end
      end

      def tools_detail_guidance
        detail_param = tool_mode == :cli ? "detail=summary" : "detail:\"summary\""
        [
          "### detail parameter — ALWAYS start with summary",
          "",
          "Most tools accept `#{detail_param}`. Use the right level:",
          "- **summary** — first call, orient yourself (table list, model names, route overview)",
          "- **standard** — working detail (columns with types, associations, action source) — DEFAULT",
          "- **full** — only when you need indexes, foreign keys, code snippets, or complete content",
          "",
          "Pattern: summary to find the target → standard to understand it → full only if needed.",
          ""
        ]
      end

      def tools_power_tool_section
        [
          "### Start here — composite tools save multiple calls",
          "",
          "**New to this project?** Get a full walkthrough first:",
          tool_call("rails_onboard(detail:\"standard\")", cli_cmd("onboard", "detail=standard")),
          "",
          "**`get_context` is your power tool** — bundles schema + model + controller + routes + views in ONE call:",
          tool_call("rails_get_context(controller:\"CooksController\", action:\"create\")", cli_cmd("context", "controller=CooksController action=create")),
          tool_call("rails_get_context(model:\"Cook\")", cli_cmd("context", "model=Cook")),
          tool_call("rails_get_context(feature:\"cook\")", cli_cmd("context", "feature=cook")),
          "",
          "**`analyze_feature` for broad discovery** — scans all layers (models, controllers, routes, services, jobs, views, tests):",
          tool_call("rails_analyze_feature(feature:\"authentication\")", cli_cmd("analyze_feature", "feature=authentication")),
          "",
          "Use individual tools only when you need deeper detail on a specific layer.",
          ""
        ]
      end

      def tools_workflow_section # rubocop:disable Metrics/MethodLength
        [
          "### Step-by-step workflows (follow this order)",
          "",
          "**Modify a model** (add field, change validation, add scope):",
          "1. #{tool_call_inline("rails_get_context", "model:\"Cook\"", "context", "model=Cook")} — schema + associations + validations in one call",
          "2. Read the model file, make your edit",
          "3. #{tool_call_inline("rails_migration_advisor", "action:\"add_column\", table:\"cooks\", column:\"rating\", type:\"integer\"", "migration_advisor", "action=add_column table=cooks column=rating type=integer")} — if schema change needed",
          "4. #{tool_call_inline("rails_validate", "files:[\"app/models/cook.rb\"], level:\"rails\"", "validate", "files=app/models/cook.rb level=rails")} — EVERY time after editing",
          "5. #{tool_call_inline("rails_generate_test", "model:\"Cook\"", "generate_test", "model=Cook")} — generate tests matching project patterns",
          "",
          "**Fix a controller bug:**",
          "1. #{tool_call_inline("rails_get_context", "controller:\"CooksController\", action:\"create\"", "context", "controller=CooksController action=create")} — action source + routes + views + model",
          "2. Read the controller file, make your fix",
          "3. #{tool_call_inline("rails_validate", "files:[\"app/controllers/cooks_controller.rb\"], level:\"rails\"", "validate", "files=app/controllers/cooks_controller.rb level=rails")}",
          "",
          "**Build or modify a view:**",
          "1. #{tool_call_inline("rails_get_design_system", "detail:\"standard\"", "design_system", "detail=standard")} — get copy-paste HTML/ERB patterns",
          "2. #{tool_call_inline("rails_get_view", "controller:\"cooks\"", "view", "controller=cooks")} — existing templates, partials, Stimulus refs",
          "3. #{tool_call_inline("rails_get_partial_interface", "partial:\"shared/status_badge\"", "partial_interface", "partial=shared/status_badge")} — partial locals contract",
          "4. Read the view file, make your edit",
          "5. #{tool_call_inline("rails_validate", "files:[\"app/views/cooks/index.html.erb\"]", "validate", "files=app/views/cooks/index.html.erb")}",
          "",
          "**Trace a method:**",
          tool_call("rails_search_code(pattern:\"can_cook?\", match_type:\"trace\")", cli_cmd("search_code", "pattern=\"can_cook?\" match_type=trace")),
          "",
          "**Debug an error (one call — gathers context + git + logs + fix):**",
          tool_call("rails_diagnose(error:\"NoMethodError: undefined method `foo` for nil\", file:\"app/models/cook.rb\")", cli_cmd("diagnose", "error=\"NoMethodError: undefined method foo\" file=app/models/cook.rb")),
          "",
          "**Review changes before merging:**",
          tool_call("rails_review_changes(ref:\"main\")", cli_cmd("review_changes", "ref=main")),
          "",
          "**Generate tests matching project patterns:**",
          tool_call("rails_generate_test(model:\"Cook\")", cli_cmd("generate_test", "model=Cook")),
          ""
        ]
      end

      def tools_antipatterns_section
        search_tool = tool_mode == :cli ? cli_cmd("search_code") : "rails_search_code"
        validate_tool = tool_mode == :cli ? cli_cmd("validate") : "rails_validate"
        [
          "### Common mistakes — avoid these",
          "",
          "- **Don't read db/schema.rb** — use `get_schema`. It adds [indexed]/[unique] hints you'd miss.",
          "- **Don't read model files for reference** — use `get_model_details`. It resolves concerns, inherited methods, and implicit belongs_to validations.",
          "- **Don't use Grep/search agents** — use `#{search_tool}`. It excludes sensitive files, supports `match_type:\"trace\"`, and paginates.",
          "- **Don't call tools without a target** — `get_model_details()` without `model:` returns a paginated list, not an error. Always specify what you want.",
          "- **Don't skip validation** — run `#{validate_tool}` after EVERY edit. It catches syntax errors AND Rails-specific issues (missing partials, bad column refs).",
          "- **Don't ignore cross-references** — tool responses include `_Next:` hints suggesting the best follow-up call. Follow them.",
          "- **Don't call `detail:\"full\"` first** — start with `summary` to find your target, then drill in. Full responses waste tokens.",
          ""
        ]
      end

      def tools_rules_section
        case tool_mode
        when :cli
          [
            "### Rules",
            "",
            "1. **Use composite tools first** — `#{cli_cmd("context")}` and `#{cli_cmd("analyze_feature")}` before individual tools",
            "2. **NEVER read reference files** — db/schema.rb, config/routes.rb, model files, test files — tools are better",
            "3. **NEVER use Grep** — use `#{cli_cmd("search_code")}`",
            "4. **Read files ONLY to Edit them** — not for reference",
            "5. **Validate EVERY edit** — `#{cli_cmd("validate", "files=... level=rails")}`",
            "6. **Follow _Next:_ hints** — tool responses suggest the best follow-up call",
            ""
          ]
        else
          [
            "### Rules",
            "",
            "1. **Use composite tools first** — `rails_get_context` and `rails_analyze_feature` before individual tools",
            "2. **NEVER read reference files** — db/schema.rb, config/routes.rb, model files, test files — tools are better",
            "3. **NEVER use Grep** — use `rails_search_code`",
            "4. **Read files ONLY to Edit them** — not for reference",
            "5. **Validate EVERY edit** — `rails_validate(files:[...], level:\"rails\")`",
            "6. **Follow _Next:_ hints** — tool responses suggest the best follow-up call",
            "7. If MCP tools are not connected, use CLI: `#{cli_cmd("TOOL_NAME", "param=value")}`",
            ""
          ]
        end
      end

      def tools_table # rubocop:disable Metrics/MethodLength
        lines = [ "### All 37 Tools", "" ]

        if tool_mode == :cli
          lines.concat(tools_table_cli)
        else
          lines.concat(tools_table_mcp_and_cli)
        end

        lines
      end

      def tools_table_mcp_and_cli # rubocop:disable Metrics/MethodLength
        [
          "| MCP | CLI | What it does |",
          "|-----|-----|-------------|",
          "| `rails_get_context(model:\"X\")` | `#{cli_cmd("context", "model=X")}` | **START HERE** — schema + model + controller + routes + views in one call |",
          "| `rails_analyze_feature(feature:\"X\")` | `#{cli_cmd("analyze_feature", "feature=X")}` | Full-stack: models + controllers + routes + services + jobs + views + tests |",
          "| `rails_search_code(pattern:\"X\", match_type:\"trace\")` | `#{cli_cmd("search_code", "pattern=X match_type=trace")}` | Search + trace: definition, source, callers, test coverage. Also: `match_type:\"any\"` for regex search |",
          "| `rails_get_controllers(controller:\"X\", action:\"Y\")` | `#{cli_cmd("controllers", "controller=X action=Y")}` | Action source + inherited filters + render map + private methods |",
          "| `rails_validate(files:[...], level:\"rails\")` | `#{cli_cmd("validate", "files=a.rb,b.rb level=rails")}` | Syntax + semantic validation (run after EVERY edit) |",
          "| `rails_get_schema(table:\"X\")` | `#{cli_cmd("schema", "table=X")}` | Columns with [indexed]/[unique]/[encrypted]/[default] hints |",
          "| `rails_get_model_details(model:\"X\")` | `#{cli_cmd("model_details", "model=X")}` | Associations, validations, scopes, enums, macros, delegations |",
          "| `rails_get_routes(controller:\"X\")` | `#{cli_cmd("routes", "controller=X")}` | Routes with code-ready helpers and controller filters inline |",
          "| `rails_get_view(controller:\"X\")` | `#{cli_cmd("view", "controller=X")}` | Templates with ivars, Turbo wiring, Stimulus refs, partial locals |",
          "| `rails_get_design_system` | `#{cli_cmd("design_system")}` | Canonical HTML/ERB copy-paste patterns for buttons, inputs, cards |",
          "| `rails_get_stimulus(controller:\"X\")` | `#{cli_cmd("stimulus", "controller=X")}` | Targets, values, actions + HTML data-attributes + view lookup |",
          "| `rails_get_test_info(model:\"X\")` | `#{cli_cmd("test_info", "model=X")}` | Tests + fixture contents + test template |",
          "| `rails_get_concern(name:\"X\", detail:\"full\")` | `#{cli_cmd("concern", "name=X detail=full")}` | Concern methods with source + which models include it |",
          "| `rails_get_callbacks(model:\"X\")` | `#{cli_cmd("callbacks", "model=X")}` | Callbacks in Rails execution order with source |",
          "| `rails_get_edit_context(file:\"X\", near:\"Y\")` | `#{cli_cmd("edit_context", "file=X near=Y")}` | Code around a match with class/method context |",
          "| `rails_get_service_pattern` | `#{cli_cmd("service_pattern")}` | Service objects: interface, dependencies, side effects, callers |",
          "| `rails_get_job_pattern` | `#{cli_cmd("job_pattern")}` | Jobs: queue, retries, guard clauses, broadcasts, schedules |",
          "| `rails_get_env` | `#{cli_cmd("env")}` | Environment variables + credentials keys (not values) |",
          "| `rails_get_partial_interface(partial:\"X\")` | `#{cli_cmd("partial_interface", "partial=X")}` | Partial locals contract: what to pass + usage examples |",
          "| `rails_get_turbo_map` | `#{cli_cmd("turbo_map")}` | Turbo Stream/Frame wiring + mismatch warnings |",
          "| `rails_get_helper_methods` | `#{cli_cmd("helper_methods")}` | App + framework helpers with view cross-references |",
          "| `rails_get_config` | `#{cli_cmd("config")}` | Database adapter, auth, assets, cache, queue, Action Cable |",
          "| `rails_get_gems` | `#{cli_cmd("gems")}` | Notable gems with versions, categories, config file locations |",
          "| `rails_get_conventions` | `#{cli_cmd("conventions")}` | App patterns: auth checks, flash messages, test patterns |",
          "| `rails_security_scan` | `#{cli_cmd("security_scan")}` | Brakeman static analysis: SQL injection, XSS, mass assignment |",
          "| `rails_get_component_catalog(component:\"X\")` | `#{cli_cmd("component_catalog", "component=X")}` | ViewComponent/Phlex: props, slots, previews, usage |",
          "| `rails_performance_check(model:\"X\")` | `#{cli_cmd("performance_check", "model=X")}` | N+1 risks, missing indexes, Model.all anti-patterns |",
          "| `rails_dependency_graph(model:\"X\")` | `#{cli_cmd("dependency_graph", "model=X")}` | Model association graph as Mermaid diagram |",
          "| `rails_migration_advisor(action:\"X\", table:\"Y\")` | `#{cli_cmd("migration_advisor", "action=X table=Y")}` | Generate migration code, flag irreversible ops |",
          "| `rails_get_frontend_stack` | `#{cli_cmd("frontend_stack")}` | React/Vue/Svelte/Angular, Inertia, TypeScript, package manager |",
          "| `rails_search_docs(query:\"X\")` | `#{cli_cmd("search_docs", "query=X")}` | Bundled topic index with weighted keyword search, on-demand GitHub fetch |",
          "| `rails_query(sql:\"X\")` | `#{cli_cmd("query", "sql=X")}` | Safe read-only SQL queries with timeout, row limit, column redaction |",
          "| `rails_read_logs(level:\"X\")` | `#{cli_cmd("read_logs", "level=X")}` | Reverse file tail with level filtering and sensitive data redaction |",
          "| `rails_generate_test(model:\"X\")` | `#{cli_cmd("generate_test", "model=X")}` | Generate test scaffolding matching project patterns (framework, factories, style) |",
          "| `rails_diagnose(error:\"X\")` | `#{cli_cmd("diagnose", "error=\"X\"")}` | One-call error diagnosis: context + git changes + logs + fix suggestions |",
          "| `rails_review_changes(ref:\"main\")` | `#{cli_cmd("review_changes", "ref=main")}` | PR/commit review: file context + warnings (missing indexes, removed validations) |",
          "| `rails_onboard(detail:\"standard\")` | `#{cli_cmd("onboard", "detail=standard")}` | Narrative app walkthrough for new developers or AI agents |"
        ]
      end

      def tools_table_cli # rubocop:disable Metrics/MethodLength
        [
          "| CLI | What it does |",
          "|-----|-------------|",
          "| `#{cli_cmd("context", "model=X")}` | **START HERE** — schema + model + controller + routes + views in one call |",
          "| `#{cli_cmd("analyze_feature", "feature=X")}` | Full-stack: models + controllers + routes + services + jobs + views + tests |",
          "| `#{cli_cmd("search_code", "pattern=X match_type=trace")}` | Search + trace: definition, source, callers, test coverage. Also: `match_type=any` for regex search |",
          "| `#{cli_cmd("controllers", "controller=X action=Y")}` | Action source + inherited filters + render map + private methods |",
          "| `#{cli_cmd("validate", "files=a.rb,b.rb level=rails")}` | Syntax + semantic validation (run after EVERY edit) |",
          "| `#{cli_cmd("schema", "table=X")}` | Columns with [indexed]/[unique]/[encrypted]/[default] hints |",
          "| `#{cli_cmd("model_details", "model=X")}` | Associations, validations, scopes, enums, macros, delegations |",
          "| `#{cli_cmd("routes", "controller=X")}` | Routes with code-ready helpers and controller filters inline |",
          "| `#{cli_cmd("view", "controller=X")}` | Templates with ivars, Turbo wiring, Stimulus refs, partial locals |",
          "| `#{cli_cmd("design_system")}` | Canonical HTML/ERB copy-paste patterns for buttons, inputs, cards |",
          "| `#{cli_cmd("stimulus", "controller=X")}` | Targets, values, actions + HTML data-attributes + view lookup |",
          "| `#{cli_cmd("test_info", "model=X")}` | Tests + fixture contents + test template |",
          "| `#{cli_cmd("concern", "name=X detail=full")}` | Concern methods with source + which models include it |",
          "| `#{cli_cmd("callbacks", "model=X")}` | Callbacks in Rails execution order with source |",
          "| `#{cli_cmd("edit_context", "file=X near=Y")}` | Code around a match with class/method context |",
          "| `#{cli_cmd("service_pattern")}` | Service objects: interface, dependencies, side effects, callers |",
          "| `#{cli_cmd("job_pattern")}` | Jobs: queue, retries, guard clauses, broadcasts, schedules |",
          "| `#{cli_cmd("env")}` | Environment variables + credentials keys (not values) |",
          "| `#{cli_cmd("partial_interface", "partial=X")}` | Partial locals contract: what to pass + usage examples |",
          "| `#{cli_cmd("turbo_map")}` | Turbo Stream/Frame wiring + mismatch warnings |",
          "| `#{cli_cmd("helper_methods")}` | App + framework helpers with view cross-references |",
          "| `#{cli_cmd("config")}` | Database adapter, auth, assets, cache, queue, Action Cable |",
          "| `#{cli_cmd("gems")}` | Notable gems with versions, categories, config file locations |",
          "| `#{cli_cmd("conventions")}` | App patterns: auth checks, flash messages, test patterns |",
          "| `#{cli_cmd("security_scan")}` | Brakeman static analysis: SQL injection, XSS, mass assignment |",
          "| `#{cli_cmd("component_catalog", "component=X")}` | ViewComponent/Phlex: props, slots, previews, usage |",
          "| `#{cli_cmd("performance_check", "model=X")}` | N+1 risks, missing indexes, Model.all anti-patterns |",
          "| `#{cli_cmd("dependency_graph", "model=X")}` | Model association graph as Mermaid diagram |",
          "| `#{cli_cmd("migration_advisor", "action=X table=Y")}` | Generate migration code, flag irreversible ops |",
          "| `#{cli_cmd("frontend_stack")}` | React/Vue/Svelte/Angular, Inertia, TypeScript, package manager |",
          "| `#{cli_cmd("search_docs", "query=X")}` | Bundled topic index with weighted keyword search, on-demand GitHub fetch |",
          "| `#{cli_cmd("query", "sql=X")}` | Safe read-only SQL queries with timeout, row limit, column redaction |",
          "| `#{cli_cmd("read_logs", "level=X")}` | Reverse file tail with level filtering and sensitive data redaction |",
          "| `#{cli_cmd("generate_test", "model=X")}` | Generate test scaffolding matching project patterns (framework, factories, style) |",
          "| `#{cli_cmd("diagnose", "error=\"X\"")}` | One-call error diagnosis: context + git changes + logs + fix suggestions |",
          "| `#{cli_cmd("review_changes", "ref=main")}` | PR/commit review: file context + warnings (missing indexes, removed validations) |",
          "| `#{cli_cmd("onboard", "detail=standard")}` | Narrative app walkthrough for new developers or AI agents |"
        ]
      end

      # Full tool guide section — used by split rules files (.claude/rules/, .cursor/rules/, etc.)
      def render_tools_guide
        lines = []
        lines << tools_header
        lines << ""
        lines.concat(tools_intro)
        lines.concat(tools_detail_guidance)
        lines.concat(tools_power_tool_section)
        lines.concat(tools_workflow_section)
        lines.concat(tools_antipatterns_section)
        lines.concat(tools_rules_section)
        lines.concat(tools_table)
        lines
      end

      # Compact tool guide for root files (CLAUDE.md, AGENTS.md) that have line limits.
      # Includes power tools + workflows + rules + dense tool name list (no table).
      def render_tools_guide_compact
        lines = []
        lines << tools_header
        lines << ""
        lines.concat(tools_intro)
        lines.concat(tools_power_tool_section)
        lines.concat(tools_workflow_section)
        lines.concat(tools_rules_section)
        lines.concat(tools_name_list)
        lines
      end

      # Dense one-line-per-tool listing — fits in compact mode without the table overhead
      def tools_name_list
        all_tools = %w[
          rails_get_context rails_analyze_feature rails_search_code rails_get_controllers
          rails_validate rails_get_schema rails_get_model_details rails_get_routes
          rails_get_view rails_get_design_system rails_get_stimulus rails_get_test_info
          rails_get_concern rails_get_callbacks rails_get_edit_context
          rails_get_service_pattern rails_get_job_pattern rails_get_env
          rails_get_partial_interface rails_get_turbo_map rails_get_helper_methods
          rails_get_config rails_get_gems rails_get_conventions rails_security_scan
          rails_get_component_catalog rails_performance_check rails_dependency_graph
          rails_migration_advisor rails_get_frontend_stack rails_search_docs
          rails_query rails_read_logs rails_generate_test rails_diagnose
          rails_review_changes rails_onboard
        ]
        [
          "### All #{all_tools.size} tools",
          "`#{all_tools.join('` `')}`",
          ""
        ]
      end

      private

      # Generate zsh-safe CLI command: rails 'ai:tool[name]' params
      def cli_cmd(tool_name, params = nil)
        cmd = "rails 'ai:tool[#{tool_name}]'"
        cmd += " #{params}" if params
        cmd
      end

      # Inline tool call for workflow steps (shorter format).
      # mcp_name is the full MCP tool name (e.g. "rails_validate", "rails_get_context").
      def tool_call_inline(mcp_name, mcp_params, cli_short, cli_params)
        case tool_mode
        when :cli
          "`#{cli_cmd(cli_short, cli_params)}`"
        when :mcp
          "`#{mcp_name}(#{mcp_params})` or `#{cli_cmd(cli_short, cli_params)}`"
        else
          "`#{mcp_name}(#{mcp_params})`"
        end
      end
    end
  end
end
