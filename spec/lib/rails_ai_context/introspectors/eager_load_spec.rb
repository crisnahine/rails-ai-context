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

  # An engine's test/dummy boots the engine; its classes are the project's.
  it "loads the kind in an engine the app sits inside, and in no other engine" do
    Dir.mktmpdir do |dir|
      dummy = File.join(dir, "test", "dummy")
      FileUtils.mkdir_p(File.join(dummy, "app", "models"))
      FileUtils.mkdir_p(File.join(dir, "app", "models", "shop"))
      FileUtils.mkdir_p(File.join(dir, "other", "app", "models"))
      enclosing = double("engine", root: Pathname.new(dir))
      unrelated = double("engine", root: Pathname.new(File.join(dir, "other")))
      rootless = double("engine", root: nil)
      allow(Rails::Engine).to receive(:subclasses).and_return([ rootless, enclosing, unrelated ])
      loaded = []
      allow(described_class).to receive(:load_dir) do |path|
        loaded << path
        {}
      end

      described_class.dir(dummy, kind: "app/models")

      expect(loaded).to eq([ File.join(dummy, "app", "models"), File.join(dir, "app", "models") ])
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

  # Requiring a file that does not compile raised a SyntaxError out of Ruby's
  # compiler, and with web-console in the bundle (bindex's raise hook) that
  # crashed the server. A file whose class body names its constant requires
  # it too, through the autoload.
  describe "a file that does not compile" do
    let(:dir) { Dir.mktmpdir }
    let(:loader) { Zeitwerk::Loader.new.tap { |l| l.push_dir(dir); l.setup } }

    before do
      File.write(File.join(dir, "zz_parent.rb"), "class ZzParent\n  def broken(\nend\n")
      File.write(File.join(dir, "zz_child.rb"), "class ZzChild < ZzParent\nend\n")
      File.write(File.join(dir, "zz_grandchild.rb"), "class ZzGrandchild < ZzChild\nend\n")
      File.write(File.join(dir, "zz_bystander.rb"), "class ZzBystander\n  def parent = ZzParent\nend\n")
      allow(RailsAiContext::PathResolver).to receive(:dirs_for).and_return([ dir ])
      allow(Rails.autoloaders).to receive(:main).and_return(loader)
      allow(RailsAiContext).to receive(:log_warn)
    end

    # Without reloading enabled, unload leaves what was loaded defined.
    after do
      loader.unload
      loader.unregister if loader.respond_to?(:unregister)
      %i[ZzParent ZzChild ZzGrandchild ZzBystander].each { |name| Object.send(:remove_const, name) if Object.const_defined?(name, false) }
      FileUtils.remove_entry(dir)
    end

    def syntax_errors_raised
      raised = []
      trace = TracePoint.new(:raise) { |tp| raised << tp.raised_exception if tp.raised_exception.is_a?(SyntaxError) }
      trace.enable { yield }
      raised
    end

    it "is never required, nor is a file whose class body needs it, and the rest loads" do
      raised = syntax_errors_raised { described_class.dir(dir, kind: "app/models") }

      expect(raised).to be_empty
      expect([ Object.autoload?(:ZzParent), Object.autoload?(:ZzChild), Object.autoload?(:ZzGrandchild) ]).to all(be_a(String))
      expect(Object.autoload?(:ZzBystander)).to be_nil
      expect(Object.const_defined?(:ZzBystander, false)).to be true
    end

    it "says why each was left out, once for each version of the file" do
      2.times { described_class.dir(dir, kind: "app/models") }

      expect(RailsAiContext).to have_received(:log_warn)
        .with(a_string_matching(/Left unloaded: \S*zz_parent\.rb:3: syntax error, unexpected 'end'/)).once
      expect(RailsAiContext).to have_received(:log_warn)
        .with(a_string_matching(/Left unloaded: \S*zz_child\.rb needs ZzParent, which does not compile: \S*zz_parent\.rb:3:/)).once
      expect(RailsAiContext).to have_received(:log_warn)
        .with(a_string_matching(/Left unloaded: \S*zz_grandchild\.rb needs ZzChild, which needs a file that does not compile: \S*zz_parent\.rb:3:/)).once
    end

    # After a reload every file is unloaded again; only an edited one costs a read.
    it "reads a file again only once its stat changes" do
      Dir.glob(File.join(dir, "*.rb")).each { |file| File.utime(Time.now - 60, Time.now - 60, file) }
      allow(Prism).to receive(:parse_file_success?).and_call_original

      2.times { described_class.dir(dir, kind: "app/models") }
      expect(Prism).to have_received(:parse_file_success?).with(File.join(dir, "zz_child.rb"), any_args).once

      File.write(File.join(dir, "zz_child.rb"), "class ZzChild < ZzParent\n  X = 1\nend\n")
      described_class.dir(dir, kind: "app/models")
      expect(Prism).to have_received(:parse_file_success?).with(File.join(dir, "zz_child.rb"), any_args).twice
    end

    it "loads the file once it compiles" do
      described_class.dir(dir, kind: "app/models")
      File.write(File.join(dir, "zz_parent.rb"), "class ZzParent\nend\n")

      described_class.dir(dir, kind: "app/models")

      expect([ Object.autoload?(:ZzParent), Object.autoload?(:ZzChild), Object.autoload?(:ZzGrandchild) ]).to all(be_nil)
      expect(ZzGrandchild.superclass.superclass.name).to eq("ZzParent")
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
  # Zeitwerk before 2.6.9 has no cpath_expected_at, and a record's path_name
  # for app/ reads app/services/x_mailer.rb as Services::XMailer.
  describe ".files without cpath_expected_at" do
    it "loads the class the file declares" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "zz_declared_mailer.rb")
        source = "class ZzDeclaredMailer; end\n"
        File.write(path, source)
        Object.autoload(:ZzDeclaredMailer, path)
        allow(Rails.autoloaders).to receive(:main).and_return(Object.new)
        record = RailsAiContext::Introspectors::SourceScan::Record.new(
          path: path, file: "app/services/zz_declared_mailer.rb", path_name: "Services::ZzDeclaredMailer", source: source
        )

        described_class.files([ record ])

        expect(Object.autoload?(:ZzDeclaredMailer)).to be_nil
        expect(Object.const_defined?(:ZzDeclaredMailer, false)).to be true
      ensure
        Object.send(:remove_const, :ZzDeclaredMailer) if Object.const_defined?(:ZzDeclaredMailer, false)
      end
    end
  end
end
