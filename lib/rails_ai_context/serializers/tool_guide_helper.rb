# frozen_string_literal: true

module RailsAiContext
  module Serializers
    # Shared helper for rendering the tool reference section in context files.
    # Reads config.tool_mode to generate MCP syntax, CLI syntax, or both.
    module ToolGuideHelper
      include CountPhrase

      # A workflow step that runs a tool. A plain string is a step with none.
      WorkflowStep = Struct.new(:text)

      # A tool call example, in the one form the tool mode uses: the MCP
      # client lists the tools, and the guide names the command fallback once.
      def tool_call(mcp_call, cli_call)
        "→ `#{tool_mode == :cli ? cli_call : mcp_call}`"
      end

      def tool_mode
        RailsAiContext.configuration.tool_mode
      end

      # A tool named once in prose: its MCP call, or its command where the
      # app serves no MCP.
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

      # Whether the server serves the gem's own tool under this name. A step, rule or pointer
      # carries that tool's arguments, so it is left out for a skipped tool and for a custom one in its place.
      def served?(mcp_name)
        @served_tool_names ||= exposed_tools.to_set { |tool| RailsAiContext::Server.tool_label(tool) }
        @served_tool_names.include?(mcp_name) && exposed_tools.include?(RailsAiContext::Tools::BaseTool.tool_class(mcp_name))
      end

      # "Use <tool> for ..." lines under a blank one, for the tools the server
      # serves: each pointer is [mcp_name, mcp_params, cli_params, purpose].
      def tool_pointers(*pointers)
        served = pointers.select { |name, *| served?(name) }
        return [] if served.empty?

        [ "", *served.map { |name, mcp_params, cli_params, purpose| "Use #{tool_ref(name, mcp_params, cli_params)} #{purpose}" } ]
      end

      # The named tools the server serves, each as tool_ref gives it.
      def served_refs(*mcp_names)
        mcp_names.select { |name| served?(name) }.map { |name| tool_ref(name) }
      end

      def tools_header
        "## Tools (#{tool_count}): use them before reading files"
      end

      def tools_intro
        if tool_mode == :cli
          [
            "This project has #{count_phrase(tool_count, "introspection tool")}. They answer from the app itself:",
            "its real schema, associations and filters, where reading files gives guesses.",
            "Run one with `#{cli_cmd("TOOL_NAME", "param=value")}`.",
            ""
          ]
        else
          [
            "This project has #{count_phrase(tool_count, "MCP tool")} via `#{serve_cmd}`. They answer from the app itself:",
            "its real schema, associations and filters, where reading files gives guesses.",
            "If the MCP tools are not connected, run the same tools as `#{cli_cmd("TOOL_NAME", "param=value")}`.",
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
          "1. **Verify before you write.** Never reference a column, association, route, helper, method, class, partial, or gem you have not verified in this project with a tool call in this turn. If it's not verified here, verify it now. Never invent names that \"sound right.\"",
          "2. **Mark every assumption.** If you must proceed without verification, prefix the relevant output with `[ASSUMPTION]` and state what you're assuming and why. Silent assumptions are forbidden. \"I'd need to check X first\" is a valid and preferred answer.",
          "3. **Training data describes average Rails. This app isn't average.** When something feels \"obviously\" like standard Rails, query anyway. Factories vs fixtures? Pundit vs CanCan? Devise vs has_secure_password? #{stack_check_text} before scaffolding anything.",
          "4. **Check the inheritance chain before every edit.** Before writing a controller action: inherited `before_action` filters and ancestor classes. Before writing a model method: concerns, includes, STI parents. Inheritance is never flat.",
          "5. **Empty tool output is information, not permission.** \"0 callers found,\" \"no validations,\" or a missing model is a signal to investigate or confirm with the user - not a license to proceed on guesses. Follow `_Next:` hints.",
          "6. **Stale context lies. Re-query after writes.** After any edit, tool output from earlier in this turn may be wrong. Re-query the affected tool before the next write.",
          ""
        ]
      end

      # Rule 3's check before scaffolding: the conventions and gems sections the
      # server serves, else the app's own files.
      def stack_check_text
        refs = %w[conventions gems].filter_map { |section| section_ref(section) }
        refs.any? ? "Check #{refs.join(" and ")}" : "Check the Gemfile and the code that already does it"
      end

      # A rails_get_config section named once in prose, or nil when skip_tools turned it off.
      def section_ref(section)
        return nil unless RailsAiContext::Tools::GetConfig.section_named(section).served?

        tool_ref("rails_get_config", %(section:"#{section}"), "section=#{section}")
      end

      def tools_detail_guidance
        names = detail_tool_names
        return [] if names.empty?

        lines = [
          "### The detail parameter: start with summary",
          "",
          *Budget.wrap(names, lead: "Tools that take `detail`: "),
          "",
          "Pass `#{param_text("detail", "summary")}` first. Use the right level:",
          "- **summary** - first call, orient yourself (table list, model names, route overview)",
          "- **standard** - working detail (columns with types, associations, action source) - DEFAULT",
          "- **full** - only when you need indexes, foreign keys, code snippets, or complete content",
          "",
          "Pattern: summary to find the target → standard to understand it → full only if needed.",
          ""
        ]
        composites = served_refs("rails_get_context", "rails_analyze_feature")
        if composites.any?
          lines << "**Composite tools take no `detail`** - #{composites.join(" and ")} #{composites.size > 1 ? "refuse" : "refuses"} it."
          lines << ""
        end
        lines
      end

      def detail_tool_names
        taking = exposed_tools.select { |tool| tool.input_schema_value.to_h.dig(:properties, :detail, :enum) == RailsAiContext::DetailLevel::ALL }
        taking.map do |tool|
          name = RailsAiContext::Server.tool_label(tool)
          name = RailsAiContext::CLI::ToolRunner.short_name(name) if tool_mode == :cli
          "`#{name}`#{detail_sections_note(tool)}"
        end
      end

      # rails_get_config reads `detail` in some sections, and its default one answers that it does not.
      def detail_sections_note(tool)
        return nil unless tool.equal?(RailsAiContext::Tools::GetConfig)

        names = tool.sections_on.select { |section| section.params.include?(:detail) }.map(&:name)
        " (section#{"s" if names.size > 1}: #{names.join(", ")})"
      end

      def tools_power_tool_section
        ex = guide_examples
        lines = []
        if served?("rails_onboard")
          lines.push("**New to this project?** Get a full walkthrough first:",
                     tool_call("rails_onboard(detail:\"standard\")", cli_cmd("onboard", "detail=standard")), "")
        end
        if served?("rails_get_context")
          lines.push("**#{tool_ref("rails_get_context")} is your power tool** - bundles schema + model + controller + routes + views in one call:",
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
          tool_step("rails_validate", "files:[\"#{ex.model_file}\"], level:\"rails\"", "validate", "files=#{ex.model_file} level=rails"),
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

      # Each rule once, with its reason: what to read for reference, what to
      # run after an edit, and how to ask.
      def tools_rules_section
        rules = []
        composites = served_refs("rails_get_context", "rails_analyze_feature")
        rules << "**Composite tools first** - #{composites.join(" and ")} before the single-layer tools" if composites.any?
        rules << "**Read a file only to edit it** - #{reference_reads}"
        if served?("rails_search_code")
          rules << "**Trace with #{tool_ref("rails_search_code")}** - it skips sensitive files, follows a method with " \
                   "`#{param_text("match_type", "trace")}` and paginates; plain search is fine for a simple lookup"
        end
        if served?("rails_validate")
          rules << "**Run #{tool_ref("rails_validate", 'files:[...], level:"rails"', "files=... level=rails")} after each edit** - " \
                   "it catches syntax errors and Rails ones (missing partials, bad column references), so there is no need to re-read the file"
        end
        rules << "**Name a target** - a lookup without one returns a paginated list, not an error"
        rules << "**Start with `#{param_text("detail", "summary")}`** to find the target, then drill in; a full answer first buries it"
        rules << "**Follow _Next:_ hints** - each answer names the best next call"
        [ "### Rules", "", *rules.each_with_index.map { |rule, i| "#{i + 1}. #{rule}" }, "" ]
      end

      # What answers better than the file, for the tools the app serves.
      def reference_reads
        reads = []
        reads << "#{tool_ref("rails_get_schema")} reads #{schema_dump_path} and marks indexed and unique columns" if served?("rails_get_schema")
        if served?("rails_get_model_details")
          reads << "#{tool_ref("rails_get_model_details")} resolves concerns, inherited methods and implicit belongs_to validations"
        end
        reads << "#{tool_ref("rails_get_routes")} reads config/routes.rb" if served?("rails_get_routes")
        reads.any? ? "for reference, #{reads.join("; ")}" : "the tools answer from the app for reference"
      end

      def tools_table
        [ "### All #{tool_count} Tools", "", *build_tools_table ]
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

      # One row per tool, in the one form the tool mode uses.
      def build_tools_table
        rows = tool_rows.map do |tool, row|
          if tool_mode == :cli
            # A command passes `match_type=any`, where a description shows the MCP form.
            cli = cli_cmd(RailsAiContext::CLI::ToolRunner.short_name(tool.tool_name), row.cli_args)
            "| `#{cli}` | #{row.summary.gsub('match_type:"any"', "match_type=any")} |"
          else
            "| `#{row.mcp}` | #{row.summary} |"
          end
        end
        header = tool_mode == :cli ? [ "| CLI | What it does |", "|-----|-------------|" ] : [ "| MCP | What it does |", "|-----|-------------|" ]
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
        lines.concat(tools_rules_section)
        lines.concat(tools_table)
        lines
      end

      # The guide a root file carries, loaded in every session: no table, and
      # the names only in :cli mode, since an MCP client lists the tools itself.
      def render_tools_guide_compact
        lines = []
        lines << tools_header
        lines << ""
        lines.concat(tools_intro)
        lines.concat(tools_anti_hallucination_section)
        lines.concat(tools_power_tool_section)
        lines.concat(tools_workflow_section)
        lines.concat(tools_rules_section)
        lines.concat(tools_name_list) if tool_mode == :cli
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
        lines << "Run one as `#{cli_cmd("NAME", "param=value")}`, `NAME` being one of:" if cli
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

      # A workflow step's call, in the one form the tool mode uses.
      def tool_call_inline(mcp_name, mcp_params, cli_short, cli_params)
        tool_mode == :cli ? "`#{cli_cmd(cli_short, cli_params)}`" : "`#{mcp_name}(#{mcp_params})`"
      end
    end
  end
end
