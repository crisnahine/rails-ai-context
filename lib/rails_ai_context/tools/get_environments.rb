# frozen_string_literal: true

module RailsAiContext
  module Tools
    class GetEnvironments < BaseTool
      tool_name "rails_get_environments"
      description "Get per-environment configuration from config/environments/*.rb: notable toggles (force_ssl, eager_load, caching, log level, queue adapter, mailer delivery) and every config key each environment sets. " \
        "Use when: comparing development vs production behavior, debugging env-specific bugs, or checking what a custom environment changes. " \
        "Filter with environment:\"production\". Omit for all environments."

      input_schema(
        properties: {
          environment: {
            type: "string",
            description: "Show only this environment (e.g. \"production\"). Default: all environments."
          }
        }
      )

      annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true, open_world_hint: false)

      def self.call(environment: nil, server_context: nil)
        envs = cached_context[:environments]
        return text_response("Environment introspection not available. Add :environments to introspectors.") unless envs
        return text_response("Environment introspection failed: #{envs[:error]}") if envs[:error]
        note = unavailable_note(envs)
        return text_response(note) if note

        list = envs[:environments] || []

        if environment
          names = list.map { |e| e[:name] }
          match = find_closest_match(environment, names)
          return not_found_response("Environment", environment, names, recovery_tool: "omit `environment` for all environments") unless match

          list = list.select { |e| e[:name] == match }
        end

        lines = [ "# Environments" ]
        lines << ""
        lines << "_Current: **#{envs[:current]}** - #{envs[:count]} environment file(s) under config/environments/_"

        if list.any?
          list.each { |entry| render_environment(lines, entry) }
        else
          lines << "" << "_No environment files found#{" matching '#{environment}'" if environment}._"
        end

        text_response(lines.join("\n"))
      end

      class << self
        private

        def render_environment(lines, entry)
          lines << "" << "## #{entry[:name]}"
          lines << "_#{entry[:file]}_"

          notable = entry[:notable] || {}
          if notable.any?
            notable.each { |key, value| lines << "- **#{key}:** `#{value}`" }
          else
            lines << "- _No notable toggles set_"
          end

          keys = entry[:config_keys] || []
          lines << "" << "**Config keys set (#{keys.size}):** #{keys.map { |k| "`#{k}`" }.join(', ')}" if keys.any?
        end
      end
    end
  end
end
