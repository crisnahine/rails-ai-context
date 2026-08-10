# frozen_string_literal: true

module RailsAiContext
  module Tools
    class GetEnvConfig < BaseTool
      tool_name "rails_get_env_config"
      description "Get per-environment configuration from config/environments/*.rb: notable toggles (force_ssl, eager_load, caching, log level, queue adapter, mailer delivery) and every config key each environment sets. " \
        "Use when: comparing development vs production behavior, debugging env-specific bugs, or checking what a custom environment changes. " \
        "Filter with environment:\"production\". Omit for all environments. " \
        "For environment variables and ENV[] usage, use rails_get_env instead."

      input_schema(
        properties: {
          environment: {
            type: "string",
            description: "Show only this environment (e.g. \"production\"). Default: all environments."
          },
          offset: {
            type: "integer",
            description: "Skip this many config keys per environment for pagination. Default: 0."
          },
          limit: {
            type: "integer",
            description: "Max config keys to list per environment. Default: 50."
          }
        }
      )

      guide_row(
        order: 45,
        mcp: "rails_get_env_config(environment:\"production\")",
        cli_args: "environment=production",
        summary: "Per-environment config: notable toggles + config keys each env sets"
      )

      annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true, open_world_hint: false)

      def self.call(environment: nil, offset: 0, limit: nil, server_context: nil)
        fetch_section(:env_config, subject: "Environment config introspection") do |envs|
          list = envs[:environments] || []

          if environment
            names = list.map { |e| e[:name] }
            match = find_closest_match(environment, names)
            return not_found_response("Environment", environment, names, recovery_tool: "omit `environment` for all environments") unless match

            list = list.select { |e| e[:name] == match }
          end

          lines = [ "# Environments" ]
          lines << ""
          lines << "_Current: **#{envs[:current]}** - #{count_phrase(envs[:count], "environment file")} under config/environments/_"

          if list.any?
            list.each { |entry| render_environment(lines, entry, offset: offset, limit: limit) }
          else
            # A named environment that misses returns not_found_response above,
            # so reaching here always means the app has no environment files at
            # all - never a filter that matched nothing.
            lines << "" << "_No environment files found._"
          end

          text_response(lines.join("\n"))
        end
      end

      class << self
        private

        # Paging is per environment, so one offset/limit reads the same slice
        # of every environment listed - which is what makes comparing the same
        # page across development and production useful.
        def render_environment(lines, entry, offset:, limit:)
          lines << "" << "## #{entry[:name]}"
          lines << "_#{entry[:file]}_"

          notable = entry[:notable] || {}
          if notable.any?
            notable.each { |key, value| lines << "- **#{key}:** `#{value}`" }
          else
            lines << "- _No notable toggles set_"
          end

          keys = entry[:config_keys] || []
          return if keys.empty?

          page = paginate(keys, offset: offset, limit: limit, default_limit: 50)
          lines << "" << "**Config keys set (#{page[:total]}):** #{page[:items].map { |k| "`#{k}`" }.join(', ')}"
          lines << page[:hint] unless page[:hint].empty?
        end
      end
    end
  end
end
