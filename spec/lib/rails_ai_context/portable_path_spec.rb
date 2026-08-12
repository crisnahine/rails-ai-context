# frozen_string_literal: true

require "spec_helper"

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
end
