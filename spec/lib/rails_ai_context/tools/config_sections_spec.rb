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
    let(:all_eleven) { RailsAiContext::Tools::GetConfig::SECTIONS.values }

    def served_names
      RailsAiContext::Server.new(Rails.application).build.tools.keys
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
  end

  # The parameters each retired tool took, and a call with them.
  let(:calls) do
    {
      "gems" => [ {}, { category: "auth" }, { offset: 1, limit: 2 } ],
      "frontend" => [ {}, { detail: "summary" }, { detail: "full" } ],
      "api" => [ {}, { detail: "full" } ],
      "engines" => [ {} ],
      "conventions" => [ {} ],
      "autoload" => [ {} ],
      "active_support" => [ {} ],
      "env" => [ {}, { detail: "summary" }, { detail: "full" } ],
      "env_config" => [ {}, { environment: "production" }, { offset: 1, limit: 1 } ],
      "i18n" => [ {}, { locale: "fr" }, { offset: 0, limit: 1 } ]
    }
  end

  shared_examples "answers each section as its retired tool did" do
    it "matches the retired tool's answer for the same parameters" do
      calls.each do |section, param_sets|
        param_sets.each do |params|
          RailsAiContext::Tools::BaseTool.reset_cache!
          expected = text(retired.fetch(section).call(**params))
          RailsAiContext::Tools::BaseTool.reset_cache!
          actual = text(RailsAiContext::Tools::GetConfig.call(section: section, **params))

          expect(actual).to eq(expected), "section #{section} with #{params.inspect}"
        end
      end
    end
  end

  context "on the booted tier" do
    include_examples "answers each section as its retired tool did"
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

    include_examples "answers each section as its retired tool did"
  end
end
