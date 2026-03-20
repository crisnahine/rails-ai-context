# frozen_string_literal: true

module RailsAiContext
  module Serializers
    # Generates .github/instructions/*.instructions.md files with applyTo frontmatter
    # for GitHub Copilot path-specific instructions.
    class CopilotInstructionsSerializer
      attr_reader :context

      def initialize(context)
        @context = context
      end

      def call(output_dir)
        dir = File.join(output_dir, ".github", "instructions")
        FileUtils.mkdir_p(dir)

        written = []
        skipped = []

        files = {
          "rails-context.instructions.md" => render_context_instructions,
          "rails-models.instructions.md" => render_models_instructions,
          "rails-controllers.instructions.md" => render_controllers_instructions,
          "rails-ui-patterns.instructions.md" => render_ui_patterns_instructions,
          "rails-mcp-tools.instructions.md" => render_mcp_tools_instructions
        }

        files.each do |filename, content|
          next unless content
          filepath = File.join(dir, filename)
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

      def render_context_instructions
        lines = [
          "---",
          "applyTo: \"**/*\"",
          "---",
          "",
          "# #{context[:app_name] || 'Rails App'} — Overview",
          "",
          "Rails #{context[:rails_version]} | Ruby #{context[:ruby_version]}",
          ""
        ]

        schema = context[:schema]
        if schema.is_a?(Hash) && !schema[:error]
          lines << "- Database: #{schema[:adapter]} — #{schema[:total_tables]} tables"
        end

        models = context[:models]
        lines << "- Models: #{models.size}" if models.is_a?(Hash) && !models[:error]

        routes = context[:routes]
        lines << "- Routes: #{routes[:total_routes]}" if routes.is_a?(Hash) && !routes[:error]

        gems = context[:gems]
        if gems.is_a?(Hash) && !gems[:error]
          notable = gems[:notable_gems] || []
          notable.group_by { |g| g[:category]&.to_s || "other" }.first(6).each do |cat, gem_list|
            lines << "- #{cat}: #{gem_list.map { |g| g[:name] }.join(', ')}"
          end
        end

        conv = context[:conventions]
        if conv.is_a?(Hash) && !conv[:error]
          (conv[:architecture] || []).first(5).each { |p| lines << "- #{p}" }
        end

        lines << ""
        lines << "Use MCP tools for detailed data. Start with `detail:\"summary\"`."

        lines.join("\n")
      end

      def render_models_instructions
        models = context[:models]
        return nil unless models.is_a?(Hash) && !models[:error] && models.any?

        lines = [
          "---",
          "applyTo: \"app/models/**/*.rb\"",
          "---",
          "",
          "# ActiveRecord Models (#{models.size})",
          "",
          "Use `rails_get_model_details` MCP tool for full details.",
          ""
        ]

        models.keys.sort.first(30).each do |name|
          data = models[name]
          assocs = (data[:associations] || []).size
          lines << "- #{name} (#{assocs} associations)"
        end

        lines << "- ...#{models.size - 30} more" if models.size > 30
        lines.join("\n")
      end

      def render_controllers_instructions
        data = context[:controllers]
        return nil unless data.is_a?(Hash) && !data[:error]
        controllers = data[:controllers] || {}
        return nil if controllers.empty?

        lines = [
          "---",
          "applyTo: \"app/controllers/**/*.rb\"",
          "---",
          "",
          "# Controllers (#{controllers.size})",
          "",
          "Use `rails_get_controllers` MCP tool for full details.",
          ""
        ]

        controllers.keys.sort.first(25).each do |name|
          info = controllers[name]
          actions = info[:actions]&.size || 0
          lines << "- #{name} (#{actions} actions)"
        end

        lines.join("\n")
      end

      def render_ui_patterns_instructions
        vt = context[:view_templates]
        return nil unless vt.is_a?(Hash) && !vt[:error]
        components = vt.dig(:ui_patterns, :components) || []
        return nil if components.empty?

        lines = [
          "---",
          "applyTo: \"app/views/**/*.erb\"",
          "---",
          "",
          "# UI Patterns",
          ""
        ]
        components.first(15).each { |c| next unless c[:label] && c[:classes]; lines << "- #{c[:label]}: `#{c[:classes]}`" }

        lines.join("\n")
      end

      def render_mcp_tools_instructions # rubocop:disable Metrics/MethodLength
        lines = [
          "---",
          "applyTo: \"**/*\"",
          "---",
          "",
          "# Rails MCP Tools (12) — Use These First",
          "",
          "Use MCP for reference files (schema, routes, tests). Read directly if you'll edit.",
          "MCP tools return line numbers for surgical edits.",
          "**Start with `detail:\"summary\"`, then drill into specifics.**",
          "",
          "- `rails_get_schema(detail:\"summary\")` → `rails_get_schema(table:\"name\")`",
          "- `rails_get_model_details(detail:\"summary\")` → `rails_get_model_details(model:\"Name\")`",
          "- `rails_get_routes(detail:\"summary\")` → `rails_get_routes(controller:\"name\")`",
          "- `rails_get_controllers(controller:\"Name\", action:\"index\")` — one action's source code",
          "- `rails_get_view(controller:\"cooks\")` — view list; `(path:\"cooks/index.html.erb\")` — content",
          "- `rails_get_stimulus(detail:\"summary\")` → `(controller:\"name\")` — targets, actions, values",
          "- `rails_get_test_info(detail:\"full\")` — fixtures, factories, helpers; `(model:\"Cook\")` — existing tests",
          "- `rails_get_config` | `rails_get_gems` | `rails_get_conventions` | `rails_search_code`"
        ]

        lines.join("\n")
      end
    end
  end
end
