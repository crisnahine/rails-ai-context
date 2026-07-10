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
        # Rails 8's solid_queue generator writes queue.yml (worker/dispatcher
        # config) and recurring.yml (scheduled tasks) - never solid_queue.yml.
        # Checked at runtime since apps that only added the gem without
        # running the generator yet won't have either file.
        "solid_queue" => %w[config/queue.yml config/recurring.yml],
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
            config_hint = resolve_config_hint(GEM_CONFIG_HINTS[g[:name]])
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

      # A hint is either a fixed string (shown as-is, no existence check - e.g.
      # a directory convention like "app/policies/") or a list of candidate
      # config file paths to check for existence, joined to show only the
      # ones actually present. Returns nil when none of the candidates exist
      # so the tool doesn't claim a config file that isn't there.
      private_class_method def self.resolve_config_hint(hint)
        return hint if hint.is_a?(String)
        return nil unless hint.is_a?(Array)

        root = defined?(Rails) && Rails.respond_to?(:root) && Rails.root ? Rails.root : Dir.pwd
        present = hint.select { |path| File.exist?(File.join(root, path)) }
        present.any? ? present.join(", ") : nil
      end
    end
  end
end
