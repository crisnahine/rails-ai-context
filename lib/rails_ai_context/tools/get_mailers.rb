# frozen_string_literal: true

module RailsAiContext
  module Tools
    class GetMailers < BaseTool
      tool_name "rails_get_mailers"
      description "Get ActionMailer mailers: every mailer class with its delivery actions and delivery method. " \
        "Use when: adding an email, checking which mailer sends what, or finding the action to preview/test. " \
        "Filter with mailer:\"UserMailer\". Omit for all mailers."

      input_schema(
        properties: {
          mailer: {
            type: "string",
            description: "Show only this mailer (e.g. \"UserMailer\"). Default: all mailers."
          },
          offset: {
            type: "integer",
            description: "Skip this many mailers for pagination. Default: 0."
          },
          limit: {
            type: "integer",
            description: "Max mailers to return. Default: 50."
          }
        }
      )

      guide_row(
        order: 41,
        mcp: "rails_get_mailers(mailer:\"UserMailer\")",
        cli_args: "mailer=UserMailer",
        summary: "Mailer classes with delivery actions and delivery method"
      )

      annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true, open_world_hint: false)

      def self.call(mailer: nil, offset: 0, limit: nil, server_context: nil)
        fetch_section(:jobs, subject: "Mailer introspection") do |jobs|
          mailers = jobs[:mailers] || []

          if mailer
            names = mailers.map { |m| m[:name] }
            match = find_closest_match(mailer, names)
            return not_found_response("Mailer", mailer, names, recovery_tool: "omit `mailer` for all mailers") unless match

            mailers = mailers.select { |m| m[:name] == match }
          end

          page = paginate(mailers, offset: offset, limit: limit, default_limit: 50)

          lines = [ "# Mailers" ]
          if page[:items].any?
            page[:items].each do |m|
              lines << "" << "## #{m[:name]}"
              # Configured at boot, so the static tier has no value to give.
              lines << "- **Delivery method:** #{m[:delivery_method]}" if m[:delivery_method].present?
              lines << "- **Actions:** #{Array(m[:actions]).join(', ')}"
            end
          else
            lines << "_No mailers found#{" matching '#{mailer}'" if mailer}._"
          end

          lines << "" << page[:hint] unless page[:hint].empty?
          text_response(lines.join("\n"))
        end
      end
    end
  end
end
