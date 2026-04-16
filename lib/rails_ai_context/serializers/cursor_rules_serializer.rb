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
      include StackOverviewHelper
      include ToolGuideHelper

      attr_reader :context

      def initialize(context)
        @context = context
      end

      # @param output_dir [String] Rails root path
      # @return [Hash] { written: [paths], skipped: [paths] }
      def call(output_dir)
        rules_dir = File.join(output_dir, ".cursor", "rules")

        files = {
          File.join(rules_dir, "rails-project.mdc") => render_project_rule,
          File.join(rules_dir, "rails-models.mdc") => render_models_rule,
          File.join(rules_dir, "rails-controllers.mdc") => render_controllers_rule,
          File.join(rules_dir, "rails-mcp-tools.mdc") => render_mcp_tools_rule,
          File.join(output_dir, ".cursorrules")       => render_cursorrules_legacy
        }

        write_rule_files(files)
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

        schema = context[:schema]
        if schema && !schema[:error]
          lines << "- Database: #{schema[:adapter]} — #{schema[:total_tables]} tables"
        end

        models = context[:models]
        lines << "- Models: #{models.size}" if models.is_a?(Hash) && !models[:error]

        routes = context[:routes]
        if routes && !routes[:error]
          lines << "- Routes: #{routes[:total_routes]}"
        end

        gems = context[:gems]
        if gems.is_a?(Hash) && !gems[:error]
          notable = notable_gems_list(gems)
          grouped = notable.group_by { |g| g[:category]&.to_s || "other" }
          grouped.each do |cat, gem_list|
            lines << "- #{cat}: #{gem_list.map { |g| g[:name] }.join(', ')}"
          end
        end

        conv = context[:conventions]
        if conv.is_a?(Hash) && !conv[:error]
          arch_labels = arch_labels_hash
          (conv[:architecture] || []).first(5).each { |p| lines << "- #{arch_labels[p] || p}" }
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
        lines << "" << "Global before_actions: #{before_actions.join(', ')}" if before_actions.any?

        lines << ""
        lines << "MCP tools available — see rails-mcp-tools.mdc for full reference."
        lines << "Always call with detail:\"summary\" first, then drill into specifics."

        lines.join("\n")
      end

      # Auto-attached when working in app/models/
      def render_models_rule
        models = context[:models]
        return nil unless models.is_a?(Hash) && !models[:error] && models.any?

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

        lines << "Check here first for scopes, constants, associations. Read model files for business logic/methods."
        lines << ""

        models.keys.sort.first(30).each do |name|
          data = models[name]
          assocs = (data[:associations] || []).size
          lines << "- #{name} (#{assocs} associations, table: #{data[:table_name] || '?'})"
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
        data = context[:controllers]
        return nil unless data.is_a?(Hash) && !data[:error]
        controllers = data[:controllers] || {}
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

        lines.concat(render_compact_controllers_list(controllers))

        lines << ""
        lines << "Use `rails_get_controllers` MCP tool with controller:\"Name\" for full detail."

        lines.join("\n")
      end

      # Agent-requested MCP tool reference — loaded on-demand when agent needs tool guidance
      def render_mcp_tools_rule
        lines = [
          "---",
          "description: \"Rails MCP tools reference — #{tool_count} tools for schema, models, routes, controllers, search, testing, and more\"",
          "alwaysApply: false",
          "---",
          ""
        ]

        lines.concat(render_tools_guide)

        lines.join("\n")
      end

      # Legacy .cursorrules fallback. Plain text, no frontmatter — Cursor's
      # chat agent reads it unconditionally in every version (unlike the
      # newer .cursor/rules/*.mdc files which some Cursor builds / modes
      # don't auto-attach to chat context). Keep it concise so it doesn't
      # bloat the agent's context window on every message.
      def render_cursorrules_legacy
        lines = [
          "# #{context[:app_name]} — Rails project rules",
          "",
          "Rails #{context[:rails_version]} | Ruby #{context[:ruby_version]}",
          ""
        ]

        schema = context[:schema]
        lines << "- Database: #{schema[:adapter]} — #{schema[:total_tables]} tables" if schema && !schema[:error]

        models = context[:models]
        lines << "- Models: #{models.size}" if models.is_a?(Hash) && !models[:error]

        routes = context[:routes]
        lines << "- Routes: #{routes[:total_routes]}" if routes && !routes[:error]

        conv = context[:conventions]
        if conv.is_a?(Hash) && !conv[:error]
          arch_labels = arch_labels_hash
          (conv[:architecture] || []).first(5).each { |p| lines << "- #{arch_labels[p] || p}" }
        end

        lines << ""
        lines << "## MCP tools"
        lines << ""
        lines << "This project has rails-ai-context installed. Use its MCP tools for ground-truth Rails context instead of guessing from file listings:"
        lines << ""
        lines << "- `rails_get_schema` — DB tables + columns + indexes"
        lines << "- `rails_get_routes` — all routes with controller actions"
        lines << "- `rails_get_model_details model:\"Name\"` — associations, validations, scopes, callbacks"
        lines << "- `rails_get_controllers controller:\"Name\"` — actions, filters, params, rendered views"
        lines << "- `rails_search_code pattern:\"...\"` — ripgrep across the app, respecting .gitignore"
        lines << "- `rails_validate file:\"path\"` — semantic validation (columns, partials, routes) before commit"
        lines << ""
        lines << "Always call with `detail:\"summary\"` first, then drill into specifics. See .cursor/rules/rails-mcp-tools.mdc for the full tool list."
        lines << ""
        lines << "## Anti-hallucination"
        lines << ""
        lines << "- Never invent column names, association names, or route paths. Call `rails_get_schema` / `rails_get_routes` / `rails_get_model_details` first."
        lines << "- Never assume a gem is installed. Check `rails_get_gems` or the Gemfile."
        lines << "- When editing an existing file, read the surrounding code via `rails_get_edit_context` before applying changes."

        lines.join("\n")
      end
    end
  end
end
