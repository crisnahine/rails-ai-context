# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe RailsAiContext::Install::Workspace do
  describe ".server_names" do
    it "names each server after its app's folder" do
      expect(described_class.server_names(%w[api web])).to eq(
        "api" => "rails-ai-context-api", "web" => "rails-ai-context-web"
      )
    end

    # Two apps called web in different folders: the folder name alone would
    # make one entry overwrite the other.
    it "names apps that share a folder name by their whole path" do
      expect(described_class.server_names(%w[client/web admin/web api])).to eq(
        "client/web" => "rails-ai-context-client-web",
        "admin/web" => "rails-ai-context-admin-web",
        "api" => "rails-ai-context-api"
      )
    end

    it "keeps a name when an app with another folder name is added" do
      before = described_class.server_names(%w[api web])
      after = described_class.server_names(%w[api web billing])
      expect(after.slice("api", "web")).to eq(before)
    end

    it "numbers a name that is still taken, in path order" do
      names = described_class.server_names(%w[x/web y/web x-web])
      expect(names.values.uniq.size).to eq(3)
      expect(names["x-web"]).to eq("rails-ai-context-x-web")
      expect(names["x/web"]).to eq("rails-ai-context-x-web-2")
    end

    it "keeps to the characters every client and a bare TOML key accept" do
      names = described_class.server_names([ "my app.v2", "café", "---" ])
      expect(names.values).to all(match(/\Arails-ai-context-[A-Za-z0-9_-]+\z/))
      expect(names["my app.v2"]).to eq("rails-ai-context-my-app-v2")
      expect(names["---"]).to eq("rails-ai-context-app")
    end

    # Clients prefix every tool with its server's name and cap the result.
    it "shortens a long name to fit, staying unique and stable" do
      paths = %w[customer-portal-backend customer-portal-frontend]
      names = described_class.server_names(paths)

      expect(names.values).to all(satisfy { |name| name.size <= described_class::MAX_SERVER_NAME })
      expect(names.values.uniq.size).to eq(2)
      expect(described_class.server_names(paths)).to eq(names)
      expect(names.values).to all(start_with("rails-ai-context-custom"))
    end

    it "fits a numbered name too" do
      long = "a-very-long-application-folder-name"
      names = described_class.server_names([ "x/#{long}", "y/#{long}", "x-#{long}" ])
      expect(names.values.uniq.size).to eq(3)
      expect(names.values).to all(satisfy { |name| name.size <= described_class::MAX_SERVER_NAME })
    end
  end

  describe ".generated_name?" do
    it "knows the names it gives an app, under any set of apps" do
      expect(described_class.generated_name?("rails-ai-context-web", "apps/web")).to be(true)
      expect(described_class.generated_name?("rails-ai-context-apps-web", "apps/web")).to be(true)
      long = "a-very-long-application-folder-name"
      expect(described_class.generated_name?(described_class.server_names([ long ]).fetch(long), long)).to be(true)
    end

    it "does not claim a name made by hand" do
      expect(described_class.generated_name?("rails-ai-context-readonly", "apps/web")).to be(false)
      expect(described_class.generated_name?("rails-ai-context", "apps/web")).to be(false)
      expect(described_class.generated_name?("web", "apps/web")).to be(false)
    end

    it "does not claim a numbered name, which is as likely a second entry made by hand" do
      expect(described_class.generated_name?("rails-ai-context-web-2", "apps/web")).to be(false)
    end
  end

  describe ".apps" do
    around do |example|
      Dir.mktmpdir do |dir|
        @dir = File.realpath(dir)
        example.run
      end
    end

    def app(path, lock_gems: nil)
      root = File.join(@dir, path)
      FileUtils.mkdir_p(File.join(root, "config"))
      if lock_gems
        File.write(File.join(root, "Gemfile"), "")
        specs = lock_gems.map { |name| "    #{name} (1.0.0)\n" }.join
        File.write(File.join(root, "Gemfile.lock"), "GEM\n  remote: https://rubygems.org/\n  specs:\n#{specs}\n")
      end
      root
    end

    it "decides the install mode from each app's own lockfile" do
      standalone = app("a", lock_gems: %w[rails])
      bundled = app("group/b", lock_gems: %w[rails rails-ai-context])

      apps = described_class.apps(@dir, [ standalone, bundled ])

      expect(apps.map(&:path)).to eq(%w[a group/b])
      expect(apps.map(&:standalone)).to eq([ true, false ])
    end

    # A fresh clone has no lockfile yet; a Gemfile that does not name the gem
    # cannot be serving it, so bundle exec would find no binary to run.
    it "reads an app with a Gemfile and no lockfile by what its Gemfile names" do
      without = app("a")
      File.write(File.join(without, "Gemfile"), %(source "https://rubygems.org"\ngem "rails"\n))
      with = app("b")
      File.write(File.join(with, "Gemfile"), %(source "https://rubygems.org"\ngem "rails"\ngem "rails-ai-context"\n))

      expect(described_class.apps(@dir, [ without, with ]).map(&:standalone)).to eq([ true, false ])
    end

    it "points a standalone app's server at it with no Bundler variables" do
      root = app("a", lock_gems: %w[rails])
      server = described_class.apps(@dir, [ root ]).first.server

      expect(server.argv).to eq(%w[rails-ai-context serve --app-path a])
      expect(server.env).to eq("RAILS_AI_CONTEXT_SERVER_NAME" => "a-rails-ai-context")
    end

    # bundle exec looks for a Gemfile upward from where the client starts
    # it, which is the workspace, never the app below.
    it "gives an in-Gemfile app's server its own Gemfile" do
      root = app("group/b", lock_gems: %w[rails rails-ai-context])
      server = described_class.apps(@dir, [ root ]).first.server

      expect(server.argv).to eq(%w[bundle exec rails-ai-context serve --app-path group/b])
      expect(server.env).to eq("BUNDLE_GEMFILE" => "group/b/Gemfile", "RAILS_AI_CONTEXT_SERVER_NAME" => "b-rails-ai-context")
    end

    # VS Code names each tool after the announced name and keeps 13
    # characters of it: rails-ai-cont for every app, were the app not first.
    it "has each server announce its app first, distinct within 13 characters" do
      roots = %w[web api customer-portal-backend].map { |path| app(path, lock_gems: %w[rails]) }
      names = described_class.apps(@dir, roots).map { |a| a.server.announce }

      expect(names.first(2)).to eq(%w[web-rails-ai-context api-rails-ai-context])
      expect(names.last).to match(/\Acustom-[0-9a-f]{6}-rails-ai-context\z/)
      expect(names.map { |name| name[0, 13] }.uniq.size).to eq(3)
    end

    # A monorepo's apps share one bundle, which each app's config/boot.rb
    # names; the app has no Gemfile for bundle exec to find.
    it "gives an app the shared Gemfile its config/boot.rb names" do
      FileUtils.mkdir_p(File.join(@dir, ".git"))
      File.write(File.join(@dir, "Gemfile"), "")
      File.write(File.join(@dir, "Gemfile.lock"), "GEM\n  remote: https://rubygems.org/\n  specs:\n    rails-ai-context (1.0.0)\n\n")
      root = app("apps/a")
      File.write(File.join(root, "config/boot.rb"), %(ENV["BUNDLE_GEMFILE"] ||= File.expand_path("../../../Gemfile", __dir__)\n))

      found = described_class.apps(@dir, [ root ]).first

      expect(found.standalone).to be(false)
      expect(found.gemfile).to eq(File.join(@dir, "Gemfile"))
      expect(found.server.env).to include("BUNDLE_GEMFILE" => "Gemfile")
    end

    # Bundler names the lockfile after the path it is given: the link's,
    # beside which the app's own Gemfile.lock lies.
    it "names a Gemfile linked in from elsewhere by the link" do
      File.write(File.join(@dir, "Gemfile.shared"), "")
      root = app("api", lock_gems: %w[rails rails-ai-context])
      File.delete(File.join(root, "Gemfile"))
      File.symlink(File.join(@dir, "Gemfile.shared"), File.join(root, "Gemfile"))

      expect(described_class.apps(@dir, [ root ]).first.server.env).to include("BUNDLE_GEMFILE" => "api/Gemfile")
    end

    # config/boot.rb's Gemfile is the one the app boots against, read or not.
    it "names the Gemfile config/boot.rb points at outside any git repository" do
      File.write(File.join(@dir, "Gemfile"), "")
      root = app("apps/a")
      File.write(File.join(root, "config/boot.rb"), %(ENV["BUNDLE_GEMFILE"] ||= File.expand_path("../../../Gemfile", __dir__)\n))

      found = described_class.apps(@dir, [ root ]).first

      expect(found.gemfile).to eq(File.join(@dir, "Gemfile"))
      expect(found.server.env).to include("BUNDLE_GEMFILE" => "Gemfile")
    end

    # With nothing naming one, the Gemfile bundle exec run inside the app
    # would find, which may sit above the workspace.
    it "names the Gemfile Bundler's own search finds from inside the app" do
      Dir.mktmpdir do |outer|
        outer = File.realpath(outer)
        File.write(File.join(outer, "Gemfile"), "")
        work = File.join(outer, "apps")
        root = File.join(work, "a")
        FileUtils.mkdir_p(File.join(root, "config"))

        expect(described_class.apps(work, [ root ]).first.server.env).to include("BUNDLE_GEMFILE" => "../Gemfile")
      end
    end

    it "names no Gemfile when there is none to find" do
      root = app("a")
      allow(described_class).to receive(:nearest_gemfile).and_return(nil)

      found = described_class.apps(@dir, [ root ]).first

      expect(found.gemfile).to be_nil
      expect(found.server.env).not_to have_key("BUNDLE_GEMFILE")
    end

    it "names a gems.rb bundle by its own file name" do
      root = app("b")
      File.write(File.join(root, "gems.rb"), "")
      File.write(File.join(root, "gems.locked"), "GEM\n  remote: https://rubygems.org/\n  specs:\n    rails-ai-context (1.0.0)\n\n")

      expect(described_class.apps(@dir, [ root ]).first.server.env).to include("BUNDLE_GEMFILE" => "b/gems.rb")
    end
  end
end
