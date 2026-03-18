# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Configuration do
  let(:config) { described_class.new }

  it "has sensible defaults" do
    expect(config.server_name).to eq("rails-ai-context")
    expect(config.http_port).to eq(6029)
    expect(config.http_bind).to eq("127.0.0.1")
    expect(config.auto_mount).to eq(false)
    expect(config.cache_ttl).to eq(30)
  end

  it "defaults to standard preset" do
    expect(config.introspectors).to eq(described_class::PRESETS[:standard])
  end

  it "excludes internal Rails models by default" do
    expect(config.excluded_models).to include("ApplicationRecord")
    expect(config.excluded_models).to include("ActiveStorage::Blob")
  end

  it "is configurable" do
    config.server_name = "my-app"
    config.http_port = 8080
    config.auto_mount = true

    expect(config.server_name).to eq("my-app")
    expect(config.http_port).to eq(8080)
    expect(config.auto_mount).to eq(true)
  end

  describe "#preset=" do
    it "sets introspectors to standard preset" do
      config.preset = :standard
      expect(config.introspectors).to eq(%i[schema models routes jobs gems conventions controllers tests])
    end

    it "sets introspectors to full preset" do
      config.preset = :full
      expect(config.introspectors.size).to eq(21)
      expect(config.introspectors).to include(:stimulus, :views, :turbo, :auth, :api, :devops)
    end

    it "accepts string preset names" do
      config.preset = "full"
      expect(config.introspectors.size).to eq(21)
    end

    it "raises on unknown preset" do
      expect { config.preset = :unknown }.to raise_error(ArgumentError, /Unknown preset/)
    end

    it "allows adding introspectors after preset" do
      config.preset = :standard
      config.introspectors += %i[views turbo]
      expect(config.introspectors).to include(:views, :turbo)
      expect(config.introspectors.size).to eq(10)
    end
  end

  describe RailsAiContext do
    it "supports block configuration" do
      RailsAiContext.configure do |c|
        c.server_name = "test-app"
      end

      expect(RailsAiContext.configuration.server_name).to eq("test-app")
    ensure
      # Reset
      RailsAiContext.configuration = RailsAiContext::Configuration.new
    end
  end
end
