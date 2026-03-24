# frozen_string_literal: true

module RailsAiContext
  module Tools
    class GetTurboMap < BaseTool
      tool_name "rails_get_turbo_map"
      description "Map Turbo Streams and Frames across the app: model broadcasts, channel subscriptions, frame tags, and DOM target mismatches. " \
        "Use when: debugging Turbo Stream delivery, adding real-time updates, or understanding broadcast→subscription wiring. " \
        "Filter with stream:\"notifications\" for a specific stream, or controller:\"messages\" for one controller's Turbo usage."

      BROADCAST_METHODS = %w[
        broadcast_replace_to
        broadcast_append_to
        broadcast_prepend_to
        broadcast_remove_to
        broadcast_update_to
        broadcast_action_to
      ].freeze

      MODEL_BROADCAST_MACROS = %w[
        broadcasts
        broadcasts_to
        broadcasts_refreshes
        broadcasts_refreshes_to
      ].freeze

      input_schema(
        properties: {
          detail: {
            type: "string",
            enum: %w[summary standard full],
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

      annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true, open_world_hint: false)

      def self.call(detail: "standard", stream: nil, controller: nil, server_context: nil)
        root = Rails.root.to_s

        # Collect all Turbo data
        model_broadcasts = scan_model_broadcasts(root)
        rb_broadcasts = scan_rb_broadcasts(root)
        view_subscriptions = scan_view_subscriptions(root)
        view_frames = scan_view_frames(root)

        # Apply filters
        if stream
          stream_lower = stream.downcase
          model_broadcasts = model_broadcasts.select { |b| b[:stream]&.downcase&.include?(stream_lower) }
          rb_broadcasts = rb_broadcasts.select { |b| b[:stream]&.downcase&.include?(stream_lower) }
          view_subscriptions = view_subscriptions.select { |s| s[:stream]&.downcase&.include?(stream_lower) }
        end

        if controller
          ctrl_lower = controller.downcase
          rb_broadcasts = rb_broadcasts.select { |b| b[:file]&.downcase&.include?(ctrl_lower) }
          view_subscriptions = view_subscriptions.select { |s| s[:file]&.downcase&.include?(ctrl_lower) }
          view_frames = view_frames.select { |f| f[:file]&.downcase&.include?(ctrl_lower) }
        end

        # Detect mismatches
        warnings = detect_mismatches(model_broadcasts, rb_broadcasts, view_subscriptions)

        case detail
        when "summary"
          format_summary(model_broadcasts, rb_broadcasts, view_subscriptions, view_frames, warnings)
        when "standard"
          format_standard(model_broadcasts, rb_broadcasts, view_subscriptions, view_frames, warnings)
        when "full"
          format_full(model_broadcasts, rb_broadcasts, view_subscriptions, view_frames, warnings)
        else
          text_response("Unknown detail level: #{detail}. Use summary, standard, or full.")
        end
      end

      private_class_method def self.format_summary(model_broadcasts, rb_broadcasts, view_subscriptions, view_frames, warnings)
        total_broadcasts = model_broadcasts.size + rb_broadcasts.size
        lines = [ "# Turbo Map", "" ]
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

      private_class_method def self.format_standard(model_broadcasts, rb_broadcasts, view_subscriptions, view_frames, warnings)
        lines = [ "# Turbo Map", "" ]

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

        if model_broadcasts.empty? && rb_broadcasts.empty? && view_subscriptions.empty? && view_frames.empty?
          lines << "_No Turbo Streams or Frames detected in this app._"
        else
          lines << "_Use `detail:\"full\"` for DOM IDs and inline templates, or `stream:\"name\"` to filter._"
        end

        text_response(lines.join("\n"))
      end

      private_class_method def self.format_full(model_broadcasts, rb_broadcasts, view_subscriptions, view_frames, warnings)
        lines = [ "# Turbo Map (Full Detail)", "" ]

        # Model broadcasts with full context
        if model_broadcasts.any?
          lines << "## Model Broadcasts (#{model_broadcasts.size})"
          model_broadcasts.each do |b|
            lines << "### #{b[:model]} — `#{b[:macro]}`"
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
            lines << "- `turbo_stream_from` `#{s[:stream]}` — `#{s[:file]}:#{s[:line]}`"
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

        if model_broadcasts.empty? && rb_broadcasts.empty? && view_subscriptions.empty? && view_frames.empty?
          lines << "_No Turbo Streams or Frames detected in this app._"
        end

        text_response(lines.join("\n"))
      end

      # Scan models for broadcasts, broadcasts_to, broadcasts_refreshes, broadcasts_refreshes_to
      private_class_method def self.scan_model_broadcasts(root)
        results = []
        models_dir = File.join(root, "app", "models")
        return results unless Dir.exist?(models_dir)

        Dir.glob(File.join(models_dir, "**", "*.rb")).sort.each do |file|
          next if File.size(file) > max_file_size
          source = safe_read(file)
          next unless source

          relative = file.sub("#{root}/", "")
          model_name = extract_class_name(source) || File.basename(file, ".rb").camelize

          source.each_line.with_index(1) do |line, line_num|
            MODEL_BROADCAST_MACROS.each do |macro|
              next unless line.match?(/\b#{macro}\b/)

              stream = extract_stream_name_from_macro(line, macro)
              results << {
                model: model_name,
                macro: macro,
                stream: stream,
                file: relative,
                line: line_num,
                snippet: line.strip
              }
            end
          end
        end

        results
      end

      # Scan all .rb files for explicit broadcast_*_to calls
      private_class_method def self.scan_rb_broadcasts(root)
        results = []
        search_dirs = %w[app/controllers app/models app/services app/jobs app/workers app/channels].map { |d| File.join(root, d) }

        search_dirs.each do |dir|
          next unless Dir.exist?(dir)

          Dir.glob(File.join(dir, "**", "*.rb")).sort.each do |file|
            next if File.size(file) > max_file_size
            source = safe_read(file)
            next unless source

            relative = file.sub("#{root}/", "")

            source.each_line.with_index(1) do |line, line_num|
              BROADCAST_METHODS.each do |method|
                next unless line.include?(method)

                stream = extract_stream_from_broadcast(line, method)
                target = extract_target_from_broadcast(line)
                partial = extract_partial_from_broadcast(line)

                results << {
                  method: method,
                  stream: stream,
                  target: target,
                  partial: partial,
                  file: relative,
                  line: line_num,
                  snippet: line.strip
                }
              end
            end
          end
        end

        results
      end

      # Scan view files for turbo_stream_from tags
      private_class_method def self.scan_view_subscriptions(root)
        results = []
        views_dir = File.join(root, "app", "views")
        return results unless Dir.exist?(views_dir)

        Dir.glob(File.join(views_dir, "**", "*.{erb,haml,slim}")).sort.each do |file|
          next if File.size(file) > max_file_size
          source = safe_read(file)
          next unless source

          relative = file.sub("#{root}/", "")

          source.each_line.with_index(1) do |line, line_num|
            next unless line.include?("turbo_stream_from")

            stream = extract_stream_from_subscription(line)
            results << {
              stream: stream,
              file: relative,
              line: line_num,
              snippet: line.strip
            }
          end
        end

        results
      end

      # Scan view files for turbo_frame_tag
      private_class_method def self.scan_view_frames(root)
        results = []
        views_dir = File.join(root, "app", "views")
        return results unless Dir.exist?(views_dir)

        Dir.glob(File.join(views_dir, "**", "*.{erb,haml,slim}")).sort.each do |file|
          next if File.size(file) > max_file_size
          source = safe_read(file)
          next unless source

          relative = file.sub("#{root}/", "")

          source.each_line.with_index(1) do |line, line_num|
            next unless line.include?("turbo_frame_tag")

            id = extract_frame_id(line)
            src = extract_frame_src(line)
            results << {
              id: id,
              src: src,
              file: relative,
              line: line_num,
              snippet: line.strip
            }
          end
        end

        results
      end

      # Extract stream name from model broadcast macro line
      private_class_method def self.extract_stream_name_from_macro(line, macro)
        case macro
        when "broadcasts"
          # broadcasts — stream name is typically the model's plural name
          # broadcasts inserts_by: :prepend
          "self (model plural)"
        when "broadcasts_to"
          # broadcasts_to :room, inserts_by: :prepend
          match = line.match(/broadcasts_to\s+:?(\w+)/)
          match ? match[1] : nil
        when "broadcasts_refreshes"
          "self (model plural, refreshes)"
        when "broadcasts_refreshes_to"
          match = line.match(/broadcasts_refreshes_to\s+:?(\w+)/)
          match ? match[1] : nil
        end
      rescue
        nil
      end

      # Extract stream name from broadcast_*_to call
      private_class_method def self.extract_stream_from_broadcast(line, method)
        # broadcast_replace_to :stream_name, ...
        # broadcast_replace_to "stream_name", ...
        # broadcast_replace_to stream_name, ...
        pattern = /#{Regexp.escape(method)}\s*\(?\s*:?["']?(\w+)["']?/
        match = line.match(pattern)
        match ? match[1] : "(dynamic)"
      rescue
        "(dynamic)"
      end

      # Extract target: from a broadcast call
      private_class_method def self.extract_target_from_broadcast(line)
        match = line.match(/target:\s*["'](\w+)["']/)
        match ? match[1] : nil
      rescue
        nil
      end

      # Extract partial: from a broadcast call
      private_class_method def self.extract_partial_from_broadcast(line)
        match = line.match(/partial:\s*["']([^"']+)["']/)
        match ? match[1] : nil
      rescue
        nil
      end

      # Extract stream name from turbo_stream_from call
      private_class_method def self.extract_stream_from_subscription(line)
        # turbo_stream_from :notifications
        # turbo_stream_from "notifications"
        # turbo_stream_from @room
        # turbo_stream_from current_user, :notifications
        match = line.match(/turbo_stream_from\s+(.+?)(?:\s*%>|\s*$|\s*do\b)/)
        return "(dynamic)" unless match

        args = match[1].strip
        # Clean up and return meaningful stream name
        args.gsub(/["']/, "").gsub(/\s*,\s*/, ", ").strip
      rescue
        "(dynamic)"
      end

      # Extract frame ID from turbo_frame_tag call
      private_class_method def self.extract_frame_id(line)
        # turbo_frame_tag "frame_id"
        # turbo_frame_tag :frame_id
        # turbo_frame_tag dom_id(@model)
        match = line.match(/turbo_frame_tag\s+["':]*([^"',\s)]+)/)
        match ? match[1] : "(dynamic)"
      rescue
        "(dynamic)"
      end

      # Extract src: from turbo_frame_tag
      private_class_method def self.extract_frame_src(line)
        match = line.match(/src:\s*["']?([^"',\s)]+)["']?/)
        match ? match[1] : nil
      rescue
        nil
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

        # Broadcasts without subscribers
        orphan_broadcasts = broadcast_streams - subscription_streams
        orphan_broadcasts.each do |stream|
          source = rb_broadcasts.find { |b| b[:stream] == stream }
          source ||= model_broadcasts.find { |b| b[:stream] == stream }
          file_ref = source ? " (#{source[:file]}:#{source[:line]})" : ""
          warnings << "Broadcast to `#{stream}` has no matching `turbo_stream_from`#{file_ref}"
        end

        # Subscriptions without broadcasters
        orphan_subscriptions = subscription_streams - broadcast_streams
        orphan_subscriptions.each do |stream|
          # Skip dynamic/complex stream names
          next if stream.include?(",") || stream.include?("@")
          source = view_subscriptions.find { |s| s[:stream] == stream }
          file_ref = source ? " (#{source[:file]}:#{source[:line]})" : ""
          warnings << "Subscription to `#{stream}` has no matching broadcast#{file_ref}"
        end

        warnings.sort
      rescue
        []
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
      rescue
        {}
      end

      private_class_method def self.extract_class_name(source)
        match = source.match(/class\s+([\w:]+)/)
        match[1] if match
      rescue
        nil
      end

      private_class_method def self.safe_read(path)
        File.read(path, encoding: "UTF-8", invalid: :replace, undef: :replace)
      rescue
        nil
      end

      private_class_method def self.max_file_size
        RailsAiContext.configuration.max_file_size
      end
    end
  end
end
