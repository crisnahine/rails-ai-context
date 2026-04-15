# frozen_string_literal: true

module RailsAiContext
  # Bridges MCP gem instrumentation to ActiveSupport::Notifications.
  # Enables Rails apps to subscribe to MCP events (tool calls, resource reads, etc.).
  module Instrumentation
    EVENT_PREFIX = "rails_ai_context"

    # Metadata-only fields forwarded to ActiveSupport::Notifications. We
    # deliberately exclude `tool_arguments`, `params`, `arguments`, and
    # `request` because the MCP SDK includes raw tool inputs in those keys —
    # e.g. `rails_query(sql: "SELECT password_digest...")`, `rails_get_env(name: "SECRET_KEY_BASE")`,
    # `rails_read_logs(search: "api_key=xyz")`. Forwarding them unredacted
    # would leak the request-side data that each tool's response-side
    # redaction was specifically designed to protect. Fixed in v5.8.1.
    #
    # Users who legitimately need tool arguments in observability can set
    # config.instrumentation_include_arguments = true in an initializer
    # (see CONFIGURATION.md for the redaction obligation that comes with it).
    SAFE_KEYS = %i[method tool_name duration error resource_uri prompt_name].freeze

    # Returns a lambda for MCP::Configuration#instrumentation_callback.
    # Instruments each MCP method call as an ActiveSupport::Notifications event.
    def self.callback
      ->(data) {
        return unless defined?(ActiveSupport::Notifications)

        begin
          method = data[:method] || "unknown"
          event_name = "#{EVENT_PREFIX}.#{method.to_s.tr("/", ".")}"

          # build_payload reads configuration — wrap it in the rescue so a
          # broken/nil configuration doesn't propagate out of the lambda and
          # crash the MCP SDK's ensure block. v5.8.1-r3 hardening.
          payload = build_payload(data)
          ActiveSupport::Notifications.instrument(event_name, payload)
        rescue => e
          # The MCP SDK's instrument_call invokes this callback from an `ensure`
          # block, which means any exception raised here would overwrite the
          # tool's actual return value with the subscriber's error — effectively
          # crashing every tool call whenever a single subscriber is broken.
          # Swallow the error and log to stderr instead. Fixed in v5.8.1.
          $stderr.puts "[rails-ai-context] instrumentation subscriber failed: #{e.message}" if ENV["DEBUG"]
        end
      }
    end

    # Build a safe payload from the raw MCP SDK data hash. Strips tool
    # arguments unless the user has explicitly opted in.
    def self.build_payload(data)
      payload = SAFE_KEYS.each_with_object({}) do |key, acc|
        acc[key] = data[key] if data.key?(key)
      end

      if RailsAiContext.configuration.instrumentation_include_arguments
        # User opted in: include arguments verbatim. They take on the
        # redaction obligation for anything downstream consumers log.
        payload[:tool_arguments] = data[:tool_arguments] if data.key?(:tool_arguments)
        payload[:arguments]      = data[:arguments]      if data.key?(:arguments)
      end

      payload
    end
  end
end
