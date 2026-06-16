# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::CLI::ToolRunner do
  describe ".available_tools" do
    it "returns all tools from Server::TOOLS" do
      tools = described_class.available_tools
      expect(tools.size).to be >= 24
      expect(tools).to include(RailsAiContext::Tools::GetSchema)
    end

    it "respects skip_tools config" do
      allow(RailsAiContext.configuration).to receive(:skip_tools).and_return(%w[rails_security_scan])
      tools = described_class.available_tools
      tool_names = tools.map(&:tool_name)
      expect(tool_names).not_to include("rails_security_scan")
    end
  end

  describe ".short_name" do
    it "strips rails_get_ prefix" do
      expect(described_class.short_name("rails_get_schema")).to eq("schema")
    end

    it "strips rails_ prefix for non-get tools" do
      expect(described_class.short_name("rails_search_code")).to eq("search_code")
    end

    it "strips rails_ prefix for analyze" do
      expect(described_class.short_name("rails_analyze_feature")).to eq("analyze_feature")
    end

    it "strips rails_ prefix for validate" do
      expect(described_class.short_name("rails_validate")).to eq("validate")
    end

    it "strips rails_ prefix for security_scan" do
      expect(described_class.short_name("rails_security_scan")).to eq("security_scan")
    end
  end

  describe ".tool_list" do
    it "returns formatted list of all tools" do
      list = described_class.tool_list
      expect(list).to include("Available tools:")
      expect(list).to include("schema")
      expect(list).to include("routes")
      expect(list).to include("search_code")
      expect(list).to include("validate")
      expect(list).to include("rails 'ai:tool[NAME]'")
    end
  end

  describe ".tool_help" do
    it "generates help from input_schema" do
      help = described_class.tool_help(RailsAiContext::Tools::GetSchema)
      expect(help).to include("rails_get_schema")
      expect(help).to include("--table")
      expect(help).to include("--detail")
      expect(help).to include("summary/standard/full")
      expect(help).to include("--limit")
    end

    it "shows required parameters" do
      help = described_class.tool_help(RailsAiContext::Tools::SearchCode)
      expect(help).to include("[required]")
      expect(help).to include("--pattern")
    end
  end

  describe "tool resolution" do
    it "resolves full MCP name" do
      runner = described_class.new("rails_get_schema", [])
      expect(runner.tool_class).to eq(RailsAiContext::Tools::GetSchema)
    end

    it "resolves without rails_ prefix" do
      runner = described_class.new("get_schema", [])
      expect(runner.tool_class).to eq(RailsAiContext::Tools::GetSchema)
    end

    it "resolves short name" do
      runner = described_class.new("schema", [])
      expect(runner.tool_class).to eq(RailsAiContext::Tools::GetSchema)
    end

    it "resolves search_code" do
      runner = described_class.new("search_code", [])
      expect(runner.tool_class).to eq(RailsAiContext::Tools::SearchCode)
    end

    it "resolves validate" do
      runner = described_class.new("validate", [])
      expect(runner.tool_class).to eq(RailsAiContext::Tools::Validate)
    end

    it "resolves analyze_feature" do
      runner = described_class.new("analyze_feature", [])
      expect(runner.tool_class).to eq(RailsAiContext::Tools::AnalyzeFeature)
    end

    it "resolves conventions" do
      runner = described_class.new("conventions", [])
      expect(runner.tool_class).to eq(RailsAiContext::Tools::GetConventions)
    end

    it "raises ToolNotFoundError for unknown tool" do
      expect { described_class.new("nonexistent", []) }
        .to raise_error(described_class::ToolNotFoundError, /Unknown tool/)
    end

    it "suggests close matches on typo" do
      expect { described_class.new("schem", []) }
        .to raise_error(described_class::ToolNotFoundError, /Did you mean/)
    end
  end

  describe "argument parsing - CLI style" do
    it "parses --key value pairs" do
      runner = described_class.new("schema", [ "--table", "users", "--detail", "full" ])
      output = runner.run
      expect(output).to include("users")
    end

    it "parses --key=value pairs" do
      runner = described_class.new("schema", [ "--detail=summary" ])
      output = runner.run
      expect(output).to be_a(String)
      expect(output.length).to be > 0
    end

    it "parses boolean --flag as true" do
      runner = described_class.new("search_code", [ "--pattern", "def index", "--exclude-tests" ])
      output = runner.run
      expect(output).to be_a(String)
    end

    it "parses --no-flag as false" do
      runner = described_class.new("routes", [ "--no-app-only", "--detail", "summary" ])
      output = runner.run
      expect(output).to be_a(String)
    end

    it "converts kebab-case to snake_case" do
      runner = described_class.new("search_code", [ "--pattern", "test", "--match-type", "definition" ])
      output = runner.run
      expect(output).to be_a(String)
    end
  end

  describe "argument parsing - rake style (hash)" do
    it "accepts hash params" do
      runner = described_class.new("schema", { detail: "summary" })
      output = runner.run
      expect(output).to be_a(String)
      expect(output.length).to be > 0
    end

    it "accepts string keys" do
      runner = described_class.new("schema", { "detail" => "summary" })
      output = runner.run
      expect(output).to be_a(String)
    end
  end

  describe "validation" do
    it "returns friendly message for missing required params instead of raising" do
      runner = described_class.new("search_code", [])
      output = runner.run
      expect(output).to include("Pattern is required")
    end

    it "strips invalid enum value and uses tool default instead of raising" do
      runner = described_class.new("schema", [ "--detail", "superdetailed" ])
      output = runner.run
      expect(output).to be_a(String)
      expect(output).not_to be_empty
    end
  end

  describe "JSON mode" do
    it "wraps output in JSON envelope" do
      runner = described_class.new("conventions", [], json_mode: true)
      output = runner.run
      parsed = JSON.parse(output)
      expect(parsed["tool"]).to eq("rails_get_conventions")
      expect(parsed["output"]).to be_a(String)
    end
  end

  describe "mcp >= 0.20.0 compatibility (issue #85)" do
    # mcp 0.20.0 removed MCP::Tool::InputSchema#schema, leaving only #to_h.
    # This double mimics that surface: #to_h works, #schema raises.
    # The locked dev mcp still exposes both, so the double is the only way to
    # reproduce the break version-independently.
    let(:schema_only_to_h) do
      double(
        "InputSchema020",
        to_h: {
          type: "object",
          properties: {
            table: { type: "string", description: "Table name" },
            detail: { type: "string", enum: %w[summary standard full], description: "Detail level" }
          },
          required: [ "table" ]
        }
      )
    end

    it "tool_help reads the schema via to_h, not the removed #schema accessor" do
      allow(RailsAiContext::Tools::GetSchema).to receive(:input_schema_value).and_return(schema_only_to_h)
      help = described_class.tool_help(RailsAiContext::Tools::GetSchema)
      expect(help).to include("--table")
      expect(help).to include("[required]")
    end

    it "run builds and validates kwargs via to_h, not the removed #schema accessor" do
      allow(RailsAiContext::Tools::GetSchema).to receive(:input_schema_value).and_return(schema_only_to_h)
      runner = described_class.new("rails_get_schema", [ "--detail", "summary" ])
      output = nil
      expect { output = runner.run }.not_to raise_error
      expect(output).to be_a(String)
      expect(output).not_to be_empty
    end
  end

  describe "integration - real tool calls" do
    it "runs schema tool" do
      runner = described_class.new("schema", [ "--detail", "summary" ])
      output = runner.run
      expect(output).to include("table")
    end

    it "runs conventions tool" do
      runner = described_class.new("conventions", [])
      output = runner.run
      expect(output).to be_a(String)
      expect(output.length).to be > 0
    end

    it "runs config tool" do
      runner = described_class.new("config", [])
      output = runner.run
      expect(output).to be_a(String)
    end

    it "runs gems tool" do
      runner = described_class.new("gems", [])
      output = runner.run
      expect(output).to be_a(String)
    end
  end
end
