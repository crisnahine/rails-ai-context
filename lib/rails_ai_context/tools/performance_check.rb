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

      # Each category, once: the payload key it reads, the label the summary
      # counts print, and the heading the detail section prints. The two label
      # sets are spelled separately because they differ in case, and N+1 has no
      # heading here because render_n_plus_one_section writes its own.
      CATEGORIES = {
        "n_plus_one"    => [ :n_plus_one_risks,         "N+1 risks",             nil ],
        "counter_cache" => [ :missing_counter_cache,    "Missing counter_cache", "Missing counter_cache" ],
        "indexes"       => [ :missing_fk_indexes,       "Missing FK indexes",    "Missing FK Indexes" ],
        "model_all"     => [ :model_all_in_controllers, "Model.all in controllers", "Model.all in Controllers" ],
        "eager_load"    => [ :eager_load_candidates,    "Eager load candidates", "Eager Load Candidates" ]
      }.freeze

      input_schema(
        properties: {
          model: {
            type: "string",
            description: "Filter results to a specific model (e.g., 'User', 'Post')"
          },
          category: {
            type: "string",
            enum: CATEGORIES.keys + %w[all],
            description: "Filter by issue category (default: all)"
          },
          detail: RailsAiContext::DetailLevel.schema("Level of detail: summary (counts), standard (issues + suggestions), full (+ code context)")
        }
      )

      guide_row(
        order: 26,
        mcp: "rails_performance_check(model:\"X\")",
        cli_args: "model=X",
        summary: "N+1 risks, missing indexes, Model.all anti-patterns"
      )

      annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true, open_world_hint: false)

      def self.call(model: nil, category: "all", detail: "standard", server_context: nil)
        fetch_section(:performance, unusable_message: "No performance data available. Ensure :performance introspector is enabled.") do |data|
          model = model.to_s.strip if model

          # Validate model exists if specified
          if model && !model.empty?
            models_data = Payload.models(cached_context)
            if models_data.any?
              model_names = models_data.keys.map(&:to_s)
              key = fuzzy_find_key(model_names, model)
              unless key
                return not_found_response("Model", model, model_names,
                  recovery_tool: "Call rails_performance_check() without model filter to see all issues")
              end
              model = key
            end
          end

          lines = [ "# Performance Analysis", "" ]

          # Collect all items then filter, so the count reflects actual displayed results
          all_sections = CATEGORIES.transform_values { |(key, _, _)| data[key] || [] }

          # Apply model filter to count
          filtered_count = if model && !model.empty?
            all_sections.values.sum { |items| filter_items(items, model).size }
          elsif category != "all"
            (all_sections[category] || []).size
          else
            all_sections.values.sum(&:size)
          end

          lines << "**Total issues found:** #{filtered_count}"
          lines << ""

          if RailsAiContext::DetailLevel.summary?(detail)
            CATEGORIES.each do |name, (_, label, _)|
              items = filter_items(all_sections[name], model)
              counts = name == "n_plus_one" ? risk_summary_counts(items) : ""
              lines << "- #{label}: #{items.size}#{counts}"
            end
          else
            CATEGORIES.each do |name, (key, _, title)|
              next unless category == "all" || category == name

              lines.concat(
                title ? render_section(title, data[key], model, detail) : render_n_plus_one_section(data[key], model)
              )
            end
          end

          if filtered_count == 0
            scoped = []
            scoped << "for #{model}" if model && !model.empty?
            scoped << "in category '#{category}'" if category != "all"

            if scoped.empty?
              lines << "No performance issues detected. Your app looks good!"
            else
              lines << "No issues found #{scoped.join(' ')}. Other categories or models may still have issues - " \
                "call rails_performance_check() without filters for the full report."
            end
          end

          text_response(lines.join("\n"))
        end
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

        RISK_ORDER = { "high" => 0, "medium" => 1, "low" => 2 }.freeze
        RISK_BADGES = { "high" => "[HIGH]", "medium" => "[MEDIUM]", "low" => "[low]" }.freeze

        def render_n_plus_one_section(items, model_filter)
          return [] unless items&.any?

          filtered = filter_items(items, model_filter)
          return [] if filtered.empty?

          # Sort by risk: high → medium → low
          sorted = filtered.sort_by { |i| RISK_ORDER[i[:risk].to_s] || 99 }

          lines = [ "## N+1 Query Risks (#{sorted.size})#{risk_summary_counts(sorted)}", "" ]

          sorted.each do |item|
            badge = RISK_BADGES[item[:risk].to_s] || ""
            lines << "- #{badge} **#{item[:model] || "Unknown"}**.#{item[:association]}#{call_site(item)}"
            lines << "  #{item[:suggestion]}" if item[:suggestion]
            lines << ""
          end

          lines
        end

        # One association can be at risk in several actions, and those are
        # different findings. Without the call site on the row they read as
        # one line printed twice, and the section count stops adding up.
        def call_site(item)
          return "" unless item[:controller]

          action = item[:action] ? "##{item[:action]}" : ""
          " (#{item[:controller]}#{action})"
        end

        def render_section(title, items, model_filter, detail)
          return [] unless items&.any?

          filtered = filter_items(items, model_filter)
          return [] if filtered.empty?

          lines = [ "## #{title} (#{filtered.size})", "" ]

          filtered.each do |item|
            lines << "- **#{item[:model] || item[:table] || "Unknown"}**"
            lines << "  #{item[:suggestion]}" if item[:suggestion]
            if RailsAiContext::DetailLevel.full?(detail)
              lines << "  Controller: #{item[:controller]}" if item[:controller]
              lines << "  Association: #{item[:association]}" if item[:association]
              lines << "  Column: #{item[:column]}" if item[:column]
              lines << "  Associations: #{item[:associations]&.join(', ')}" if item[:associations]
            end
            lines << ""
          end

          lines
        end

        def risk_summary_counts(items)
          return "" unless items&.any? { |i| i[:risk] }
          counts = items.group_by { |i| i[:risk].to_s }
          parts = []
          parts << "#{counts["high"]&.size || 0} high" if counts["high"]
          parts << "#{counts["medium"]&.size || 0} medium" if counts["medium"]
          parts << "#{counts["low"]&.size || 0} low" if counts["low"]
          parts.any? ? " (#{parts.join(", ")})" : ""
        end
      end
    end
  end
end
