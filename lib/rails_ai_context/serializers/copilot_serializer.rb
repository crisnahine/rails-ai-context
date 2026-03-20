# frozen_string_literal: true

module RailsAiContext
  module Serializers
    # Generates GitHub Copilot instructions.
    # In :compact mode (default), produces ≤500 lines with MCP tool references.
    # In :full mode, delegates to MarkdownSerializer with Copilot header.
    class CopilotSerializer
      attr_reader :context

      def initialize(context)
        @context = context
      end

      def call
        if RailsAiContext.configuration.context_mode == :full
          FullCopilotSerializer.new(context).call
        else
          render_compact
        end
      end

      private

      def render_compact
        lines = []
        lines << "# #{context[:app_name]} — Copilot Context"
        lines << ""
        lines << "Rails #{context[:rails_version]} | Ruby #{context[:ruby_version]}"
        lines << ""

        # Stack overview
        lines << "## Stack"
        schema = context[:schema]
        lines << "- Database: #{schema[:adapter]} — #{schema[:total_tables]} tables" if schema && !schema[:error]

        models = context[:models]
        lines << "- Models: #{models.size}" if models.is_a?(Hash) && !models[:error]

        routes = context[:routes]
        if routes && !routes[:error]
          lines << "- Routes: #{routes[:total_routes]} across #{(routes[:by_controller] || {}).size} controllers"
        end

        # Gems by category
        gems = context[:gems]
        if gems.is_a?(Hash) && !gems[:error]
          notable = gems[:notable_gems] || gems[:notable] || gems[:detected] || []
          notable.group_by { |g| g[:category]&.to_s || "other" }.each do |cat, list|
            lines << "- #{cat}: #{list.map { |g| g[:name] }.join(', ')}"
          end
        end

        lines << ""

        # Models — Copilot gets more detail (up to 25 with associations)
        if models.is_a?(Hash) && !models[:error] && models.any?
          lines << "## Models (#{models.size})"
          models.keys.sort.first(25).each do |name|
            data = models[name]
            assocs = (data[:associations] || []).first(3).map { |a| "#{a[:type]} :#{a[:name]}" }.join(", ")
            line = "- **#{name}**"
            line += " — #{assocs}" unless assocs.empty?
            lines << line
          end
          lines << "- _...#{models.size - 25} more_" if models.size > 25
          lines << ""
        end

        # Architecture
        conv = context[:conventions]
        if conv.is_a?(Hash) && !conv[:error]
          arch = conv[:architecture] || []
          patterns = conv[:patterns] || []
          if arch.any? || patterns.any?
            lines << "## Architecture"
            arch.each { |p| lines << "- #{p}" }
            patterns.first(10).each { |p| lines << "- #{p}" }
            lines << ""
          end
        end

        # UI Patterns
        vt = context[:view_templates]
        if vt.is_a?(Hash) && !vt[:error]
          components = vt.dig(:ui_patterns, :components) || []
          if components.any?
            lines << "## UI Patterns"
            components.first(15).each { |c| next unless c[:label] && c[:classes]; lines << "- #{c[:label]}: `#{c[:classes]}`" }
            lines << ""
          end
        end

        # MCP tools
        lines << "## MCP Tool Reference"
        lines << ""
        lines << "This project has MCP tools for live introspection."
        lines << "**Always start with `detail:\"summary\"`, then drill into specifics.**"
        lines << ""
        lines << "### Detail levels (schema, routes, models, controllers)"
        lines << "- `summary` — names + counts (default limit: 50)"
        lines << "- `standard` — names + key details (default limit: 15, this is the default)"
        lines << "- `full` — everything including indexes, FKs (default limit: 5)"
        lines << ""
        lines << "### rails_get_schema"
        lines << "Params: `table`, `detail`, `limit`, `offset`, `format`"
        lines << "- `rails_get_schema(detail:\"summary\")` — all tables with column counts"
        lines << "- `rails_get_schema(table:\"users\")` — full detail for one table"
        lines << "- `rails_get_schema(detail:\"summary\", limit:20, offset:40)` — paginate"
        lines << ""
        lines << "### rails_get_model_details"
        lines << "Params: `model`, `detail`"
        lines << "- `rails_get_model_details(detail:\"summary\")` — list all model names"
        lines << "- `rails_get_model_details(model:\"User\")` — associations, validations, scopes, enums"
        lines << ""
        lines << "### rails_get_routes"
        lines << "Params: `controller`, `detail`, `limit`, `offset`"
        lines << "- `rails_get_routes(detail:\"summary\")` — route counts per controller"
        lines << "- `rails_get_routes(controller:\"users\")` — routes for one controller"
        lines << ""
        lines << "### rails_get_controllers"
        lines << "Params: `controller`, `detail`"
        lines << "- `rails_get_controllers(detail:\"summary\")` — names + action counts"
        lines << "- `rails_get_controllers(controller:\"UsersController\")` — actions, filters, params"
        lines << ""
        lines << "### Other tools"
        lines << "- `rails_get_config` — cache store, session, timezone, middleware"
        lines << "- `rails_get_test_info` — test framework, factories/fixtures, CI config"
        lines << "- `rails_get_gems` — notable gems categorized by function"
        lines << "- `rails_get_conventions` — architecture patterns, directory structure"
        lines << "- `rails_search_code(pattern:\"regex\", file_type:\"rb\", max_results:20)` — codebase search"
        lines << ""

        # Conventions
        lines << "## Conventions"
        lines << "- Follow existing patterns and naming conventions"
        lines << "- Use MCP tools to check schema before writing migrations"
        lines << "- Run `bundle exec rspec` after changes"
        lines << ""

        lines.join("\n")
      end
    end

    # Internal: full-mode Copilot serializer (wraps MarkdownSerializer)
    class FullCopilotSerializer < MarkdownSerializer
      private

      def header
        <<~MD
          # #{context[:app_name]} — Copilot Instructions

          > Rails #{context[:rails_version]} | Ruby #{context[:ruby_version]}
          > Auto-generated by rails-ai-context v#{RailsAiContext::VERSION}

          Use this context to generate code that fits this project's structure and patterns.
        MD
      end

      def footer
        <<~MD
          ---
          _Auto-generated. Run `rails ai:context` to regenerate._
        MD
      end
    end
  end
end
