# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext do
  describe "tier state" do
    after do
      RailsAiContext.tier = :runtime
      RailsAiContext.static_reason = nil
    end

    it "defaults to :runtime" do
      expect(RailsAiContext.tier).to eq(:runtime)
      expect(RailsAiContext.static_tier?).to be(false)
    end

    it "records the static tier and reason" do
      RailsAiContext.tier = :static
      RailsAiContext.static_reason = "RuntimeError: FATAL_ENV_MISSING"
      expect(RailsAiContext.static_tier?).to be(true)
      expect(RailsAiContext.static_reason).to eq("RuntimeError: FATAL_ENV_MISSING")
    end

    it "builds a StaticApp from configuration.app_root in static tier" do
      RailsAiContext.tier = :static
      RailsAiContext.configuration.app_root = "/tmp/static_root"
      app = RailsAiContext.send(:default_app)
      expect(app).to be_a(RailsAiContext::StaticApp)
      expect(app.root.to_s).to eq("/tmp/static_root")
    ensure
      RailsAiContext.configuration.app_root = nil
    end

    it "returns Rails.application in runtime tier" do
      expect(RailsAiContext.send(:default_app)).to eq(Rails.application)
    end
  end
end
