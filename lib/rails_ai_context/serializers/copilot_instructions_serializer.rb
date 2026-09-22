# frozen_string_literal: true

module RailsAiContext
  module Serializers
    # Generates .github/instructions/*.instructions.md files with applyTo frontmatter
    # for GitHub Copilot path-specific instructions.
    class CopilotInstructionsSerializer
      include StackOverviewHelper
      include ToolGuideHelper

      attr_reader :context

      def initialize(context)
        @context = context
      end

      RULE_FILES = {
        "rails-context.instructions.md" => { renderer: :render_context_instructions, reason: "nothing to document" },
        "rails-models.instructions.md" => { renderer: :render_models_instructions, reason: "no models" },
        "rails-controllers.instructions.md" => { renderer: :render_controllers_instructions, reason: "no controllers" },
        "rails-mcp-tools.instructions.md" => { renderer: :render_mcp_tools_instructions, reason: "nothing to document" }
      }.freeze

      # @param output_dir [String] Rails root path
      # @return [Hash] { written: [paths], skipped: [paths], not_applicable: { path => reason } }
      def call(output_dir)
        write_rule_table(File.join(output_dir, Install::AiTool.find(:copilot).rules_dir), RULE_FILES)
      end

      private

      def render_context_instructions
        lines = [
          "---",
          "applyTo: \"**/*\"",
          "name: \"Rails Project Overview\"",
          "description: \"Rails version, database, models, routes, gems, architecture patterns\"",
          "---",
          "",
          "# #{context[:app_name] || 'Rails App'} - Overview",
          "",
          "Rails #{context[:rails_version]} | Ruby #{context[:ruby_version]}",
          ""
        ]
        lines.concat(overview_lines)

        lines << ""
        lines << "Use MCP tools for detailed data. Start with `detail:\"summary\"`."

        lines.join("\n")
      end

      def render_models_instructions
        models = Payload.models(context)
        return nil unless models.any?

        lines = [
          "---",
          "applyTo: \"app/models/**/*.rb\"",
          "name: \"Rails Models Reference\"",
          "description: \"ActiveRecord models - associations, validations, scopes, enums\"",
          "---",
          "",
          "# ActiveRecord Models (#{models.size})",
          ""
        ]
        lines.concat(SectionFacts.static_notice_lines(context))
        lines << "Check here first for scopes, constants, associations. Read model files for business logic/methods."
        lines << ""

        models.keys.sort.first(30).each do |name|
          data = models[name]
          if (unread = SectionFacts.unread_row("- #{name}", data))
            lines << unread
            next
          end

          assocs = (data[:associations] || []).size
          lines << "- #{name} (#{count_phrase(assocs, "association")})"
          extras = model_extras_line(data)
          lines << extras if extras
        end

        lines << "- ...#{models.size - 30} more" if models.size > 30
        lines.join("\n")
      end

      def render_controllers_instructions
        controllers = Payload.app_controllers(context)
        return nil if controllers.empty?

        lines = [
          "---",
          "applyTo: \"app/controllers/**/*.rb\"",
          "name: \"Rails Controllers Reference\"",
          "description: \"Controllers - actions, filters, strong parameters\"",
          "---",
          "",
          "# Controllers (#{controllers.size})",
          ""
        ]
        lines.concat(SectionFacts.static_notice_lines(context))
        lines << "Use `rails_get_controllers` MCP tool for full details."
        lines << ""

        lines.concat(render_compact_controllers_list(controllers))

        lines.join("\n")
      end

      def render_mcp_tools_instructions
        lines = [
          "---",
          "applyTo: \"**/*\"",
          "name: \"Rails MCP Tools\"",
          "description: \"#{count_phrase(tool_count, "introspection tool")} - schema, models, routes, controllers, search, testing, validation\"",
          "excludeAgent: \"code-review\"",
          "---",
          ""
        ]

        lines.concat(render_tools_guide)

        lines.join("\n")
      end
    end
  end
end
