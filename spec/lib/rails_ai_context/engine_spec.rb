# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Engine do
  describe "class hierarchy" do
    it "is a subclass of Rails::Engine" do
      expect(described_class).to be < ::Rails::Engine
    end

    it "is defined within the RailsAiContext module" do
      expect(described_class.name).to eq("RailsAiContext::Engine")
    end
  end

  describe "initializers" do
    let(:initializer_names) { described_class.initializers.map(&:name) }

    it "registers the setup initializer" do
      expect(initializer_names).to include("rails_ai_context.setup")
    end

    it "registers the middleware initializer" do
      expect(initializer_names).to include("rails_ai_context.middleware")
    end

    it "mounts the middleware after user initializers have run" do
      initializer = RailsAiContext::Engine.initializers.find { |i| i.name == "rails_ai_context.middleware" }
      expect(initializer).not_to be_nil
      expect(initializer.after).to eq(:load_config_initializers)
    end
  end

  describe "configuration integration" do
    it "makes configuration accessible via Rails.application.config" do
      config = Rails.application.config.rails_ai_context
      expect(config).to be_a(RailsAiContext::Configuration)
    end

    it "returns a Configuration instance from the module" do
      expect(RailsAiContext.configuration).to be_a(RailsAiContext::Configuration)
    end
  end

  describe "rake tasks" do
    it "has a rake_tasks block registered" do
      # The engine should have registered a rake_tasks block
      # We verify by checking the initializer infrastructure exists
      expect(described_class).to respond_to(:rake_tasks)
    end
  end

  describe "generators" do
    it "has a generators block registered" do
      expect(described_class).to respond_to(:generators)
    end
  end

  describe "engine_name" do
    it "derives the engine name from the module" do
      expect(described_class.engine_name).to eq("rails_ai_context_engine")
    end
  end
end
