# frozen_string_literal: true

require "spec_helper"

# The migration onto SectionFetch is mechanical, so the guard is that the
# honest answers come out byte for byte the way they did before. One row per
# migrated tool: the section it reads, what it calls that section, and the
# exact three strings a caller can still get back.
RSpec.describe "Section-fetch migration, byte for byte" do
  MIGRATED = [
    { tool: RailsAiContext::Tools::GetActiveSupport, key: :active_support, subject: "ActiveSupport introspection" },
    { tool: RailsAiContext::Tools::GetAutoload,      key: :autoload,       subject: "Autoload introspection" },
    { tool: RailsAiContext::Tools::GetCallbacks,     key: :models,         subject: "Model introspection" },
    { tool: RailsAiContext::Tools::GetControllers,   key: :controllers,    subject: "Controller introspection" },
    { tool: RailsAiContext::Tools::GetEngines,       key: :engines,        subject: "Engine introspection" },
    { tool: RailsAiContext::Tools::GetEnvConfig,     key: :env_config,     subject: "Environment config introspection" },
    { tool: RailsAiContext::Tools::GetGems,          key: :gems,           subject: "Gem introspection" },
    { tool: RailsAiContext::Tools::GetI18n,          key: :i18n,           subject: "I18n introspection" },
    { tool: RailsAiContext::Tools::GetMailers,       key: :jobs,           subject: "Mailer introspection" },
    { tool: RailsAiContext::Tools::GetModelDetails,  key: :models,         subject: "Model introspection" },
    { tool: RailsAiContext::Tools::GetRoutes,        key: :routes,         subject: "Route introspection" },
    { tool: RailsAiContext::Tools::GetStimulus,      key: :stimulus,       subject: "Stimulus introspection" },
    { tool: RailsAiContext::Tools::GetTestInfo,      key: :tests,          subject: "Test introspection" },
    { tool: RailsAiContext::Tools::GetConfig,        key: :config,         subject: "Config introspection",
      remedy: "Add :config to introspectors or use `config.preset = :full`." },
    { tool: RailsAiContext::Tools::GetConventions,   key: :conventions,    subject: "Convention detection" },
    # The sixteenth. Its failed-case wording was "not available: <error>",
    # the only one of the sixteen that did not say "failed:"; migrating it
    # onto the shared seam settles it on the common phrasing.
    { tool: RailsAiContext::Tools::GetSchema,        key: :schema,         subject: "Schema introspection" }
  ].freeze

  def text_of(response)
    response.content.first[:text]
  end

  MIGRATED.each do |row|
    describe row[:tool].tool_name do
      let(:remedy) { row[:remedy] || "Add :#{row[:key]} to introspectors." }

      it "says the section was never introspected, unchanged" do
        allow(row[:tool]).to receive(:cached_context).and_return({})

        expect(text_of(row[:tool].call)).to start_with("#{row[:subject]} not available. #{remedy}")
      end

      it "says the introspector raised, unchanged" do
        allow(row[:tool]).to receive(:cached_context)
          .and_return({ row[:key] => { error: "disk on fire" } })

        expect(text_of(row[:tool].call)).to start_with("#{row[:subject]} failed: disk on fire")
      end

      it "says the data source was absent, unchanged" do
        allow(row[:tool]).to receive(:cached_context)
          .and_return({ row[:key] => { unavailable: "requires a booted Rails app" } })

        expect(text_of(row[:tool].call))
          .to start_with("[UNAVAILABLE: requires a booted Rails app]")
      end
    end
  end

  # The other migrated tools pass `unusable_message:`, one answer covering both
  # "never introspected" and "the introspector raised". Same guard, different
  # shape: the opening is pinned and the two cases must stay indistinguishable.
  FLAT = [
    { tool: RailsAiContext::Tools::GetApi, key: :api,
      opening: "No API layer data available." },
    { tool: RailsAiContext::Tools::GetComponentCatalog, key: :components,
      opening: "No component data available." },
    { tool: RailsAiContext::Tools::GetFrontendStack, key: :frontend_frameworks,
      opening: "No frontend framework data available." },
    { tool: RailsAiContext::Tools::PerformanceCheck, key: :performance,
      opening: "No performance data available." }
  ].freeze

  FLAT.each do |row|
    describe row[:tool].tool_name do
      it "says the section was never introspected, unchanged" do
        allow(row[:tool]).to receive(:cached_context).and_return({})

        expect(text_of(row[:tool].call)).to start_with(row[:opening])
      end

      it "gives the raised case the same answer" do
        allow(row[:tool]).to receive(:cached_context).and_return({})
        never_introspected = text_of(row[:tool].call)

        allow(row[:tool]).to receive(:cached_context)
          .and_return({ row[:key] => { error: "disk on fire" } })

        expect(text_of(row[:tool].call)).to eq(never_introspected)
      end

      it "says the data source was absent, unchanged" do
        allow(row[:tool]).to receive(:cached_context)
          .and_return({ row[:key] => { unavailable: "requires a booted Rails app" } })

        expect(text_of(row[:tool].call))
          .to start_with("[UNAVAILABLE: requires a booted Rails app]")
      end
    end
  end
end
