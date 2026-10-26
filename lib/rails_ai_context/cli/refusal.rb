# frozen_string_literal: true

require "json"

module RailsAiContext
  module CLI
    # Where the plugin's server cannot serve it still connects, with no tools and the reason as its instructions:
    # Claude Code skips a plugin server that fails to start, in every folder, for 15 minutes. Stdlib only.
    module Refusal
      # Text bound for a JSON reply: a C locale tags paths and lines binary, which json 3 refuses to write or parse.
      def self.utf8(text)
        text.to_s.dup.force_encoding(Encoding::UTF_8).scrub
      end

      # One JSON-RPC message a line; nil for a line that holds none.
      def self.parse(line)
        message = JSON.parse(utf8(line))
        message if message.is_a?(Hash)
      rescue JSON::ParserError
        nil
      end

      def self.serve(reason, io_in:, io_out:)
        reason = utf8(reason)
        io_in.each_line do |line|
          request = parse(line)
          next unless request&.key?("id")

          io_out.puts JSON.generate({ "jsonrpc" => "2.0", "id" => request["id"] }.merge(answer(request, reason)))
          io_out.flush
        end
      end

      # The revisions whose initialize these answers follow, newest first.
      PROTOCOL_VERSIONS = %w[2025-11-25 2025-06-18 2025-03-26 2024-11-05].freeze

      # The client's revision where it is one of them, else the newest, which the client then accepts or refuses.
      def self.protocol_version(asked)
        PROTOCOL_VERSIONS.include?(asked) ? asked : PROTOCOL_VERSIONS.first
      end

      def self.welcome(params, instructions, capabilities: { "tools" => {} }, version: "0")
        asked = params.is_a?(Hash) ? params["protocolVersion"] : nil
        { "result" => { "protocolVersion" => protocol_version(asked), "capabilities" => capabilities,
                        "serverInfo" => { "name" => "rails-ai-context", "version" => version }, "instructions" => instructions } }
      end

      # discover's method-not-found sends a client to initialize, which carries the instructions on every protocol.
      def self.answer(request, reason)
        case request["method"]
        when "initialize" then welcome(request["params"], reason)
        when "tools/list" then { "result" => { "tools" => [] } }
        when "ping" then { "result" => {} }
        else { "error" => { "code" => -32_601, "message" => reason } }
        end
      end
    end
  end
end
