# frozen_string_literal: true

module RailsAiContext
  module Serializers
    # Generates .cursor/rules/*.mdc files: the scoped models and controllers
    # rules, and where no root file carries the root content, the overview and
    # the tools guide. The root content itself is in AGENTS.md or CLAUDE.md,
    # which Cursor reads on every surface.
    class CursorRulesSerializer < Base
      include StackOverviewHelper
      include ToolGuideHelper

      # Split rule files (.cursor/rules/*.mdc) are fully gem-owned, written
      # as-is with no markers (the gem manages every file in that
      # directory).
      RULE_FILES = {
        "rails-project.mdc" => { renderer: :render_project_rule, reason: :overview_reason, scope: :project_scope },
        "rails-models.mdc" => { renderer: :render_models_rule, reason: "no models",
                                scope: RuleScope.paths("app/models/**/*.rb", description: "ActiveRecord models") },
        "rails-controllers.mdc" => { renderer: :render_controllers_rule, reason: "no controllers",
                                     scope: RuleScope.paths("app/controllers/**/*.rb", description: "Controllers") },
        "rails-mcp-tools.mdc" => { renderer: :render_mcp_tools_rule, reason: :overview_reason, scope: :tools_scope, kind: :root }
      }.freeze

      # @param output_dir [String] Rails root path
      # @return [Hash] { written:, skipped:, removed:, trimmed: [paths], not_applicable: { path => reason } }
      def call(output_dir)
        rules_dir = File.join(output_dir, Install::AiTool.find(:cursor).rules_dir)
        result = write_rule_table(rules_dir, RULE_FILES, root: output_dir, tool: :cursor)
        return result unless plan.root_carries?(:cursor)

        # Cursor calls .cursorrules legacy and reads the content from the root
        # file the plan picked, so the block an earlier release wrote goes.
        SectionMarkerWriter.drop(File.join(output_dir, ".cursorrules"), root: output_dir, whole: false, result: result)
      end

      private

      def plan
        @plan ||= LoadPlan.new([ :cursor ])
      end

      def overview_reason
        plan.root_carries?(:cursor) ? in_root_reason : "nothing to document"
      end

      def project_scope
        RuleScope.always("Rails project context for #{context[:app_name]}")
      end

      # The agent picks it by its description, so the description names the mode's tools.
      def tools_scope
        RuleScope.on_request("Rails #{tool_mode == :cli ? "CLI" : "MCP"} tools reference - #{count_phrase(tool_count, "tool")} for schema, models, routes, controllers, search, testing, and more")
      end

      # The overview, where no root file Cursor reads carries the root content.
      def render_project_rule
        return nil if plan.root_carries?(:cursor)

        lines = [
          "# #{context[:app_name]}",
          "",
          "Rails #{context[:rails_version]} | Ruby #{context[:ruby_version]}",
          ""
        ]
        lines.concat(overview_lines)

        lines << ""
        lines << "#{tools_noun.upcase_first} available - see rails-mcp-tools.mdc for full reference."
        lines << "Always call with #{param_text("detail", "summary")} first, then drill into specifics."

        lines.join("\n")
      end

      # Auto-attached when working in app/models/
      def render_models_rule
        models = Payload.models(context)
        return nil unless models.any?

        lines = [
          "# Models (#{models.size})",
          ""
        ]
        lines.concat(SectionFacts.static_notice_lines(context))

        lines << MODELS_READING
        lines << ""

        lines.concat(model_rows(:listing))
        if served?("rails_get_model_details")
          lines << ""
          lines << "Use #{tool_named("rails_get_model_details", "model", "Name")} for full detail."
        end

        lines.join("\n")
      end

      # Auto-attached when working in app/controllers/
      def render_controllers_rule
        controllers = Payload.app_controllers(context)
        return nil if controllers.empty?

        lines = [
          "# Controllers (#{controllers.size})",
          ""
        ]
        lines.concat(SectionFacts.static_notice_lines(context))

        lines.concat(render_compact_controllers_list(controllers))

        if served?("rails_get_controllers")
          lines << ""
          lines << "Use #{tool_named("rails_get_controllers", "controller", "Name")} for full detail."
        end

        lines.join("\n")
      end

      # The guide on request, where no root file Cursor reads carries it.
      def render_mcp_tools_rule
        plan.root_carries?(:cursor) ? nil : render_tools_guide.join("\n")
      end
    end
  end
end
