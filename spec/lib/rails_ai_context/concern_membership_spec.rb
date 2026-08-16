# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe RailsAiContext::ConcernMembership do
  describe ".payload?" do
    it "keeps app concerns and gem capability modules, namespaced or not" do
      expect(described_class.payload?("Searchable")).to be(true)
      expect(described_class.payload?("Billing::Chargeable")).to be(true)
      expect(described_class.payload?("Discard::Model")).to be(true)
    end

    it "hides the noisy gem families through the default config, tunably" do
      expect(described_class.payload?("Devise::Models::Recoverable")).to be(false)

      original = RailsAiContext.configuration.excluded_concerns
      RailsAiContext.configuration.excluded_concerns = []
      expect(described_class.payload?("Devise::Models::Recoverable")).to be(true)
    ensure
      RailsAiContext.configuration.excluded_concerns = original
    end

    it "drops the stdlib and framework plumbing" do
      expect(described_class.payload?(nil)).to be(false)
      expect(described_class.payload?("Kernel")).to be(false)
      expect(described_class.payload?("JSON")).to be(false)
      expect(described_class.payload?("ActiveRecord::Timestamp")).to be(false)
      expect(described_class.payload?("ActiveSupport::Callbacks")).to be(false)
      expect(described_class.payload?("ActionController::MimeResponds")).to be(false)
      expect(described_class.payload?("AbstractController::Rendering")).to be(false)
    end

    it "drops the modules Rails generates inside the class" do
      expect(described_class.payload?("Post::GeneratedAssociationMethods")).to be(false)
      expect(described_class.payload?("GeneratedAttributeMethods")).to be(false)
    end

    it "honours excluded_concerns" do
      original = RailsAiContext.configuration.excluded_concerns
      RailsAiContext.configuration.excluded_concerns = [ /\AAudit/ ]
      expect(described_class.payload?("Auditable")).to be(false)
      expect(described_class.payload?("Searchable")).to be(true)
    ensure
      RailsAiContext.configuration.excluded_concerns = original
    end
  end

  describe ".from_mixins" do
    it "keeps only ancestor-reaching mixins, through the payload rule" do
      mixins = [
        { macro: :include, name: "Searchable", ancestor: true },
        { macro: :extend, name: "ClassLevel", ancestor: false },
        { macro: :include, name: "ActiveSupport::Callbacks", ancestor: true },
        { macro: :include, name: "Searchable", ancestor: true }
      ]

      expect(described_class.from_mixins(mixins)).to eq(%w[Searchable])
    end
  end

  describe ".app_owned" do
    it "keeps the concerns the app has a file for" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "app", "models", "concerns"))
        File.write(File.join(root, "app", "models", "concerns", "searchable.rb"), "module Searchable\nend\n")

        names = %w[Searchable Devise::Models::Recoverable]
        expect(described_class.app_owned(names, root)).to eq(%w[Searchable])
      end
    end
  end
end
