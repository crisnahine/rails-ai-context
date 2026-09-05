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
      allow(RailsAiContext::Fingerprinter).to receive(:stale?).and_return(false)
      allow(RailsAiContext::Fingerprinter).to receive(:mark)
        .and_return(RailsAiContext::Fingerprinter::Mark.new(digest: "abc123"))
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

    # A mark taken after the introspection covers edits the answer never
    # read, so the next caller trusts a context that is already stale.
    it "marks the app before it introspects" do
      expect(RailsAiContext::Fingerprinter).to receive(:mark).ordered
        .and_return(RailsAiContext::Fingerprinter::Mark.new(digest: "abc123"))
      expect(RailsAiContext).to receive(:introspect).ordered.and_return({})

      described_class.cached_context
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

  describe "static tier banner" do
    around do |example|
      RailsAiContext.tier = :static
      RailsAiContext.static_reason = "RuntimeError: FATAL_ENV_MISSING"
      RailsAiContext.static_kind = :boot_failed
      example.run
    ensure
      RailsAiContext.tier = :runtime
      RailsAiContext.static_reason = nil
      RailsAiContext.static_kind = nil
    end

    it "appends the banner to every response" do
      response = RailsAiContext::Tools::GetSchema.text_response("## Schema\n\ntables: 3")
      text = response.content.first[:text]
      expect(text).to start_with("## Schema")
      expect(text).to include("App boot failed (RuntimeError: FATAL_ENV_MISSING)")
      expect(text).to include("static analysis")
      expect(text).to include("rails-ai-context doctor")
    end

    it "composes with a caller-provided suffix" do
      response = RailsAiContext::Tools::GetSchema.text_response("body", suffix: "\n\n_custom note_")
      text = response.content.first[:text]
      expect(text).to include("_custom note_")
      expect(text.index("_custom note_")).to be < text.index("App boot failed")
    end

    it "survives truncation" do
      allow(RailsAiContext.configuration).to receive(:max_tool_response_chars).and_return(50)
      response = RailsAiContext::Tools::GetSchema.text_response("x" * 500)
      text = response.content.first[:text]
      expect(text).to include("Response truncated")
      expect(text).to include("App boot failed")
    end

    it "describes --no-boot mode when there is no boot failure" do
      RailsAiContext.static_reason = "static mode requested with --no-boot"
      RailsAiContext.static_kind = :requested
      response = RailsAiContext::Tools::GetSchema.text_response("body")
      expect(response.content.first[:text]).to include("Static mode (static mode requested with --no-boot)")
    end

    # A tree with no config/environment.rb never attempted a boot, so calling
    # it a boot failure sends the reader after an error that was never raised.
    it "names the missing file rather than a boot failure when nothing booted" do
      RailsAiContext.static_reason = "no config/environment.rb in /tmp/app"
      RailsAiContext.static_kind = :source_only
      text = RailsAiContext::Tools::GetSchema.text_response("body").content.first[:text]
      expect(text).to include("Static mode (no config/environment.rb in /tmp/app)")
      expect(text).not_to include("App boot failed")
    end

    # The kind decides the headline, not the shape of the reason string.
    it "reads the kind rather than the reason text" do
      RailsAiContext.static_reason = "no config/environment.rb in /tmp/app"
      RailsAiContext.static_kind = :boot_failed
      text = RailsAiContext::Tools::GetSchema.text_response("body").content.first[:text]
      expect(text).to include("App boot failed (no config/environment.rb in /tmp/app)")
    end
  end

  describe "static tier refusal" do
    around do |example|
      RailsAiContext.tier = :static
      example.run
    ensure
      RailsAiContext.tier = :runtime
      RailsAiContext.static_reason = nil
      RailsAiContext.static_kind = nil
    end

    def refusal_text
      RailsAiContext::Tools::GetSchema.send(:static_tier_refusal, "Live runtime state").content.first[:text]
    end

    it "sends a --no-boot run back without the flag" do
      RailsAiContext.static_reason = "static mode requested with --no-boot"
      RailsAiContext.static_kind = :requested
      text = refusal_text
      expect(text).to include("Rerun without `--no-boot`.")
      expect(text).not_to include("boot failure")
    end

    it "sends a failed boot to doctor" do
      RailsAiContext.static_reason = "RuntimeError: FATAL_ENV_MISSING"
      RailsAiContext.static_kind = :boot_failed
      text = refusal_text
      expect(text).to include("Fix the boot failure (see `rails-ai-context doctor`).")
      expect(text).not_to include("--no-boot")
    end

    # Neither remedy applies to a tree that never booted and was never asked
    # to skip booting.
    it "tells a source-only tree what it is missing" do
      RailsAiContext.static_reason = "no config/environment.rb in /tmp/app"
      RailsAiContext.static_kind = :source_only
      text = refusal_text
      expect(text).to include("This tree has no `config/environment.rb`; add one (or run from the app root) for runtime data.")
      expect(text).not_to include("--no-boot")
      expect(text).not_to include("boot failure")
    end
  end

  describe "runtime tier" do
    it "adds no banner to text_response" do
      response = RailsAiContext::Tools::GetSchema.text_response("body")
      expect(response.content.first[:text]).to eq("body")
    end
  end

  describe ".rails_env_name" do
    it "returns Rails.env when Rails is loaded" do
      expect(described_class.rails_env_name).to eq(Rails.env)
    end

    it "falls back to RAILS_ENV when Rails does not respond to :env" do
      allow(Rails).to receive(:respond_to?).with(:env).and_return(false)
      begin
        original = ENV["RAILS_ENV"]
        ENV["RAILS_ENV"] = "staging"
        expect(described_class.rails_env_name).to eq("staging")
      ensure
        ENV["RAILS_ENV"] = original
      end
    end

    it "falls back to development when neither Rails.env nor RAILS_ENV is available" do
      allow(Rails).to receive(:respond_to?).with(:env).and_return(false)
      begin
        original = ENV["RAILS_ENV"]
        ENV.delete("RAILS_ENV")
        expect(described_class.rails_env_name).to eq("development")
      ensure
        ENV["RAILS_ENV"] = original
      end
    end
  end

  describe ".unavailable_note" do
    it "returns nil for a Hash without :unavailable" do
      expect(described_class.unavailable_note({ notable_gems: [] })).to be_nil
    end

    it "returns nil for a Hash carrying a real :error" do
      expect(described_class.unavailable_note({ error: "boom" })).to be_nil
    end

    it "returns nil for non-Hash input" do
      expect(described_class.unavailable_note(nil)).to be_nil
      expect(described_class.unavailable_note([])).to be_nil
    end

    it "returns a bracketed note carrying the reason for an unavailable section" do
      note = described_class.unavailable_note({ unavailable: "requires a booted Rails app (RuntimeError: boom)" })
      expect(note).to eq("[UNAVAILABLE: requires a booted Rails app (RuntimeError: boom)]")
    end

    # The bracket text is Confidence's to build, so a raised message with a
    # backtrace under it collapses here the way it does everywhere else.
    it "collapses a multi-line reason to its first line" do
      note = described_class.unavailable_note({ unavailable: "boom\n  from somewhere.rb:1" })
      expect(note).to eq("[UNAVAILABLE: boom]")
    end

    it "spells the static refusal the same way" do
      expect(described_class.unavailable_text).to eq("[UNAVAILABLE: requires a booted Rails app]")
    end
  end

  describe ".error_response" do
    it "does not append a banner in runtime tier" do
      response = RailsAiContext::Tools::GetSchema.error_response("something failed")
      expect(response.content.first[:text]).to eq("something failed")
    end

    context "in static tier" do
      around do |example|
        RailsAiContext.tier = :static
        RailsAiContext.static_reason = "RuntimeError: FATAL_ENV_MISSING"
        RailsAiContext.static_kind = :boot_failed
        example.run
      ensure
        RailsAiContext.tier = :runtime
        RailsAiContext.static_reason = nil
        RailsAiContext.static_kind = nil
      end

      it "appends the tier banner so a failing tool keeps degradation context" do
        response = RailsAiContext::Tools::GetSchema.error_response("something failed")
        text = response.content.first[:text]
        expect(text).to start_with("something failed")
        expect(text).to include("App boot failed (RuntimeError: FATAL_ENV_MISSING)")
      end
    end
  end

  describe ".rails_app tier routing" do
    after do
      RailsAiContext.tier = :runtime
      RailsAiContext.configuration.app_root = nil
    end

    it "returns a StaticApp in static tier" do
      RailsAiContext.tier = :static
      RailsAiContext.configuration.app_root = "/tmp/static_root"

      app = described_class.rails_app
      expect(app).to be_a(RailsAiContext::StaticApp)
      expect(app.root.to_s).to eq("/tmp/static_root")
    end

    it "returns Rails.application in runtime tier" do
      expect(described_class.rails_app).to eq(Rails.application)
    end
  end
end
