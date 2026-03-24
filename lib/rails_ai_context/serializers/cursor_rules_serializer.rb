# frozen_string_literal: true

module RailsAiContext
  module Serializers
    # Generates .cursor/rules/*.mdc files in the new Cursor MDC format.
    # Each file is focused, <50 lines, with YAML frontmatter.
    # .cursorrules is deprecated by Cursor; this is the recommended format.
    class CursorRulesSerializer
      include StackOverviewHelper
      include DesignSystemHelper

      attr_reader :context

      def initialize(context)
        @context = context
      end

      # @param output_dir [String] Rails root path
      # @return [Hash] { written: [paths], skipped: [paths] }
      def call(output_dir)
        rules_dir = File.join(output_dir, ".cursor", "rules")
        FileUtils.mkdir_p(rules_dir)

        written = []
        skipped = []

        files = {
          "rails-project.mdc" => render_project_rule,
          "rails-models.mdc" => render_models_rule,
          "rails-controllers.mdc" => render_controllers_rule,
          "rails-ui-patterns.mdc" => render_ui_patterns_rule,
          "rails-mcp-tools.mdc" => render_mcp_tools_rule
        }

        files.each do |filename, content|
          next unless content
          filepath = File.join(rules_dir, filename)
          if File.exist?(filepath) && File.read(filepath) == content
            skipped << filepath
          else
            File.write(filepath, content)
            written << filepath
          end
        end

        { written: written, skipped: skipped }
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
          notable = gems[:notable_gems] || gems[:notable] || gems[:detected] || []
          grouped = notable.group_by { |g| g[:category]&.to_s || "other" }
          grouped.each do |cat, gem_list|
            lines << "- #{cat}: #{gem_list.map { |g| g[:name] }.join(', ')}"
          end
        end

        conv = context[:conventions]
        if conv.is_a?(Hash) && !conv[:error]
          arch_labels = RailsAiContext::Tools::GetConventions::ARCH_LABELS rescue {}
          (conv[:architecture] || []).first(5).each { |p| lines << "- #{arch_labels[p] || p}" }
        end

        lines.concat(full_preset_stack_lines)

        # List service objects
        begin
          root = defined?(Rails) ? Rails.root.to_s : Dir.pwd
          services_dir = File.join(root, "app", "services")
          if Dir.exist?(services_dir)
            service_files = Dir.glob(File.join(services_dir, "*.rb"))
              .map { |f| File.basename(f, ".rb").camelize }
              .reject { |s| s == "ApplicationService" }
            lines << "- Services: #{service_files.join(', ')}" if service_files.any?
          end
        rescue; end

        # List jobs
        begin
          root = defined?(Rails) ? Rails.root.to_s : Dir.pwd
          jobs_dir = File.join(root, "app", "jobs")
          if Dir.exist?(jobs_dir)
            job_files = Dir.glob(File.join(jobs_dir, "*.rb"))
              .map { |f| File.basename(f, ".rb").camelize }
              .reject { |j| j == "ApplicationJob" }
            lines << "- Jobs: #{job_files.join(', ')}" if job_files.any?
          end
        rescue; end

        # ApplicationController before_actions
        begin
          root = defined?(Rails) ? Rails.root.to_s : Dir.pwd
          app_ctrl = File.join(root, "app", "controllers", "application_controller.rb")
          if File.exist?(app_ctrl)
            source = File.read(app_ctrl)
            before_actions = source.scan(/before_action\s+:([\w!?]+)/).flatten
            lines << "" << "Global before_actions: #{before_actions.join(', ')}" if before_actions.any?
          end
        rescue; end

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
          "description: \"ActiveRecord models reference\"",
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
          scopes = (data[:scopes] || [])
          constants = (data[:constants] || [])
          if scopes.any? || constants.any?
            extras = []
            extras << "scopes: #{scopes.join(', ')}" if scopes.any?
            constants.each { |c| extras << "#{c[:name]}: #{c[:values].join(', ')}" }
            lines << "  #{extras.join(' | ')}"
          end
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
          "description: \"Controller reference\"",
          "globs:",
          "  - \"app/controllers/**/*.rb\"",
          "alwaysApply: false",
          "---",
          "",
          "# Controllers (#{controllers.size})",
          ""
        ]

        controllers.keys.sort.first(25).each do |name|
          info = controllers[name]
          action_count = info[:actions]&.size || 0
          lines << "- #{name} (#{action_count} actions)"
        end

        lines << "- ...#{controllers.size - 25} more" if controllers.size > 25
        lines << ""
        lines << "Use `rails_get_controllers` MCP tool with controller:\"Name\" for full detail."

        lines.join("\n")
      end

      def render_ui_patterns_rule
        vt = context[:view_templates]
        return nil unless vt.is_a?(Hash) && !vt[:error]
        components = vt.dig(:ui_patterns, :components) || []
        return nil if components.empty?

        lines = [
          "---",
          "description: \"Design system and UI patterns for this Rails app\"",
          "globs:",
          "  - \"app/views/**/*.erb\"",
          "alwaysApply: false",
          "---",
          ""
        ]

        lines.concat(render_design_system_full(context))

        # Shared partials
        begin
          root = defined?(Rails) ? Rails.root.to_s : Dir.pwd
          shared_dir = File.join(root, "app", "views", "shared")
          if Dir.exist?(shared_dir)
            partials = Dir.glob(File.join(shared_dir, "_*.html.erb")).map { |f| File.basename(f) }.sort
            if partials.any?
              lines << "" << "## Shared partials"
              partials.each { |p| lines << "- #{p}" }
            end
          end
        rescue; end

        # Stimulus controllers
        stim = context[:stimulus]
        if stim.is_a?(Hash) && !stim[:error]
          controllers = stim[:controllers] || []
          if controllers.any?
            names = controllers.map { |c| c[:name] || c[:file]&.gsub("_controller.js", "") }.compact.sort
            lines << "" << "## Stimulus controllers"
            lines << names.join(", ")
          end
        end

        lines.join("\n")
      end

      # Always-on MCP tool reference — strongest enforcement point for Cursor
      def render_mcp_tools_rule # rubocop:disable Metrics/MethodLength
        lines = [
          "---",
          "description: \"Rails MCP tools (16) — use for reference files, read directly if you'll edit\"",
          "alwaysApply: true",
          "---",
          "",
          "# Rails MCP Tools (16) — Use These First",
          "",
          "Use MCP for reference files (schema, routes, tests). Read files directly if you'll edit them.",
          "MCP tools return line numbers for surgical edits.",
          "",
          "- `rails_get_schema(detail:\"summary\")` → `rails_get_schema(table:\"name\")`",
          "- `rails_get_model_details(detail:\"summary\")` → `rails_get_model_details(model:\"Name\")`",
          "- `rails_get_routes(detail:\"summary\")` → `rails_get_routes(controller:\"name\")`",
          "- `rails_get_controllers(controller:\"Name\", action:\"index\")` — one action's source code",
          "- `rails_get_view(controller:\"cooks\")` — view list; `rails_get_view(path:\"cooks/index.html.erb\")` — content",
          "- `rails_get_stimulus(detail:\"summary\")` → `rails_get_stimulus(controller:\"name\")`",
          "- `rails_get_test_info(detail:\"full\")` — fixtures, factories, helpers; `(model:\"Cook\")` — existing tests",
          "- `rails_analyze_feature(feature:\"auth\")` — schema + models + controllers + routes for a feature",
          "- `rails_get_design_system` — color palette, components, canonical page examples",
          "- `rails_get_config` | `rails_get_gems` | `rails_get_conventions` | `rails_search_code`",
          "- `rails_get_edit_context(file:\"path\", near:\"keyword\")` — surgical edit context with line numbers",
          "- `rails_validate(files:[\"path\"])` — validate Ruby, ERB, JS syntax in one call",
          "",
          "After editing: use rails_validate to check syntax. Do NOT re-read files to verify."
        ]

        lines.join("\n")
      end
    end
  end
end
