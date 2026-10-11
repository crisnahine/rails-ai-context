# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "tmpdir"
require "open3"
require "shellwords"
require "rails/generators"
require "generators/rails_ai_context/install/install_generator"

RSpec.describe RailsAiContext::Generators::InstallGenerator do
  subject(:generator) do
    described_class.new([], {}, destination_root: tmpdir).tap do |instance|
      instance.instance_variable_set(:@selected_formats, %i[claude copilot])
      instance.instance_variable_set(:@tool_mode, :mcp)
    end
  end

  let(:tmpdir) { Dir.mktmpdir }
  let(:initializer_path) { File.join(tmpdir, "config/initializers/rails_ai_context.rb") }

  before do
    FileUtils.mkdir_p(File.dirname(initializer_path))
    allow(Rails).to receive(:root).and_return(Pathname.new(tmpdir))
  end

  after do
    FileUtils.remove_entry(tmpdir)
  end

  describe "#create_initializer" do
    it "creates a guarded initializer for fresh installs" do
      generator.create_initializer

      content = File.read(initializer_path)

      expect(content).to start_with(<<~RUBY)
        # frozen_string_literal: true

        if defined?(RailsAiContext) && RailsAiContext.respond_to?(:configure)
          RailsAiContext.configure do |config|
      RUBY
      expect(content).to include("  config.ai_tools = %i[claude copilot]")
      expect(content).to include("  config.tool_mode = :mcp   # MCP primary + CLI fallback")
      expect(content).to end_with("  end\nend\n")
    end

    # This file lands in the app's repo and is read by whoever maintains it
    # next, so its own Rubocop sees it. The AI Tools section was written at one
    # indent and every section after it at another, and the guard wrap kept the
    # gap by indenting both equally.
    it "indents the whole configure body the same way" do
      generator.create_initializer

      body = File.read(initializer_path)
        .lines
        .drop_while { |l| !l.include?("RailsAiContext.configure do |config|") }
        .drop(1)
      body = body.take_while { |l| l !~ /\A  end$/ }
      indents = body.reject { |l| l.strip.empty? }.map { |l| l[/\A */].size }

      expect(indents.uniq).to eq([ 4 ])
    end

    # A new Rails app runs these rules in `bin/rubocop`, `bin/ci` and its
    # GitHub lint job, so a generated file that breaks them fails the app's
    # CI right after install.
    context "under the omakase Rubocop a new Rails app runs" do
      def rubocop_offenses
        config = File.join(tmpdir, ".rubocop.yml")
        File.write(config, "inherit_gem:\n  rubocop-rails-omakase: rubocop.yml\n")
        out, status = Open3.capture2e("bundle", "exec", "rubocop", "--config", config, "--format", "simple", initializer_path)
        status.success? ? nil : out
      end

      it "writes a fresh initializer it passes" do
        generator.create_initializer

        expect(rubocop_offenses).to be_nil
      end

      it "brings an older initializer up to date in a form it passes" do
        File.write(initializer_path, <<~RUBY)
          # frozen_string_literal: true

          RailsAiContext.configure do |config|
            config.ai_tools = %i[claude]
            config.preset = :standard
          end
        RUBY

        generator.create_initializer

        expect(File.read(initializer_path)).to include("    config.preset = :standard\n\n    # ── AI Tools")
        expect(rubocop_offenses).to be_nil
      end
    end

    it "names the :standard preset's introspectors from the preset" do
      generator.create_initializer

      comment = File.read(initializer_path)[/#   :standard.*?\)/m]
      named = comment.scan(/\b[a-z][a-z0-9_]*\b/) - %w[standard core introspectors]
      expect(named).to eq(RailsAiContext::Configuration::PRESETS[:standard].map(&:to_s))
    end

    it "adds the guard when updating an existing unguarded initializer" do
      File.write(initializer_path, <<~RUBY)
        # frozen_string_literal: true

        RailsAiContext.configure do |config|
          config.ai_tools = %i[claude]
          config.tool_mode = :cli
        end
      RUBY

      generator.create_initializer

      content = File.read(initializer_path)

      expect(content.scan("if defined?(RailsAiContext)").size).to eq(1)
      expect(content).to include("  config.ai_tools = %i[claude copilot]")
      expect(content).to include("  config.tool_mode = :mcp   # MCP primary + CLI fallback")
      expect(content).to match(
        /if defined\?\(RailsAiContext\) && RailsAiContext\.respond_to\?\(:configure\)\n  RailsAiContext.configure do \|config\|.*\n  end\nend\n/m
      )
    end

    it "upgrades a bare defined?(RailsAiContext) guard to check respond_to?(:configure) too" do
      File.write(initializer_path, <<~RUBY)
        # frozen_string_literal: true

        if defined?(RailsAiContext)
          RailsAiContext.configure do |config|
            config.ai_tools = %i[claude]
          end
        end
      RUBY

      generator.create_initializer

      content = File.read(initializer_path)

      expect(content).to include(
        "if defined?(RailsAiContext) && RailsAiContext.respond_to?(:configure)\n"
      )
      expect(content).not_to include("if defined?(RailsAiContext)\n")
    end

    it "keeps added sections inside the configure block for guarded initializers" do
      File.write(initializer_path, <<~RUBY)
        # frozen_string_literal: true

        if defined?(RailsAiContext)
          RailsAiContext.configure do |config|
            config.ai_tools = %i[claude]
          end
        end
      RUBY

      generator.create_initializer

      content = File.read(initializer_path)

      expect(content.scan("if defined?(RailsAiContext)").size).to eq(1)
      expect(content).to include("    config.ai_tools = %i[claude copilot]")
      expect(content).to include("    # ── Introspection")
      expect(content).to include("    # config.tool_mode = :mcp")
      expect(content).not_to include("\n  config.ai_tools = %i[claude copilot]")
      expect(content).to match(
        /if defined\?\(RailsAiContext\) && RailsAiContext\.respond_to\?\(:configure\)\n  RailsAiContext.configure do \|config\|.*# ── Introspection.*\n  end\nend\n/m
      )
    end

    it "does not double-wrap an initializer that already has the respond_to? guard" do
      File.write(initializer_path, <<~RUBY)
        # frozen_string_literal: true

        if defined?(RailsAiContext) && RailsAiContext.respond_to?(:configure)
          RailsAiContext.configure do |config|
            config.ai_tools = %i[claude]
          end
        end
      RUBY

      generator.create_initializer

      content = File.read(initializer_path)

      expect(content.scan("if defined?(RailsAiContext)").size).to eq(1)
      expect(content).to include("    config.ai_tools = %i[claude copilot]")
    end

    it "preserves indentation when replacing config lines in guarded initializers" do
      File.write(initializer_path, <<~RUBY)
        # frozen_string_literal: true

        if defined?(RailsAiContext)
          RailsAiContext.configure do |config|
            config.ai_tools = %i[claude]
            config.tool_mode = :cli
          end
        end
      RUBY

      generator.create_initializer

      content = File.read(initializer_path)

      expect(content).to include("    config.ai_tools = %i[claude copilot]")
      expect(content).to include("    config.tool_mode = :mcp   # MCP primary + CLI fallback")
      expect(content).not_to include("\n  config.tool_mode = :mcp   # MCP primary + CLI fallback")
    end
  end

  # An engine's bin/rails boots test/dummy, so Rails.root is the dummy app
  # while the generator runs from the engine's root. The initializer went to
  # the engine's root, which every host app loads and the gemspec ships, and
  # everything else into test/dummy.
  context "run from a mountable engine's root" do
    let(:dummy) { File.join(tmpdir, "test", "dummy") }

    before do
      FileUtils.mkdir_p(File.join(dummy, "config"))
      File.write(File.join(tmpdir, "Gemfile"), "source \"https://rubygems.org\"\ngemspec\ngem \"rails-ai-context\"\n")
      File.write(File.join(tmpdir, ".gitignore"), "/log\n")
      allow(Rails).to receive(:root).and_return(Pathname.new(dummy))
      stub_const("ENGINE_ROOT", tmpdir)
    end

    it "writes no initializer, at the engine's root or the dummy app's, and says why" do
      FileUtils.rm_rf(File.dirname(initializer_path))
      said = []
      allow(generator).to receive(:say) { |text, *| said << text }

      generator.create_initializer

      expect(File.exist?(initializer_path)).to be(false)
      expect(File.exist?(File.join(dummy, "config/initializers/rails_ai_context.rb"))).to be(false)
      expect(said.join).to include("Rails would run it in every app that mounts the engine")
    end

    it "warns about an initializer an earlier install left in the engine, and leaves it alone" do
      File.write(initializer_path, "RailsAiContext.configure { |config| config.ai_tools = %i[claude] }\n")
      said = []
      allow(generator).to receive(:say) { |text, *| said << text }

      generator.create_initializer

      expect(File.read(initializer_path)).to eq("RailsAiContext.configure { |config| config.ai_tools = %i[claude] }\n")
      expect(said.join).to include("is inside the engine", "delete it")
    end

    it "writes the MCP configs, the record and the .gitignore lines at the engine's root" do
      allow(generator).to receive(:say)
      generator.instance_variable_set(:@context_files, true)

      generator.create_mcp_config
      generator.create_yaml_config
      generator.add_to_gitignore

      expect(File.exist?(File.join(tmpdir, ".mcp.json"))).to be(true)
      expect(File.exist?(File.join(tmpdir, ".rails-ai-context.yml"))).to be(true)
      expect(File.read(File.join(tmpdir, ".gitignore"))).to include(".ai-context.json")
      expect(Dir.children(dummy)).to eq([ "config" ])
    end

    it "offers commands that run at the engine's root, where the rake tasks are app:ai:*" do
      said = []
      allow(generator).to receive(:say) { |text = "", *| said << text }

      generator.show_instructions

      expect(said.join("\n")).to include("bundle exec rails-ai-context context", "bundle exec rails-ai-context serve",
                                         "bundle exec rails-ai-context doctor")
      expect(said.join("\n")).not_to include("rails ai:", "rails 'ai:")
    end
  end

  describe "#install_validation_hook" do
    let(:hook_path) { File.join(tmpdir, ".git/hooks/pre-commit") }

    before do
      git("init", "-q", tmpdir)
      allow(generator).to receive(:ask).and_return("y")
    end

    def git(*args)
      system("git", *args, out: File::NULL, err: File::NULL) or raise "git #{args.join(' ')} failed"
    end

    def commit_all(repo)
      git("-C", repo, "add", "-A")
      git("-C", repo, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "apps")
    end

    it "offers nothing outside a git repository" do
      FileUtils.rm_rf(File.join(tmpdir, ".git"))
      Dir.mktmpdir do |outside|
        allow(Rails).to receive(:root).and_return(Pathname.new(outside))
        generator.install_validation_hook
        expect(generator).not_to have_received(:ask)
      end
    end

    # A monorepo app has no .git of its own; the hook goes in the repo's
    # hooks dir, runs from the app, and reads paths relative to it.
    it "installs into the repo above a monorepo app and validates from the app" do
      FileUtils.rm_rf(File.join(tmpdir, ".git"))
      Dir.mktmpdir do |mono|
        git("init", "-q", mono)
        app = File.join(mono, "apps", "web")
        FileUtils.mkdir_p(File.join(app, "config"))
        File.write(File.join(app, "config/application.rb"), "")
        commit_all(mono)
        allow(Rails).to receive(:root).and_return(Pathname.new(app))

        generator.install_validation_hook

        content = File.read(File.join(mono, ".git/hooks/pre-commit"))
        expect(content).to include("# rails-ai-context apps: apps/web\n")
        expect(content).to include("for app in apps/web; do\n")
        expect(content).to include('relative=(--relative="$app/")')
        expect(content).to include('git diff --cached --name-only -z --diff-filter=d "${relative[@]}"')
        expect(File.exist?(File.join(app, ".git"))).to be(false)
      end
    end

    # A submodule's .git is a file naming the real git dir.
    it "installs into the real hooks dir when .git is a file" do
      FileUtils.rm_rf(File.join(tmpdir, ".git"))
      Dir.mktmpdir do |store|
        git("init", "-q", "--separate-git-dir", File.join(store, "web.git"), tmpdir)

        generator.install_validation_hook

        expect(File.file?(File.join(tmpdir, ".git"))).to be(true)
        expect(File.read(File.join(store, "web.git/hooks/pre-commit"))).to include("rails-ai-context")
        expect(File.read(File.join(store, "web.git/hooks/pre-commit"))).to include("# rails-ai-context apps: .\n")
      end
    end

    it "installs where core.hooksPath points, where git runs it" do
      git("-C", tmpdir, "config", "core.hooksPath", ".githooks")

      generator.install_validation_hook

      expect(File.exist?(File.join(tmpdir, ".githooks/pre-commit"))).to be(true)
      expect(File.exist?(hook_path)).to be(false)
    end

    # A core.hooksPath set globally is shared by every repository.
    it "leaves a hooks directory outside the repository alone and says so" do
      Dir.mktmpdir do |shared|
        git("-C", tmpdir, "config", "core.hooksPath", shared)
        allow(generator).to receive(:say)

        generator.install_validation_hook

        expect(generator).not_to have_received(:ask)
        expect(generator).to have_received(:say).with(a_string_including("core.hooksPath points outside this repository"), :yellow)
        expect(Dir.children(shared)).to be_empty
      end
    end

    context "in a monorepo with two apps" do
      let(:mono) { Dir.mktmpdir }

      before do
        FileUtils.rm_rf(File.join(tmpdir, ".git"))
        git("init", "-q", mono)
        %w[apps/web apps/admin].each do |app|
          FileUtils.mkdir_p(File.join(mono, app, "config"))
          File.write(File.join(mono, app, "config/application.rb"), "")
          FileUtils.mkdir_p(File.join(mono, app, "app", "models"))
        end
        commit_all(mono)
      end

      after { FileUtils.remove_entry(mono) }

      def install_for(app)
        allow(Rails).to receive(:root).and_return(Pathname.new(File.join(mono, app)))
        generator.install_validation_hook
      end

      let(:mono_hook) { File.join(mono, ".git/hooks/pre-commit") }

      it "covers the second app in the same hook" do
        install_for("apps/web")
        install_for("apps/admin")

        expect(File.read(mono_hook)).to include("# rails-ai-context apps: apps/web apps/admin\n")
        expect(File.read(mono_hook)).to include("for app in apps/web apps/admin; do\n")
      end

      # As git names its top level: through any symlink in the temp dir (macOS).
      it "names the repository the hook goes into" do
        install_for("apps/web")

        expect(generator).to have_received(:ask).with(a_string_including("in #{File.realpath(mono)}"))
      end

      # An untouched hook in the other install form is still the gem's.
      it "adds the app to a hook written in the other install form, keeping that form" do
        allow(RailsAiContext::InstallMode).to receive(:standalone?).and_return(true)
        install_for("apps/web")
        allow(RailsAiContext::InstallMode).to receive(:standalone?).and_return(false)
        install_for("apps/admin")

        expect(File.read(mono_hook)).to include("# rails-ai-context apps: apps/web apps/admin\n")
        expect(File.read(mono_hook)).to include("rails-ai-context tool validate")
      end

      it "says why it leaves a hook it did not write as it stands alone, for an app below the root" do
        FileUtils.mkdir_p(File.dirname(mono_hook))
        File.write(mono_hook, "#!/bin/bash\n# rails-ai-context: validate Rails references before commit\n")
        allow(generator).to receive(:say)

        install_for("apps/web")

        expect(generator).not_to have_received(:ask)
        expect(generator).to have_received(:say).with(a_string_including("is not a hook this version wrote"), :yellow)
      end

      # An earlier version's hook, unchanged, served the app at the top.
      it "adds an app below the root to an earlier version's hook, bringing it up to date" do
        FileUtils.mkdir_p(File.dirname(mono_hook))
        File.write(mono_hook, RailsAiContext::Install::ValidationHook::LEGACY.keys.first)
        allow(RailsAiContext::InstallMode).to receive(:standalone?).and_return(false)

        install_for("apps/web")

        expect(generator).to have_received(:ask).once
        expect(File.read(mono_hook)).to eq(RailsAiContext::Install::ValidationHook.script(%w[. apps/web], standalone: false))
      end

      # The form for several apps that ran the rake task, which has to boot
      # the app, with its errors thrown away.
      it "brings the earlier hook for an app below the root up to date without asking" do
        FileUtils.mkdir_p(File.dirname(mono_hook))
        File.write(mono_hook, RailsAiContext::Install::ValidationHook.earlier_script(%w[apps/web], standalone: false))
        allow(RailsAiContext::InstallMode).to receive(:standalone?).and_return(false)
        allow(generator).to receive(:say)

        install_for("apps/web")

        expect(generator).not_to have_received(:ask)
        expect(File.read(mono_hook)).to eq(RailsAiContext::Install::ValidationHook.script(%w[apps/web], standalone: false))
        expect(generator).to have_received(:say).with(a_string_including("Updated the pre-commit validation hook"), :green)
      end

      it "keeps an earlier hook's apps and install form when it brings it up to date" do
        FileUtils.mkdir_p(File.dirname(mono_hook))
        File.write(mono_hook, RailsAiContext::Install::ValidationHook.earlier_script(%w[apps/web apps/admin], standalone: true))
        allow(RailsAiContext::InstallMode).to receive(:standalone?).and_return(false)

        install_for("apps/admin")

        expect(generator).not_to have_received(:ask)
        expect(File.read(mono_hook)).to eq(RailsAiContext::Install::ValidationHook.script(%w[apps/web apps/admin], standalone: true))
      end

      it "asks nothing for an app the hook already covers" do
        install_for("apps/web")
        install_for("apps/web")

        expect(generator).to have_received(:ask).once
      end

      it "leaves a hook changed by hand alone, and says how to add the app" do
        install_for("apps/web")
        File.write(mono_hook, File.read(mono_hook) + "echo mine\n")
        allow(generator).to receive(:say)

        install_for("apps/admin")

        expect(File.read(mono_hook)).to end_with("echo mine\n")
        expect(File.read(mono_hook)).not_to include("apps/admin")
        expect(generator).to have_received(:say).with(a_string_including("was changed by hand - add apps/admin"), :yellow)
      end

      # A stand-in `bundle` on PATH logs what it was given and where, and
      # fails in the app named by `fail_in`, as validate does on a file that
      # does not parse.
      def fake_bundle(bin, log, fail_in: nil)
        File.write(File.join(bin, "bundle"), <<~SH)
          #!/bin/sh
          echo "$(basename "$PWD") $*" >> #{log.shellescape}
          [ "$(basename "$PWD")" != "#{fail_in}" ]
        SH
        File.chmod(0o755, File.join(bin, "bundle"))
      end

      def commit(repo, bin)
        env = { "PATH" => [ bin, ENV.fetch("PATH") ].join(File::PATH_SEPARATOR), "GIT_AUTHOR_NAME" => "t", "GIT_AUTHOR_EMAIL" => "t@t",
                "GIT_COMMITTER_NAME" => "t", "GIT_COMMITTER_EMAIL" => "t@t" }
        Open3.capture2e(env, "git", "-C", repo, "commit", "-q", "-m", "x")
      end

      # What git runs at commit: each app's staged files, by paths relative
      # to it, validated from inside it, and a failure stops the commit.
      it "validates each app's staged files from inside it when git commits" do
        install_for("apps/web")
        install_for("apps/admin")
        Dir.mktmpdir do |bin|
          log = File.join(bin, "calls.log")
          fake_bundle(bin, log, fail_in: "admin")
          File.write(File.join(mono, "apps/web/app/models/post.rb"), "class Post; end\n")
          File.write(File.join(mono, "apps/admin/app/models/user.rb"), "class User; end\n")
          File.write(File.join(mono, "README.md"), "x\n")
          git("-C", mono, "add", "-A")

          out, status = commit(mono, bin)

          expect(File.read(log).lines).to eq([ "web exec rails-ai-context tool validate --files app/models/post.rb\n",
                                               "admin exec rails-ai-context tool validate --files app/models/user.rb\n" ])
          expect(status.success?).to be(false), out
          expect(out).to include("rails-ai-context validation found issues.")
        end
      end

      it "hands validation the app's staged JavaScript, and asks about it" do
        install_for("apps/web")
        Dir.mktmpdir do |bin|
          log = File.join(bin, "calls.log")
          fake_bundle(bin, log)
          FileUtils.mkdir_p(File.join(mono, "apps/web/app/javascript/controllers"))
          File.write(File.join(mono, "apps/web/app/javascript/controllers/cart_controller.js"), "export default class {}\n")
          File.write(File.join(mono, "apps/web/app/javascript/legacy.cjs"), "module.exports = {}\n")
          git("-C", mono, "add", "-A")

          out, status = commit(mono, bin)

          expect(status.success?).to be(true), out
          expect(File.read(log).lines).to eq([ "web exec rails-ai-context tool validate --files " \
                                               "app/javascript/controllers/cart_controller.js,app/javascript/legacy.cjs\n" ])
        end
        expect(generator).to have_received(:ask).with(a_string_including("checks staged Ruby, ERB and JavaScript files"))
      end

      # git exports GIT_DIR to a hook in a linked worktree, where a diff run
      # from inside an app would list paths from the top of the work tree.
      it "lists an app's files by paths relative to it from a linked worktree too" do
        install_for("apps/web")
        Dir.mktmpdir do |bin|
          worktree = File.join(bin, "wt")
          git("-C", mono, "worktree", "add", "-q", worktree)
          log = File.join(bin, "calls.log")
          fake_bundle(bin, log)
          FileUtils.mkdir_p(File.join(worktree, "apps/web/app/models"))
          File.write(File.join(worktree, "apps/web/app/models/post.rb"), "class Post; end\n")
          File.write(File.join(worktree, "top.rb"), "x\n")
          git("-C", worktree, "add", "-A")

          out, status = commit(worktree, bin)

          expect(status.success?).to be(true), out
          expect(File.read(log).lines).to eq([ "web exec rails-ai-context tool validate --files app/models/post.rb\n" ])
        end
      end

      # git quotes a name holding a character outside ASCII in its line
      # format, which no extension test matched, so the file went unchecked.
      # validate takes its list comma-separated, so a name with a comma is
      # named rather than passed in two halves.
      it "validates a staged file whose name git quotes, and names one with a comma it cannot pass" do
        install_for("apps/web")
        Dir.mktmpdir do |bin|
          log = File.join(bin, "calls.log")
          fake_bundle(bin, log)
          File.write(File.join(mono, "apps/web/app/models/caf\u00e9.rb"), "class Cafe; end\n")
          File.write(File.join(mono, "apps/web/app/models/a,b.rb"), "x\n")
          git("-C", mono, "add", "-A")

          out, status = commit(mono, bin)

          expect(status.success?).to be(true), out
          expect(File.read(log, encoding: "UTF-8").lines).to eq([ "web exec rails-ai-context tool validate --files app/models/caf\u00e9.rb\n" ])
          expect(out).to include("app/models/a,b.rb is not checked")
        end
      end

      # cd consults CDPATH for a bare relative name, and a committer's
      # exported CDPATH may hold a folder of the same name.
      it "validates inside the app whatever CDPATH holds" do
        install_for("apps/web")
        Dir.mktmpdir do |bin|
          FileUtils.mkdir_p(File.join(bin, "elsewhere/apps/web"))
          File.write(File.join(bin, "bundle"), "#!/bin/sh\necho \"$PWD\" >> #{File.join(bin, 'pwd.log').shellescape}\n")
          File.chmod(0o755, File.join(bin, "bundle"))
          File.write(File.join(mono, "apps/web/app/models/post.rb"), "class Post; end\n")
          git("-C", mono, "add", "-A")
          env = { "PATH" => [ bin, ENV.fetch("PATH") ].join(File::PATH_SEPARATOR), "CDPATH" => File.join(bin, "elsewhere"),
                  "GIT_AUTHOR_NAME" => "t", "GIT_AUTHOR_EMAIL" => "t@t", "GIT_COMMITTER_NAME" => "t", "GIT_COMMITTER_EMAIL" => "t@t" }

          out, status = Open3.capture2e(env, "git", "-C", mono, "commit", "-q", "-m", "x")

          expect(status.success?).to be(true), out
          # The sh Git for Windows runs the hook with names /d/a/... for D:/a/...
          logged = File.read(File.join(bin, "pwd.log")).strip
          logged = logged.sub(%r{\A/([a-z])/}i) { "#{Regexp.last_match(1).upcase}:/" } if Gem.win_platform?
          expect(File.realpath(logged)).to eq(File.realpath(File.join(mono, "apps/web")))
        end
      end

      # A deleted file has nothing left to validate, and an app that is gone
      # has nothing to validate in.
      it "passes over deleted files and an app that is gone" do
        File.write(File.join(mono, "apps/web/app/models/post.rb"), "class Post; end\n")
        commit_all(mono)
        install_for("apps/web")
        install_for("apps/admin")
        Dir.mktmpdir do |bin|
          log = File.join(bin, "calls.log")
          fake_bundle(bin, log)
          git("-C", mono, "rm", "-q", "apps/web/app/models/post.rb")
          git("-C", mono, "rm", "-q", "-r", "apps/admin")

          out, status = commit(mono, bin)

          expect(status.success?).to be(true), out
          expect(out).not_to include("No such file or directory")
          expect(File.exist?(log)).to be(false)
        end
      end
    end

    # A dotfiles repository at $HOME holds every app below it in name only.
    it "offers no hook for an app the repository above it does not track" do
      FileUtils.rm_rf(File.join(tmpdir, ".git"))
      Dir.mktmpdir do |home|
        git("init", "-q", home)
        app = File.join(home, "code", "shop")
        FileUtils.mkdir_p(File.join(app, "config"))
        File.write(File.join(app, "config/application.rb"), "")
        allow(Rails).to receive(:root).and_return(Pathname.new(app))
        allow(generator).to receive(:say)

        generator.install_validation_hook

        expect(generator).not_to have_received(:ask)
        expect(generator).to have_received(:say).with(a_string_including("is not tracked in the git repository at"), :yellow)
        expect(File.exist?(File.join(home, ".git/hooks/pre-commit"))).to be(false)
      end
    end

    # Each release from v5.9.0 wrote one of these for the app at the top of
    # its repository, and each hands validate the files a commit deletes.
    RailsAiContext::Install::ValidationHook::LEGACY.each_with_index do |(legacy, _), index|
      it "brings an earlier version's hook up to date without asking again (#{index + 1} of 3)" do
        FileUtils.mkdir_p(File.dirname(hook_path))
        File.write(hook_path, legacy)
        allow(generator).to receive(:say)
        allow(RailsAiContext::InstallMode).to receive(:standalone?).and_return(true)

        generator.install_validation_hook

        expect(generator).not_to have_received(:ask)
        expect(File.read(hook_path)).to eq(RailsAiContext::Install::ValidationHook.script([ "." ], standalone: true))
        # Windows keeps no exec bit; git runs a hook there whatever its mode.
        expect(File.executable?(hook_path)).to be(true) unless Gem.win_platform?
        expect(generator).to have_received(:say).with(a_string_including("Updated the pre-commit validation hook"), :green)
      end
    end

    # A version that wrote the hook in text mode ended its lines in CRLF on
    # Windows, which the sh Git for Windows runs hooks with cannot read: the
    # same hook, which the install did not know and so never put right.
    it "brings a hook whose lines end in CRLF up to date, in LF" do
      current = RailsAiContext::Install::ValidationHook.script([ "." ], standalone: true)
      FileUtils.mkdir_p(File.dirname(hook_path))
      File.binwrite(hook_path, current.gsub("\n", "\r\n"))
      allow(generator).to receive(:say)
      allow(RailsAiContext::InstallMode).to receive(:standalone?).and_return(true)

      generator.install_validation_hook

      expect(generator).not_to have_received(:ask)
      expect(File.binread(hook_path)).to eq(current)
      expect(generator).to have_received(:say).with(a_string_including("Updated the pre-commit validation hook"), :green)
    end

    # What the update is for: a commit that deletes a file.
    it "lets a commit that deletes a file through once an earlier version's hook is updated" do
      FileUtils.mkdir_p(File.join(tmpdir, "app/models"))
      File.write(File.join(tmpdir, "app/models/old.rb"), "class Old; end\n")
      commit_all(tmpdir)
      FileUtils.mkdir_p(File.dirname(hook_path))
      File.write(hook_path, RailsAiContext::Install::ValidationHook::LEGACY.keys.last)
      FileUtils.chmod(0o755, hook_path)
      allow(RailsAiContext::InstallMode).to receive(:standalone?).and_return(true)
      Dir.mktmpdir do |bin|
        # A validator that fails on a file that is not there, as the real one does.
        File.write(File.join(bin, "rails-ai-context"), %(#!/bin/sh\nfor f in $(echo "$4" | tr ',' ' '); do [ -f "$f" ] || exit 1; done\n))
        File.chmod(0o755, File.join(bin, "rails-ai-context"))
        env = { "PATH" => [ bin, ENV.fetch("PATH") ].join(File::PATH_SEPARATOR), "GIT_AUTHOR_NAME" => "t", "GIT_AUTHOR_EMAIL" => "t@t",
                "GIT_COMMITTER_NAME" => "t", "GIT_COMMITTER_EMAIL" => "t@t" }
        git("-C", tmpdir, "rm", "-q", "app/models/old.rb")
        # Through bash, as git runs it: Windows starts no script by itself.
        blocked, = Open3.capture2e(env, "bash", hook_path, chdir: tmpdir)

        generator.install_validation_hook
        out, status = Open3.capture2e(env, "git", "-C", tmpdir, "commit", "-q", "-m", "x")

        expect(blocked).to include("rails-ai-context validation found issues.")
        expect(status.success?).to be(true), out
      end
    end

    # A team's own hook that calls the gem among its other checks is not the
    # gem's to replace, whatever it looks like.
    it "leaves a hook that runs the gem among other checks alone, and says so" do
      own = "#!/bin/sh\n# team checks\nbundle exec rubocop --force-exclusion\nrails-ai-context tool validate --files \"$FILES\"\n"
      FileUtils.mkdir_p(File.dirname(hook_path))
      File.write(hook_path, own)
      allow(generator).to receive(:say)

      generator.install_validation_hook

      expect(generator).not_to have_received(:ask)
      expect(File.read(hook_path)).to eq(own)
      expect(generator).to have_received(:say)
        .with(a_string_including("already runs rails-ai-context and is not a hook this version wrote"), :yellow)
      expect(generator).not_to have_received(:say).with(a_string_including("delete it"), anything)
    end

    # The apps line edited by hand into something a shell would not read.
    it "says why it leaves a hook whose apps line it cannot read alone, instead of raising" do
      FileUtils.mkdir_p(File.dirname(hook_path))
      allow(generator).to receive(:say)
      [ "# rails-ai-context apps: apps/web \"apps/x\n", "# rails-ai-context apps: caf\xC3(\xFF\n".b ].each do |line|
        File.binwrite(hook_path, "#!/bin/bash\n".b + line)

        expect { generator.install_validation_hook }.not_to raise_error
      end

      expect(generator).to have_received(:say).with(a_string_including("names its apps in a form this version cannot read"), :yellow).twice
      expect(generator).not_to have_received(:ask)
    end

    it "reads the staged names NUL-separated and passes them to validation as one list" do
      generator.install_validation_hook

      content = File.read(hook_path)

      expect(content).to include("git diff --cached --name-only -z --diff-filter=d")
      expect(content).to include(%(files="${files:+$files,}$name"))
      expect(content).to include("rails-ai-context tool validate --files \"$files\"")
      expect(content).not_to include("echo $changed_files")
    end

    it "uses the CLI in the app's bundle on in-Gemfile installs" do
      allow(RailsAiContext::InstallMode).to receive(:standalone?).and_return(false)

      generator.install_validation_hook

      content = File.read(hook_path)
      expect(content).to include("if command -v bundle &> /dev/null")
      expect(content).to include("bundle exec rails-ai-context tool validate --files \"$files\"")
      expect(content).not_to include("ai:tool")
    end

    # validate's errors were sent to /dev/null, so a commit it stopped said
    # only that validation found issues.
    it "shows what validation printed to stderr when it stops a commit" do
      allow(RailsAiContext::InstallMode).to receive(:standalone?).and_return(false)
      generator.install_validation_hook
      Dir.mktmpdir do |bin|
        File.write(File.join(bin, "bundle"), "#!/bin/sh\necho 'Could not find gem rails-ai-context' >&2\nexit 7\n")
        File.chmod(0o755, File.join(bin, "bundle"))
        FileUtils.mkdir_p(File.join(tmpdir, "app/models"))
        File.write(File.join(tmpdir, "app/models/post.rb"), "class Post; end\n")
        git("-C", tmpdir, "add", "-A")
        env = { "PATH" => [ bin, ENV.fetch("PATH") ].join(File::PATH_SEPARATOR), "GIT_AUTHOR_NAME" => "t", "GIT_AUTHOR_EMAIL" => "t@t",
                "GIT_COMMITTER_NAME" => "t", "GIT_COMMITTER_EMAIL" => "t@t" }

        out, status = Open3.capture2e(env, "git", "-C", tmpdir, "commit", "-q", "-m", "x")

        expect(status.success?).to be(false)
        expect(out).to include("Could not find gem rails-ai-context").and include("rails-ai-context validation found issues.")
      end
    end

    it "uses the CLI binary on standalone installs (no rake tasks exist)" do
      allow(RailsAiContext::InstallMode).to receive(:standalone?).and_return(true)

      generator.install_validation_hook

      content = File.read(hook_path)
      expect(content).to include("if command -v rails-ai-context &> /dev/null")
      expect(content).to include("rails-ai-context tool validate --files \"$files\"")
      expect(content).not_to include("ai:tool")
    end

    it "declines the hook instead of raising when stdin hits EOF (ask returns nil)" do
      allow(generator).to receive(:ask).and_return(nil)

      expect { generator.install_validation_hook }.not_to raise_error
      expect(File.exist?(hook_path)).to be(false)
    end
  end

  describe "#ask_safe" do
    it "returns an empty string instead of raising when ask hits EOF (nil)" do
      allow(generator).to receive(:ask).and_return(nil)

      expect(generator.send(:ask_safe, "Prompt:")).to eq("")
    end

    it "skips the prompt and returns an empty string when --defaults is set" do
      defaults_generator = described_class.new([], { defaults: true }, destination_root: tmpdir)

      expect(defaults_generator).not_to receive(:ask)
      expect(defaults_generator.send(:ask_safe, "Prompt:")).to eq("")
    end
  end

  describe "#select_ai_tools" do
    it "falls back to all tools instead of raising when stdin hits EOF (ask returns nil)" do
      allow(generator).to receive(:ask).and_return(nil)

      expect { generator.select_ai_tools }.not_to raise_error
      expect(generator.instance_variable_get(:@selected_formats))
        .to match_array(RailsAiContext::Install::AiTool.all.map(&:key))
    end

    # A re-run asked the question with no hint of the answer it gave before.
    it "shows the selection a re-run starts from" do
      File.write(File.join(tmpdir, ".rails-ai-context.yml"), "ai_tools:\n- claude\n- cursor\n")
      said = []
      allow(generator).to receive(:say) { |text, *| said << text }
      allow(generator).to receive(:ask).and_return("1,2")

      generator.select_ai_tools

      expect(said).to include("Currently selected: 1,2 (Claude Code, Cursor)")
    end
  end

  # The closing summary told an in-Gemfile user how to install standalone,
  # offered the tools they had just picked, and asked them to gitignore a
  # file the step before had already ignored.
  describe "#show_instructions" do
    def summary
      said = []
      allow(generator).to receive(:say) { |text = "", *| said << text }
      generator.show_instructions
      said.join("\n")
    end

    it "offers only the tools not picked, and no standalone install" do
      expect(summary).to include("rails ai:context:cursor", "rails ai:context:opencode", "rails ai:context:codex")
      expect(summary).not_to include("rails ai:context:claude", "rails ai:context:copilot")
      expect(summary).not_to include("Standalone (no Gemfile needed)", "gem install rails-ai-context")
    end

    it "offers no more tools when every one is picked" do
      generator.instance_variable_set(:@selected_formats, RailsAiContext::Install::AiTool.all.map(&:key))

      expect(summary).not_to include("To add more AI tools later")
    end

    it "asks to gitignore the Codex config only while a commit would take it" do
      generator.instance_variable_set(:@selected_formats, %i[codex])
      File.write(File.join(tmpdir, ".gitignore"), "")
      expect(summary).to include("add it to .gitignore")

      File.write(File.join(tmpdir, ".gitignore"), ".codex/config.toml\n")
      expect(summary).not_to include("add it to .gitignore")
    end

    it "names no Codex config and no MCP configs in CLI mode" do
      generator.instance_variable_set(:@selected_formats, %i[codex])
      generator.instance_variable_set(:@tool_mode, :cli)

      expect(summary).to include("Codex CLI        -> AGENTS.md\n")
      expect(summary).not_to include(".codex/config.toml", "MCP configs")
    end

    it "offers no regeneration when the install writes no context files" do
      generator.instance_variable_set(:@context_files, false)

      expect(summary).not_to include("rails ai:context ")
      expect(summary).not_to include("Regenerate context files")
    end
  end

  describe "#select_setup" do
    it "defaults to :mcp instead of raising when stdin hits EOF (ask returns nil)" do
      allow(generator).to receive(:ask).and_return(nil)

      expect { generator.select_setup }.not_to raise_error
      expect(generator.instance_variable_get(:@tool_mode)).to eq(:mcp)
    end
  end

  describe "#create_yaml_config" do
    let(:yaml_path) { File.join(tmpdir, ".rails-ai-context.yml") }

    it "creates the file and reports Created on first run" do
      expect { generator.create_yaml_config }
        .to output(/Created \.rails-ai-context\.yml/).to_stdout
      expect(File.read(yaml_path)).to include("ai_tools:")
    end

    it "does not mislabel the file as a standalone config" do
      expect { generator.create_yaml_config }
        .not_to output(/standalone config/).to_stdout
    end

    it "reports unchanged and does not rewrite the file when content is identical" do
      generator.create_yaml_config
      mtime_before = File.mtime(yaml_path)

      expect { generator.create_yaml_config }.to output(/\.rails-ai-context\.yml \(unchanged\)/).to_stdout
      expect(File.mtime(yaml_path)).to eq(mtime_before)
    end

    it "reports Updated when the selection changed" do
      generator.create_yaml_config
      generator.instance_variable_set(:@selected_formats, %i[claude])

      expect { generator.create_yaml_config }.to output(/Updated \.rails-ai-context\.yml/).to_stdout
      expect(File.read(yaml_path)).to include("- claude")
      expect(File.read(yaml_path)).not_to include("- copilot")
    end
  end

  describe "#add_to_gitignore" do
    let(:gitignore_path) { File.join(tmpdir, ".gitignore") }

    it "does not create .gitignore when the project doesn't have one" do
      generator.add_to_gitignore
      expect(File.exist?(gitignore_path)).to be(false)
    end

    it "appends both .ai-context.json and .codex/config.toml when .gitignore exists" do
      File.write(gitignore_path, "*.log\n")

      generator.add_to_gitignore

      content = File.read(gitignore_path)
      expect(content).to include(".ai-context.json")
      expect(content).to include(".codex/config.toml")
    end

    it "does not duplicate entries that are already present" do
      File.write(gitignore_path, "*.log\n.ai-context.json\n.codex/config.toml\n")

      expect { generator.add_to_gitignore }.to output("").to_stdout

      content = File.read(gitignore_path)
      expect(content.scan(".ai-context.json").size).to eq(1)
      expect(content.scan(".codex/config.toml").size).to eq(1)
    end
  end

  # MCP-only: the server and the CLI still answer, and the gem writes to none
  # of the files a user keeps by hand.
  describe "--mcp-only" do
    subject(:generator) do
      described_class.new([], { mcp_only: true }, destination_root: tmpdir).tap do |instance|
        instance.instance_variable_set(:@selected_formats, %i[claude])
      end
    end

    it "records the mode without asking" do
      generator.select_setup

      expect(generator.instance_variable_get(:@tool_mode)).to eq(:mcp)
      expect(generator.instance_variable_get(:@context_files)).to be(false)
    end

    it "writes config.context_files = false into a fresh initializer" do
      generator.select_setup
      generator.create_initializer

      expect(File.read(initializer_path)).to include("config.context_files = false")
    end

    it "records the choice in the YAML too" do
      generator.select_setup
      silence_output { generator.create_yaml_config }

      expect(File.read(File.join(tmpdir, ".rails-ai-context.yml"))).to include("context_files: false")
    end

    it "writes no context files and says so" do
      generator.select_setup

      expect(RailsAiContext).not_to receive(:generate_context)
      expect { generator.generate_context_files }.to output(/MCP-only install/).to_stdout
    end

    it "leaves the JSON cache out of .gitignore" do
      File.write(File.join(tmpdir, ".gitignore"), "*.log\n")
      generator.select_setup
      silence_output { generator.add_to_gitignore }

      expect(File.read(File.join(tmpdir, ".gitignore"))).not_to include(".ai-context.json")
    end
  end

  def silence_output
    original = $stdout
    $stdout = StringIO.new
    yield
  ensure
    $stdout = original
  end
end
