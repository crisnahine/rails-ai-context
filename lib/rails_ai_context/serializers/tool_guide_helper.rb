# frozen_string_literal: true

module RailsAiContext
  module Serializers
    # Shared helper for rendering the tool reference section in context files.
    # Reads config.tool_mode to generate MCP syntax, CLI syntax, or both.
    module ToolGuideHelper
      include CountPhrase

      # Returns the tool invocation example for a given tool call.
      # MCP: rails_analyze_feature(feature:"post")
      # CLI: rails 'ai:tool[analyze_feature]' feature=post
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

      # A tool named once in prose: its MCP call, or its command where the
      # app serves no MCP. A pointer in a rules file names the one form to
      # use; the workflows below show both in :mcp mode.
      def tool_ref(mcp_name, mcp_params = nil, cli_params = nil)
        if tool_mode == :cli
          "`#{cli_cmd(RailsAiContext::CLI::ToolRunner.short_name(mcp_name), cli_params)}`"
        else
          "`#{mcp_name}#{"(#{mcp_params})" if mcp_params}`"
        end
      end

      # "`rails_get_schema` MCP tool", or the command in :cli mode. A
      # parameter follows the name in prose, or goes into the command.
      def tool_named(mcp_name, key = nil, value = nil)
        return tool_ref(mcp_name, nil, ("#{key}=#{value}" if key)) if tool_mode == :cli

        key ? "`#{mcp_name}` MCP tool with #{param_text(key, value)}" : "`#{mcp_name}` MCP tool"
      end

      # The tools as a whole, in a sentence: in :cli mode, with how to run one.
      def tools_noun
        tool_mode == :cli ? "introspection tools (`#{cli_cmd("TOOL_NAME", "param=value")}`)" : "MCP tools"
      end

      # A parameter as the mode passes it: detail:"summary" to an MCP tool,
      # detail=summary on the command line.
      def param_text(key, value)
        tool_mode == :cli ? "#{key}=#{value}" : "#{key}:\"#{value}\""
      end

      # True when the app runs in API-only mode (no view layer) - used to swap
      # the view-editing workflow for an API-focused one in the generated guide.
      # Falls back to false (the view workflow) when the includer has no
      # `context` to inspect.
      def api_only?
        return false unless respond_to?(:context)

        ctx = context
        return true if ctx.is_a?(Hash) && ctx.dig(:api, :api_only) == true

        RailsAiContext::Payload.architecture(ctx).include?("api_only")
      end

      # The tools the server serves: the built-ins skip_tools leaves, then
      # the custom ones. Every count and list in the guide reads this, so none
      # names a tool tools/list lacks. Resolved once per generation run.
      def exposed_tools
        RailsAiContext::RunCache.fetch(:exposed_tools) { RailsAiContext::Server.exposed_tools }
      end

      def tool_count
        exposed_tools.size
      end

      def tools_header
        "## Tools (#{tool_count}) - MANDATORY, Use Before Read"
      end

      def tools_intro
        case tool_mode
        when :cli
          [
            "This project has #{count_phrase(tool_count, "introspection tool")}. **MANDATORY - use these instead of reading files.**",
            "They return ground truth from the running app: real schema, real associations, real filters - not guesses.",
            "Run one with `#{cli_cmd("TOOL_NAME", "param=value")}`. Read files ONLY when you are about to Edit them.",
            ""
          ]
        else
          [
            "This project has #{count_phrase(tool_count, "MCP tool")} via `#{serve_cmd}`.",
            "**MANDATORY - use these instead of reading files.** They return ground truth from the running app:",
            "real schema, real associations, real filters - not guesses from file reads.",
            "Read files ONLY when you are about to Edit them.",
            "If MCP tools are not connected, use CLI fallback: `#{cli_cmd("TOOL_NAME", "param=value")}`",
            ""
          ]
        end
      end

      def tools_anti_hallucination_section
        return [] unless RailsAiContext.configuration.anti_hallucination_rules

        [
          "### Anti-Hallucination Protocol - Verify Before You Write",
          "",
          "AI assistants produce confident-wrong code when statistical priors from training",
          "data override observed facts in the current project. These 6 rules force",
          "verification at the exact moments hallucination is most likely.",
          "",
          "1. **Verify before you write.** Never reference a column, association, route, helper, method, class, partial, or gem you have NOT verified in THIS project via a tool call in THIS turn. If it's not verified here, verify it now. Never invent names that \"sound right.\"",
          "2. **Mark every assumption.** If you must proceed without verification, prefix the relevant output with `[ASSUMPTION]` and state what you're assuming and why. Silent assumptions are forbidden. \"I'd need to check X first\" is a valid and preferred answer.",
          "3. **Training data describes average Rails. This app isn't average.** When something feels \"obviously\" like standard Rails, query anyway. Factories vs fixtures? Pundit vs CanCan? Devise vs has_secure_password? Check #{tool_ref("rails_get_conventions")} and #{tool_ref("rails_get_gems")} BEFORE scaffolding anything.",
          "4. **Check the inheritance chain before every edit.** Before writing a controller action: inherited `before_action` filters and ancestor classes. Before writing a model method: concerns, includes, STI parents. Inheritance is never flat.",
          "5. **Empty tool output is information, not permission.** \"0 callers found,\" \"no validations,\" or a missing model is a signal to investigate or confirm with the user - not a license to proceed on guesses. Follow `_Next:` hints.",
          "6. **Stale context lies. Re-query after writes.** After any edit, tool output from earlier in this turn may be wrong. Re-query the affected tool before the next write.",
          ""
        ]
      end

      def tools_detail_guidance
        [
          "### detail parameter - ALWAYS start with summary",
          "",
          "Individual lookup tools accept `#{param_text("detail", "summary")}`. Use the right level:",
          "- **summary** - first call, orient yourself (table list, model names, route overview)",
          "- **standard** - working detail (columns with types, associations, action source) - DEFAULT",
          "- **full** - only when you need indexes, foreign keys, code snippets, or complete content",
          "",
          "Pattern: summary to find the target → standard to understand it → full only if needed.",
          "",
          "**Do NOT pass `detail` to composite tools** - #{tool_ref("rails_get_context")} and #{tool_ref("rails_analyze_feature")} do not accept it and will return an error.",
          ""
        ]
      end

      def tools_power_tool_section
        ex = guide_examples
        [
          "### Start here - composite tools save multiple calls",
          "",
          "**New to this project?** Get a full walkthrough first:",
          tool_call("rails_onboard(detail:\"standard\")", cli_cmd("onboard", "detail=standard")),
          "",
          "**#{tool_ref("rails_get_context")} is your power tool** - bundles schema + model + controller + routes + views in ONE call:",
          tool_call("rails_get_context(controller:\"#{ex.controller}\", action:\"#{ex.action}\")", cli_cmd("context", "controller=#{ex.controller} action=#{ex.action}")),
          tool_call("rails_get_context(model:\"#{ex.model}\")", cli_cmd("context", "model=#{ex.model}")),
          tool_call("rails_get_context(feature:\"#{ex.feature}\")", cli_cmd("context", "feature=#{ex.feature}")),
          "",
          "**#{tool_ref("rails_analyze_feature")} for broad discovery** - scans all layers (models, controllers, routes, services, jobs, views, tests):",
          tool_call("rails_analyze_feature(feature:\"authentication\")", cli_cmd("analyze_feature", "feature=authentication")),
          "",
          "Use individual tools only when you need deeper detail on a specific layer.",
          ""
        ]
      end

      def tools_workflow_section
        ex = guide_examples
        [
          "### Step-by-step workflows (follow this order)",
          "",
          "**Modify a model** (add field, change validation, add scope):",
          "1. #{tool_call_inline("rails_get_context", "model:\"#{ex.model}\"", "context", "model=#{ex.model}")} - schema + associations + validations in one call",
          "2. Read the model file, make your edit",
          "3. #{tool_call_inline("rails_migration_advisor", "action:\"add_column\", table:\"#{ex.table}\", column:\"rating\", type:\"integer\"", "migration_advisor", "action=add_column table=#{ex.table} column=rating type=integer")} - if schema change needed",
          "4. #{tool_call_inline("rails_validate", "files:[\"#{ex.model_file}\"], level:\"rails\"", "validate", "files=#{ex.model_file} level=rails")} - EVERY time after editing",
          "5. #{tool_call_inline("rails_generate_test", "model:\"#{ex.model}\"", "generate_test", "model=#{ex.model}")} - generate tests matching project patterns",
          "",
          "**Fix a controller bug:**",
          "1. #{tool_call_inline("rails_get_context", "controller:\"#{ex.controller}\", action:\"#{ex.action}\"", "context", "controller=#{ex.controller} action=#{ex.action}")} - action source + routes + views + model",
          "2. Read the controller file, make your fix",
          "3. #{tool_call_inline("rails_validate", "files:[\"#{ex.controller_file}\"], level:\"rails\"", "validate", "files=#{ex.controller_file} level=rails")}",
          ""
        ] + (api_only? ? api_endpoint_workflow_lines : view_workflow_lines) + [
          "**Trace a method:**",
          tool_call("rails_search_code(pattern:\"#{ex.method_name}\", match_type:\"trace\")", cli_cmd("search_code", "pattern=\"#{ex.method_name}\" match_type=trace")),
          "",
          "**Debug an error (one call - gathers context + git + logs + fix):**",
          # Single quotes, as Ruby 3.4 prints the name: a backtick would close the code span.
          tool_call("rails_diagnose(error:\"NoMethodError: undefined method 'foo' for nil\", file:\"#{ex.model_file}\")",
                    cli_cmd("diagnose", "error=\"NoMethodError: undefined method 'foo' for nil\" file=#{ex.model_file}")),
          "",
          "**Review changes before merging:**",
          tool_call("rails_review_changes(ref:\"main\")", cli_cmd("review_changes", "ref=main")),
          "",
          "**Generate tests matching project patterns:**",
          tool_call("rails_generate_test(model:\"#{ex.model}\")", cli_cmd("generate_test", "model=#{ex.model}")),
          ""
        ]
      end

      # HTML/Hotwire apps get the view-editing workflow.
      def view_workflow_lines
        ex = guide_examples
        [
          "**Build or modify a view:**",
          "1. #{tool_call_inline("rails_get_view", "controller:\"#{ex.view_controller}\"", "view", "controller=#{ex.view_controller}")} - existing templates, partials, Stimulus refs",
          "2. #{tool_call_inline("rails_get_partial_interface", "partial:\"#{ex.partial}\"", "partial_interface", "partial=#{ex.partial}")} - partial locals contract",
          "3. #{tool_call_inline("rails_get_component_catalog", "component:\"#{ex.component}\"", "component_catalog", "component=#{ex.component}")} - ViewComponent/Phlex props, slots, previews",
          "4. Read the view file, make your edit",
          "5. #{tool_call_inline("rails_validate", "files:[\"#{ex.view_file}\"]", "validate", "files=#{ex.view_file}")}",
          ""
        ]
      end

      # API-only apps have no view layer - swap in a workflow for modifying
      # a JSON/XML response instead.
      def api_endpoint_workflow_lines
        ex = guide_examples
        [
          "**Modify a JSON endpoint** (add/change a serialized field, adjust status codes):",
          "1. #{tool_call_inline("rails_get_controllers", "controller:\"#{ex.controller}\", action:\"#{ex.action}\"", "controllers", "controller=#{ex.controller} action=#{ex.action}")} - action source + strong params + render map",
          "2. #{tool_call_inline("rails_get_model_details", "model:\"#{ex.model}\"", "model_details", "model=#{ex.model}")} - schema + associations + validations backing the response",
          "3. Read the controller file, make your edit",
          "4. #{tool_call_inline("rails_validate", "files:[\"#{ex.controller_file}\"], level:\"rails\"", "validate", "files=#{ex.controller_file} level=rails")}",
          ""
        ]
      end

      def tools_antipatterns_section
        [
          "### Common mistakes - avoid these",
          "",
          "- **Don't read #{schema_dump_path}** - use #{tool_ref("rails_get_schema")}. It adds [indexed]/[unique] hints you'd miss.",
          "- **Don't read model files for reference** - use #{tool_ref("rails_get_model_details")}. It resolves concerns, inherited methods, and implicit belongs_to validations.",
          "- **Prefer #{tool_ref("rails_search_code")} over Grep** for method tracing and cross-layer search. It excludes sensitive files, supports `#{param_text("match_type", "trace")}`, and paginates.",
          "- **Don't call tools without a target** - #{tool_ref("rails_get_model_details", "")} without `#{tool_mode == :cli ? "model=" : "model:"}` returns a paginated list, not an error. Always specify what you want.",
          "- **Don't skip validation** - run #{tool_ref("rails_validate")} after EVERY edit. It catches syntax errors AND Rails-specific issues (missing partials, bad column refs).",
          "- **Don't ignore cross-references** - tool responses include `_Next:` hints suggesting the best follow-up call. Follow them.",
          "- **Don't call `#{param_text("detail", "full")}` first** - start with `summary` to find your target, then drill in. Full responses bury the signal.",
          ""
        ]
      end

      def tools_rules_section
        case tool_mode
        when :cli
          [
            "### Rules",
            "",
            "1. **Use composite tools first** - `#{cli_cmd("context")}` and `#{cli_cmd("analyze_feature")}` before individual tools",
            "2. **NEVER read reference files** - #{schema_dump_path}, config/routes.rb, model files, test files - tools are better",
            "3. **Prefer `#{cli_cmd("search_code")}`** for tracing and cross-layer search - standard search tools are fine for simple targeted lookups",
            "4. **Read files ONLY to Edit them** - not for reference",
            "5. **Validate EVERY edit** - `#{cli_cmd("validate", "files=... level=rails")}`",
            "6. **Follow _Next:_ hints** - tool responses suggest the best follow-up call",
            ""
          ]
        else
          [
            "### Rules",
            "",
            "1. **Use composite tools first** - `rails_get_context` and `rails_analyze_feature` before individual tools",
            "2. **NEVER read reference files** - #{schema_dump_path}, config/routes.rb, model files, test files - tools are better",
            "3. **Prefer `rails_search_code`** for tracing and cross-layer search - standard search tools are fine for simple targeted lookups",
            "4. **Read files ONLY to Edit them** - not for reference",
            "5. **Validate EVERY edit** - `rails_validate(files:[...], level:\"rails\")`",
            "6. **Follow _Next:_ hints** - tool responses suggest the best follow-up call",
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

      # One row per tool the server serves, in the guide's order: a built-in
      # declares its own, and a custom tool, which declares none, follows
      # with the first sentence of its description.
      def tool_rows
        builtin = exposed_tools.filter_map do |tool|
          row = tool.guide_row if tool.respond_to?(:guide_row)
          [ tool, row ] if row
        end
        custom = (exposed_tools - builtin.map(&:first)).map { |tool| [ tool, custom_tool_row(tool) ] }
        builtin.sort_by { |_tool, row| row.order } + custom
      end

      def build_tools_table(include_mcp:)
        # For CLI-only tables, `match_type=any` uses `=` (not `:`), so we tweak description.
        rows = tool_rows.map do |tool, row|
          cli = cli_cmd(RailsAiContext::CLI::ToolRunner.short_name(tool.tool_name), row.cli_args)
          if include_mcp
            "| `#{row.mcp}` | `#{cli}` | #{row.summary} |"
          else
            "| `#{cli}` | #{row.summary.gsub('match_type:"any"', "match_type=any")} |"
          end
        end
        header = include_mcp ? [ "| MCP | CLI | What it does |", "|-----|-----|-------------|" ] : [ "| CLI | What it does |", "|-----|-------------|" ]
        header + rows
      end

      # Full tool guide section - used by split rules files (.claude/rules/, .cursor/rules/, etc.)
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

      # What a tools rule file adds to a root file that carries the guide: the
      # detail levels and the table. Claude Code loads CLAUDE.md and its rules
      # on every request, as Copilot does its instructions, so a whole guide in
      # both put the guide and the protocol in front of the AI twice.
      def render_tools_reference(root_file)
        [
          "## Tools (#{tool_count}) - Reference",
          "",
          "How to use them - the protocol, the workflows and the rules - is in #{root_file}. This file is the reference.",
          "",
          *tools_detail_guidance,
          *tools_table
        ]
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

      # Dense one-line listing, from the same rows the table uses: the MCP
      # names, or in :cli mode the names the command takes.
      def tools_name_list
        cli = tool_mode == :cli
        names = tool_rows.map do |tool, _row|
          cli ? RailsAiContext::CLI::ToolRunner.short_name(tool.tool_name) : tool.tool_name
        end
        lines = [ "### All #{count_phrase(names.size, "tool")}" ]
        lines << "Run one as `#{cli_cmd("NAME", "param=value")}`, NAME being one of:" if cli
        lines << "`#{names.join('` `')}`"
        lines << ""
      end

      private

      # The model, controller and files the examples name, the app's own
      # where it has them.
      def guide_examples
        @guide_examples ||= GuideExamples.new(respond_to?(:context) ? context : {})
      end

      # A row for a tool that declares none: its name and the first sentence
      # of its description, which is all a custom MCP::Tool is sure to have.
      def custom_tool_row(tool)
        description = tool.respond_to?(:description_value) ? tool.description_value.to_s : ""
        summary = description.strip.split(/(?<=\.)\s/).first.to_s.gsub(/\s+/, " ").gsub("|", "\\|")
        RailsAiContext::Tools::BaseTool::GuideRow.new(mcp: tool.tool_name, summary: summary.empty? ? "Custom tool" : summary)
      end

      # Apps with `config.active_record.schema_format = :sql` dump the schema
      # to db/structure.sql instead of db/schema.rb; guidance that names the
      # wrong file sends the AI hunting for a file that does not exist.
      #
      # Rails 7.1 moved the accessor from ActiveRecord::Base to ActiveRecord,
      # so both homes are asked before falling back to what is on disk - the
      # fallback is for the static tier, where nothing is loaded.
      def schema_dump_path
        sql_format = if defined?(ActiveRecord) && ActiveRecord.respond_to?(:schema_format)
          ActiveRecord.schema_format == :sql
        elsif defined?(ActiveRecord::Base) && ActiveRecord::Base.respond_to?(:schema_format)
          ActiveRecord::Base.schema_format == :sql
        end
        root = defined?(Rails) && Rails.respond_to?(:root) && Rails.root ? Rails.root.to_s : Dir.pwd
        candidates = RailsAiContext::Introspectors::SchemaDumpPath.candidates(root)
        _, path = if sql_format.nil?
          candidates.find { |_, candidate| File.exist?(candidate) } || candidates.first
        else
          candidates.find { |format, _| format == (sql_format ? :sql : :ruby) }
        end
        path.delete_prefix("#{root.chomp('/')}/")
      end

      # Generate zsh-safe CLI command. In-Gemfile installs go through the rake
      # task (`rails 'ai:tool[name]'`); standalone installs (gem not in the
      # host app's Gemfile) have no rake tasks at all, so they use the CLI
      # binary directly (`rails-ai-context tool name`).
      def cli_cmd(tool_name, params = nil)
        cmd = standalone_install? ? "rails-ai-context tool #{tool_name}" : "rails 'ai:tool[#{tool_name}]'"
        cmd += " #{params}" if params
        cmd
      end

      def serve_cmd
        RailsAiContext::InstallMode.command(:serve, standalone: standalone_install?)
      end

      # Delegates to InstallMode (shared with the CLI surfaces), memoized per
      # serializer instance because cli_cmd runs once per documented tool.
      def standalone_install?
        return @standalone_install if defined?(@standalone_install)

        @standalone_install = RailsAiContext::InstallMode.standalone?
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
