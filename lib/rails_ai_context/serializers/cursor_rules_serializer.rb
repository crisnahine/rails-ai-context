# frozen_string_literal: true

module RailsAiContext
  module Serializers
    # Generates .cursor/rules/*.mdc files (new Cursor MDC format) AND a
    # .cursorrules legacy fallback at the project root.
    #
    # Why both:
    #   - .cursor/rules/*.mdc is the recommended format for Cursor 0.42+
    #     with per-file scoping (alwaysApply / globs / description triggers)
    #   - .cursorrules is still consulted by Cursor's chat agent in many
    #     versions and is the only format older clients understand. Real
    #     user report (v5.9.0 release QA): the chat agent didn't detect
    #     rules written only as .cursor/rules/*.mdc; adding .cursorrules
    #     alongside fixed it.
    class CursorRulesSerializer
      include TestCommandDetection
      include StackOverviewHelper
      include ToolGuideHelper
      include CompactSerializerHelper

      attr_reader :context

      def initialize(context)
        @context = context
      end

      # Split rule files (.cursor/rules/*.mdc) are fully gem-owned, written
      # as-is with no markers (the gem manages every file in that
      # directory).
      RULE_FILES = {
        "rails-project.mdc" => { renderer: :render_project_rule, reason: "nothing to document" },
        "rails-models.mdc" => { renderer: :render_models_rule, reason: "no models" },
        "rails-controllers.mdc" => { renderer: :render_controllers_rule, reason: "no controllers" },
        "rails-mcp-tools.mdc" => { renderer: :render_mcp_tools_rule, reason: "nothing to document" }
      }.freeze

      # @param output_dir [String] Rails root path
      # @return [Hash] { written: [paths], skipped: [paths], not_applicable: { path => reason } }
      def call(output_dir)
        rules_dir = File.join(output_dir, Install::AiTool.find(:cursor).rules_dir)
        result = write_rule_table(rules_dir, RULE_FILES)

        # .cursorrules is at the project root and may pre-date the gem
        # install (users frequently hand-write .cursorrules before
        # adopting any tooling). Wrap it in BEGIN/END markers like
        # CLAUDE.md / AGENTS.md / .github/copilot-instructions.md so
        # user content above/below the gem-managed block survives every
        # `rails ai:context` regeneration.
        cursorrules_path = File.join(output_dir, ".cursorrules")
        case SectionMarkerWriter.write_with_markers(cursorrules_path, render_cursorrules_legacy)
        when :written then result[:written] << cursorrules_path
        when :skipped then result[:skipped] << cursorrules_path
        end

        result
      end

      private

      # Always-on project overview rule (<50 lines)
      def render_project_rule
        lines = [
          "---",
          "description: \"Rails project context for #{context[:app_name]}\"",
          "alwaysApply: true",
          "---",
          "",
          "# #{context[:app_name]}",
          "",
          "Rails #{context[:rails_version]} | Ruby #{context[:ruby_version]}",
          ""
        ]
        lines.concat(overview_lines)

        lines << ""
        lines << "MCP tools available - see rails-mcp-tools.mdc for full reference."
        lines << "Always call with detail:\"summary\" first, then drill into specifics."

        lines.join("\n")
      end

      # Auto-attached when working in app/models/
      def render_models_rule
        models = Payload.models(context)
        return nil unless models.any?

        lines = [
          "---",
          "globs:",
          "  - \"app/models/**/*.rb\"",
          "alwaysApply: false",
          "---",
          "",
          "# Models (#{models.size})",
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
          lines << "- #{name} (#{count_phrase(assocs, "association")}, table: #{data[:table_name] || '?'})"
          extras = model_extras_line(data)
          lines << extras if extras
        end

        lines << "- ...#{models.size - 30} more" if models.size > 30
        lines << ""
        lines << "Use `rails_get_model_details` MCP tool with model:\"Name\" for full detail."

        lines.join("\n")
      end

      # Auto-attached when working in app/controllers/
      def render_controllers_rule
        controllers = Payload.app_controllers(context)
        return nil if controllers.empty?

        lines = [
          "---",
          "globs:",
          "  - \"app/controllers/**/*.rb\"",
          "alwaysApply: false",
          "---",
          "",
          "# Controllers (#{controllers.size})",
          ""
        ]
        lines.concat(SectionFacts.static_notice_lines(context))

        lines.concat(render_compact_controllers_list(controllers))

        lines << ""
        lines << "Use `rails_get_controllers` MCP tool with controller:\"Name\" for full detail."

        lines.join("\n")
      end

      # Agent-requested MCP tool reference - loaded on-demand when agent needs tool guidance
      def render_mcp_tools_rule
        lines = [
          "---",
          "description: \"Rails MCP tools reference - #{count_phrase(tool_count, "tool")} for schema, models, routes, controllers, search, testing, and more\"",
          "alwaysApply: false",
          "---",
          ""
        ]

        lines.concat(render_tools_guide)

        lines.join("\n")
      end

      # Legacy .cursorrules fallback. Same content pipeline as CLAUDE.md
      # (render_compact_rules from CompactSerializerHelper) - both files
      # give an AI agent the same project context; only the filename /
      # distribution mechanism differs. Cursor's chat agent reads
      # .cursorrules unconditionally in every version, so this serves as
      # the guaranteed fallback while .cursor/rules/*.mdc is the
      # preferred-when-supported scoped format.
      def render_cursorrules_legacy
        render_compact_rules
      end
    end
  end
end
