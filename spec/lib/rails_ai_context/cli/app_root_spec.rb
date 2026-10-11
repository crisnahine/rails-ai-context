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

  # macOS filesystems refuse a name that is not UTF-8.
  def latin1_app(path)
    app(path)
  rescue Errno::EILSEQ
    skip "this filesystem refuses names that are not UTF-8"
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

  # doctor at an engine's root diagnoses the app the engine's bin/rails boots.
  describe ".dummy_app" do
    def bootable(path)
      app(path).tap { |root| File.write(File.join(root, "config", "environment.rb"), "") }
    end

    def engine(bin_rails = nil)
      dir("engine").tap do |root|
        FileUtils.mkdir_p(File.join(root, "bin"))
        File.write(File.join(root, "bin", "rails"), bin_rails) if bin_rails
      end
    end

    it "finds the dummy app the engine's bin/rails names" do
      root = engine(%(ENGINE_ROOT = File.expand_path("..", __dir__)\nAPP_PATH = File.expand_path("../spec/internal/config/application", __dir__)\n))
      bootable("engine/test/dummy")
      named = bootable("engine/spec/internal")

      expect(described_class.dummy_app(root)).to eq(named)
    end

    it "finds test/dummy, then spec/dummy, when bin/rails names none" do
      root = engine
      spec_dummy = bootable("engine/spec/dummy")
      expect(described_class.dummy_app(root)).to eq(spec_dummy)

      test_dummy = bootable("engine/test/dummy")
      expect(described_class.dummy_app(root)).to eq(test_dummy)
    end

    it "is nil for an app that boots itself, and for a root with no dummy app" do
      expect(described_class.dummy_app(bootable("shop"))).to be_nil
      expect(described_class.dummy_app(engine)).to be_nil
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
        "Error: #{cwd} is no Rails app, and holds 2 below it. Name one with --app-path:",
        "  rails-ai-context --app-path a tool schema",
        "  rails-ai-context --app-path b tool schema"
      ])
    end

    # As a person types it: letters outside ASCII as they are, a word a
    # shell would split or expand in single quotes, `=` as itself after the
    # command's name. A folder named in another encoding is escaped byte by
    # byte, not refused, and a path that starts with a dash is spelled from
    # here, where it would read as an option.
    it "writes each command the way a shell reads it" do
      app("work/a b")
      app("work/\u0448\u043e\u043f")
      app("work/-api")
      latin1_app("work/caf\xE9".b)
      cwd = File.join(tmp, "work")
      lines = described_class.several_apps(described_class.resolve(cwd: cwd), cwd, %w[tool search_code pattern=x$y])

      expect(lines).to include("  rails-ai-context --app-path ./-api tool search_code 'pattern=x$y'")
      expect(lines).to include("  rails-ai-context --app-path 'a b' tool search_code 'pattern=x$y'")
      expect(lines).to include("  rails-ai-context --app-path \u0448\u043e\u043f tool search_code 'pattern=x$y'")
      expect(lines.map(&:b)).to include("  rails-ai-context --app-path caf\\\xE9 tool search_code pattern=x\\$y".b)
    end

    # Names that are no UTF-8 are directories all the same.
    it "walks up from, and down to, a folder whose name is not UTF-8" do
      root = latin1_app("caf\xE9".b)
      nested = File.join(root, "app/models")

      expect(described_class.resolve(cwd: nested.dup.force_encoding(Encoding::UTF_8)).root.b).to eq(root.b)
      expect(described_class.resolve(cwd: tmp.dup.force_encoding(Encoding::UTF_8)).root.b).to eq(root.b)
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

      # A monorepo's apps have no Gemfile; their config/boot.rb names the
      # shared one, wherever it sits.
      it "says nothing for the bundle an app's config/boot.rb names" do
        root = app("mono/apps/web")
        FileUtils.mkdir_p(File.join(tmp, "mono/gems"))
        File.write(File.join(tmp, "mono/gems/Gemfile"), "")
        File.write(File.join(root, "config/boot.rb"), %(ENV["BUNDLE_GEMFILE"] ||= File.expand_path("../../../gems/Gemfile", __dir__)\n))
        under_bundle(File.join(tmp, "mono/gems/Gemfile"))

        expect(described_class.bundle_warning(root, tmp)).to be_nil
      end

      # ENV hands Bundler's path back tagged binary in a C locale, whatever
      # the binary made the default; the warning must not fail to join it.
      it "warns when the bundle's path and the app's both hold text outside ASCII" do
        root = app("caf\u00e9/tiend\u00e1")
        File.write(File.join(root, "Gemfile"), "")
        other = File.join(tmp, "caf\u00e9/other/Gemfile")
        FileUtils.mkdir_p(File.dirname(other))
        File.write(other, "")
        stub_const("ENV", ENV.to_h.merge("BUNDLE_BIN_PATH" => "/usr/bin/bundle"))
        allow(Bundler).to receive(:default_gemfile).and_return(Pathname.new(other.b))

        expect(described_class.bundle_warning(root, File.join(tmp, "caf\u00e9"))).to include("tiend\u00e1/ boots against the bundle of")
      end

      it "names the app it stands in plainly" do
        root = app("shop")
        File.write(File.join(root, "Gemfile"), "")
        File.write(File.join(tmp, "Gemfile"), "")
        under_bundle(File.join(tmp, "Gemfile"))

        warning = described_class.bundle_warning(root, root)
        expect(warning).to start_with("[rails-ai-context] WARNING: This app boots against")
        expect(warning).not_to include("from inside the app")
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

    describe ".bundled_handoff" do
      def locked_from(root, source)
        File.write(File.join(root, "Gemfile"), %(gem "rails-ai-context"\n))
        File.write(File.join(root, "Gemfile.lock"), "#{source}\nPLATFORMS\n  ruby\n\nDEPENDENCIES\n  rails-ai-context!\n")
      end

      def path_copy(path)
        dir(path).tap { |copy| File.write(File.join(copy, "rails-ai-context.gemspec"), "") }
      end

      before { stub_const("ENV", ENV.to_h.except("BUNDLE_BIN_PATH", "BUNDLE_GEMFILE", described_class::HANDOFF_ENV)) }

      # Two copies in one process: this one's files load before the boot,
      # the bundle's over them.
      it "hands the command to the bundle's own copy, found where its lockfile names it" do
        root = app("shop")
        copy = path_copy("vendor/rails-ai-context")
        locked_from(root, "PATH\n  remote: ../vendor/rails-ai-context\n  specs:\n    rails-ai-context (5.0.0)\n")

        handoff = described_class.bundled_handoff(root)

        expect(handoff.version).to eq("5.0.0")
        expect(handoff.env).to eq("BUNDLE_GEMFILE" => File.join(root, "Gemfile"), described_class::HANDOFF_ENV => "1")
        expect(File.directory?(copy)).to be true
      end

      # A dual boot's Gemfile.next is named by BUNDLE_GEMFILE, as for bundle exec.
      it "reads the bundle a BUNDLE_GEMFILE someone set names, and keeps it" do
        root = app("shop")
        path_copy("vendor/rails-ai-context")
        locked_from(root, "GEM\n  remote: https://rubygems.org/\n  specs:\n    rails-ai-context (0.0.1)\n")
        File.write(File.join(root, "Gemfile.next"), %(gem "rails-ai-context", path: "../vendor/rails-ai-context"\n))
        File.write(File.join(root, "Gemfile.next.lock"),
                   "PATH\n  remote: ../vendor/rails-ai-context\n  specs:\n    rails-ai-context (5.0.0)\n\nPLATFORMS\n  ruby\n\n" \
                   "DEPENDENCIES\n  rails-ai-context!\n")
        stub_const("ENV", ENV.to_h.merge("BUNDLE_GEMFILE" => File.join(root, "Gemfile.next")))

        handoff = described_class.bundled_handoff(root)

        expect(handoff.version).to eq("5.0.0")
        expect(handoff.env["BUNDLE_GEMFILE"]).to eq(File.join(root, "Gemfile.next"))
      end

      it "runs on when the bundle's copy is this one, or this run is already the bundle's" do
        root = app("shop")
        locked_from(root, "PATH\n  remote: #{described_class::OWN_COPY}\n  specs:\n    rails-ai-context (5.0.0)\n")
        expect(described_class.bundled_handoff(root)).to be_nil

        path_copy("vendor/rails-ai-context")
        locked_from(root, "PATH\n  remote: ../vendor/rails-ai-context\n  specs:\n    rails-ai-context (5.0.0)\n")
        stub_const("ENV", ENV.to_h.merge("BUNDLE_BIN_PATH" => "/usr/bin/bundle"))
        expect(described_class.bundled_handoff(root)).to be_nil
        stub_const("ENV", ENV.to_h.except("BUNDLE_BIN_PATH").merge(described_class::HANDOFF_ENV => "1"))
        expect(described_class.bundled_handoff(root)).to be_nil
      end

      # A bundle not installed yet fails to boot, which the static tier
      # answers; bundle exec would only fail.
      it "runs on when the bundle's copy is not installed, or the bundle holds none" do
        root = app("shop")
        locked_from(root, "GEM\n  remote: https://rubygems.org/\n  specs:\n    rails-ai-context (0.0.1)\n")
        expect(described_class.bundled_handoff(root)).to be_nil

        locked_from(root, "PATH\n  remote: ../nowhere\n  specs:\n    rails-ai-context (5.0.0)\n")
        expect(described_class.bundled_handoff(root)).to be_nil

        locked_from(root, "GEM\n  remote: https://rubygems.org/\n  specs:\n    rails (8.0.0)\n")
        expect(described_class.bundled_handoff(root)).to be_nil
      end
    end

    # bundle exec fails where a gem the app locks is not installed, as in a
    # repo cloned and not yet bundled; this copy answers from source there.
    describe ".bundle_ready?" do
      def bundle_standing_in(name, body)
        File.join(tmp, name).tap { |path| File.write(path, body) }
      end

      it "is what bundle check answers, asked to write nothing" do
        seen = File.join(tmp, "argv")
        ready = bundle_standing_in("ready", %(File.write(#{seen.inspect}, ARGV.join(" ")); exit 0\n))
        missing = bundle_standing_in("missing", %(exit 1\n))

        expect(described_class.bundle_ready?({}, tmp, bundle: ready)).to be(true)
        expect(File.read(seen)).to eq("check --dry-run")
        expect(described_class.bundle_ready?({}, tmp, bundle: missing)).to be(false)
      end

      # A Gemfile edited since its lock sends Bundler to the network.
      it "gives up on a check that runs past its time, and leaves no process behind" do
        pid_file = File.join(tmp, "pid")
        slow = bundle_standing_in("slow", %(File.write(#{pid_file.inspect}, Process.pid.to_s); sleep 30\n))

        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        expect(described_class.bundle_ready?({}, tmp, bundle: slow, seconds: 0.5)).to be(false)
        expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 5
        expect { Process.kill(0, File.read(pid_file).to_i) }.to raise_error(Errno::ESRCH)
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
