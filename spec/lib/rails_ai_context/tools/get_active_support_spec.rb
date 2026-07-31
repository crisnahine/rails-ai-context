# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Tools::GetActiveSupport do
  before { described_class.reset_cache! }

  let(:active_support_data) do
    {
      concerns: {
        "app/models/concerns" => [
          { name: "Searchable", file: "app/models/concerns/searchable.rb",
            uses_active_support_concern: true, included_blocks: 1, class_methods_block: true }
        ],
        "app/controllers/concerns" => [
          { name: "Authenticatable", file: "app/controllers/concerns/authenticatable.rb",
            uses_active_support_concern: true, included_blocks: 0, class_methods_block: false }
        ]
      },
      deprecators: %w[7.1 deprecation],
      message_verifier_usage: [
        { file: "app/services/token_service.rb", encryptor: true, verifier: false }
      ],
      tagged_logging: { configured: true, tags: %w[request_id] },
      on_load_hooks: [ { hook: "active_record", callbacks: 3 } ],
      cache_usage: { store: "solid_cache_store", options: %w[namespace] }
    }
  end

  before do
    allow(described_class).to receive(:cached_context).and_return({ active_support: active_support_data })
  end

  describe ".call" do
    it "renders the concerns registry with shape markers" do
      text = described_class.call.content.first[:text]
      expect(text).to include("# ActiveSupport")
      expect(text).to include("## Concerns (2)")
      expect(text).to include("### app/models/concerns")
      expect(text).to include("**Searchable** (included block, class_methods)")
      expect(text).to include("**Authenticatable**")
    end

    it "renders deprecators" do
      text = described_class.call.content.first[:text]
      expect(text).to include("## Deprecators")
      expect(text).to include("`7.1`")
    end

    it "renders verifier/encryptor usage" do
      text = described_class.call.content.first[:text]
      expect(text).to include("## MessageVerifier / MessageEncryptor Usage")
      expect(text).to include("`app/services/token_service.rb` (encryptor)")
    end

    it "renders tagged logging when configured" do
      text = described_class.call.content.first[:text]
      expect(text).to include("## Tagged Logging")
      expect(text).to include("**Tags:** request_id")
    end

    it "renders subscribed on_load hooks" do
      text = described_class.call.content.first[:text]
      expect(text).to include("## Subscribed on_load Hooks")
      expect(text).to include("`active_record` - 3 subscriber(s)")
    end

    it "renders the cache store" do
      text = described_class.call.content.first[:text]
      expect(text).to include("## Cache Store")
      expect(text).to include("**Store:** solid_cache_store")
      expect(text).to include("**Options:** namespace")
    end

    context "with an empty introspection result" do
      before { allow(described_class).to receive(:cached_context).and_return({ active_support: {} }) }

      it "renders the heading without raising" do
        text = described_class.call.content.first[:text]
        expect(text).to include("# ActiveSupport")
        expect(text).to include("_No concerns found under app/**/concerns._")
      end
    end

    context "with no cache store configured" do
      before do
        allow(described_class).to receive(:cached_context)
          .and_return({ active_support: { cache_usage: { store: "" } } })
      end

      it "omits the cache section instead of rendering a blank store" do
        text = described_class.call.content.first[:text]
        expect(text).not_to include("## Cache Store")
      end
    end

    context "when the introspector is not configured" do
      before { allow(described_class).to receive(:cached_context).and_return({}) }

      it "says how to enable it" do
        text = described_class.call.content.first[:text]
        expect(text).to include("Add :active_support to introspectors")
      end
    end

    context "when introspection failed" do
      before { allow(described_class).to receive(:cached_context).and_return({ active_support: { error: "boom" } }) }

      it "reports the failure honestly" do
        text = described_class.call.content.first[:text]
        expect(text).to include("ActiveSupport introspection failed: boom")
      end
    end

    context "when running in the static tier" do
      before do
        allow(described_class).to receive(:cached_context)
          .and_return({ active_support: { unavailable: "requires a booted Rails app" } })
      end

      it "renders the unavailable note" do
        text = described_class.call.content.first[:text]
        expect(text).to include("[UNAVAILABLE: requires a booted Rails app]")
      end
    end
  end
end
