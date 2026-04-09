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
          model_broadcasts = model_broadcasts.select { |b|
            b[:stream]&.downcase&.include?(stream_lower) ||
            b[:snippet]&.downcase&.include?(stream_lower)
          }
          rb_broadcasts = rb_broadcasts.select { |b|
            b[:stream]&.downcase&.include?(stream_lower) ||
            b[:snippet]&.downcase&.include?(stream_lower)
          }
          view_subscriptions = view_subscriptions.select { |s|
            s[:stream]&.downcase&.include?(stream_lower) ||
            s[:snippet]&.downcase&.include?(stream_lower)
          }
        end

        if controller
          ctrl_lower = controller.downcase
          # Filter subscriptions and frames by controller path
          view_subscriptions = view_subscriptions.select { |s| s[:file]&.downcase&.include?(ctrl_lower) }
          view_frames = view_frames.select { |f| f[:file]&.downcase&.include?(ctrl_lower) }

          # For broadcasts: include those in the controller path OR those whose
          # stream matches any subscription that survived the filter (e.g. jobs
          # broadcasting to streams that the controller's views subscribe to)
          matched_streams = view_subscriptions.map { |s| s[:stream] }.compact
          rb_broadcasts = rb_broadcasts.select { |b|
            b[:file]&.downcase&.include?(ctrl_lower) ||
              (b[:stream] && matched_streams.any? { |ss| streams_match?(b[:stream], ss) })
          }
        end

        # Detect mismatches
        warnings = detect_mismatches(model_broadcasts, rb_broadcasts, view_subscriptions)

        filter_label = stream ? "stream:\"#{stream}\"" : controller ? "controller:\"#{controller}\"" : nil

        case detail
        when "summary"
          format_summary(model_broadcasts, rb_broadcasts, view_subscriptions, view_frames, warnings, filter_label: filter_label)
        when "standard"
          format_standard(model_broadcasts, rb_broadcasts, view_subscriptions, view_frames, warnings, filter_label: filter_label)
        when "full"
          format_full(model_broadcasts, rb_broadcasts, view_subscriptions, view_frames, warnings, filter_label: filter_label)
        else
          text_response("Unknown detail level: #{detail}. Use summary, standard, or full.")
        end
      end

      private_class_method def self.format_summary(model_broadcasts, rb_broadcasts, view_subscriptions, view_frames, warnings, filter_label: nil)
        total_broadcasts = model_broadcasts.size + rb_broadcasts.size
        turbo_data = cached_context[:turbo]
        turbo_stream_response_count = turbo_data.is_a?(Hash) && !turbo_data[:error] ? turbo_data[:turbo_stream_responses]&.size.to_i : 0

        lines = [ "# Turbo Map", "" ]
        lines << "- **Turbo Stream responses:** #{turbo_stream_response_count} (controller `.turbo_stream.erb` templates)" if turbo_stream_response_count > 0
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

      private_class_method def self.format_standard(model_broadcasts, rb_broadcasts, view_subscriptions, view_frames, warnings, filter_label: nil)
        lines = [ "# Turbo Map", "" ]

        # Turbo Drive Configuration
        turbo_data = cached_context[:turbo]
        if turbo_data.is_a?(Hash) && !turbo_data[:error]
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

        has_turbo_stream_responses = turbo_data.is_a?(Hash) && turbo_data[:turbo_stream_responses]&.any?

        if model_broadcasts.empty? && rb_broadcasts.empty? && view_subscriptions.empty? && view_frames.empty? && !has_turbo_stream_responses
          if filter_label
            lines << "_No Turbo usage matching #{filter_label}. Try without filter to see all Turbo Streams and Frames._"
          else
            lines << "_No Turbo Streams or Frames detected in this app._"
          end
        else
          lines << "_Use `detail:\"full\"` for DOM IDs and inline templates, or `stream:\"name\"` to filter._"
        end

        text_response(lines.join("\n"))
      end

      private_class_method def self.format_full(model_broadcasts, rb_broadcasts, view_subscriptions, view_frames, warnings, filter_label: nil)
        lines = [ "# Turbo Map (Full Detail)", "" ]

        # Turbo Drive Configuration & Stream Responses
        turbo_data = cached_context[:turbo]
        if turbo_data.is_a?(Hash) && !turbo_data[:error]
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
        end

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

        has_turbo_stream_responses = turbo_data.is_a?(Hash) && turbo_data[:turbo_stream_responses]&.any?

        if model_broadcasts.empty? && rb_broadcasts.empty? && view_subscriptions.empty? && view_frames.empty? && !has_turbo_stream_responses
          if filter_label
            lines << "_No Turbo usage matching #{filter_label}. Try without filter to see all Turbo Streams and Frames._"
          else
            lines << "_No Turbo Streams or Frames detected in this app._"
          end
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
      # Handles multi-line calls by joining the method line with subsequent lines
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
            lines = source.lines

            lines.each_with_index do |line, idx|
              line_num = idx + 1
              BROADCAST_METHODS.each do |method|
                next unless line.include?(method)

                # Join up to 3 subsequent lines for multi-line calls
                context_lines = lines[idx, 4].map(&:chomp).join(" ")

                stream = extract_stream_from_broadcast(context_lines, method)
                target = extract_target_from_broadcast(context_lines)
                partial = extract_partial_from_broadcast(context_lines)

                results << {
                  method: method,
                  stream: stream,
                  target: target,
                  partial: partial,
                  file: relative,
                  line: line_num,
                  snippet: context_lines.squeeze(" ").strip[0, 200]
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
      rescue => e
        $stderr.puts "[rails-ai-context] extract_stream_name_from_macro failed: #{e.message}" if ENV["DEBUG"]
        nil
      end

      # Extract stream name from broadcast_*_to call
      private_class_method def self.extract_stream_from_broadcast(line, method)
        # Try string interpolation first: "cook_#{cook.id}" → "cook_#{id}"
        interp_pattern = /#{Regexp.escape(method)}\s*\(?\s*["']([^"']*#\{[^}]+\}[^"']*)["']/
        interp_match = line.match(interp_pattern)
        if interp_match
          # Normalize: "cook_#{cook.id}" → "cook_{id}", "cook_#{@cook.id}" → "cook_{id}"
          return interp_match[1].gsub(/#\{(.+?)\}/) { |_|
            expr = $1.strip
            # Extract the last method call: "@cook.id" → "id", "cook.id" → "id", "id" → "id"
            last_method = expr.split(".").last
            "{#{last_method}}"
          }
        end

        # Try symbol: :stream_name
        # Try plain string: "stream_name"
        # Try bare identifier: stream_name
        pattern = /#{Regexp.escape(method)}\s*\(?\s*:?["']?(\w+)["']?/
        match = line.match(pattern)
        match ? match[1] : "(dynamic)"
      rescue => e
        $stderr.puts "[rails-ai-context] extract_stream_from_broadcast failed: #{e.message}" if ENV["DEBUG"]
        "(dynamic)"
      end

      # Extract target: from a broadcast call
      private_class_method def self.extract_target_from_broadcast(line)
        match = line.match(/target:\s*["'](\w+)["']/)
        match ? match[1] : nil
      rescue => e
        $stderr.puts "[rails-ai-context] extract_target_from_broadcast failed: #{e.message}" if ENV["DEBUG"]
        nil
      end

      # Extract partial: from a broadcast call
      private_class_method def self.extract_partial_from_broadcast(line)
        match = line.match(/partial:\s*["']([^"']+)["']/)
        match ? match[1] : nil
      rescue => e
        $stderr.puts "[rails-ai-context] extract_partial_from_broadcast failed: #{e.message}" if ENV["DEBUG"]
        nil
      end

      # Extract stream name from turbo_stream_from call
      private_class_method def self.extract_stream_from_subscription(line)
        # turbo_stream_from :notifications
        # turbo_stream_from "notifications"
        # turbo_stream_from @room
        # turbo_stream_from current_user, :notifications
        # turbo_stream_from "cook_#{@cook.id}"
        match = line.match(/turbo_stream_from\s+(.+?)(?:\s*%>|\s*$|\s*do\b)/)
        return "(dynamic)" unless match

        args = match[1].strip

        # Handle string interpolation: "cook_#{@cook.id}" → "cook_{id}"
        if args.include?("#")
          normalized = args.gsub(/["']/, "").gsub(/#\{(.+?)\}/) { |_|
            expr = $1.strip
            last_method = expr.split(".").last
            "{#{last_method}}"
          }
          return normalized
        end

        # Clean up and return meaningful stream name
        args.gsub(/["']/, "").gsub(/\s*,\s*/, ", ").strip
      rescue => e
        $stderr.puts "[rails-ai-context] extract_stream_from_subscription failed: #{e.message}" if ENV["DEBUG"]
        "(dynamic)"
      end

      # Extract frame ID from turbo_frame_tag call
      private_class_method def self.extract_frame_id(line)
        # turbo_frame_tag "frame_id"
        # turbo_frame_tag :frame_id
        # turbo_frame_tag dom_id(@model)
        match = line.match(/turbo_frame_tag\s+["':]*([^"',\s)]+)/)
        match ? match[1] : "(dynamic)"
      rescue => e
        $stderr.puts "[rails-ai-context] extract_frame_id failed: #{e.message}" if ENV["DEBUG"]
        "(dynamic)"
      end

      # Extract src: from turbo_frame_tag
      private_class_method def self.extract_frame_src(line)
        match = line.match(/src:\s*["']?([^"',\s)]+)["']?/)
        match ? match[1] : nil
      rescue => e
        $stderr.puts "[rails-ai-context] extract_frame_src failed: #{e.message}" if ENV["DEBUG"]
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

        # Broadcasts without subscribers — use fuzzy matching for dynamic streams
        orphan_broadcasts = broadcast_streams.reject { |bs|
          subscription_streams.any? { |ss| streams_match?(bs, ss) }
        }
        orphan_broadcasts.each do |stream|
          source = rb_broadcasts.find { |b| b[:stream] == stream }
          source ||= model_broadcasts.find { |b| b[:stream] == stream }
          file_ref = source ? " (#{source[:file]}:#{source[:line]})" : ""
          warnings << "Broadcast to `#{stream}` has no matching `turbo_stream_from`#{file_ref}"
        end

        # Subscriptions without broadcasters — use fuzzy matching
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

      # Fuzzy-match stream names: "cook_{id}" matches "cook_{id}",
      # and static prefixes match (e.g., "cook_" prefix in both)
      private_class_method def self.streams_match?(a, b)
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

      private_class_method def self.extract_class_name(source)
        match = source.match(/class\s+([\w:]+)/)
        match[1] if match
      rescue => e
        $stderr.puts "[rails-ai-context] extract_class_name failed: #{e.message}" if ENV["DEBUG"]
        nil
      end
    end
  end
end
