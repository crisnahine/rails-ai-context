# frozen_string_literal: true

module RailsAiContext
  module Tools
    class GetActiveSupport < BaseTool
      tool_name "rails_get_active_support"
      description "Get ActiveSupport surface: concern modules across app/**/concerns, registered deprecators, MessageVerifier/MessageEncryptor usage, the ActiveSupport::Notifications events the app subscribes to and where, tagged logging, subscribed on_load hooks, and cache store. " \
        "Use when: checking framework-level wiring, finding where crypto helpers are used, or understanding boot-time hooks."

      input_schema(properties: {})

      guide_row(
        order: 44,
        mcp: "rails_get_active_support",
        summary: "Concerns registry, deprecators, MessageVerifier usage, notification subscriptions, on_load hooks, cache store"
      )

      annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true, open_world_hint: false)

      def self.call(server_context: nil)
        fetch_section(:active_support, subject: "ActiveSupport introspection") do |active_support|
          lines = [ "# ActiveSupport" ]

          render_concerns(lines, active_support[:concerns])
          render_simple_list(lines, "Deprecators", active_support[:deprecators])
          render_verifier_usage(lines, active_support[:message_verifier_usage])
          render_subscriptions(lines, active_support[:notification_subscriptions])
          render_tagged_logging(lines, active_support[:tagged_logging])
          render_on_load_hooks(lines, active_support[:on_load_hooks])
          render_cache(lines, active_support[:cache_usage])

          text_response(lines.join("\n"))
        end
      end

      class << self
        private

        # A validator in app/models/concerns is not a concern (nothing includes it); counting it
        # would disagree with rails_get_concern's count.
        def render_concerns(lines, concerns)
          concerns = concerns || {}
          validators = concerns.values.flatten.select { |m| m[:validator] }
          total = concerns.values.sum(&:size) - validators.size
          lines << "" << "## Concerns (#{total})"
          if total > 0
            concerns.each do |dir, modules|
              modules = modules.reject { |m| m[:validator] }
              next if modules.empty?

              lines << "" << "### #{dir}"
              modules.each { |m| lines << concern_line(m) }
            end
          elsif validators.any?
            lines << "_Every module under app/**/concerns is a validator, listed below._"
          else
            lines << "_No concerns found under app/**/concerns._"
          end

          return if validators.empty?

          lines << "" << "## Validators (#{validators.size})"
          validators.each { |m| lines << "- **#{m[:name]}** (`#{m[:file]}`, < #{m[:validator]})" }
        end

        def concern_line(m)
          bits = []
          bits << "included block" if m[:included_blocks].to_i > 0
          bits << "class_methods" if m[:class_methods_block]
          if m[:kind] == "class"
            bits << [ "class", m[:superclass] && "< #{m[:superclass]}" ].compact.join(" ")
          elsif !m[:uses_active_support_concern]
            bits << "plain module"
          end
          line = "- **#{m[:name]}**"
          line += " (#{bits.join(', ')})" if bits.any?
          line
        end

        # A section the introspector could not reach says so under its own
        # heading. Silently omitting it reads as "nothing here".
        def render_unavailable(lines, title, data)
          return false unless data.is_a?(Hash) && data[:unavailable]

          lines << "" << "## #{title}"
          lines << RailsAiContext::Confidence.unavailable(data[:unavailable])
          true
        end

        def render_simple_list(lines, title, items)
          return if render_unavailable(lines, title, items)

          items = Array(items)
          return if items.empty?

          lines << "" << "## #{title}"
          items.each { |i| lines << "- `#{i}`" }
        end

        def render_verifier_usage(lines, usage)
          usage = Array(usage)
          return if usage.empty?

          lines << "" << "## MessageVerifier / MessageEncryptor Usage"
          usage.each do |u|
            kinds = []
            kinds << "encryptor" if u[:encryptor]
            kinds << "verifier" if u[:verifier]
            lines << "- `#{u[:file]}` (#{kinds.join(', ')})"
          end
        end

        def render_subscriptions(lines, subscriptions)
          subscriptions = Array(subscriptions)
          return if subscriptions.empty?

          lines << "" << "## Notification Subscriptions (#{subscriptions.size})"
          subscriptions.each { |s| lines << "- `#{s[:event]}` - #{s[:via]} (`#{s[:file]}:#{s[:line]}`)" }
        end

        def render_tagged_logging(lines, tagged)
          tagged = tagged || {}
          tags = tagged[:tags]
          unavailable = tags[:unavailable] if tags.is_a?(Hash)
          return unless tagged[:configured] || unavailable

          lines << "" << "## Tagged Logging"
          if unavailable
            lines << "- **Tags:** #{RailsAiContext::Confidence.unavailable(unavailable)}"
          elsif tags&.any?
            lines << "- **Tags:** #{Array(tags).join(', ')}"
          end
          lines << "- **Configured in:** `#{tagged[:initializer]}`" if tagged[:initializer]
        end

        def render_on_load_hooks(lines, hooks)
          return if render_unavailable(lines, "Subscribed on_load Hooks", hooks)

          hooks = Array(hooks)
          return if hooks.empty?

          lines << "" << "## Subscribed on_load Hooks"
          hooks.each { |h| lines << "- `#{h[:hook]}` - #{count_phrase(h[:callbacks], "subscriber")}" }
        end

        def render_cache(lines, cache)
          return if render_unavailable(lines, "Cache Store", cache)

          cache = cache || {}
          return if cache.empty? || cache[:store].to_s.empty?

          lines << "" << "## Cache Store"
          lines << "- **Store:** #{cache[:store]}"
          lines << "- **Options:** #{Array(cache[:options]).join(', ')}" if cache[:options]&.any?
        end
      end
    end
  end
end
