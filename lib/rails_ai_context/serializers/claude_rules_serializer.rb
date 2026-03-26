# frozen_string_literal: true

module RailsAiContext
  module Serializers
    # Generates .claude/rules/ files for Claude Code auto-discovery.
    # These provide quick-reference lists without bloating CLAUDE.md.
    class ClaudeRulesSerializer
      include StackOverviewHelper
      include DesignSystemHelper

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
          lines << "  scopes: #{scopes.join(', ')}" if scopes.any?

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

      def render_mcp_tools_reference # rubocop:disable Metrics/MethodLength,Metrics/AbcSize
        lines = [
          "# Rails MCP Tools (25)",
          "",
          "This project has 25 MCP tools available via `rails ai:serve` (configured in `.mcp.json`).",
          "When MCP tools are connected, **prefer them over reading files** — they return only relevant data and save tokens.",
          "If MCP tools are not available, read files directly as usual.",
          "",
          "## What Are You Trying to Do?",
          "",
          "**Understand a feature or area:**",
          "→ `rails_analyze_feature(feature:\"cook\")` — models + controllers + routes + services + jobs + views + tests in one call",
          "→ `rails_get_context(model:\"Cook\")` — schema + model + controller + views assembled together",
          "",
          "**Understand a method (who calls it, what it calls):**",
          "→ `rails_search_code(pattern:\"can_cook?\", match_type:\"trace\")` — definition + source + siblings + all callers + test coverage",
          "",
          "**Add a field or modify a model:**",
          "→ `rails_get_schema(table:\"cooks\")` — columns, types, indexes, defaults, encrypted hints",
          "→ `rails_get_model_details(model:\"Cook\")` — associations, validations, scopes, enums, callbacks, macros",
          "",
          "**Fix a controller bug:**",
          "→ `rails_get_controllers(controller:\"CooksController\", action:\"create\")` — source + inherited filters + render map + side effects + private methods",
          "",
          "**Build or modify a view:**",
          "→ `rails_get_design_system(detail:\"standard\")` — canonical HTML/ERB patterns to copy",
          "→ `rails_get_view(controller:\"cooks\")` — templates with ivars, Turbo wiring, Stimulus refs",
          "→ `rails_get_partial_interface(partial:\"shared/status_badge\")` — what locals to pass",
          "",
          "**Write tests:**",
          "→ `rails_get_test_info(detail:\"standard\")` — framework + fixtures + test template to copy",
          "→ `rails_get_test_info(model:\"Cook\")` — existing tests for a model",
          "",
          "**Find code:**",
          "→ `rails_search_code(pattern:\"has_many\")` — regex search with 2 lines of context",
          "→ `rails_search_code(pattern:\"create\", match_type:\"definition\")` — only `def` lines",
          "→ `rails_search_code(pattern:\"can_cook\", match_type:\"call\")` — only call sites",
          "",
          "**After editing (EVERY time):**",
          "→ `rails_validate(files:[\"app/models/cook.rb\", \"app/views/cooks/new.html.erb\"], level:\"rails\")` — syntax + semantics + security",
          "",
          "## Rules (when MCP is connected)",
          "",
          "1. Prefer MCP tools over reading db/schema.rb, config/routes.rb, model files — they return structured, relevant data",
          "2. Prefer `rails_search_code` over Grep for code search — it supports trace mode and smart context",
          "3. Prefer `rails_validate` over `ruby -c` or `erb` — it includes semantic + security checks",
          "4. Read files when you need to Edit them, or when MCP tools are not available",
          "5. Start with `detail:\"summary\"` to orient, then drill into specifics",
          "",
          "## All 25 Tools",
          "",
          "| Tool | What it does |",
          "|------|-------------|",
          "| `rails_analyze_feature(feature:\"X\")` | Full-stack: models + controllers (inherited filters) + routes (helpers) + services + jobs + views + tests + gaps |",
          "| `rails_get_context(model:\"X\")` | Composite: schema + model + controller + routes + views in one call |",
          "| `rails_search_code(pattern:\"X\", match_type:\"trace\")` | Trace: definition + class context + source + siblings + callers + test coverage |",
          "| `rails_get_controllers(controller:\"X\", action:\"Y\")` | Action source + inherited filters + render map + side effects + private methods |",
          "| `rails_validate(files:[...], level:\"rails\")` | Syntax + semantic validation + Brakeman security (if installed) |",
          "| `rails_get_schema(table:\"X\")` | Columns with [indexed]/[unique]/[encrypted]/[default] + orphaned table warnings |",
          "| `rails_get_model_details(model:\"X\")` | Associations, validations, scopes (with body), enums (with backing type), macros, delegations |",
          "| `rails_get_routes(controller:\"X\")` | Routes with code-ready helpers (`cook_path(@record)`) and controller filters inline |",
          "| `rails_get_view(controller:\"X\")` | Templates with ivars, Turbo Frame/Stream IDs, Stimulus refs, partial locals |",
          "| `rails_get_design_system` | Canonical HTML/ERB copy-paste patterns for buttons, inputs, cards, modals |",
          "| `rails_get_stimulus(controller:\"X\")` | Targets, values, actions + copy-paste HTML data-attributes + reverse view lookup |",
          "| `rails_get_test_info(model:\"X\")` | Existing tests + fixture contents with relationships + test template |",
          "| `rails_get_concern(name:\"X\", detail:\"full\")` | Concern methods with full source code + which models include it |",
          "| `rails_get_callbacks(model:\"X\")` | Callbacks in Rails execution order with source |",
          "| `rails_get_edit_context(file:\"X\", near:\"Y\")` | Code around a match with class/method context + line numbers |",
          "| `rails_search_code(pattern:\"X\")` | Regex search with smart limiting + `exclude_tests` + `group_by_file` + pagination |",
          "| `rails_get_service_pattern` | Service objects: interface, dependencies, side effects, callers |",
          "| `rails_get_job_pattern` | Jobs: queue, retries, guard clauses, broadcasts, schedules |",
          "| `rails_get_env` | Environment variables + credentials keys (not values) + external services |",
          "| `rails_get_partial_interface(partial:\"X\")` | Partial locals contract: what to pass + usage examples |",
          "| `rails_get_turbo_map` | Turbo Stream/Frame wiring: broadcasts → subscriptions + mismatch warnings |",
          "| `rails_get_helper_methods` | App + framework helper methods with view cross-references |",
          "| `rails_get_config` | Database adapter, auth framework, assets stack, cache, queue, Action Cable |",
          "| `rails_get_gems` | Notable gems with versions, categories, config file locations |",
          "| `rails_get_conventions` | App patterns: auth checks, flash messages, create action template, test patterns |",
          "| `rails_security_scan` | Brakeman static analysis: SQL injection, XSS, mass assignment |"
        ]

        lines.join("\n")
      end
    end
  end
end
