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
        if (notice = SectionFacts.static_notice(context))
          lines.insert(-2, notice)
        end

        if (db_line = SectionFacts.database_line(context))
          lines << db_line
        end
        if (models_line = SectionFacts.models_line(context))
          lines << models_line
        end

        routes = Payload.section(context, :routes)
        lines << "- Routes: #{routes[:total_routes]}#{RouteCoverage.suffix(routes)}" if routes

        notable = Payload.notable_gems(context)
        if notable.any?
          notable.group_by { |g| g[:category]&.to_s || "other" }.first(6).each do |cat, gem_list|
            lines << "- #{cat}: #{gem_list.map { |g| g[:name] }.join(', ')}"
          end
        end

        if Payload.section(context, :conventions)
          arch_labels = arch_labels_hash
          Payload.architecture(context).first(5).each { |p| lines << "- #{arch_labels[p] || p}" }
        end

        lines.concat(full_preset_stack_lines)

        # List service objects
        services = detect_service_files
        lines << "- Services: #{services.join(', ')}" if services.any?

        # List jobs
        jobs = detect_job_files
        lines << "- Jobs: #{jobs.join(', ')}" if jobs.any?

        # ApplicationController before_actions
        before_actions = detect_before_actions
        lines << "" << "**Global before_actions:** #{before_actions.join(', ')}" if before_actions.any?

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
