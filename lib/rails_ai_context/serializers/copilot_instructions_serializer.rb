# frozen_string_literal: true

module RailsAiContext
  module Serializers
    # Generates .github/instructions/*.instructions.md files with applyTo frontmatter
    # for GitHub Copilot path-specific instructions.
    class CopilotInstructionsSerializer < Base
      include StackOverviewHelper
      include ToolGuideHelper

      RULE_FILES = {
        "rails-context.instructions.md" => {
          renderer: :render_context_instructions, reason: :overview_reason, name: "Rails Project Overview",
          scope: RuleScope.always("Rails version, database, models, routes, gems, architecture patterns")
        },
        "rails-models.instructions.md" => {
          renderer: :render_models_instructions, reason: "no models", name: "Rails Models Reference",
          scope: RuleScope.paths("app/models/**/*.rb", description: "ActiveRecord models - associations, validations, scopes, enums")
        },
        "rails-controllers.instructions.md" => {
          renderer: :render_controllers_instructions, reason: "no controllers", name: "Rails Controllers Reference",
          scope: RuleScope.paths("app/controllers/**/*.rb", description: "Controllers - actions, filters, strong parameters")
        },
        # Code review reads only copilot-instructions.md.
        "rails-mcp-tools.instructions.md" => {
          renderer: :render_mcp_tools_instructions, reason: :overview_reason, name: :tools_name,
          scope: :tools_scope, exclude_agent: "code-review", kind: :root
        }
      }.freeze

      # @param output_dir [String] Rails root path
      # @return [Hash] { written: [paths], skipped: [paths], not_applicable: { path => reason } }
      def call(output_dir)
        write_rule_table(File.join(output_dir, Install::AiTool.find(:copilot).rules_dir), RULE_FILES, root: output_dir, tool: :copilot)
      end

      private

      def plan
        @plan ||= LoadPlan.new([ :copilot ])
      end

      def overview_reason
        plan.root_carries?(:copilot) ? in_root_reason : "nothing to document"
      end

      # copilot-instructions.md states the overview whenever it is written.
      def render_context_instructions
        return nil if plan.root_carries?(:copilot)

        lines = header_lines(:overview, title: "Overview")
        lines.concat(overview_lines)

        lines << ""
        lines << "Use #{tools_noun} for detailed data. Start with `#{param_text("detail", "summary")}`."

        lines.join("\n")
      end

      def render_models_instructions
        models = Payload.models(context)
        return nil unless models.any?

        lines = [
          "# ActiveRecord Models (#{models.size})",
          ""
        ]
        lines.concat(SectionFacts.static_notice_lines(context))
        lines << MODELS_READING
        lines << ""

        lines.concat(model_rows(:listing))
        lines.join("\n")
      end

      def render_controllers_instructions
        controllers = Payload.app_controllers(context)
        return nil if controllers.empty?

        lines = [
          "# Controllers (#{controllers.size})",
          ""
        ]
        lines.concat(SectionFacts.static_notice_lines(context))
        lines.concat(render_compact_controllers_list(controllers))
        lines.concat(tool_pointers([ "rails_get_controllers", 'controller:"Name"', "controller=Name", "for full detail." ]))

        lines.join("\n")
      end

      def tools_name
        "Rails #{tool_mode == :cli ? "CLI" : "MCP"} Tools"
      end

      def tools_scope
        RuleScope.always("#{count_phrase(tool_count, "introspection tool")} - schema, models, routes, controllers, search, testing, validation")
      end

      # The guide, where copilot-instructions.md does not carry it.
      def render_mcp_tools_instructions
        plan.root_carries?(:copilot) ? nil : render_tools_guide.join("\n")
      end
    end
  end
end
