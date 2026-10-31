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

  # What a session started in a folder gets: one app, the apps it reaches, or a reason for neither.
  describe ".target" do
    def monorepo(path, boots:)
      root = dir(path)
      dir("#{path}/bin")
      File.write(File.join(root, "bin", "rails"), %(APP_PATH = File.expand_path("../#{boots}/config/application", __dir__)\nrequire "rails/commands"\n))
      root
    end

    def described(target)
      case target.kind
      when :app then [ :app, target.root ]
      when :apps then [ :apps, target.apps.map { |found| [ found.name, found.root ] } ]
      else [ :none, target.reason ]
      end
    end

    it "answers each start folder with the app, the apps or why neither" do
      shop = app("one/shop")
      FileUtils.mkdir_p(File.join(shop, "packs/billing/app/models"))
      File.write(File.join(shop, "packs/billing/app/models/invoice.rb"), "class Invoice; end\n")
      alpha = app("two/alpha")
      beta = app("two/beta")
      deep_alpha = app("deep/apps/alpha")
      deep_beta = app("deep/apps/beta")
      mixed_alpha = app("mixed/alpha")
      mixed_beta = app("mixed/svc/beta")
      web = app("mono/apps/web")
      app("mono/apps/admin")
      monorepo("mono", boots: "apps/web")
      engine = monorepo("engine", boots: "nowhere").tap do |root|
        File.write(File.join(root, "bin", "rails"), %(ENGINE_PATH = File.expand_path("../lib/eng/engine", __dir__)\n))
        dir("engine/lib/eng")
        File.write(File.join(root, "lib", "eng.rb"), "module Eng; end\n")
        dir("engine/app/assets")
      end
      cafe = app("café")
      empty = dir("empty")

      table = {
        shop => [ :app, shop ],
        File.join(shop, "app", "models") => [ :app, shop ],
        File.join(shop, "packs", "billing") => [ :app, shop ],
        File.join(tmp, "one") => [ :app, shop ],
        File.join(tmp, "two") => [ :apps, [ [ "alpha", alpha ], [ "beta", beta ] ] ],
        File.join(tmp, "deep") => [ :apps, [ [ "alpha", deep_alpha ], [ "beta", deep_beta ] ] ],
        File.join(tmp, "mixed") => [ :apps, [ [ "alpha", mixed_alpha ], [ "beta", mixed_beta ] ] ],
        File.join(tmp, "mono") => [ :app, web ],
        File.join(tmp, "mono", "docs").tap { |path| FileUtils.mkdir_p(path) } => [ :app, web ],
        engine => [ :none, "#{engine} has a bin/rails but no app source: no config/application.rb, config/environment.rb or app/**/*.rb." ],
        empty => [ :none, "#{empty} holds no Rails app." ],
        cafe => [ :app, cafe ]
      }
      expect(table.keys.to_h { |folder| [ folder, described(described_class.target(folder)) ] }).to eq(table)
    end

    it "takes the bin/rails app only where it lies below the folder" do
      root = monorepo("mono", boots: "../outside")
      app("outside")
      expect(described(described_class.target(root))).to eq([ :none, "#{root} has a bin/rails but no app source: " \
                                                                       "no config/application.rb, config/environment.rb or app/**/*.rb." ])
    end

    it "takes the app an engine's bin/rails names from __FILE__, as Rails 5.1 wrote it" do
      root = dir("engine")
      dir("engine/bin")
      File.write(File.join(root, "bin", "rails"), "ENGINE_ROOT = File.expand_path('../..', __FILE__)\n" \
                                                  "APP_PATH = File.expand_path('../../spec/internal/config/application', __FILE__)\n")
      app("engine/test/dummy")
      named = app("engine/spec/internal")

      expect(described(described_class.target(root))).to eq([ :app, named ])
    end

    it "takes test/dummy, then spec/dummy, at an engine root whose bin/rails names no app, as Rails 4.2 and 5.0 wrote it" do
      root = dir("engine")
      dir("engine/bin")
      File.write(File.join(root, "bin", "rails"), "ENGINE_ROOT = File.expand_path('../..', __FILE__)\n" \
                                                  "ENGINE_PATH = File.expand_path('../../lib/eng/engine', __FILE__)\n")
      spec_dummy = app("engine/spec/dummy")
      expect(described(described_class.target(root))).to eq([ :app, spec_dummy ])

      test_dummy = app("engine/test/dummy")
      expect(described(described_class.target(root))).to eq([ :app, test_dummy ])
      expect(described(described_class.target(dir("engine/lib")))).to eq([ :app, test_dummy ])
    end

    it "serves nothing from the home folder or the filesystem root" do
      home = dir("home")
      app("home/shop")
      app("home/projects/admin")
      allow(Dir).to receive(:home).and_return(home)

      expect(described(described_class.target(home))).to eq([ :none, "#{home} holds no Rails app." ])
      expect(described_class.target("/").kind).to eq(:none)
    end

    it "names two apps that share a folder name by their paths" do
      a = app("work/shop/web")
      b = app("work/admin/web")
      expect(described(described_class.target(dir("work")))).to eq([ :apps, [ [ "admin-web", b ], [ "shop-web", a ] ] ])
    end

    it "keeps the walk the binary relays" do
      shop = app("shop")
      target = described_class.target(dir("shop/app/models"))
      expect([ target.resolution.root, target.resolution.walked ]).to eq([ shop, :up ])

      web = app("mono/apps/web")
      target = described_class.target(monorepo("mono", boots: "apps/web"))
      expect([ target.resolution.root, target.resolution.walked ]).to eq([ web, :down ])
    end
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
    #
    # Windows names files in UTF-16, so no folder there is named in bytes
    # that are not UTF-8: the bytes below would come back as a valid name.
    # There the other three apps are written all the same.
    it "writes each command the way a shell reads it" do
      app("work/a b")
      app("work/\u0448\u043e\u043f")
      app("work/-api")
      latin1 = latin1_app("work/caf\xE9".b) unless Gem.win_platform?
      cwd = File.join(tmp, "work")
      lines = described_class.several_apps(described_class.resolve(cwd: cwd), cwd, %w[tool search_code pattern=x$y])

      expect(lines).to include("  rails-ai-context --app-path ./-api tool search_code 'pattern=x$y'")
      expect(lines).to include("  rails-ai-context --app-path 'a b' tool search_code 'pattern=x$y'")
      expect(lines).to include("  rails-ai-context --app-path \u0448\u043e\u043f tool search_code 'pattern=x$y'")
      expect(lines.map(&:b)).to include("  rails-ai-context --app-path caf\\\xE9 tool search_code pattern=x\\$y".b) if latin1
    end

    # Names that are no UTF-8 are directories all the same.
    it "walks up from, and down to, a folder whose name is not UTF-8" do
      skip "Windows names files in UTF-16, so no folder name on disk is bytes that are not UTF-8" if Gem.win_platform?

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
        stub_const("ENV", ENV.to_h.except("BUNDLE_BIN_PATH", "BUNDLE_GEMFILE"))
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

      context "with BUNDLE_GEMFILE inherited and no bundle exec" do
        def inherited(gemfile, extra = {})
          stub_const("ENV", ENV.to_h.except("BUNDLE_BIN_PATH", "BUNDLE_GEMFILE", "RAILS_AI_CONTEXT_HANDOFF")
                                    .merge("BUNDLE_GEMFILE" => gemfile).merge(extra))
        end

        # config/boot.rb's `||=` keeps the inherited value, so the app boots
        # against that bundle; "run it without bundle exec" would not help.
        it "warns for another project's Gemfile and names the variable" do
          root = app("shop")
          File.write(File.join(root, "Gemfile"), "")
          other = File.join(dir("elsewhere"), "Gemfile")
          File.write(other, "")
          inherited(other)

          expect(described_class.bundle_warning(root, root))
            .to eq("[rails-ai-context] WARNING: This app boots against #{other}, which BUNDLE_GEMFILE names, " \
                   "not its own Gemfile. Unset BUNDLE_GEMFILE, or point it at the app's Gemfile.")
        end

        it "reads a relative value against the current folder, as Bundler does" do
          root = app("shop")
          File.write(File.join(root, "Gemfile"), "")
          File.write(File.join(dir("elsewhere"), "Gemfile"), "")
          inherited("../elsewhere/Gemfile")

          Dir.chdir(root) do
            expect(described_class.bundle_warning(root, root)).to include("#{File.join(tmp, 'elsewhere/Gemfile')}, which BUNDLE_GEMFILE names")
          end
        end

        it "says nothing for the app's own Gemfile, a Gemfile.next inside it, or an empty value" do
          root = app("shop")
          File.write(File.join(root, "Gemfile"), "")
          File.write(File.join(root, "Gemfile.next"), "")

          [ File.join(root, "Gemfile"), File.join(root, "Gemfile.next"), "" ].each do |gemfile|
            inherited(gemfile)
            expect(described_class.bundle_warning(root, tmp)).to be_nil
          end
        end

        it "says nothing for the bundle an app with no Gemfile sits under" do
          root = app("work/engine/spec/dummy")
          File.write(File.join(tmp, "work/engine/Gemfile"), "")
          inherited(File.join(tmp, "work/engine/Gemfile"))

          expect(described_class.bundle_warning(root, tmp)).to be_nil
        end

        # The run that handed off has already warned about the same Gemfile.
        it "says nothing in the run a bundled-copy handoff started" do
          root = app("shop")
          File.write(File.join(root, "Gemfile"), "")
          other = File.join(dir("elsewhere"), "Gemfile")
          File.write(other, "")
          inherited(other, described_class::HANDOFF_ENV => "1")
          expect(described_class.bundle_warning(root, tmp)).to be_nil

          under_bundle(other)
          expect(described_class.bundle_warning(root, tmp)).to be_nil
        end
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

      # No Bundler setting of this run's, nor the user's own, decides where a bundle here installs.
      before do
        stub_const("ENV", ENV.to_h.reject { |key, _| key.start_with?("BUNDLE_") }.except(described_class::HANDOFF_ENV)
                             .merge("BUNDLE_USER_CONFIG" => File.join(tmp, "no-user-config")))
      end

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

      # Parsing a Gemfile costs a second on a machine with many gems, for the many apps that never lock this one.
      it "reads no lockfile in full that never names the gem" do
        root = app("shop")
        File.write(File.join(root, "Gemfile"), %(gem "rails"\n))
        File.write(File.join(root, "Gemfile.lock"), "GEM\n  remote: https://rubygems.org/\n  specs:\n    rails (8.0.0)\n\nDEPENDENCIES\n  rails\n")
        allow(RailsAiContext::GemLock).to receive(:for).and_call_original

        expect(described_class.bundled_handoff(root)).to be_nil
        expect(described_class.pinned?(root)).to be(false)
        expect(RailsAiContext::GemLock).not_to have_received(:for)
      end

      # Only a lock naming this very version decides the copy that runs; another one is handed the run, or not found.
      it "takes the app as pinned where its lockfile names the version running" do
        root = app("shop")
        locked_from(root, "GEM\n  remote: https://rubygems.org/\n  specs:\n    rails-ai-context (#{RailsAiContext::VERSION})\n")
        expect(described_class.pinned?(root)).to be(true)

        locked_from(root, "GEM\n  remote: https://rubygems.org/\n  specs:\n    rails-ai-context (5.0.0)\n")
        expect(described_class.pinned?(root)).to be(false)
      end

      it "reads a gems.rb app's bundle from gems.locked" do
        root = app("shop")
        path_copy("vendor/rails-ai-context")
        File.write(File.join(root, "gems.rb"), %(gem "rails-ai-context", path: "../vendor/rails-ai-context"\n))
        File.write(File.join(root, "gems.locked"), "PATH\n  remote: ../vendor/rails-ai-context\n  specs:\n    rails-ai-context (5.0.0)\n\n" \
                                                   "PLATFORMS\n  ruby\n\nDEPENDENCIES\n  rails-ai-context!\n")

        expect(described_class.bundled_handoff(root)).to have_attributes(version: "5.0.0")
        expect(described_class.pinned?(root, "5.0.0")).to be(true)
      end

      def vendored(root, under: File.join("vendor", "bundle"), version: "5.0.0")
        locked_from(root, "GEM\n  remote: https://rubygems.org/\n  specs:\n    rails-ai-context (#{version})\n")
        copy = File.join(root, under, RUBY_ENGINE, RbConfig::CONFIG["ruby_version"], "gems", "rails-ai-context-#{version}")
        FileUtils.mkdir_p(File.join(copy, "lib"))
        File.write(File.join(copy, "lib", "rails_ai_context.rb"), "")
      end

      def bundle_config(root, text)
        FileUtils.mkdir_p(File.join(root, ".bundle"))
        File.write(File.join(root, ".bundle", "config"), "---\n#{text}")
      end

      # Installed under the bundle's own path, the copy is seen from no Gem path, and the boot would load it over this one.
      it "hands the command to a copy the bundle installed under its own path" do
        root = app("shop")
        vendored(root)
        expect(described_class.bundled_handoff(root)).to be_nil

        bundle_config(root, %(BUNDLE_PATH: "vendor/bundle"\n))
        expect(described_class.bundled_handoff(root)).to have_attributes(version: "5.0.0")
        bundle_config(root, %(BUNDLE_DEPLOYMENT: "true"\n))
        expect(described_class.bundled_handoff(root)).to have_attributes(version: "5.0.0")
      end

      # As Bundler's Settings#path: the first level naming a path or system gems decides, before any deployment.
      it "finds the bundle's path level by level, as Bundler does" do
        root = app("shop")
        vendored(root)
        bundle_config(root, %(BUNDLE_DEPLOYMENT: "true"\n))
        stub_const("ENV", ENV.to_h.merge("BUNDLE_PATH" => "elsewhere"))
        expect(described_class.bundled_handoff(root)).to be_nil

        bundle_config(root, %(BUNDLE_PATH: vendor/bundle\nBUNDLE_PATH__SYSTEM: "true"\n))
        expect(described_class.bundled_handoff(root)).to be_nil
        bundle_config(root, %(BUNDLE_PATH: vendor/bundle\nBUNDLE_DISABLE_SHARED_GEMS: "false"\n))
        expect(described_class.bundled_handoff(root)).to be_nil
        bundle_config(root, %(BUNDLE_PATH: vendor/bundle\nBUNDLE_DISABLE_SHARED_GEMS: "true"\n))
        expect(described_class.bundled_handoff(root)).to have_attributes(version: "5.0.0")
      end

      it "reads the user's Bundler config where Bundler does, and none where it is told to ignore it" do
        root = app("shop")
        vendored(root)
        File.write(File.join(tmp, "user-config"), %(---\nBUNDLE_PATH: "#{File.join(root, "vendor", "bundle")}"\n))
        stub_const("ENV", ENV.to_h.merge("BUNDLE_USER_CONFIG" => File.join(tmp, "user-config")))
        expect(described_class.bundled_handoff(root)).to have_attributes(version: "5.0.0")

        stub_const("ENV", ENV.to_h.merge("BUNDLE_IGNORE_CONFIG" => "1"))
        expect(described_class.bundled_handoff(root)).to be_nil
      end

      it "takes the user's config from BUNDLE_CONFIG before BUNDLE_USER_CONFIG, and from BUNDLE_USER_HOME without either" do
        root = app("shop")
        vendored(root)
        File.write(File.join(tmp, "user-config"), %(---\nBUNDLE_PATH: "#{File.join(tmp, 'elsewhere')}"\n))
        File.write(File.join(tmp, "config"), %(---\nBUNDLE_PATH: "#{File.join(root, 'vendor', 'bundle')}"\n))
        stub_const("ENV", ENV.to_h.merge("BUNDLE_USER_CONFIG" => File.join(tmp, "user-config"), "BUNDLE_CONFIG" => File.join(tmp, "config")))
        expect(described_class.bundled_handoff(root)).to have_attributes(version: "5.0.0")

        stub_const("ENV", ENV.to_h.except("BUNDLE_CONFIG", "BUNDLE_USER_CONFIG").merge("BUNDLE_USER_HOME" => tmp))
        expect(described_class.bundled_handoff(root)).to have_attributes(version: "5.0.0")
      end

      it "reads the app's config from the folder BUNDLE_APP_CONFIG names, against the app" do
        root = app("shop")
        vendored(root)
        bundle_config(root, %(BUNDLE_PATH__SYSTEM: "true"\n))
        FileUtils.mkdir_p(File.join(root, "settings"))
        File.write(File.join(root, "settings", "config"), %(---\nBUNDLE_PATH: "vendor/bundle"\n))
        expect(described_class.bundled_handoff(root)).to be_nil

        stub_const("ENV", ENV.to_h.merge("BUNDLE_APP_CONFIG" => "settings"))
        expect(described_class.bundled_handoff(root)).to have_attributes(version: "5.0.0")
      end

      # Bundler writes double quotes and no comment; a hand-edited file may hold either.
      it "reads a single-quoted value as Bundler does" do
        root = app("shop")
        vendored(root)
        bundle_config(root, %(BUNDLE_PATH: 'vendor/bundle'\n))
        expect(described_class.bundled_handoff(root)).to have_attributes(version: "5.0.0")
      end

      it "cuts a trailing comment off a bare value as Bundler does" do
        root = app("shop")
        vendored(root)
        bundle_config(root, %(BUNDLE_PATH: vendor/bundle # kept with the app\n))
        expect(described_class.bundled_handoff(root)).to have_attributes(version: "5.0.0")
      end

      # bundle exec loads only the copy under the bundle's path, though the Gem path holds one at the same version.
      it "hands the command to the bundle's copy under its own path at this very version" do
        root = app("shop")
        vendored(root, version: RailsAiContext::VERSION)
        bundle_config(root, %(BUNDLE_PATH: "vendor/bundle"\n))
        allow(Gem::Specification).to receive(:find_all_by_name).and_call_original
        allow(Gem::Specification).to receive(:find_all_by_name).with("rails-ai-context", "= #{RailsAiContext::VERSION}")
                                                              .and_return([ instance_double(Gem::Specification, full_gem_path: described_class::OWN_COPY) ])

        expect(described_class.bundled_handoff(root)).to have_attributes(version: RailsAiContext::VERSION)
      end

      # Bundler 5 installs a bundle that names no path under the app's .bundle folder.
      it "looks under .bundle for a bundle Bundler 5 locked" do
        root = app("shop")
        vendored(root, under: ".bundle")
        File.write(File.join(root, "Gemfile.lock"), "#{File.read(File.join(root, "Gemfile.lock"))}\nBUNDLED WITH\n   4.0.18\n")
        expect(described_class.bundled_handoff(root)).to be_nil

        File.write(File.join(root, "Gemfile.lock"), File.read(File.join(root, "Gemfile.lock")).sub("4.0.18", "5.0.0"))
        expect(described_class.bundled_handoff(root)).to have_attributes(version: "5.0.0")
        bundle_config(root, %(BUNDLE_DISABLE_SHARED_GEMS: "true"\n))
        expect(described_class.bundled_handoff(root)).to have_attributes(version: "5.0.0")
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

      # A Gemfile edited since its lock sends Bundler to the network. The
      # limit leaves Ruby time to start and write its pid, which takes more
      # than half a second on a Windows runner.
      it "gives up on a check that runs past its time, and leaves no process behind" do
        pid_file = File.join(tmp, "pid")
        slow = bundle_standing_in("slow", %(File.write(#{pid_file.inspect}, Process.pid.to_s); sleep 30\n))

        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        expect(described_class.bundle_ready?({}, tmp, bundle: slow, seconds: 3)).to be(false)
        expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 10
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
