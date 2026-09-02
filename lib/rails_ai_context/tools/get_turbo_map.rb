# frozen_string_literal: true

module RailsAiContext
  module Tools
    class GetTurboMap < BaseTool
      tool_name "rails_get_turbo_map"
      description "Map Turbo Streams and Frames across the app: model broadcasts, channel subscriptions, frame tags, and DOM target mismatches. " \
        "Use when: debugging Turbo Stream delivery, adding real-time updates, or understanding broadcast→subscription wiring. " \
        "Filter with stream:\"notifications\" for a specific stream, or controller:\"messages\" for one controller's Turbo usage."

      input_schema(
        properties: {
          detail: {
            type: "string",
            enum: RailsAiContext::DetailLevel::SCHEMA_ENUM,
            description: "Detail level. summary: count of streams, frames, model broadcasts. standard: each stream with source → target (default). full: everything including inline template refs and DOM IDs."
          },
          stream: {
            type: "string",
            description: "Filter by stream/channel name (e.g. 'notifications', 'messages'). Shows only broadcasts and subscriptions for this stream."
          },
          controller: {
            type: "string",
            description: "Filter by controller name (e.g. 'messages', 'comments'). Shows Turbo usage in that controller's views and actions."
          }
        }
      )

      guide_row(
        order: 19,
        mcp: "rails_get_turbo_map",
        summary: "Turbo Stream/Frame wiring + mismatch warnings"
      )

      annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true, open_world_hint: false)

      def self.call(detail: "standard", stream: nil, controller: nil, server_context: nil)
        return text_response("Turbo is not installed in this app (no `turbo-rails` gem in Gemfile.lock).") if turbo_rails_absent?

        fetch_section(:turbo, subject: "Turbo introspection") do |data|
          model_broadcasts = Payload.model_broadcasts(cached_context)
          rb_broadcasts = Payload.explicit_broadcasts(cached_context)
          view_subscriptions = Payload.stream_subscriptions(cached_context)
          view_frames = Payload.turbo_frames(cached_context)

          if stream
            stream_lower = stream.downcase
            mentions = ->(entry) { entry[:stream]&.downcase&.include?(stream_lower) || entry[:snippet]&.downcase&.include?(stream_lower) }
            model_broadcasts = model_broadcasts.select(&mentions)
            rb_broadcasts = rb_broadcasts.select(&mentions)
            view_subscriptions = view_subscriptions.select(&mentions)
          end

          if controller
            ctrl_lower = controller.downcase
            view_subscriptions = view_subscriptions.select { |s| s[:file]&.downcase&.include?(ctrl_lower) }
            view_frames = view_frames.select { |f| f[:file]&.downcase&.include?(ctrl_lower) }

            # A broadcast belongs to the controller when it sits in its path or
            # feeds a stream one of its surviving views subscribes to (a job
            # broadcasting to a stream the controller's views listen on).
            matched_streams = view_subscriptions.map { |s| s[:stream] }.compact
            rb_broadcasts = rb_broadcasts.select { |b|
              b[:file]&.downcase&.include?(ctrl_lower) ||
                (b[:stream] && matched_streams.any? { |ss| streams_match?(b[:stream], ss) })
            }
          end

          warnings = detect_mismatches(model_broadcasts, rb_broadcasts, view_subscriptions)
          filter_label = stream ? "stream:\"#{stream}\"" : controller ? "controller:\"#{controller}\"" : nil

          case detail
          when "summary"
            format_summary(model_broadcasts, rb_broadcasts, view_subscriptions, view_frames, warnings, turbo_data: data, filter_label: filter_label)
          when "standard"
            format_standard(model_broadcasts, rb_broadcasts, view_subscriptions, view_frames, warnings, turbo_data: data, filter_label: filter_label)
          when "full"
            format_full(model_broadcasts, rb_broadcasts, view_subscriptions, view_frames, warnings, turbo_data: data, filter_label: filter_label)
          end
        end
      end

      # No lockfile means unknown, not absent, so this answers false there.
      private_class_method def self.turbo_rails_absent?
        lock = RailsAiContext::GemLock.for(rails_app.root)
        !lock.missing? && !lock.present?("turbo-rails")
      rescue => e
        $stderr.puts "[rails-ai-context] turbo_rails_absent? failed: #{e.message}" if ENV["DEBUG"]
        false
      end

      private_class_method def self.format_summary(model_broadcasts, rb_broadcasts, view_subscriptions, view_frames, warnings, turbo_data:, filter_label: nil)
        turbo_stream_response_count = turbo_data[:turbo_stream_responses]&.size.to_i
        turbo_stream_template_count = turbo_data[:turbo_streams]&.size.to_i

        lines = [ "# Turbo Map", "" ]
        lines << "- **Turbo Stream responses:** #{turbo_stream_response_count} (controllers responding with `turbo_stream` format)" if turbo_stream_response_count > 0
        lines << "- **Turbo Stream templates:** #{turbo_stream_template_count} (`.turbo_stream.erb` view templates)" if turbo_stream_template_count > 0
        lines << "- **Model broadcasts:** #{model_broadcasts.size} (via `broadcasts`, `broadcasts_to`, etc.)"
        lines << "- **Explicit broadcasts:** #{rb_broadcasts.size} (via `broadcast_*_to` calls in .rb files)"
        lines << "- **Stream subscriptions:** #{view_subscriptions.size} (`turbo_stream_from` in views)"
        lines << "- **Turbo Frames:** #{view_frames.size} (`turbo_frame_tag` in views)"

        if warnings.any?
          lines << "" << "**Warnings:** #{warnings.size} potential mismatch(es) detected"
        end

        lines << ""
        lines << "_Use `detail:\"standard\"` for stream wiring, or `stream:\"name\"` to filter._"

        text_response(lines.join("\n"))
      end

      private_class_method def self.format_standard(model_broadcasts, rb_broadcasts, view_subscriptions, view_frames, warnings, turbo_data:, filter_label: nil)
        lines = [ "# Turbo Map", "" ]

        # Turbo Drive Configuration
        drive_parts = []
        drive_parts << "morph: #{turbo_data[:morph_meta] ? 'yes' : 'no'}" unless turbo_data[:morph_meta].nil?
        drive_parts << "permanent elements: #{turbo_data[:permanent_elements].size}" if turbo_data[:permanent_elements]&.any?
        if turbo_data[:turbo_drive_settings].is_a?(Hash) && turbo_data[:turbo_drive_settings].any?
          turbo_data[:turbo_drive_settings].each { |k, v| drive_parts << "#{k}: #{v}" }
        end
        if drive_parts.any?
          lines << "## Turbo Drive Configuration"
          drive_parts.each { |p| lines << "- #{p}" }
          lines << ""
        end

        # Turbo Stream responses
        if turbo_data[:turbo_stream_responses]&.any?
          lines << "## Turbo Stream Responses"
          turbo_data[:turbo_stream_responses].first(15).each do |resp|
            lines << "- `#{resp}`"
          end
          lines << ""
        end

        # .turbo_stream.erb response templates - the most common scaffold-style
        # Turbo Stream pattern. The introspector collects these via its view
        # scan; without rendering them here, an app whose streams are driven
        # entirely by templates wrongly reports "no Turbo Streams detected".
        if turbo_data[:turbo_streams]&.any?
          actions = turbo_data[:stream_actions]
          action_summary = actions.is_a?(Hash) && actions.any? ? " (actions: #{actions.map { |a, n| "#{a}×#{n}" }.join(', ')})" : ""
          lines << "## Turbo Stream Templates (#{turbo_data[:turbo_streams].size})#{action_summary}"
          turbo_data[:turbo_streams].first(20).each { |tpl| lines << "- `#{tpl}`" }
          lines << ""
        end

        # Model broadcasts
        if model_broadcasts.any?
          lines << "## Model Broadcasts (#{model_broadcasts.size})"
          model_broadcasts.each do |b|
            stream_label = b[:stream] ? " → stream: `#{b[:stream]}`" : ""
            lines << "- **#{b[:model]}** `#{b[:macro]}`#{stream_label} (`#{b[:file]}:#{b[:line]}`)"
          end
          lines << ""
        end

        # Explicit broadcasts from .rb files
        if rb_broadcasts.any?
          lines << "## Explicit Broadcasts (#{rb_broadcasts.size})"
          rb_broadcasts.each do |b|
            target_label = b[:target] ? " target: `#{b[:target]}`" : ""
            lines << "- `#{b[:method]}` → stream: `#{b[:stream]}`#{target_label} (`#{b[:file]}:#{b[:line]}`)"
          end
          lines << ""
        end

        # View subscriptions
        if view_subscriptions.any?
          lines << "## Stream Subscriptions (#{view_subscriptions.size})"
          view_subscriptions.each do |s|
            lines << "- `turbo_stream_from` `#{s[:stream]}` (`#{s[:file]}:#{s[:line]}`)"
          end
          lines << ""
        end

        # Turbo Frames
        if view_frames.any?
          lines << "## Turbo Frames (#{view_frames.size})"
          view_frames.each do |f|
            src_label = f[:src] ? " src: `#{f[:src]}`" : ""
            lines << "- `turbo_frame_tag` `#{f[:id]}`#{src_label} (`#{f[:file]}:#{f[:line]}`)"
          end
          lines << ""
        end

        # Warnings
        if warnings.any?
          lines << "## Warnings"
          warnings.each { |w| lines << "- #{w}" }
          lines << ""
        end

        has_turbo_stream_responses = turbo_data[:turbo_stream_responses]&.any?
        has_stream_templates = turbo_data[:turbo_streams]&.any?

        if model_broadcasts.empty? && rb_broadcasts.empty? && view_subscriptions.empty? && view_frames.empty? && !has_turbo_stream_responses && !has_stream_templates
          note = api_only_note("the Turbo Streams/Frames surface")
          return text_response(note) if note

          if filter_label
            lines << "_No Turbo usage matching #{filter_label}. Try without filter to see all Turbo Streams and Frames._"
          else
            lines << "_No Turbo Streams or Frames detected in this app._"
          end
          return empty_response(lines.join("\n"))
        end

        lines << "_Use `detail:\"full\"` for DOM IDs and inline templates, or `stream:\"name\"` to filter._"
        text_response(lines.join("\n"))
      end

      private_class_method def self.format_full(model_broadcasts, rb_broadcasts, view_subscriptions, view_frames, warnings, turbo_data:, filter_label: nil)
        lines = [ "# Turbo Map (Full Detail)", "" ]

        # Turbo Drive Configuration & Stream Responses
        drive_parts = []
        drive_parts << "morph: #{turbo_data[:morph_meta] ? 'yes' : 'no'}" unless turbo_data[:morph_meta].nil?
        drive_parts << "permanent elements: #{turbo_data[:permanent_elements].size}" if turbo_data[:permanent_elements]&.any?
        if turbo_data[:turbo_drive_settings].is_a?(Hash) && turbo_data[:turbo_drive_settings].any?
          turbo_data[:turbo_drive_settings].each { |k, v| drive_parts << "#{k}: #{v}" }
        end
        if drive_parts.any?
          lines << "## Turbo Drive Configuration"
          drive_parts.each { |p| lines << "- #{p}" }
          lines << ""
        end

        # Turbo Stream responses
        if turbo_data[:turbo_stream_responses]&.any?
          lines << "## Turbo Stream Responses (#{turbo_data[:turbo_stream_responses].size})"
          turbo_data[:turbo_stream_responses].each do |resp|
            lines << "- `#{resp}`"
          end
          lines << ""
        end

        # .turbo_stream.erb response templates (scaffold-style Turbo Streams).
        if turbo_data[:turbo_streams]&.any?
          lines << "## Turbo Stream Templates (#{turbo_data[:turbo_streams].size})"
          turbo_data[:turbo_streams].each { |tpl| lines << "- `#{tpl}`" }
          actions = turbo_data[:stream_actions]
          lines << "- **Actions used:** #{actions.map { |a, n| "#{a}×#{n}" }.join(', ')}" if actions.is_a?(Hash) && actions.any?
          lines << ""
        end

        # Model broadcasts with full context
        if model_broadcasts.any?
          lines << "## Model Broadcasts (#{model_broadcasts.size})"
          model_broadcasts.each do |b|
            lines << "### #{b[:model]} - `#{b[:macro]}`"
            lines << "- **File:** `#{b[:file]}:#{b[:line]}`"
            lines << "- **Stream:** `#{b[:stream]}`" if b[:stream]
            lines << "- **Snippet:** `#{b[:snippet]}`" if b[:snippet]
            lines << ""
          end
        end

        # Explicit broadcasts with full context
        if rb_broadcasts.any?
          lines << "## Explicit Broadcasts (#{rb_broadcasts.size})"
          rb_broadcasts.each do |b|
            lines << "### `#{b[:method]}` → `#{b[:stream]}`"
            lines << "- **File:** `#{b[:file]}:#{b[:line]}`"
            lines << "- **Target:** `#{b[:target]}`" if b[:target]
            lines << "- **Partial:** `#{b[:partial]}`" if b[:partial]
            lines << "- **Snippet:** `#{b[:snippet]}`" if b[:snippet]
            lines << ""
          end
        end

        # View subscriptions with full context
        if view_subscriptions.any?
          lines << "## Stream Subscriptions (#{view_subscriptions.size})"
          view_subscriptions.each do |s|
            lines << "- `turbo_stream_from` `#{s[:stream]}` - `#{s[:file]}:#{s[:line]}`"
            lines << "  ```erb"
            lines << "  #{s[:snippet]}"
            lines << "  ```" if s[:snippet]
          end
          lines << ""
        end

        # Turbo Frames with full context
        if view_frames.any?
          lines << "## Turbo Frames (#{view_frames.size})"
          view_frames.each do |f|
            lines << "### `turbo_frame_tag` `#{f[:id]}`"
            lines << "- **File:** `#{f[:file]}:#{f[:line]}`"
            lines << "- **src:** `#{f[:src]}`" if f[:src]
            lines << "- **Snippet:** `#{f[:snippet]}`" if f[:snippet]
            lines << ""
          end
        end

        # Wiring map: match broadcast streams to subscription streams
        stream_wiring = build_stream_wiring(model_broadcasts, rb_broadcasts, view_subscriptions)
        if stream_wiring.any?
          lines << "## Stream Wiring"
          stream_wiring.each do |stream_name, wiring|
            lines << "### Stream: `#{stream_name}`"
            if wiring[:broadcasters].any?
              lines << "- **Broadcasters:** #{wiring[:broadcasters].map { |b| "`#{b}`" }.join(', ')}"
            end
            if wiring[:subscribers].any?
              lines << "- **Subscribers:** #{wiring[:subscribers].map { |s| "`#{s}`" }.join(', ')}"
            end
            if wiring[:broadcasters].any? && wiring[:subscribers].empty?
              lines << "- _No subscribers found for this stream_"
            end
            if wiring[:subscribers].any? && wiring[:broadcasters].empty?
              lines << "- _No broadcasters found for this stream_"
            end
            lines << ""
          end
        end

        # Warnings
        if warnings.any?
          lines << "## Warnings"
          warnings.each { |w| lines << "- #{w}" }
          lines << ""
        end

        has_turbo_stream_responses = turbo_data[:turbo_stream_responses]&.any?
        has_stream_templates = turbo_data[:turbo_streams]&.any?

        if model_broadcasts.empty? && rb_broadcasts.empty? && view_subscriptions.empty? && view_frames.empty? && !has_turbo_stream_responses && !has_stream_templates
          note = api_only_note("the Turbo Streams/Frames surface")
          return text_response(note) if note

          if filter_label
            lines << "_No Turbo usage matching #{filter_label}. Try without filter to see all Turbo Streams and Frames._"
          else
            lines << "_No Turbo Streams or Frames detected in this app._"
          end
          return empty_response(lines.join("\n"))
        end

        text_response(lines.join("\n"))
      end

      # Detect mismatches between broadcasts and subscriptions
      private_class_method def self.detect_mismatches(model_broadcasts, rb_broadcasts, view_subscriptions)
        warnings = []

        # Collect all broadcast stream names
        broadcast_streams = Set.new
        model_broadcasts.each { |b| broadcast_streams << b[:stream] if b[:stream] && !b[:stream].include?("dynamic") && !b[:stream].include?("self") }
        rb_broadcasts.each { |b| broadcast_streams << b[:stream] if b[:stream] && !b[:stream].include?("dynamic") }

        # Collect all subscription stream names
        subscription_streams = Set.new
        view_subscriptions.each { |s| subscription_streams << s[:stream] if s[:stream] && !s[:stream].include?("dynamic") }

        # Broadcasts without subscribers - use fuzzy matching for dynamic streams
        orphan_broadcasts = broadcast_streams.reject { |bs|
          subscription_streams.any? { |ss| streams_match?(bs, ss) }
        }
        orphan_broadcasts.each do |stream|
          source = rb_broadcasts.find { |b| b[:stream] == stream }
          source ||= model_broadcasts.find { |b| b[:stream] == stream }
          file_ref = source ? " (#{source[:file]}:#{source[:line]})" : ""
          warnings << "Broadcast to `#{stream}` has no matching `turbo_stream_from`#{file_ref}"
        end

        # Subscriptions without broadcasters - use fuzzy matching
        orphan_subscriptions = subscription_streams.reject { |ss|
          broadcast_streams.any? { |bs| streams_match?(bs, ss) }
        }
        orphan_subscriptions.each do |stream|
          next if stream.include?(",") || stream.include?("@")
          source = view_subscriptions.find { |s| s[:stream] == stream }
          file_ref = source ? " (#{source[:file]}:#{source[:line]})" : ""
          warnings << "Subscription to `#{stream}` has no matching broadcast#{file_ref}"
        end

        warnings.sort
      rescue => e
        $stderr.puts "[rails-ai-context] detect_mismatches failed: #{e.message}" if ENV["DEBUG"]
        []
      end

      # Fuzzy-match stream names: "post_{id}" matches "post_{id}",
      # and static prefixes match (e.g., "post_" prefix in both).
      # `@post` and `post` are the same record stream seen from a view
      # ivar vs a model-side local, so ivar sigils are stripped first.
      private_class_method def self.streams_match?(a, b)
        a = a.to_s.delete_prefix("@")
        b = b.to_s.delete_prefix("@")
        return true if a == b

        # Compare static prefixes for dynamic streams (containing {})
        if a.include?("{") || b.include?("{")
          prefix_a = a.split("{").first.to_s
          prefix_b = b.split("{").first.to_s
          return true if prefix_a == prefix_b && prefix_a.length > 0
        end

        false
      end

      # Build a wiring map: stream name → { broadcasters: [...], subscribers: [...] }
      private_class_method def self.build_stream_wiring(model_broadcasts, rb_broadcasts, view_subscriptions)
        wiring = {}

        model_broadcasts.each do |b|
          next unless b[:stream] && !b[:stream].include?("dynamic")
          wiring[b[:stream]] ||= { broadcasters: [], subscribers: [] }
          wiring[b[:stream]][:broadcasters] << "#{b[:model]}.#{b[:macro]} (#{b[:file]}:#{b[:line]})"
        end

        rb_broadcasts.each do |b|
          next unless b[:stream] && !b[:stream].include?("dynamic")
          wiring[b[:stream]] ||= { broadcasters: [], subscribers: [] }
          wiring[b[:stream]][:broadcasters] << "#{b[:method]} (#{b[:file]}:#{b[:line]})"
        end

        view_subscriptions.each do |s|
          next unless s[:stream] && !s[:stream].include?("dynamic")
          wiring[s[:stream]] ||= { broadcasters: [], subscribers: [] }
          wiring[s[:stream]][:subscribers] << "#{s[:file]}:#{s[:line]}"
        end

        wiring.sort_by { |k, _| k }.to_h
      rescue => e
        $stderr.puts "[rails-ai-context] build_stream_wiring failed: #{e.message}" if ENV["DEBUG"]
        {}
      end
    end
  end
end
