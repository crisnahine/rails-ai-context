# frozen_string_literal: true

module RailsAiContext
  module Serializers
    # Generates .claude/rules/ files for Claude Code auto-discovery.
    # These provide quick-reference lists without bloating CLAUDE.md.
    class ClaudeRulesSerializer
      include StackOverviewHelper
      include DesignSystemHelper
      include ToolGuideHelper

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
          "rails-mcp-tools.md" => render_mcp_tools_reference,
          "rails-components.md" => render_components_reference,
          "rails-accessibility.md" => render_accessibility_reference
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

        lines.concat(full_preset_stack_lines)

        # ApplicationController before_actions — apply to all controllers
        begin
          root = defined?(Rails) ? Rails.root.to_s : Dir.pwd
          app_ctrl_file = File.join(root, "app", "controllers", "application_controller.rb")
          if File.exist?(app_ctrl_file)
            source = File.read(app_ctrl_file)
            before_actions = source.scan(/before_action\s+:([\w!?]+)/).flatten
            if before_actions.any?
              lines << "" << "**Global before_actions:** #{before_actions.join(', ')}"
            end
          end
        rescue; end

        lines << ""
        lines << "ALWAYS use MCP tools for context — do NOT read reference files directly."
        lines << "Start with `detail:\"summary\"`. Read files ONLY when you will Edit them."

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
          "All columns with types are listed below — no need to read db/schema.rb.",
          "For indexes, foreign keys, or constraints, use `rails_get_schema(table:\"name\")`.",
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
          # Skip standard Rails FK columns (like user_id, account_id) but keep
          # external ID columns (like paymongo_checkout_id, stripe_payment_id)
          fk_columns = (data[:foreign_keys] || []).map { |f| f[:column] }.to_set
          all_table_names = tables.keys.to_set
          key_cols = columns.select do |c|
            next true if keep_cols.include?(c[:name])
            next true if c[:name].end_with?("_type")
            next false if skip_cols.include?(c[:name])
            if c[:name].end_with?("_id")
              # Skip if it's a known FK or matches a table name (conventional Rails FK)
              ref_table = c[:name].sub(/_id\z/, "").pluralize
              next false if fk_columns.include?(c[:name]) || all_table_names.include?(ref_table)
            end
            true
          end

          col_sample = key_cols.map do |c|
            col_type = c[:array] ? "#{c[:type]}[]" : c[:type].to_s
            entry = "#{c[:name]}:#{col_type}"
            if c.key?(:default) && !c[:default].nil?
              default_display = c[:default] == "" ? '""' : c[:default]
              entry += "(=#{default_display})"
            end
            entry
          end
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
              lines << "  #{attr}: #{values.is_a?(Hash) ? values.keys.join(', ') : Array(values).join(', ')}"
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
          "Check this file first for associations, scopes, constants, and validations.",
          "If you need more detail (callbacks, methods, business logic), use `rails_get_model_details(model:\"Name\")` or Read the file directly.",
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

          # Include app-specific concerns (filter out Rails/gem internals)
          noise = %w[GeneratedAssociationMethods GeneratedAttributeMethods Kernel PP ObjectMixin
                     GlobalID Bullet ActionText Turbo ActiveStorage JSON]
          concerns = (data[:concerns] || []).select { |c|
            !noise.any? { |n| c.include?(n) } && !c.start_with?("Devise") && !c.include?("::")
          }
          lines << "  concerns: #{concerns.join(', ')}" if concerns.any?

          # Include scopes so agents know available query methods
          scopes = data[:scopes] || []
          scope_names = scopes.map { |s| s.is_a?(Hash) ? s[:name] : s }
          lines << "  scopes: #{scope_names.join(', ')}" if scopes.any?

          # Instance methods — introspector already prioritizes source-defined and filters Devise
          methods = (data[:instance_methods] || []).reject { |m| m.end_with?("=") }.first(20)
          lines << "  methods: #{methods.join(', ')}" if methods.any?

          # Include constants (e.g. STATUSES, MODES) so agents know valid values
          constants = data[:constants] || []
          constants.each do |c|
            lines << "  #{c[:name]}: #{c[:values].join(', ')}"
          end

          # Include enums so agents know valid values
          enums = data[:enums] || {}
          enums.each do |attr, values|
            lines << "  #{attr}: #{values.is_a?(Hash) ? values.keys.join(', ') : Array(values).join(', ')}"
          end
        end

        lines.join("\n")
      end

      def render_ui_patterns_reference
        vt = context[:view_templates]
        return nil unless vt.is_a?(Hash) && !vt[:error]
        patterns = vt[:ui_patterns] || {}
        components = patterns[:components] || []
        return nil if components.empty?

        lines = [ "# Design System", "" ]

        # Full design system with canonical examples
        lines.concat(render_design_system_full(context))

        # Shared partials — so agents reuse them instead of recreating
        begin
          root = defined?(Rails) ? Rails.root.to_s : Dir.pwd
          shared_dir = File.join(root, "app", "views", "shared")
          if Dir.exist?(shared_dir)
            partials = Dir.glob(File.join(shared_dir, "_*.html.erb"))
              .map { |f| File.basename(f) }
              .sort
            if partials.any?
              lines << "" << "## Shared partials (app/views/shared/)"
              partials.each { |p| lines << "- #{p}" }
            end
          end
        rescue; end

        # Helpers — so agents use existing helpers instead of creating new ones
        begin
          root = defined?(Rails) ? Rails.root.to_s : Dir.pwd
          helper_file = File.join(root, "app", "helpers", "application_helper.rb")
          if File.exist?(helper_file)
            helper_methods = File.read(helper_file).scan(/def\s+(\w+)/).flatten
            if helper_methods.any?
              lines << "" << "## Helpers (ApplicationHelper)"
              lines << helper_methods.map { |m| "- #{m}" }.join("\n")
            end
          end
        rescue; end

        # Stimulus controllers — so agents reuse existing controllers
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

      def render_components_reference
        comp = context[:components]
        return nil unless comp.is_a?(Hash) && !comp[:error]
        components = comp[:components] || []
        return nil if components.empty?

        lines = [
          "# Components (#{components.size})",
          "",
          "ViewComponent and Phlex components available for reuse.",
          "Use `rails_get_component_catalog(component:\"Name\")` for full details.",
          ""
        ]

        components.each do |c|
          slots = (c[:slots] || []).map { |s| s[:name] }
          props = (c[:props] || []).map { |p| p[:default] ? "#{p[:name]}:#{p[:default]}" : p[:name] }
          lines << "- **#{c[:name]}** (#{c[:type]})"
          lines << "  props: #{props.join(', ')}" if props.any?
          lines << "  slots: #{slots.join(', ')}" if slots.any?
        end

        lines.join("\n")
      end

      def render_accessibility_reference
        a11y = context[:accessibility]
        return nil unless a11y.is_a?(Hash) && !a11y[:error]
        summary = a11y[:summary]
        return nil unless summary

        lines = [
          "# Accessibility Patterns",
          "",
          "Score: **#{summary[:score_label]}** (#{summary[:accessibility_score]}/5)",
          "Files scanned: #{summary[:files_scanned]}",
          ""
        ]

        if a11y[:semantic_elements]&.any?
          lines << "## Semantic HTML"
          a11y[:semantic_elements].each { |el, count| lines << "- `<#{el}>`: #{count}" }
          lines << ""
        end

        if a11y[:roles]&.any?
          lines << "## ARIA Roles"
          a11y[:roles].first(10).each { |role, count| lines << "- `role=\"#{role}\"`: #{count}" }
          lines << ""
        end

        lines << "## Rules"
        lines << "- All interactive elements MUST have aria-label or visible label"
        lines << "- All images MUST have alt text (empty alt=\"\" for decorative)"
        lines << "- Use semantic HTML elements (nav, main, article) over generic divs"
        lines << "- Include sr-only text for icon-only buttons"

        lines.join("\n")
      end

      def render_mcp_tools_reference
        render_tools_guide.join("\n")
      end
    end
  end
end
