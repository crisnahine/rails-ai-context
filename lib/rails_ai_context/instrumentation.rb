# frozen_string_literal: true

module RailsAiContext
  # Bridges MCP gem instrumentation to ActiveSupport::Notifications.
  # Enables Rails apps to subscribe to MCP events (tool calls, resource reads, etc.).
  module Instrumentation
    EVENT_PREFIX = "rails_ai_context"

    # Returns a lambda for MCP::Configuration#instrumentation_callback.
    # Instruments each MCP method call as an ActiveSupport::Notifications event.
    def self.callback
      ->(data) {
        return unless defined?(ActiveSupport::Notifications)

        method = data[:method] || "unknown"
        event_name = "#{EVENT_PREFIX}.#{method.tr("/", ".")}"

        ActiveSupport::Notifications.instrument(event_name, data)
      }
    end
  end
end
