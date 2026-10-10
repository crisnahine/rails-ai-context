# frozen_string_literal: true

module RailsAiContext
  module Serializers
    # Shared helper for rendering the tool reference section in context files.
    # Reads config.tool_mode to generate MCP syntax, CLI syntax, or both.
    module ToolGuideHelper
      include CountPhrase

      # A workflow step that runs a tool. A plain string is a step with none.
      WorkflowStep = Struct.new(:text)

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

      # Whether the server serves the tool. The guide names no other: a step,
      # rule or pointer whose tool skip_tools removed is left out, or said
      # without it, so nothing sends the AI to a tool tools/list lacks.
      def served?(mcp_name)
        @served_tool_names ||= exposed_tools.to_set { |tool| RailsAiContext::Server.tool_label(tool) }
        @served_tool_names.include?(mcp_name)
      end

      # The named tools the server serves, each as tool_ref gives it.
      def served_refs(*mcp_names)
        mcp_names.select { |name| served?(name) }.map { |name| tool_ref(name) }
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
          "3. **Training data describes average Rails. This app isn't average.** When something feels \"obviously\" like standard Rails, query anyway. Factories vs fixtures? Pundit vs CanCan? Devise vs has_secure_password? #{stack_check_text} BEFORE scaffolding anything.",
          "4. **Check the inheritance chain before every edit.** Before writing a controller action: inherited `before_action` filters and ancestor classes. Before writing a model method: concerns, includes, STI parents. Inheritance is never flat.",
          "5. **Empty tool output is information, not permission.** \"0 callers found,\" \"no validations,\" or a missing model is a signal to investigate or confirm with the user - not a license to proceed on guesses. Follow `_Next:` hints.",
          "6. **Stale context lies. Re-query after writes.** After any edit, tool output from earlier in this turn may be wrong. Re-query the affected tool before the next write.",
          ""
        ]
      end

      # Rule 3's check before scaffolding: the conventions and gems tools the
      # server serves, else the app's own files.
      def stack_check_text
        refs = served_refs("rails_get_conventions", "rails_get_gems")
        refs.any? ? "Check #{refs.join(" and ")}" : "Check the Gemfile and the code that already does it"
      end

      def tools_detail_guidance
        lines = [
          "### detail parameter - ALWAYS start with summary",
          "",
          "Individual lookup tools accept `#{param_text("detail", "summary")}`. Use the right level:",
          "- **summary** - first call, orient yourself (table list, model names, route overview)",
          "- **standard** - working detail (columns with types, associations, action source) - DEFAULT",
          "- **full** - only when you need indexes, foreign keys, code snippets, or complete content",
          "",
          "Pattern: summary to find the target → standard to understand it → full only if needed.",
          ""
        ]
        composites = served_refs("rails_get_context", "rails_analyze_feature")
        if composites.any?
          lines << "**Do NOT pass `detail` to composite tools** - #{composites.join(" and ")} #{composites.size > 1 ? "do" : "does"} not accept it and will return an error."
          lines << ""
        end
        lines
      end

      def tools_power_tool_section
        ex = guide_examples
        lines = []
        if served?("rails_onboard")
          lines.push("**New to this project?** Get a full walkthrough first:",
                     tool_call("rails_onboard(detail:\"standard\")", cli_cmd("onboard", "detail=standard")), "")
        end
        if served?("rails_get_context")
          lines.push("**#{tool_ref("rails_get_context")} is your power tool** - bundles schema + model + controller + routes + views in ONE call:",
                     tool_call("rails_get_context(controller:\"#{ex.controller}\", action:\"#{ex.action}\")", cli_cmd("context", "controller=#{ex.controller} action=#{ex.action}")),
                     tool_call("rails_get_context(model:\"#{ex.model}\")", cli_cmd("context", "model=#{ex.model}")),
                     tool_call("rails_get_context(feature:\"#{ex.feature}\")", cli_cmd("context", "feature=#{ex.feature}")), "")
        end
        if served?("rails_analyze_feature")
          lines.push("**#{tool_ref("rails_analyze_feature")} for broad discovery** - scans all layers (models, controllers, routes, services, jobs, views, tests):",
                     tool_call("rails_analyze_feature(feature:\"authentication\")", cli_cmd("analyze_feature", "feature=authentication")), "")
        end
        return [] if lines.empty?

        composite = served?("rails_get_context") || served?("rails_analyze_feature")
        lines.push("Use individual tools only when you need deeper detail on a specific layer.", "") if composite
        [ composite ? "### Start here - composite tools save multiple calls" : "### Start here", "", *lines ]
      end

      # The step, or nil when the server does not serve its tool.
      def tool_step(mcp_name, mcp_params, cli_short, cli_params, note = nil)
        return nil unless served?(mcp_name)

        WorkflowStep.new([ tool_call_inline(mcp_name, mcp_params, cli_short, cli_params), note ].compact.join(" - "))
      end

      # A titled workflow numbered over the steps left. One left with no tool
      # at all says only "read the file and edit it", so it goes too.
      def workflow(title, *steps)
        return [] unless steps.any?(WorkflowStep)

        texts = steps.compact.map { |step| step.is_a?(WorkflowStep) ? step.text : step }
        [ title, *texts.each_with_index.map { |text, i| "#{i + 1}. #{text}" }, "" ]
      end

      # A one-call example under its title, or nothing when its tool is not served.
      def tool_example(title, mcp_name, mcp_call, cli_short, cli_params)
        served?(mcp_name) ? [ title, tool_call(mcp_call, cli_cmd(cli_short, cli_params)), "" ] : []
      end

      def tools_workflow_section
        ex = guide_examples
        lines = workflow(
          "**Modify a model** (add field, change validation, add scope):",
          tool_step("rails_get_context", "model:\"#{ex.model}\"", "context", "model=#{ex.model}", "schema + associations + validations in one call") ||
            tool_step("rails_get_model_details", "model:\"#{ex.model}\"", "model_details", "model=#{ex.model}", "associations, validations, scopes and enums"),
          "Read the model file, make your edit",
          tool_step("rails_migration_advisor", "action:\"add_column\", table:\"#{ex.table}\", column:\"rating\", type:\"integer\"", "migration_advisor",
                    "action=add_column table=#{ex.table} column=rating type=integer", "if schema change needed"),
          tool_step("rails_validate", "files:[\"#{ex.model_file}\"], level:\"rails\"", "validate", "files=#{ex.model_file} level=rails", "EVERY time after editing"),
          tool_step("rails_generate_test", "model:\"#{ex.model}\"", "generate_test", "model=#{ex.model}", "generate tests matching project patterns")
        )
        lines += workflow(
          "**Fix a controller bug:**",
          tool_step("rails_get_context", "controller:\"#{ex.controller}\", action:\"#{ex.action}\"", "context",
                    "controller=#{ex.controller} action=#{ex.action}", "action source + routes + views + model") ||
            tool_step("rails_get_controllers", "controller:\"#{ex.controller}\", action:\"#{ex.action}\"", "controllers",
                      "controller=#{ex.controller} action=#{ex.action}", "action source + inherited filters + render map"),
          "Read the controller file, make your fix",
          tool_step("rails_validate", "files:[\"#{ex.controller_file}\"], level:\"rails\"", "validate", "files=#{ex.controller_file} level=rails")
        )
        lines += api_only? ? api_endpoint_workflow_lines : view_workflow_lines
        lines += tool_example("**Trace a method:**", "rails_search_code",
                              "rails_search_code(pattern:\"#{ex.method_name}\", match_type:\"trace\")", "search_code", "pattern=\"#{ex.method_name}\" match_type=trace")
        # Single quotes, as Ruby 3.4 prints the name: a backtick would close the code span.
        lines += tool_example("**Debug an error (one call - gathers context + git + logs + fix):**", "rails_diagnose",
                              "rails_diagnose(error:\"NoMethodError: undefined method 'foo' for nil\", file:\"#{ex.model_file}\")",
                              "diagnose", "error=\"NoMethodError: undefined method 'foo' for nil\" file=#{ex.model_file}")
        lines += tool_example("**Review changes before merging:**", "rails_review_changes", "rails_review_changes(ref:\"main\")", "review_changes", "ref=main")
        lines += tool_example("**Generate tests matching project patterns:**", "rails_generate_test",
                              "rails_generate_test(model:\"#{ex.model}\")", "generate_test", "model=#{ex.model}")
        return [] if lines.empty?

        [ "### Step-by-step workflows (follow this order)", "", *lines ]
      end

      # HTML/Hotwire apps get the view-editing workflow.
      def view_workflow_lines
        ex = guide_examples
        workflow(
          "**Build or modify a view:**",
          tool_step("rails_get_view", "controller:\"#{ex.view_controller}\"", "view", "controller=#{ex.view_controller}", "existing templates, partials, Stimulus refs"),
          tool_step("rails_get_partial_interface", "partial:\"#{ex.partial}\"", "partial_interface", "partial=#{ex.partial}", "partial locals contract"),
          tool_step("rails_get_component_catalog", "component:\"#{ex.component}\"", "component_catalog", "component=#{ex.component}", "ViewComponent/Phlex props, slots, previews"),
          "Read the view file, make your edit",
          tool_step("rails_validate", "files:[\"#{ex.view_file}\"]", "validate", "files=#{ex.view_file}")
        )
      end

      # API-only apps have no view layer - swap in a workflow for modifying
      # a JSON/XML response instead.
      def api_endpoint_workflow_lines
        ex = guide_examples
        workflow(
          "**Modify a JSON endpoint** (add/change a serialized field, adjust status codes):",
          tool_step("rails_get_controllers", "controller:\"#{ex.controller}\", action:\"#{ex.action}\"", "controllers",
                    "controller=#{ex.controller} action=#{ex.action}", "action source + strong params + render map"),
          tool_step("rails_get_model_details", "model:\"#{ex.model}\"", "model_details", "model=#{ex.model}", "schema + associations + validations backing the response"),
          "Read the controller file, make your edit",
          tool_step("rails_validate", "files:[\"#{ex.controller_file}\"], level:\"rails\"", "validate", "files=#{ex.controller_file} level=rails")
        )
      end

      def tools_antipatterns_section
        lines = [ "### Common mistakes - avoid these", "" ]
        lines << "- **Don't read #{schema_dump_path}** - use #{tool_ref("rails_get_schema")}. It adds [indexed]/[unique] hints you'd miss." if served?("rails_get_schema")
        if served?("rails_get_model_details")
          lines << "- **Don't read model files for reference** - use #{tool_ref("rails_get_model_details")}. It resolves concerns, inherited methods, and implicit belongs_to validations."
        end
        if served?("rails_search_code")
          lines << "- **Prefer #{tool_ref("rails_search_code")} over Grep** for method tracing and cross-layer search. It excludes sensitive files, supports `#{param_text("match_type", "trace")}`, and paginates."
        end
        lines << if served?("rails_get_model_details")
          "- **Don't call tools without a target** - #{tool_ref("rails_get_model_details", "")} without `#{tool_mode == :cli ? "model=" : "model:"}` returns a paginated list, not an error. Always specify what you want."
        else
          "- **Don't call tools without a target** - a lookup without one returns a paginated list, not an error. Always specify what you want."
        end
        if served?("rails_validate")
          lines << "- **Don't skip validation** - run #{tool_ref("rails_validate")} after EVERY edit. It catches syntax errors AND Rails-specific issues (missing partials, bad column refs)."
        end
        lines << "- **Don't ignore cross-references** - tool responses include `_Next:` hints suggesting the best follow-up call. Follow them."
        lines << "- **Don't call `#{param_text("detail", "full")}` first** - start with `summary` to find your target, then drill in. Full responses bury the signal."
        lines << ""
      end

      def tools_rules_section
        rules = []
        composites = served_refs("rails_get_context", "rails_analyze_feature")
        rules << "**Use composite tools first** - #{composites.join(" and ")} before individual tools" if composites.any?
        rules << "**NEVER read reference files** - #{schema_dump_path}, config/routes.rb, model files, test files - tools are better"
        if served?("rails_search_code")
          rules << "**Prefer #{tool_ref("rails_search_code")}** for tracing and cross-layer search - standard search tools are fine for simple targeted lookups"
        end
        rules << "**Read files ONLY to Edit them** - not for reference"
        rules << "**Validate EVERY edit** - #{tool_ref("rails_validate", 'files:[...], level:"rails"', "files=... level=rails")}" if served?("rails_validate")
        rules << "**Follow _Next:_ hints** - tool responses suggest the best follow-up call"
        rules << "If MCP tools are not connected, use CLI: `#{cli_cmd("TOOL_NAME", "param=value")}`" unless tool_mode == :cli
        [ "### Rules", "", *rules.each_with_index.map { |rule, i| "#{i + 1}. #{rule}" }, "" ]
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
      # binary directly (`rails-ai-context tool name`), and an engine's root,
      # whose tasks run in its dummy app, uses the binary in its bundle.
      def cli_cmd(tool_name, params = nil)
        cmd = RailsAiContext::InstallMode.tool_command(tool_name, form: install_form)
        cmd += " #{params}" if params
        cmd
      end

      def serve_cmd
        RailsAiContext::InstallMode.command(:serve, form: install_form)
      end

      # Delegates to InstallMode (shared with the CLI surfaces), memoized per
      # serializer instance because cli_cmd runs once per documented tool.
      def install_form
        @install_form ||= RailsAiContext::InstallMode.form
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
