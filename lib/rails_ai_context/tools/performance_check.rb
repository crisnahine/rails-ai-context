# frozen_string_literal: true

module RailsAiContext
  module Tools
    class PerformanceCheck < BaseTool
      tool_name "rails_performance_check"
      description "Static analysis for Rails performance anti-patterns: N+1 query risks, " \
        "missing counter_cache, Model.all in controllers, missing foreign key indexes, " \
        "eager loading candidates. " \
        "Use when: reviewing code for performance, before deploying, or investigating slow pages. " \
        "Key params: model (filter by model), category (filter by issue type), detail level."

      input_schema(
        properties: {
          model: {
            type: "string",
            description: "Filter results to a specific model (e.g., 'User', 'Post')"
          },
          category: {
            type: "string",
            enum: %w[n_plus_one counter_cache indexes model_all eager_load all],
            description: "Filter by issue category (default: all)"
          },
          detail: {
            type: "string",
            enum: %w[summary standard full],
            description: "Level of detail: summary (counts), standard (issues + suggestions), full (+ code context)"
          }
        }
      )

      annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true, open_world_hint: false)

      def self.call(model: nil, category: "all", detail: "standard", server_context: nil)
        data = cached_context[:performance]

        unless data.is_a?(Hash) && !data[:error]
          return text_response("No performance data available. Ensure :performance introspector is enabled.")
        end

        model = model.to_s.strip if model

        # Validate model exists if specified
        if model && !model.empty?
          models_data = cached_context[:models]
          if models_data.is_a?(Hash) && !models_data[:error]
            model_names = models_data.keys.map(&:to_s)
            unless model_names.any? { |m| m.downcase == model.downcase }
              return not_found_response("Model", model, model_names,
                recovery_tool: "Call rails_performance_check() without model filter to see all issues")
            end
          end
        end

        lines = [ "# Performance Analysis", "" ]

        # Collect all items then filter, so the count reflects actual displayed results
        all_sections = {}
        all_sections[:n_plus_one] = data[:n_plus_one_risks] || []
        all_sections[:counter_cache] = data[:missing_counter_cache] || []
        all_sections[:indexes] = data[:missing_fk_indexes] || []
        all_sections[:model_all] = data[:model_all_in_controllers] || []
        all_sections[:eager_load] = data[:eager_load_candidates] || []

        # Apply model filter to count
        filtered_count = if model && !model.empty?
          all_sections.values.sum { |items| filter_items(items, model).size }
        elsif category != "all"
          (all_sections[category.to_sym] || []).size
        else
          all_sections.values.sum(&:size)
        end

        lines << "**Total issues found:** #{filtered_count}"
        lines << ""

        if detail == "summary"
          lines << "- N+1 risks: #{filter_items(all_sections[:n_plus_one], model).size}"
          lines << "- Missing counter_cache: #{filter_items(all_sections[:counter_cache], model).size}"
          lines << "- Missing FK indexes: #{filter_items(all_sections[:indexes], model).size}"
          lines << "- Model.all in controllers: #{filter_items(all_sections[:model_all], model).size}"
          lines << "- Eager load candidates: #{filter_items(all_sections[:eager_load], model).size}"
        else
          if category == "all" || category == "n_plus_one"
            lines.concat(render_section("N+1 Query Risks", data[:n_plus_one_risks], model, detail))
          end
          if category == "all" || category == "counter_cache"
            lines.concat(render_section("Missing counter_cache", data[:missing_counter_cache], model, detail))
          end
          if category == "all" || category == "indexes"
            lines.concat(render_section("Missing FK Indexes", data[:missing_fk_indexes], model, detail))
          end
          if category == "all" || category == "model_all"
            lines.concat(render_section("Model.all in Controllers", data[:model_all_in_controllers], model, detail))
          end
          if category == "all" || category == "eager_load"
            lines.concat(render_section("Eager Load Candidates", data[:eager_load_candidates], model, detail))
          end
        end

        if filtered_count == 0
          lines << "No performance issues detected#{model && !model.empty? ? " for #{model}" : ""}. Your app looks good!"
        end

        text_response(lines.join("\n"))
      end

      class << self
        private

        def filter_items(items, model_filter)
          return (items || []) unless model_filter && !model_filter.empty?
          return [] unless items&.any?

          filter_lower = model_filter.downcase
          table_form = begin
            model_filter.underscore.pluralize.downcase
          rescue => e
            $stderr.puts "[rails-ai-context] filter_items failed: #{e.message}" if ENV["DEBUG"]
            filter_lower
          end
          items.select { |i|
            (i[:model]&.downcase == filter_lower) ||
            (i[:table]&.downcase == table_form) ||
            (i[:table]&.downcase == filter_lower) ||
            (i[:table]&.downcase == model_filter.underscore.downcase)
          }
        end

        def render_section(title, items, model_filter, detail)
          return [] unless items&.any?

          filtered = filter_items(items, model_filter)
          return [] if filtered.empty?

          lines = [ "## #{title} (#{filtered.size})", "" ]

          filtered.each do |item|
            lines << "- **#{item[:model] || item[:table] || "Unknown"}**"
            lines << "  #{item[:suggestion]}" if item[:suggestion]
            if detail == "full"
              lines << "  Controller: #{item[:controller]}" if item[:controller]
              lines << "  Association: #{item[:association]}" if item[:association]
              lines << "  Column: #{item[:column]}" if item[:column]
              lines << "  Associations: #{item[:associations]&.join(', ')}" if item[:associations]
            end
            lines << ""
          end

          lines
        end
      end
    end
  end
end
