# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe RailsAiContext::Introspectors::SuperclassChain do
  describe ".lookup_for" do
    it "answers with the source of the class a service file declares" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "services", "billing"))
        File.write(File.join(dir, "app", "services", "billing", "base_request.rb"),
                   "class Billing::BaseRequest < ActiveInteraction::Base\nend\n")

        lookup = described_class.lookup_for(dir)

        expect(lookup.call("Billing::BaseRequest")).to include("ActiveInteraction::Base")
        expect(lookup.call("Billing::Missing")).to be_nil
      end
    end

    it "finds a base class in any autoload root, not just the service ones" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models", "concerns"))
        FileUtils.mkdir_p(File.join(dir, "lib", "billing"))
        File.write(File.join(dir, "app", "models", "concerns", "base_request.rb"),
                   "class BaseRequest < ActiveInteraction::Base\nend\n")
        File.write(File.join(dir, "lib", "billing", "legacy_request.rb"),
                   "class Billing::LegacyRequest < ActiveInteraction::Base\nend\n")

        lookup = described_class.lookup_for(dir)

        expect(lookup.call("BaseRequest")).to include("ActiveInteraction::Base")
        expect(lookup.call("Billing::LegacyRequest")).to include("ActiveInteraction::Base")
      end
    end

    it "reads app/interactions as well as app/services" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "interactions"))
        File.write(File.join(dir, "app", "interactions", "base_request.rb"),
                   "class BaseRequest < ActiveInteraction::Base\nend\n")

        expect(described_class.lookup_for(dir).call("BaseRequest")).to include("ActiveInteraction::Base")
      end
    end

    # An app whose interactions all name ActiveInteraction::Base never asks,
    # and the roots are resolved on the first question rather than up front.
    it "does not touch the filesystem until a name is asked for" do
      Dir.mktmpdir do |dir|
        expect(RailsAiContext::PathResolver).not_to receive(:dirs_for)
        described_class.lookup_for(dir)
      end
    end
  end

  describe ".to" do
    # MAX_DEPTH counts hops, not the names a hop records, so a chain of app
    # base classes is followed as far as the cap says.
    it "follows a chain of app base classes to the base it is asked for" do
      sources = {
        "Level4" => "class Level4 < ActiveModel::EachValidator\nend\n",
        "Level3" => "class Level3 < Level4\nend\n",
        "Level2" => "class Level2 < Level3\nend\n",
        "Level1" => "class Level1 < Level2\nend\n"
      }
      chain = described_class.to("class EmailValidator < Level1\nend\n",
                                 bases: %w[ActiveModel::EachValidator],
                                 lookup: ->(name) { sources[name] })

      expect(chain.map(&:name)).to eq(%w[EmailValidator Level1 Level2 Level3 Level4])
    end

    # A caller asking which of several bases the chain reached reads it off
    # the last link rather than parsing that file again.
    it "names each link's superclass, ending at the base it reached" do
      base = "class ApplicationValidator < ActiveModel::EachValidator\nend\n"
      chain = described_class.to("class EmailValidator < ApplicationValidator\nend\n",
                                 bases: %w[ActiveModel::Validator ActiveModel::EachValidator],
                                 lookup: ->(name) { base if name == "ApplicationValidator" })

      expect(chain.map(&:superclass)).to eq(%w[ApplicationValidator ActiveModel::EachValidator])
    end

    it "follows a parent that a Class.new assignment declares" do
      base = "Base = Class.new(ApplicationRecord) do\n  self.abstract_class = true\nend\n"
      chain = described_class.to("class Widget < Base\nend\n",
                                 bases: %w[ApplicationRecord],
                                 lookup: ->(name) { base if name == "Base" })

      expect(chain.map(&:name)).to eq(%w[Widget Base])
    end

    it "gives up past the depth cap rather than walking forever" do
      sources = (1..20).to_h { |i| [ "Level#{i}", "class Level#{i} < Level#{i + 1}\nend\n" ] }
      chain = described_class.to("class Deep < Level1\nend\n",
                                 bases: %w[ActiveModel::Validator],
                                 lookup: ->(name) { sources[name] })

      expect(chain).to eq([])
    end

    it "is empty when the source declares nothing" do
      expect(described_class.to("# just a comment\n", bases: %w[ActiveModel::Validator])).to eq([])
    end
  end

  # Ruby resolves a bare superclass from the enclosing namespace outward, and
  # three walks each wrote that loop, two of them innermost-first and one
  # bare-first.
  describe ".resolve_in_scope" do
    let(:known) { %w[Fasp::BaseWorker BaseWorker Trackers::Base] }

    it "reads a compact class's superclass from the nesting it is written in" do
      resolved = described_class.resolve_in_scope("Fasp::BackfillWorker", "BaseWorker", nesting: []) do |name|
        name if known.include?(name)
      end

      expect(resolved).to eq("BaseWorker")
    end

    it "walks Module.nesting rather than every prefix of the declared name" do
      tried = []
      described_class.resolve_in_scope("A::B::D::C", "X", nesting: %w[A::B::D A]) { |name| tried << name && nil }

      expect(tried).to eq(%w[A::B::D::X A::X X])
    end

    it "prefers the nearest enclosing namespace over the bare name" do
      resolved = described_class.resolve_in_scope("Fasp::BackfillWorker", "BaseWorker") do |name|
        name if known.include?(name)
      end

      expect(resolved).to eq("Fasp::BaseWorker")
    end

    it "falls back to the bare name when no namespace carries it" do
      resolved = described_class.resolve_in_scope("Other::Thing", "BaseWorker") do |name|
        name if known.include?(name)
      end

      expect(resolved).to eq("BaseWorker")
    end

    # `class CostQuery::Export < Export` names the top-level Export: the
    # nearest-scope candidate here is the class itself, and resolving a class
    # to its own name makes the walk read it as its own parent.
    it "never resolves a class to itself" do
      resolved = described_class.resolve_in_scope("CostQuery::Export", "Export") do |name|
        name if %w[CostQuery::Export Export].include?(name)
      end

      expect(resolved).to eq("Export")
    end

    it "answers what the block answers, not the name" do
      resolved = described_class.resolve_in_scope("Trackers::Null", "Base") { |name| known.index(name) }

      expect(resolved).to eq(2)
    end

    it "answers nothing for no superclass" do
      expect(described_class.resolve_in_scope("Fasp::BackfillWorker", nil) { |n| n }).to be_nil
    end
  end

  # Three callers answered "is this an abstract base" three ways, and
  # disagreed about ApplicationJobBase.
  describe ".abstract_base?" do
    it "calls a Base-named class with a subclass a base" do
      expect(described_class.abstract_base?("Trackers::Base", inherited: true)).to be(true)
      expect(described_class.abstract_base?("ApplicationJobBase", inherited: true)).to be(true)
      expect(described_class.abstract_base?("BaseService", inherited: true)).to be(true)
    end

    # A base nobody inherits from is somebody's only job.
    it "does not call a Base-named class with no subclass a base" do
      expect(described_class.abstract_base?("BaseService", inherited: false)).to be(false)
    end

    # Rails' own base is one whether or not this app got round to using it.
    it "calls an Application base one with no subclass" do
      expect(described_class.abstract_base?("ApplicationService", inherited: false)).to be(true)
      expect(described_class.abstract_base?("Admin::ApplicationJob", inherited: false)).to be(true)
    end

    # Mastodon's FollowService has a subclass and is called everywhere.
    it "does not call a subclassed service with an ordinary name a base" do
      expect(described_class.abstract_base?("FollowService", inherited: true)).to be(false)
    end

    # "Base" anywhere in a name caught the word rather than the role:
    # TimeBasedJob and KnowledgeBaseImporter are the work, not the base of it.
    it "does not read the word base inside an ordinary name" do
      %w[TimeBasedJob RoleBasedAccessWorker KnowledgeBaseImporter DatabaseCleanupJob].each do |name|
        expect(described_class.abstract_base?(name, inherited: true)).to be(false), name
      end
    end

    it "still reads the shapes apps write a base in" do
      %w[Base BaseWorker JobBase BaseService BaseBookmarkable DeriveProgressValuesBase
         BustCacheBaseWorker Jobs::Base].each do |name|
        expect(described_class.abstract_base?(name, inherited: true)).to be(true), name
      end
    end
  end

  describe ".conventional_base?" do
    it "reads an engine's own copy of the layer base" do
      expect(described_class.conventional_base?("Admin::ApplicationController", "ApplicationController")).to be(true)
      expect(described_class.conventional_base?("ApplicationController", "ApplicationController")).to be(true)
      expect(described_class.conventional_base?("ReportsController", "ApplicationController")).to be(false)
    end
  end
end
