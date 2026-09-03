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

  # Camelizing the path gives ZzHtmlParser, a constant nothing defines, so
  # the file loads only if the loader's own inflector names it. The broken
  # sibling stops eager_load_dir, which is what puts the inflected file on
  # the per-constant path in the first place.
  describe "a file the app registers an inflection for" do
    let(:dir) { Dir.mktmpdir }
    let(:loader) do
      Zeitwerk::Loader.new.tap do |l|
        l.inflector.inflect("zz_html_parser" => "ZzHTMLParser")
        l.push_dir(dir)
        l.setup
      end
    end

    before do
      File.write(File.join(dir, "zz_a_broken.rb"), "class ZzABroken <\n")
      File.write(File.join(dir, "zz_html_parser.rb"), "class ZzHTMLParser; end\n")
      allow(RailsAiContext::PathResolver).to receive(:dirs_for).and_return([ dir ])
      allow(Rails.autoloaders).to receive(:main).and_return(loader)
    end

    after do
      loader.unload
      loader.unregister if loader.respond_to?(:unregister)
      FileUtils.remove_entry(dir)
    end

    it "loads the constant the inflector names" do
      described_class.dir(dir, kind: "app/models")

      expect(Object.autoload?(:ZzHTMLParser)).to be_nil
      expect(Object.const_defined?(:ZzHTMLParser, false)).to be true
    end
  end

  # A pack or an in-repo engine runs its own loader, so the main loader
  # declines to name that directory's files: cpath_expected_at raises
  # Zeitwerk::Error for a root it does not manage.
  describe "a directory another loader owns" do
    let(:main_dir) { Dir.mktmpdir }
    let(:pack_dir) { Dir.mktmpdir }
    let(:main_loader) { Zeitwerk::Loader.new.tap { |l| l.push_dir(main_dir); l.setup } }
    let(:pack_loader) { Zeitwerk::Loader.new.tap { |l| l.push_dir(pack_dir); l.setup } }

    before do
      File.write(File.join(main_dir, "zz_main_thing.rb"), "class ZzMainThing; end\n")
      File.write(File.join(pack_dir, "zz_pack_thing.rb"), "class ZzPackThing; end\n")
      main_loader
      pack_loader
      allow(RailsAiContext::PathResolver).to receive(:dirs_for).and_return([ pack_dir ])
      allow(Rails.autoloaders).to receive(:main).and_return(main_loader)
    end

    after do
      [ main_loader, pack_loader ].each do |l|
        l.unload
        l.unregister if l.respond_to?(:unregister)
      end
      [ main_dir, pack_dir ].each { |d| FileUtils.remove_entry(d) }
    end

    it "loads the constant through the owning loader's autoload" do
      described_class.dir(pack_dir, kind: "app/models")

      expect(Object.autoload?(:ZzPackThing)).to be_nil
      expect(Object.const_defined?(:ZzPackThing, false)).to be true
    end
  end
end
