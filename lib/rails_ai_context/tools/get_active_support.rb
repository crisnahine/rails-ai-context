# frozen_string_literal: true

module RailsAiContext
  module Tools
    class GetActiveSupport < BaseTool
      tool_name "rails_get_active_support"
      description "Get ActiveSupport surface: concern modules across app/**/concerns, registered deprecators, MessageVerifier/MessageEncryptor usage, tagged logging, subscribed on_load hooks, and cache store. " \
        "Use when: checking framework-level wiring, finding where crypto helpers are used, or understanding boot-time hooks."

      input_schema(properties: {})

      guide_row(
        order: 44,
        mcp: "rails_get_active_support",
        summary: "Concerns registry, deprecators, MessageVerifier usage, on_load hooks, cache store"
      )

      annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true, open_world_hint: false)

      def self.call(server_context: nil)
        fetch_section(:active_support, subject: "ActiveSupport introspection") do |active_support|
          lines = [ "# ActiveSupport" ]

          render_concerns(lines, active_support[:concerns])
          render_simple_list(lines, "Deprecators", active_support[:deprecators])
          render_verifier_usage(lines, active_support[:message_verifier_usage])
          render_tagged_logging(lines, active_support[:tagged_logging])
          render_on_load_hooks(lines, active_support[:on_load_hooks])
          render_cache(lines, active_support[:cache_usage])

          text_response(lines.join("\n"))
        end
      end

      class << self
        private

        def render_concerns(lines, concerns)
          concerns = concerns || {}
          total = concerns.values.sum(&:size)
          lines << "" << "## Concerns (#{total})"
          if concerns.any?
            concerns.each do |dir, modules|
              lines << "" << "### #{dir}"
              modules.each do |m|
                bits = []
                bits << "included block" if m[:included_blocks].to_i > 0
                bits << "class_methods" if m[:class_methods_block]
                bits << "plain module" unless m[:uses_active_support_concern]
                line = "- **#{m[:name]}**"
                line += " (#{bits.join(', ')})" if bits.any?
                lines << line
              end
            end
          else
            lines << "_No concerns found under app/**/concerns._"
          end
        end

        def render_simple_list(lines, title, items)
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

        def render_tagged_logging(lines, tagged)
          tagged = tagged || {}
          return unless tagged[:configured]

          lines << "" << "## Tagged Logging"
          lines << "- **Tags:** #{Array(tagged[:tags]).join(', ')}" if tagged[:tags]&.any?
          lines << "- **Configured in:** `#{tagged[:initializer]}`" if tagged[:initializer]
        end

        def render_on_load_hooks(lines, hooks)
          hooks = Array(hooks)
          return if hooks.empty?

          lines << "" << "## Subscribed on_load Hooks"
          hooks.each { |h| lines << "- `#{h[:hook]}` - #{count_phrase(h[:callbacks], "subscriber")}" }
        end

        def render_cache(lines, cache)
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
