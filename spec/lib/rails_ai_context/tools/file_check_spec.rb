# frozen_string_literal: true

require "spec_helper"

# Without live reload, nothing dropped the caches on an edit: inside
# cache_ttl a server answered for the app as it was, and what the booted
# tier reads by reflection stayed stale until a restart.
RSpec.describe "a server's check of the app's files at each call" do
  let(:base) { RailsAiContext::Tools::BaseTool }
  let(:mark) { ->(digest) { RailsAiContext::Fingerprinter::Mark.new(digest: digest) } }

  before do
    allow(RailsAiContext::CodeReloader).to receive(:reload!).and_return(true)
    allow(base).to receive(:reset_all_caches!).and_call_original
  end

  it "walks nothing in a process that started no server" do
    expect(RailsAiContext::Fingerprinter).not_to receive(:mark)

    base.refresh_if_files_changed!
  end

  it "leaves a server whose files cannot be read to serve without the check" do
    expect { base.check_files_per_call!(Object.new) }.not_to raise_error
    expect(base::FILE_CHECK[:mark]).to be_nil
  end

  context "once a server has asked for it" do
    before do
      allow(RailsAiContext::Fingerprinter).to receive(:mark).and_return(mark.call("a"))
      base.check_files_per_call!(base.rails_app)
    end

    it "keeps the caches while the files are as they were" do
      base.refresh_if_files_changed!

      expect(base).not_to have_received(:reset_all_caches!)
      expect(RailsAiContext::CodeReloader).not_to have_received(:reload!)
    end

    it "reloads the app's code, then drops the caches, once the files moved" do
      allow(RailsAiContext::Fingerprinter).to receive(:mark).and_return(mark.call("b"))

      base.refresh_if_files_changed!
      base.refresh_if_files_changed!

      expect(RailsAiContext::CodeReloader).to have_received(:reload!).ordered
      expect(base).to have_received(:reset_all_caches!).once.ordered
    end

    it "leaves the code to Rails inside a request the app serves" do
      allow(RailsAiContext::Fingerprinter).to receive(:mark).and_return(mark.call("b"))
      allow(RailsAiContext::CodeReloader).to receive(:inside_app_executor?).and_return(true)

      base.refresh_if_files_changed!

      expect(RailsAiContext::CodeReloader).not_to have_received(:reload!)
      expect(base).to have_received(:reset_all_caches!).once
    end

    # A burst on a large app pays for one walk; on a typical app the walk is
    # so short that calls even milliseconds apart each check.
    it "shares a walk with a call within ten walks' time of it, and not one after" do
      allow(RailsAiContext::Fingerprinter).to receive(:mark) { sleep(0.02) && mark.call("a") }

      base.refresh_if_files_changed!
      base.refresh_if_files_changed!
      expect(RailsAiContext::Fingerprinter).to have_received(:mark).twice

      sleep(0.25)
      base.refresh_if_files_changed!
      expect(RailsAiContext::Fingerprinter).to have_received(:mark).exactly(3).times
    end

    it "asks nothing for a tool another tool calls" do
      allow(RailsAiContext::Fingerprinter).to receive(:mark).and_return(mark.call("b"))

      RailsAiContext::RunCache.around { base.refresh_if_files_changed! }

      expect(base).not_to have_received(:reset_all_caches!)
    end
  end

  # The path a client's call takes: an answer read before an edit is not
  # served after it.
  it "gives a tool call the context as the files are now" do
    allow(RailsAiContext::Fingerprinter).to receive(:mark).and_return(mark.call("a"))
    base.check_files_per_call!(base.rails_app)
    allow(RailsAiContext).to receive(:introspect).and_return({ app_name: "Before" }, { app_name: "After" })

    first = RailsAiContext::Tools::GetConventions.send(:cached_context)[:app_name]
    allow(RailsAiContext::Fingerprinter).to receive(:mark).and_return(mark.call("b"))
    RailsAiContext::Tools::GetConventions.call

    expect([ first, RailsAiContext::Tools::GetConventions.send(:cached_context)[:app_name] ]).to eq(%w[Before After])
  end
end
