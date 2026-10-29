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
      # The content with the note ending its first text block, or the content
      # itself when there is no note or no text to end.
      def self.noted(content, note)
        first = Array(content).first
        return content unless note && first.is_a?(Hash) && first[:type] == "text"

        body = first[:text].to_s
        [ first.merge(text: body.strip.empty? ? note.lstrip : "#{body}#{note}") ] + content[1..].to_a
      end

      # The parameters tools/list shows, which for rails_get_config leaves out those of a section turned off.
      def self.published_params(tool)
        schema = tool.respond_to?(:input_schema_value) ? tool.input_schema_value : tool.input_schema
        (schema&.to_h&.dig(:properties) || {}).keys.map(&:to_s)
      end

      def call(**kwargs)
        # An MCP client sends whatever keys it likes. Reaching the tool with
        # one it does not declare answers with an unknown-keyword ArgumentError
        # and a backtrace, where the CLI names the params the tool takes.
        unknown = unknown_params(kwargs)
        return with_report(unknown_param_response(unknown)) if unknown.any? && !Thread.current[:rails_ai_context_call]
        return unknown_param_response(unknown) if unknown.any?

        # Held as a local, not a thread-local: the wrapper sees both the value
        # it discarded and the response that came back, so the note needs no
        # state outliving the call. It also lands on every way out of a tool,
        # not just text_response, and a tool that calls another tool cannot
        # have its note consumed by the inner one.
        discarded = discarded_detail(kwargs)
        kwargs = listify_arrays(normalize_detail(kwargs))
        answer = -> { answer_call(discarded) { super(**kwargs) } }

        # Only the call the client made is its query. A composite tool answers
        # by calling others, and each of those recorded itself, so one
        # get_context read as four calls the client never made - and the
        # first inner call took the outer one's params with it.
        return answer.call if Thread.current[:rails_ai_context_call]

        # Before the call reads anything: an edit since the last call drops
        # the caches and reloads the app's code (see the method).
        RailsAiContext::Tools::BaseTool.refresh_if_files_changed!
        call = Thread.current[:rails_ai_context_call] = { tool: self, params: session_params(kwargs) }
        begin
          with_report(with_crashes(answer.call, call[:crashed]))
        ensure
          Thread.current[:rails_ai_context_call] = nil
        end
      end

      def unknown_param_response(unknown, known = SafeCall.published_params(self))
        lines = unknown.map do |name|
          suggestion = RailsAiContext::Tools::BaseTool.find_closest_match(name, known)
          suggestion ? "'#{name}' - did you mean '#{suggestion}'?" : "'#{name}'"
        end
        valid = known.any? ? "Valid params: #{known.join(', ')}" : "This tool takes no params."
        text = "Unknown param#{"s" if unknown.size > 1}: #{lines.join(', ')}\n#{valid}"
        MCP::Tool::Response.new([ { type: "text", text: text } ], error: true)
      end

      private

      def answer_call(discarded)
        # Held across the tool body: a reload another call runs must not
        # unload constants while this call is reading them.
        #
        # The rescue sits INSIDE the block on purpose. `executor.wrap` reports
        # anything that crosses it to the host app's error_reporter as
        # unhandled, which would page a team over a failure this method turns
        # into an ordinary isError result. Nothing escapes the block, so
        # nothing is reported.
        RailsAiContext::CodeReloader.with_app_code do
          begin
            # One call is one run: what it reads per controller or per route is read once.
            response, left_out = with_left_out_frame { RailsAiContext::RunCache.around_app { yield } }
            response = append_note(response, RailsAiContext::Tools::BaseTool.left_out_note(left_out))
            append_note(response, invalid_detail_note(discarded))
          # An app file that cannot load, a stack overflow or a SecurityError costs that call,
          # where a StandardError rescue alone would let it end the stdio server and every tool with it.
          rescue StandardError, ScriptError, SystemStackError, SecurityError => e
            failure_response(e).tap do |failure|
              call = Thread.current[:rails_ai_context_call]
              (call[:crashed] ||= []) << failure.content.first[:text] if call
            end
          end
        end
      end

      # A tool this call ran crashed: the answer is an error, and it says so where its text left the crash out.
      # The report line ends the answer the client asked for, once; a JSON
      # answer carries it under its key instead, since its body has to parse.
      def with_report(response)
        return response unless RailsAiContext.configuration.report_issue_line

        # json_response's object, which carries the line under its own key.
        body = response.content.first&.dig(:text).to_s if response.respond_to?(:content)
        return response if body&.start_with?("{") && body.end_with?("}")

        append_note(response, RailsAiContext::Tools::BaseTool.report_banner)
      end

      def with_crashes(response, crashes)
        return response unless crashes && response.respond_to?(:error?) && !response.error?

        text = response.content.first&.dig(:text).to_s
        unsaid = crashes.uniq.reject { |failure| text.include?(failure.lines.first.strip) }
        rebuilt(response, SafeCall.noted(response.content, ("\n\n#{unsaid.join("\n\n")}" if unsaid.any?)), error: true)
      end

      # The tools this call's composed sections left out, kept apart from
      # those of any tool it calls.
      def with_left_out_frame
        stack = (Thread.current[RailsAiContext::Tools::BaseTool::LEFT_OUT] ||= [])
        stack.push([])
        response = yield
        [ response, stack.last.uniq ]
      ensure
        stack.pop
      end

      # The declared params are the contract, so a tool whose method takes
      # **kwargs refuses the same keys as one that names them.
      def unknown_params(kwargs)
        properties = (respond_to?(:input_schema) ? input_schema&.to_h : nil)&.dig(:properties)
        return [] unless properties

        RailsAiContext::Tools::BaseTool.unknown_param_names(kwargs.keys, properties)
      end

      # A string where the schema declares an array is a list of one, and a
      # comma-separated one is the list the CLI documents (`a.rb,b.rb`): an MCP
      # client can send either, and review_changes answered a string with
      # "undefined method 'any?'". Done here so every tool and every way in -
      # MCP, the CLI, a direct call - gets the same list.
      def listify_arrays(kwargs)
        properties = (respond_to?(:input_schema) ? input_schema&.to_h : nil)&.dig(:properties) || {}
        kwargs.to_h do |key, value|
          prop = properties[key.to_sym] || properties[key.to_s] || {}
          next [ key, value ] unless prop[:type] == "array" && value.is_a?(String)

          [ key, value.split(",").map(&:strip).reject(&:empty?) ]
        end
      end

      def failure_response(error)
        # Retrying cannot help a call whose own gem files are gone; reconnecting can.
        if error.is_a?(LoadError) && RailsAiContext.files_gone?
          return MCP::Tool::Response.new([ { type: "text", text: RailsAiContext.files_gone_message } ], error: true)
        end

        label = respond_to?(:tool_name) ? tool_name : name
        # A section renderer answers inside rails_get_config, the tool the caller named.
        section = RailsAiContext::Tools::GetConfig.retired_section(label)
        label = "rails_get_config (section #{section.name})" if section && section.renderer.equal?(self)
        origin = portable_origin(Array(error.backtrace).first.to_s)
        text = +"Tool #{label} failed: #{error.class}: #{error.message.to_s.lines.first&.strip}\n"
        text << "At: #{origin}\n" unless origin.empty?
        text << "Recovery: retry with a narrower query (a single table, model, or " \
                "controller), or run `#{RailsAiContext.doctor_command}` to check app health."
        MCP::Tool::Response.new([ { type: "text", text: text } ], error: true)
      end

      # A backtrace frame is an absolute path, and on an installed gem that is
      # the machine's GEM_HOME. The answer leaves the machine, so the frame is
      # spelled the way every other path this gem reports is, and one no
      # portable form names keeps only its file name.
      def portable_origin(frame)
        # Ruby 3.3+ names an eval without a file `(eval at FILE:LINE):LINE`.
        if (eval_frame = frame.match(/\A\(eval at (.+)\)(:\d+(?::.*)?)?\z/m))
          return "(eval at #{portable_origin(eval_frame[1])})#{eval_frame[2]}"
        end

        # FILE:LINE, split at the line number: a Windows path has a colon of
        # its own after the drive letter (D:/a/app/x.rb:1).
        path, rest = frame.match(/\A(.+?):(\d+(?::.*)?)\z/m)&.captures || [ frame, nil ]
        # A relative path (`(eval)`, `-e`) names nothing on this machine.
        return frame unless RailsAiContext::SafePath.absolute?(path)

        # This runs inside the rescue that answers a tool failure, so a raise
        # here would leave the net and reach the client as a protocol error.
        # No app, or no root, still strips the gem prefix.
        root = begin
          rails_app.root.to_s
        rescue StandardError
          ""
        end
        relative = begin
          RailsAiContext::PortablePath.relativize(path, root)
        rescue StandardError
          path
        end
        relative = File.basename(relative) if RailsAiContext::SafePath.absolute?(relative)
        [ relative, rest ].compact.join(":")
      end

      # The value the caller sent, when this tool takes a DetailLevel detail
      # and that value is not one of its levels.
      def discarded_detail(kwargs)
        return nil unless detail_param?

        given = kwargs[:detail]
        given unless given.nil? || RailsAiContext::DetailLevel.valid?(given)
      end

      def append_note(response, note)
        return response unless note && response.respond_to?(:content)

        noted = SafeCall.noted(response.content, note)
        return response if noted.equal?(response.content)

        rebuilt(response, noted, error: response.error?)
      end

      def rebuilt(response, content, error:)
        # `meta` arrived in mcp 0.13, which is the gemspec floor, but the
        # reader is still asked for rather than assumed: getting it wrong
        # turns a good answer into a NoMethodError that SafeCall's own rescue
        # then reports as a tool failure.
        extra = { structured_content: response.structured_content }
        extra[:meta] = response.meta if response.respond_to?(:meta)

        MCP::Tool::Response.new(content, error: error, **extra)
      end
    end
  end
end
