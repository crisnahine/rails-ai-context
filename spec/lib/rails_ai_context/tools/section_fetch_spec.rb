# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Tools::SectionFetch do
  let(:tool) do
    Class.new(RailsAiContext::Tools::BaseTool) do
      tool_name "rails_spec_section"
      description "probe"
      input_schema(properties: {})
    end
  end

  after { tool.abstract! }

  def stub_section(value)
    allow(tool).to receive(:cached_context).and_return(value.nil? ? {} : { gems: value })
  end

  def text_of(response)
    response.content.first[:text]
  end

  describe "#fetch_section" do
    it "hands the section to the block when it is usable" do
      stub_section(total_gems: 3)

      result = tool.fetch_section(:gems, subject: "Gem introspection") { |data| data[:total_gems] }

      expect(result).to eq(3)
    end

    it "answers honestly when the section was never introspected" do
      stub_section(nil)

      result = tool.fetch_section(:gems, subject: "Gem introspection") { raise "must not run" }

      expect(text_of(result)).to eq("Gem introspection not available. Add :gems to introspectors.")
    end

    it "carries a custom remedy into the not-available answer" do
      stub_section(nil)

      result = tool.fetch_section(:gems, subject: "Gem introspection",
                                         remedy: "Add :gems to introspectors or use `config.preset = :full`.") { raise "must not run" }

      expect(text_of(result))
        .to eq("Gem introspection not available. Add :gems to introspectors or use `config.preset = :full`.")
    end

    it "answers honestly when the introspector raised" do
      stub_section(error: "Gemfile.lock unreadable")

      result = tool.fetch_section(:gems, subject: "Gem introspection") { raise "must not run" }

      expect(text_of(result)).to eq("Gem introspection failed: Gemfile.lock unreadable")
    end

    it "answers honestly when the data source was absent" do
      stub_section(unavailable: "requires a booted Rails app")

      result = tool.fetch_section(:gems, subject: "Gem introspection") { raise "must not run" }

      expect(text_of(result)).to eq("[UNAVAILABLE: requires a booted Rails app]")
    end

    it "refuses a runtime-only section in the static tier without consulting the data" do
      allow(RailsAiContext).to receive(:static_tier?).and_return(true)
      allow(RailsAiContext).to receive(:static_reason).and_return("RuntimeError: boom")
      allow(tool).to receive(:cached_context).and_return({ config: { some: "leftovers" } })

      result = tool.fetch_section(:config, subject: "Config introspection") { raise "must not run" }

      expect(text_of(result)).to include("requires a booted Rails app")
      expect(text_of(result)).to include("RuntimeError: boom")
    end

    it "serves a files-only section in the static tier" do
      allow(RailsAiContext).to receive(:static_tier?).and_return(true)
      stub_section(total_gems: 3)

      result = tool.fetch_section(:gems, subject: "Gem introspection") { |data| data[:total_gems] }

      expect(result).to eq(3)
    end

    it "answers honestly for a view section on an API-only app" do
      allow(tool).to receive(:cached_context).and_return({ views: { layouts: [] }, api: { api_only: true } })

      result = tool.fetch_section(:views, subject: "View introspection", api_only: "views") { raise "must not run" }

      expect(text_of(result)).to include("API-only app")
    end

    it "never hands the block a hash carrying error or unavailable" do
      [ { error: "x" }, { unavailable: "y" } ].each do |bad|
        stub_section(bad)
        tool.fetch_section(:gems, subject: "Gem introspection") do |data|
          raise "leaked #{data.inspect}"
        end
      end
    end
  end
end
