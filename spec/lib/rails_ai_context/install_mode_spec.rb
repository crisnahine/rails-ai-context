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
      File.write(File.join(tmpdir, "Gemfile.lock"), "GEM\n  remote: https://rubygems.org/\n  specs:\n    rails-ai-context (5.13.0)\n")
      expect(described_class.standalone?).to be(false)
    end

    it "is false when rails-ai-context is a path gem" do
      File.write(File.join(tmpdir, "Gemfile.lock"), "PATH\n  remote: ../rails-ai-context\n  specs:\n    rails-ai-context (5.13.0)\n")
      expect(described_class.standalone?).to be(false)
    end

    it "is true when the Gemfile.lock does not list rails-ai-context" do
      File.write(File.join(tmpdir, "Gemfile.lock"), "GEM\n  remote: https://rubygems.org/\n  specs:\n    rails (7.1.0)\n")
      expect(described_class.standalone?).to be(true)
    end

    it "defaults to false (in-Gemfile) when there is no Gemfile.lock at all" do
      expect(described_class.standalone?).to be(false)
    end

    it "defaults to false when detection raises" do
      allow(Bundler).to receive(:root).and_raise(Bundler::GemfileNotFound)
      expect(described_class.standalone?).to be(false)
    end

    # A fresh clone has no lockfile yet.
    it "reads a Gemfile with no lockfile beside it by whether it names the gem" do
      File.write(File.join(tmpdir, "Gemfile"), %(source "https://rubygems.org"\ngem "rails"\n))
      expect(described_class.standalone?).to be(true)

      Dir.mktmpdir do |bundled|
        File.write(File.join(bundled, "Gemfile"), %(source "https://rubygems.org"\ngem "rails"\ngem "rails-ai-context"\n))
        expect(described_class.standalone?(root: bundled)).to be(false)
      end
    end

    # A workspace asks about apps that are not the bundle it runs in.
    it "reads the app named by root: rather than the process's bundle" do
      File.write(File.join(tmpdir, "Gemfile.lock"), "GEM\n  remote: https://rubygems.org/\n  specs:\n    rails-ai-context (5.13.0)\n")
      Dir.mktmpdir do |app|
        File.write(File.join(app, "Gemfile.lock"), "GEM\n  remote: https://rubygems.org/\n  specs:\n    rails (7.1.0)\n")
        expect(described_class.standalone?(root: app)).to be(true)
        expect(described_class.standalone?).to be(false)
      end
    end
  end
end
