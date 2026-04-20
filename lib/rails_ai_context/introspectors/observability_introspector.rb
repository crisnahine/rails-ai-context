# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    # Captures the Rails observability surface: ActiveSupport::Notifications
    # subscribers, LogSubscriber registrations, Server-Timing middleware,
    # the Rails 8.1 structured event reporter, and the well-known Rails
    # event-name catalog. Covers RAILS_NERVOUS_SYSTEM.md §34 (Observability)
    # and §38 (AS::Notifications event catalog).
    class ObservabilityIntrospector
      attr_reader :app

      def initialize(app)
        @app = app
      end

      def call
        {
          log_subscribers: extract_log_subscribers,
          notification_subscribers: extract_notification_subscribers,
          server_timing: detect_server_timing,
          event_reporter: detect_event_reporter,
          log_level: app.config.log_level.to_s,
          log_tags: Array(app.config.log_tags).map(&:to_s),
          colorize_logging: !!app.config.colorize_logging,
          known_events: KNOWN_EVENTS
        }
      rescue => e
        $stderr.puts "[rails-ai-context] ObservabilityIntrospector#call failed: #{e.message}" if ENV["DEBUG"]
        { error: e.message }
      end

      private

      def root
        app.root.to_s
      end

      # Every LogSubscriber registered with ActiveSupport::LogSubscriber is
      # reachable via `.log_subscribers` (available since Rails 3). Returns
      # class names + the notification namespace each subscribes to.
      def extract_log_subscribers
        return [] unless defined?(ActiveSupport::LogSubscriber) && ActiveSupport::LogSubscriber.respond_to?(:log_subscribers)

        ActiveSupport::LogSubscriber.log_subscribers.map do |sub|
          entry = { class: sub.class.name }
          namespace = sub.class.respond_to?(:namespace) ? sub.class.namespace : nil
          entry[:namespace] = namespace.to_s if namespace
          entry
        end.sort_by { |e| e[:class].to_s }
      rescue => e
        $stderr.puts "[rails-ai-context] extract_log_subscribers failed: #{e.message}" if ENV["DEBUG"]
        []
      end

      # Walk the Notifications notifier's subscriber registry. Each event
      # name maps to one or more Subscribers; return the event + pattern +
      # subscriber count (never the actual callable object).
      def extract_notification_subscribers
        return [] unless defined?(ActiveSupport::Notifications)
        notifier = ActiveSupport::Notifications.notifier
        entries = extract_subscribers_from_notifier(notifier)
        return [] if entries.empty?

        grouped = entries.group_by { |pattern, _| pattern }
        grouped.map do |pattern, pairs|
          subs = pairs.map { |_, s| s }
          {
            pattern: pattern,
            subscriber_count: subs.size,
            sample_class: subs.map { |s| subscriber_class_name(s) }.compact.uniq.first(3)
          }
        end.sort_by { |h| h[:pattern].to_s }
      rescue => e
        $stderr.puts "[rails-ai-context] extract_notification_subscribers failed: #{e.message}" if ENV["DEBUG"]
        []
      end

      # The Fanout notifier splits subscribers across @string_subscribers
      # (exact-name → Array) and @other_subscribers (Regexp/nil patterns →
      # flat Array). This shape has been stable since Rails 6.0 — the gem's
      # supported floor is Rails 7.1, so both ivars are always present.
      def extract_subscribers_from_notifier(notifier)
        all = []
        if (str_subs = notifier.instance_variable_get(:@string_subscribers))
          str_subs.each { |pattern, subs| Array(subs).each { |s| all << [ pattern.to_s, s ] } }
        end
        if (other = notifier.instance_variable_get(:@other_subscribers))
          Array(other).each { |s| all << [ subscriber_raw_pattern(s), s ] }
        end
        all
      rescue StandardError => e
        $stderr.puts "[rails-ai-context] extract_subscribers_from_notifier failed: #{e.message}" if ENV["DEBUG"]
        []
      end

      def subscriber_raw_pattern(sub)
        pat = sub.instance_variable_get(:@pattern) || (sub.respond_to?(:pattern) ? sub.pattern : nil)
        unwrap_pattern(pat)
      rescue StandardError
        "unknown"
      end

      # The Fanout notifier wraps non-string patterns in a `Matcher` object
      # that holds the original Regexp in its own `@pattern` ivar. Unwrap
      # one level so we surface `some.regexp.\w+` instead of
      # `#<…::Matcher:0x…>`.
      def unwrap_pattern(pat)
        case pat
        when Regexp then pat.source
        when String then pat
        when NilClass then ""
        else
          inner = pat.instance_variable_get(:@pattern)
          case inner
          when Regexp then inner.source
          when String then inner
          else pat.class.name.to_s
          end
        end
      end

      def subscriber_class_name(sub)
        delegate = sub.instance_variable_get(:@delegate) || sub
        delegate.class.name
      rescue StandardError
        nil
      end

      def detect_server_timing
        middleware_names = app.middleware.map { |m| m.name || m.klass.to_s }
        {
          middleware_inserted: middleware_names.include?("ActionDispatch::ServerTiming"),
          enabled: app.config.respond_to?(:server_timing) ? !!app.config.server_timing : false
        }
      rescue => e
        $stderr.puts "[rails-ai-context] detect_server_timing failed: #{e.message}" if ENV["DEBUG"]
        {}
      end

      # Rails 8.1 adds `Rails.application.event_reporter`. Report whether it's
      # available and the subscriber count. We deliberately do NOT call
      # `reporter.tagged` — it's a block-scoped DSL (`reporter.tagged(:x) { … }`)
      # that delegates to `TagStack#with_tags` and `yield`s unconditionally, so
      # a blockless call raises `LocalJumpError`. There is no keyspace to
      # introspect.
      def detect_event_reporter
        return { available: false } unless app.respond_to?(:event_reporter) && app.event_reporter

        reporter = app.event_reporter
        entry = { available: true }
        entry[:subscriber_count] = reporter.subscribers.size if reporter.respond_to?(:subscribers) && reporter.subscribers.respond_to?(:size)
        entry
      rescue => e
        $stderr.puts "[rails-ai-context] detect_event_reporter failed: #{e.message}" if ENV["DEBUG"]
        { available: false }
      end

      # Canonical Rails notification event names grouped by subsystem. Kept
      # as static data (not derived) since these are framework-defined and
      # stable. Useful for AI clients building subscribers or dashboards.
      KNOWN_EVENTS = {
        action_controller: %w[
          start_processing.action_controller process_action.action_controller
          send_file.action_controller send_data.action_controller
          redirect_to.action_controller halted_callback.action_controller
          unpermitted_parameters.action_controller
        ],
        action_view: %w[
          render_template.action_view render_partial.action_view
          render_collection.action_view
        ],
        active_record: %w[
          sql.active_record instantiation.active_record
          strict_loading_violation.active_record
        ],
        active_job: %w[
          enqueue.active_job enqueue_at.active_job perform_start.active_job
          perform.active_job enqueue_retry.active_job retry_stopped.active_job
          discard.active_job
        ],
        action_mailer: %w[
          process.action_mailer deliver.action_mailer
        ],
        action_mailbox: %w[
          process.action_mailbox
        ],
        action_cable: %w[
          perform_action.action_cable transmit.action_cable transmit_subscription_confirmation.action_cable
          transmit_subscription_rejection.action_cable broadcast.action_cable
        ],
        active_support: %w[
          cache_read.active_support cache_write.active_support cache_delete.active_support
          cache_fetch_hit.active_support cache_generate.active_support cache_exist?.active_support
        ],
        active_storage: %w[
          service_upload.active_storage service_streaming_download.active_storage
          service_download.active_storage service_delete.active_storage
          service_url.active_storage service_exist.active_storage
          preview.active_storage analyze.active_storage
        ],
        railties: %w[
          load_config_initializer.railties
        ]
      }.freeze
    end
  end
end
