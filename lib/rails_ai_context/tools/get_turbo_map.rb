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
          detail: RailsAiContext::DetailLevel.schema("Detail level. summary: count of streams, frames, model broadcasts. standard: each stream with source → target (default). full: everything including inline template refs and DOM IDs."),
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

      # Long enough to show the shape of an app's stream responses, short
      # enough not to bury the rest of the map. `detail:"full"` prints them all.
      STREAM_RESPONSE_CAP = 15

      annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true, open_world_hint: false)

      # What the filters left, in one value: every formatter needs all five.
      Found = Data.define(:model_broadcasts, :rb_broadcasts, :view_subscriptions, :view_frames, :wiring, :warnings)

      def self.call(detail: "standard", stream: nil, controller: nil, server_context: nil)
        # An MCP client sends "" for an argument it leaves unset, which is no
        # filter at all - and a name of no segments matches nothing.
        stream = nil if stream.to_s.strip.empty?
        controller = nil if controller.to_s.delete("/").strip.empty?
        return text_response("Turbo is not installed in this app (no `turbo-rails` gem in Gemfile.lock).") if turbo_rails_absent?

        fetch_section(:turbo, subject: "Turbo introspection") do |data|
          model_broadcasts = Payload.model_broadcasts(cached_context)
          rb_broadcasts = Payload.explicit_broadcasts(cached_context)
          view_subscriptions = Payload.stream_subscriptions(cached_context)
          view_frames = Payload.turbo_frames(cached_context)
          # Whether a stream is wired is a fact about the whole app: a filter
          # narrows what is shown, not who can reach whom.
          wiring = build_stream_wiring(model_broadcasts, rb_broadcasts, view_subscriptions)

          if stream
            stream_lower = stream.downcase
            names = lambda do |entry|
              labelled = entry[:streams] ? entry[:streams].map { |parts| parts_label(parts) } : [ entry[:parts] ? parts_label(entry[:parts]) : entry[:stream] ]
              labelled.compact
            end
            mentions = ->(entry) { names.call(entry).any? { |name| name.downcase.include?(stream_lower) } || entry[:snippet]&.downcase&.include?(stream_lower) }
            all_streams = (model_broadcasts + rb_broadcasts + view_subscriptions).flat_map(&names).uniq.sort
            model_broadcasts = model_broadcasts.select(&mentions)
            rb_broadcasts = rb_broadcasts.select(&mentions)
            view_subscriptions = view_subscriptions.select(&mentions)
            # The frames and responses are not streams, so the answer was the
            # whole map with no word that the filter matched nothing.
            if model_broadcasts.empty? && rb_broadcasts.empty? && view_subscriptions.empty?
              known = all_streams.any? ? " Streams in this app: #{all_streams.map { |s| "`#{s}`" }.join(', ')}." : ""
              return empty_response("No broadcast or `turbo_stream_from` matches stream:\"#{echo_input(stream)}\".#{known}")
            end
          end

          if controller
            ctrl_lower = controller.downcase
            view_subscriptions = view_subscriptions.select { |s| controller_file?(s[:file], ctrl_lower) }
            view_frames = view_frames.select { |f| controller_file?(f[:file], ctrl_lower) }

            # A broadcast belongs to the controller when it sits in its path or
            # feeds a stream one of its surviving views subscribes to (a job
            # broadcasting to a stream the controller's views listen on).
            models = Payload.models(cached_context)
            subscribed = subscription_streams(view_subscriptions, models)
            rb_broadcasts = rb_broadcasts.select { |b|
              controller_file?(b[:file], ctrl_lower) ||
                broadcast_streams([], [ b ], models).any? { |cast| subscribed.any? { |sub| stream_relation(sub, cast, models) == :match } }
            }
          end

          wiring = wiring_touching(wiring, model_broadcasts + rb_broadcasts + view_subscriptions) if stream || controller
          filter_label = stream ? "stream:\"#{echo_input(stream)}\"" : controller ? "controller:\"#{echo_input(controller)}\"" : nil

          found = Found.new(
            model_broadcasts: model_broadcasts, rb_broadcasts: rb_broadcasts,
            view_subscriptions: view_subscriptions, view_frames: view_frames,
            wiring: wiring, warnings: detect_mismatches(wiring)
          )

          case detail
          when "summary" then format_summary(found, turbo_data: data, filter_label: filter_label)
          when "standard" then format_standard(found, turbo_data: data, filter_label: filter_label)
          when "full" then format_full(found, turbo_data: data, filter_label: filter_label)
          end
        end
      end

      # A file belongs to a controller when the name is a whole run of its path
      # segments - the view directory, or the controller file itself.
      private_class_method def self.controller_file?(file, ctrl)
        path_segments_match?(file.to_s.sub(/\.\w+(\.\w+)*\z/, "").sub(/_controller\z/, ""), ctrl)
      end

      # No lockfile means unknown, not absent, so this answers false there.
      private_class_method def self.turbo_rails_absent?
        lock = RailsAiContext::GemLock.for(rails_app.root)
        !lock.missing? && !lock.present?("turbo-rails")
      rescue => e
        RailsAiContext.debug_fail(e, false, label: "turbo_rails_absent?")
      end

      private_class_method def self.format_summary(found, turbo_data:, filter_label: nil)
        found.to_h => { model_broadcasts:, rb_broadcasts:, view_subscriptions:, view_frames:, warnings: }
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

      # Both formatters answer an app with no Turbo the same way, and the
      # answer is marked empty so a composing tool can read it.
      private_class_method def self.nothing_found_response(found, turbo_data, filter_label, lines)
        found.to_h => { model_broadcasts:, rb_broadcasts:, view_subscriptions:, view_frames: }
        return nil unless model_broadcasts.empty? && rb_broadcasts.empty? && view_subscriptions.empty? &&
                          view_frames.empty? && !turbo_data[:turbo_stream_responses]&.any? &&
                          !turbo_data[:turbo_streams]&.any?

        note = api_only_note("the Turbo Streams/Frames surface")
        return text_response(note) if note

        lines << if filter_label
          "_No Turbo usage matching #{filter_label}. Try without filter to see all Turbo Streams and Frames._"
        else
          "_No Turbo Streams or Frames detected in this app._"
        end
        empty_response(lines.join("\n"))
      end

      private_class_method def self.format_standard(found, turbo_data:, filter_label: nil)
        found.to_h => { model_broadcasts:, rb_broadcasts:, view_subscriptions:, view_frames:, warnings: }
        lines = [ "# Turbo Map", "" ]
        lines.concat(drive_configuration_lines(turbo_data))

        # Turbo Stream responses
        if turbo_data[:turbo_stream_responses]&.any?
          responses = turbo_data[:turbo_stream_responses]
          shown = responses.first(STREAM_RESPONSE_CAP)
          lines << "## Turbo Stream Responses"
          shown.each { |resp| lines << "- `#{stream_response_label(resp)}`" }
          lines << "_Showing #{shown.size} of #{responses.size}. Call `rails_get_turbo_map(detail:\"full\")` for the rest._" if shown.size < responses.size
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

        if model_broadcasts.any?
          lines << "## Model Broadcasts (#{model_broadcasts.size})"
          model_broadcasts.each do |b|
            stream_label = b[:stream] ? " → stream: `#{b[:stream]}`" : ""
            lines << "- **#{b[:model]}** `#{b[:macro]}`#{stream_label} (`#{b[:file]}:#{b[:line]}`)"
          end
          lines << ""
        end

        if rb_broadcasts.any?
          lines << "## Explicit Broadcasts (#{rb_broadcasts.size})"
          rb_broadcasts.each do |b|
            target_label = b[:target] ? " target: `#{b[:target]}`" : ""
            lines << "- `#{b[:method]}` → stream: `#{b[:parts] ? parts_label(b[:parts]) : b[:stream]}`#{target_label} (`#{b[:file]}:#{b[:line]}`)"
          end
          lines << ""
        end

        if view_subscriptions.any?
          lines << "## Stream Subscriptions (#{view_subscriptions.size})"
          view_subscriptions.each do |s|
            lines << "- `turbo_stream_from` `#{s[:stream]}` (`#{s[:file]}:#{s[:line]}`)"
          end
          lines << ""
        end

        if view_frames.any?
          lines << "## Turbo Frames (#{view_frames.size})"
          view_frames.each do |f|
            src_label = f[:src] ? " src: `#{f[:src]}`" : ""
            lines << "- `turbo_frame_tag` `#{f[:id]}`#{src_label} (`#{f[:file]}:#{f[:line]}`)"
          end
          lines << ""
        end

        if warnings.any?
          lines << "## Warnings"
          warnings.each { |w| lines << "- #{w}" }
          lines << ""
        end

        nothing = nothing_found_response(found, turbo_data, filter_label, lines)
        return nothing if nothing

        lines << "_Use `detail:\"full\"` for DOM IDs and inline templates, or `stream:\"name\"` to filter._"
        text_response(lines.join("\n"))
      end

      # The entries are `{ controller:, action: }`; the rest of the file names
      # a controller action `PostsController#create`, so this section does too.
      private_class_method def self.stream_response_label(resp)
        return resp.to_s unless resp.is_a?(Hash)

        "#{resp[:controller]}##{resp[:action]}"
      end

      # The one Drive section: both formatters render it identically.
      private_class_method def self.drive_configuration_lines(turbo_data)
        parts = []
        parts << "morph: #{turbo_data[:morph_meta] ? 'yes' : 'no'}" unless turbo_data[:morph_meta].nil?
        parts << "permanent elements: #{turbo_data[:permanent_elements].size}" if turbo_data[:permanent_elements]&.any?
        if turbo_data[:turbo_drive_settings].is_a?(Hash) && turbo_data[:turbo_drive_settings].any?
          turbo_data[:turbo_drive_settings].each { |k, v| parts << "#{k}: #{v}" }
        end
        return [] if parts.empty?

        [ "## Turbo Drive Configuration" ] + parts.map { |p| "- #{p}" } + [ "" ]
      end

      private_class_method def self.format_full(found, turbo_data:, filter_label: nil)
        found.to_h => { model_broadcasts:, rb_broadcasts:, view_subscriptions:, view_frames:, warnings: }
        lines = [ "# Turbo Map (Full Detail)", "" ]
        lines.concat(drive_configuration_lines(turbo_data))

        # Turbo Stream responses
        if turbo_data[:turbo_stream_responses]&.any?
          lines << "## Turbo Stream Responses (#{turbo_data[:turbo_stream_responses].size})"
          turbo_data[:turbo_stream_responses].each do |resp|
            lines << "- `#{stream_response_label(resp)}`"
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

        if rb_broadcasts.any?
          lines << "## Explicit Broadcasts (#{rb_broadcasts.size})"
          rb_broadcasts.each do |b|
            lines << "### `#{b[:method]}` → `#{b[:parts] ? parts_label(b[:parts]) : b[:stream]}`"
            lines << "- **File:** `#{b[:file]}:#{b[:line]}`"
            lines << "- **Target:** `#{b[:target]}`" if b[:target]
            lines << "- **Partial:** `#{b[:partial]}`" if b[:partial]
            lines << "- **Snippet:** `#{b[:snippet]}`" if b[:snippet]
            lines << ""
          end
        end

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
        stream_wiring = found.wiring
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
              lines << if wiring[:unsure]
                "- _Can't tell whether a subscriber matches: a part of a stream here names nothing this reading resolves_"
              else
                "- _No subscribers found for this stream_"
              end
            end
            if wiring[:subscribers].any? && wiring[:broadcasters].empty?
              lines << if wiring[:unknown].any?
                "- _Can't tell whether #{wiring[:unknown].map { |b| "`#{b}`" }.join(', ')} broadcast#{"s" if wiring[:unknown].one?} here: " \
                  "a part of its stream names nothing this reading resolves_"
              else
                "- _No broadcasters found for this stream_"
              end
            end
            lines << ""
          end
        end

        if warnings.any?
          lines << "## Warnings"
          warnings.each { |w| lines << "- #{w}" }
          lines << ""
        end

        nothing = nothing_found_response(found, turbo_data, filter_label, lines)
        return nothing if nothing

        text_response(lines.join("\n"))
      end

      # A broadcast or a subscription as the wiring compares them: its label,
      # where it is, and its stream's parts with each expression resolved to
      # the model whose record it names. Nil parts compare by label alone.
      WiredStream = Data.define(:label, :where, :parts)

      # The streams a filter's entries take part in, each with every
      # broadcaster and subscriber the app has for it: a comments filter
      # keeps Comment's broadcast, and the post view that hears it, rather
      # than calling the stream unheard.
      private_class_method def self.wiring_touching(wiring, entries)
        places = entries.map { |entry| /#{Regexp.escape("#{entry[:file]}:#{entry[:line]}")}(?!\d)/ }
        wiring.select do |_, streams|
          (streams[:broadcasters] + streams[:subscribers] + streams[:unknown]).any? { |where| places.any? { |place| where.match?(place) } }
        end
      end

      # Warnings only where the wiring is sure: a stream whose parts this
      # reading could not resolve is "can't tell", not a mismatch.
      private_class_method def self.detect_mismatches(stream_wiring)
        warnings = []
        stream_wiring.each do |label, wiring|
          next if wiring[:unknown].any? || wiring[:unsure]

          if wiring[:subscribers].any? && wiring[:broadcasters].empty?
            warnings << "Subscription to `#{label}` has no matching broadcast (#{wiring[:subscribers].join(', ')})"
          elsif wiring[:broadcasters].any? && wiring[:subscribers].empty?
            warnings << "Broadcast to `#{label}` has no matching `turbo_stream_from` (#{wiring[:broadcasters].join(', ')})"
          end
        end
        warnings.sort
      rescue => e
        RailsAiContext.debug_fail(e, [], label: "detect_mismatches")
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

      # stream label => { subscribers:, broadcasters:, unknown: [broadcasters
      # it cannot tell about], unsure: a broadcast that might reach some
      # subscriber }. Each subscription lists the broadcasts that reach it, and
      # a broadcast that reaches none gets an entry of its own. Turbo names a
      # stream by its parts, so a model's `[product, :reviews]` and a view's
      # `@product, :reviews` are one stream when both are a Product.
      private_class_method def self.build_stream_wiring(model_broadcasts, rb_broadcasts, view_subscriptions)
        models = Payload.models(cached_context)
        casts = broadcast_streams(model_broadcasts, rb_broadcasts, models)
        reached = Set.new
        unsure = Set.new
        wiring = {}

        subscription_streams(view_subscriptions, models).each do |sub|
          entry = (wiring[sub.label] ||= { broadcasters: [], subscribers: [], unknown: [] })
          entry[:subscribers] << sub.where
          casts.each_with_index do |cast, index|
            case stream_relation(sub, cast, models)
            when :match
              entry[:broadcasters] << cast.where
              reached << index
            when :unknown
              entry[:unknown] << cast.where
              unsure << index
            end
          end
        end

        casts.each_with_index do |cast, index|
          next if reached.include?(index)

          entry = (wiring[cast.label] ||= { broadcasters: [], subscribers: [], unknown: [] })
          entry[:broadcasters] << cast.where
          entry[:unsure] = true if unsure.include?(index)
        end

        wiring.each_value { |entry| %i[broadcasters subscribers unknown].each { |key| entry[key].uniq! } }
        wiring.sort_by { |k, _| k }.to_h
      rescue => e
        RailsAiContext.debug_fail(e, {}, label: "build_stream_wiring")
      end

      private_class_method def self.subscription_streams(view_subscriptions, models)
        view_subscriptions.filter_map do |s|
          next unless s[:stream]

          WiredStream.new(label: s[:stream], where: "#{s[:file]}:#{s[:line]}", parts: resolve_parts(s[:parts], models, nil))
        end
      end

      # `broadcasts` and `broadcasts_refreshes` send to two streams, the
      # model's plural on create and the record on update and destroy, so
      # each stream is its own entry, labelled with the events it carries.
      MACRO_EVENTS = [ " on create", " on update and destroy" ].freeze

      private_class_method def self.broadcast_streams(model_broadcasts, rb_broadcasts, models)
        streams = []
        model_broadcasts.each do |b|
          where = "#{b[:model]}.#{b[:macro]} (#{b[:file]}:#{b[:line]})"
          if b[:streams]
            two = b[:streams].size == 2
            b[:streams].each_with_index do |parts, index|
              streams << WiredStream.new(label: parts_label(parts), where: "#{where}#{MACRO_EVENTS[index] if two}",
                                         parts: resolve_parts(parts, models, b[:model]))
            end
          elsif b[:stream]
            streams << WiredStream.new(label: b[:stream], where: where, parts: nil)
          end
        end
        rb_broadcasts.each do |b|
          next unless b[:stream]

          label = b[:parts] ? parts_label(b[:parts]) : b[:stream]
          streams << WiredStream.new(label: label, where: "#{b[:method]} (#{b[:file]}:#{b[:line]})",
                                     parts: resolve_parts(b[:parts], models, b[:owner]))
        end
        streams
      end

      # Parts as a subscription label spells them: `user, notifications`.
      private_class_method def self.parts_label(parts)
        parts.map { |part| part[:literal] || part[:expr] }.join(", ")
      end

      # Each expression as the model whose record it names, when one does;
      # `owner` is the class a broadcast sits in, nil for a view.
      private_class_method def self.resolve_parts(parts, models, owner)
        return nil unless parts.is_a?(Array)

        parts.map do |part|
          next part unless part[:expr]

          model = owner ? model_side_record(part[:expr], owner, models) : view_side_record(part[:expr], models)
          model ? { record: model } : part
        end
      end

      # In a model, `self` is the record and a bare name one of its
      # belongs_to or has_one associations; `Current.user` reads as in a view.
      private_class_method def self.model_side_record(expr, owner, models)
        return view_side_record(expr, models) if expr.start_with?("Current.")

        name = expr.delete_prefix("self.")
        return (models.key?(owner) ? owner : nil) if name == "self"
        return nil unless name.match?(/\A[a-z_]\w*\z/) && models[owner].is_a?(Hash)

        assoc = Array(models[owner][:associations]).find do |a|
          a.is_a?(Hash) && a[:name].to_s == name && %w[belongs_to has_one].include?(a[:type].to_s) && !a[:polymorphic]
        end
        assoc && Introspectors::TableName.model_for(assoc[:class_name] || name.camelize, owner, models)
      end

      # In a view, `@product`, `product`, `current_user` and `Current.user`
      # (Rails 8's authentication keeps the signed-in user there) name a
      # record by the model their name spells, and `@order.user` one through
      # the first model's association.
      private_class_method def self.view_side_record(expr, models)
        head, *chain = expr.delete_prefix("@").delete_prefix("Current.").split(".")
        return nil unless head.to_s.match?(/\A[a-z_]\w*\z/) && chain.all? { |name| name.match?(/\A[a-z_]\w*\z/) }

        named = head.delete_prefix("current_")
        found = models.keys.map(&:to_s).select { |key| key.demodulize.underscore == named }
        model = found.one? ? found.first : nil
        chain.each { |name| model = model && model_side_record(name, model, models) }
        model
      end

      # :match, :differ, or :unknown when a part names something this
      # reading cannot resolve.
      private_class_method def self.stream_relation(a, b, models)
        unless a.parts && b.parts
          return :match if streams_match?(a.label, b.label)

          return [ a.label, b.label ].any? { |label| label.include?("dynamic") } ? :unknown : :differ
        end
        return :differ unless a.parts.size == b.parts.size

        relations = a.parts.zip(b.parts).map { |x, y| part_relation(x, y, models) }
        return :differ if relations.include?(:differ)

        relations.include?(:unknown) ? :unknown : :match
      end

      private_class_method def self.part_relation(x, y, models)
        if x[:literal] && y[:literal]
          x[:literal] == y[:literal] ? :match : :differ
        elsif x[:record] && y[:record]
          return :match if x[:record] == y[:record]

          # A record streams under its own class, so a parent and its STI
          # subclass may or may not be one stream.
          sti_related?(x[:record], y[:record], models) ? :unknown : :differ
        elsif (x[:literal] && y[:record]) || (x[:record] && y[:literal])
          :differ
        else
          :unknown
        end
      end

      private_class_method def self.sti_related?(a, b, models)
        ancestors = lambda do |name|
          chain = []
          while (parent = models.dig(name, :parent_model)) && !chain.include?(parent)
            chain << parent
            name = parent
          end
          chain
        end
        ancestors.call(a).include?(b) || ancestors.call(b).include?(a)
      end
    end
  end
end
