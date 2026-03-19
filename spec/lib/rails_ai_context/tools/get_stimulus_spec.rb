# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Tools::GetStimulus do
  before { described_class.reset_cache! }

  let(:stimulus_data) do
    {
      controllers: [
        { name: "hello", targets: %w[name output], actions: %w[greet], values: { "name" => "String" }, outlets: [], classes: [], file: "hello_controller.js" },
        { name: "search", targets: %w[input results], actions: %w[search clear], values: {}, outlets: %w[hello], classes: %w[active], file: "search_controller.js" }
      ]
    }
  end

  before do
    allow(described_class).to receive(:cached_context).and_return({ stimulus: stimulus_data })
  end

  describe ".call" do
    it "lists controllers with counts for detail:summary" do
      result = described_class.call(detail: "summary")
      text = result.content.first[:text]
      expect(text).to include("**hello** — 2 targets, 1 actions")
      expect(text).to include("**search** — 2 targets, 2 actions")
    end

    it "lists controllers with targets and actions for detail:standard" do
      result = described_class.call(detail: "standard")
      text = result.content.first[:text]
      expect(text).to include("## hello")
      expect(text).to include("Targets: name, output")
      expect(text).to include("Actions: greet")
    end

    it "shows everything for detail:full" do
      result = described_class.call(detail: "full")
      text = result.content.first[:text]
      expect(text).to include("**Values:** name:String")
      expect(text).to include("**Outlets:** hello")
      expect(text).to include("**Classes:** active")
    end

    it "returns full detail for specific controller" do
      result = described_class.call(controller: "hello")
      text = result.content.first[:text]
      expect(text).to include("## hello")
      expect(text).to include("**Targets:**")
      expect(text).to include("**File:** hello_controller.js")
    end

    it "supports case-insensitive lookup" do
      result = described_class.call(controller: "HELLO")
      text = result.content.first[:text]
      expect(text).to include("## hello")
    end

    it "handles missing controller" do
      result = described_class.call(controller: "nonexistent")
      text = result.content.first[:text]
      expect(text).to include("not found")
      expect(text).to include("hello, search")
    end

    it "handles missing stimulus data" do
      allow(described_class).to receive(:cached_context).and_return({})
      result = described_class.call
      text = result.content.first[:text]
      expect(text).to include("not available")
    end

    it "handles empty controllers" do
      allow(described_class).to receive(:cached_context).and_return({ stimulus: { controllers: [] } })
      result = described_class.call
      text = result.content.first[:text]
      expect(text).to include("No Stimulus controllers")
    end
  end
end
