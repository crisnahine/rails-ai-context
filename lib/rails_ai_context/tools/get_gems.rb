# frozen_string_literal: true

module RailsAiContext
  module Tools
    class GetGems < BaseTool
      tool_name "rails_get_gems"
      description "Analyze the app's Gemfile.lock to identify notable gems, their categories (auth, jobs, frontend, API, database, testing, deploy), and what they mean for the app's architecture."

      input_schema(
        properties: {
          category: {
            type: "string",
            enum: %w[auth jobs frontend api database files testing deploy all],
            description: "Filter by category. Default: all."
          }
        }
      )

      annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true, open_world_hint: false)

      def self.call(category: "all", server_context: nil)
        gems = cached_context[:gems]
        return text_response("Gem introspection failed: #{gems[:error]}") if gems[:error]

        notable = gems[:notable_gems] || []
        notable = notable.select { |g| g[:category] == category } unless category == "all"

        lines = [ "# Gem Analysis", "" ]
        lines << "Total gems: #{gems[:total_gems]}"
        lines << ""

        if notable.any?
          current_cat = nil
          notable.sort_by { |g| [ g[:category], g[:name] ] }.each do |g|
            if g[:category] != current_cat
              current_cat = g[:category]
              lines << "" << "## #{current_cat.capitalize}"
            end
            lines << "- **#{g[:name]}** (#{g[:version]}): #{g[:note]}"
          end
        else
          lines << "_No notable gems found#{" in category '#{category}'" unless category == 'all'}._"
        end

        text_response(lines.join("\n"))
      end
    end
  end
end
