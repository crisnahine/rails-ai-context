# frozen_string_literal: true

module RailsAiContext
  module Tools
    class GetMailers < BaseTool
      tool_name "rails_get_mailers"
      description "Get ActionMailer mailers: every mailer class with its delivery actions and delivery method, " \
        "and the Action Mailbox mailboxes with the routing that sends inbound mail to each. " \
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
        summary: "Mailer classes with delivery actions and delivery method, mailboxes and their routing"
      )

      annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true, open_world_hint: false)

      def self.call(mailer: nil, offset: 0, limit: nil, server_context: nil)
        blank = blank_name_response("mailer", mailer)
        return blank if blank

        fetch_section(:jobs, subject: "Mailer introspection") do |jobs|
          mailers = jobs[:mailers] || []
          # A base other mailers inherit from is not one an agent sends.
          bases = Array(jobs[:mailer_bases]).select { |base| base.is_a?(Hash) }
          base_names = bases.map { |base| base[:name] }

          if mailer
            names = mailers.map { |m| m[:name] }
            # Exact only: a substring hit answers with another mailer's actions.
            match = find_exact_match(mailer, names)
            # The listing offers a base by name, so its name answers too.
            base = !match && find_exact_match(mailer, base_names)
            return text_response(base_page(bases.find { |b| b[:name] == base })) if base
            return not_found_response("Mailer", mailer, names, recovery_tool: "omit `mailer` for all mailers") unless match

            mailers = mailers.select { |m| m[:name] == match }
          end

          page = paginate(mailers, offset: offset, limit: limit, default_limit: 50)

          lines = [ "# Mailers" ]
          # Past the end of the list, the hint below says where the end is.
          past_end = page[:items].empty? && !page[:total].zero?
          lines << "" << bases_note("mailers", base_names) if bases.any? && mailer.nil? && !past_end
          if page[:items].any?
            page[:items].each do |m|
              lines << "" << "## #{m[:name]}"
              # Configured at boot, so the static tier has no value to give.
              lines << "- **Delivery method:** #{m[:delivery_method]}" if m[:delivery_method].present?
              lines.concat(action_lines(m))
            end
          elsif page[:total].zero?
            # An empty page past the end is not an app without mailers, and the
            # hint below already says where the end is.
            lines << "_No mailers found#{" matching '#{mailer}'" if mailer}._"
          end

          lines.concat(mailbox_lines(Payload.section(cached_context, :action_mailbox))) if mailer.nil? && page[:offset].zero?
          lines << "" << page[:hint] unless page[:hint].empty?
          text_response(lines.join("\n"))
        end
      end

      HEIRS_SHOWN = 12

      private_class_method def self.mailbox_lines(data)
        routes = Array(data&.dig(:routes))
        mailboxes = Array(data&.dig(:mailboxes))
        return [] if routes.empty? && mailboxes.empty?

        lines = [ "", "## Mailboxes (Action Mailbox)" ]
        if routes.any?
          defined = mailboxes.map { |m| m[:name] }
          files = routes.map { |r| r[:file] }.uniq.map { |f| "`#{f}`" }.join(", ")
          lines << "" << "Routing, first match wins (#{files}):"
          routes.each_with_index do |r, i|
            missing = " (not defined in app/mailboxes)" unless defined.include?(r[:mailbox])
            lines << "#{i + 1}. `#{r[:pattern]}` -> #{r[:mailbox]}#{missing}"
          end
        end
        lines << "" if mailboxes.any?
        mailboxes.each do |m|
          callbacks = Array(m[:callbacks]).map { |c| "#{c[:type]} :#{c[:method]}" }
          line = "- **#{m[:name]}** (`#{m[:file]}`)"
          line += ": #{callbacks.join(', ')}" if callbacks.any?
          line += " - no route sends mail here" if routes.any? && Array(m[:routed_from]).empty?
          lines << line
        end
        lines
      end

      private_class_method def self.base_page(base)
        lines = [ "# #{base[:name]}", "",
                  "_A base class: other mailers inherit from it, so it is not counted as a mailer of its own._" ]
        lines << "" << "**File:** `#{base[:file]}`" if base[:file]
        if (declares = Array(base[:declares])).any?
          lines << "" << "**Declares** (every mailer below inherits these):"
          declares.each { |line| lines << "- `#{line}`" }
        end
        lines << "" << "**Defines:** #{Array(base[:methods]).join(', ')}" if Array(base[:methods]).any?
        if (heirs = Array(base[:inherited_by])).any?
          shown = heirs.first(HEIRS_SHOWN).join(", ")
          shown += ", ...#{heirs.size - HEIRS_SHOWN} more" if heirs.size > HEIRS_SHOWN
          lines << "" << "**Inherited by (#{heirs.size}):** #{shown}"
        end
        lines.join("\n")
      end

      # A mailer with no action of its own says where its actions are, so it does not read as
      # one that sends nothing.
      def self.action_lines(mailer)
        actions = Array(mailer[:actions])
        return [ "- **Actions:** #{actions.join(', ')}" ] if actions.any?

        parent = mailer[:parent_class]
        reason = parent ? "none declared here; inherited from `#{parent}`" : "none declared here"
        lines = [ "- **Actions:** #{RailsAiContext::Confidence.unavailable(reason)}" ]
        class_actions = Array(mailer[:class_actions])
        lines << "- **Class methods:** #{class_actions.join(', ')}" if class_actions.any?
        lines
      end
    end
  end
end
