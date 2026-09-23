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
end
