# frozen_string_literal: true

module RailsAiContext
  module Serializers
    # Generates .claude/rules/ files for Claude Code auto-discovery.
    # These provide quick-reference lists without bloating CLAUDE.md.
    class ClaudeRulesSerializer
      include StackOverviewHelper
      include ToolGuideHelper

      attr_reader :context

      def initialize(context)
        @context = context
      end

      # @param output_dir [String] Rails root path
      # @return [Hash] { written: [paths], skipped: [paths] }
      def call(output_dir)
        rules_dir = File.join(output_dir, ".claude", "rules")

        files = {
          File.join(rules_dir, "rails-context.md") => render_context_overview,
          File.join(rules_dir, "rails-schema.md") => render_schema_reference,
          File.join(rules_dir, "rails-models.md") => render_models_reference,
          File.join(rules_dir, "rails-mcp-tools.md") => render_mcp_tools_reference,
          File.join(rules_dir, "rails-components.md") => render_components_reference
        }

        write_rule_files(files)
      end

      private

      def render_context_overview
        lines = [
          "# #{context[:app_name] || 'Rails App'} — Overview",
          "",
          "Rails #{context[:rails_version]} | Ruby #{context[:ruby_version]}",
          ""
        ]

        # Compact counts — gems and architecture are already in the root file (CLAUDE.md/AGENTS.md)
        schema = context[:schema]
        if schema.is_a?(Hash) && !schema[:error]
          lines << "- Database: #{schema[:adapter]} — #{schema[:total_tables]} tables"
        end

        models = context[:models]
        lines << "- Models: #{models.size}" if models.is_a?(Hash) && !models[:error]

        routes = context[:routes]
        lines << "- Routes: #{routes[:total_routes]}" if routes.is_a?(Hash) && !routes[:error]

        lines.concat(full_preset_stack_lines)

        # ApplicationController before_actions — apply to all controllers
        before_actions = detect_before_actions
        lines << "" << "**Global before_actions:** #{before_actions.join(', ')}" if before_actions.any?

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
          "---",
          "paths:",
          '  - "db/schema.rb"',
          '  - "db/migrate/**"',
          "---",
          "",
          "# Database Tables (#{tables.size})",
          "",
          "_Snapshot — may be stale after migrations. Use `rails_get_schema(table:\"name\")` for live data._",
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
          # external ID columns (like stripe_checkout_id, stripe_payment_id)
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
          "---",
          "paths:",
          '  - "app/models/**/*.rb"',
          "---",
          "",
          "# ActiveRecord Models (#{models.size})",
          "",
          "_Quick reference — use `rails_get_model_details(model:\"Name\")` for live data with resolved concerns and callbacks._",
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
          scope_names = scope_names(scopes)
          lines << "  scopes: #{scope_names.join(', ')}" if scopes.any?

          # Instance methods — filter Devise/framework internals that add noise
          devise_noise = %w[after_remembered apply_to_attribute_or_variable clear_reset_password_token
                            clear_reset_password_token? current_password devise_modules devise_modules?
                            devise_respond_to_and_will_save_change_to_attribute?]
          methods = (data[:instance_methods] || [])
            .reject { |m| m.end_with?("=") || devise_noise.include?(m) }
            .first(20)
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

      def render_components_reference
        comp = context[:components]
        return nil unless comp.is_a?(Hash) && !comp[:error]
        components = comp[:components] || []
        return nil if components.empty?

        lines = [
          "---",
          "paths:",
          '  - "app/components/**/*.rb"',
          '  - "app/views/components/**"',
          "---",
          "",
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

      def render_mcp_tools_reference
        render_tools_guide.join("\n")
      end
    end
  end
end
