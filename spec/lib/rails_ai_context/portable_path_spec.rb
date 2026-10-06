# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe RailsAiContext::PortablePath do
  let(:gem_root) { File.join(Gem.path.first, "gems") }

  describe ".relativize" do
    it "makes an app path app-relative" do
      expect(described_class.relativize("/srv/blog/app/models", "/srv/blog")).to eq("app/models")
    end

    it "keeps the gem and version and drops the install prefix" do
      path = File.join(gem_root, "doorkeeper-5.9.5", "app", "controllers")

      expect(described_class.relativize(path, "/srv/blog")).to eq("doorkeeper-5.9.5/app/controllers")
    end

    it "leaves a path that belongs to neither alone" do
      expect(described_class.relativize("/opt/shared/lib", "/srv/blog")).to eq("/opt/shared/lib")
    end

    it "does not treat a sibling directory as the app root" do
      expect(described_class.relativize("/srv/blog-staging/app", "/srv/blog")).to eq("/srv/blog-staging/app")
    end

    it "accepts a Pathname" do
      expect(described_class.relativize(Pathname.new("/srv/blog/lib"), Pathname.new("/srv/blog"))).to eq("lib")
    end
  end

  describe ".relativize_marked" do
    it "marks a gem path, which no app root resolves" do
      path = File.join(gem_root, "doorkeeper-5.9.5", "app", "models", "access_grant.rb")

      expect(described_class.relativize_marked(path, "/srv/blog"))
        .to eq("gem:doorkeeper-5.9.5/app/models/access_grant.rb")
    end

    it "leaves an app path unmarked" do
      expect(described_class.relativize_marked("/srv/blog/app/models/user.rb", "/srv/blog"))
        .to eq("app/models/user.rb")
    end

    it "leaves a path that belongs to neither unmarked" do
      expect(described_class.relativize_marked("/opt/shared/lib/thing.rb", "/srv/blog"))
        .to eq("/opt/shared/lib/thing.rb")
    end
  end

  # The marker existed with a writer and no reader, so every consumer joined a
  # gem-owned path to the app root and opened nothing.
  describe "a file of the gem the app sits inside" do
    it "is the app's own source, relative to the root whichever spelling either path uses" do
      Dir.mktmpdir do |dir|
        engine = File.join(File.realpath(dir), "engine")
        FileUtils.mkdir_p([ File.join(engine, "app/models"), File.join(engine, "test/dummy") ])
        File.write(File.join(engine, "app/models/widget.rb"), "")
        link = File.join(File.realpath(dir), "link")
        File.symlink(engine, link)
        spec = double("Gem::Specification", full_gem_path: link, full_name: "engine-0.1.0", default_gem?: false)
        allow(Gem).to receive(:loaded_specs).and_return("engine" => spec)
        root = File.join(link, "test/dummy")

        expect(described_class.relativize_marked(File.join(engine, "app/models/widget.rb"), root)).to eq("../../app/models/widget.rb")
        expect(described_class.relativize_marked(File.join(link, "app/models/widget.rb"), root)).to eq("../../app/models/widget.rb")
        expect(described_class.resolve("../../app/models/widget.rb", root)).to eq(File.join(root, "../../app/models/widget.rb"))
        expect(described_class.relativize("/opt/shared/lib", root)).to eq("/opt/shared/lib")
      end
    end
  end

  describe ".resolve" do
    it "sends a marked path back to the gem it names, not to the app root" do
      path = File.join(gem_root, "doorkeeper-5.9.5", "app", "models", "access_grant.rb")
      marked = described_class.relativize_marked(path, "/srv/blog")

      expect(described_class.resolve(marked, "/srv/blog")).to eq(path)
    end

    it "resolves an app path against the app root" do
      expect(described_class.resolve("app/models/user.rb", "/srv/blog"))
        .to eq("/srv/blog/app/models/user.rb")
    end

    it "leaves an absolute path alone" do
      expect(described_class.resolve("/opt/shared/lib/thing.rb", "/srv/blog"))
        .to eq("/opt/shared/lib/thing.rb")
    end

    it "answers nothing for nothing" do
      expect(described_class.resolve(nil, "/srv/blog")).to be_nil
      expect(described_class.resolve("", "/srv/blog")).to be_nil
    end
  end

  describe ".gem_checkouts" do
    # The gem under test is loaded from this checkout rather than unpacked
    # under a gem root, which is the shape a Gemfile `path:` entry produces.
    it "names a gem that lives outside every gem root" do
      own = described_class.gem_checkouts.find { |_dir, name| name.start_with?("rails-ai-context-") }
      skip "rails-ai-context is installed under a gem root here" unless own

      dir, name = own
      expect(dir).to end_with(File::SEPARATOR)
      expect(described_class.relativize(File.join(dir, "app/controllers"), "/srv/blog"))
        .to eq("#{name}/app/controllers")
    end

    # The list was kept from the first call, so one taken while a gem set
    # was stubbed, or before a gem was activated, outlived it and left this
    # checkout's own files spelled as absolute paths.
    it "follows the set of loaded gems rather than the one it first saw" do
      real = Gem.loaded_specs
      spec = double("Gem::Specification", full_gem_path: "/opt/engine", full_name: "engine-0.1.0", default_gem?: false)
      allow(Gem).to receive(:loaded_specs).and_return("engine" => spec)
      expect(described_class.gem_checkouts).to eq([ [ "/opt/engine/", "engine-0.1.0" ] ])

      allow(Gem).to receive(:loaded_specs).and_return(real)
      expect(described_class.gem_checkouts.map(&:last)).not_to include("engine-0.1.0")
    end

    it "lists no checkout that a gem root already covers" do
      dirs = described_class.gem_checkouts.map(&:first)

      expect(dirs.select { |dir| described_class.gem_roots.any? { |root| dir.start_with?(root) } }).to be_empty
    end
  end

  describe ".relativize_all" do
    it "reports a path once even when several railties contributed it" do
      paths = [ "/srv/blog/lib", "/srv/blog/lib", "/srv/blog/app/services" ]

      expect(described_class.relativize_all(paths, "/srv/blog")).to eq([ "lib", "app/services" ])
    end
  end

  describe ".relativize_text" do
    it "strips the root where a path starts" do
      text = "cannot load /app/app/models/user.rb:3 (from '/app/lib/x.rb')"

      expect(described_class.relativize_text(text, "/app")).to eq("cannot load app/models/user.rb:3 (from 'lib/x.rb')")
    end

    it "leaves a root that appears inside a longer path alone" do
      engine = "/app/engines/billing/app/models/x.rb:3"
      gem = "/usr/local/bundle/gems/devise-4.9/app/models/devise.rb"

      expect(described_class.relativize_text(engine, "/app")).to eq("engines/billing/app/models/x.rb:3")
      expect(described_class.relativize_text(gem, "/app")).to eq(gem)
    end

    it "strips the resolved root before the root it resolves from" do
      allow(File).to receive(:realpath).and_call_original
      allow(File).to receive(:realpath).with("/tmp/rvw_app").and_return("/private/tmp/rvw_app")
      text = "cannot load /private/tmp/rvw_app/app/models/user.rb:3 or /tmp/rvw_app/lib/a.rb"

      expect(described_class.relativize_text(text, "/tmp/rvw_app")).to eq("cannot load app/models/user.rb:3 or lib/a.rb")
    end

    it "strips the root after = and , and names the bare root as ." do
      expect(described_class.relativize_text("path=/app/a.rb", "/app")).to eq("path=a.rb")
      expect(described_class.relativize_text("a,/app/b.rb", "/app")).to eq("a,b.rb")
      expect(described_class.relativize_text("dir /app", "/app")).to eq("dir .")
      expect(described_class.relativize_text("see /application /app.rb", "/app")).to eq("see /application /app.rb")
    end
  end
end
