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

      # Derived from BaseTool.registered_tools — the single source of truth for tool count.
      def tool_count
        RailsAiContext::Server.builtin_tools.size
      end

      def tools_header
        "## Tools (#{tool_count}) — MANDATORY, Use Before Read"
      end

      def tools_intro
        case tool_mode
        when :cli
          [
            "This project has #{tool_count} introspection tools. **MANDATORY — use these instead of reading files.**",
            "They return ground truth from the running app: real schema, real associations, real filters — not guesses.",
            "Read files ONLY when you are about to Edit them.",
            ""
          ]
        else
          [
            "This project has #{tool_count} MCP tools via `rails ai:serve`.",
            "**MANDATORY — use these instead of reading files.** They return ground truth from the running app:",
            "real schema, real associations, real filters — not guesses from file reads.",
            "Read files ONLY when you are about to Edit them.",
            "If MCP tools are not connected, use CLI fallback: `#{cli_cmd("TOOL_NAME", "param=value")}`",
            ""
          ]
        end
      end

      def tools_anti_hallucination_section
        return [] unless RailsAiContext.configuration.anti_hallucination_rules

        [
          "### Anti-Hallucination Protocol — Verify Before You Write",
          "",
          "AI assistants produce confident-wrong code when statistical priors from training",
          "data override observed facts in the current project. These 6 rules force",
          "verification at the exact moments hallucination is most likely.",
          "",
          "1. **Verify before you write.** Never reference a column, association, route, helper, method, class, partial, or gem you have NOT verified in THIS project via a tool call in THIS turn. If it's not verified here, verify it now. Never invent names that \"sound right.\"",
          "2. **Mark every assumption.** If you must proceed without verification, prefix the relevant output with `[ASSUMPTION]` and state what you're assuming and why. Silent assumptions are forbidden. \"I'd need to check X first\" is a valid and preferred answer.",
          "3. **Training data describes average Rails. This app isn't average.** When something feels \"obviously\" like standard Rails, query anyway. Factories vs fixtures? Pundit vs CanCan? Devise vs has_secure_password? Check `rails_get_conventions` and `rails_get_gems` BEFORE scaffolding anything.",
          "4. **Check the inheritance chain before every edit.** Before writing a controller action: inherited `before_action` filters and ancestor classes. Before writing a model method: concerns, includes, STI parents. Inheritance is never flat.",
          "5. **Empty tool output is information, not permission.** \"0 callers found,\" \"no validations,\" or a missing model is a signal to investigate or confirm with the user — not a license to proceed on guesses. Follow `_Next:` hints.",
          "6. **Stale context lies. Re-query after writes.** After any edit, tool output from earlier in this turn may be wrong. Re-query the affected tool before the next write.",
          ""
        ]
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
          "1. #{tool_call_inline("rails_get_view", "controller:\"cooks\"", "view", "controller=cooks")} — existing templates, partials, Stimulus refs",
          "2. #{tool_call_inline("rails_get_partial_interface", "partial:\"shared/status_badge\"", "partial_interface", "partial=shared/status_badge")} — partial locals contract",
          "3. #{tool_call_inline("rails_get_component_catalog", "component:\"Button\"", "component_catalog", "component=Button")} — ViewComponent/Phlex props, slots, previews",
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
          "- **Prefer `#{search_tool}` over Grep** for method tracing and cross-layer search. It excludes sensitive files, supports `match_type:\"trace\"`, and paginates.",
          "- **Don't call tools without a target** — `get_model_details()` without `model:` returns a paginated list, not an error. Always specify what you want.",
          "- **Don't skip validation** — run `#{validate_tool}` after EVERY edit. It catches syntax errors AND Rails-specific issues (missing partials, bad column refs).",
          "- **Don't ignore cross-references** — tool responses include `_Next:` hints suggesting the best follow-up call. Follow them.",
          "- **Don't call `detail:\"full\"` first** — start with `summary` to find your target, then drill in. Full responses bury the signal.",
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
            "3. **Prefer `#{cli_cmd("search_code")}`** for tracing and cross-layer search — standard search tools are fine for simple targeted lookups",
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
            "3. **Prefer `rails_search_code`** for tracing and cross-layer search — standard search tools are fine for simple targeted lookups",
            "4. **Read files ONLY to Edit them** — not for reference",
            "5. **Validate EVERY edit** — `rails_validate(files:[...], level:\"rails\")`",
            "6. **Follow _Next:_ hints** — tool responses suggest the best follow-up call",
            "7. If MCP tools are not connected, use CLI: `#{cli_cmd("TOOL_NAME", "param=value")}`",
            ""
          ]
        end
      end

      def tools_table
        lines = [ "### All #{tool_count} Tools", "" ]
        lines.concat(build_tools_table(include_mcp: tool_mode != :cli))
        lines
      end

      # Single source of truth for the tools table.
      # Each row is [mcp_call, cli_name, cli_args, description].
      # Set include_mcp: false for CLI-only 2-column table.
      TOOL_ROWS = [
        [ 'rails_get_context(model:"X")', "context", "model=X", "**START HERE** — schema + model + controller + routes + views in one call" ],
        [ 'rails_analyze_feature(feature:"X")', "analyze_feature", "feature=X", "Full-stack: models + controllers + routes + services + jobs + views + tests" ],
        [ 'rails_search_code(pattern:"X", match_type:"trace")', "search_code", "pattern=X match_type=trace", 'Search + trace: definition, source, callers, test coverage. Also: `match_type:"any"` for regex search' ],
        [ 'rails_get_controllers(controller:"X", action:"Y")', "controllers", "controller=X action=Y", "Action source + inherited filters + render map + private methods" ],
        [ 'rails_validate(files:[...], level:"rails")', "validate", "files=a.rb,b.rb level=rails", "Syntax + semantic validation (run after EVERY edit)" ],
        [ 'rails_get_schema(table:"X")', "schema", "table=X", "Columns with [indexed]/[unique]/[encrypted]/[default] hints" ],
        [ 'rails_get_model_details(model:"X")', "model_details", "model=X", "Associations, validations, scopes, enums, macros, delegations" ],
        [ 'rails_get_routes(controller:"X")', "routes", "controller=X", "Routes with code-ready helpers and controller filters inline" ],
        [ 'rails_get_view(controller:"X")', "view", "controller=X", "Templates with ivars, Turbo wiring, Stimulus refs, partial locals" ],
        [ 'rails_get_stimulus(controller:"X")', "stimulus", "controller=X", "Targets, values, actions + HTML data-attributes + view lookup" ],
        [ 'rails_get_test_info(model:"X")', "test_info", "model=X", "Tests + fixture contents + test template" ],
        [ 'rails_get_concern(name:"X", detail:"full")', "concern", "name=X detail=full", "Concern methods with source + which models include it" ],
        [ 'rails_get_callbacks(model:"X")', "callbacks", "model=X", "Callbacks in Rails execution order with source" ],
        [ 'rails_get_edit_context(file:"X", near:"Y")', "edit_context", "file=X near=Y", "Code around a match with class/method context" ],
        [ "rails_get_service_pattern", "service_pattern", nil, "Service objects: interface, dependencies, side effects, callers" ],
        [ "rails_get_job_pattern", "job_pattern", nil, "Jobs: queue, retries, guard clauses, broadcasts, schedules" ],
        [ "rails_get_env", "env", nil, "Environment variables + credentials keys (not values)" ],
        [ 'rails_get_partial_interface(partial:"X")', "partial_interface", "partial=X", "Partial locals contract: what to pass + usage examples" ],
        [ "rails_get_turbo_map", "turbo_map", nil, "Turbo Stream/Frame wiring + mismatch warnings" ],
        [ "rails_get_helper_methods", "helper_methods", nil, "App + framework helpers with view cross-references" ],
        [ "rails_get_config", "config", nil, "Database adapter, auth, assets, cache, queue, Action Cable" ],
        [ "rails_get_gems", "gems", nil, "Notable gems with versions, categories, config file locations" ],
        [ "rails_get_conventions", "conventions", nil, "App patterns: auth checks, flash messages, test patterns" ],
        [ "rails_security_scan", "security_scan", nil, "Brakeman static analysis: SQL injection, XSS, mass assignment" ],
        [ 'rails_get_component_catalog(component:"X")', "component_catalog", "component=X", "ViewComponent/Phlex: props, slots, previews, usage" ],
        [ 'rails_performance_check(model:"X")', "performance_check", "model=X", "N+1 risks, missing indexes, Model.all anti-patterns" ],
        [ 'rails_dependency_graph(model:"X")', "dependency_graph", "model=X", "Model association graph as Mermaid diagram" ],
        [ 'rails_migration_advisor(action:"X", table:"Y")', "migration_advisor", "action=X table=Y", "Generate migration code, flag irreversible ops" ],
        [ "rails_get_frontend_stack", "frontend_stack", nil, "React/Vue/Svelte/Angular, Inertia, TypeScript, package manager" ],
        [ 'rails_search_docs(query:"X")', "search_docs", "query=X", "Bundled topic index with weighted keyword search, on-demand GitHub fetch" ],
        [ 'rails_query(sql:"X")', "query", "sql=X", "Safe read-only SQL queries with timeout, row limit, column redaction" ],
        [ 'rails_read_logs(level:"X")', "read_logs", "level=X", "Reverse file tail with level filtering and sensitive data redaction" ],
        [ 'rails_generate_test(model:"X")', "generate_test", "model=X", "Generate test scaffolding matching project patterns (framework, factories, style)" ],
        [ 'rails_diagnose(error:"X")', "diagnose", 'error="X"', "One-call error diagnosis: context + git changes + logs + fix suggestions" ],
        [ 'rails_review_changes(ref:"main")', "review_changes", "ref=main", "PR/commit review: file context + warnings (missing indexes, removed validations)" ],
        [ 'rails_onboard(detail:"standard")', "onboard", "detail=standard", "Narrative app walkthrough for new developers or AI agents" ],
        [ 'rails_runtime_info(detail:"standard")', "runtime_info", "detail=standard", "Live runtime: DB pool, table sizes, cache stats, job queues, pending migrations" ],
        [ 'rails_session_context(action:"status")', "session_context", "action=status", "Track what you've already queried, avoid redundant calls" ]
      ].freeze

      def build_tools_table(include_mcp:)
        # For CLI-only tables, `match_type=any` uses `=` (not `:`), so we tweak description.
        rows = TOOL_ROWS.map do |mcp_call, cli_name, cli_args, desc|
          cli = cli_cmd(cli_name, cli_args)
          if include_mcp
            "| `#{mcp_call}` | `#{cli}` | #{desc} |"
          else
            "| `#{cli}` | #{desc.gsub('match_type:"any"', "match_type=any")} |"
          end
        end
        header = include_mcp ? [ "| MCP | CLI | What it does |", "|-----|-----|-------------|" ] : [ "| CLI | What it does |", "|-----|-------------|" ]
        header + rows
      end

      # Full tool guide section — used by split rules files (.claude/rules/, .cursor/rules/, etc.)
      def render_tools_guide
        lines = []
        lines << tools_header
        lines << ""
        lines.concat(tools_intro)
        lines.concat(tools_anti_hallucination_section)
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
        lines.concat(tools_anti_hallucination_section)
        lines.concat(tools_power_tool_section)
        lines.concat(tools_workflow_section)
        lines.concat(tools_antipatterns_section)
        lines.concat(tools_rules_section)
        lines.concat(tools_name_list)
        lines
      end

      # Dense one-line-per-tool listing — derived from TOOL_ROWS (single source of truth)
      def tools_name_list
        all_tools = TOOL_ROWS.map { |row| row[0][/^(rails_\w+)/, 1] }
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
