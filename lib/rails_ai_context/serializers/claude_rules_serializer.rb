# frozen_string_literal: true

module RailsAiContext
  module Serializers
    # Generates .claude/rules/ files for Claude Code auto-discovery.
    # These provide quick-reference lists without bloating CLAUDE.md.
    class ClaudeRulesSerializer
      attr_reader :context

      def initialize(context)
        @context = context
      end

      # @param output_dir [String] Rails root path
      # @return [Hash] { written: [paths], skipped: [paths] }
      def call(output_dir)
        rules_dir = File.join(output_dir, ".claude", "rules")
        FileUtils.mkdir_p(rules_dir)

        written = []
        skipped = []

        files = {
          "rails-context.md" => render_context_overview,
          "rails-schema.md" => render_schema_reference,
          "rails-models.md" => render_models_reference,
          "rails-ui-patterns.md" => render_ui_patterns_reference,
          "rails-mcp-tools.md" => render_mcp_tools_reference
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

      def render_context_overview
        lines = [
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

      def render_schema_reference
        schema = context[:schema]
        return nil unless schema.is_a?(Hash) && !schema[:error]
        tables = schema[:tables] || {}
        return nil if tables.empty?

        lines = [
          "# Database Tables (#{tables.size})",
          "",
          "DO NOT read db/schema.rb directly. Use the `rails_get_schema` MCP tool instead.",
          "Call with `detail:\"summary\"` first, then `table:\"name\"` for specifics.",
          ""
        ]

        skip_cols = %w[id created_at updated_at]
        keep_cols = %w[type deleted_at discarded_at]
        # Get enum values from models introspection if available
        models = context[:models] || {}

        tables.keys.sort.first(30).each do |name|
          data = tables[name]
          columns = data[:columns] || []
          col_count = columns.size
          pk = data[:primary_key]
          pk_display = pk.is_a?(Array) ? pk.join(", ") : (pk || "id").to_s

          # Show column names WITH types for key columns
          key_cols = columns.select do |c|
            next true if keep_cols.include?(c[:name])
            next true if c[:name].end_with?("_type")
            next false if skip_cols.include?(c[:name])
            next false if c[:name].end_with?("_id")
            true
          end

          col_sample = key_cols.first(10).map { |c| "#{c[:name]}:#{c[:type]}" }
          col_sample << "..." if key_cols.size > 10
          col_str = col_sample.any? ? " — #{col_sample.join(', ')}" : ""

          # Foreign keys
          fks = (data[:foreign_keys] || []).map { |f| "#{f[:column]}→#{f[:to_table]}" }
          fk_str = fks.any? ? " | FK: #{fks.join(', ')}" : ""

          # Key indexes (unique or composite)
          idxs = (data[:indexes] || []).select { |i| i[:unique] || Array(i[:columns]).size > 1 }
            .map { |i| i[:unique] ? "#{Array(i[:columns]).join('+')}(unique)" : Array(i[:columns]).join("+") }
          idx_str = idxs.any? ? " | Idx: #{idxs.join(', ')}" : ""

          lines << "- **#{name}** (#{col_count} cols)#{col_str}#{fk_str}#{idx_str}"

          # Include enum values if model has them
          model_name = name.classify
          model_data = models[model_name]
          if model_data.is_a?(Hash) && model_data[:enums]&.any?
            model_data[:enums].each do |attr, values|
              lines << "  #{attr}: #{values.join(', ')}"
            end
          end
        end

        if tables.size > 30
          lines << "- ...#{tables.size - 30} more tables (use `rails_get_schema` MCP tool)"
        end

        lines.join("\n")
      end

      def render_models_reference
        models = context[:models]
        return nil unless models.is_a?(Hash) && !models[:error]
        return nil if models.empty?

        lines = [
          "# ActiveRecord Models (#{models.size})",
          "",
          "DO NOT read model files to check associations/validations. Use `rails_get_model_details` MCP tool instead.",
          "Call with `detail:\"summary\"` first, then `model:\"Name\"` for specifics.",
          ""
        ]

        models.keys.sort.each do |name|
          data = models[name]
          assocs = (data[:associations] || []).size
          vals = (data[:validations] || []).size
          table = data[:table_name]
          line = "- #{name}"
          line += " (table: #{table})" if table
          line += " — #{assocs} assocs, #{vals} validations"
          lines << line
        end

        lines.join("\n")
      end

      def render_ui_patterns_reference
        vt = context[:view_templates]
        return nil unless vt.is_a?(Hash) && !vt[:error]
        patterns = vt[:ui_patterns] || {}
        components = patterns[:components] || []
        return nil if components.empty?

        lines = [ "# UI Patterns", "" ]

        scheme = patterns[:color_scheme] || {}
        parts = []
        parts << "Primary: #{scheme[:primary]}" if scheme[:primary]
        parts << "Text: #{scheme[:text]}" if scheme[:text]
        lines << parts.join(" | ") if parts.any?

        radius = patterns[:radius] || {}
        if radius.any?
          # Group by radius value to avoid repetition
          by_radius = radius.group_by { |_, r| r }.map { |r, types| "#{r} (#{types.map(&:first).join(', ')})" }
          lines << "Radius: #{by_radius.join(', ')}"
        end
        lines << ""

        lines << "## Components"
        components.first(20).each { |c| next unless c[:label] && c[:classes]; lines << "- #{c[:label]}: `#{c[:classes]}`" }

        fl = patterns[:form_layout] || {}
        if fl.any?
          lines << "" << "## Form layout"
          lines << "- Spacing: #{fl[:spacing]}" if fl[:spacing]
          lines << "- Grid: #{fl[:grid]}" if fl[:grid]
        end

        lines.join("\n")
      end

      def render_mcp_tools_reference # rubocop:disable Metrics/MethodLength,Metrics/AbcSize
        lines = [
          "# Rails MCP Tools — ALWAYS Use These First",
          "",
          "IMPORTANT: This project has live MCP tools that return parsed, up-to-date data.",
          "ALWAYS use these tools BEFORE reading files like db/schema.rb, config/routes.rb, or model source files.",
          "The tools return structured, token-efficient summaries. Reading raw files wastes tokens and may be stale.",
          "",
          "## When to use MCP tools vs Read",
          "- Use MCP for files you WON'T edit (schema, routes, understanding context)",
          "- For files you WILL edit, just Read them directly — you need Read before Edit anyway",
          "- Use MCP for orientation (summary calls) on large codebases",
          "- Skip MCP when CLAUDE.md + rules already have the info you need",
          "",
          "## MCP tools return line numbers — use for surgical edits",
          "- `rails_get_controllers(action:\"index\")` returns source with line numbers",
          "- `rails_get_model_details(model:\"Cook\")` returns file structure with line ranges",
          "- `rails_get_view(path:\"cooks/index.html.erb\")` returns full template",
          "",
          "## Reference-only files — ALWAYS use MCP instead of Read",
          "- DO NOT read db/schema.rb — use `rails_get_schema` instead",
          "- DO NOT read config/routes.rb — use `rails_get_routes` instead",
          "- DO NOT read test files for patterns — use `rails_get_test_info(detail:\"full\")` instead",
          "",
          "## Tools (12)",
          "",
          "**rails_get_schema** — database tables, columns, indexes, foreign keys",
          "- `rails_get_schema(detail:\"summary\")` — all tables with column counts",
          "- `rails_get_schema(table:\"users\")` — full detail for one table",
          "",
          "**rails_get_model_details** — associations, validations, scopes, enums, callbacks",
          "- `rails_get_model_details(detail:\"summary\")` — list all model names",
          "- `rails_get_model_details(model:\"User\")` — full detail for one model",
          "",
          "**rails_get_routes** — HTTP verbs, paths, controller actions",
          "- `rails_get_routes(detail:\"summary\")` — route counts per controller",
          "- `rails_get_routes(controller:\"users\")` — routes for one controller",
          "",
          "**rails_get_controllers** — actions, filters, strong params, action source code",
          "- `rails_get_controllers(detail:\"summary\")` — names + action counts",
          "- `rails_get_controllers(controller:\"CooksController\", action:\"index\")` — action source code + filters",
          "",
          "**rails_get_view** — view templates, partials, Stimulus references",
          "- `rails_get_view(controller:\"cooks\")` — list all views for a controller",
          "- `rails_get_view(path:\"cooks/index.html.erb\")` — full template content",
          "",
          "**rails_get_stimulus** — Stimulus controllers with targets, values, actions",
          "- `rails_get_stimulus(detail:\"summary\")` — all controllers with counts",
          "- `rails_get_stimulus(controller:\"filter-form\")` — full detail for one controller",
          "",
          "**rails_get_test_info** — test framework, fixtures, factories, helpers",
          "- `rails_get_test_info(detail:\"full\")` — fixture names, factory names, helper setup",
          "- `rails_get_test_info(model:\"Cook\")` — existing tests for a model",
          "- `rails_get_test_info(controller:\"Cooks\")` — existing controller tests",
          "",
          "**rails_get_edit_context** — surgical edit helper with line numbers",
          "- `rails_get_edit_context(file:\"app/models/cook.rb\", near:\"scope\")` — returns code around match with line numbers",
          "",
          "**rails_get_config** — cache store, session, timezone, middleware, initializers",
          "**rails_get_gems** — notable gems categorized by function",
          "**rails_get_conventions** — architecture patterns, directory structure",
          "**rails_search_code** — regex search: `rails_search_code(pattern:\"regex\", file_type:\"rb\")`"
        ]

        lines.join("\n")
      end
    end
  end
end
