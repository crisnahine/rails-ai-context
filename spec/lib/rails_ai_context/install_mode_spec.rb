# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe RailsAiContext::InstallMode do
  describe ".standalone?" do
    let(:tmpdir) { Dir.mktmpdir }

    before { allow(Bundler).to receive(:root).and_return(Pathname.new(tmpdir)) }
    after  { FileUtils.remove_entry(tmpdir) }

    it "is false when the Gemfile.lock lists rails-ai-context" do
      File.write(File.join(tmpdir, "Gemfile.lock"), "    rails-ai-context (5.13.0)\n")
      expect(described_class.standalone?).to be(false)
    end

    it "is true when the Gemfile.lock does not list rails-ai-context" do
      File.write(File.join(tmpdir, "Gemfile.lock"), "    rails (7.1.0)\n")
      expect(described_class.standalone?).to be(true)
    end

    it "defaults to false (in-Gemfile) when there is no Gemfile.lock at all" do
      expect(described_class.standalone?).to be(false)
    end

    it "defaults to false when detection raises" do
      allow(Bundler).to receive(:root).and_raise(Bundler::GemfileNotFound)
      expect(described_class.standalone?).to be(false)
    end
  end
end
