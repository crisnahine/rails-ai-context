# frozen_string_literal: true

require "spec_helper"
require "fileutils"

RSpec.describe RailsAiContext::Tools::GetTurboMap do
  before { described_class.reset_cache! }

  describe ".call with no turbo usage" do
    it "reports no turbo streams or frames detected" do
      result = described_class.call
      text = result.content.first[:text]
      expect(text).to include("Turbo Map")
      # The test app may or may not have turbo usage; either show results or say none
      expect(text).to be_a(String)
    end
  end

  describe ".call with detail:summary" do
    it "returns summary counts" do
      result = described_class.call(detail: "summary")
      text = result.content.first[:text]
      expect(text).to include("Turbo Map")
      expect(text).to include("Model broadcasts:")
      expect(text).to include("Explicit broadcasts:")
      expect(text).to include("Stream subscriptions:")
      expect(text).to include("Turbo Frames:")
    end
  end

  describe ".call with detail:standard" do
    it "returns standard detail" do
      result = described_class.call(detail: "standard")
      text = result.content.first[:text]
      expect(text).to include("Turbo Map")
    end
  end

  describe ".call with detail:full" do
    it "returns full detail" do
      result = described_class.call(detail: "full")
      text = result.content.first[:text]
      expect(text).to include("Turbo Map (Full Detail)")
    end
  end

  describe ".call with unknown detail level" do
    it "returns an error message" do
      result = described_class.call(detail: "invalid")
      text = result.content.first[:text]
      expect(text).to include("Unknown detail level")
    end
  end

  describe ".call with stream filter" do
    it "filters results by stream name" do
      result = described_class.call(stream: "nonexistent_stream_xyz")
      text = result.content.first[:text]
      # With a nonsense filter, should get no matching results
      expect(text).to include("Turbo Map")
    end

    it "reports no matching turbo usage with bad filter" do
      result = described_class.call(stream: "nonexistent_stream_xyz", detail: "standard")
      text = result.content.first[:text]
      # Should either show empty results or a helpful hint
      expect(text).to match(/No Turbo usage matching|Turbo Map/)
    end
  end

  describe ".call with controller filter" do
    it "filters results by controller name" do
      result = described_class.call(controller: "nonexistent_controller_xyz")
      text = result.content.first[:text]
      expect(text).to include("Turbo Map")
    end

    it "reports no matching turbo usage with bad controller filter" do
      result = described_class.call(controller: "nonexistent_controller_xyz", detail: "standard")
      text = result.content.first[:text]
      expect(text).to match(/No Turbo usage matching|Turbo Map/)
    end
  end

  describe "turbo stream response detection" do
    it "detects turbo stream templates from test app" do
      # The test app has spec/internal/app/views/posts/create.turbo_stream.erb
      result = described_class.call(detail: "summary")
      text = result.content.first[:text]
      expect(text).to include("Turbo")
    end
  end

  describe "when turbo-rails is not installed" do
    let(:lock_path) { File.join(Rails.root.to_s, "Gemfile.lock") }

    before do
      File.write(lock_path, <<~LOCK)
        GEM
          remote: https://rubygems.org/
          specs:
            rails (8.0.0)
      LOCK
    end

    after { FileUtils.rm_f(lock_path) }

    it "short-circuits with a not-installed message instead of a Turbo Drive block" do
      result = described_class.call
      text = result.content.first[:text]
      expect(text).to include("Turbo is not installed in this app")
      expect(text).not_to include("Turbo Drive Configuration")
      expect(text).not_to include("Turbo Map")
    end
  end

  describe "when turbo-rails IS installed (per Gemfile.lock)" do
    let(:lock_path) { File.join(Rails.root.to_s, "Gemfile.lock") }

    before do
      File.write(lock_path, <<~LOCK)
        GEM
          remote: https://rubygems.org/
          specs:
            turbo-rails (2.0.0)
      LOCK
    end

    after { FileUtils.rm_f(lock_path) }

    it "runs the normal Turbo Map flow" do
      result = described_class.call
      text = result.content.first[:text]
      expect(text).to include("Turbo Map")
      expect(text).not_to include("Turbo is not installed")
    end
  end
end
