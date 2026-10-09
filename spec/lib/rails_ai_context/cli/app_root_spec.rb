# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "rails_ai_context/cli/app_root"

RSpec.describe RailsAiContext::CLI::AppRoot do
  # mktmpdir can hand back a symlinked path (macOS /var); Dir.pwd never does.
  around do |example|
    Dir.mktmpdir do |dir|
      @tmp = File.realpath(dir)
      example.run
    end
  end

  let(:tmp) { @tmp }

  def app(path)
    dir = File.join(tmp, path)
    FileUtils.mkdir_p(File.join(dir, "config"))
    FileUtils.mkdir_p(File.join(dir, "app", "models"))
    File.write(File.join(dir, "config", "application.rb"), "module X\n  class Application < Rails::Application\n  end\nend\n")
    dir
  end

  def dir(path)
    File.join(tmp, path).tap { |d| FileUtils.mkdir_p(d) }
  end

  describe ".resolve" do
    it "keeps the current directory when it is an app" do
      root = app("shop")
      result = described_class.resolve(cwd: root)
      expect([ result.root, result.walked, result.workspace? ]).to eq([ root, nil, false ])
    end

    it "walks up from a subdirectory to the app root" do
      root = app("shop")
      result = described_class.resolve(cwd: dir("shop/app/models"))
      expect([ result.root, result.walked, result.workspace? ]).to eq([ root, :up, false ])
    end

    # A pack has app/ and passes the looser test a command applies to the
    # directory it stands in; the walk must not stop there.
    it "walks past a packwerk pack to the host app" do
      root = app("shop")
      dir("shop/packs/billing/app/models")
      File.write(File.join(root, "packs/billing/app/models/invoice.rb"), "class Invoice; end\n")

      expect(described_class.resolve(cwd: dir("shop/packs/billing/app/models")).root).to eq(root)
    end

    # A pack has app/ and nothing else; standing in its root still means the
    # host app, the way it does from any directory inside it.
    it "takes a pack's root for the host app" do
      root = app("shop")
      FileUtils.mkdir_p(File.join(root, "packs/billing/app/models"))
      File.write(File.join(root, "packs/billing/app/models/invoice.rb"), "class Invoice; end\n")

      result = described_class.resolve(cwd: File.join(root, "packs/billing"))
      expect([ result.root, result.walked ]).to eq([ root, :up ])
    end

    it "keeps a tree of source alone when no app holds it" do
      engine = dir("engine")
      FileUtils.mkdir_p(File.join(engine, "app/models"))
      File.write(File.join(engine, "app/models/widget.rb"), "class Widget; end\n")

      expect(described_class.resolve(cwd: engine).root).to eq(engine)
    end

    it "lands an engine's dummy app on the dummy app" do
      app("engine")
      dummy = app("engine/spec/dummy")
      expect(described_class.resolve(cwd: dir("engine/spec/dummy/app/models")).root).to eq(dummy)
    end

    it "lands an engine's spec directory on the engine, by its bin/rails" do
      engine = dir("engine")
      dir("engine/bin")
      File.write(File.join(engine, "bin/rails"), "ENGINE_PATH = File.expand_path('../lib/engine/engine', __dir__)\n")
      expect(described_class.resolve(cwd: dir("engine/spec")).root).to eq(engine)
    end

    it "ignores a bin/rails that boots neither an app nor an engine" do
      dir("tool/bin")
      File.write(File.join(tmp, "tool/bin/rails"), "puts 'hi'\n")
      expect(described_class.resolve(cwd: dir("tool/lib")).root).to be_nil
    end

    it "walks past an app vendored under node_modules or vendor/bundle" do
      root = app("shop")
      app("shop/node_modules/pkg")
      app("shop/vendor/bundle/ruby/3.4.0/gems/thing")

      expect(described_class.resolve(cwd: dir("shop/node_modules/pkg/lib")).root).to eq(root)
      expect(described_class.resolve(cwd: dir("shop/vendor/bundle/ruby/3.4.0/gems/thing/lib")).root).to eq(root)
    end

    # GEM_PATH=":$HOME/.gem" puts an empty entry in Gem.path.
    it "is not thrown off by an empty Gem.path entry" do
      root = app("shop")
      allow(Gem).to receive(:path).and_return([ "", "relative/gems", File.join(tmp, "gems") ])
      expect(described_class.resolve(cwd: dir("shop/app/models")).root).to eq(root)
    end

    it "never takes $HOME as the app" do
      home = app("home")
      allow(Dir).to receive(:home).and_return(home)
      expect(described_class.resolve(cwd: dir("home/projects")).root).to be_nil
    end

    it "uses the one app below the current directory" do
      root = app("work/a")
      result = described_class.resolve(cwd: dir("work"))
      expect([ result.root, result.walked, result.below, result.workspace? ]).to eq([ root, :down, [ root ], true ])
    end

    it "names every app below when there are several, and picks none" do
      a = app("work/a")
      b = app("work/group/b")
      result = described_class.resolve(cwd: dir("work"))
      expect([ result.root, result.walked, result.workspace? ]).to eq([ nil, nil, true ])
      expect(result.below).to eq([ a, b ])
    end

    it "never walks an explicit --app-path" do
      app("shop")
      models = dir("shop/app/models")
      result = described_class.resolve(cwd: tmp, app_path: "shop/app/models")
      expect([ result.root, result.walked, result.explicit ]).to eq([ models, nil, true ])
    end
  end

  describe ".walk_down" do
    it "skips hidden directories, deeper levels, and node_modules, vendor and tmp" do
      app("work/.claude/worktrees/x")
      app("work/a/b/c")
      app("work/node_modules/x")
      app("work/vendor/x")
      app("work/tmp/x")
      expect(described_class.walk_down(dir("work"))).to eq([])
    end

    it "names an app reached through a symlink once" do
      a = app("work/a")
      File.symlink(a, File.join(tmp, "work/current"))
      expect(described_class.walk_down(dir("work"))).to eq([ a ])
    end

    it "leaves out an app nested inside another" do
      a = app("work/a")
      app("work/a/inner")
      expect(described_class.walk_down(dir("work"))).to eq([ a ])
    end

    # Two levels down from /Users reach ~/Documents, and on macOS listing it
    # raises a folder-access prompt.
    it "never lists a directory above $HOME" do
      home = dir("users/me")
      app("users/me/shop")
      app("users/other")
      allow(Dir).to receive(:home).and_return(home)
      expect(described_class.walk_down(File.join(tmp, "users"))).to eq([])
    end

    it "never lists $HOME or the filesystem root" do
      home = dir("home")
      app("home/a")
      allow(Dir).to receive(:home).and_return(home)
      expect(described_class.walk_down(home)).to eq([])
      expect(described_class.walk_down("/")).to eq([])
    end
  end

  describe "the lines the binary relays" do
    it "says which app a walk chose, relative when it is below" do
      root = app("work/a")
      result = described_class.resolve(cwd: dir("work"))
      expect(described_class.notice(result, File.join(tmp, "work"))).to eq("[rails-ai-context] using app at a/")
      expect(described_class.notice(result, File.join(root, "app"))).to eq("[rails-ai-context] using app at #{root}/")
    end

    it "gives each app found below the exact command to run" do
      app("work/a")
      app("work/b")
      cwd = File.join(tmp, "work")
      lines = described_class.several_apps(described_class.resolve(cwd: cwd), cwd, %w[tool schema])
      expect(lines).to eq([
        "Error: No Rails app found in #{cwd}, and 2 below it. Name one with --app-path:",
        "  rails-ai-context --app-path a tool schema",
        "  rails-ai-context --app-path b tool schema"
      ])
    end

    # A client launched inside one app still reads the workspace's config
    # above it, and starts the server where it was launched.
    it "names the folder a relative --app-path was written for" do
      app("work/a")
      launched = dir("work/b/app")

      expect(described_class.relative_path_hint("a", launched))
        .to eq("--app-path a is read from #{launched}; it names an app from #{File.join(tmp, 'work')}. " \
               "A workspace's MCP configs expect the client to be started in the workspace folder.")
      expect(described_class.relative_path_hint("missing", launched)).to be_nil
      expect(described_class.relative_path_hint(File.join(tmp, "work/a"), launched)).to be_nil
      expect(described_class.relative_path_hint(nil, launched)).to be_nil
    end

    describe ".bundle_warning" do
      def under_bundle(gemfile)
        stub_const("ENV", ENV.to_h.merge("BUNDLE_BIN_PATH" => "/usr/bin/bundle"))
        allow(Bundler).to receive(:default_gemfile).and_return(Pathname.new(gemfile))
      end

      it "says nothing outside bundle exec, or for the app whose Gemfile bundle exec loaded" do
        root = app("work/shop")
        File.write(File.join(root, "Gemfile"), "")
        stub_const("ENV", ENV.to_h.except("BUNDLE_BIN_PATH"))
        expect(described_class.bundle_warning(root, tmp)).to be_nil

        under_bundle(File.join(root, "Gemfile"))
        expect(described_class.bundle_warning(root, tmp)).to be_nil
      end

      # A folder of apps with a bundle of its own: the app is inside that
      # bundle's directory and still not its app.
      it "warns for an app whose own Gemfile is not the one bundle exec loaded" do
        root = app("work/shop")
        File.write(File.join(root, "Gemfile"), "")
        File.write(File.join(tmp, "work/Gemfile"), "")
        under_bundle(File.join(tmp, "work/Gemfile"))

        expect(described_class.bundle_warning(root, File.join(tmp, "work")))
          .to start_with("[rails-ai-context] WARNING: shop/ boots against the bundle of #{File.join(tmp, 'work/Gemfile')}")
      end

      # Bundler names the Gemfile it found in the app; the link is followed
      # only to compare it.
      it "says nothing for an app whose Gemfile links to a shared one" do
        root = app("work/shop")
        File.write(File.join(tmp, "work/Gemfile.shared"), "")
        File.symlink(File.join(tmp, "work/Gemfile.shared"), File.join(root, "Gemfile"))

        under_bundle(File.join(root, "Gemfile"))
        expect(described_class.bundle_warning(root, tmp)).to be_nil

        under_bundle(File.join(tmp, "work/Gemfile.shared"))
        expect(described_class.bundle_warning(root, tmp)).to be_nil
      end

      # Dual boot (Gemfile.next) and Appraisal (gemfiles/rails_7_1.gemfile)
      # keep a second bundle inside the app.
      it "says nothing for a bundle whose Gemfile is inside the app" do
        root = app("shop")
        File.write(File.join(root, "Gemfile"), "")
        File.write(File.join(root, "Gemfile.next"), "")
        under_bundle(File.join(root, "Gemfile.next"))

        expect(described_class.bundle_warning(root, tmp)).to be_nil
      end

      it "warns for an app with no Gemfile outside the bundle's directory, and not inside it" do
        inside = app("work/engine/spec/dummy")
        outside = app("other")
        File.write(File.join(tmp, "work/engine/Gemfile"), "")
        under_bundle(File.join(tmp, "work/engine/Gemfile"))

        expect(described_class.bundle_warning(inside, tmp)).to be_nil
        expect(described_class.bundle_warning(outside, tmp)).to include("boots against the bundle of")
      end
    end

    it "names the app above a wrong --app-path" do
      root = app("shop")
      models = dir("shop/app/models")
      expect(described_class.app_above_hint(models, tmp))
        .to eq("#{models} is inside the app at shop: pass --app-path shop")
      expect(described_class.app_above_hint(root, tmp)).to be_nil
    end
  end
end
