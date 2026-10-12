# frozen_string_literal: true

require "spec_helper"

# rails_get_config answers one config section per call, and the ten tools
# that each answered one section leave tools/list.
RSpec.describe "rails_get_config sections" do
  let(:retired) do
    {
      "gems" => RailsAiContext::Tools::GetGems,
      "frontend" => RailsAiContext::Tools::GetFrontendStack,
      "api" => RailsAiContext::Tools::GetApi,
      "engines" => RailsAiContext::Tools::GetEngines,
      "conventions" => RailsAiContext::Tools::GetConventions,
      "autoload" => RailsAiContext::Tools::GetAutoload,
      "active_support" => RailsAiContext::Tools::GetActiveSupport,
      "env" => RailsAiContext::Tools::GetEnv,
      "env_config" => RailsAiContext::Tools::GetEnvConfig,
      "i18n" => RailsAiContext::Tools::GetI18n
    }
  end

  around do |example|
    saved = RailsAiContext.configuration.skip_tools
    example.run
  ensure
    RailsAiContext.configuration.skip_tools = saved
  end

  def text(response)
    response.content.first[:text]
  end

  describe "tools/list" do
    it "serves 35 tools, rails_get_config among them and none of the ten section tools" do
      names = RailsAiContext::Server.new(Rails.application).build.tools.keys

      expect(names.size).to eq(35)
      expect(names).to include("rails_get_config")
      expect(names & retired.values.map(&:tool_name)).to be_empty
    end

    it "keeps the ten classes callable from Ruby, out of the registry" do
      retired.each_value do |tool|
        expect(tool).to be_abstract
        expect(tool.call).to be_a(MCP::Tool::Response)
      end
    end
  end

  describe "parameters" do
    it "names a parameter the asked section does not read" do
      answer = text(RailsAiContext::Tools::GetConfig.call(section: "engines", locale: "fr", limit: 3))

      expect(answer).to end_with("_The `engines` section does not read `limit`, `locale`, so they were ignored._")
      expect(text(RailsAiContext::Tools::GetConfig.call(detail: "full"))).to end_with(
        "_The `app` section does not read `detail`, so it was ignored._"
      )
    end

    it "says nothing about a parameter the section reads" do
      expect(text(RailsAiContext::Tools::GetConfig.call(section: "i18n", locale: "en"))).not_to include("does not read")
    end

    it "refuses a section it does not have, naming the ones it has" do
      response = RailsAiContext::Tools::GetConfig.call(section: "routes")

      expect(response.error?).to be(true)
      expect(text(response)).to start_with("`section` does not take 'routes'. It takes: app, gems, frontend,")
    end
  end

  describe "skip_tools" do
    let(:config) { RailsAiContext.configuration }
    let(:all_eleven) { RailsAiContext::Tools::GetConfig::SECTIONS.map(&:tool_name) }

    def served_names
      RailsAiContext::Server.new(Rails.application).build.tools.keys
    end

    it "offers no section it turned off, in the published definition or the guide" do
      config.skip_tools = %w[rails_get_env rails_get_gems]

      definition = RailsAiContext::Server.new(Rails.application).build.tools.fetch("rails_get_config").to_h
      enum = definition.dig(:inputSchema, :properties, :section, :enum)
      expect(enum).to include("app", "i18n")
      expect(enum).not_to include("env", "gems")
      expect(definition[:description]).not_to match(/\b(env|gems)\b/)
      expect(definition[:description]).to include("i18n")
      expect(definition.dig(:inputSchema, :properties)).not_to have_key(:category)
      expect(JSON.generate(definition[:inputSchema])).not_to match(/\b(env|gems)\b/)

      row = RailsAiContext::Tools::GetConfig.guide_row
      expect(row.summary).not_to match(/\b(env|gems)\b/)
      expect(row.summary).to include("env_config")
    end

    it "still answers an off section with the turned-off message, also with a parameter only that section reads" do
      config.skip_tools = %w[rails_get_gems]
      result = RailsAiContext::Server.new(Rails.application).build.handle(
        { jsonrpc: "2.0", id: 1, method: "tools/call",
          params: { name: "rails_get_config", arguments: { section: "gems", category: "auth" } } }
      )[:result]

      expect(result[:isError]).to be(true)
      expect(result[:content].first[:text]).to start_with("The `gems` section of rails_get_config is turned off")
    end

    it "keeps the env section off when it names rails_get_env, and the rest on" do
      config.skip_tools = %w[rails_get_env]

      response = RailsAiContext::Tools::GetConfig.call(section: "env")
      expect(response.error?).to be(true)
      expect(text(response)).to start_with("The `env` section of rails_get_config is turned off in this app: skip_tools lists rails_get_env")
      expect(RailsAiContext::Tools::GetConfig.call(section: "i18n").error?).to be(false)
      expect(served_names).to include("rails_get_config")
      expect(RailsAiContext::Server.served?("rails_get_env")).to be(false)
      expect(RailsAiContext::Server.served?("rails_get_i18n")).to be(true)
    end

    it "turns off only the app section when it names rails_get_config" do
      config.skip_tools = %w[rails_get_config]

      expect(served_names).to include("rails_get_config")
      expect(RailsAiContext::Tools::GetConfig.call.error?).to be(true)
      expect(text(RailsAiContext::Tools::GetConfig.call(section: "gems"))).not_to include("turned off")
      expect(RailsAiContext::Server.skipped_tools).to be_empty
    end

    it "takes the tool out of tools/list when it names all eleven" do
      config.skip_tools = all_eleven

      expect(served_names).not_to include("rails_get_config")
      expect(RailsAiContext::Server.served?("rails_get_config")).to be(false)
      expect(RailsAiContext::Server.skipped_tools).to match_array(all_eleven)
    end
  end

  describe "a retired name over MCP" do
    def call(name, arguments = {})
      RailsAiContext::Server.new(Rails.application).build.handle(
        { jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: name, arguments: arguments } }
      )[:result]
    end

    it "is answered from its section, with the new call named" do
      result = call("rails_get_i18n", { locale: "en" })
      section = text(RailsAiContext::Tools::GetConfig.call(section: "i18n", locale: "en"))

      expect(result[:isError]).to be(false)
      expect(result[:content].first[:text]).to eq(
        "#{section}\n\n_rails_get_i18n is now `rails_get_config(section:\"i18n\", locale:\"en\")`; call that instead._"
      )
    end

    it "says the section is off when skip_tools lists the retired name" do
      RailsAiContext.configuration.skip_tools = %w[rails_get_env]
      result = call("rails_get_env")

      expect(result[:isError]).to be(true)
      expect(result[:content].first[:text]).to start_with("rails_get_env is turned off in this app")
    end
  end

  describe "the pointer helper" do
    it "renders a retired name as its section call, and nothing when the section is off" do
      expect(RailsAiContext::Tools::BaseTool.pointer("rails_get_env_config", 'environment:"..."', "shows options."))
        .to eq('`rails_get_config(section:"env_config", environment:"...")` shows options.')
      expect(RailsAiContext::Tools::BaseTool.pointer("rails_get_gems")).to eq('`rails_get_config(section:"gems")`')

      RailsAiContext.configuration.skip_tools = %w[rails_get_gems rails_get_config]
      expect(RailsAiContext::Tools::BaseTool.pointer("rails_get_gems")).to be_nil
      expect(RailsAiContext::Tools::BaseTool.pointer("rails_get_config")).to be_nil
    end

    it "renders a section call when only the app section is off" do
      RailsAiContext.configuration.skip_tools = %w[rails_get_config]

      expect(RailsAiContext::Tools::BaseTool.pointer("rails_get_gems")).to eq('`rails_get_config(section:"gems")`')
      expect(RailsAiContext::Tools::BaseTool.pointer("rails_get_config")).to be_nil
    end
  end

  describe "with the app section off" do
    before { RailsAiContext.configuration.skip_tools = %w[rails_get_config] }

    it "publishes section as required, with no default named" do
      definition = RailsAiContext::Server.new(Rails.application).build.tools.fetch("rails_get_config").to_h

      expect(definition.dig(:inputSchema, :required)).to eq([ "section" ])
      expect(definition.dig(:inputSchema, :properties, :section, :description)).not_to include("Default")
      expect(definition[:description]).to include("section (required): gems (")
    end

    it "answers a call with no section by naming the sections it takes" do
      response = RailsAiContext::Tools::GetConfig.call

      expect(response.error?).to be(true)
      expect(text(response)).to start_with("`section` is required in this app").and include("It takes: gems, frontend,")
    end

    it "shows a call that answers in the guide row" do
      row = RailsAiContext::Tools::GetConfig.guide_row

      expect(row.mcp).to eq('rails_get_config(section:"gems")')
      expect(row.cli_args).to eq("section=gems")
      expect(RailsAiContext::Tools::GetConfig.call(section: "gems").error?).to be(false)
    end
  end

  describe "a custom tool named rails_get_config, with skip_tools listing the name" do
    let(:custom) do
      Class.new(MCP::Tool) do
        tool_name "rails_get_config"
        description "The app's own config tool."
        def self.call(server_context: nil, **)
          MCP::Tool::Response.new([ { type: "text", text: "custom config" } ])
        end
      end
    end

    around do |example|
      saved = RailsAiContext.configuration.custom_tools
      RailsAiContext.configuration.custom_tools = [ custom ]
      RailsAiContext.configuration.skip_tools = %w[rails_get_config]
      example.run
    ensure
      RailsAiContext.configuration.custom_tools = saved
    end

    def call(name, arguments = {})
      RailsAiContext::Server.new(Rails.application).build.handle(
        { jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: name, arguments: arguments } }
      )
    end

    it "serves the custom tool in the built-in's place, with no warning" do
      server = nil
      expect { server = RailsAiContext::Server.new(Rails.application).build }.not_to output.to_stderr

      expect(server.tools.fetch("rails_get_config")).to equal(custom)
      expect(RailsAiContext::Server.exposed_tools).to include(custom)
      expect(RailsAiContext::Server.exposed_tools).not_to include(RailsAiContext::Tools::GetConfig)
      expect(call("rails_get_config")[:result][:content].first[:text]).to eq("custom config")
    end

    it "answers a retired name as an unknown tool, on both surfaces" do
      allow($stderr).to receive(:puts)

      expect(call("rails_get_gems")[:error][:message]).to start_with("Tool not found: rails_get_gems.")
      expect { RailsAiContext::CLI::ToolRunner.new("gems", []) }
        .to raise_error(RailsAiContext::CLI::ToolRunner::ToolNotFoundError, /Unknown tool 'gems'/)
    end

    it "points no hint at a section, and leaves a config include out" do
      expect(RailsAiContext::Tools::BaseTool.pointer("rails_get_gems")).to be_nil
      expect(custom).not_to receive(:call)

      answer = text(RailsAiContext::Tools::GetContext.call(model: "Post", include: %w[gems]))
      expect(answer).to include(RailsAiContext::Server.skipped_tool_message("rails_get_config"))
    end
  end

  describe "the line a retired name's answer ends with" do
    it "names only the parameters the section reads" do
      result = RailsAiContext::Server.new(Rails.application).build.handle(
        { jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "rails_get_engines", arguments: { limit: 3 } } }
      )[:result]

      expect(result[:content].first[:text]).to end_with('_rails_get_engines is now `rails_get_config(section:"engines")`; call that instead._')
    end

    it "is the command under tool_mode :cli" do
      allow(RailsAiContext.configuration).to receive(:tool_mode).and_return(:cli)

      answer = RailsAiContext::CLI::ToolRunner.new("i18n", [ "--locale", "en" ]).run
      command = RailsAiContext::InstallMode.tool_command("config")

      expect(answer).to end_with("_rails_get_i18n is now `#{command} section=i18n locale=en`; call that instead._")
    end
  end

  describe "the session record" do
    before { RailsAiContext::Tools::BaseTool.session_reset! }

    def status
      text(RailsAiContext::Tools::SessionContext.call(action: "status"))
    end

    it "names rails_get_config with its section for a section call and for a retired name" do
      server = RailsAiContext::Server.new(Rails.application).build
      server.handle({ jsonrpc: "2.0", id: 1, method: "tools/call",
                      params: { name: "rails_get_config", arguments: { section: "gems" } } })
      server.handle({ jsonrpc: "2.0", id: 2, method: "tools/call", params: { name: "rails_get_i18n", arguments: {} } })
      RailsAiContext::CLI::ToolRunner.new("engines", []).run

      expect(status).to include("section:gems", "section:i18n", "section:engines")
      expect(status).not_to match(/rails_get_(gems|i18n|engines)/)
    end
  end

  # Each section through tools/call, under its section and under its retired
  # name, with the parameters the retired tool took and a fact of the app it reads.
  describe "each section through the server" do
    def answer(name, arguments)
      result = RailsAiContext::Server.new(Rails.application).build.handle(
        { jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: name, arguments: arguments } }
      )[:result]
      expect(result[:isError]).to be(false), "#{name} #{arguments.inspect}: #{result[:content].first[:text]}"
      result[:content].first[:text]
    end

    def expect_facts(rows)
      rows.each do |section, arguments, *facts|
        retired = RailsAiContext::Tools::GetConfig.section_named(section).tool_name
        [ answer("rails_get_config", arguments.merge(section: section)), answer(retired, arguments) ].each do |text|
          expect(text).to include(*facts), "section #{section} with #{arguments.inspect}"
        end
        expect(answer(retired, arguments)).to include("_#{retired} is now `rails_get_config(section:\"#{section}\"")
      end
    end

    it "answers from the booted app" do
      expect_facts([
        [ "frontend", { detail: "summary" }, "React 19.0.0 + Inertia + TypeScript + Zustand" ],
        [ "frontend", { detail: "full" }, "## TypeScript Path Aliases", "`@components/*`" ],
        [ "api", { detail: "full" }, "- **Versioning:** v1 (app/controllers/api/v1)", "## OpenAPI Specs" ],
        [ "engines", {}, "_Nothing mounted in config/routes.rb._" ],
        [ "conventions", {}, "- ViewComponent (app/components/)" ],
        [ "autoload", {}, "- **Mode:** zeitwerk", "- `app/components`" ],
        [ "active_support", {}, "## Subscribed on_load Hooks", "- `active_record` - " ],
        [ "env_config", { environment: "production" }, "Environment 'production' not found." ],
        [ "env_config", { offset: 1, limit: 1 }, "_Current: **test** - 0 environment files under config/environments/_" ],
        [ "i18n", { locale: "fr" }, "Locale 'fr' not found.\nAvailable: en" ],
        [ "i18n", { offset: 0, limit: 1 }, "- **Default locale:** en", "- `en.yml` - 3 keys" ]
      ])
    end

    context "on the static tier" do
      around do |example|
        saved_root = RailsAiContext.configuration.app_root
        RailsAiContext.tier = :static
        RailsAiContext.configuration.app_root = IntrospectedFixture::ROOT
        RailsAiContext::Tools::BaseTool.reset_cache!
        example.run
      ensure
        RailsAiContext.tier = nil
        RailsAiContext.configuration.app_root = saved_root
        RailsAiContext::Tools::BaseTool.reset_cache!
      end

      it "answers from the app's files" do
        expect_facts([
          [ "gems", {}, "- **devise** `4.9.4`", "- **pg** `1.5.9`" ],
          [ "gems", { category: "auth" }, "- **pundit** `2.4.0`" ],
          [ "gems", { offset: 1, limit: 2 }, "- **pg** `1.5.9`", "_Showing 2-3 of 9. Use offset:3 for next page._" ],
          [ "env", { detail: "summary" }, "**External services:** 1" ],
          [ "env", { detail: "full" }, "- **Sidekiq (Redis)**", "  - Gem: `sidekiq`" ],
          [ "frontend", { detail: "full" }, "- **Stimulus controllers:** 3 (hello, search, tabs)" ]
        ])
        expect(answer("rails_get_config", { section: "gems", category: "auth" })).not_to include("**pg**")
      end
    end
  end
end
