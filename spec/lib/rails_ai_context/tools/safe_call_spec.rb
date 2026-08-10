# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Tools::SafeCall do
  # A tool built the way every registered tool is, so what the wrapper does
  # for it is what the wrapper does for all of them. Subclassing BaseTool
  # enrols the class in the global registry, so each one is withdrawn again
  # before the next example reads the tool list.
  def build_tool(&body)
    Class.new(RailsAiContext::Tools::BaseTool) do
      tool_name "rails_spec_probe"
      description "probe"
      class_exec(&body)
    end.tap { |klass| @built_tools << klass }
  end

  before do
    @built_tools = []
    RailsAiContext::Tools::BaseTool.session_reset!
  end

  after { @built_tools.each(&:abstract!) }

  describe "call parameter recording" do
    it "records a tool's own arguments with no per-tool code" do
      tool = build_tool do
        input_schema(properties: { table: { type: "string" } }, required: [])
        def self.call(table: nil, server_context: nil)
          text_response("ok")
        end
      end

      tool.call(table: "users")

      entry = RailsAiContext::Tools::BaseTool.session_queries.last
      expect(entry[:params]).to eq(table: "users")
    end

    it "drops nil and empty arguments rather than recording noise" do
      tool = build_tool do
        input_schema(properties: { table: { type: "string" }, scope: { type: "string" } }, required: [])
        def self.call(table: nil, scope: nil, server_context: nil)
          text_response("ok")
        end
      end

      tool.call(table: "users", scope: "")

      expect(RailsAiContext::Tools::BaseTool.session_queries.last[:params]).to eq(table: "users")
    end

    it "never records the MCP server context object" do
      tool = build_tool do
        input_schema(properties: {}, required: [])
        def self.call(server_context: nil)
          text_response("ok")
        end
      end

      tool.call(server_context: { session_id: "abc" })

      expect(RailsAiContext::Tools::BaseTool.session_queries.last[:params]).to eq({})
    end

    it "lets a tool reshape what gets recorded" do
      tool = build_tool do
        input_schema(properties: { sql: { type: "string" } }, required: [])

        def self.session_params(kwargs)
          super.merge(sql: "REDACTED")
        end

        def self.call(sql: nil, server_context: nil)
          text_response("ok")
        end
      end

      tool.call(sql: "SELECT * FROM users")

      expect(RailsAiContext::Tools::BaseTool.session_queries.last[:params]).to eq(sql: "REDACTED")
    end

    it "does not leak a failed call's params into the next call" do
      tool = build_tool do
        input_schema(properties: { table: { type: "string" } }, required: [])
        def self.call(table: nil, server_context: nil)
          raise "boom" if table == "explode"
          text_response("ok")
        end
      end

      tool.call(table: "explode")
      tool.call(table: "users")

      expect(RailsAiContext::Tools::BaseTool.session_queries.map { |q| q[:params] })
        .to eq([ { table: "users" } ])
    end
  end

  describe "detail normalization" do
    it "hands the tool a normalized detail" do
      seen = nil
      tool = build_tool do
        input_schema(properties: { detail: { type: "string", enum: RailsAiContext::DetailLevel::ALL } }, required: [])
        define_singleton_method(:call) do |detail: nil, server_context: nil|
          seen = detail
          text_response("ok")
        end
      end

      tool.call(detail: "superdetailed")
      expect(seen).to eq(RailsAiContext::DetailLevel::DEFAULT)
    end

    it "fills in the default when detail is omitted but declared" do
      seen = :untouched
      tool = build_tool do
        input_schema(properties: { detail: { type: "string", enum: RailsAiContext::DetailLevel::ALL } }, required: [])
        define_singleton_method(:call) do |detail: nil, server_context: nil|
          seen = detail
          text_response("ok")
        end
      end

      tool.call
      expect(seen).to eq(RailsAiContext::DetailLevel::DEFAULT)
    end

    it "passes a valid detail through untouched" do
      seen = nil
      tool = build_tool do
        input_schema(properties: { detail: { type: "string", enum: RailsAiContext::DetailLevel::ALL } }, required: [])
        define_singleton_method(:call) do |detail: nil, server_context: nil|
          seen = detail
          text_response("ok")
        end
      end

      tool.call(detail: "full")
      expect(seen).to eq("full")
    end

    # The eleven per-tool "Unknown detail level" branches are gone, but the
    # signal they carried is not: a caller who mistypes still has to be told,
    # or the tool answers a question they did not ask and says nothing.
    it "tells the caller when it discarded an invalid detail" do
      tool = build_tool do
        input_schema(properties: { detail: { type: "string", enum: RailsAiContext::DetailLevel::ALL } }, required: [])
        define_singleton_method(:call) { |detail: nil, server_context: nil| text_response("body") }
      end

      text = tool.call(detail: "bogus").content.first[:text]

      expect(text).to start_with("body")
      expect(text).to include("bogus")
      expect(text).to include("summary, standard, full")
    end

    it "says nothing when the detail was valid" do
      tool = build_tool do
        input_schema(properties: { detail: { type: "string", enum: RailsAiContext::DetailLevel::ALL } }, required: [])
        define_singleton_method(:call) { |detail: nil, server_context: nil| text_response("body") }
      end

      expect(tool.call(detail: "full").content.first[:text]).to eq("body")
    end

    it "says nothing when detail was simply omitted" do
      tool = build_tool do
        input_schema(properties: { detail: { type: "string", enum: RailsAiContext::DetailLevel::ALL } }, required: [])
        define_singleton_method(:call) { |detail: nil, server_context: nil| text_response("body") }
      end

      expect(tool.call.content.first[:text]).to eq("body")
    end

    it "does not carry one call's bad detail into the next" do
      tool = build_tool do
        input_schema(properties: { detail: { type: "string", enum: RailsAiContext::DetailLevel::ALL } }, required: [])
        define_singleton_method(:call) { |detail: nil, server_context: nil| text_response("body") }
      end

      tool.call(detail: "bogus")

      expect(tool.call(detail: "full").content.first[:text]).to eq("body")
    end

    # These are the paths the note used to miss: it was appended inside
    # text_response, so any other way out of a tool dropped it, and a tool
    # that called another tool had its note consumed by the inner one.
    it "still says so when the tool answers through error_response" do
      tool = build_tool do
        input_schema(properties: { detail: { type: "string", enum: RailsAiContext::DetailLevel::ALL } }, required: [])
        define_singleton_method(:call) { |detail: nil, server_context: nil| error_response("nope") }
      end

      text = tool.call(detail: "bogus").content.first[:text]

      expect(text).to include("nope")
      expect(text).to include("not a valid `detail`")
    end

    it "keeps the outer tool's note when it calls another tool" do
      inner = build_tool do
        tool_name "rails_spec_inner"
        input_schema(properties: {}, required: [])
        define_singleton_method(:call) { |server_context: nil| text_response("inner") }
      end

      outer = build_tool do
        input_schema(properties: { detail: { type: "string", enum: RailsAiContext::DetailLevel::ALL } }, required: [])
        define_singleton_method(:call) do |detail: nil, server_context: nil|
          inner.call
          text_response("outer")
        end
      end

      text = outer.call(detail: "bogus").content.first[:text]

      expect(text).to start_with("outer")
      expect(text).to include("not a valid `detail`")
    end

    it "does not report a note for the inner call that had no bad detail" do
      inner = build_tool do
        tool_name "rails_spec_inner"
        input_schema(properties: {}, required: [])
        define_singleton_method(:call) { |server_context: nil| text_response("inner") }
      end

      expect(inner.call.content.first[:text]).to eq("inner")
    end

    it "shortens an absurd detail rather than echoing it past the truncation cap" do
      tool = build_tool do
        input_schema(properties: { detail: { type: "string", enum: RailsAiContext::DetailLevel::ALL } }, required: [])
        define_singleton_method(:call) { |detail: nil, server_context: nil| text_response("body") }
      end

      text = tool.call(detail: "z" * 5_000).content.first[:text]

      expect(text).to include("not a valid `detail`")
      expect(text.length).to be < 500
    end

    # append_note rebuilds the response, so anything it forgets to carry over
    # is silently dropped. No tool sets these today; nothing says one won't.
    it "keeps the rest of the response it rebuilds" do
      tool = build_tool do
        input_schema(properties: { detail: { type: "string", enum: RailsAiContext::DetailLevel::ALL } }, required: [])
        define_singleton_method(:call) do |detail: nil, server_context: nil|
          MCP::Tool::Response.new(
            [ { type: "text", text: "body" } ],
            structured_content: { rows: 2 },
            meta: { source: "spec" }
          )
        end
      end

      response = tool.call(detail: "bogus")

      expect(response.content.first[:text]).to include("not a valid `detail`")
      expect(response.structured_content).to eq(rows: 2)
      expect(response.meta).to eq(source: "spec")
    end

    it "leaves a detail that spells its own levels alone" do
      seen = nil
      tool = build_tool do
        input_schema(properties: { detail: { type: "string", enum: %w[quick standard full] } }, required: [])
        define_singleton_method(:call) do |detail: nil, server_context: nil|
          seen = detail
          text_response("ok")
        end
      end

      tool.call(detail: "quick")
      expect(seen).to eq("quick")
    end

    it "leaves a tool with no detail parameter alone" do
      received = nil
      tool = build_tool do
        input_schema(properties: { table: { type: "string" } }, required: [])
        define_singleton_method(:call) do |**kwargs|
          received = kwargs
          text_response("ok")
        end
      end

      tool.call(table: "users")
      expect(received).to eq(table: "users")
    end
  end

  describe "failure wrapping" do
    it "still turns an exception into an error response" do
      tool = build_tool do
        input_schema(properties: {}, required: [])
        def self.call(server_context: nil)
          raise "boom"
        end
      end

      response = tool.call
      expect(response.error?).to be(true)
      expect(response.content.first[:text]).to include("rails_spec_probe failed")
    end
  end
end
