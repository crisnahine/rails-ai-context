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

    # Every neighbouring key in the generated initializer takes symbols
    # (ai_tools, tool_mode, preset), so %i[] is the spelling a reader reaches
    # for - and it used to skip nothing at all, silently.
    it "respects skip_tools written as symbols" do
      RailsAiContext.configuration.skip_tools = %i[rails_security_scan]
      tool_names = described_class.available_tools.map(&:tool_name)
      expect(tool_names).not_to include("rails_security_scan")
    ensure
      RailsAiContext.configuration.skip_tools = []
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

    it "shows only the CLI usage form on standalone installs (no rake tasks exist)" do
      allow(RailsAiContext::InstallMode).to receive(:standalone?).and_return(true)

      list = described_class.tool_list
      expect(list).to include("Usage: rails-ai-context tool NAME --param value")
      expect(list).not_to include("rails 'ai:tool[NAME]'")
    end

    it "truncates a long description at a word boundary with an ellipsis" do
      list = described_class.tool_list
      full_description = RailsAiContext::Tools::AnalyzeFeature.description_value.to_s
      expected = described_class.truncate_at_word(full_description, 79)
      expect(list).to include(expected)
      # The old bug cut mid-word with no "...": guard against that regressing.
      expect(list).not_to include(full_description[0..79])
    end
  end

  describe ".truncate_at_word" do
    it "leaves short text unchanged" do
      expect(described_class.truncate_at_word("short text", 79)).to eq("short text")
    end

    it "truncates long text at the last whole word and appends an ellipsis" do
      text = "Full-stack feature analysis: models, controllers, routes, services, jobs, views, tests"
      result = described_class.truncate_at_word(text, 79)
      expect(result).to eq("Full-stack feature analysis: models, controllers, routes, services, jobs,...")
      expect(text).to start_with(result.delete_suffix("..."))
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

    it "shows both invocation forms on in-Gemfile installs" do
      allow(RailsAiContext::InstallMode).to receive(:standalone?).and_return(false)

      help = described_class.tool_help(RailsAiContext::Tools::GetSchema)
      expect(help).to include("rails 'ai:tool[schema]'")
      expect(help).to include("rails-ai-context tool schema")
    end

    it "shows only the CLI form on standalone installs (no rake tasks exist)" do
      allow(RailsAiContext::InstallMode).to receive(:standalone?).and_return(true)

      help = described_class.tool_help(RailsAiContext::Tools::GetSchema)
      expect(help).to include("rails-ai-context tool schema")
      expect(help).not_to include("ai:tool")
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

    it "points to both the rake and CLI ways to list tools, not a rake-incompatible --list flag" do
      expect { described_class.new("nonexistent", []) }
        .to raise_error(described_class::ToolNotFoundError) { |e|
          expect(e.message).to include("rails 'ai:tool'")
          expect(e.message).to include("rails-ai-context tool --list")
        }
    end

    it "points only to the CLI list command on standalone installs (no rake tasks exist)" do
      allow(RailsAiContext::InstallMode).to receive(:standalone?).and_return(true)

      expect { described_class.new("nonexistent", []) }
        .to raise_error(described_class::ToolNotFoundError) { |e|
          expect(e.message).to include("rails-ai-context tool --list")
          expect(e.message).not_to include("ai:tool'")
        }
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

    # Asserting on the rendered output let a silent inversion ship: a boolean
    # flag consumed no value, so `--app-only false` set app_only to true and
    # dropped the "false" token. Read the parsed params instead.
    # `validate --files a.rb b.rb` kept only a.rb and reported "1/1 files
    # passed" - a validation tool answering "pass" for a set containing a
    # broken file.
    describe "array parameters" do
      def parse(args)
        described_class.new("validate", args).send(:build_kwargs)
      end

      it "takes every following token, not just the first" do
        expect(parse([ "--files", "a.rb", "b.rb", "c.rb" ])).to include(files: %w[a.rb b.rb c.rb])
      end

      it "stops at the next flag" do
        expect(parse([ "--files", "a.rb", "b.rb", "--level", "syntax" ]))
          .to include(files: %w[a.rb b.rb], level: "syntax")
      end

      it "still accepts the comma-separated form" do
        expect(parse([ "--files", "a.rb,b.rb" ])).to include(files: %w[a.rb b.rb])
      end

      it "handles a single file" do
        expect(parse([ "--files", "a.rb" ])).to include(files: %w[a.rb])
      end

      # docs/CLI.md teaches both spellings; fixing only the space form left
      # the equals form still dropping every file after the first.
      it "takes every token after the equals form too" do
        expect(parse([ "--files=a.rb", "b.rb" ])).to include(files: %w[a.rb b.rb])
      end

      # The comma form is the documented one. Mixing it with a second token
      # used to fabricate a path no filesystem could hold.
      it "splits commas in every collected token, not just a lone one" do
        expect(parse([ "--files", "a.rb,b.rb", "c.rb" ])).to include(files: %w[a.rb b.rb c.rb])
      end

      it "reads a bare flag as no files rather than true" do
        expect(parse([ "--files" ])).to include(files: [])
      end

      # Array params sit next to the rake-style key=value form. Consuming
      # every non-flag token swallowed the next parameter whole.
      it "stops at a rake-style key=value token" do
        parsed = described_class.new("context", [ "--include", "callbacks", "model=Post" ]).send(:build_kwargs)
        expect(parsed).to include(include: %w[callbacks], model: "Post")
      end
    end

    describe "boolean values" do
      def parse(args)
        described_class.new("routes", args).send(:build_kwargs)
      end

      it "reads a space-separated false" do
        expect(parse([ "--app-only", "false" ])).to include(app_only: false)
      end

      it "reads a space-separated true" do
        expect(parse([ "--app-only", "true" ])).to include(app_only: true)
      end

      it "still treats a bare flag as true" do
        expect(parse([ "--app-only" ])).to include(app_only: true)
      end

      it "reads --no-flag as false" do
        expect(parse([ "--no-app-only" ])).to include(app_only: false)
      end

      it "reads --flag=false" do
        expect(parse([ "--app-only=false" ])).to include(app_only: false)
      end

      it "accepts the other falsey spellings" do
        expect(parse([ "--app-only", "no" ])).to include(app_only: false)
        expect(parse([ "--app-only", "0" ])).to include(app_only: false)
      end

      it "leaves a following flag alone" do
        expect(parse([ "--app-only", "--detail", "summary" ]))
          .to include(app_only: true, detail: "summary")
      end

      it "does not swallow a following non-boolean word" do
        parsed = described_class.new("search_code", [ "--exclude-tests", "pattern-ish" ])
                                .send(:build_kwargs)
        expect(parsed).to include(exclude_tests: true)
      end
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

    it "includes error: false for a successful call" do
      runner = described_class.new("conventions", [], json_mode: true)
      output = runner.run
      expect(JSON.parse(output)["error"]).to eq(false)
    end
  end

  describe "#error" do
    it "defaults to false before any call" do
      runner = described_class.new("conventions", [])
      expect(runner.error).to eq(false)
    end

    it "stays false for a successful tool call" do
      runner = described_class.new("conventions", [])
      runner.run
      expect(runner.error).to eq(false)
    end

    it "stays false for an informational not-found response (deliberate non-goal)" do
      # "Model not found" is a friendly text response, not an isError result -
      # scripts should not treat it as a failure worth a non-zero exit.
      runner = described_class.new("model_details", [ "--model", "TotallyNotAModel" ])
      output = runner.run
      expect(output).to include("not found")
      expect(runner.error).to eq(false)
    end

    it "becomes true when the tool response reports isError" do
      runner = described_class.new("conventions", [])
      response = instance_double(MCP::Tool::Response, content: [ { type: "text", text: "boom" } ], error?: true)
      runner.send(:extract_output, response)
      expect(runner.error).to eq(true)
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
