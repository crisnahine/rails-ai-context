# frozen_string_literal: true

module RailsAiContext
  module Tools
    # Last-resort rescue for tool execution, prepended to every registered
    # tool's singleton class so it wraps each tool's `self.call` regardless
    # of when the subclass defines the method.
    #
    # Without this, an exception inside a tool escapes to the MCP SDK, which
    # converts it into a JSON-RPC -32603 protocol error. Most AI clients
    # swallow protocol errors, so the model never sees what went wrong and
    # cannot recover. An error tool-result (isError: true) lands in the
    # model's context instead, with enough detail to retry or route around
    # the failure.
    module SafeCall
      def call(**kwargs)
        super
      rescue StandardError => e
        # A failed call must not leak its recorded params into the next
        # call's session entry.
        Thread.current[:rails_ai_context_call_params] = nil

        label = respond_to?(:tool_name) ? tool_name : name
        origin = Array(e.backtrace).first.to_s
        text = +"Tool #{label} failed: #{e.class}: #{e.message.to_s.lines.first&.strip}\n"
        text << "At: #{origin}\n" unless origin.empty?
        text << "Recovery: retry with a narrower query (a single table, model, or " \
                "controller), or run `rails-ai-context doctor` to check app health."
        MCP::Tool::Response.new([ { type: "text", text: text } ], error: true)
      end
    end
  end
end
