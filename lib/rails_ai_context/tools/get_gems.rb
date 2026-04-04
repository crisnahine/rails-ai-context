# frozen_string_literal: true

module RailsAiContext
  module Tools
    class GetGems < BaseTool
      tool_name "rails_get_gems"
      description "Get notable gems from Gemfile.lock grouped by category: auth, jobs, frontend, API, database, testing, deploy. " \
        "Use when: checking what libraries are available before adding a dependency, or understanding the tech stack. " \
        "Filter with category:\"auth\" or category:\"database\". Omit for all categories."

      input_schema(
        properties: {
          category: {
            type: "string",
            enum: %w[auth jobs frontend api database files testing deploy all],
            description: "Filter by category. Default: all."
          },
          offset: {
            type: "integer",
            description: "Skip this many gems for pagination. Default: 0."
          },
          limit: {
            type: "integer",
            description: "Max gems to return. Default: 50."
          }
        }
      )

      annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true, open_world_hint: false)

      GEM_CONFIG_HINTS = {
        "devise" => "config/initializers/devise.rb",
        "pundit" => "app/policies/",
        "cancancan" => "app/models/ability.rb",
        "sidekiq" => "config/sidekiq.yml",
        "solid_queue" => "config/solid_queue.yml",
        "redis" => "config/initializers/redis.rb",
        "stripe" => "config/initializers/stripe.rb",
        "sentry-ruby" => "config/initializers/sentry.rb",
        "rollbar" => "config/initializers/rollbar.rb",
        "aws-sdk-s3" => "config/storage.yml",
        "pg_search" => "app/models/ (include PgSearch::Model)",
        "elasticsearch-rails" => "config/initializers/elasticsearch.rb",
        "pagy" => "config/initializers/pagy.rb",
        "kaminari" => "config/initializers/kaminari_config.rb",
        "rack-cors" => "config/initializers/cors.rb",
        "omniauth" => "config/initializers/omniauth.rb",
        "paper_trail" => "app/models/ (has_paper_trail)"
      }.freeze

      def self.call(category: "all", offset: 0, limit: nil, server_context: nil)
        gems = cached_context[:gems]
        return text_response("Gem introspection not available. Add :gems to introspectors.") unless gems
        return text_response("Gem introspection failed: #{gems[:error]}") if gems[:error]

        notable = gems[:notable_gems] || []
        notable = notable.select { |g| g[:category] == category } unless category == "all"
        sorted = notable.sort_by { |g| [ g[:category], g[:name] ] }

        page = paginate(sorted, offset: offset, limit: limit, default_limit: 50)

        lines = [ "# Notable Gems" ]

        if page[:items].any?
          current_cat = nil
          page[:items].each do |g|
            if g[:category] != current_cat
              current_cat = g[:category]
              lines << "" << "## #{current_cat.capitalize}"
            end
            config_hint = GEM_CONFIG_HINTS[g[:name]]
            version_str = g[:version] ? " `#{g[:version]}`" : ""
            line = "- **#{g[:name]}**#{version_str}: #{g[:note]}"
            line += " _(config: #{config_hint})_" if config_hint
            lines << line
          end
        else
          all_cats = (gems[:notable_gems] || []).map { |g| g[:category] }.uniq.sort
          hint = all_cats.any? ? " Available categories: #{all_cats.join(', ')}" : ""
          lines << "_No notable gems found#{" in category '#{category}'" unless category == 'all'}.#{hint}_"
        end

        lines << "" << page[:hint] unless page[:hint].empty?
        text_response(lines.join("\n"))
      end
    end
  end
end
