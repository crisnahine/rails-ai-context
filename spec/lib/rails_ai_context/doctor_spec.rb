# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Doctor do
  let(:doctor) { described_class.new(Rails.application) }

  describe "#run" do
    subject(:result) { doctor.run }

    it "returns checks and a score" do
      expect(result).to have_key(:checks)
      expect(result).to have_key(:score)
    end

    it "returns an array of checks" do
      expect(result[:checks]).to all(be_a(RailsAiContext::Doctor::Check))
    end

    it "computes a score between 0 and 100" do
      expect(result[:score]).to be_between(0, 100)
    end

    it "checks schema presence" do
      names = result[:checks].map(&:name)
      expect(names).to include("Schema")
    end

    describe "the Brakeman check" do
      def brakeman_check
        doctor.run[:checks].find { |c| c.name == "Brakeman" }
      end

      it "says the scan runs from outside the bundle when that is where brakeman is" do
        allow(RailsAiContext::Tools::SecurityScan).to receive(:brakeman_location).and_return([ :machine, "7.1.0" ])
        allow(RailsAiContext::Tools::SecurityScan).to receive(:unbundled_failure).and_return(nil)

        check = brakeman_check
        expect(check.status).to eq(:pass)
        expect(check.message).to include("7.1.0").and include("outside")
      end

      # It said the scan ran brakeman from there while the scan could not start it.
      it "warns, naming why, when the scan cannot run the brakeman outside the bundle" do
        allow(RailsAiContext::Tools::SecurityScan).to receive(:brakeman_location).and_return([ :machine, "8.1.0" ])
        allow(RailsAiContext::Tools::SecurityScan).to receive(:unbundled_failure).and_return("cannot load such file -- ruby_parser (LoadError)")

        check = brakeman_check
        expect(check).to have_attributes(status: :warn, fix: "Add: `gem 'brakeman', group: :development` to scan in this process",
                                         message: "Brakeman 8.1.0 is on this machine, outside the app's bundle, but rails_security_scan " \
                                                  "cannot run it there: cannot load such file -- ruby_parser (LoadError)")
      end

      # Mastodon locks brakeman; a static run never loads the app's bundle.
      it "does not tell an app whose lockfile carries brakeman to add it" do
        allow(RailsAiContext::Tools::SecurityScan).to receive(:brakeman_location).and_return([ :machine, "8.0.6" ])
        allow(RailsAiContext::Tools::SecurityScan).to receive(:unbundled_failure).and_return(nil)
        allow(RailsAiContext::GemLock).to receive(:for).and_return(RailsAiContext::GemLock::Spec.new({ "brakeman" => "8.0.6" }))

        check = brakeman_check
        expect(check.message).to include("Gemfile.lock carries brakeman 8.0.6")
        expect(check.fix).to be_nil
      end

      it "says to install a brakeman the lockfile carries and the machine lacks" do
        allow(RailsAiContext::Tools::SecurityScan).to receive(:brakeman_location).and_return([ nil, nil ])
        allow(RailsAiContext::GemLock).to receive(:for).and_return(RailsAiContext::GemLock::Spec.new({ "brakeman" => "8.0.6" }))

        check = brakeman_check
        expect(check.status).to eq(:warn)
        expect(check.fix).to include("bundle install")
        expect(check.fix).not_to include("gem 'brakeman'")
      end

      it "reports it missing only when no scanner is anywhere" do
        allow(RailsAiContext::Tools::SecurityScan).to receive(:brakeman_location).and_return([ nil, nil ])

        check = brakeman_check
        expect(check.status).to eq(:warn)
        expect(check.message).to include("not installed")
      end
    end

    it "includes core checks" do
      names = result[:checks].map(&:name)
      expect(names).to include("Controllers", "Views", "Tests", "MCP server")
    end

    it "includes deep checks" do
      names = result[:checks].map(&:name)
      expect(names).to include("Context files", "Preset coverage", "Secrets in .gitignore", "MCP HTTP endpoint")
    end

    it "runs at least 15 checks" do
      expect(result[:checks].size).to be >= 15
    end

    it "checks MCP server buildability" do
      mcp_check = result[:checks].find { |c| c.name == "MCP server" }
      expect(mcp_check.status).to eq(:pass)
    end

    it "all checks have a name and message" do
      result[:checks].each do |check|
        expect(check.name).to be_a(String)
        expect(check.message).to be_a(String)
        expect(%i[pass warn fail]).to include(check.status)
      end
    end

    it "checks security settings" do
      endpoint = result[:checks].find { |c| c.name == "MCP HTTP endpoint" }
      expect(endpoint).not_to be_nil
      expect(endpoint.status).to eq(:pass)
    end

    describe "the HTTP endpoint in production" do
      def endpoint_check
        doctor.send(:check_security_http_endpoint)
      end

      it "passes auto_mount, which refuses in production unless the app opts in" do
        allow(RailsAiContext.configuration).to receive(:auto_mount).and_return(true)

        expect(endpoint_check.status).to eq(:pass)
      end

      it "warns when the app lets the engine answer in production" do
        allow(RailsAiContext.configuration).to receive(:allow_http_in_production).and_return(true)

        expect(endpoint_check.status).to eq(:warn)
      end

      # auto_mount answers before routing, so no authentication can sit in front of it.
      it "fails auto_mount answering in production" do
        allow(RailsAiContext.configuration).to receive_messages(allow_http_in_production: true, auto_mount: true)

        expect(endpoint_check.status).to eq(:fail)
      end
    end

    it "checks preset coverage" do
      preset = result[:checks].find { |c| c.name == "Preset coverage" }
      expect(preset).not_to be_nil
    end
  end

  # A standalone install has no rake tasks and no generator: the gem is not in
  # the app's bundle. A fix that names `rails ai:context` sends the reader to a
  # command that does not exist there.
  describe "the commands its fixes name" do
    def fixes_for(standalone:)
      allow(RailsAiContext::InstallMode).to receive(:standalone?).and_return(standalone)
      described_class.new(Rails.application).run[:checks].filter_map(&:fix)
    end

    it "names the binary's commands in a standalone install" do
      fixes = fixes_for(standalone: true)

      expect(fixes.join("\n")).not_to match(/rails ai:|rails generate rails_ai_context/)
      expect(fixes).to include("Run `rails-ai-context context`", "Run `rails-ai-context init` to fix")
    end

    it "names the rake task and the generator where the app bundles the gem" do
      fixes = fixes_for(standalone: false)

      expect(fixes.join("\n")).not_to match(/rails-ai-context (context|init)/)
      expect(fixes).to include("Run `rails ai:context`", "Run `rails generate rails_ai_context:install` to fix")
    end
  end

  describe ".report_lines" do
    # The struct check below is not what a user reads. The printed report is.
    it "prints the introspector's own error under its check" do
      allow(RailsAiContext.configuration).to receive(:introspectors).and_return([ :database_stats ])
      allow(ActiveRecord::Base).to receive(:connection)
        .and_raise(StandardError, "Database not found: no_such_db. Run bin/rails db:create")

      lines = described_class.report_lines(doctor.run)
      index = lines.index { |line| line.include?("Introspector health") }

      expect(lines[index]).to include("[WARN] Introspector health:")
      expect(lines[index + 1]).to include("Fix: database_stats: StandardError: Database not found: no_such_db")
      expect(lines[index + 1]).not_to include("stimulus")
    end

    # The emoji icons are not one width, so indenting the Fix line by the
    # icon above it put the rake report's Fix lines at three columns.
    it "indents every Fix line to the same column under the emoji icons" do
      result = {
        checks: [
          described_class::Check.new(name: "Schema", status: :fail, message: "missing", fix: "run db:migrate"),
          described_class::Check.new(name: "Views", status: :warn, message: "none", fix: "add a view"),
          described_class::Check.new(name: "Gems", status: :pass, message: "ok", fix: nil)
        ]
      }

      lines = described_class.report_lines(result, icons: described_class::EMOJI_ICONS)
      fixes = lines.grep(/Fix:/)

      expect(fixes.size).to eq(2)
      expect(fixes.map { |line| line.index("Fix:") }.uniq.size).to eq(1)
    end
  end

  describe "#check_live_reload" do
    # `require "listen"` failing, as it does where no listen is reachable.
    def missing_listen_check
      allow(doctor).to receive(:require).and_call_original
      allow(doctor).to receive(:require).with("listen").and_raise(LoadError, "cannot load such file -- listen")
      doctor.send(:check_live_reload)
    end

    it "offers gem install in a standalone install, which reaches an installed listen" do
      allow(RailsAiContext::InstallMode).to receive(:standalone?).and_return(true)

      check = missing_listen_check
      expect(check.status).to eq(:warn)
      expect(check.fix).to eq("Run: `gem install listen`")
    end

    it "offers the Gemfile line where the app bundles the gem" do
      allow(RailsAiContext::InstallMode).to receive(:standalone?).and_return(false)

      expect(missing_listen_check.fix).to eq("Add: `gem 'listen', group: :development`")
    end
  end

  describe "#check_introspector_health" do
    subject(:check) { doctor.send(:check_introspector_health) }

    def only_introspectors(*names)
      allow(RailsAiContext.configuration).to receive(:introspectors).and_return(names)
    end

    it "quotes the error the introspector returned" do
      only_introspectors(:database_stats)
      allow(ActiveRecord::Base).to receive(:connection)
        .and_raise(StandardError, "Database not found: no_such_db. Run bin/rails db:create")

      expect(check.status).to eq(:warn)
      expect(check.message).to include("database_stats")
      expect(check.fix).to include("database_stats: StandardError: Database not found: no_such_db")
      expect(check.fix).not_to include("stimulus")
    end

    it "runs every introspector inside one run, so they share its file lists and stats" do
      only_introspectors(:gems, :routes)
      stores = []
      [ RailsAiContext::Introspectors::GemIntrospector, RailsAiContext::Introspectors::RouteIntrospector ].each do |klass|
        allow_any_instance_of(klass).to receive(:call) { stores << Thread.current[RailsAiContext::RunCache::KEY] && {} }
      end

      check

      expect(stores.size).to eq(2)
      expect(stores).to all(be_a(Hash))
      expect(stores.first).to equal(stores.last)
    end

    it "keeps the message line to names when an introspector raises" do
      only_introspectors(:gems)
      allow_any_instance_of(RailsAiContext::Introspectors::GemIntrospector)
        .to receive(:call).and_raise(StandardError, "no Gemfile.lock here")

      expect(check.message).to eq("1 introspector returned errors: gems")
      expect(check.fix).to include("no Gemfile.lock here")
    end

    it "reports an introspector that raises a ScriptError" do
      only_introspectors(:gems)
      allow_any_instance_of(RailsAiContext::Introspectors::GemIntrospector)
        .to receive(:call).and_raise(SyntaxError, "app/models/user.rb:3: syntax error")

      expect(check.status).to eq(:warn)
      expect(check.fix).to include("app/models/user.rb:3: syntax error")
    end

    it "shows the first three errors and counts the rest" do
      only_introspectors(:gems, :routes, :schema, :controllers, :views)
      [
        RailsAiContext::Introspectors::GemIntrospector,
        RailsAiContext::Introspectors::RouteIntrospector,
        RailsAiContext::Introspectors::SchemaIntrospector,
        RailsAiContext::Introspectors::ControllerIntrospector,
        RailsAiContext::Introspectors::ViewIntrospector
      ].each do |klass|
        allow_any_instance_of(klass).to receive(:call).and_raise(StandardError, "boom")
      end

      expect(check.fix.scan("boom").size).to eq(3)
      expect(check.fix).to include("and 2 more introspectors")
    end

    it "keeps the rest of the report when a check raises a ScriptError" do
      allow(doctor).to receive(:check_introspector_health).and_raise(SyntaxError, "broken")
      result = nil

      expect { result = doctor.run }.to output(/check_introspector_health failed/).to_stderr
      expect(result[:checks].map(&:name)).to include("Schema")
    end
  end

  describe "#check_codex_env_staleness" do
    # A real file in a real app folder: the check reads it the way the
    # generator does, bytes and all.
    around do |example|
      Dir.mktmpdir do |dir|
        @root = File.realpath(dir)
        example.run
      end
    end

    subject(:check) { described_class.new(RailsAiContext::StaticApp.new(@root)).send(:check_codex_env_staleness) }

    def write_toml(content)
      FileUtils.mkdir_p(File.join(@root, ".codex"))
      File.binwrite(File.join(@root, ".codex/config.toml"), content)
    end

    context "when codex is not in ai_tools" do
      before do
        allow(RailsAiContext.configuration).to receive(:ai_tools).and_return(%i[claude cursor])
        write_toml(%([mcp_servers.rails-ai-context.env]\nGEM_HOME = "/nonexistent/gems"\n))
      end

      it "returns nil (skipped)" do
        expect(check).to be_nil
      end
    end

    context "when codex is in ai_tools" do
      before do
        allow(RailsAiContext.configuration).to receive(:ai_tools).and_return(%i[claude codex])
      end

      context "when .codex/config.toml does not exist" do
        it "returns nil (skipped)" do
          expect(check).to be_nil
        end
      end

      context "when .codex/config.toml exists but has no env section" do
        before do
          write_toml(<<~TOML)
            [mcp_servers.rails-ai-context]
            command = "bundle"
            args = ["exec", "rails", "ai:serve"]
          TOML
        end

        it "returns nil (skipped)" do
          expect(check).to be_nil
        end
      end

      # rbenv and asdf save a PATH and nothing else, so the PATH is what
      # says whether the snapshot still starts the server.
      context "when the snapshot holds a PATH only" do
        let(:bin) { bin_dir_with("rails-ai-context") }

        after { FileUtils.rm_rf(bin) }

        def write_snapshot(path)
          write_toml(<<~TOML)
            [mcp_servers.rails-ai-context]
            command = "rails-ai-context"
            args = ["serve"]

            [mcp_servers.rails-ai-context.env]
            PATH = "#{path}"
          TOML
        end

        it "passes while that PATH reaches the command" do
          write_snapshot("/nonexistent/ruby/9.9.9/bin:#{bin}")

          expect(check.status).to eq(:pass)
          expect(check.message).to eq("Codex env snapshot in .codex/config.toml is current: its PATH reaches `rails-ai-context`")
        end

        it "fails when it no longer does, naming the directory that is gone" do
          write_snapshot("/nonexistent/ruby/9.9.9/bin:#{bin_dir_with}")

          expect(check.status).to eq(:fail)
          expect(check.message).to eq("Codex MCP env snapshot in .codex/config.toml is stale - the PATH saved for rails-ai-context " \
                                      "no longer reaches `rails-ai-context` (/nonexistent/ruby/9.9.9/bin is gone)")
          expect(check.fix).to eq("Run `#{RailsAiContext::InstallMode.command(:install)}`")
        end
      end

      context "when GEM_HOME directory exists on disk" do
        let(:gem_home) { Dir.mktmpdir("gem_home_test") }
        let(:bin) { bin_dir_with("bundle") }

        after { FileUtils.rm_rf([ gem_home, bin ]) }

        before do
          write_toml(<<~TOML)
            [mcp_servers.rails-ai-context]
            command = "bundle"
            args = ["exec", "rails", "ai:serve"]

            [mcp_servers.rails-ai-context.env]
            GEM_HOME = "#{gem_home}"
            PATH = "#{bin}"
          TOML
        end

        it "returns a pass check" do
          expect(check.status).to eq(:pass)
          expect(check.name).to eq("Codex env snapshot")
          expect(check.message).to include(gem_home)
        end
      end

      context "when GEM_HOME directory no longer exists" do
        let(:stale_gem_home) { "/nonexistent/path/to/gems/3.3.0" }
        let(:bin) { bin_dir_with("bundle") }

        after { FileUtils.rm_rf(bin) }

        before do
          write_toml(<<~TOML)
            [mcp_servers.rails-ai-context]
            command = "bundle"
            args = ["exec", "rails", "ai:serve"]

            [mcp_servers.rails-ai-context.env]
            GEM_HOME = "#{stale_gem_home}"
            PATH = "#{bin}"
          TOML
        end

        it "returns a warn check with stale GEM_HOME path" do
          expect(check.status).to eq(:warn)
          expect(check.name).to eq("Codex env snapshot")
          expect(check.message).to include("stale")
          expect(check.message).to include(stale_gem_home)
          expect(check.fix).to include("install")
        end

        it "names only the command this install has" do
          allow(RailsAiContext::InstallMode).to receive(:standalone?).and_return(true)
          expect(check.fix).to eq("Run `rails-ai-context init`")

          allow(RailsAiContext::InstallMode).to receive(:standalone?).and_return(false)
          expect(described_class.new(RailsAiContext::StaticApp.new(@root)).send(:check_codex_env_staleness).fix)
            .to eq("Run `rails generate rails_ai_context:install`")
        end
      end

      # The generator saves GEM_PATH beside GEM_HOME, and a directory on it
      # goes stale the same way.
      context "with a GEM_PATH saved" do
        let(:gems) { Dir.mktmpdir("gem_path_test") }
        let(:bin) { bin_dir_with("rails-ai-context") }

        after { FileUtils.rm_rf([ gems, bin ]) }

        def write_gem_path(value)
          write_toml(<<~TOML)
            [mcp_servers.rails-ai-context]
            command = "rails-ai-context"
            args = ["serve"]

            [mcp_servers.rails-ai-context.env]
            PATH = "#{bin}"
            GEM_PATH = "#{value}"
          TOML
        end

        it "warns when a directory on it no longer exists" do
          write_gem_path("/nonexistent/ruby/3.3.5/gems:#{gems}")

          expect(check).to have_attributes(status: :warn,
                                           message: "Codex MCP env snapshot is stale - GEM_PATH names /nonexistent/ruby/3.3.5/gems, which no longer exists")
        end

        it "passes when every directory on it exists" do
          write_gem_path(gems)

          expect(check).to have_attributes(status: :pass,
                                           message: "Codex env snapshot in .codex/config.toml is current: its PATH reaches `rails-ai-context`, " \
                                                    "and every directory on its GEM_PATH exists")
        end
      end

      context "when env section is followed by another TOML section" do
        let(:gem_home) { Dir.mktmpdir("gem_home_boundary") }

        after { FileUtils.rm_rf(gem_home) }

        before do
          write_toml(<<~TOML)
            [mcp_servers.rails-ai-context]
            command = "bundle"
            args = ["exec", "rails", "ai:serve"]

            [mcp_servers.rails-ai-context.env]
            GEM_HOME = "#{gem_home}"

            [mcp_servers.other-tool]
            command = "other"
          TOML
        end

        it "correctly parses the env section and returns pass" do
          expect(check.status).to eq(:pass)
          expect(check.message).to include(gem_home)
        end
      end

      # A Windows GEM_HOME is written with its backslashes escaped.
      context "when GEM_HOME holds TOML escapes" do
        before do
          write_toml(%([mcp_servers.rails-ai-context]\ncommand = "rails-ai-context"\nargs = ["serve"]\n\n) +
                     %([mcp_servers.rails-ai-context.env]\nGEM_HOME = "C:\\\\Ruby33\\\\lib"\n))
        end

        it "names the path the snapshot holds" do
          expect(check.message).to include("GEM_HOME C:\\Ruby33\\lib no longer exists")
        end
      end

      # The file is shared by every app in a workspace; a byte outside ASCII
      # in a comment or a PATH must not stop the check in a C locale.
      context "when the file holds bytes outside ASCII" do
        before do
          write_toml("# caf\xC3\xA9 \xFF\n[mcp_servers.rails-ai-context]\ncommand = \"rails-ai-context\"\nargs = [\"serve\"]\n\n" \
                     "[mcp_servers.rails-ai-context.env]\nGEM_HOME = \"/nonexistent/gems\"\n".b)
        end

        it "still reads the snapshot" do
          expect(check.message).to include("/nonexistent/gems")
        end
      end

      # A hand-made entry under the gem's prefix that runs something else
      # is somebody's own, and its environment is theirs.
      context "when a section only shares the gem's name" do
        before do
          write_toml(<<~TOML)
            [mcp_servers.rails-ai-context-prod]
            command = "npx"
            args = ["mcp-remote", "https://prod.example/mcp"]

            [mcp_servers.rails-ai-context-prod.env]
            GEM_HOME = "/nonexistent/prod/gems"
          TOML
        end

        it "is not read" do
          expect(check).to be_nil
        end
      end
    end
  end

  describe "#check_initializer_guard" do
    subject(:check) { doctor.send(:check_initializer_guard) }

    let(:root) { Rails.application.root }
    let(:initializer_path) { File.join(root, "config/initializers/rails_ai_context.rb") }

    before do
      allow(File).to receive(:exist?).and_call_original
      allow(File).to receive(:read).and_call_original
    end

    context "when no initializer exists" do
      before { allow(File).to receive(:exist?).with(initializer_path).and_return(false) }

      it "returns nil" do
        expect(check).to be_nil
      end
    end

    context "when the initializer uses the bare defined? guard" do
      before do
        allow(File).to receive(:exist?).with(initializer_path).and_return(true)
        allow(File).to receive(:read).with(initializer_path).and_return(<<~RUBY)
          if defined?(RailsAiContext)
            RailsAiContext.configure do |config|
            end
          end
        RUBY
      end

      it "warns with a fix" do
        expect(check.status).to eq(:warn)
        expect(check.message).to include("defined?(RailsAiContext)")
        expect(check.fix).to include("respond_to?(:configure)")
      end

      it "offers the binary's init in a standalone install" do
        allow(RailsAiContext::InstallMode).to receive(:standalone?).and_return(true)

        expect(check.fix).to include("`rails-ai-context init`")
        expect(check.fix).not_to include("rails generate")
      end

      it "offers the generator where the app bundles the gem" do
        allow(RailsAiContext::InstallMode).to receive(:standalone?).and_return(false)

        expect(check.fix).to include("`rails generate rails_ai_context:install`")
      end
    end

    # An unguarded file is correct in an app that bundles the gem everywhere,
    # so this is a warn about another environment, never a fail.
    context "when the initializer has no guard at all" do
      before do
        allow(File).to receive(:exist?).with(initializer_path).and_return(true)
        allow(File).to receive(:read).with(initializer_path).and_return(<<~RUBY)
          RailsAiContext.configure do |config|
          end
        RUBY
      end

      it "warns that it breaks where the gem is not loaded" do
        expect(check.status).to eq(:warn)
        expect(check.message).to include("no recognised guard")
        expect(check.fix).to include("defined?(RailsAiContext)")
      end
    end

    context "when the initializer already guards with respond_to?" do
      before do
        allow(File).to receive(:exist?).with(initializer_path).and_return(true)
        allow(File).to receive(:read).with(initializer_path).and_return(<<~RUBY)
          if defined?(RailsAiContext) && RailsAiContext.respond_to?(:configure)
            RailsAiContext.configure do |config|
            end
          end
        RUBY
      end

      it "returns nil" do
        expect(check).to be_nil
      end
    end

    # The two generated spellings are not the only working guards, and a
    # readiness score must not be docked for a file that is already safe.
    context "when the initializer guards on respond_to? alone" do
      before do
        allow(File).to receive(:exist?).with(initializer_path).and_return(true)
        allow(File).to receive(:read).with(initializer_path).and_return(<<~RUBY)
          if RailsAiContext.respond_to?(:configure)
            RailsAiContext.configure do |config|
            end
          end
        RUBY
      end

      it "returns nil" do
        expect(check).to be_nil
      end
    end

    context "when the initializer returns early unless the gem is defined" do
      before do
        allow(File).to receive(:exist?).with(initializer_path).and_return(true)
        allow(File).to receive(:read).with(initializer_path).and_return(<<~RUBY)
          return unless defined?(RailsAiContext::Configuration)

          RailsAiContext.configure do |config|
          end
        RUBY
      end

      it "returns nil" do
        expect(check).to be_nil
      end
    end

    context "when the only mention of a guard comes after the configure call" do
      before do
        allow(File).to receive(:exist?).with(initializer_path).and_return(true)
        allow(File).to receive(:read).with(initializer_path).and_return(<<~RUBY)
          RailsAiContext.configure do |config|
          end

          # TODO: wrap this in defined?(RailsAiContext)
        RUBY
      end

      it "still warns" do
        expect(check.status).to eq(:warn)
        expect(check.message).to include("no recognised guard")
      end
    end
  end

  # A lockfile as Bundler writes one, holding the gems named.
  def lockfile(*gems)
    specs = gems.map { |name| "    #{name} (1.0.0)\n" }.join
    "GEM\n  remote: https://rubygems.org/\n  specs:\n#{specs}\nPLATFORMS\n  ruby\n\nDEPENDENCIES\n" \
      "#{gems.map { |name| "  #{name}\n" }.join}\nBUNDLED WITH\n   2.5.0\n"
  end

  # A directory holding an executable of each name, to stand for a client's PATH.
  def bin_dir_with(*names)
    dir = Dir.mktmpdir("bin")
    names.each do |name|
      File.write(File.join(dir, name), "#!/bin/sh\n")
      File.chmod(0o755, File.join(dir, name))
    end
    dir
  end

  describe "#check_mcp_json" do
    # Real files in a real app folder: the check reads them the way the
    # generator does.
    around do |example|
      Dir.mktmpdir do |dir|
        @root = File.realpath(dir)
        @bin = bin_dir_with("bundle", "rails-ai-context")
        example.run
      ensure
        FileUtils.rm_rf(@bin)
      end
    end

    let(:app_doctor) { described_class.new(RailsAiContext::StaticApp.new(@root)) }

    subject(:check) { app_doctor.send(:check_mcp_json) }

    before { allow(app_doctor).to receive(:client_path).and_return(@bin) }

    def write(path, content)
      FileUtils.mkdir_p(File.dirname(File.join(@root, path)))
      File.binwrite(File.join(@root, path), content)
    end

    def server(command)
      JSON.generate("mcpServers" => { "rails-ai-context" => { "command" => command.first, "args" => command.drop(1) } })
    end

    let(:bundled) { %w[bundle exec rails-ai-context serve] }
    let(:bare) { %w[rails-ai-context serve] }

    context "when tool_mode is :cli" do
      before do
        allow(RailsAiContext.configuration).to receive(:tool_mode).and_return(:cli)
      end

      it "returns pass with skip message" do
        expect(check.status).to eq(:pass)
        expect(check.message).to include("CLI-only")
      end
    end

    context "when multiple tools configured, some configs missing" do
      before do
        allow(RailsAiContext.configuration).to receive(:tool_mode).and_return(:mcp)
        allow(RailsAiContext.configuration).to receive(:ai_tools).and_return(%i[claude cursor copilot])
        write(".mcp.json", server(bundled))
      end

      it "aggregates all failures into a single check" do
        expect(check.status).to eq(:warn)
        expect(check.message).to include("2 of 3")
        expect(check.message).to include(".cursor/mcp.json")
        expect(check.message).to include(".vscode/mcp.json")
        expect(check.fix).to eq("Run `#{RailsAiContext::InstallMode.command(:install)}` to fix")
      end
    end

    context "when all configs present and valid" do
      before do
        allow(RailsAiContext.configuration).to receive(:tool_mode).and_return(:mcp)
        allow(RailsAiContext.configuration).to receive(:ai_tools).and_return(%i[claude opencode])
        write(".mcp.json", server(bundled))
        write("opencode.json", JSON.generate("mcp" => { "rails-ai-context" => { "type" => "local", "command" => bundled } }))
      end

      it "returns pass with count" do
        expect(check.status).to eq(:pass)
        expect(check.message).to include("2 of 2")
      end
    end

    # VS Code keeps its mcp.json as JSONC, and doctor failed one with
    # trailing commas whose entry was there and current.
    context "when a config has trailing commas, as VS Code writes them" do
      before do
        skip "json #{JSON::VERSION} reads no trailing commas" if Gem::Version.new(JSON::VERSION) < Gem::Version.new("2.9")
        allow(RailsAiContext.configuration).to receive(:tool_mode).and_return(:mcp)
        allow(RailsAiContext.configuration).to receive(:ai_tools).and_return(%i[copilot])
        write(".vscode/mcp.json", %({\n  "servers": {\n    "rails-ai-context": { "command": "bundle", ) +
                                  %("args": ["exec", "rails-ai-context", "serve",], },\n  },\n}\n))
      end

      it "reads it as VS Code does, and passes it" do
        expect(check.status).to eq(:pass)
      end
    end

    context "when no tools configured (defaults to all)" do
      before do
        allow(RailsAiContext.configuration).to receive(:tool_mode).and_return(:mcp)
        allow(RailsAiContext.configuration).to receive(:ai_tools).and_return(nil)
        %w[.mcp.json .cursor/mcp.json].each { |path| write(path, server(bundled)) }
        write(".vscode/mcp.json", JSON.generate("servers" => { "rails-ai-context" => { "command" => "bundle", "args" => bundled.drop(1) } }))
        write("opencode.json", JSON.generate("mcp" => { "rails-ai-context" => { "type" => "local", "command" => bundled } }))
        write(".codex/config.toml", %([mcp_servers.rails-ai-context]\ncommand = "bundle"\nargs = ["exec", "rails-ai-context", "serve"]\n))
      end

      it "checks all 5 tools and returns pass" do
        expect(check.status).to eq(:pass)
        expect(check.message).to include("5 of 5")
      end
    end

    # A config the client reads but that names no server of the gem's starts none.
    context "when a config holds no rails-ai-context server" do
      before do
        allow(RailsAiContext.configuration).to receive(:tool_mode).and_return(:mcp)
        allow(RailsAiContext.configuration).to receive(:ai_tools).and_return(%i[claude codex])
        write(".mcp.json", '{"mcpServers":{"github":{"command":"gh-mcp"}}}')
        write(".codex/config.toml", "")
      end

      it "warns about each, with the install as the fix" do
        expect(check.status).to eq(:warn)
        expect(check.message).to eq("2 of 2 MCP configs need attention: .mcp.json (Claude Code), .codex/config.toml (Codex CLI): " \
                                    "holds no rails-ai-context server")
        expect(check.fix).to eq("Run `#{RailsAiContext::InstallMode.command(:install)}` to fix")
      end
    end

    # The user's own entry under the gem's name, an HTTP one, is theirs to judge.
    context "when the entry under the gem's name runs no command" do
      before do
        allow(RailsAiContext.configuration).to receive(:tool_mode).and_return(:mcp)
        allow(RailsAiContext.configuration).to receive(:ai_tools).and_return(%i[claude])
        write(".mcp.json", '{"mcpServers":{"rails-ai-context":{"type":"http","url":"http://localhost:6029/mcp"}}}')
      end

      it "passes it" do
        expect(check.status).to eq(:pass)
      end
    end

    # The install wrote its table beside an entry it did not read, and the
    # check passed a config Codex refuses to read.
    context "when the Codex config declares the gem's server twice" do
      before do
        allow(RailsAiContext.configuration).to receive(:tool_mode).and_return(:mcp)
        allow(RailsAiContext.configuration).to receive(:ai_tools).and_return(%i[codex])
      end

      it "fails one spelled two ways, with deleting all but one as the fix" do
        write(".codex/config.toml", %([mcp_servers]\nrails-ai-context = { command = "rails-ai-context", args = ["serve"] }\n\n) +
                                    %([mcp_servers.rails-ai-context]\ncommand = "rails-ai-context"\nargs = ["serve"]\n))

        expect(check.status).to eq(:fail)
        expect(check.message).to end_with(".codex/config.toml (Codex CLI): it declares rails-ai-context twice, which Codex refuses to read")
        expect(check.fix).to eq("Delete all but one by hand")
      end

      it "fails two tables, one name quoted, with the install as the fix, which merges them" do
        write(".codex/config.toml", %([mcp_servers."rails-ai-context"]\ncommand = "rails-ai-context"\n\n) +
                                    %([mcp_servers.rails-ai-context]\ncommand = "rails-ai-context"\n))

        expect(check.status).to eq(:fail)
        expect(check.fix).to eq("Run `#{RailsAiContext::InstallMode.command(:install)}` to fix")
      end
    end

    context "when the Codex config sets the gem's server as an inline table" do
      before do
        allow(RailsAiContext.configuration).to receive(:tool_mode).and_return(:mcp)
        allow(RailsAiContext.configuration).to receive(:ai_tools).and_return(%i[codex])
        write(".codex/config.toml", %([mcp_servers]\nrails-ai-context = { command = "rails-ai-context", args = ["serve"] }\n))
      end

      it "reads the entry and warns that the install leaves it as it is" do
        expect(check.status).to eq(:warn)
        expect(check.message).to end_with("it sets rails-ai-context as an inline table or with dotted keys, which the install does not rewrite")
        expect(check.fix).to start_with("Write it as a [mcp_servers.rails-ai-context] table by hand")
      end
    end

    # A Latin-1 byte in a quoted server name raised inside the check, which
    # dropped the MCP row; Codex refuses such a file outright.
    context "when the Codex config is not UTF-8" do
      before do
        allow(RailsAiContext.configuration).to receive(:tool_mode).and_return(:mcp)
        allow(RailsAiContext.configuration).to receive(:ai_tools).and_return(%i[codex])
        write(".codex/config.toml", "[mcp_servers.\"caf\xE9\"]\ncommand = \"x\"\n\n[mcp_servers.rails-ai-context]\n" \
                                    "command = \"rails-ai-context\"\nargs = [\"serve\"]\n".b)
      end

      it "fails it as a file Codex cannot read" do
        expect(check.status).to eq(:fail)
        expect(check.message).to end_with(".codex/config.toml (Codex CLI): Codex CLI cannot read it: it is not UTF-8, which TOML is")
        expect(check.fix).to eq("Save it as UTF-8")
      end
    end

    # After `bundle remove rails-ai-context` every config still runs bundle
    # exec, which Bundler refuses: the gem is not in the bundle.
    context "when an entry runs bundle exec and the app's bundle has no rails-ai-context" do
      before do
        allow(RailsAiContext.configuration).to receive(:tool_mode).and_return(:mcp)
        allow(RailsAiContext.configuration).to receive(:ai_tools).and_return(%i[claude cursor])
        write("Gemfile", %(gem "rails"\n))
        write("Gemfile.lock", lockfile("rails"))
        %w[.mcp.json .cursor/mcp.json].each { |path| write(path, server(bundled)) }
      end

      it "fails, naming the lockfile and the binary's init" do
        expect(check.status).to eq(:fail)
        expect(check.message).to eq("2 of 2 MCP configs need attention: .mcp.json (Claude Code), .cursor/mcp.json (Cursor): " \
                                    "`bundle exec rails-ai-context serve` cannot start - Gemfile.lock has no rails-ai-context")
        expect(check.fix).to eq("Run `rails-ai-context init` to fix")
      end
    end

    # The bare binary in an app whose bundle carries the gem starts the copy
    # installed outside the bundle, beside the bundle's own.
    context "when an entry runs the bare binary and the app's bundle carries rails-ai-context" do
      before do
        allow(RailsAiContext.configuration).to receive(:tool_mode).and_return(:mcp)
        allow(RailsAiContext.configuration).to receive(:ai_tools).and_return(%i[claude])
        write("Gemfile", %(gem "rails"\ngem "rails-ai-context"\n))
        write("Gemfile.lock", lockfile("rails", "rails-ai-context"))
        write(".mcp.json", server(bare))
      end

      it "warns and names the install that writes bundle exec" do
        expect(check.status).to eq(:warn)
        expect(check.message).to include("`rails-ai-context serve` needs the gem installed outside the app's bundle, " \
                                         "while Gemfile.lock carries rails-ai-context 1.0.0")
        expect(check.fix).to eq("Run `rails generate rails_ai_context:install` to fix")
      end

      it "fails when the binary is not on PATH either" do
        allow(app_doctor).to receive(:client_path).and_return(bin_dir_with)

        expect(check.status).to eq(:fail)
        expect(check.message).to include("`rails-ai-context serve` cannot start - `rails-ai-context` is not on PATH")
      end
    end

    context "when the command an entry runs is not on PATH" do
      before do
        allow(RailsAiContext.configuration).to receive(:tool_mode).and_return(:mcp)
        allow(RailsAiContext.configuration).to receive(:ai_tools).and_return(%i[claude copilot])
        allow(app_doctor).to receive(:client_path).and_return(bin_dir_with("bundle"))
        write(".mcp.json", server(bare))
        # A PATH the entry sets itself is the one its server gets.
        write(".vscode/mcp.json", JSON.generate("servers" => {
          "rails-ai-context" => { "command" => "bundle", "args" => bundled.drop(1), "env" => { "PATH" => "/nonexistent/bin" } }
        }))
      end

      it "fails each, naming the PATH it was looked up on" do
        expect(check.status).to eq(:fail)
        expect(check.message).to include(".mcp.json (Claude Code): `rails-ai-context serve` cannot start - `rails-ai-context` is not on PATH")
        expect(check.message).to include(".vscode/mcp.json (GitHub Copilot): `bundle exec rails-ai-context serve` cannot start - " \
                                         "`bundle` is not on the PATH its env sets")
        expect(check.fix).to include("Run `gem install rails-ai-context` for the Ruby on PATH")
      end
    end

    # A path: copy whose gemspec lists no executable leaves `bundle exec
    # rails-ai-context` nothing to run.
    context "when the bundle's copy of the gem lists no executable" do
      before do
        allow(RailsAiContext.configuration).to receive(:tool_mode).and_return(:mcp)
        allow(RailsAiContext.configuration).to receive(:ai_tools).and_return(%i[claude])
        write("Gemfile", %(gem "rails-ai-context", path: "vendor/rails-ai-context"\n))
        write("Gemfile.lock", lockfile("rails-ai-context"))
        write(".mcp.json", server(bundled))
        allow(app_doctor).to receive(:bundled_gem_spec).with(File.join(@root, "Gemfile"))
          .and_return(instance_double(Gem::Specification, executables: [], full_gem_path: "/vendor/rails-ai-context"))
      end

      it "fails and says where that copy is" do
        expect(check.status).to eq(:fail)
        expect(check.message).to include("`bundle exec rails-ai-context serve` cannot start - the bundle's rails-ai-context at " \
                                         "/vendor/rails-ai-context lists no `rails-ai-context` executable")
      end
    end

    context "when a JSON config has invalid JSON" do
      before do
        allow(RailsAiContext.configuration).to receive(:tool_mode).and_return(:mcp)
        allow(RailsAiContext.configuration).to receive(:ai_tools).and_return(%i[claude])
        write(".mcp.json", "not json{{{")
      end

      it "returns fail status with tool label" do
        expect(check.status).to eq(:fail)
        expect(check.message).to include("1 of 1")
        expect(check.message).to include(".mcp.json (Claude Code): it does not parse as JSON")
      end

      # The install refuses a file holding comments whichever json version
      # reads it, and doctor names the same problem.
      it "names comments as the problem, as the install does" do
        allow(RailsAiContext.configuration).to receive(:ai_tools).and_return(%i[copilot])
        write(".vscode/mcp.json", %({\n  // the gem's\n  "servers": {"rails-ai-context": {"command": "bundle"} "other": {}}\n}))

        expect(check.message).to eq("1 of 1 MCP config needs attention: .vscode/mcp.json (GitHub Copilot): " \
                                    "#{RailsAiContext::McpConfigGenerator::COMMENTS_PROBLEM}")
      end

      # Claude Code reads .mcp.json with JSON.parse, so a trailing comma or a
      # comment there leaves it no server, whatever a JSONC reader makes of
      # the file; doctor passed one whose entry was current.
      it "fails a config its client reads as JSON when it holds a trailing comma or comments" do
        entry = %("rails-ai-context": {"command": "rails-ai-context", "args": ["serve"]})
        write(".mcp.json", %({\n  "mcpServers": {\n    #{entry},\n  },\n}\n))

        expect(check.status).to eq(:fail)
        expect(check.message).to end_with(".mcp.json (Claude Code): Claude Code cannot read it: it holds a trailing comma, " \
                                          "which JSON does not allow")

        write(".mcp.json", %({\n  // the gem's\n  "mcpServers": {#{entry}}\n}\n))
        expect(app_doctor.send(:check_mcp_json).message).to end_with("Claude Code cannot read it: it holds comments, which JSON does not allow")
      end

      # Install leaves a file it cannot parse as it is, so running it alone
      # would change nothing.
      it "asks for the file to be made valid before init runs, in a standalone install" do
        allow(RailsAiContext::InstallMode).to receive(:standalone?).and_return(true)

        expect(check.fix).to eq("Make .mcp.json valid JSON holding an object (the install leaves a file it cannot merge into as it is), " \
                                "then run `rails-ai-context init`")
      end
    end

    # The install refuses to merge into anything but an object.
    context "when a JSON config parses but holds no object to merge into" do
      before do
        allow(RailsAiContext.configuration).to receive(:tool_mode).and_return(:mcp)
        allow(RailsAiContext.configuration).to receive(:ai_tools).and_return(%i[claude copilot])
        write(".mcp.json", "[1, 2]")
        write(".vscode/mcp.json", %({"servers": ["x"]}))
      end

      it "reports both, as the install would refuse them" do
        expect(check.status).to eq(:fail)
        expect(check.message).to include("2 of 2")
        expect(check.fix).to start_with("Make .mcp.json, .vscode/mcp.json valid JSON holding an object")
        expect(described_class.new(RailsAiContext::StaticApp.new(@root)).run[:checks].map(&:message).join)
          .not_to include("has invalid JSON")
      end
    end

    context "when a JSON config is empty, or starts with a byte order mark" do
      before do
        allow(RailsAiContext.configuration).to receive(:tool_mode).and_return(:mcp)
        allow(RailsAiContext.configuration).to receive(:ai_tools).and_return(%i[claude copilot])
        write(".mcp.json", "\uFEFF\n")
        write(".vscode/mcp.json", %(\uFEFF{"servers": {"rails-ai-context": {"command": "bundle", "args": ["exec", "rails-ai-context", "serve"]}}}))
      end

      # init fills an empty file, so init is the fix.
      it "asks init to fill the empty one and reads the other" do
        expect(check.status).to eq(:warn)
        expect(check.message).to include("1 of 2", ".mcp.json")
        expect(check.fix).to eq("Run `#{RailsAiContext::InstallMode.command(:install)}` to fix")
      end
    end

    # A config shared by every app in a workspace may hold any bytes.
    context "when a JSON config holds bytes outside ASCII" do
      before do
        allow(RailsAiContext.configuration).to receive(:tool_mode).and_return(:mcp)
        allow(RailsAiContext.configuration).to receive(:ai_tools).and_return(%i[claude])
        write(".mcp.json", %({"mcpServers":{"caf\xC3\xA9":{"command":"x"},"rails-ai-context":{"command":"bundle","args":["exec","rails-ai-context","serve"]}}}).b)
      end

      it "reads it as UTF-8 whatever the locale" do
        expect(check.status).to eq(:pass)
      end
    end
  end

  describe "#check_stdio_activation_hygiene" do
    around do |example|
      Dir.mktmpdir do |dir|
        @root = File.realpath(dir)
        example.run
      end
    end

    let(:app_doctor) { described_class.new(RailsAiContext::StaticApp.new(@root)) }

    before do
      allow(RailsAiContext.configuration).to receive(:tool_mode).and_return(:mcp)
      allow(RailsAiContext.configuration).to receive(:ai_tools).and_return(%i[claude])
      allow(RailsAiContext::InstallMode).to receive(:standalone?).and_return(false)
    end

    def write_config(command)
      File.write(File.join(@root, ".mcp.json"), JSON.generate("mcpServers" => { "rails-ai-context" => { "command" => command.first, "args" => command.drop(1) } }))
    end

    it "takes bundler's word for an in-Gemfile install whose configs run bundle exec" do
      write_config(%w[bundle exec rails-ai-context serve])

      expect(app_doctor.send(:check_stdio_activation_hygiene).message).to include("activates via bundler")
    end

    # The binary outside the bundle activates through RubyGems, whatever the install.
    it "checks the activation when a config starts the binary itself" do
      write_config(%w[rails-ai-context serve])
      status = instance_double(Process::Status, success?: true, exitstatus: 0)
      allow(Open3).to receive(:capture3).and_return([ "", "", status ])

      expect(app_doctor.send(:check_stdio_activation_hygiene).message).to eq("gem activation is silent on stdout")
    end
  end

  # Only the bundle this process runs in has its gemspec loaded here.
  describe "#bundled_gem_spec" do
    it "answers for the Gemfile this process was bundled from, and for no other" do
      doctor = described_class.new(Rails.application)

      expect(doctor.send(:bundled_gem_spec, Bundler.default_gemfile.to_s)).to equal(Gem.loaded_specs["rails-ai-context"])
      expect(doctor.send(:bundled_gem_spec, File.join(Dir.tmpdir, "Gemfile"))).to be_nil
    end
  end

  # An app in a workspace is served from the folder above it, by an entry
  # named rails-ai-context-<app> that points --app-path at it.
  describe "an app set up as part of a workspace" do
    around do |example|
      Dir.mktmpdir do |dir|
        @work = File.realpath(dir)
        FileUtils.mkdir_p(File.join(@work, "a"))
        example.run
      end
    end

    let(:app_root) { File.join(@work, "a") }
    let(:workspace_doctor) { described_class.new(RailsAiContext::StaticApp.new(app_root)) }

    before do
      allow(RailsAiContext.configuration).to receive(:tool_mode).and_return(:mcp)
      allow(RailsAiContext.configuration).to receive(:ai_tools).and_return(%i[claude codex])
      allow(workspace_doctor).to receive(:client_path).and_return(bin_dir_with("bundle", "rails-ai-context"))
    end

    def write(path, content)
      FileUtils.mkdir_p(File.dirname(File.join(@work, path)))
      File.write(File.join(@work, path), content)
    end

    # A workspace entry reaches its app's bundle through the Gemfile its env
    # names, from the folder's own name for itself where the tool has one.
    it "reads the bundle a workspace entry's BUNDLE_GEMFILE names" do
      allow(RailsAiContext.configuration).to receive(:ai_tools).and_return(%i[cursor])
      write("a/Gemfile", %(gem "rails"\n))
      write("a/Gemfile.lock", lockfile("rails"))
      write(".cursor/mcp.json", JSON.generate("mcpServers" => {
        "rails-ai-context-a" => { "command" => "bundle", "args" => %w[exec rails-ai-context serve --app-path ${workspaceFolder}/a],
                                  "env" => { "BUNDLE_GEMFILE" => "${workspaceFolder}/a/Gemfile" } }
      }))

      check = workspace_doctor.send(:check_mcp_json)

      expect(check.status).to eq(:fail)
      expect(check.message).to include("`bundle exec rails-ai-context serve` cannot start - Gemfile.lock has no rails-ai-context")
      expect(check.fix).to eq("Run `rails-ai-context init` in the folder that holds ../.cursor/mcp.json to fix")
    end

    it "finds its MCP configs in the workspace and names where they are" do
      write(".mcp.json", JSON.generate("mcpServers" => {
        "rails-ai-context-a" => { "command" => "rails-ai-context", "args" => %w[serve --app-path a] }
      }))
      write(".codex/config.toml", %([mcp_servers.rails-ai-context-a]\ncommand = "rails-ai-context"\nargs = ["serve", "--app-path", "a"]\n))

      check = workspace_doctor.send(:check_mcp_json)

      expect(check.status).to eq(:pass)
      expect(check.message).to include("2 of 2")
    end

    it "still asks for a config when the workspace's serves other apps only" do
      write(".mcp.json", JSON.generate("mcpServers" => {
        "rails-ai-context-b" => { "command" => "rails-ai-context", "args" => %w[serve --app-path b] }
      }))

      check = workspace_doctor.send(:check_mcp_json)

      expect(check.status).to eq(:warn)
      expect(check.message).to include(".mcp.json")
    end

    # The folder's config cannot say whether it serves this app, and is the
    # one a client opened at the folder reads.
    it "names a config of the gem's above it that does not parse" do
      allow(RailsAiContext.configuration).to receive(:ai_tools).and_return(%i[copilot])
      write(".vscode/mcp.json", %({"servers": {"rails-ai-context-a": {"command": "rails-ai-context"}))

      check = workspace_doctor.send(:check_mcp_json)

      expect(check.status).to eq(:fail)
      expect(check.message).to include(".vscode/mcp.json")
      expect(check.fix).to eq("Make ../.vscode/mcp.json valid JSON holding an object (the install leaves a file it cannot merge " \
                              "into as it is), then run `rails-ai-context init` in the folder that holds it")
    end

    it "passes over a config above it that names no server of the gem's" do
      allow(RailsAiContext.configuration).to receive(:ai_tools).and_return(%i[copilot])
      write(".vscode/mcp.json", %({"servers": {"github": {"url": "x"}))

      check = workspace_doctor.send(:check_mcp_json)

      expect(check.status).to eq(:warn)
      expect(check.fix).to eq("Run `#{RailsAiContext::InstallMode.command(:install)}` to fix")
    end

    it "checks the Codex env snapshot of every server the gem wrote there" do
      Dir.mktmpdir("gem_home") do |gem_home|
        write(".codex/config.toml", <<~TOML)
          [mcp_servers.rails-ai-context-a]
          command = "rails-ai-context"
          args = ["serve", "--app-path", "a"]

          [mcp_servers.rails-ai-context-a.env]
          GEM_HOME = "#{gem_home}"

          [mcp_servers.rails-ai-context-b]
          command = "rails-ai-context"
          args = ["serve", "--app-path", "b"]

          [mcp_servers.rails-ai-context-b.env]
          GEM_HOME = "/nonexistent/gems/3.3.0"
        TOML

        check = workspace_doctor.send(:check_codex_env_staleness)

        expect(check.status).to eq(:warn)
        expect(check.message).to include("/nonexistent/gems/3.3.0")
      end
    end

    # The workspace's snapshot is what Codex starts this app's server with.
    it "fails when the PATH a workspace entry saved no longer reaches its command" do
      write(".codex/config.toml", <<~TOML)
        [mcp_servers.rails-ai-context-a]
        command = "rails-ai-context"
        args = ["serve", "--app-path", "a"]

        [mcp_servers.rails-ai-context-a.env]
        PATH = "/nonexistent/ruby/9.9.9/bin"
      TOML

      check = workspace_doctor.send(:check_codex_env_staleness)

      expect(check.status).to eq(:fail)
      expect(check.message).to include("the PATH saved for rails-ai-context-a no longer reaches `rails-ai-context`")
      expect(check.fix).to eq("Run `rails-ai-context init` in the folder that holds ../.codex/config.toml")
    end
  end

  describe "#check_security_gitignore" do
    def gitignore_check_for(root)
      described_class.new(RailsAiContext::StaticApp.new(root)).send(:check_security_gitignore)
    end

    def app_with(files)
      Dir.mktmpdir do |dir|
        files.each do |path, content|
          FileUtils.mkdir_p(File.dirname(File.join(dir, path)))
          File.write(File.join(dir, path), content)
        end
        yield dir
      end
    end

    it "passes and says so when no secret file exists" do
      app_with("app/models/user.rb" => "class User; end\n") do |dir|
        check = gitignore_check_for(dir)

        expect(check.status).to eq(:pass)
        expect(check.message).to eq("No secret files found")
      end
    end

    # A stock app commits all of these, and none holds a secret: the
    # credentials are encrypted, and the configs read their passwords
    # through ERB.
    it "passes a stock app's committed files" do
      files = {
        "config/credentials.yml.enc" => "x\n", "config/master.key" => "x\n", ".gitignore" => "/.env*\n/config/*.key\n",
        "config/database.yml" => "production:\n  database: shop\n  password: <%= ENV[\"SHOP_DATABASE_PASSWORD\"] %>\n  pool: 5\n",
        "config/storage.yml" => "local:\n  service: Disk\n  root: <%= Rails.root.join(\"storage\") %>\n",
        "config/cable.yml" => "development:\n  adapter: async\nproduction:\n  url: <%= ENV.fetch(\"REDIS_URL\") { \"redis://localhost:6379/1\" } %>\n"
      }
      app_with(files) do |dir|
        check = gitignore_check_for(dir)

        expect(check.status).to eq(:pass)
        expect(check.message).to eq("Secret files gitignored: config/master.key")
      end
    end

    it "warns about a config that holds a secret as a literal, naming the line" do
      app_with("config/database.yml" => "development:\n  adapter: postgresql\n  password: hunter2 # local only\n",
               "config/cable.yml" => "production:\n  url: redis://:s3cret@redis.internal:6379/1\n", ".gitignore" => "/.env*\n") do |dir|
        check = gitignore_check_for(dir)

        expect(check.status).to eq(:warn)
        expect(check.message).to eq("A literal secret in config/cable.yml (`url` on line 2), config/database.yml (`password` on line 3), " \
                                    "which .gitignore does not cover")
        expect(check.fix).to include("<%= ENV[")
      end
    end

    it "passes over a literal secret in a config .gitignore covers" do
      app_with("config/database.yml" => "development:\n  password: hunter2\n", ".gitignore" => "/config/database.yml\n") do |dir|
        expect(gitignore_check_for(dir).status).to eq(:pass)
      end
    end

    # The check looked for three names while the tools refuse a list of patterns.
    it "checks every file the tools refuse, and names each one and whether it is ignored" do
      files = { "config/application.yml" => "k: v\n", ".env" => "A=1\n", "config/ssl/server.pem" => "x\n",
                "node_modules/pkg/test.pem" => "x\n", ".gitignore" => "config/application.yml\n" }
      app_with(files) do |dir|
        check = gitignore_check_for(dir)

        expect(check.status).to eq(:fail)
        expect(check.message).to eq(".env not in .gitignore; also committed: config/ssl/server.pem")
        expect(check.fix).to include("`.env`")
      end
    end

    # Rails' own .gitignore leaves out every .env file, as the tools do.
    it "fails an environment file .gitignore does not cover, whatever environment it names" do
      app_with(".env.development" => "A=1\n", "config/application.yml" => "k: v\n", ".gitignore" => "/config/application.yml\n") do |dir|
        check = gitignore_check_for(dir)

        expect(check.status).to eq(:fail)
        expect(check.message).to eq(".env.development not in .gitignore")
      end
    end

    it "leaves a committed placeholder such as .env.example out of the files the tools refuse" do
      app_with(".env.example" => "A=\n", ".env" => "A=1\n", ".gitignore" => "/.env\n") do |dir|
        check = gitignore_check_for(dir)

        expect(check.status).to eq(:pass)
        expect(check.message).to eq("Secret files gitignored: .env")
      end
    end

    it "lists the sensitive files it found when every one is ignored" do
      app_with("config/application.yml" => "k: v\n", "config/master.key" => "x\n",
               ".gitignore" => "/config/application.yml\n/config/master.key\n") do |dir|
        check = gitignore_check_for(dir)

        expect(check.status).to eq(:pass)
        expect(check.message).to eq("Secret files gitignored: config/application.yml, config/master.key")
      end
    end

    it "reports a missing .gitignore, not a missing entry" do
      app_with("config/master.key" => "x\n") do |dir|
        check = gitignore_check_for(dir)

        expect(check.status).to eq(:fail)
        expect(check.message).to include("No .gitignore found", "config/master.key")
        expect(check.fix).to include("Create .gitignore with", "config/master.key")
      end
    end

    # The encrypted credentials are committed by design; the key is what stays out.
    it "advises gitignoring the key, never the encrypted credentials, when there is no .gitignore" do
      app_with("config/master.key" => "x\n", "config/credentials.yml.enc" => "x\n", "config/database.yml" => "x\n") do |dir|
        check = gitignore_check_for(dir)

        expect(check.status).to eq(:fail)
        expect(check.message).to eq("No .gitignore found - config/master.key would be committed")
        expect(check.fix).to eq("Create .gitignore with: `config/master.key`")
      end
      app_with("config/credentials.yml.enc" => "x\n", "config/credentials/production.yml.enc" => "x\n") do |dir|
        check = gitignore_check_for(dir)

        expect(check.status).to eq(:pass)
        expect(check.message).to eq("No secret files found")
      end
    end

    # The Codex config carries this machine's PATH and GEM_HOME, which is why
    # install gitignores it; the check never asked whether that survived.
    it "reports the Codex config as unignored, and passes once .gitignore covers it" do
      app_with(".codex/config.toml" => "[mcp_servers.rails-ai-context]\n", ".gitignore" => "log/\n") do |dir|
        check = gitignore_check_for(dir)
        expect(check.status).to eq(:fail)
        expect(check.message).to include(".codex/config.toml")

        File.write(File.join(dir, ".gitignore"), ".codex/config.toml\n")
        expect(gitignore_check_for(dir).status).to eq(:pass)
      end
    end

    # Git answers what a commit takes: every ignore rule it reads, and the
    # files it tracks already, which no rule takes back out.
    context "inside a git repository" do
      def git(dir, *args)
        system("git", "-C", dir, *args, out: File::NULL, err: File::NULL) or raise "git #{args.join(' ')} failed"
      end

      def repo_with(files)
        app_with(files) do |dir|
          git(dir, "init", "-q")
          yield dir
        end
      end

      # A monorepo keeps its rules at its root, above the app.
      it "reads the ignore rules above the app" do
        repo_with(".gitignore" => "/backend/config/master.key\n", "backend/config/master.key" => "x\n") do |dir|
          check = gitignore_check_for(File.join(dir, "backend"))

          expect(check).to have_attributes(status: :pass, message: "Secret files gitignored: config/master.key")
        end
      end

      it "reads info/exclude" do
        repo_with("config/master.key" => "x\n") do |dir|
          File.write(File.join(dir, ".git", "info", "exclude"), "/config/master.key\n")

          expect(gitignore_check_for(dir)).to have_attributes(status: :pass, message: "Secret files gitignored: config/master.key")
        end
      end

      it "fails a key git tracks whatever .gitignore says, naming the command that stops tracking it" do
        repo_with(".gitignore" => "/config/*.key\n", "config/master.key" => "x\n") do |dir|
          git(dir, "add", "-f", "config/master.key")

          expect(gitignore_check_for(dir)).to have_attributes(status: :fail, message: "config/master.key is committed",
                                                              fix: "Run `git rm --cached config/master.key` and rotate it: the history still holds it")
        end
      end

      it "asks for an ignore rule as well when none covers the committed key" do
        repo_with(".gitignore" => "log/\n", "config/master.key" => "x\n") do |dir|
          git(dir, "add", "config/master.key")

          expect(gitignore_check_for(dir).fix).to eq("Run `git rm --cached config/master.key`, add `config/master.key` to .gitignore, " \
                                                     "and rotate it: the history still holds it")
        end
      end

      it "says a literal secret in a config git tracks is committed" do
        repo_with(".gitignore" => "/config/database.yml\n", "config/database.yml" => "development:\n  password: hunter2\n") do |dir|
          git(dir, "add", "-f", "config/database.yml")
          check = gitignore_check_for(dir)

          expect(check).to have_attributes(status: :warn, message: "A literal secret in config/database.yml (`password` on line 2), which is committed")
          expect(check.fix).to end_with("or gitignore the file and run `git rm --cached config/database.yml`")
        end
      end
    end
  end

  # Stale means the run the fix names would rewrite the file: a file that
  # run leaves alone is never stale however old it is, so the fix always
  # clears the warning, and the files are read where config.output_dir puts them.
  describe "#check_context_freshness" do
    subject(:check) { doctor.send(:check_context_freshness) }

    # The context goes to a directory of its own, as config.output_dir names
    # one, so nothing is written into the app's tree.
    around do |example|
      Dir.mktmpdir do |dir|
        previous = RailsAiContext.configuration.output_dir
        @out = File.realpath(dir)
        RailsAiContext.configuration.output_dir = @out
        example.run
      ensure
        RailsAiContext.configuration.output_dir = previous
      end
    end

    before { allow(RailsAiContext.configuration).to receive(:ai_tools).and_return(%i[claude]) }

    def generate
      RailsAiContext.generate_context(Rails.application)
    end

    def contents
      Dir.glob(File.join(@out, "**/*"), File::FNM_DOTMATCH).select { |path| File.file?(path) }.sort.to_h { |path| [ path, File.binread(path) ] }
    end

    # An MCP-only install asked for no context files, so "No context files
    # generated" is the configuration working, not something to fix.
    it "is skipped rather than warned under an MCP-only install" do
      allow(RailsAiContext.configuration).to receive(:context_files).and_return(false)

      expect(check).to be_nil
    end

    it "warns when the output directory holds none" do
      expect(check.status).to eq(:warn)
      expect(check.message).to eq("No context files generated")
    end

    # A file the run leaves alone keeps its old mtime, and every app file is newer.
    it "passes files a run would leave alone, however old they are" do
      generate
      Dir.glob(File.join(@out, "**/*"), File::FNM_DOTMATCH).each { |path| File.utime(Time.at(0), Time.at(0), path) if File.file?(path) }

      expect(check.status).to eq(:pass)
      expect(check.message).to match(%r{\A#{Regexp.escape(@out)}/CLAUDE\.md and \d+ more context files are up to date\z})
    end

    it "warns about a file an older version wrote, and passes once the fix has run" do
      generate
      claude = File.join(@out, "CLAUDE.md")
      File.write(claude, File.read(claude).sub("rails-ai-context v#{RailsAiContext::VERSION}", "rails-ai-context v5.31.0"))

      expect(check.status).to eq(:warn)
      expect(check.message).to eq("#{claude} is out of date: written by rails-ai-context v5.31.0, this is v#{RailsAiContext::VERSION}")
      expect(check.fix).to eq("Run `#{RailsAiContext::InstallMode.command(:context)}` to regenerate")

      generate
      expect(doctor.send(:check_context_freshness).status).to eq(:pass)
    end

    it "names the directories with newer files when no version explains the change" do
      generate
      claude = File.join(@out, "CLAUDE.md")
      File.write(claude, File.read(claude).sub("## Stack", "## Stack (edited)"))
      File.utime(Time.at(0), Time.at(0), claude)

      expect(check.status).to eq(:warn)
      expect(check.message).to start_with("#{claude} is out of date: ").and include("app/models")
    end

    it "writes nothing where the context lives" do
      generate
      claude = File.join(@out, "CLAUDE.md")
      File.write(claude, File.read(claude).sub("## Stack", "## Stack (edited)"))
      before = contents

      check

      expect(contents).to eq(before)
    end

    it "reads a tool's rules directory when it has no root file" do
      allow(RailsAiContext.configuration).to receive(:ai_tools).and_return(%i[cursor])
      generate
      File.delete(File.join(@out, ".cursorrules"))

      expect(check.status).to eq(:warn)
      expect(check.message).to include("#{@out}/.cursorrules is out of date")
    end
  end

  describe "source file checks" do
    def check_named(dir, name)
      described_class.new(RailsAiContext::StaticApp.new(dir)).run[:checks].find { |c| c.name == name }
    end

    it "counts a pack's models and controllers" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "packs", "billing", "app", "models"))
        FileUtils.mkdir_p(File.join(dir, "packs", "billing", "app", "controllers"))
        File.write(File.join(dir, "packs", "billing", "app", "models", "invoice.rb"), "class Invoice; end\n")
        File.write(File.join(dir, "packs", "billing", "app", "controllers", "invoices_controller.rb"),
                   "class InvoicesController; end\n")

        expect(check_named(dir, "Models")).to have_attributes(status: :pass, message: "1 model file found")
        expect(check_named(dir, "Controllers")).to have_attributes(status: :pass, message: "1 controller file found")
      end
    end

    it "warns without naming one directory when no model file exists anywhere" do
      Dir.mktmpdir do |dir|
        expect(check_named(dir, "Models")).to have_attributes(status: :warn, message: "No model files")
      end
    end
  end

  describe "view counts" do
    def check_named(dir, name)
      described_class.new(RailsAiContext::StaticApp.new(dir)).run[:checks].find { |c| c.name == name }
    end

    # Two lines of one report counted different populations under the same
    # noun, so a reader saw two view counts and could not tell which was which.
    it "says what each of the two view lines counted" do
      Dir.mktmpdir do |dir|
        views = File.join(dir, "app", "views", "posts")
        FileUtils.mkdir_p(views)
        File.write(File.join(views, "index.html.erb"), "<h1>Posts</h1>\n")
        File.write(File.join(views, "show.html.erb"), "<h1>Post</h1>\n")
        File.write(File.join(views, "index.json.jbuilder"), "json.posts []\n")

        expect(check_named(dir, "Views").message).to eq("3 files under app/views")
        expect(check_named(dir, "View aggregation size").message)
          .to start_with("2 erb/haml/slim templates")
      end
    end

    # Raising a setting no check reads would leave the warning in place.
    it "names only the setting the warning is measured against" do
      Dir.mktmpdir do |dir|
        views = File.join(dir, "app", "views", "posts")
        FileUtils.mkdir_p(views)
        File.write(File.join(views, "index.html.erb"), "<h1>Posts</h1>\n")

        original = RailsAiContext.configuration.max_view_total_size
        RailsAiContext.configuration.max_view_total_size = 10
        begin
          check = check_named(dir, "View aggregation size")
          expect(check.status).to eq(:warn)
          expect(check.fix).to eq("Increase `config.max_view_total_size`")
        ensure
          RailsAiContext.configuration.max_view_total_size = original
        end
      end
    end
  end

  # The binary warns at boot of a dependency the app's bundle pins outside
  # what the gem needs, and the row that names that dependency says the same.
  describe "a dependency the app pins outside what the gem needs" do
    def loaded_with(name, version)
      spec = Gem::Specification.new do |s|
        s.name = name
        s.version = version
      end
      allow(Gem).to receive(:loaded_specs).and_return(Gem.loaded_specs.merge(name => spec))
    end

    def needed(name)
      Gem.loaded_specs["rails-ai-context"].runtime_dependencies.find { |dep| dep.name == name }.requirement
    end

    it "passes Prism, naming its version, when the loaded one is supported" do
      expect(doctor.send(:check_prism)).to have_attributes(status: :pass, message: "Prism #{Prism::VERSION} available for AST-based validation")
    end

    it "warns on the Prism row about a prism below the floor" do
      loaded_with("prism", "1.3.0")

      check = doctor.send(:check_prism)
      expect(check.status).to eq(:warn)
      expect(check.message).to eq("the app locks prism 1.3.0; this gem needs prism #{needed("prism")}, so the tools that use it may fail")
      expect(check.fix).to eq("Run `bundle update prism` in the app, after relaxing any pin its Gemfile puts on prism")
    end

    it "warns on the MCP server row about an mcp below the floor" do
      loaded_with("mcp", "0.12.0")

      check = doctor.send(:check_mcp_buildable)
      expect(check.status).to eq(:warn)
      expect(check.message).to start_with("MCP server builds, but the app locks mcp 0.12.0; this gem needs mcp #{needed("mcp")}")
    end
  end

  describe "#check_tests" do
    def tests_check(root)
      described_class.new(RailsAiContext::StaticApp.new(root)).send(:check_tests)
    end

    def write(root, rel, body = "")
      path = File.join(root, rel)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, body)
    end

    it "agrees with test_info about a spec directory that holds no specs" do
      Dir.mktmpdir do |root|
        write(root, "spec/javascripts/admin_spec.js")
        write(root, "test/unit/user_test.rb")

        check = tests_check(root)
        expect(check.status).to eq(:pass)
        expect(check.message).to eq("minitest test suite found")
      end
    end

    it "warns when no suite is there to find" do
      Dir.mktmpdir do |root|
        expect(tests_check(root).status).to eq(:warn)
      end
    end

    it "names both suites when the app runs both" do
      Dir.mktmpdir do |root|
        write(root, "spec/models/user_spec.rb")
        write(root, "test/unit/user_test.rb")

        expect(tests_check(root).message).to eq("rspec, minitest test suite found")
      end
    end
  end

  describe "model count" do
    it "is what SourceScan.paths resolves for the fixture, concerns included" do
      root = IntrospectedFixture::ROOT
      expected = RailsAiContext::Introspectors::SourceScan.paths(root, kind: "app/models", skip_concerns: false).count
      check = described_class.new(RailsAiContext::StaticApp.new(root)).run[:checks].find { |c| c.name == "Models" }
      expect(check.message).to eq("#{expected} model files found")
    end
  end

  describe "#check_migrations" do
    it "counts the migrations in the migrations_paths database.yml names" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(%w[config db/main_migrate].map { |path| File.join(dir, path) })
        File.write(File.join(dir, "config/database.yml"), "#{Rails.env}:\n  adapter: sqlite3\n  migrations_paths: db/main_migrate\n")
        File.write(File.join(dir, "db/main_migrate/20240101000000_create_notes.rb"), "class CreateNotes < ActiveRecord::Migration[7.1]; end\n")
        check = described_class.new(RailsAiContext::StaticApp.new(dir)).send(:check_migrations)
        expect([ check.status, check.message ]).to eq([ :pass, "1 migration file" ])
      end
    end

    it "counts every database's migrations, and says which hold them" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(%w[config db/migrate db/analytics_migrate].map { |path| File.join(dir, path) })
        File.write(File.join(dir, "config/database.yml"),
                   "#{Rails.env}:\n  primary:\n    adapter: sqlite3\n  analytics:\n    adapter: sqlite3\n    migrations_paths: db/analytics_migrate\n")
        File.write(File.join(dir, "db/migrate/20240101000000_create_notes.rb"), "class CreateNotes < ActiveRecord::Migration[7.1]; end\n")
        File.write(File.join(dir, "db/analytics_migrate/20240101000001_create_events.rb"), "class CreateEvents < ActiveRecord::Migration[7.1]; end\n")
        check = described_class.new(RailsAiContext::StaticApp.new(dir)).send(:check_migrations)
        expect(check.message).to eq("2 migration files (1 in primary, 1 in analytics)")
      end
    end
  end

  # The rows read what the tools read: an engine's test/dummy runs in its
  # engine, and an app with no lockfile has the bundle its config/boot.rb names.
  describe "an app whose bundle and code live above it" do
    around do |example|
      Dir.mktmpdir do |dir|
        @top = File.realpath(dir)
        example.run
      end
    end

    def write(path, content = "")
      FileUtils.mkdir_p(File.dirname(File.join(@top, path)))
      File.write(File.join(@top, path), content)
    end

    def check_named(root, name)
      described_class.new(RailsAiContext::StaticApp.new(File.join(@top, root))).send(:"check_#{name}")
    end

    it "finds a monorepo's shared lockfile through config/boot.rb" do
      FileUtils.mkdir_p(File.join(@top, ".git"))
      write("Gemfile", %(gem "rails"\n))
      write("Gemfile.lock", lockfile("rails"))
      write("web/config/boot.rb", %(ENV["BUNDLE_GEMFILE"] ||= File.expand_path("../../Gemfile", __dir__)\n))

      expect(check_named("web", "gems")).to have_attributes(status: :pass, message: "../Gemfile.lock found", fix: nil)
    end

    # Booted through another bundle (BUNDLE_GEMFILE), nothing writes it, and
    # the row named no file: " not found".
    it "names a shared lockfile that is not there yet" do
      FileUtils.mkdir_p(File.join(@top, ".git"))
      write("Gemfile", %(gem "rails"\n))
      write("web/config/boot.rb", %(ENV["BUNDLE_GEMFILE"] ||= File.expand_path("../../Gemfile", __dir__)\n))

      expect(check_named("web", "gems")).to have_attributes(status: :warn, message: "../Gemfile.lock not found")
    end

    it "names that lockfile where a config's bundle exec reads a bundle without the gem" do
      FileUtils.mkdir_p(File.join(@top, ".git"))
      write("Gemfile", %(gem "rails"\n))
      write("web/config/boot.rb", %(ENV["BUNDLE_GEMFILE"] ||= File.expand_path("../../Gemfile", __dir__)\n))
      write("web/.mcp.json", JSON.generate("mcpServers" => { "rails-ai-context" => { "command" => "bundle", "args" => %w[exec rails-ai-context serve] } }))
      allow(RailsAiContext.configuration).to receive(:tool_mode).and_return(:mcp)
      allow(RailsAiContext.configuration).to receive(:ai_tools).and_return(%i[claude])
      doctor = described_class.new(RailsAiContext::StaticApp.new(File.join(@top, "web")))
      bin = bin_dir_with("bundle")
      allow(doctor).to receive(:client_path).and_return(bin)

      expect(doctor.send(:check_mcp_json).message).to end_with("`bundle exec rails-ai-context serve` cannot start - ../Gemfile.lock has no rails-ai-context")
    ensure
      FileUtils.rm_rf(bin) if bin
    end

    # Outside a git repository the tools leave that bundle unread, and
    # `bundle install` would not change it.
    it "says why a shared lockfile is not read, without sending the reader to bundle install" do
      write("Gemfile.lock", lockfile("rails"))
      write("web/config/boot.rb", %(ENV["BUNDLE_GEMFILE"] ||= File.expand_path("../../Gemfile", __dir__)\n))

      check = check_named("web", "gems")
      expect(check.status).to eq(:warn)
      expect(check.message).to include("config/boot.rb points Bundler at `../Gemfile`")
      expect(check.fix).to be_nil
    end

    context "in an engine's test/dummy" do
      let(:engine) { @top }
      let(:dummy) { File.join(@top, "test/dummy") }

      before do
        FileUtils.mkdir_p(File.join(@top, ".git"))
        write("Gemfile", %(gemspec\n))
        write("Gemfile.lock", lockfile("rails"))
        write("blorgh.gemspec")
        write("app/models/blorgh/article.rb", "module Blorgh; class Article < ApplicationRecord; end; end\n")
        write("app/controllers/blorgh/articles_controller.rb", "module Blorgh; class ArticlesController < ApplicationController; end; end\n")
        write("db/migrate/20240101000000_create_blorgh_articles.rb", "class CreateBlorghArticles < ActiveRecord::Migration[7.1]; end\n")
        write("test/test_helper.rb")
        write("test/models/article_test.rb")
        write("test/dummy/config/boot.rb", %(ENV["BUNDLE_GEMFILE"] ||= File.expand_path("../../../Gemfile", __dir__)\n))
        write("test/dummy/app/models/application_record.rb", "class ApplicationRecord < ActiveRecord::Base; end\n")
        allow(RailsAiContext::PathResolver).to receive(:enclosing_engine_roots).and_call_original
        allow(RailsAiContext::PathResolver).to receive(:enclosing_engine_roots).with(dummy).and_return([ engine ])
      end

      it "reads the engine's lockfile, suite, models and migrations, as the tools do" do
        expect(check_named("test/dummy", "gems").message).to eq("../../Gemfile.lock found")
        expect(check_named("test/dummy", "tests").message).to eq("minitest test suite found (the engine's, at ../..)")
        expect(check_named("test/dummy", "models").message).to eq("2 model files found (1 in the engine at ../..)")
        expect(check_named("test/dummy", "controllers").message).to eq("1 controller file found (1 in the engine at ../..)")
        expect(check_named("test/dummy", "migrations").message).to eq("1 migration file (1 in the engine at ../..)")
      end

      # From the dummy, Rails lists the engine's migrations as NO FILE; the
      # engine's own db:migrate is the one that runs them.
      it "names the engine's root as where a pending migration is run" do
        doctor = described_class.new(RailsAiContext::StaticApp.new(dummy))
        allow(doctor).to receive(:database_states).and_return([ { name: "primary", config: nil, pending: [ { version: "1", name: "X" } ] } ])

        expect(doctor.send(:check_pending_migrations).fix).to eq("Run `RAILS_ENV=#{Rails.env} bin/rails db:migrate` in the engine at ../..")
      end

      # Typed at the engine's root, where `bin/rails app:ai:doctor` and the
      # binary run, ../.. sent the reader two folders up, and app/views named
      # the engine's own views: every place is named from where it was typed.
      context "typed at the engine's root" do
        let(:doctor) { described_class.new(RailsAiContext::StaticApp.new(dummy), from: engine) }

        before do
          write("app/views/blorgh/articles/index.html.erb", "")
          write("test/dummy/app/views/layouts/application.html.erb", "")
          write("test/dummy/db/schema.rb", "ActiveRecord::Schema[7.1].define(version: 1) do\nend\n")
          write("test/dummy/config/routes.rb", "Rails.application.routes.draw do\nend\n")
        end

        it "names the engine's files from there, and the dummy app's under test/dummy" do
          expect(doctor.send(:check_gems).message).to eq("Gemfile.lock found")
          expect(doctor.send(:check_tests).message).to eq("minitest test suite found (the engine's)")
          expect(doctor.send(:check_models).message).to eq("2 model files found (1 in the engine)")
          expect(doctor.send(:check_migrations).message).to eq("1 migration file (1 in the engine)")
          expect(doctor.send(:check_views).message).to eq("2 files under test/dummy/app/views, app/views")
          expect(doctor.send(:check_schema).message).to start_with("test/dummy/db/schema.rb found")
          expect(doctor.send(:check_routes).message).to eq("test/dummy/config/routes.rb found")
        end

        it "names the engine's root as where a pending migration is run" do
          allow(doctor).to receive(:database_states).and_return([ { name: "primary", config: nil, pending: [ { version: "1", name: "X" } ] } ])

          expect(doctor.send(:check_pending_migrations).fix).to eq("Run `RAILS_ENV=#{Rails.env} bin/rails db:migrate` at the engine's root")
        end

        it "names a SQLite database the dummy app reads from its root under test/dummy" do
          config = ActiveRecord::DatabaseConfigurations::HashConfig.new(Rails.env, "primary", { adapter: "sqlite3", database: "storage/development.sqlite3" })
          allow(doctor).to receive(:database_states).and_return([ { name: "primary", config: config, error: ActiveRecord::NoDatabaseError.new("no") } ])

          expect(doctor.send(:check_pending_migrations)).to have_attributes(
            message: "the #{Rails.env} database test/dummy/storage/development.sqlite3 does not exist",
            fix: "Run `RAILS_ENV=#{Rails.env} bin/rails app:db:prepare` at the engine's root"
          )
        end

        # `git rm --cached` runs where it is typed.
        it "names a secret file of the dummy app's as the git command there reads it" do
          write("test/dummy/config/master.key", "x\n")
          system("git", "-C", @top, "init", "-q", out: File::NULL, err: File::NULL) or raise "git init failed"
          system("git", "-C", @top, "add", "-f", "test/dummy/config/master.key", out: File::NULL, err: File::NULL) or raise "git add failed"

          expect(doctor.send(:check_security_gitignore)).to have_attributes(
            message: "test/dummy/config/master.key is committed",
            fix: "Run `git rm --cached test/dummy/config/master.key`, add `test/dummy/config/master.key` to .gitignore, " \
                 "and rotate it: the history still holds it"
          )
        end
      end

      # The installer run at an engine's root puts every file there, where its
      # rake tasks are app:ai:* and `rails ai:context` is no command; doctor
      # read the dummy app, sent the reader to commands that fail there, and
      # following them wrote a second install into the dummy app.
      context "with the install at the engine's root" do
        # Typed there, as `bin/rails app:ai:doctor` and the binary are.
        let(:doctor) { described_class.new(RailsAiContext::StaticApp.new(dummy), from: engine) }

        before do
          write("Gemfile.lock", lockfile("rails", "rails-ai-context"))
          write(".rails-ai-context.yml", "ai_tools:\n- claude\ntool_mode: mcp\ncontext_files: true\n")
        end

        it "reads the selection and the MCP configs there, and names the install that runs there" do
          check = doctor.send(:check_mcp_json)

          expect(check).to have_attributes(status: :warn, message: "1 of 1 MCP config needs attention: .mcp.json (Claude Code)",
                                           fix: "Run `rails generate rails_ai_context:install` at the engine's root to fix")
        end

        it "passes the config there that serves the engine" do
          write(".mcp.json", JSON.generate("mcpServers" => { "rails-ai-context" => { "command" => "bundle", "args" => %w[exec rails-ai-context serve] } }))
          allow(doctor).to receive(:client_path).and_return(bin_dir_with("bundle"))

          expect(doctor.send(:check_mcp_json)).to have_attributes(status: :pass, message: "1 of 1 MCP config valid")
        end

        it "looks for the context files there, and names the command that writes them there" do
          expect(doctor.send(:check_context_freshness)).to have_attributes(
            status: :warn, message: "No context files generated at the engine's root",
            fix: "Run `bundle exec rails-ai-context context` at the engine's root"
          )
        end

        # The context there is the binary's, reading the engine's source with
        # no app booted, so that command itself runs, into a copy.
        describe "the context run there" do
          def context_command(script)
            path = File.join(@top, "context_command.rb")
            File.write(path, script)
            allow(RailsAiContext::InstallMode).to receive(:command).and_call_original
            allow(RailsAiContext::InstallMode).to receive(:command).with(:context, form: :bundled).and_return("#{RbConfig.ruby} #{path}")
          end

          before { write("CLAUDE.md", "# blorgh\n") }

          it "passes the files it would leave as they are, and changes none of them" do
            context_command(%(dir = ARGV[ARGV.index("--output-dir") + 1]\nFile.write(File.join(dir, "CLAUDE.md"), "# blorgh\\n")\n))

            expect(doctor.send(:check_context_freshness)).to have_attributes(status: :pass, message: "CLAUDE.md is up to date")
          end

          it "names a file it would rewrite, and leaves it as it is" do
            context_command(%(dir = ARGV[ARGV.index("--output-dir") + 1]\nFile.write(File.join(dir, "CLAUDE.md"), "# blorgh, changed\\n")\n))

            check = doctor.send(:check_context_freshness)
            expect(check.message).to start_with("CLAUDE.md is out of date")
            expect(File.read(File.join(@top, "CLAUDE.md"))).to eq("# blorgh\n")
          end

          it "names the files and the command from the dummy app when typed there" do
            context_command(%(dir = ARGV[ARGV.index("--output-dir") + 1]\nFile.write(File.join(dir, "CLAUDE.md"), "# blorgh, changed\\n")\n))
            in_dummy = described_class.new(RailsAiContext::StaticApp.new(dummy), from: dummy)

            check = in_dummy.send(:check_context_freshness)
            expect(check.message).to start_with("../../CLAUDE.md is out of date")
            expect(check.fix).to end_with("in the engine at ../.. to regenerate")
          end

          it "says what stopped a run that failed, without claiming the files are up to date" do
            context_command(%($stderr.puts "Error: something broke"\nexit 1\n))

            check = doctor.send(:check_context_freshness)
            expect(check.status).to eq(:warn)
            expect(check.message).to end_with("so whether it is up to date is not known (Error: something broke)")
          end
        end

        it "keeps a dummy app's own install when the engine's root has none" do
          File.delete(File.join(@top, ".rails-ai-context.yml"))
          write("test/dummy/.rails-ai-context.yml", "ai_tools:\n- claude\n")

          expect(doctor.send(:check_mcp_json).fix).to eq("Run `#{RailsAiContext::InstallMode.command(:install)}` to fix")
        end
      end
    end
  end

  # Every database the app migrates is asked through its own connection, as
  # `db:migrate:status` asks it; one that cannot be asked is named.
  describe "#check_pending_migrations" do
    around do |example|
      Dir.mktmpdir do |dir|
        @root = File.realpath(dir)
        example.run
      end
    end

    let(:app_doctor) { described_class.new(RailsAiContext::StaticApp.new(@root)) }

    def write(path, content)
      FileUtils.mkdir_p(File.dirname(File.join(@root, path)))
      File.write(File.join(@root, path), content)
    end

    def database_named(name, database)
      ActiveRecord::DatabaseConfigurations::HashConfig.new(Rails.env, name, { adapter: "sqlite3", database: database })
    end

    def with_analytics_database
      write("config/database.yml", "#{Rails.env}:\n  primary:\n    adapter: sqlite3\n  analytics:\n    adapter: sqlite3\n    " \
                                   "database: db/analytics.sqlite3\n    migrations_paths: db/analytics_migrate\n")
      write("db/analytics_migrate/20240101000000_create_events.rb", "class CreateEvents < ActiveRecord::Migration[7.1]\nend\n")
      analytics = database_named("analytics", File.join(@root, "db/analytics.sqlite3"))
      allow(ActiveRecord::Base.configurations).to receive(:configs_for).and_call_original
      allow(ActiveRecord::Base.configurations).to receive(:configs_for).with(env_name: Rails.env)
        .and_return([ ActiveRecord::Base.connection_db_config, analytics ])
    end

    it "reads a pending migration in a secondary database, and writes nothing to it" do
      with_analytics_database
      # Created, never migrated: an empty SQLite file.
      write("db/analytics.sqlite3", "")

      check = app_doctor.send(:check_pending_migrations)

      expect(check.status).to eq(:fail)
      expect(check.message).to eq("1 pending migration in analytics - schema data will be stale")
      database = SQLite3::Database.new(File.join(@root, "db/analytics.sqlite3"), readonly: true)
      expect(database.execute("SELECT name FROM sqlite_master WHERE type = 'table'")).to eq([])
    ensure
      database&.close
    end

    # Connecting would create the file, and the next run would read an empty
    # database with every migration pending.
    it "says a SQLite database whose file is not there does not exist, and leaves it uncreated" do
      with_analytics_database

      check = app_doctor.send(:check_pending_migrations)

      expect(check).to have_attributes(name: "Database", status: :fail,
                                       message: "the #{Rails.env} database analytics (#{File.join(@root, "db/analytics.sqlite3")}) does not exist",
                                       fix: "Run `RAILS_ENV=#{Rails.env} bin/rails db:prepare`")
      expect(File.exist?(File.join(@root, "db/analytics.sqlite3"))).to be(false)
    end

    def unreachable(error)
      allow(app_doctor).to receive(:database_states).and_return([
        { name: "primary", config: database_named("primary", "shop_development"), error: error }
      ])
      app_doctor.send(:check_pending_migrations)
    end

    # The pending row used to vanish with no database, so --strict passed.
    it "fails, naming a database that does not exist and the command that makes it" do
      check = unreachable(ActiveRecord::NoDatabaseError.new("Database not found: shop_development"))

      expect(check).to have_attributes(name: "Database", status: :fail, message: "the #{Rails.env} database shop_development does not exist",
                                       fix: "Run `RAILS_ENV=#{Rails.env} bin/rails db:prepare`")
    end

    it "fails, naming a database server that does not answer" do
      check = unreachable(ActiveRecord::ConnectionNotEstablished.new(
        %(connection to server at "127.0.0.1", port 5432 failed: Connection refused\n\tIs the server running on that host?)
      ))

      expect(check.message).to eq(%(the #{Rails.env} database shop_development cannot be reached: connection to server at "127.0.0.1", ) +
                                  "port 5432 failed: Connection refused")
      expect(check.fix).to eq("Start the database server, or fix its settings in config/database.yml")
    end
  end
end
