# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Introspectors::EagerLoad do
  it "loads the constants under a kind the main autoloader manages" do
    described_class.dir(Rails.root, kind: "app/models")
    expect(Object.const_defined?(:Post)).to be true
  end

  it "does not raise for a directory no loader manages, and does not stop at the first bad file" do
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "app/models"))
      File.write(File.join(dir, "app/models/broken.rb"), "class Broken <\n")
      File.write(File.join(dir, "app/models/fine.rb"), "class Fine; end\n")
      allow(RailsAiContext::PathResolver).to receive(:dirs_for).and_return([ File.join(dir, "app/models") ])

      expect { described_class.dir(dir, kind: "app/models") }.not_to raise_error
    end
  end

  it "does nothing when the app already eager loaded" do
    allow(Rails.application.config).to receive(:eager_load).and_return(true)
    expect(RailsAiContext::PathResolver).not_to receive(:dirs_for)

    described_class.dir(Rails.root, kind: "app/models")
  end
end
