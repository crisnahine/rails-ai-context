# frozen_string_literal: true

module RailsAiContext
  module Serializers
    # Generates .windsurf/rules/*.md files in the new Windsurf rules format.
    # Each file is hard-capped at 5,800 characters (within Windsurf's 6K limit).
    class WindsurfRulesSerializer
      include DesignSystemHelper

      MAX_CHARS_PER_FILE = 5_800

      attr_reader :context

      def initialize(context)
        @context = context
      end

      def call(output_dir)
        rules_dir = File.join(output_dir, ".windsurf", "rules")
        FileUtils.mkdir_p(rules_dir)

        written = []
        skipped = []

        files = {
          "rails-context.md" => render_context_rule,
          "rails-ui-patterns.md" => render_ui_patterns_rule,
          "rails-mcp-tools.md" => render_mcp_tools_rule
        }

        files.each do |filename, content|
          next unless content
          # Enforce Windsurf's 6K limit
          content = content[0...MAX_CHARS_PER_FILE] if content.length > MAX_CHARS_PER_FILE

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

      def render_context_rule
        # Reuse WindsurfSerializer content
        WindsurfSerializer.new(context).call
      end

      def render_ui_patterns_rule
        vt = context[:view_templates]
        return nil unless vt.is_a?(Hash) && !vt[:error]
        components = vt.dig(:ui_patterns, :components) || []
        return nil if components.empty?

        # Compact design system for Windsurf's character budget
        lines = render_design_system(context, max_lines: 25)
        return nil if lines.empty?

        lines.join("\n")
      end

      def render_mcp_tools_rule # rubocop:disable Metrics/MethodLength
        lines = [
          "# Rails MCP Tools (16) — Use These First",
          "",
          "Use MCP for reference files (schema, routes, tests). Read directly if you'll edit.",
          "",
          "- rails_get_schema(detail:\"summary\") → rails_get_schema(table:\"name\")",
          "- rails_get_model_details(detail:\"summary\") → rails_get_model_details(model:\"Name\")",
          "- rails_get_routes(detail:\"summary\") → rails_get_routes(controller:\"name\")",
          "- rails_get_controllers(controller:\"Name\", action:\"index\") — one action's source",
          "- rails_get_view(controller:\"cooks\") — views; rails_get_view(path:\"file\") — content",
          "- rails_get_stimulus(detail:\"summary\") → rails_get_stimulus(controller:\"name\")",
          "- rails_get_test_info(detail:\"full\") — fixtures, helpers; (model:\"Cook\") — tests",
          "- rails_analyze_feature(feature:\"auth\") — schema + models + controllers + routes for a feature",
          "- rails_get_design_system — color palette, components, page examples",
          "- rails_get_config | rails_get_gems | rails_get_conventions | rails_search_code",
          "- rails_get_edit_context(file:\"path\", near:\"keyword\") — surgical edit context with line numbers",
          "- rails_validate(files:[\"path\"]) — validate Ruby, ERB, JS syntax in one call",
          "",
          "After editing: use rails_validate to check syntax. Do NOT re-read files to verify."
        ]

        lines.join("\n")
      end
    end
  end
end
