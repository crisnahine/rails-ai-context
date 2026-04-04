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

  describe ".cached_context deep copy" do
    before do
      described_class.reset_cache!
      allow(RailsAiContext).to receive(:introspect).and_return({
        models: { "User" => { associations: [], validations: [] } },
        schema: { tables: { "users" => { columns: [ { name: "id", type: "integer" } ] } } }
      })
      allow(RailsAiContext::Fingerprinter).to receive(:changed?).and_return(false)
      allow(RailsAiContext::Fingerprinter).to receive(:compute).and_return("abc123")
    end

    after { described_class.reset_cache! }

    it "returns a deep copy, not the shared reference" do
      ctx1 = described_class.cached_context
      ctx2 = described_class.cached_context
      expect(ctx1).not_to equal(ctx2)
      expect(ctx1[:models]).not_to equal(ctx2[:models])
    end

    it "prevents mutation from affecting subsequent calls" do
      ctx1 = described_class.cached_context
      ctx1[:models]["User"][:associations] << { type: :has_many, name: :posts }
      ctx1[:models].delete("User")

      ctx2 = described_class.cached_context
      expect(ctx2[:models]).to have_key("User")
      expect(ctx2[:models]["User"][:associations]).to be_empty
    end

    it "deep copies nested arrays" do
      ctx1 = described_class.cached_context
      ctx1[:schema][:tables]["users"][:columns] << { name: "email", type: "string" }

      ctx2 = described_class.cached_context
      expect(ctx2[:schema][:tables]["users"][:columns].size).to eq(1)
    end
  end

  describe ".paginate" do
    let(:items) { (1..25).to_a }

    it "applies default limit when limit is nil" do
      result = described_class.paginate(items, offset: 0, limit: nil, default_limit: 10)
      expect(result[:items]).to eq((1..10).to_a)
      expect(result[:total]).to eq(25)
      expect(result[:limit]).to eq(10)
    end

    it "slices items at the given offset" do
      result = described_class.paginate(items, offset: 5, limit: 3)
      expect(result[:items]).to eq([ 6, 7, 8 ])
    end

    it "includes pagination hint when more items remain" do
      result = described_class.paginate(items, offset: 0, limit: 5)
      expect(result[:hint]).to include("Showing 1-5 of 25")
      expect(result[:hint]).to include("offset:5")
    end

    it "returns empty hint when all items are shown" do
      result = described_class.paginate(items, offset: 0, limit: 50)
      expect(result[:hint]).to eq("")
    end

    it "handles offset beyond total" do
      result = described_class.paginate(items, offset: 100, limit: 10)
      expect(result[:items]).to be_empty
      expect(result[:hint]).to include("No items at offset 100")
      expect(result[:hint]).to include("Total: 25")
    end

    it "respects custom default_limit" do
      result = described_class.paginate(items, offset: 0, limit: nil, default_limit: 3)
      expect(result[:items]).to eq([ 1, 2, 3 ])
      expect(result[:limit]).to eq(3)
    end

    it "clamps limit to minimum of 1" do
      result = described_class.paginate(items, offset: 0, limit: 0)
      expect(result[:limit]).to eq(1)
      expect(result[:items]).to eq([ 1 ])
    end

    it "clamps negative offset to 0" do
      result = described_class.paginate(items, offset: -5, limit: 3)
      expect(result[:offset]).to eq(0)
      expect(result[:items]).to eq([ 1, 2, 3 ])
    end

    it "returns correct structure" do
      result = described_class.paginate(items, offset: 2, limit: 5)
      expect(result).to have_key(:items)
      expect(result).to have_key(:hint)
      expect(result).to have_key(:total)
      expect(result).to have_key(:offset)
      expect(result).to have_key(:limit)
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
