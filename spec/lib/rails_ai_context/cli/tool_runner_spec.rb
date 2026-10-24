# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::CLI::ToolRunner do
  describe "the tools it lists" do
    it "returns all tools the server serves" do
      tools = RailsAiContext::Server.exposed_tools
      expect(tools.size).to be >= 24
      expect(tools).to include(RailsAiContext::Tools::GetSchema)
    end

    it "respects skip_tools config" do
      allow(RailsAiContext.configuration).to receive(:skip_tools).and_return(%w[rails_security_scan])
      tools = RailsAiContext::Server.exposed_tools
      tool_names = tools.map(&:tool_name)
      expect(tool_names).not_to include("rails_security_scan")
    end

    # Every neighbouring key in the generated initializer takes symbols
    # (ai_tools, tool_mode, preset), so %i[] is the spelling a reader reaches
    # for - and it used to skip nothing at all, silently.
    it "respects skip_tools written as symbols" do
      RailsAiContext.configuration.skip_tools = %i[rails_security_scan]
      tool_names = RailsAiContext::Server.exposed_tools.map(&:tool_name)
      expect(tool_names).not_to include("rails_security_scan")
    ensure
      RailsAiContext.configuration.skip_tools = []
    end
  end

  # Loading every tool to find one is a tenth of a one-tool CLI call.
  describe "resolving a name the tool classes spell" do
    it "loads no tool list for a short, medium or full name" do
      allow(RailsAiContext::Server).to receive(:exposed_tools).and_call_original

      %w[schema get_schema rails_get_schema search_code rails_validate].each do |name|
        expect(described_class.new(name, []).send(:tool_class).tool_name).to start_with("rails_")
      end

      expect(RailsAiContext::Server).not_to have_received(:exposed_tools)
    end

    # "Unknown tool" sent the reader looking for a tool the gem has.
    it "still refuses a skipped tool, saying skip_tools turned it off" do
      allow(RailsAiContext.configuration).to receive(:skip_tools).and_return([ "rails_get_schema" ])

      expect { described_class.new("schema", []) }.to raise_error(
        described_class::ToolNotFoundError, /\Arails_get_schema is turned off in this app: skip_tools lists it/
      )
    end

    it "suggests the closest name for a miss" do
      expect { described_class.new("shema", []) }.to raise_error(/Did you mean 'schema'/)
    end

    it "suggests a retired name for a miss near one, while its section is on" do
      expect { described_class.new("gemz", []) }.to raise_error(/\AUnknown tool 'gemz'\. Did you mean 'gems'\?/)

      allow(RailsAiContext.configuration).to receive(:skip_tools).and_return([ "rails_get_gems" ])
      expect { described_class.new("gemz", []) }.to raise_error { |error| expect(error.message).not_to include("'gems'") }
    end
  end

  # Scripts and context files name the ten tools whose answers are rails_get_config sections.
  describe "a name that became a config section" do
    it "resolves every old short and full name to rails_get_config" do
      RailsAiContext::Tools::GetConfig::SECTIONS.map(&:tool_name).each do |tool_name|
        short = described_class.short_name(tool_name)
        [ short, tool_name ].each do |name|
          expect(described_class.new(name, []).tool_class).to eq(RailsAiContext::Tools::GetConfig)
        end
      end
    end

    it "answers an old name from its section, with the line the MCP server adds" do
      old = described_class.new("i18n", [ "--locale", "en" ]).run
      section = described_class.new("config", [ "--section", "i18n", "--locale", "en" ]).run

      expect(old).to eq("#{section}\n\n_rails_get_i18n is now `rails_get_config(section:\"i18n\", locale:\"en\")`; call that instead._")
    end

    it "reports rails_get_config in the JSON envelope of an old name" do
      parsed = JSON.parse(described_class.new("gems", [], json_mode: true).run)

      expect(parsed["tool"]).to eq("rails_get_config")
      expect(parsed["output"]).to include('_rails_get_gems is now `rails_get_config(section:"gems")`; call that instead._')
    end

    it "answers a section skip_tools turned off with the turned-off message" do
      allow(RailsAiContext.configuration).to receive(:skip_tools).and_return([ "rails_get_gems" ])
      runner = described_class.new("config", [ "--section", "gems" ])

      expect(runner.run).to start_with("The `gems` section of rails_get_config is turned off")
      expect(runner.error).to be(true)
    end

    it "refuses an old name skip_tools lists, saying so" do
      allow(RailsAiContext.configuration).to receive(:skip_tools).and_return([ "rails_get_env" ])

      expect { described_class.new("env", []) }.to raise_error(
        described_class::ToolNotFoundError, /\Arails_get_env is turned off in this app/
      )
    end

    it "hands the --environment flag to the env_config section only" do
      env_config = described_class.new("config", [ "--section", "env_config" ], environment: "production").run
      app = described_class.new("config", [], environment: "production").run

      expect(described_class.new("env_config", [ "--environment", "production" ]).run).to start_with("#{env_config}\n\n_rails_get_env_config is now")
      expect(app).not_to include("does not read")
    end

    it "hands it over whatever the capitalisation of the section's name" do
      env_config = described_class.new("config", [ "--section", "env_config" ], environment: "production").run

      expect(env_config).to start_with("Environment 'production' not found.")
      expect(described_class.new("config", [ "--section", "ENV_CONFIG" ], environment: "production").run).to eq(env_config)
    end

    it "suggests a flag the old name takes for a word that is no flag" do
      expect { described_class.new("gems", [ "auth" ]).run }.to raise_error(described_class::InvalidArgumentError) { |error|
        expect(error.message).to eq(
          "Unexpected argument:\n  'auth' is not a flag - did you mean '--category auth'?\nValid params: category, offset, limit"
        )
      }
    end

    it "gives an old name its own help: the section it runs and that section's parameters" do
      allow(RailsAiContext::InstallMode).to receive(:standalone?).and_return(true)
      help = described_class.new("gems", []).help.lines.map(&:chomp)

      expect(help.first).to eq("rails_get_gems - runs the `gems` section of rails_get_config (notable gems by category).")
      expect(help).to include("  rails-ai-context tool gems --category VALUE --offset VALUE --limit VALUE")
      expect(help.grep(/\A  --/).map { |line| line.split.first }).to eq(%w[--category --offset --limit])
    end

    it "gives rails_get_config the help of every section that is on" do
      help = described_class.new("config", []).help

      expect(help).to start_with("rails_get_config - Get the app's configuration")
      expect(help).to include("--section", "--locale", "--category")
    end
  end

  # The MCP server keeps the built-in when a custom tool claims its name and
  # lets skip_tools hand the name over; the CLI has to answer the same.
  describe "a custom tool claiming a built-in's name" do
    # A stand-in rather than a BaseTool subclass, which would enrol itself in
    # the registry every later example reads.
    let(:custom) { double("MyApp::SchemaTool", tool_name: "rails_get_schema") }

    before { allow(RailsAiContext::Server).to receive(:resolve_custom_tools).and_return([ custom ]) }

    it "resolves to the built-in, as the MCP server serves it" do
      expect(described_class.new("schema", []).tool_class).to eq(RailsAiContext::Tools::GetSchema)
      expect(RailsAiContext::Server.exposed_tools.find { |t| t.tool_name == "rails_get_schema" })
        .to eq(RailsAiContext::Tools::GetSchema)
    end

    it "lists the name once, as tools/list does" do
      expect(RailsAiContext::Server.exposed_tools.count { |t| t.tool_name == "rails_get_schema" }).to eq(1)
      expect(described_class.tool_list.scan(/^  schema /).size).to eq(1)
    end

    it "resolves to the custom tool once skip_tools names the built-in" do
      allow(RailsAiContext.configuration).to receive(:skip_tools).and_return([ "rails_get_schema" ])

      expect(described_class.new("schema", []).tool_class).to eq(custom)
      expect(RailsAiContext::Server.exposed_tools).to include(custom)
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

      expect(list).to include("Full-stack feature analysis: models, controllers, routes, services, jobs...")
      # The old bug cut mid-word with no "...": guard against that regressing.
      expect(list).not_to include(full_description[0..79])
    end

    # A cut landing right after a sentence left the period in front of the
    # ellipsis, printing four dots.
    it "drops the trailing punctuation a cut lands on" do
      list = described_class.tool_list

      expect(list).to include("Read recent log entries with level filtering and sensitive data redaction...")
      expect(list).not_to include("....")
      expect(list).not_to include(" -...")
    end

    it "keeps every description line inside the column width" do
      rows = described_class.tool_list.lines.grep(/\A {2}\S/).map(&:chomp)
      descriptions = rows.map do |row|
        name = row.strip.split(/\s/, 2).first
        row.sub(/\A {2}#{Regexp.escape(name)} +/, "")
      end

      expect(descriptions).to all(satisfy { |d| d.length <= 79 })
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

    it "resolves conventions to its config section" do
      runner = described_class.new("conventions", [])
      expect(runner.tool_class).to eq(RailsAiContext::Tools::GetConfig)
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

      # The cursor advances by tokens, never by values: a comma token yields
      # more values than it consumed, and counting values skipped the flag.
      it "keeps the cursor on tokens when a comma token expands" do
        expect(parse([ "--files", "a.rb,b.rb", "c.rb", "--level", "syntax" ]))
          .to include(files: %w[a.rb b.rb c.rb], level: "syntax")
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

      # The word is not the flag's value, and it is not usable either - it
      # used to be dropped without a word about it.
      it "refuses a following non-boolean word instead of swallowing it" do
        expect { described_class.new("search_code", [ "--exclude-tests", "pattern-ish" ]).send(:build_kwargs) }
          .to raise_error(described_class::InvalidArgumentError, /pattern-ish/)
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

    it "warns about a detail level it does not have and answers at the default one" do
      runner = described_class.new("schema", [ "--detail", "superdetailed" ])
      output = nil
      expect { output = runner.run }.to output(/'superdetailed' is not a valid value for detail/).to_stderr
      expect(output).to include("posts")
      expect(runner.error).to eq(false)
    end

    it "refuses a value outside an optional parameter's list, naming the list, without running the tool" do
      expect(RailsAiContext::Tools::GetSchema).not_to receive(:call)
      runner = described_class.new("schema", [ "--format", "xml" ])

      answer = nil
      expect { answer = runner.run }.not_to output.to_stderr
      expect(answer).to start_with("**Error:** `xml` is not a valid `format`. Valid: json, markdown")
      expect(runner.error).to eq(true)
    end

    it "hands rails_get_config any section, so the tool refuses one it does not have" do
      runner = described_class.new("config", [ "--section", "bogus" ])

      expect(runner.run).to start_with("`section` does not take 'bogus'. It takes: app, gems,")
      expect(runner.error).to eq(true)
    end

    it "takes a value in another case as the listed one" do
      expect(described_class.new("schema", [ "--format", "JSON" ]).run).to start_with("{")
      expect(described_class.new("config", [ "--section", "I18N" ]).run).to include("- **Default locale:** en")
    end

    # The text says the parameter is required, so a script wrapping the CLI
    # has to be able to see that from the exit status.
    it "reports a missing required param as a failed call" do
      runner = described_class.new("search_code", [])
      runner.run
      expect(runner.error).to eq(true)
    end

    it "answers a bad value on a required enum as invalid, naming the allowed values" do
      runner = described_class.new("migration_advisor", [ "--action", "bogus", "--table", "posts" ])
      output = runner.run
      expect(output).to include("`bogus` is not a valid `action`. Valid: add_column")
      expect(output).not_to include("is required")
      expect(runner.error).to eq(true)
    end

    it "does not call a custom tool whose required enum got a bad value" do
      custom = Class.new(MCP::Tool) do
        tool_name "rails_probe_mode"
        description "probe"
        input_schema(properties: { mode: { type: "string", enum: %w[fast slow] } }, required: [ "mode" ])

        def self.call(mode:)
          MCP::Tool::Response.new([ { type: "text", text: "mode=#{mode.inspect}" } ])
        end
      end
      allow(RailsAiContext::Server).to receive(:resolve_custom_tools).and_return([ custom ])
      runner = described_class.new("rails_probe_mode", [ "--mode", "bogus" ])

      output = runner.run
      expect(output).to eq("**Error:** `bogus` is not a valid `mode`. Valid: fast, slow")
      expect(runner.error).to eq(true)
    end

    it "leaves a call that supplied its required params successful" do
      runner = described_class.new("search_code", [ "--pattern", "def" ])
      runner.run
      expect(runner.error).to eq(false)
    end

    # A tool that answers with a listing when it has nothing to work on is
    # giving guidance, not failing.
    it "leaves a tool with no required params successful when called bare" do
      runner = described_class.new("model_details", [])
      runner.run
      expect(runner.error).to eq(false)
    end

    # Coerced to 0 or to the default, the value answers a question nobody asked.
    it "refuses a value of another type than the parameter's, naming the type, without running the tool" do
      expect(RailsAiContext::Tools::SearchCode).not_to receive(:call)

      [ [ "--pattern", "def", "--limit", "abc" ], { pattern: "def", limit: "abc" } ].each do |args|
        runner = described_class.new("search_code", args)
        answer = nil
        expect { answer = runner.run }.not_to output.to_stderr
        expect(answer).to start_with("**Error:** `abc` is not a valid `limit`. Valid: an integer")
        expect(runner.error).to eq(true)
      end
    end

    it "refuses --no- on a parameter that is no boolean, naming its type, without running the tool" do
      expect(RailsAiContext::Tools::SearchCode).not_to receive(:call)
      expect(RailsAiContext::Tools::GetSchema).not_to receive(:call)

      {
        [ "search_code", [ "--pattern", "def", "--no-limit" ] ] => "**Error:** `--no-limit` is not a valid `limit`. Valid: an integer",
        [ "schema", [ "--no-table" ] ] => "**Error:** `--no-table` is not a valid `table`. Valid: a string",
        [ "validate", [ "--no-files" ] ] => "**Error:** `--no-files` is not a valid `files`. Valid: an array",
        [ "search_code", [ "--pattern", "def", "--no-match-type" ] ] =>
          "**Error:** `--no-match-type` is not a valid `match_type`. Valid: any, definition, class, call, trace"
      }.each do |(tool, args), refusal|
        runner = described_class.new(tool, args)

        expect(runner.run).to start_with(refusal)
        expect(runner.error).to eq(true)
      end
    end

    it "falls back with a warning for --no-detail, as for any other detail it cannot take" do
      runner = described_class.new("routes", [ "--no-detail" ])

      expect { runner.run }.to output(/'false' is not a valid value for detail\. Valid: summary, standard, full\. Using default\./).to_stderr
      expect(runner.error).to eq(false)
    end

    it "still names an unknown parameter typed with --no-" do
      runner = described_class.new("schema", [ "--no-tabel" ])

      expect { runner.run }.to raise_error(described_class::InvalidArgumentError, /'--no-tabel' - did you mean '--table'\?/)
    end

    it "refuses a word that is no boolean for a boolean parameter" do
      runner = described_class.new("routes", [ "--app-only=maybe" ])

      expect(runner.run).to start_with("**Error:** `maybe` is not a valid `app_only`. Valid: true or false")
      expect(runner.error).to eq(true)
    end

    it "names the valid levels when onboard is asked for the retired quick level" do
      runner = described_class.new("onboard", [ "--detail", "quick" ])
      expect { runner.run }
        .to output(/'quick' is not a valid value for detail\. Valid: summary, standard, full\. Using default\./).to_stderr
    end

    it "keeps a numeric integer value" do
      runner = described_class.new("search_code", [ "--pattern", "def", "--limit", "5" ])
      expect(runner.send(:build_kwargs)).to include(limit: 5)
    end
  end

  describe "usage errors" do
    # `--table` with nothing after it reached the tool as the Boolean true and
    # crashed inside it with a raw NoMethodError.
    it "refuses a value-taking flag with no value" do
      runner = described_class.new("schema", [ "--table" ])
      expect { runner.run }
        .to raise_error(described_class::InvalidArgumentError, /--table/)
    end

    it "refuses a value-taking flag followed by another flag" do
      runner = described_class.new("schema", [ "--table", "--detail", "full" ])
      expect { runner.run }
        .to raise_error(described_class::InvalidArgumentError, /--table/)
    end

    # The type name is written into the sentence, so a vowel-initial one read
    # "takes a integer value".
    it "articles the type name it names" do
      expect { described_class.new("schema", [ "--limit" ]).run }
        .to raise_error(described_class::InvalidArgumentError, /takes an integer value/)
      expect { described_class.new("schema", [ "--table" ]).run }
        .to raise_error(described_class::InvalidArgumentError, /takes a string value/)
    end

    it "articles every type a tool schema can carry" do
      articled = %w[string integer number boolean array object].map do |type|
        described_class.new("schema", []).send(:missing_value_message, :thing, { type: type }).lines[1].strip
      end

      expect(articled).to eq([
        "'--thing' takes a string value",
        "'--thing' takes an integer value",
        "'--thing' takes a number value",
        "'--thing' takes a boolean value",
        "'--thing' takes an array value",
        "'--thing' takes an object value"
      ])
    end

    it "still reads a bare boolean flag as true" do
      expect(described_class.new("routes", [ "--app-only" ]).send(:build_kwargs))
        .to include(app_only: true)
    end

    # `tool schema posts` is a plausible mistype of `--table posts`; the token
    # used to be dropped and a full listing came back.
    it "refuses a positional argument after the tool name" do
      runner = described_class.new("schema", [ "posts" ])
      expect { runner.run }
        .to raise_error(described_class::InvalidArgumentError) { |e|
          expect(e.message).to include("posts")
          expect(e.message).to include("--table")
        }
    end

    it "names the tool's own params in the refusal" do
      runner = described_class.new("search_code", [ "widget" ])
      expect { runner.run }
        .to raise_error(described_class::InvalidArgumentError, /--pattern/)
    end

    it "ends an unknown-param refusal with the same valid-params sentence the other refusals use" do
      runner = described_class.new("schema", [ "--tabl", "users" ])
      expect { runner.run }
        .to raise_error(described_class::InvalidArgumentError) { |e|
          expect(e.message).to eq(
            "Unknown param:\n  '--tabl' - did you mean '--table'?\n" \
            "Valid params: table, detail, limit, offset, format"
          )
        }
    end

    # The suggestion came in the rake spelling whatever was typed.
    it "suggests the param in the form the unknown one was typed" do
      suggestion = lambda do |args|
        described_class.new("schema", args).run
      rescue described_class::InvalidArgumentError => e
        e.message.lines[1].strip
      end

      expect(suggestion.call([ "--tabel=users" ])).to eq("'--tabel' - did you mean '--table'?")
      expect(suggestion.call([ "tabel=users" ])).to eq("'tabel' - did you mean 'table='?")
      expect(suggestion.call(tabel: "users")).to eq("'tabel' - did you mean 'table='?")
    end
  end

  describe "JSON mode" do
    it "wraps output in JSON envelope" do
      runner = described_class.new("conventions", [], json_mode: true)
      output = runner.run
      parsed = JSON.parse(output)
      expect(parsed["tool"]).to eq("rails_get_config")
      expect(parsed["output"]).to be_a(String)
    end

    it "includes error: false for a successful call" do
      runner = described_class.new("conventions", [], json_mode: true)
      output = runner.run
      expect(JSON.parse(output)["error"]).to eq(false)
    end

    # A boolean flag takes only a boolean word, so -j and -h after it are the runner's own flags.
    it "reads -j and -h after a boolean flag as flags, and after a value flag as its value" do
      expect(JSON.parse(described_class.new("search_code", %w[--pattern Post --exact-match -j]).run))
        .to include("tool" => "rails_search_code", "error" => false)
      expect(described_class.new("search_code", %w[--pattern Post --exact-match -h]).run).to start_with("rails_search_code - ")
      expect(described_class.new("search_code", %w[--pattern -j]).run).to start_with("# Search: `-j`")
    end

    # The binary answers a refusal as an envelope when the runner read -j, so it reads every word first.
    it "reads a -j that follows a refused word before it refuses" do
      runner = described_class.new("search_code", %w[--pattern --exact-match -j])

      expect { runner.run }.to raise_error(described_class::InvalidArgumentError, /'--pattern' takes a string value/)
      expect(runner.json_mode).to be(true)
    end

    # Sidekiq's logger, made the first time a tool reaches it, announced its
    # Redis connection on stdout ahead of the envelope.
    it "keeps what the app prints while the tool runs off stdout" do
      custom = Class.new(MCP::Tool) do
        tool_name "rails_probe_noise"
        description "probe"

        def self.call
          $stdout.puts "from $stdout"
          STDOUT.puts "from STDOUT"
          system("echo from a child")
          MCP::Tool::Response.new([ { type: "text", text: "the answer" } ])
        end
      end
      allow(RailsAiContext::Server).to receive(:resolve_custom_tools).and_return([ custom ])
      runner = described_class.new("rails_probe_noise", [], json_mode: true)
      answer = nil

      expect {
        expect { answer = runner.run }.not_to output.to_stdout_from_any_process
      }.to output(/from \$stdout/).to_stderr_from_any_process
      expect(JSON.parse(answer)).to include("output" => "the answer", "error" => false)
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

    # The CLI prints the response text as it comes, so anything a tool adds to
    # mark its answer has to live outside that text.
    it "prints a not-found answer with no invisible marker in it" do
      plain = described_class.new("schema", [ "--table", "no_such_table_here" ]).run
      json = described_class.new("schema", [ "--table", "no_such_table_here" ], json_mode: true).run

      expect(plain).to include("not found")
      expect(plain).not_to include("​")
      expect(json).not_to include("​")
      expect(json).not_to include('\\u200b')
    end
  end

  # Under LANG=C, ARGV arrives tagged BINARY, and MCP clients always send UTF-8.
  describe "arguments from a shell whose locale is not UTF-8" do
    it "reads a non-ASCII value as UTF-8" do
      kwargs = described_class.new("search_code", [ "--pattern", "naïve".b, "--path=app/ñ".b ]).send(:build_kwargs)

      expect(kwargs.values_at(:pattern, :path)).to eq([ "naïve", "app/ñ" ])
      expect(kwargs.values_at(:pattern, :path).map(&:encoding)).to all(eq(Encoding::UTF_8))
    end

    it "reads the rake task's key=value pairs as UTF-8 too" do
      expect(described_class.new("search_code", { pattern: "naïve".b }).send(:build_kwargs)[:pattern]).to eq("naïve")
    end

    it "transcodes a value tagged with a non-UTF-8 locale encoding" do
      latin1 = "naïve".encode(Encoding::ISO_8859_1)

      expect(described_class.new("search_code", [ "--pattern", latin1 ]).send(:build_kwargs)[:pattern]).to eq("naïve")
    end

    it "replaces bytes that are not UTF-8 instead of failing" do
      [ "na\xFFve".b, (+"na\xFFve").force_encoding(Encoding::UTF_8) ].each do |raw|
        expect(described_class.new("search_code", [ "--pattern", raw ]).send(:build_kwargs)[:pattern]).to be_valid_encoding
      end
    end

    it "answers search_code with the pattern" do
      output = described_class.new("search_code", [ "--pattern", "naïve".b ]).run

      expect(output).to include("naïve")
      expect(output).not_to include("CompatibilityError")
    end
  end
end
