# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Tools::BaseTool do
  describe ".text_response truncation" do
    before do
      @original_max = RailsAiContext.configuration.max_tool_response_chars
      RailsAiContext.configuration.max_tool_response_chars = 100
    end

    after do
      RailsAiContext.configuration.max_tool_response_chars = @original_max
    end

    it "truncates responses exceeding max chars" do
      long_text = "x" * 200
      result = described_class.text_response(long_text)
      text = result.content.first[:text]
      expect(text).to include("Response truncated")
      expect(text).to include("200 chars")
    end

    it "does not truncate short responses" do
      short_text = "hello"
      result = described_class.text_response(short_text)
      text = result.content.first[:text]
      expect(text).to eq("hello")
    end

    it "includes hint to use detail:summary" do
      long_text = "x" * 200
      result = described_class.text_response(long_text)
      text = result.content.first[:text]
      expect(text).to include('detail:"summary"')
    end
  end

  describe ".reset_all_caches!" do
    it "delegates to reset_cache! on BaseTool" do
      expect(described_class).to receive(:reset_cache!)

      described_class.reset_all_caches!
    end

    it "clears the shared cache" do
      cache = described_class::SHARED_CACHE
      cache[:context] = { fake: true }
      cache[:timestamp] = 999
      cache[:fingerprint] = "abc"

      described_class.reset_all_caches!

      expect(cache[:context]).to be_nil
      expect(cache[:timestamp]).to be_nil
      expect(cache[:fingerprint]).to be_nil
    end
  end
end
