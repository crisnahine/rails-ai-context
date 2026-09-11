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

    it "reads a configured path that is already absolute" do
      outside = Dir.mktmpdir
      FileUtils.mkdir_p(File.join(outside, "shared_concerns"))
      allow(RailsAiContext.configuration).to receive(:concern_paths)
        .and_return([ File.join(outside, "shared_concerns") ])

      expect(described_class.resolve(tmpdir)).to eq([ File.join(outside, "shared_concerns") ])
    ensure
      FileUtils.remove_entry(outside) if outside
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

  describe ".find_file" do
    let(:tmpdir) { Dir.mktmpdir }

    after { FileUtils.remove_entry(tmpdir) }

    # `resolve` sorts, so app/controllers/concerns won a shared basename and
    # a model merged a controller concern's filters into its callbacks.
    it "prefers the concerns directory belonging to the owner kind" do
      %w[controllers models].each do |owner|
        FileUtils.mkdir_p(File.join(tmpdir, "app", owner, "concerns"))
        File.write(File.join(tmpdir, "app", owner, "concerns", "searchable.rb"), "module Searchable\nend\n")
      end

      expect(described_class.find_file(tmpdir, "Searchable", prefer: "model"))
        .to eq(File.join(tmpdir, "app", "models", "concerns", "searchable.rb"))
      expect(described_class.find_file(tmpdir, "Searchable", prefer: "controller"))
        .to eq(File.join(tmpdir, "app", "controllers", "concerns", "searchable.rb"))
    end

    # `include DebugConcern` inside Fasp::Provider resolves at runtime to
    # Fasp::Provider::DebugConcern; underscoring the literal spelling finds
    # nothing.
    it "walks the enclosing namespaces outward" do
      dir = File.join(tmpdir, "app", "models", "concerns", "fasp", "provider")
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, "debug_concern.rb"), "module DebugConcern\nend\n")

      expect(described_class.find_file(tmpdir, "DebugConcern", within: "Fasp::Provider"))
        .to eq(File.join(dir, "debug_concern.rb"))
      expect(described_class.find_file(tmpdir, "DebugConcern")).to be_nil
    end

    # Ruby reaches the top level last, so the nested file is the one the
    # reference binds to when both spellings exist.
    it "prefers the innermost namespace over a top-level file of the same name" do
      nested = File.join(tmpdir, "app", "models", "concerns", "fasp", "provider")
      FileUtils.mkdir_p(nested)
      File.write(File.join(nested, "debug_concern.rb"), "module DebugConcern\nend\n")
      File.write(File.join(tmpdir, "app", "models", "concerns", "debug_concern.rb"), "module DebugConcern\nend\n")

      expect(described_class.find_file(tmpdir, "DebugConcern", within: "Fasp::Provider"))
        .to eq(File.join(nested, "debug_concern.rb"))
    end
  end
end
