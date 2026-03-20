# frozen_string_literal: true

module RailsAiContext
  module Serializers
    # Generates compact, imperative-tone rules for project context.
    # In :compact mode (default), produces ≤200 lines pointing to MCP tools.
    # In :full mode, delegates to MarkdownSerializer with rules-style header.
    class RulesSerializer
      attr_reader :context

      def initialize(context)
        @context = context
      end

      def call
        if RailsAiContext.configuration.context_mode == :full
          FullRulesSerializer.new(context).call
        else
          render_compact
        end
      end

      private

      def render_compact
        lines = []
        lines << "# #{context[:app_name]} — Project Rules"
        lines << ""
        lines << "Rails #{context[:rails_version]} | Ruby #{context[:ruby_version]}"
        lines << ""

        # Stack overview
        schema = context[:schema]
        lines << "- Database: #{schema[:adapter]} — #{schema[:total_tables]} tables" if schema && !schema[:error]

        models = context[:models]
        lines << "- Models: #{models.size}" if models.is_a?(Hash) && !models[:error]

        routes = context[:routes]
        lines << "- Routes: #{routes[:total_routes]}" if routes && !routes[:error]

        # Gems by category
        gems = context[:gems]
        if gems.is_a?(Hash) && !gems[:error]
          notable = gems[:notable_gems] || gems[:notable] || gems[:detected] || []
          notable.group_by { |g| g[:category]&.to_s || "other" }.each do |cat, list|
            lines << "- #{cat}: #{list.map { |g| g[:name] }.join(', ')}"
          end
        end

        lines << ""

        # Key models
        if models.is_a?(Hash) && !models[:error] && models.any?
          lines << "## Models (#{models.size})"
          models.keys.sort.first(20).each do |name|
            data = models[name]
            assoc_count = (data[:associations] || []).size
            lines << "- #{name} (#{assoc_count} associations)"
          end
          lines << "- ...#{models.size - 20} more" if models.size > 20
          lines << ""
        end

        # Architecture
        conv = context[:conventions]
        if conv.is_a?(Hash) && !conv[:error]
          arch = conv[:architecture] || []
          if arch.any?
            lines << "## Architecture"
            arch.each { |p| lines << "- #{p}" }
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
        lines << "All introspection tools support detail:\"summary\"|\"standard\"|\"full\"."
        lines << "Start with summary, drill into specifics with a filter."
        lines << ""
        lines << "### rails_get_schema"
        lines << "Params: table, detail, limit, offset, format"
        lines << "- `rails_get_schema(detail:\"summary\")` — all tables with column counts"
        lines << "- `rails_get_schema(table:\"users\")` — full detail for one table"
        lines << "- `rails_get_schema(detail:\"summary\", limit:20, offset:40)` — paginate"
        lines << ""
        lines << "### rails_get_model_details"
        lines << "Params: model, detail"
        lines << "- `rails_get_model_details(detail:\"summary\")` — list model names"
        lines << "- `rails_get_model_details(model:\"User\")` — full associations, validations, scopes"
        lines << ""
        lines << "### rails_get_routes"
        lines << "Params: controller, detail, limit, offset"
        lines << "- `rails_get_routes(detail:\"summary\")` — route counts per controller"
        lines << "- `rails_get_routes(controller:\"users\")` — routes for one controller"
        lines << ""
        lines << "### rails_get_controllers"
        lines << "Params: controller, detail"
        lines << "- `rails_get_controllers(detail:\"summary\")` — names + action counts"
        lines << "- `rails_get_controllers(controller:\"UsersController\")` — full detail"
        lines << ""
        lines << "### Other tools"
        lines << "- `rails_get_config` — cache, session, middleware, timezone"
        lines << "- `rails_get_test_info` — framework, factories, CI"
        lines << "- `rails_get_gems` — categorized gem analysis"
        lines << "- `rails_get_conventions` — architecture patterns"
        lines << "- `rails_search_code(pattern:\"regex\", file_type:\"rb\", max_results:20)`"
        lines << ""

        # Rules
        lines << "## Rules"
        lines << "- Follow existing patterns and naming conventions"
        lines << "- Use MCP tools to check schema before writing migrations"
        lines << "- Run tests after changes"
        lines << ""
        lines << "---"
        lines << "_Auto-generated by rails-ai-context. Run `rails ai:context` to regenerate._"

        lines.join("\n")
      end
    end

    # Internal: full-mode rules serializer (wraps MarkdownSerializer)
    class FullRulesSerializer < MarkdownSerializer
      private

      def header
        <<~MD
          # #{context[:app_name]} — Project Rules

          Rails #{context[:rails_version]} | Ruby #{context[:ruby_version]}
        MD
      end

      def footer
        <<~MD
          ---
          _Auto-generated by rails-ai-context. Run `rails ai:context` to regenerate._
        MD
      end
    end
  end
end
