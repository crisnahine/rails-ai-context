# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe RailsAiContext::ConcernPaths do
  describe ".resolve" do
    let(:tmpdir) { Dir.mktmpdir }

    after { FileUtils.remove_entry(tmpdir) }

    it "finds every app/*/concerns directory, not a fixed pair" do
      %w[models controllers mailers serializers].each do |owner|
        FileUtils.mkdir_p(File.join(tmpdir, "app", owner, "concerns"))
      end

      expect(described_class.resolve(tmpdir).map { |d| d.sub("#{tmpdir}/", "") })
        .to eq(%w[
          app/controllers/concerns
          app/mailers/concerns
          app/models/concerns
          app/serializers/concerns
        ])
    end

    it "skips a directory that does not exist" do
      FileUtils.mkdir_p(File.join(tmpdir, "app", "models", "concerns"))

      expect(described_class.resolve(tmpdir).map { |d| d.sub("#{tmpdir}/", "") })
        .to eq(%w[app/models/concerns])
    end

    it "reads a configured directory that lives outside app/" do
      FileUtils.mkdir_p(File.join(tmpdir, "lib", "concerns"))
      allow(RailsAiContext.configuration).to receive(:concern_paths).and_return(%w[lib/concerns])

      expect(described_class.resolve(tmpdir).map { |d| d.sub("#{tmpdir}/", "") })
        .to eq(%w[lib/concerns])
    end

    it "searches only what the app configured, so the setting can narrow" do
      FileUtils.mkdir_p(File.join(tmpdir, "app", "models", "concerns"))
      FileUtils.mkdir_p(File.join(tmpdir, "app", "mailers", "concerns"))
      allow(RailsAiContext.configuration).to receive(:concern_paths).and_return(%w[app/models/concerns])

      expect(described_class.resolve(tmpdir).map { |d| d.sub("#{tmpdir}/", "") })
        .to eq(%w[app/models/concerns])
    end

    it "skips a configured directory that does not exist" do
      allow(RailsAiContext.configuration).to receive(:concern_paths).and_return(%w[lib/nope])

      expect(described_class.resolve(tmpdir)).to eq([])
    end

    it "auto-discovers when the setting is left alone" do
      FileUtils.mkdir_p(File.join(tmpdir, "app", "mailers", "concerns"))
      allow(RailsAiContext.configuration).to receive(:concern_paths).and_return(nil)

      expect(described_class.resolve(tmpdir).map { |d| d.sub("#{tmpdir}/", "") })
        .to eq(%w[app/mailers/concerns])
    end

    it "ships with the setting unset so discovery is the default" do
      expect(RailsAiContext::Configuration.new.concern_paths).to be_nil
    end

    it "returns nothing when the app has no concerns at all" do
      expect(described_class.resolve(tmpdir)).to eq([])
    end
  end

  describe ".type_for" do
    it "singularises the owner segment" do
      expect(described_class.type_for("/app/mailers/concerns")).to eq("mailer")
      expect(described_class.type_for("/srv/x/app/models/concerns")).to eq("model")
      expect(described_class.type_for("/srv/x/app/controllers/concerns")).to eq("controller")
    end

    it "falls back to other for a directory outside app/" do
      expect(described_class.type_for("/srv/x/lib/concerns")).to eq("other")
    end
  end
end
