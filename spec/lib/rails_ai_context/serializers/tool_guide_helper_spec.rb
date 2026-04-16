# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Serializers::ToolGuideHelper do
  let(:test_class) do
    Class.new do
      include RailsAiContext::Serializers::ToolGuideHelper
      # Make private methods accessible for testing
      public :cli_cmd, :tool_call_inline
    end
  end

  let(:helper) { test_class.new }

  before { RailsAiContext.configuration.tool_mode = :mcp }
  after  { RailsAiContext.configuration.tool_mode = :mcp }

  describe "#tool_call" do
    it "renders MCP + CLI in :mcp mode" do
      result = helper.tool_call("rails_get_schema(table:\"users\")", "rails 'ai:tool[schema]' table=users")
      expect(result).to include("MCP:")
      expect(result).to include("CLI:")
      expect(result).to include("rails_get_schema")
    end

    it "renders only CLI in :cli mode" do
      RailsAiContext.configuration.tool_mode = :cli
      result = helper.tool_call("rails_get_schema(table:\"users\")", "rails 'ai:tool[schema]' table=users")
      expect(result).to include("rails 'ai:tool[schema]'")
      expect(result).not_to include("MCP:")
    end

    it "renders only MCP for unknown mode" do
      RailsAiContext.configuration.tool_mode = :unknown
      result = helper.tool_call("rails_get_schema(table:\"users\")", "rails 'ai:tool[schema]' table=users")
      expect(result).to include("rails_get_schema")
      expect(result).not_to include("CLI:")
    end
  end

  describe "#tool_mode" do
    it "returns the configured tool mode" do
      RailsAiContext.configuration.tool_mode = :cli
      expect(helper.tool_mode).to eq(:cli)
    end
  end

  describe "#tools_header" do
    it "includes tool count and mandatory message" do
      expect(helper.tools_header).to include("Tools (#{RailsAiContext::Server::TOOLS.size})")
      expect(helper.tools_header).to include("MANDATORY")
    end
  end

  describe "#tools_intro" do
    it "mentions MCP tools in :mcp mode" do
      lines = helper.tools_intro
      expect(lines.join("\n")).to include("MCP tools")
    end

    it "mentions introspection tools in :cli mode" do
      RailsAiContext.configuration.tool_mode = :cli
      lines = helper.tools_intro
      expect(lines.join("\n")).to include("introspection tools")
      expect(lines.join("\n")).not_to include("MCP tools")
    end
  end

  describe "#tools_detail_guidance" do
    it "uses MCP param syntax in :mcp mode" do
      lines = helper.tools_detail_guidance
      text = lines.join("\n")
      expect(text).to include("detail:\"summary\"")
      expect(text).to include("summary")
      expect(text).to include("standard")
      expect(text).to include("full")
    end

    it "uses CLI param syntax in :cli mode" do
      RailsAiContext.configuration.tool_mode = :cli
      lines = helper.tools_detail_guidance
      expect(lines.join("\n")).to include("detail=summary")
    end
  end

  describe "#tools_name_list" do
    it "returns a compact list of all tool names" do
      lines = helper.tools_name_list
      text = lines.join("\n")
      expect(text).to include("rails_get_context")
      expect(text).to include("rails_diagnose")
      expect(text).to include("rails_session_context")
    end

    it "includes a count header" do
      lines = helper.tools_name_list
      expect(lines.first).to match(/All \d+ tools/)
    end
  end

  describe "#tools_anti_hallucination_section" do
    it "renders the 6-rule protocol when enabled (default)" do
      lines = helper.tools_anti_hallucination_section
      text = lines.join("\n")
      expect(text).to include("Anti-Hallucination Protocol")
      expect(text).to include("Verify before you write")
      expect(text).to include("Mark every assumption")
      expect(text).to include("Training data describes average Rails")
      expect(text).to include("Check the inheritance chain")
      expect(text).to include("Empty tool output is information")
      expect(text).to include("Stale context lies")
    end

    it "returns empty array when anti_hallucination_rules is false" do
      original = RailsAiContext.configuration.anti_hallucination_rules
      RailsAiContext.configuration.anti_hallucination_rules = false
      expect(helper.tools_anti_hallucination_section).to eq([])
    ensure
      RailsAiContext.configuration.anti_hallucination_rules = original
    end
  end

  describe "#render_tools_guide" do
    it "assembles a complete guide with header, intro, table" do
      lines = helper.render_tools_guide
      text = lines.join("\n")
      expect(text).to include("Tools (#{RailsAiContext::Server::TOOLS.size})")
      expect(text).to include("START HERE")
      expect(text).to include("Common mistakes")
      expect(text).to include("All #{RailsAiContext::Server::TOOLS.size} Tools")
    end

    it "includes the anti-hallucination protocol by default" do
      text = helper.render_tools_guide.join("\n")
      expect(text).to include("Anti-Hallucination Protocol")
    end

    it "omits the protocol when anti_hallucination_rules is false" do
      original = RailsAiContext.configuration.anti_hallucination_rules
      RailsAiContext.configuration.anti_hallucination_rules = false
      text = helper.render_tools_guide.join("\n")
      expect(text).not_to include("Anti-Hallucination Protocol")
    ensure
      RailsAiContext.configuration.anti_hallucination_rules = original
    end
  end

  describe "#render_tools_guide_compact" do
    it "assembles a compact guide without the full table" do
      lines = helper.render_tools_guide_compact
      text = lines.join("\n")
      expect(text).to include("Tools (#{RailsAiContext::Server::TOOLS.size})")
      expect(text).to include("power tool")
      expect(text).to include("All #{RailsAiContext::Server::TOOLS.size} tools")
      # Compact uses name list, not the full table
      expect(text).not_to include("| MCP |")
      expect(text).not_to include("| CLI |")
    end

    it "includes the anti-hallucination protocol by default" do
      text = helper.render_tools_guide_compact.join("\n")
      expect(text).to include("Anti-Hallucination Protocol")
    end

    it "omits the protocol when anti_hallucination_rules is false" do
      original = RailsAiContext.configuration.anti_hallucination_rules
      RailsAiContext.configuration.anti_hallucination_rules = false
      text = helper.render_tools_guide_compact.join("\n")
      expect(text).not_to include("Anti-Hallucination Protocol")
    ensure
      RailsAiContext.configuration.anti_hallucination_rules = original
    end
  end

  describe "#cli_cmd" do
    it "generates zsh-safe rake command without params" do
      expect(helper.cli_cmd("schema")).to eq("rails 'ai:tool[schema]'")
    end

    it "generates zsh-safe rake command with params" do
      expect(helper.cli_cmd("schema", "table=users")).to eq("rails 'ai:tool[schema]' table=users")
    end
  end

  describe "#tool_call_inline" do
    it "returns MCP + CLI in :mcp mode" do
      result = helper.tool_call_inline("rails_get_context", "model:\"Post\"", "context", "model=Post")
      expect(result).to include("rails_get_context(model:\"Post\")")
      expect(result).to include("rails 'ai:tool[context]' model=Post")
    end

    it "returns only CLI in :cli mode" do
      RailsAiContext.configuration.tool_mode = :cli
      result = helper.tool_call_inline("rails_get_context", "model:\"Post\"", "context", "model=Post")
      expect(result).to include("rails 'ai:tool[context]'")
      expect(result).not_to include("rails_get_context(model:")
    end
  end
end
