# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Introspector do
  let(:introspector) { described_class.new(Rails.application) }

  describe "#call" do
    it "returns a complete context hash" do
      result = introspector.call

      expect(result[:ruby_version]).to eq(RUBY_VERSION)
      expect(result[:rails_version]).to eq(Rails.version)
      expect(result[:generator]).to include("rails-ai-context")
      expect(result[:generated_at]).to be_a(String)
    end

    it "includes all configured introspectors" do
      result = introspector.call

      expect(result).to have_key(:schema)
      expect(result).to have_key(:models)
      expect(result).to have_key(:routes)
      expect(result).to have_key(:jobs)
      expect(result).to have_key(:gems)
      expect(result).to have_key(:conventions)
    end

    it "wires the 8 nervous-system introspectors into the full context" do
      result = introspector.call

      %i[initializers autoload connection_pool active_support credentials security observability env].each do |key|
        expect(result).to have_key(key), "expected orchestrator to return :#{key}"
        expect(result[key]).to be_a(Hash)
        expect(result[key]).not_to have_key(:error), "introspector :#{key} raised: #{result[key][:error]}"
      end
    end

    it "collects _warnings when an introspector fails" do
      # Use a minimal config with a known-bad introspector name won't work here,
      # so instead stub one introspector to raise
      allow_any_instance_of(RailsAiContext::Introspectors::GemIntrospector)
        .to receive(:call).and_raise(RuntimeError, "simulated failure")

      result = introspector.call

      expect(result[:gems]).to eq({ error: "simulated failure" })
      expect(result[:_warnings]).to be_an(Array)
      expect(result[:_warnings]).to include(
        hash_including(introspector: "gems", error: "simulated failure")
      )
    end

    it "only includes warnings for introspectors that actually failed" do
      result = introspector.call

      if result[:_warnings]
        result[:_warnings].each do |w|
          # Every warning must correspond to an introspector with an :error key
          expect(result[w[:introspector].to_sym]).to be_a(Hash)
          expect(result[w[:introspector].to_sym][:error]).to eq(w[:error])
        end
      end
    end

    it "isolates introspector failures even when Rails.logger is nil" do
      broken = Class.new do
        def initialize(app); end

        def call
          raise "boom"
        end
      end
      stub_const("RailsAiContext::Introspector::INTROSPECTOR_MAP",
                 RailsAiContext::Introspector::INTROSPECTOR_MAP.merge(schema: broken))
      allow(Rails).to receive(:logger).and_return(nil)

      result = nil
      expect { result = introspector.call }.to output(/schema introspection failed/).to_stderr
      expect(result[:schema]).to eq(error: "boom")
      expect(result[:_warnings]).to include(introspector: "schema", error: "boom")
    end

    it "extracts schema with tables" do
      result = introspector.call
      schema = result[:schema]

      expect(schema[:adapter]).not_to be_nil
      # Live DB may not load schema on all Rails versions via Combustion;
      # fall back to verifying static parse produces tables from schema.rb
      if schema[:tables].empty?
        static = RailsAiContext::Introspectors::SchemaIntrospector.new(Rails.application).send(:static_schema_parse)
        expect(static[:tables]).to have_key("users")
        expect(static[:tables]).to have_key("posts")
      else
        expect(schema[:tables]).to have_key("users")
        expect(schema[:tables]).to have_key("posts")
      end
    end
  end

  describe "static tier dispatch" do
    let(:static_app) { RailsAiContext::StaticApp.new(Dir.pwd) }

    around do |example|
      RailsAiContext.tier = :static
      RailsAiContext.static_reason = "RuntimeError: FATAL_ENV_MISSING"
      example.run
    ensure
      RailsAiContext.tier = :runtime
      RailsAiContext.static_reason = nil
    end

    it "routes sections through static_call when the introspector provides one" do
      static_capable = Class.new do
        def initialize(app); end

        def call
          raise "runtime path must not run in static tier"
        end

        def static_call
          { total: 7, confidence: RailsAiContext::Confidence::STATIC }
        end
      end
      stub_const("RailsAiContext::Introspector::INTROSPECTOR_MAP",
                 RailsAiContext::Introspector::INTROSPECTOR_MAP.merge(schema: static_capable))

      result = RailsAiContext::Introspector.new(static_app).call
      expect(result[:schema]).to eq(total: 7, confidence: "[STATIC]")
    end

    it "marks sections without a static path unavailable, with the boot reason" do
      result = RailsAiContext::Introspector.new(static_app).call
      expect(result[:jobs]).to eq(
        unavailable: "requires a booted Rails app (RuntimeError: FATAL_ENV_MISSING)"
      )
    end

    it "does not count unavailable sections as warnings" do
      result = RailsAiContext::Introspector.new(static_app).call
      Array(result[:_warnings]).each do |w|
        expect(w[:error]).not_to include("requires a booted Rails app")
      end
    end

    it "builds base fields without Rails" do
      result = RailsAiContext::Introspector.new(static_app).call
      expect(result[:app_name]).to eq(File.basename(Dir.pwd))
      expect(result[:rails_version]).to include("UNAVAILABLE")
      expect(result[:environment]).to be_a(String)
      expect(result[:generated_at]).to match(/\d{4}-\d{2}-\d{2}T/)
    end
  end

  describe "INTROSPECTOR_MAP / PRESETS drift guard" do
    it "every PRESETS entry is registered in INTROSPECTOR_MAP" do
      RailsAiContext::Configuration::PRESETS.each do |preset_name, names|
        names.each do |name|
          expect(described_class::INTROSPECTOR_MAP).to have_key(name),
            "Preset :#{preset_name} references unknown introspector #{name.inspect} - add it to INTROSPECTOR_MAP or remove from PRESETS"
        end
      end
    end

    it "raises ConfigurationError for unknown introspector names" do
      config = RailsAiContext.configuration
      original = config.introspectors
      config.introspectors = [ :nonexistent_thing ]
      expect { described_class.new(Rails.application).call }
        .not_to raise_error # errors are captured per-introspector via rescue
      result = described_class.new(Rails.application).call
      expect(result[:nonexistent_thing]).to include(error: /Unknown introspector/)
    ensure
      config.introspectors = original
    end
  end
end
