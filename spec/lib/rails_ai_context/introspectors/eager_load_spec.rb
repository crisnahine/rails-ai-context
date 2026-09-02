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

  # A file written after boot has no autoload, so the Combustion app's own
  # loader cannot prove recovery; a loader set up over this directory can.
  # The good file sits in a subdirectory because eager_load_dir walks every
  # top-level file before any queued namespace, so the broken sibling always
  # stops it first, whatever order the filesystem lists in. `const_defined?`
  # is true for a registered autoload, so `autoload?` (nil once loaded) is
  # the check.
  describe "per-constant recovery" do
    let(:dir) { Dir.mktmpdir }
    let(:loader) { Zeitwerk::Loader.new.tap { |l| l.push_dir(dir); l.setup } }

    before do
      FileUtils.mkdir_p(File.join(dir, "nested"))
      File.write(File.join(dir, "zz_broken.rb"), "class ZzBroken <\n")
      File.write(File.join(dir, "nested", "zz_fine.rb"), "module Nested\n  class ZzFine; end\nend\n")
      allow(RailsAiContext::PathResolver).to receive(:dirs_for).and_return([ dir ])
      allow(Rails.autoloaders).to receive(:main).and_return(loader)
    end

    after do
      loader.unload
      loader.unregister if loader.respond_to?(:unregister)
      FileUtils.remove_entry(dir)
    end

    it "loads the constant after the one eager_load_dir stopped at" do
      described_class.dir(dir, kind: "app/models")
      expect(Object.autoload?(:Nested)).to be_nil
      expect(Nested.autoload?(:ZzFine)).to be_nil
      expect(Nested.const_defined?(:ZzFine, false)).to be true
    end
  end
end
