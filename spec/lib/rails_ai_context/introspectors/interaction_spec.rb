# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe RailsAiContext::Introspectors::Interaction do
  describe ".interaction?" do
    it "is true for a direct subclass of ActiveInteraction::Base" do
      source = <<~RUBY
        class Orders::Create < ActiveInteraction::Base
          object :account
        end
      RUBY

      expect(described_class.interaction?(source)).to be(true)
    end

    it "is false for a plain service object" do
      expect(described_class.interaction?("class ChargeCard\n  def call; end\nend\n")).to be(false)
    end

    it "is false for a subclass whose parent the lookup cannot resolve" do
      source = "class Billing::Charge < Billing::BaseRequest\nend\n"

      expect(described_class.interaction?(source)).to be(false)
    end

    it "follows the chain through the lookup" do
      base = "class Billing::BaseRequest < ActiveInteraction::Base\n  string :token\nend\n"
      source = "class Billing::Charge < Billing::BaseRequest\nend\n"
      lookup = ->(name) { base if name == "Billing::BaseRequest" }

      expect(described_class.interaction?(source, lookup: lookup)).to be(true)
    end

    # A chain that points back at itself must end rather than recurse.
    it "stops on a cycle instead of recursing" do
      a = "class A < B\nend\n"
      b = "class B < A\nend\n"
      lookup = ->(name) { { "A" => a, "B" => b }[name] }

      expect(described_class.interaction?(a, lookup: lookup)).to be(false)
    end
  end

  describe ".filters" do
    it "returns the class's own filters in source order" do
      source = <<~RUBY
        class Orders::Create < ActiveInteraction::Base
          object :account
          string :reason, default: nil
        end
      RUBY

      expect(described_class.filters(source).map(&:name)).to eq(%w[account reason])
    end

    it "keeps a nested filter under the filter that declares it" do
      source = <<~RUBY
        class Orders::CreateWithParams < ActiveInteraction::Base
          hash :order_params do
            string :title, default: nil
            integer :quantity, default: nil
          end

          object :account
        end
      RUBY

      filters = described_class.filters(source)

      expect(filters.map(&:name)).to eq(%w[order_params account])
      expect(filters.first.nested.map(&:name)).to eq(%w[title quantity])
      expect(filters.first.nested.map(&:macro)).to eq(%w[string integer])
    end

    # A one-line block puts the parent and both children on the same line, so
    # a line number cannot say which call a nested filter belongs to.
    it "keeps two filters nested in a one-line block under their parent" do
      source = "class Orders::Create < ActiveInteraction::Base\n  hash(:params) { string :title; integer :quantity }\n  object :account\nend\n"

      filters = described_class.filters(source)

      expect(filters.map(&:name)).to eq(%w[params account])
      expect(filters.first.nested.map(&:name)).to eq(%w[title quantity])
    end

    it "carries the options a filter declares" do
      source = <<~RUBY
        class Orders::Create < ActiveInteraction::Base
          string :reason, default: nil
        end
      RUBY

      expect(described_class.filters(source).first.options).to include(default: nil)
    end

    # ActiveInteraction defines the parent's filters first, so a spec that
    # calls .run has to pass them in that order to read like the real call.
    it "puts an inherited filter before the subclass's own" do
      base = "class Billing::BaseRequest < ActiveInteraction::Base\n  string :token\nend\n"
      source = "class Billing::Charge < Billing::BaseRequest\n  hash :body\nend\n"
      lookup = ->(name) { base if name == "Billing::BaseRequest" }

      filters = described_class.filters(source, lookup: lookup)

      expect(filters.map(&:name)).to eq(%w[token body])
      expect(filters.first.declared_by).to eq("Billing::BaseRequest")
      expect(filters.last.declared_by).to eq("Billing::Charge")
    end

    # ActiveInteraction keeps one filter per name: a subclass that narrows a
    # parent's filter replaces it, in the parent's position.
    it "keeps one filter per name when a subclass redeclares its parent's" do
      base = "class Billing::BaseRequest < ActiveInteraction::Base\n  string :token\n  object :account\nend\n"
      source = "class Billing::Charge < Billing::BaseRequest\n  string :token, default: nil\nend\n"
      lookup = ->(name) { base if name == "Billing::BaseRequest" }

      filters = described_class.filters(source, lookup: lookup)

      expect(filters.map(&:name)).to eq(%w[token account])
      expect(filters.first.declared_by).to eq("Billing::Charge")
      expect(filters.first.options).to include(default: nil)
    end

    it "is empty for a class that is not an interaction" do
      expect(described_class.filters("class ChargeCard\n  string :nope\nend\n")).to eq([])
    end
  end

  describe ".interface" do
    it "is nil for a class that is not an interaction" do
      expect(described_class.interface("class ChargeCard\n  def call; end\nend\n")).to be_nil
    end

    # An interaction that takes nothing still runs with .run, so the empty
    # list and the nil have to stay apart.
    it "is an empty array for an interaction with no filters" do
      expect(described_class.interface("class Orders::Create < ActiveInteraction::Base\nend\n")).to eq([])
    end
  end

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
end
