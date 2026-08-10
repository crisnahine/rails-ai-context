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
        # Held as a local, not a thread-local: the wrapper sees both the value
        # it discarded and the response that came back, so the note needs no
        # state outliving the call. It also lands on every way out of a tool,
        # not just text_response, and a tool that calls another tool cannot
        # have its note consumed by the inner one.
        discarded = discarded_detail(kwargs)
        kwargs = normalize_detail(kwargs)
        Thread.current[:rails_ai_context_call_params] = session_params(kwargs)

        append_note(super(**kwargs), invalid_detail_note(discarded))
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

      private

      # The value the caller sent, when this tool takes a DetailLevel detail
      # and that value is not one of its levels.
      def discarded_detail(kwargs)
        return nil unless detail_param?

        given = kwargs[:detail]
        given unless given.nil? || RailsAiContext::DetailLevel.valid?(given)
      end

      def append_note(response, note)
        return response unless note && response.respond_to?(:content)

        content = response.content
        first = content.first
        return response unless first.is_a?(Hash) && first[:type] == "text"

        noted = [ first.merge(text: "#{first[:text]}#{note}") ] + content[1..].to_a
        MCP::Tool::Response.new(
          noted,
          error: response.error?,
          structured_content: response.structured_content,
          meta: response.meta
        )
      end
    end
  end
end
