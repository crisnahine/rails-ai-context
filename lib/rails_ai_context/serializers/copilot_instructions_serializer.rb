# frozen_string_literal: true

module RailsAiContext
  module Serializers
    # Generates .github/instructions/*.instructions.md files with applyTo frontmatter
    # for GitHub Copilot path-specific instructions.
    class CopilotInstructionsSerializer
      include StackOverviewHelper
      include DesignSystemHelper

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
            lines << "" << "**Global before_actions:** #{before_actions.join(', ')}" if before_actions.any?
          end
        rescue; end

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
          "Check here first for scopes, constants, associations. Read model files for business logic/methods.",
          ""
        ]

        models.keys.sort.first(30).each do |name|
          data = models[name]
          assocs = (data[:associations] || []).size
          lines << "- #{name} (#{assocs} associations)"
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
          ""
        ]

        lines.concat(render_design_system_full(context))

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

      def render_mcp_tools_instructions # rubocop:disable Metrics/MethodLength,Metrics/AbcSize
        lines = [
          "---",
          "applyTo: \"**/*\"",
          "excludeAgent: \"code-review\"",
          "---",
          "",
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
