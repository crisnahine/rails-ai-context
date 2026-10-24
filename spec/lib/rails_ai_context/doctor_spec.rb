# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Doctor do
  let(:doctor) { described_class.new(Rails.application) }

  def plugin_settings(enabled = true) = JSON.generate("enabledPlugins" => { "rails-ai-context@rails-ai-context" => enabled })

  # Claude Code's install registry, listing the plugin as installed on this machine.
  let(:plugin_registry) { File.join(ENV.fetch("CLAUDE_CONFIG_DIR"), "plugins", "installed_plugins.json") }

  before do
    FileUtils.mkdir_p(File.dirname(plugin_registry))
    File.write(plugin_registry, JSON.generate("version" => 2, "plugins" => { "rails-ai-context@rails-ai-context" => [ { "scope" => "user" } ] }))
  end

  after { FileUtils.rm_rf(File.dirname(plugin_registry)) }

  describe "#run" do
    subject(:result) { doctor.run }

    it "returns checks and a score" do
      expect(result).to have_key(:checks)
      expect(result).to have_key(:score)
    end

    it "returns an array of checks" do
      expect(result[:checks]).to all(be_a(RailsAiContext::Doctor::Check))
    end

    # The health check and the context files' dry run read one introspection.
    it "runs each introspector once when context files are there to check" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app/models"))
        File.write(File.join(dir, "app/models/post.rb"), "class Post < ApplicationRecord\nend\n")
        File.write(File.join(dir, "CLAUDE.md"), "# context\n")
        runs = Hash.new(0)
        allow_any_instance_of(RailsAiContext::Introspector).to receive(:resolve_introspector).and_wrap_original do |original, name|
          runs[name] += 1
          original.call(name)
        end

        checks = described_class.new(RailsAiContext::StaticApp.new(dir)).run[:checks].map(&:name)

        expect(checks).to include("Introspector health", "Context files")
        expect(runs.values.uniq).to eq([ 1 ])
        expect(runs.size).to eq(RailsAiContext.configuration.introspectors.size)
      end
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

      # An app can lock brakeman; a static run never loads the app's bundle.
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

    # Typed with --app-path from the folder above, a bare command ran there:
    # `init` set up every app in the folder, and `bin/rails` was no file.
    context "typed in the folder above the app" do
      let(:above) { File.dirname(Rails.application.root.to_s) }
      let(:app_dir) { File.basename(Rails.application.root.to_s) }

      def fixes_from_above(standalone:)
        allow(RailsAiContext::InstallMode).to receive(:standalone?).and_return(standalone)
        described_class.new(Rails.application, from: above).run[:checks].filter_map(&:fix)
      end

      it "gives the binary the app with --app-path" do
        expect(fixes_from_above(standalone: true)).to include("Run `rails-ai-context --app-path #{app_dir} context`",
                                                              "Run `rails-ai-context --app-path #{app_dir} init` to fix")
      end

      it "runs the app's other commands in the app" do
        expect(fixes_from_above(standalone: false)).to include("Run `cd #{app_dir} && rails ai:context`",
                                                               "Run `cd #{app_dir} && rails generate rails_ai_context:install` to fix")
      end

      it "runs a database task in the app" do
        doctor = described_class.new(Rails.application, from: above)
        allow(doctor).to receive(:database_states).and_return([ { name: "primary", config: nil, pending: [ { version: "1", name: "X" } ] } ])

        expect(doctor.send(:check_pending_migrations).fix).to eq("Run `cd #{app_dir} && RAILS_ENV=#{Rails.env} bin/rails db:migrate`")
      end
    end

    # Typed in app/models, the fixes were the ones for the app's root:
    # `bin/rails` is no file there, and git reads a path from there.
    context "typed in a folder inside the app" do
      let(:inside) { File.join(Rails.application.root.to_s, "app/models") }

      def fixes_from_inside(standalone:)
        allow(RailsAiContext::InstallMode).to receive(:standalone?).and_return(standalone)
        described_class.new(Rails.application, from: inside).run[:checks].filter_map(&:fix)
      end

      it "gives the binary the app with --app-path" do
        expect(fixes_from_inside(standalone: true)).to include("Run `rails-ai-context --app-path ../.. context`",
                                                               "Run `rails-ai-context --app-path ../.. init` to fix")
      end

      it "runs the app's other commands at its root" do
        expect(fixes_from_inside(standalone: false)).to include("Run `cd ../.. && rails ai:context`",
                                                                "Run `cd ../.. && rails generate rails_ai_context:install` to fix")
      end

      it "runs a database task at the app's root, and names the files it reports from there" do
        doctor = described_class.new(Rails.application, from: inside)
        config = ActiveRecord::DatabaseConfigurations::HashConfig.new(Rails.env, "primary", { adapter: "sqlite3", database: "storage/x.sqlite3" })
        allow(doctor).to receive(:database_states).and_return([ { name: "primary", config: config, error: RailsAiContext::AppDatabases::Missing.new("no") } ])

        expect(doctor.send(:check_pending_migrations)).to have_attributes(
          message: "the #{Rails.env} database storage/x.sqlite3 does not exist",
          fix: "Run `cd ../.. && RAILS_ENV=#{Rails.env} bin/rails db:prepare`"
        )
        expect(doctor.send(:check_routes).message).to eq("config/routes.rb found")
      end
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
      expect(lines[index + 1]).to include("Fix: database_stats: Database not found: no_such_db")
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
      expect(check.fix).to include("database_stats: Database not found: no_such_db")
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

    # A PATH or GEM_PATH as the platform joins one: `;` on Windows, where
    # `:` is in every absolute path.
    def path_list(*dirs) = dirs.join(File::PATH_SEPARATOR)

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
          write_snapshot(path_list("/nonexistent/ruby/9.9.9/bin", bin))

          expect(check.status).to eq(:pass)
          expect(check.message).to eq("Codex env snapshot in .codex/config.toml is current: its PATH reaches `rails-ai-context`")
        end

        it "fails when it no longer does, naming the directory that is gone" do
          write_snapshot(path_list("/nonexistent/ruby/9.9.9/bin", bin_dir_with))

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

        # The GEM_PATH init would save now: this shell's, before Bundler.
        def shell_gem_path(value)
          allow(Bundler).to receive(:original_env).and_return(Bundler.original_env.merge("GEM_PATH" => value).compact)
        end

        it "warns when a directory on it no longer exists" do
          shell_gem_path(gems)
          write_gem_path(path_list("/nonexistent/ruby/3.3.5/gems", gems))

          expect(check).to have_attributes(status: :warn,
                                           message: "Codex MCP env snapshot is stale - GEM_PATH names /nonexistent/ruby/3.3.5/gems, which no longer exists")
        end

        # RubyGems passes over a GEM_PATH directory that is not there, and init
        # saves this shell's GEM_PATH again: a warning on it was one the fix
        # could never clear.
        it "passes over a missing directory this shell's GEM_PATH names too" do
          shell_gem_path(path_list("/nonexistent/.gem/ruby/3.3.0", gems))
          write_gem_path(path_list("/nonexistent/.gem/ruby/3.3.0", gems))

          expect(check).to have_attributes(status: :pass,
                                           message: "Codex env snapshot in .codex/config.toml is current: its PATH reaches `rails-ai-context`")
        end

        it "still warns about a missing directory this shell no longer names" do
          shell_gem_path(nil)
          write_gem_path(path_list("/nonexistent/.gem/ruby/3.3.0", gems))

          expect(check).to have_attributes(status: :warn,
                                           message: "Codex MCP env snapshot is stale - GEM_PATH names /nonexistent/.gem/ruby/3.3.0, which no longer exists")
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
  # Windows runs a file by its extension, and PATH finds a bare name as one.
  def bin_dir_with(*names)
    dir = Dir.mktmpdir("bin")
    names.each do |name|
      file = File.join(dir, Gem.win_platform? ? "#{name}.exe" : name)
      File.write(file, "#!/bin/sh\n")
      File.chmod(0o755, file)
    end
    dir
  end

  # Bundler's copy of the environment is a plain Hash, and Windows keeps its
  # variable names in any case: PATH there is `Path`.
  describe "#client_path" do
    let(:doctor) { described_class.new(RailsAiContext::StaticApp.new(Dir.pwd)) }

    it "reads PATH from the environment as it was before Bundler, by Windows' name for it there" do
      allow(Bundler).to receive(:original_env).and_return("Path" => "C:/Ruby34/bin", "Gem_Path" => "/gems")
      allow(Gem).to receive(:win_platform?).and_return(true)

      expect(doctor.send(:client_path)).to eq("C:/Ruby34/bin")
      expect(doctor.send(:current_gem_path)).to eq([ "/gems" ])
    end

    it "takes a name only as it is spelled, where names are case-sensitive" do
      allow(Bundler).to receive(:original_env).and_return("Path" => "/elsewhere", "PATH" => "/usr/bin")
      allow(Gem).to receive(:win_platform?).and_return(false)

      expect(doctor.send(:client_path)).to eq("/usr/bin")
      allow(Bundler).to receive(:original_env).and_return("Path" => "/elsewhere")
      expect(doctor.send(:client_path)).to eq("")
    end
  end

  describe "#check_mcp_json" do
    # Real files in a real app folder: the check reads them the way the
    # generator does.
    around do |example|
      Dir.mktmpdir do |dir|
        # Another app beside this one, so no folder above it resolves to this app, as on a machine with several.
        FileUtils.mkdir_p(File.join(dir, "blog", "config"))
        File.write(File.join(dir, "blog", "config", "application.rb"), "")
        @root = File.join(File.realpath(dir), "shop")
        FileUtils.mkdir_p(@root)
        @bin = bin_dir_with("bundle", "rails-ai-context")
        example.run
      ensure
        FileUtils.rm_rf(@bin)
      end
    end

    # A doctor that finds commands in @bin, whatever this machine's PATH holds.
    def fresh_doctor
      described_class.new(RailsAiContext::StaticApp.new(@root)).tap { |doctor| allow(doctor).to receive(:client_path).and_return(@bin) }
    end

    let(:app_doctor) { fresh_doctor }

    subject(:check) { app_doctor.send(:check_mcp_json) }

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

    context "when the Claude Code plugin serves the app" do
      before do
        allow(RailsAiContext.configuration).to receive(:tool_mode).and_return(:mcp)
        write("config/application.rb", "")
      end

      it "passes Claude Code with no .mcp.json, and checks no other tool when none was chosen" do
        write(".claude/settings.json", plugin_settings)

        expect(check).to have_attributes(status: :pass, message: "1 of 1 MCP config valid: the rails-ai-context plugin (Claude Code)")
      end

      it "reads the plugin enabled in the user's own settings" do
        File.write(File.join(ENV.fetch("CLAUDE_CONFIG_DIR"), "settings.json"), plugin_settings)

        expect(check.status).to eq(:pass)
      ensure
        FileUtils.rm_f(File.join(ENV.fetch("CLAUDE_CONFIG_DIR"), "settings.json"))
      end

      it "lets the local settings turn off what the project settings turn on" do
        write(".claude/settings.json", plugin_settings)
        write(".claude/settings.local.json", plugin_settings(false))

        expect(check.status).to eq(:warn)
      end

      it "warns that .mcp.json starts a second server beside the plugin's" do
        allow(RailsAiContext.configuration).to receive(:ai_tools).and_return(%i[claude])
        write(".claude/settings.json", plugin_settings)
        write(".mcp.json", server(bundled))

        expect(check).to have_attributes(
          status: :warn,
          message: "1 of 1 MCP config needs attention: .mcp.json (Claude Code): `rails-ai-context` in .mcp.json runs the " \
                   "server beside the rails-ai-context plugin, so Claude Code lists every tool twice",
          fix: "Remove `rails-ai-context` from .mcp.json, or run `claude plugin disable rails-ai-context@rails-ai-context --scope local`"
        )
      end

      # An HTTP entry under the gem's name reaches the app's own endpoint, a second server all the same.
      it "warns about an HTTP entry beside the plugin, unless a serverUrl deny keeps it off" do
        allow(RailsAiContext.configuration).to receive(:ai_tools).and_return(%i[claude])
        write(".claude/settings.json", plugin_settings)
        write(".mcp.json", JSON.generate("mcpServers" => { "rails-ai-context" => { "type" => "http", "url" => "http://localhost:3000/mcp" } }))
        expect(check).to have_attributes(
          status: :warn,
          message: "1 of 1 MCP config needs attention: .mcp.json (Claude Code): `rails-ai-context` in .mcp.json runs the " \
                   "server beside the rails-ai-context plugin, so Claude Code lists every tool twice",
          fix: "Remove `rails-ai-context` from .mcp.json, or run `claude plugin disable rails-ai-context@rails-ai-context --scope local`"
        )

        write(".claude/settings.json", JSON.generate(JSON.parse(plugin_settings).merge("deniedMcpServers" => [ { "serverUrl" => "http://localhost:*/*" } ])))
        expect(fresh_doctor.send(:check_mcp_json))
          .to have_attributes(status: :pass, message: "1 of 1 MCP config valid: the rails-ai-context plugin (Claude Code)")
      end

      # With no plugin, the HTTP entry is the app's server, and the rule that keeps it off is the one to change.
      it "names the serverUrl rule that keeps an HTTP entry from starting" do
        allow(RailsAiContext.configuration).to receive(:ai_tools).and_return(%i[claude])
        user = File.join(ENV.fetch("CLAUDE_CONFIG_DIR"), "settings.json")
        write(".mcp.json", JSON.generate("mcpServers" => { "rails-ai-context" => { "type" => "http", "url" => "http://localhost:3000/mcp" } }))
        File.write(user, JSON.generate("deniedMcpServers" => [ { "serverUrl" => "http://localhost:3000/*" } ]))
        expect(check).to have_attributes(status: :warn, fix: 'Remove {"serverUrl":"http://localhost:3000/*"} from deniedMcpServers in your user settings')
        expect(check.message).to include("Claude Code's MCP policy keeps `rails-ai-context` from starting")

        File.write(user, JSON.generate("allowedMcpServers" => [ { "serverUrl" => "https://tools.example.com/*" } ]))
        expect(fresh_doctor.send(:check_mcp_json).fix)
          .to eq('Add {"serverUrl":"http://localhost:3000/mcp"} to allowedMcpServers in your user settings')
        File.write(user, JSON.generate("allowedMcpServers" => [ { "serverName" => "github" } ]))
        expect(fresh_doctor.send(:check_mcp_json).fix)
          .to eq('Add {"serverName":"rails-ai-context"} to allowedMcpServers in your user settings')
      ensure
        FileUtils.rm_f(user)
      end

      # A command named by its path is no PATH lookup, so no gem install puts it there.
      it "sends a missing command path to the entry, never to a gem install" do
        allow(RailsAiContext.configuration).to receive(:ai_tools).and_return(%i[claude])
        missing = "/nonexistent/ruby-3.3.0/bin/rails-ai-context"
        write(".mcp.json", JSON.generate("mcpServers" => { "myrails" => { "command" => missing, "args" => [ "serve" ] } }))
        expect(check.message).to include("`#{missing}` is not an executable file")
        expect(check.fix).to eq("Fix or remove `myrails` in .mcp.json by hand")

        write(".mcp.json", JSON.generate("mcpServers" => { "rails-ai-context" => { "command" => missing, "args" => [ "serve" ] } }))
        expect(fresh_doctor.send(:check_mcp_json).fix).to eq("Run `rails generate rails_ai_context:install` to fix")
      end

      # A file that parses holds no server of the gem's to remove, so the edit is all a committed plugin's .mcp.json needs.
      it "names the edit a committed .mcp.json that is no object needs" do
        write(".claude/settings.json", plugin_settings)
        write(".mcp.json", JSON.generate("mcpServers" => []))
        expect(check.fix).to eq('Make "mcpServers" in .mcp.json an object')

        write(".mcp.json", "[]")
        expect(fresh_doctor.send(:check_mcp_json).fix).to eq("Make .mcp.json a JSON object")
      end

      # A broken entry is a fault of its own, whatever else serves the app, and with the plugin serving it is one to remove.
      it "reports a broken entry before any second server" do
        write(".claude/settings.json", plugin_settings)
        write(".mcp.json", server(%w[rails-ai-context serve]))
        allow(app_doctor).to receive(:client_path).and_return(Dir.mktmpdir)

        expect(check.message).to include("cannot start")
        expect(check.message).not_to include("lists every tool twice")
        expect(check).to have_attributes(status: :warn, fix: "Remove `rails-ai-context` from .mcp.json; the rails-ai-context plugin serves this app")
      end

      it "passes a .mcp.json entry the settings reject, since Claude Code never starts it" do
        write(".claude/settings.json", JSON.generate(JSON.parse(plugin_settings).merge("disabledMcpjsonServers" => [ "rails-ai-context" ])))
        write(".mcp.json", server(bundled))

        expect(check.status).to eq(:pass)
      end

      it "passes a .mcp.json entry /mcp turned off, and fails over to the install where /mcp turned the plugin off" do
        write(".claude/settings.json", plugin_settings)
        write(".mcp.json", server(bundled))
        File.write(File.join(ENV.fetch("CLAUDE_CONFIG_DIR"), ".claude.json"),
                   JSON.generate("projects" => { @root => { "disabledMcpServers" => [ "rails-ai-context" ] } }))
        expect(check.status).to eq(:pass)

        File.write(File.join(ENV.fetch("CLAUDE_CONFIG_DIR"), ".claude.json"),
                   JSON.generate("projects" => { @root => { "disabledMcpServers" => [ "plugin:rails-ai-context:rails-ai-context" ] } }))
        expect(fresh_doctor.send(:mcp_config_verdict, :claude).status).to eq(:pass)
        expect(fresh_doctor.send(:claude_code).plugin?).to be(false)
      ensure
        FileUtils.rm_f(File.join(ENV.fetch("CLAUDE_CONFIG_DIR"), ".claude.json"))
      end

      # The install's own fix would add the second server the plugin replaces,
      # and a machine that never added the marketplace needs it named.
      it "asks a teammate with the committed setting to install the plugin, not to run the install" do
        allow(RailsAiContext.configuration).to receive(:ai_tools).and_return(nil)
        write(".claude/settings.json", plugin_settings)
        FileUtils.rm_rf(File.dirname(plugin_registry))

        expect(check).to have_attributes(
          status: :warn,
          message: "1 of 1 MCP config needs attention: the rails-ai-context plugin (Claude Code): enabled for this app but not installed on this machine",
          fix: "Run `claude plugin install rails-ai-context --marketplace crisnahine/rails-ai-context --scope local`"
        )
      end

      # A project install would rewrite the committed file; a user's own setting wants a user install.
      it "names the install scope that leaves the committed settings alone" do
        allow(RailsAiContext.configuration).to receive(:ai_tools).and_return(nil)
        File.write(File.join(ENV.fetch("CLAUDE_CONFIG_DIR"), "settings.json"), plugin_settings)
        FileUtils.rm_rf(File.dirname(plugin_registry))

        expect(check.fix).to eq("Run `claude plugin install rails-ai-context --marketplace crisnahine/rails-ai-context --scope user`")
      ensure
        FileUtils.rm_f(File.join(ENV.fetch("CLAUDE_CONFIG_DIR"), "settings.json"))
      end

      # init would add the second server the plugin is there to replace.
      it "asks to turn the plugin's server back on where /mcp turned it off, not to run the install" do
        allow(RailsAiContext.configuration).to receive(:ai_tools).and_return(nil)
        write(".claude/settings.json", plugin_settings)
        File.write(File.join(ENV.fetch("CLAUDE_CONFIG_DIR"), ".claude.json"),
                   JSON.generate("projects" => { @root => { "disabledMcpServers" => [ "plugin:rails-ai-context:rails-ai-context" ] } }))

        expect(check).to have_attributes(
          status: :warn,
          message: "1 of 1 MCP config needs attention: the rails-ai-context plugin (Claude Code): its server is turned off in /mcp",
          fix: "Turn the plugin's server back on with /mcp in a session started here"
        )
        expect(app_doctor.send(:check_context_freshness)).to be_nil
      ensure
        FileUtils.rm_f(File.join(ENV.fetch("CLAUDE_CONFIG_DIR"), ".claude.json"))
      end

      it "says Claude Code's MCP policy keeps the plugin's server from starting, and what would let it" do
        write(".claude/settings.json", plugin_settings)
        install = File.join(@root, "cache")
        File.write(plugin_registry, JSON.generate("version" => 2, "plugins" => {
          "rails-ai-context@rails-ai-context" => [ { "scope" => "user", "installPath" => install } ]
        }))
        write("cache/.mcp.json", File.read(File.expand_path("../../../plugins/rails-ai-context/.mcp.json", __dir__)))
        File.write(File.join(ENV.fetch("CLAUDE_CONFIG_DIR"), "settings.json"), JSON.generate("allowedMcpServers" => [ { "serverName" => "github" } ]))

        expect(check.message).to eq("1 of 1 MCP config needs attention: the rails-ai-context plugin (Claude Code): " \
                                    "Claude Code's MCP policy keeps its server from starting")
        command = [ "ruby", "-e", "load File.join(ENV.fetch('CLAUDE_PLUGIN_ROOT'), 'scripts', 'serve.rb')" ]
        # One command entry turns every stdio server to matching by command, so the github one needs its own.
        expect(check.fix).to eq("Add #{JSON.generate("serverCommand" => command)} to allowedMcpServers in your user settings, and a serverCommand " \
                                "entry for each stdio server it admits by name, since then every one matches by command")
      ensure
        FileUtils.rm_f(File.join(ENV.fetch("CLAUDE_CONFIG_DIR"), "settings.json"))
      end

      # Claude Code then reads its settings and plugins from whatever folder a session starts in.
      it "warns that CLAUDE_CONFIG_DIR is set but empty" do
        write(".claude/settings.json", plugin_settings)
        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with("CLAUDE_CONFIG_DIR").and_return("")

        expect(check.message).to eq("1 of 1 MCP config needs attention: the rails-ai-context plugin (Claude Code): CLAUDE_CONFIG_DIR " \
                                    "is set but empty, so Claude Code reads its settings and plugins from whatever folder a session starts in")
        expect(check.fix).to eq("Unset CLAUDE_CONFIG_DIR, or set it to the absolute path of the folder Claude Code keeps its settings in")
      end

      # Claude Code reads a relative one under each session's folder; doctor would read it under the app's.
      it "warns that CLAUDE_CONFIG_DIR is not an absolute path, wherever it would judge Claude Code" do
        allow(RailsAiContext.configuration).to receive(:ai_tools).and_return(%i[claude])
        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with("CLAUDE_CONFIG_DIR").and_return("ccrel")
        problem = "CLAUDE_CONFIG_DIR (`ccrel`) is not an absolute path, so Claude Code reads its settings and plugins from " \
                  "that path under whatever folder a session starts in"
        expect(check).to have_attributes(message: "1 of 1 MCP config needs attention: .mcp.json (Claude Code): #{problem}",
                                         fix: "Set CLAUDE_CONFIG_DIR to the absolute path of the folder Claude Code keeps its settings in")

        write(".mcp.json", server(bundled))
        expect(fresh_doctor.send(:check_mcp_json).message).to end_with(problem)

        write(".claude/settings.json", plugin_settings)
        expect(fresh_doctor.send(:check_mcp_json).message)
          .to eq("1 of 1 MCP config needs attention: the rails-ai-context plugin (Claude Code): #{problem}")
      end

      # Following an allowlist step where only a denylist blocks would stop every other server.
      it "names only the rule that blocks the plugin's server" do
        write(".claude/settings.json", plugin_settings)
        File.write(File.join(ENV.fetch("CLAUDE_CONFIG_DIR"), "settings.json"),
                   JSON.generate("deniedMcpServers" => [ { "serverName" => "plugin:rails-ai-context:rails-ai-context" } ]))

        expect(check.fix).to eq("Remove {\"serverName\":\"plugin:rails-ai-context:rails-ai-context\"} from deniedMcpServers in your user settings")
      ensure
        FileUtils.rm_f(File.join(ENV.fetch("CLAUDE_CONFIG_DIR"), "settings.json"))
      end

      # A server the policy blocks serves no session, so it is no setup to pass.
      it "judges a .mcp.json entry by Claude Code's MCP policy too" do
        write(".claude/settings.json", plugin_settings)
        write(".mcp.json", server(bundled))
        File.write(plugin_registry, JSON.generate("version" => 2, "plugins" => {
          "rails-ai-context@rails-ai-context" => [ { "scope" => "user", "installPath" => File.join(@root, "cache") } ]
        }))
        write("cache/.mcp.json", JSON.generate("mcpServers" => { "rails-ai-context" => { "command" => "ruby", "args" => [ "--", "${CLAUDE_PLUGIN_ROOT}/scripts/serve.rb" ] } }))
        File.write(File.join(ENV.fetch("CLAUDE_CONFIG_DIR"), "settings.json"), JSON.generate("allowedMcpServers" => [ { "serverName" => "github" } ]))
        expect(check.message).to include("Claude Code's MCP policy keeps its server from starting")

        write(".claude/settings.json", plugin_settings(false))
        allow(RailsAiContext.configuration).to receive(:ai_tools).and_return(%i[claude])
        verdict = fresh_doctor.send(:check_mcp_json)
        expect(verdict.message).to include("Claude Code's MCP policy keeps `rails-ai-context` from starting")
        # A name entry admits it without turning the github entry to matching by command.
        expect(verdict.fix).to eq("Add {\"serverName\":\"rails-ai-context\"} to allowedMcpServers in your user settings")
      ensure
        FileUtils.rm_f(File.join(ENV.fetch("CLAUDE_CONFIG_DIR"), "settings.json"))
      end

      # Unread, Claude Code's settings say nothing about the duplicate or its fix.
      it "warns about an empty CLAUDE_CONFIG_DIR before judging a .mcp.json entry" do
        write(".claude/settings.json", plugin_settings)
        write(".mcp.json", server(bundled))
        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with("CLAUDE_CONFIG_DIR").and_return("")

        expect(check.message).to include("CLAUDE_CONFIG_DIR is set but empty")
      end

      it "names the plugin as what passes where the .mcp.json entry is off" do
        write(".claude/settings.json", JSON.generate(JSON.parse(plugin_settings).merge("disabledMcpjsonServers" => [ "rails-ai-context" ])))
        write(".mcp.json", server(bundled))

        expect(check).to have_attributes(status: :pass, message: "1 of 1 MCP config valid: the rails-ai-context plugin (Claude Code)")
      end

      # The install writes no server where the committed settings turn the plugin on, so init would change nothing.
      it "names the setting that turns the committed plugin off for this user" do
        write(".claude/settings.json", plugin_settings)
        write(".claude/settings.local.json", plugin_settings(false))

        expect(check).to have_attributes(
          status: :warn,
          message: "1 of 1 MCP config needs attention: the rails-ai-context plugin (Claude Code): the app's .claude/settings.json " \
                   "turns it on, and .claude/settings.local.json turns it off for you",
          fix: "Run `claude plugin enable rails-ai-context@rails-ai-context --scope local`"
        )
      end

      # The setup the docs give plugin users chooses other tools, and still runs the plugin.
      it "checks Claude Code wherever the plugin serves the app, whatever AI tools were chosen" do
        allow(RailsAiContext.configuration).to receive(:ai_tools).and_return(%i[cursor])
        write(".claude/settings.json", plugin_settings)
        write(".mcp.json", server(bundled))
        write(".cursor/mcp.json", server(bundled))

        expect(check.message).to include("`rails-ai-context` in .mcp.json runs the server beside the rails-ai-context plugin")
      end

      # With no AI tools chosen, another tool's config that exists counts for what is broken in it.
      it "fails a broken config of another tool, and asks nothing of one that serves other things" do
        allow(RailsAiContext.configuration).to receive(:ai_tools).and_return(nil)
        write(".claude/settings.json", plugin_settings)
        write(".cursor/mcp.json", %({"mcpServers": {"other": {"command": "other"}}}))
        expect(check).to have_attributes(status: :pass, message: "1 of 1 MCP config valid: the rails-ai-context plugin (Claude Code)")

        write(".cursor/mcp.json", %({"mcpServers": {"other": {"command": "other"},}}))
        expect(app_doctor.send(:check_mcp_json).status).to eq(:fail)
      end

      # tool_mode :cli writes no MCP config, which does not stop Claude Code starting the plugin.
      it "checks the plugin under CLI-only mode" do
        allow(RailsAiContext.configuration).to receive(:tool_mode).and_return(:cli)
        write(".claude/settings.json", plugin_settings)
        write(".mcp.json", server(bundled))

        expect(check.message).to include("runs the server beside the rails-ai-context plugin")
      end

      it "asks nothing of context files where the plugin brings the rules and no AI tools were chosen" do
        allow(RailsAiContext.configuration).to receive(:ai_tools).and_return(nil)
        write(".claude/settings.json", plugin_settings)

        expect(app_doctor.send(:check_context_freshness)).to be_nil
      end

      # The .mcp.json is the team's, and the next context run would write the entry back.
      it "asks a user whose own settings run the plugin to turn the .mcp.json server off for themselves" do
        File.write(File.join(ENV.fetch("CLAUDE_CONFIG_DIR"), "settings.json"), plugin_settings)
        write(".mcp.json", server(bundled))

        expect(check.fix).to eq("Turn `rails-ai-context` off with /mcp in a session started here, " \
                                "or run `claude plugin disable rails-ai-context@rails-ai-context --scope local`")
      ensure
        FileUtils.rm_f(File.join(ENV.fetch("CLAUDE_CONFIG_DIR"), "settings.json"))
      end

      # A /mcp switch is kept for the repository, but only a session that loads the server lists it.
      it "names a worktree's own folder for the /mcp switch of its .mcp.json server" do
        main = File.join(@root, "main")
        write("main/config/application.rb", "")
        git = ->(dir, *args) { system("git", "-C", dir, "-c", "user.email=a@b.c", "-c", "user.name=a", *args, out: File::NULL, err: File::NULL) }
        skip "git is not available" unless git.(main, "init", "-q")
        git.(main, "add", "-A")
        git.(main, "commit", "-qm", "init")
        tree = File.join(@root, "tree")
        git.(main, "worktree", "add", "-q", tree)
        File.write(File.join(tree, ".mcp.json"), server(bundled))
        File.write(File.join(ENV.fetch("CLAUDE_CONFIG_DIR"), "settings.json"), plugin_settings)

        doctor = described_class.new(RailsAiContext::StaticApp.new(tree), from: tree)
        allow(doctor).to receive(:client_path).and_return(@bin)
        expect(doctor.send(:check_mcp_json).fix).to start_with("Turn `rails-ai-context` off with /mcp in a session started here,")
      ensure
        FileUtils.rm_f(File.join(ENV.fetch("CLAUDE_CONFIG_DIR"), "settings.json"))
      end

      # Turning the plugin off still leaves two of the gem's servers.
      it "names every removal, and no disable, where a session runs two servers beside the plugin" do
        write(".claude/settings.json", plugin_settings)
        File.write(File.join(ENV.fetch("CLAUDE_CONFIG_DIR"), ".claude.json"), JSON.generate(
          "mcpServers" => { "usr" => { "command" => "rails-ai-context", "args" => [ "serve" ] } },
          "projects" => { @root => { "mcpServers" => { "loc" => { "command" => "rails-ai-context", "args" => [ "serve" ] } } } }
        ))

        expect(check.fix).to eq("Run `claude mcp remove usr -s user` and run `claude mcp remove loc -s local`")
        expect(check.message).to end_with("so Claude Code lists every tool 3 times")
      ensure
        FileUtils.rm_f(File.join(ENV.fetch("CLAUDE_CONFIG_DIR"), ".claude.json"))
      end

      # Claude Code refuses to disable a plugin managed settings turn on.
      it "offers no disable where managed settings turn the plugin on" do
        write(".claude/settings.json", plugin_settings)
        write(".mcp.json", server(bundled))
        managed = RailsAiContext::ClaudeCodeSettings::MANAGED_SETTINGS
        FileUtils.mkdir_p(File.dirname(managed))
        File.write(managed, plugin_settings)

        expect(check.fix).to eq("Remove `rails-ai-context` from .mcp.json")
      ensure
        FileUtils.rm_f(managed)
      end

      # Deployed, managed-mcp.json names every server Claude Code starts, the plugin's and .mcp.json's left out.
      it "judges Claude Code by managed-mcp.json where it is deployed" do
        write(".claude/settings.json", plugin_settings)
        write(".mcp.json", server(bundled))
        managed_mcp = File.join(File.dirname(RailsAiContext::ClaudeCodeSettings::MANAGED_SETTINGS), "managed-mcp.json")
        FileUtils.mkdir_p(File.dirname(managed_mcp))
        File.write(managed_mcp, JSON.generate("mcpServers" => { "github" => { "command" => "gh" } }))

        expect(check).to have_attributes(
          status: :warn,
          message: "1 of 1 MCP config needs attention: #{managed_mcp} (Claude Code): it names every MCP server Claude Code " \
                   "starts on this machine, and none of them serves this app",
          fix: "Have whoever manages your Claude Code settings add " \
               "#{JSON.generate("rails-ai-context" => { "command" => "rails-ai-context", "args" => [ "serve" ] })} to its mcpServers"
        )

        File.write(managed_mcp, server(bare))
        expect(fresh_doctor.send(:check_mcp_json))
          .to have_attributes(status: :pass, message: "1 of 1 MCP config valid")
      ensure
        FileUtils.rm_f(managed_mcp)
      end

      # Claude Code applies a deny and /mcp to managed-mcp.json's servers, so doctor names what keeps the one for this app off.
      it "names what keeps managed-mcp.json's server for this app from starting" do
        allow(RailsAiContext.configuration).to receive(:ai_tools).and_return(%i[claude])
        managed_dir = File.dirname(RailsAiContext::ClaudeCodeSettings::MANAGED_SETTINGS)
        FileUtils.mkdir_p(managed_dir)
        File.write(File.join(managed_dir, "managed-mcp.json"), JSON.generate("mcpServers" => { "rails" => { "command" => "rails-ai-context", "args" => [ "serve" ] } }))
        File.write(File.join(ENV.fetch("CLAUDE_CONFIG_DIR"), "settings.json"), JSON.generate("deniedMcpServers" => [ { "serverCommand" => bare } ]))
        expect(check).to have_attributes(status: :warn, fix: "Remove {\"serverCommand\":[\"rails-ai-context\",\"serve\"]} from deniedMcpServers in your user settings")
        expect(check.message).to include("Claude Code does not start `rails`, its server for this app: the MCP policy keeps it off")

        FileUtils.rm_f(File.join(ENV.fetch("CLAUDE_CONFIG_DIR"), "settings.json"))
        File.write(File.join(ENV.fetch("CLAUDE_CONFIG_DIR"), ".claude.json"), JSON.generate("projects" => { @root => { "disabledMcpServers" => [ "rails" ] } }))
        expect(fresh_doctor.send(:check_mcp_json).fix)
          .to eq("Turn `rails` back on with /mcp in a session started here")
      ensure
        FileUtils.rm_rf(managed_dir)
        FileUtils.rm_f([ File.join(ENV.fetch("CLAUDE_CONFIG_DIR"), "settings.json"), File.join(ENV.fetch("CLAUDE_CONFIG_DIR"), ".claude.json") ])
      end

      # An HTTP entry is the endpoint's own to judge, as in .mcp.json; a serverUrl deny still keeps it off.
      it "passes managed-mcp.json's HTTP entry for this app, and names the serverUrl deny that keeps it off" do
        allow(RailsAiContext.configuration).to receive(:ai_tools).and_return(%i[claude])
        managed_dir = File.dirname(RailsAiContext::ClaudeCodeSettings::MANAGED_SETTINGS)
        FileUtils.mkdir_p(managed_dir)
        File.write(File.join(managed_dir, "managed-mcp.json"), JSON.generate("mcpServers" => { "rails-ai-context" => { "type" => "http", "url" => "http://localhost:3000/mcp" } }))
        expect(check).to have_attributes(status: :pass, message: "1 of 1 MCP config valid")

        File.write(File.join(ENV.fetch("CLAUDE_CONFIG_DIR"), "settings.json"), JSON.generate("deniedMcpServers" => [ { "serverUrl" => "http://localhost:3000/*" } ]))
        fresh = fresh_doctor.send(:check_mcp_json)
        expect(fresh).to have_attributes(status: :warn, fix: 'Remove {"serverUrl":"http://localhost:3000/*"} from deniedMcpServers in your user settings')
        expect(fresh.message).to include("Claude Code does not start `rails-ai-context`, its server for this app: the MCP policy keeps it off")
      ensure
        FileUtils.rm_rf(managed_dir)
        FileUtils.rm_f(File.join(ENV.fetch("CLAUDE_CONFIG_DIR"), "settings.json"))
      end

      # A gem's executables are batch files on Windows, which Claude Code cannot start without a shell.
      it "names a managed-mcp.json entry Windows can start" do
        allow(RailsAiContext::McpConfigGenerator).to receive(:windows_shell?).and_return(true)
        managed_dir = File.dirname(RailsAiContext::ClaudeCodeSettings::MANAGED_SETTINGS)
        FileUtils.mkdir_p(managed_dir)
        File.write(File.join(managed_dir, "managed-mcp.json"), JSON.generate("mcpServers" => {}))

        expect(check.fix).to include(JSON.generate("rails-ai-context" => { "command" => "cmd", "args" => %w[/c rails-ai-context serve] }))
      ensure
        FileUtils.rm_rf(managed_dir)
      end

      # Claude Code takes it from the settings' env block too, and resolves a relative one under each session's folder.
      it "names the settings file whose env block sets a CLAUDE_CONFIG_DIR that is not absolute" do
        write(".claude/settings.json", plugin_settings)
        user = File.join(ENV.fetch("CLAUDE_CONFIG_DIR"), "settings.json")
        File.write(user, JSON.generate("env" => { "CLAUDE_CONFIG_DIR" => "rel" }))

        expect(check).to have_attributes(
          message: "1 of 1 MCP config needs attention: the rails-ai-context plugin (Claude Code): CLAUDE_CONFIG_DIR (`rel`) in the env block of " \
                   "#{user} is not an absolute path, so Claude Code reads its settings and plugins from that path under whatever folder a session starts in",
          fix: "Set CLAUDE_CONFIG_DIR in the env block of #{user} to the absolute path of the folder Claude Code keeps its settings in, or remove it"
        )
      ensure
        FileUtils.rm_f(user)
      end

      # A marketplace Claude Code recorded from another source refuses a second add.
      it "names a plain install where Claude Code already knows the plugin's marketplace" do
        allow(RailsAiContext.configuration).to receive(:ai_tools).and_return(nil)
        write(".claude/settings.json", plugin_settings)
        FileUtils.rm_rf(File.dirname(plugin_registry))
        FileUtils.mkdir_p(File.dirname(plugin_registry))
        File.write(File.join(File.dirname(plugin_registry), "known_marketplaces.json"),
                   JSON.generate("rails-ai-context" => { "source" => { "source" => "github", "repo" => "someone/fork" } }))

        expect(check.fix).to eq("Run `claude plugin install rails-ai-context@rails-ai-context --scope local`")
      end

      # Under a managed lock plugin servers still start, which the plugin is.
      it "offers the plugin first where the managed lock keeps a .mcp.json server off" do
        allow(RailsAiContext.configuration).to receive(:ai_tools).and_return(%i[claude])
        write(".mcp.json", server(bundled))
        managed = RailsAiContext::ClaudeCodeSettings::MANAGED_SETTINGS
        FileUtils.mkdir_p(File.dirname(managed))
        File.write(managed, JSON.generate("strictPluginOnlyCustomization" => [ "mcp" ]))

        expect(check.fix).to eq("Run `claude plugin install rails-ai-context --marketplace crisnahine/rails-ai-context --scope local`, whose server " \
                                "this lock still starts, or have whoever manages your Claude Code settings lift strictPluginOnlyCustomization's " \
                                "mcp lock, which lets only plugin and managed servers start")
      ensure
        FileUtils.rm_f(managed)
      end

      it "asks whoever manages the settings to change a managed allowlist, and to turn a managed off back on" do
        write(".claude/settings.json", plugin_settings)
        File.write(plugin_registry, JSON.generate("version" => 2, "plugins" => {
          "rails-ai-context@rails-ai-context" => [ { "scope" => "user", "installPath" => File.join(@root, "cache") } ]
        }))
        write("cache/.mcp.json", File.read(File.expand_path("../../../plugins/rails-ai-context/.mcp.json", __dir__)))
        managed = RailsAiContext::ClaudeCodeSettings::MANAGED_SETTINGS
        FileUtils.mkdir_p(File.dirname(managed))
        File.write(managed, JSON.generate("allowedMcpServers" => [ { "serverCommand" => %w[gh mcp] } ]))
        expect(check.fix).to start_with("Have whoever manages your Claude Code settings add {\"serverCommand\":")

        File.write(managed, plugin_settings(false))
        expect(fresh_doctor.send(:check_mcp_json))
          .to have_attributes(fix: "Have whoever manages your Claude Code settings turn it on")
      ensure
        FileUtils.rm_f(managed)
      end

      # Claude Code starts one server per name, whatever scopes hold it.
      it "counts a name a user scope server and .mcp.json share as one server" do
        File.write(File.join(ENV.fetch("CLAUDE_CONFIG_DIR"), "settings.json"), plugin_settings)
        write(".mcp.json", server(bare))
        File.write(File.join(ENV.fetch("CLAUDE_CONFIG_DIR"), ".claude.json"), JSON.generate("mcpServers" => { "rails-ai-context" => { "command" => "rails-ai-context", "args" => [ "serve" ] } }))

        expect(check.message).to end_with("lists every tool twice")
        expect(check.fix).to end_with("or run `claude plugin disable rails-ai-context@rails-ai-context --scope local`")
      ensure
        FileUtils.rm_f([ File.join(ENV.fetch("CLAUDE_CONFIG_DIR"), "settings.json"), File.join(ENV.fetch("CLAUDE_CONFIG_DIR"), ".claude.json") ])
      end

      # The plugin's choice counts where its committed settings make it, whatever one user turned off.
      it "takes a committed plugin a user turned off as the choice for context files and under CLI-only mode" do
        allow(RailsAiContext.configuration).to receive(:ai_tools).and_return(nil)
        write(".claude/settings.json", plugin_settings)
        write(".claude/settings.local.json", plugin_settings(false))
        expect(app_doctor.send(:check_context_freshness)).to be_nil

        allow(RailsAiContext.configuration).to receive(:tool_mode).and_return(:cli)
        expect(fresh_doctor.send(:check_mcp_json).message).to include("turns it off for you")
      end

      # The app's own sessions start its .mcp.json server; only sessions started above it run the plugin.
      it "credits the .mcp.json server where the plugin runs only in sessions started above the app" do
        allow(RailsAiContext.configuration).to receive(:ai_tools).and_return(%i[claude])
        Dir.mktmpdir do |dir|
          ws = File.realpath(dir)
          app = File.join(ws, "shop")
          FileUtils.mkdir_p([ File.join(app, "config"), File.join(ws, ".claude") ])
          File.write(File.join(app, "config", "application.rb"), "")
          File.write(File.join(ws, ".claude", "settings.json"), plugin_settings)
          File.write(File.join(app, ".mcp.json"), server(bare))
          doctor = described_class.new(RailsAiContext::StaticApp.new(app))
          allow(doctor).to receive(:client_path).and_return(@bin)

          expect(doctor.send(:check_mcp_json)).to have_attributes(status: :pass, message: "1 of 1 MCP config valid")
        end
      end

      # In a repository's subfolder, the local file that wins is the repository's, where `--scope local` writes it.
      it "names the local settings file that turns a committed plugin off, where it is" do
        skip "Claude Code keeps each folder's local settings apart on Windows" if Gem.win_platform?

        allow(RailsAiContext.configuration).to receive(:ai_tools).and_return(%i[claude])
        Dir.mktmpdir do |dir|
          repo = File.realpath(dir)
          shop = File.join(repo, "shop")
          FileUtils.mkdir_p([ File.join(repo, ".git"), File.join(repo, ".claude"), File.join(shop, "config"), File.join(shop, ".claude") ])
          File.write(File.join(shop, "config", "application.rb"), "")
          File.write(File.join(shop, ".claude", "settings.json"), plugin_settings)
          File.write(File.join(repo, ".claude", "settings.local.json"), plugin_settings(false))
          doctor = described_class.new(RailsAiContext::StaticApp.new(shop))
          allow(doctor).to receive(:client_path).and_return(@bin)

          expect(doctor.send(:check_mcp_json).message).to end_with("the app's .claude/settings.json turns it on, and ../.claude/settings.local.json turns it off for you")
        end
      end

      # A /mcp switch is kept per repository, so one session started there flips it for all of them.
      it "names one session per repository for the /mcp switch" do
        allow(RailsAiContext.configuration).to receive(:ai_tools).and_return(%i[claude])
        Dir.mktmpdir do |dir|
          repo = File.realpath(dir)
          app = File.join(repo, "shop")
          FileUtils.mkdir_p([ File.join(repo, ".git"), File.join(app, "config") ])
          File.write(File.join(app, "config", "application.rb"), "")
          File.write(File.join(ENV.fetch("CLAUDE_CONFIG_DIR"), "settings.json"), plugin_settings)
          File.write(File.join(ENV.fetch("CLAUDE_CONFIG_DIR"), ".claude.json"),
                     JSON.generate("projects" => { repo => { "disabledMcpServers" => [ "plugin:rails-ai-context:rails-ai-context" ] } }))
          doctor = described_class.new(RailsAiContext::StaticApp.new(app))
          allow(doctor).to receive(:client_path).and_return(@bin)

          expect(doctor.send(:check_mcp_json).fix).to eq("Turn the plugin's server back on with /mcp in a session started here")
        end
      ensure
        FileUtils.rm_f([ File.join(ENV.fetch("CLAUDE_CONFIG_DIR"), "settings.json"), File.join(ENV.fetch("CLAUDE_CONFIG_DIR"), ".claude.json") ])
      end

      # A session started where doctor was typed is one that could serve the app.
      it "reads the settings of the folder doctor was typed in" do
        models = File.join(@root, "app", "models")
        write("app/models/.claude/settings.json", plugin_settings)

        typed = described_class.new(RailsAiContext::StaticApp.new(@root), from: models)
        allow(typed).to receive(:client_path).and_return(@bin)
        expect(typed.send(:check_mcp_json)).to have_attributes(
          message: "1 of 1 MCP config needs attention: .mcp.json (Claude Code): the rails-ai-context plugin serves this app " \
                   "only in sessions started here, not in ones started in ../..",
          fix: "Start Claude Code here, or run `claude plugin enable rails-ai-context@rails-ai-context --scope local` in ../.."
        )
      end

      # Claude Code starts the server while any marketplace's copy is on.
      it "disables every id the plugin runs under" do
        File.write(plugin_registry, JSON.generate("version" => 2, "plugins" => {
          "rails-ai-context@rails-ai-context" => [ { "scope" => "user" } ], "rails-ai-context@mirror" => [ { "scope" => "user" } ]
        }))
        write(".claude/settings.json", JSON.generate("enabledPlugins" => { "rails-ai-context@rails-ai-context" => true, "rails-ai-context@mirror" => true }))
        write(".mcp.json", server(bundled))

        expect(check.fix).to eq("Remove `rails-ai-context` from .mcp.json, or run `claude plugin disable rails-ai-context@rails-ai-context --scope local` " \
                                "and `claude plugin disable rails-ai-context@mirror --scope local`")
      end

      it "names a user scope server beside the plugin, with the command that removes it" do
        write(".claude/settings.json", plugin_settings)
        File.write(File.join(ENV.fetch("CLAUDE_CONFIG_DIR"), ".claude.json"),
                   JSON.generate("mcpServers" => { "rails-ai-context" => { "command" => "rails-ai-context", "args" => [ "serve" ] } }))

        expect(check).to have_attributes(status: :warn, fix: "Run `claude mcp remove rails-ai-context -s user`, or run `claude plugin disable rails-ai-context@rails-ai-context --scope local`")
        expect(check.message).to eq("1 of 1 MCP config needs attention: the rails-ai-context plugin (Claude Code): the user scope " \
                                    "server `rails-ai-context` runs the server beside the rails-ai-context plugin, so Claude Code " \
                                    "lists every tool twice")
      ensure
        FileUtils.rm_f(File.join(ENV.fetch("CLAUDE_CONFIG_DIR"), ".claude.json"))
      end

      # A file named from the app's folder would be one that is not there.
      it "names each policy file as a path from where doctor ran, the repository's local file included" do
        skip "Claude Code keeps each folder's local settings apart on Windows" if Gem.win_platform?

        allow(RailsAiContext.configuration).to receive(:ai_tools).and_return(%i[claude])
        Dir.mktmpdir do |dir|
          repo = File.realpath(dir)
          shop = File.join(repo, "shop")
          FileUtils.mkdir_p([ File.join(repo, ".git"), File.join(repo, ".claude"), File.join(shop, "config") ])
          File.write(File.join(shop, "config", "application.rb"), "")
          File.write(File.join(ENV.fetch("CLAUDE_CONFIG_DIR"), "settings.json"), plugin_settings)
          local = File.join(repo, ".claude", "settings.local.json")
          File.write(local, JSON.generate("deniedMcpServers" => [ { "serverName" => "plugin:rails-ai-context:rails-ai-context" } ]))
          doctor = described_class.new(RailsAiContext::StaticApp.new(shop))
          allow(doctor).to receive(:client_path).and_return(@bin)
          expect(doctor.send(:check_mcp_json).fix)
            .to eq("Remove {\"serverName\":\"plugin:rails-ai-context:rails-ai-context\"} from deniedMcpServers in ../.claude/settings.local.json")

          FileUtils.rm_f(File.join(ENV.fetch("CLAUDE_CONFIG_DIR"), "settings.json"))
          File.write(local, JSON.generate("allowedMcpServers" => [ { "serverName" => "github" } ]))
          File.write(File.join(shop, ".mcp.json"), server(bare))
          doctor = described_class.new(RailsAiContext::StaticApp.new(shop))
          allow(doctor).to receive(:client_path).and_return(@bin)
          expect(doctor.send(:check_mcp_json).fix).to eq("Add {\"serverName\":\"rails-ai-context\"} to allowedMcpServers in ../.claude/settings.local.json")
        end
      ensure
        FileUtils.rm_f(File.join(ENV.fetch("CLAUDE_CONFIG_DIR"), "settings.json"))
      end

      # Each deny holds on its own, and a managed one only an admin lifts.
      it "names every deny of the plugin's server, the managed one first" do
        write(".claude/settings.json", plugin_settings)
        deny = JSON.generate("deniedMcpServers" => [ { "serverName" => "plugin:rails-ai-context:rails-ai-context" } ])
        File.write(File.join(ENV.fetch("CLAUDE_CONFIG_DIR"), "settings.json"), deny)
        managed = RailsAiContext::ClaudeCodeSettings::MANAGED_SETTINGS
        FileUtils.mkdir_p(File.dirname(managed))
        File.write(managed, deny)

        rule = JSON.generate("serverName" => "plugin:rails-ai-context:rails-ai-context")
        expect(check.fix).to eq("Have whoever manages your Claude Code settings remove #{rule} from deniedMcpServers in the managed settings, " \
                                "and remove #{rule} from deniedMcpServers in your user settings")
      ensure
        FileUtils.rm_f([ managed, File.join(ENV.fetch("CLAUDE_CONFIG_DIR"), "settings.json") ])
      end

      it "sends a CLAUDE_CONFIG_DIR the managed settings set to whoever manages them" do
        write(".claude/settings.json", plugin_settings)
        managed = RailsAiContext::ClaudeCodeSettings::MANAGED_SETTINGS
        FileUtils.mkdir_p(File.dirname(managed))
        File.write(managed, JSON.generate("env" => { "CLAUDE_CONFIG_DIR" => "rel" }))

        expect(check.fix).to start_with("Have whoever manages your Claude Code settings set CLAUDE_CONFIG_DIR in the env block of #{managed}")
      ensure
        FileUtils.rm_f(managed)
      end

      # Filled by the install, an empty file would hold the second server the plugin replaces.
      it "passes the plugin over an empty .mcp.json, and never names the install" do
        write(".claude/settings.json", plugin_settings)
        write(".mcp.json", "")

        expect(check).to have_attributes(status: :pass, message: "1 of 1 MCP config valid: the rails-ai-context plugin (Claude Code)")
      end

      it "judges only Claude Code under CLI-only mode, whatever else was chosen" do
        allow(RailsAiContext.configuration).to receive(:tool_mode).and_return(:cli)
        allow(RailsAiContext.configuration).to receive(:ai_tools).and_return(%i[claude cursor])
        write(".claude/settings.json", plugin_settings)
        write(".cursor/mcp.json", %({"mcpServers": {"other": {"command": "other"},}}))

        expect(check).to have_attributes(status: :pass, message: "1 of 1 MCP config valid: the rails-ai-context plugin (Claude Code)")
      end

      # Claude Code runs a plugin only where the winning value is true; a list of version constraints is not.
      it "takes any value but true in the local settings as turning the committed plugin off" do
        write(".claude/settings.json", plugin_settings)
        write(".claude/settings.local.json", plugin_settings([ "^1.0.0" ]))

        expect(check).to have_attributes(
          message: "1 of 1 MCP config needs attention: the rails-ai-context plugin (Claude Code): the app's .claude/settings.json " \
                   "turns it on, and .claude/settings.local.json turns it off for you",
          fix: "Run `claude plugin enable rails-ai-context@rails-ai-context --scope local`"
        )
      end

      # The install would write no server there either.
      it "names what turned the committed plugin off where .mcp.json holds no server of the gem's" do
        write(".claude/settings.json", plugin_settings)
        write(".claude/settings.local.json", plugin_settings(false))
        write(".mcp.json", JSON.generate("mcpServers" => { "github" => { "command" => "gh" } }))

        expect(check.message).to end_with("and .claude/settings.local.json turns it off for you")
      end

      # The local install enables it as well, so one step does both.
      it "names the local install where a user turned the committed plugin off and never installed it" do
        write(".claude/settings.json", plugin_settings)
        write(".claude/settings.local.json", plugin_settings(false))
        FileUtils.rm_rf(File.dirname(plugin_registry))

        expect(check.fix).to eq("Run `claude plugin install rails-ai-context --marketplace crisnahine/rails-ai-context --scope local`")
      end

      # The install writes no Claude Code server where the committed settings turn the plugin on.
      it "never names the install for a .mcp.json entry where the committed settings turn the plugin on" do
        write(".claude/settings.json", plugin_settings)
        write("Gemfile", %(gem "rails"\n))
        write("Gemfile.lock", lockfile("rails"))
        write(".mcp.json", JSON.generate("mcpServers" => { "rails" => { "command" => "bundle", "args" => %w[exec rails-ai-context serve] } }))
        expect(check).to have_attributes(status: :warn, fix: "Remove `rails` from .mcp.json; the rails-ai-context plugin serves this app")
        expect(check.message).to end_with("`bundle exec rails-ai-context serve` cannot start - Gemfile.lock has no rails-ai-context")

        write(".claude/settings.local.json", plugin_settings(false))
        expect(fresh_doctor.send(:check_mcp_json)).to have_attributes(
                   status: :fail,
                   fix: "Fix `rails` in .mcp.json by hand, or run `claude plugin enable rails-ai-context@rails-ai-context --scope local`"
                 )
      end

      it "ends a committed plugin's .mcp.json fix at the hand edit, since the install leaves that file alone" do
        fix = -> { fresh_doctor.send(:check_mcp_json).fix }
        write(".claude/settings.json", plugin_settings)
        write(".mcp.json", %({"mcpServers":{"rails-ai-context":{"command":"rails-ai-context","args":["serve"],"env":{"X":"caf\xE9"}}}}).b)
        expect(fix.call).to eq("Save .mcp.json as UTF-8, then remove the gem's server from it; the rails-ai-context plugin serves this app")

        write(".mcp.json", %({"mcpServers":{"rails-ai-context":{"command":"rails-ai-context","args":["serve"]},}}))
        expect(fix.call).to eq("Make .mcp.json valid JSON holding an object, then remove the gem's server from it; the rails-ai-context plugin serves this app")

        write(".claude/settings.local.json", plugin_settings(false))
        expect(fix.call).to eq("Make .mcp.json valid JSON holding an object")
      end

      # The server the install leaves serves this user, under whatever name.
      it "passes a hand-named .mcp.json server of the gem's where a user turned the committed plugin off" do
        write(".claude/settings.json", plugin_settings)
        write(".claude/settings.local.json", plugin_settings(false))
        write("Gemfile", %(gem "rails-ai-context"\n))
        write("Gemfile.lock", lockfile("rails-ai-context"))
        write(".mcp.json", JSON.generate("mcpServers" => { "rails" => { "command" => "bundle", "args" => %w[exec rails-ai-context serve] } }))

        expect(check.status).to eq(:pass)
      end

      it "judges the managed-mcp.json server that starts as a .mcp.json entry is judged" do
        allow(RailsAiContext.configuration).to receive(:ai_tools).and_return(%i[claude])
        write("Gemfile", %(gem "rails"\n))
        write("Gemfile.lock", lockfile("rails"))
        managed_mcp = File.join(File.dirname(RailsAiContext::ClaudeCodeSettings::MANAGED_SETTINGS), "managed-mcp.json")
        FileUtils.mkdir_p(File.dirname(managed_mcp))
        File.write(managed_mcp, server(bundled))

        expect(check).to have_attributes(
          status: :fail,
          message: "1 of 1 MCP config needs attention: #{managed_mcp} (Claude Code): `bundle exec rails-ai-context serve` cannot start - " \
                   "Gemfile.lock has no rails-ai-context",
          fix: "Have whoever manages your Claude Code settings fix `rails-ai-context` in #{managed_mcp}"
        )
      ensure
        FileUtils.rm_f(managed_mcp)
      end

      # Added under the name already there, it would replace the other app's server; unpinned, it would start there too.
      it "suggests a managed-mcp.json entry under a free name, pinned to this app, beside another app's server" do
        managed_mcp = File.join(File.dirname(RailsAiContext::ClaudeCodeSettings::MANAGED_SETTINGS), "managed-mcp.json")
        FileUtils.mkdir_p(File.dirname(managed_mcp))
        allow(RailsAiContext.configuration).to receive(:ai_tools).and_return(%i[claude])
        name = RailsAiContext::Install::Workspace.server_names([ File.basename(@root) ]).values.first
        other = { "command" => "rails-ai-context", "args" => %w[serve --app-path /srv/other] }
        File.write(managed_mcp, JSON.generate("mcpServers" => { "rails-ai-context" => other, name => other }))

        expect(check.fix).to eq("Have whoever manages your Claude Code settings add " \
                                "#{JSON.generate("#{name}-2" => { "command" => "rails-ai-context", "args" => [ "serve", "--app-path", @root ] })} to its mcpServers")
      ensure
        FileUtils.rm_f(managed_mcp)
      end

      # Claude Code refuses to start with a managed file it cannot read.
      it "fails Claude Code where a managed settings file is not JSON" do
        write(".claude/settings.json", plugin_settings)
        managed = RailsAiContext::ClaudeCodeSettings::MANAGED_SETTINGS
        FileUtils.mkdir_p(File.dirname(managed))
        File.write(managed, "{")

        expect(check).to have_attributes(
          status: :fail,
          message: "1 of 1 MCP config needs attention: #{managed} (Claude Code): Claude Code will not start until #{managed} is fixed",
          fix: "Ask whoever manages your Claude Code settings to fix it"
        )
      ensure
        FileUtils.rm_f(managed)
      end

      it "names the managed marketplace gate that keeps the plugin from loading, and the key that sets it" do
        write(".claude/settings.json", plugin_settings)
        File.write(File.join(File.dirname(plugin_registry), "known_marketplaces.json"),
                   JSON.generate("rails-ai-context" => { "source" => { "source" => "github", "repo" => "crisnahine/rails-ai-context" } }))
        managed = RailsAiContext::ClaudeCodeSettings::MANAGED_SETTINGS
        FileUtils.mkdir_p(File.dirname(managed))
        File.write(managed, JSON.generate("strictKnownMarketplaces" => []))
        expect(check).to have_attributes(
          message: "1 of 1 MCP config needs attention: the rails-ai-context plugin (Claude Code): Claude Code's managed marketplace policy keeps it from loading",
          fix: "Have whoever manages your Claude Code settings add the rails-ai-context marketplace's source to strictKnownMarketplaces in #{managed}"
        )

        File.write(managed, JSON.generate("blockedMarketplaces" => [ { "source" => "github", "repo" => "crisnahine/rails-ai-context" } ]))
        expect(fresh_doctor.send(:check_mcp_json).fix)
          .to eq("Have whoever manages your Claude Code settings take the entry that names the rails-ai-context marketplace out of blockedMarketplaces in #{managed}")
      ensure
        FileUtils.rm_f(managed)
      end

      # An install fails while the marketplace's folder is gone.
      it "says to add a local marketplace again once its folder is gone" do
        write(".claude/settings.json", plugin_settings)
        gone = File.join(@root, "moved-marketplace")
        File.write(File.join(File.dirname(plugin_registry), "known_marketplaces.json"),
                   JSON.generate("rails-ai-context" => { "source" => { "source" => "directory", "path" => gone } }))

        expect(check).to have_attributes(
          message: "1 of 1 MCP config needs attention: the rails-ai-context plugin (Claude Code): Claude Code loads the plugin from #{gone}, which is gone",
          fix: "Add the marketplace again from its folder with `claude plugin marketplace add <folder>`"
        )
      end

      it "says a local marketplace that is there has no plugin, not that it is gone" do
        write(".claude/settings.json", plugin_settings)
        checkout = File.join(@root, "old-checkout")
        write("old-checkout/.claude-plugin/marketplace.json", JSON.generate("plugins" => [ { "name" => "rails-ai-context", "source" => "./plugins/rails-ai-context" } ]))
        File.write(File.join(File.dirname(plugin_registry), "known_marketplaces.json"),
                   JSON.generate("rails-ai-context" => { "source" => { "source" => "directory", "path" => checkout } }))

        expect(check).to have_attributes(
          message: "1 of 1 MCP config needs attention: the rails-ai-context plugin (Claude Code): the marketplace at #{checkout} has no rails-ai-context plugin",
          fix: "Check out a version that has plugins/rails-ai-context, or add the marketplace from one that does"
        )
        expect(app_doctor.send(:claude_plugin_switch_on, @root, "rails-ai-context@rails-ai-context"))
          .to eq("the marketplace at #{checkout} has no rails-ai-context plugin: check out a version that has plugins/rails-ai-context, or add the marketplace from one that does")
      end

      # Claude Code reads no project settings below the folder a session starts in.
      it "notes where a session started where doctor was typed, inside the app, would not run the plugin" do
        write(".claude/settings.json", plugin_settings)
        typed = described_class.new(RailsAiContext::StaticApp.new(@root), from: File.join(@root, "app", "models"))
        FileUtils.mkdir_p(File.join(@root, "app", "models"))
        allow(typed).to receive(:client_path).and_return(@bin)

        expect(typed.send(:check_mcp_json)).to have_attributes(
          status: :pass,
          message: "1 of 1 MCP config valid: the rails-ai-context plugin (Claude Code); a session started here would not run it: " \
                   "run `claude plugin enable rails-ai-context@rails-ai-context --scope local`"
        )
        expect(check.message).to eq("1 of 1 MCP config valid: the rails-ai-context plugin (Claude Code)")
      end

      it "notes it at an engine's dummy app root, below the engine whose settings turn the plugin on" do
        write(".claude/settings.json", plugin_settings)
        dummy = File.join(@root, "test", "dummy")
        FileUtils.mkdir_p(File.join(dummy, "config"))
        allow(RailsAiContext::PathResolver).to receive(:enclosing_engine_roots).and_call_original
        allow(RailsAiContext::PathResolver).to receive(:enclosing_engine_roots).with(dummy).and_return([ @root ])
        typed = described_class.new(RailsAiContext::StaticApp.new(dummy), from: dummy)
        allow(typed).to receive(:client_path).and_return(@bin)

        expect(typed.send(:check_mcp_json)).to have_attributes(
          status: :pass,
          message: "1 of 1 MCP config valid: the rails-ai-context plugin (Claude Code); a session started here would not run it: " \
                   "run `claude plugin enable rails-ai-context@rails-ai-context --scope local`"
        )
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

      # init writes its own name beside a hand-named server and leaves that one as it is.
      it "has a hand-named server mended by hand, never by init" do
        allow(RailsAiContext.configuration).to receive(:ai_tools).and_return(%i[claude])
        write(".mcp.json", JSON.generate("mcpServers" => { "myctx" => { "command" => "bundle", "args" => %w[exec rails-ai-context serve] } }))

        expect(check).to have_attributes(status: :fail, fix: "Fix or remove `myctx` in .mcp.json by hand")
        expect(check.message).to end_with("`bundle exec rails-ai-context serve` cannot start - Gemfile.lock has no rails-ai-context")
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

    # On Windows the install starts the server through `cmd /c`: a gem's
    # executable there is a .bat file, which a client starting its server
    # without a shell may not run. `bundle` sits beside its .bat so the
    # lookup finds it on every platform these examples run on.
    context "on Windows, where a gem's executables are batch files" do
      let(:batch_bin) do
        Dir.mktmpdir("bin").tap do |dir|
          File.write(File.join(dir, "bundle"), "#!/bin/sh\n")
          File.chmod(0o755, File.join(dir, "bundle"))
          File.write(File.join(dir, "bundle.bat"), "@echo off\r\n")
        end
      end

      before do
        allow(RailsAiContext::McpConfigGenerator).to receive(:windows_shell?).and_return(true)
        allow(RailsAiContext.configuration).to receive(:tool_mode).and_return(:mcp)
        allow(RailsAiContext.configuration).to receive(:ai_tools).and_return(%i[claude])
        allow(app_doctor).to receive(:client_path).and_return(batch_bin)
      end

      after { FileUtils.rm_rf(batch_bin) }

      it "passes an entry that starts the command through cmd /c" do
        write(".mcp.json", server(%w[cmd /c] + bundled))

        expect(check.status).to eq(:pass)
      end

      it "warns about one that starts the batch file bare, and names the install that wraps it" do
        write(".mcp.json", server(bundled))

        expect(check.status).to eq(:warn)
        expect(check.message).to include("`bundle exec rails-ai-context serve` may not start - `bundle` is a batch file, " \
                                         "which a client that starts its server without a shell does not run")
        expect(check.fix).to eq("Run `#{RailsAiContext::InstallMode.command(:install)}` to fix")
      end

      it "reads a Codex entry's command on the PATH its snapshot sets" do
        allow(RailsAiContext.configuration).to receive(:ai_tools).and_return(%i[codex])
        write(".codex/config.toml", %([mcp_servers.rails-ai-context]\ncommand = "bundle"\nargs = ["exec", "rails-ai-context", "serve"]\n\n) +
                                    %([mcp_servers.rails-ai-context.env]\nPATH = #{JSON.generate(batch_bin)}\n))

        expect(check.status).to eq(:warn)
        expect(check.message).to include("`bundle` is a batch file")
      end

      it "passes a bare command PATH finds as an .exe" do
        File.write(File.join(batch_bin, "bundle.exe"), "")
        write(".mcp.json", server(bundled))

        expect(check.status).to eq(:pass)
      end

      it "fails an entry wrapped in cmd /c on any other platform, where there is no cmd" do
        allow(RailsAiContext::McpConfigGenerator).to receive(:windows_shell?).and_return(false)
        write(".mcp.json", server(%w[cmd /c] + bundled))

        expect(check.status).to eq(:fail)
        expect(check.message).to include("`bundle exec rails-ai-context serve` cannot start - it runs through `cmd /c`, " \
                                         "Windows' shell, which is not here")
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
        expect(fresh_doctor.run[:checks].map(&:message).join)
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

    # Doctor said to run the install, the install left the file as it is and
    # said to add the entry by hand, and doctor said to run the install
    # again. Each fix here is the one the install gives for the same file.
    context "when the install would leave the config as it is" do
      def install_reason(tool)
        result = RailsAiContext::McpConfigGenerator.new(tools: [ tool ], output_dir: @root, tool_mode: :mcp, standalone: true).call
        result[:reasons].values.first.to_s
      end

      before do
        allow(RailsAiContext.configuration).to receive(:tool_mode).and_return(:mcp)
        allow(RailsAiContext::InstallMode).to receive(:standalone?).and_return(true)
      end

      # VS Code and OpenCode read comments; the install would drop them.
      it "names the entry to add by hand to a commented config that holds none of the gem's, as the install does" do
        allow(RailsAiContext.configuration).to receive(:ai_tools).and_return(%i[copilot opencode])
        write(".vscode/mcp.json", %({\n  // GitHub's server\n  "servers": { "github": { "url": "https://api.example/mcp" } }\n}\n))
        write("opencode.json", %({\n  /* the team's model */\n  "model": "x"\n}\n))

        vscode = %({"servers":{"rails-ai-context":{"command":"rails-ai-context","args":["serve"]}}})
        opencode = %({"mcp":{"rails-ai-context":{"type":"local","command":["rails-ai-context","serve"]}}})
        expect(check).to have_attributes(status: :warn, message: "2 of 2 MCP configs need attention: .vscode/mcp.json (GitHub Copilot), " \
                                                                 "opencode.json (OpenCode): holds no rails-ai-context server")
        expect(check.fix).to eq("Add #{vscode} to .vscode/mcp.json by hand: #{RailsAiContext::McpConfigGenerator::COMMENTS_PROBLEM}, " \
                                "so the install leaves it as it is; Add #{opencode} to opencode.json by hand: " \
                                "#{RailsAiContext::McpConfigGenerator::COMMENTS_PROBLEM}, so the install leaves it as it is")
        expect(install_reason(:copilot)).to end_with("Add #{vscode} to it by hand")
        expect(install_reason(:opencode)).to end_with("Add #{opencode} to it by hand")
      end

      it "names the entry to replace by hand where the commented config's entry needs rewriting" do
        allow(RailsAiContext.configuration).to receive(:ai_tools).and_return(%i[copilot])
        write("Gemfile", %(gem "rails"\n))
        write("Gemfile.lock", lockfile("rails"))
        write(".vscode/mcp.json", %({\n  // ours\n  "servers": { "rails-ai-context": { "command": "bundle", "args": ["exec", "rails-ai-context", "serve"] } }\n}\n))

        expect(check.status).to eq(:fail)
        expect(check.message).to end_with("`bundle exec rails-ai-context serve` cannot start - Gemfile.lock has no rails-ai-context")
        expect(check.fix).to start_with(%(Add {"servers":{"rails-ai-context":{"command":"rails-ai-context","args":["serve"]}}} to .vscode/mcp.json by hand))
        expect(install_reason(:copilot)).to include("holds comments")

        write(".vscode/mcp.json", %({\n  // ours\n  "servers": { "rails-ai-context": { "command": "rails-ai-context", "args": ["serve"] } }\n}\n))
        expect(app_doctor.send(:check_mcp_json).status).to eq(:pass)
      end

      # Added by hand, the entry sits in a file its client cannot read either.
      it "asks for a config that is not UTF-8 to be saved as UTF-8 before the install runs" do
        allow(RailsAiContext.configuration).to receive(:ai_tools).and_return(%i[claude])
        write(".mcp.json", %({"mcpServers": {"x": {"command": "caf\xE9"}}}\n).b)

        expect(check).to have_attributes(status: :fail, message: end_with(".mcp.json (Claude Code): it is not UTF-8, which JSON is"),
                                         fix: "Save .mcp.json as UTF-8, then run `rails-ai-context init`")
      end

      it "names the Codex table to write by hand for an entry the install does not rewrite that cannot start" do
        allow(RailsAiContext.configuration).to receive(:ai_tools).and_return(%i[codex])
        write("Gemfile", %(gem "rails"\n))
        write("Gemfile.lock", lockfile("rails"))
        write(".codex/config.toml", %([mcp_servers]\nrails-ai-context = { command = "bundle", args = ["exec", "rails-ai-context", "serve"] }\n))

        expect(check.status).to eq(:fail)
        expect(check.message).to end_with("`bundle exec rails-ai-context serve` cannot start - Gemfile.lock has no rails-ai-context")
        expect(check.fix).to eq("Write it as a [mcp_servers.rails-ai-context] table by hand, or delete it and run `rails-ai-context init`: " \
                                "it sets rails-ai-context as an inline table or with dotted keys, which the install does not rewrite")
        expect(install_reason(:codex)).to include("Write it as a [mcp_servers.rails-ai-context] table by hand")
      end

      it "names the same edit for a stale snapshot in such an entry" do
        allow(RailsAiContext.configuration).to receive(:ai_tools).and_return(%i[codex])
        write(".codex/config.toml", %([mcp_servers]\nrails-ai-context = { command = "rails-ai-context", args = ["serve"], ) +
                                    %(env = { PATH = "/nonexistent/ruby/9.9.9/bin" } }\n))

        staleness = app_doctor.send(:check_codex_env_staleness)
        expect(staleness.status).to eq(:fail)
        expect(staleness.fix).to start_with("Write it as a [mcp_servers.rails-ai-context] table by hand, or delete it and run `rails-ai-context init`")
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

    # The plugin starts the gem installed for that Ruby, never a bundle's copy.
    it "fails where the plugin serves the app and the gem is not installed outside the bundle, saying why" do
      FileUtils.mkdir_p([ File.join(@root, ".claude"), File.join(@root, "config") ])
      File.write(File.join(@root, "config", "application.rb"), "")
      File.write(File.join(@root, ".claude", "settings.json"), plugin_settings)
      empty = Dir.mktmpdir
      allow(Bundler).to receive(:original_env).and_return(ENV.to_h.merge("GEM_HOME" => empty, "GEM_PATH" => empty))

      check = app_doctor.send(:check_stdio_activation_hygiene)
      # The gem script beside that Ruby, not the first `gem` on PATH, which a version manager's shim leads.
      gem = File.join(RbConfig::CONFIG["bindir"], "gem")
      expect(check).to have_attributes(status: :fail, fix: "Run `#{RailsAiContext::CLI::AppRoot.command_line([ Gem.ruby, gem, "install", "rails-ai-context" ])}`")
      expect(check.message).to include("the rails-ai-context plugin", Gem.ruby, "Could not find 'rails-ai-context'")
      expect(check.message).not_to include(".rb:")

      allow(RailsAiContext.configuration).to receive(:tool_mode).and_return(:cli)
      expect(app_doctor.send(:check_stdio_activation_hygiene).status).to eq(:fail)
    ensure
      FileUtils.rm_rf(empty)
    end

    # serve.rb refuses a gem older than the plugin's own requirement.
    it "activates the gem at the requirement of the plugin copy that runs" do
      FileUtils.mkdir_p([ File.join(@root, ".claude"), File.join(@root, "config") ])
      File.write(File.join(@root, "config", "application.rb"), "")
      File.write(File.join(@root, ".claude", "settings.json"), plugin_settings)
      install = File.join(@root, "cache")
      FileUtils.mkdir_p(File.join(install, "scripts"))
      File.write(File.join(install, "scripts", "gem_requirement.rb"), %(module RailsAiContextPlugin\n  GEM_REQUIREMENT = ">= 99.0"\nend\n))
      File.write(plugin_registry, JSON.generate("version" => 2, "plugins" => { "rails-ai-context@rails-ai-context" => [ { "scope" => "user", "installPath" => install } ] }))

      check = app_doctor.send(:check_stdio_activation_hygiene)
      expect(check.status).to eq(:fail)
      expect(check.message).to include("(>= 99.0)")
    end

    # No plugin starts until Claude Code runs, so a CI gate on STRICT stays green, and a developer still hears of it.
    it "only warns where Claude Code never ran, for a committed plugin and the gem in the bundle alone" do
      FileUtils.mkdir_p([ File.join(@root, ".claude"), File.join(@root, "config") ])
      File.write(File.join(@root, "config", "application.rb"), "")
      File.write(File.join(@root, ".claude", "settings.json"), plugin_settings)
      write_config(%w[bundle exec rails-ai-context serve])
      missing = File.join(@root, "no-claude")
      allow(RailsAiContext::ClaudeCodeSettings).to receive_messages(user_config_dir: missing, user_claude_json: File.join(missing, ".claude.json"))
      empty = Dir.mktmpdir
      allow(Bundler).to receive(:original_env).and_return(ENV.to_h.merge("GEM_HOME" => empty, "GEM_PATH" => empty))

      check = app_doctor.send(:check_stdio_activation_hygiene)
      expect(check.status).to eq(:warn)
      expect(check.message).to start_with("once Claude Code runs here, the rails-ai-context plugin needs the gem installed for #{Gem.ruby}, which did not activate")
    ensure
      FileUtils.rm_rf(empty)
    end

    it "checks the activation when the Claude Code plugin starts the installed binary" do
      FileUtils.mkdir_p([ File.join(@root, ".claude"), File.join(@root, "config") ])
      File.write(File.join(@root, "config", "application.rb"), "")
      File.write(File.join(@root, ".claude", "settings.json"), plugin_settings)
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

    # init in the folder leaves a commented config of the folder's as it is
    # too, and names the entries to add by hand: this app's is one of them.
    it "names this app's entry as init writes it, for a commented config of the folder's that needs it rewritten" do
      allow(RailsAiContext.configuration).to receive(:ai_tools).and_return(%i[copilot])
      write("a/Gemfile", %(gem "rails"\n))
      write("a/Gemfile.lock", lockfile("rails"))
      write(".vscode/mcp.json", %({\n  // the folder's servers\n  "servers": {\n    "rails-ai-context-a": { "command": "bundle", ) +
                                %("args": ["exec", "rails-ai-context", "serve", "--app-path", "${workspaceFolder}/a"], ) +
                                %("env": { "BUNDLE_GEMFILE": "${workspaceFolder}/a/Gemfile" } }\n  }\n}\n))

      check = workspace_doctor.send(:check_mcp_json)

      servers = RailsAiContext::Install::Workspace.apps(@work, [ app_root ]).map(&:server)
      init = RailsAiContext::McpConfigGenerator.new(tools: [ :copilot ], output_dir: @work, tool_mode: :mcp, servers: servers).call
      entry = init[:reasons].values.first[/Add (\{.*\}) to it by hand\z/, 1]
      expect(entry).to include(%("rails-ai-context-a":{"command":"rails-ai-context"))
      expect(check.fix).to eq("Add #{entry} to ../.vscode/mcp.json by hand: #{RailsAiContext::McpConfigGenerator::COMMENTS_PROBLEM}, " \
                              "so the install leaves it as it is")
    end

    context "with the Claude Code plugin on" do
      before do
        allow(RailsAiContext.configuration).to receive(:ai_tools).and_return(%i[claude])
        write("a/config/application.rb", "")
        write("a/.claude/settings.json", plugin_settings)
        write(".claude/settings.json", plugin_settings)
        write(".mcp.json", JSON.generate("mcpServers" => {
          "rails-ai-context-a" => { "command" => "rails-ai-context", "args" => %w[serve --app-path a] }
        }))
      end

      it "counts the folder's entry as a second server when the folder holds this app alone" do
        expect(workspace_doctor.send(:check_mcp_json).status).to eq(:warn)
      end

      # A session in the folder starts its .mcp.json, but not the plugin the app alone enables.
      it "passes the folder's entry when only the app's own settings turn the plugin on" do
        FileUtils.rm_f(File.join(@work, ".claude", "settings.json"))

        expect(workspace_doctor.send(:check_mcp_json).status).to eq(:pass)
      end

      it "counts an entry naming no app, which serves the one app the folder holds" do
        write(".mcp.json", JSON.generate("mcpServers" => { "rails-ai-context" => { "command" => "rails-ai-context", "args" => [ "serve" ] } }))

        expect(workspace_doctor.send(:check_mcp_json).message).to include("`rails-ai-context` in ../.mcp.json runs the server")
      end

      # A local server and the plugin's local switch both live with the folder a session started in.
      it "says where to run the commands that remove a local server added in the folder" do
        FileUtils.rm_f(File.join(@work, ".mcp.json"))
        File.write(File.join(ENV.fetch("CLAUDE_CONFIG_DIR"), ".claude.json"), JSON.generate("projects" => {
          @work => { "mcpServers" => { "rac" => { "command" => "rails-ai-context", "args" => [ "serve" ] } } }
        }))

        expect(workspace_doctor.send(:check_mcp_json).fix).to eq(
          "Run `claude mcp remove rac -s local` in .., or run `claude plugin disable rails-ai-context@rails-ai-context --scope local` in .."
        )
      ensure
        FileUtils.rm_f(File.join(ENV.fetch("CLAUDE_CONFIG_DIR"), ".claude.json"))
      end

      it "names the folder to run the enable in, from where doctor ran" do
        FileUtils.rm_f(File.join(@work, ".mcp.json"))
        write("a/.claude/settings.json", plugin_settings(false))
        doctor = described_class.new(RailsAiContext::StaticApp.new(app_root), from: @work)

        expect(doctor.send(:check_mcp_json).fix).to end_with("`claude plugin enable rails-ai-context@rails-ai-context --scope local` in a")
      end

      # Enabled there already, so `enable` would change nothing.
      it "points at /mcp where it turned the plugin off for the app's folder" do
        FileUtils.rm_f(File.join(@work, ".mcp.json"))
        File.write(File.join(ENV.fetch("CLAUDE_CONFIG_DIR"), ".claude.json"), JSON.generate("projects" => {
          app_root => { "disabledMcpServers" => [ "plugin:rails-ai-context:rails-ai-context" ] }
        }))

        expect(workspace_doctor.send(:check_mcp_json).fix).to eq(
          "Start Claude Code there, or turn the plugin's server back on with /mcp in a session started here"
        )
      ensure
        FileUtils.rm_f(File.join(ENV.fetch("CLAUDE_CONFIG_DIR"), ".claude.json"))
      end

      it "asks for both steps where the app turned the plugin off and /mcp turned its server off" do
        FileUtils.rm_f(File.join(@work, ".mcp.json"))
        write("a/.claude/settings.json", plugin_settings(false))
        File.write(File.join(ENV.fetch("CLAUDE_CONFIG_DIR"), ".claude.json"), JSON.generate("projects" => {
          app_root => { "disabledMcpServers" => [ "plugin:rails-ai-context:rails-ai-context" ] }
        }))

        expect(workspace_doctor.send(:check_mcp_json).fix).to eq(
          "Start Claude Code there, or run `claude plugin enable rails-ai-context@rails-ai-context --scope local`, " \
          "then turn the plugin's server back on with /mcp in a session started here"
        )
      ensure
        FileUtils.rm_f(File.join(ENV.fetch("CLAUDE_CONFIG_DIR"), ".claude.json"))
      end

      # Each session's plugin may come from another marketplace.
      it "names each session's own plugin id in the disable hint" do
        FileUtils.rm_f(File.join(@work, ".mcp.json"))
        File.write(plugin_registry, JSON.generate("version" => 2, "plugins" => {
          "rails-ai-context@one" => [ { "scope" => "user" } ], "rails-ai-context@two" => [ { "scope" => "user" } ]
        }))
        write(".claude/settings.json", JSON.generate("enabledPlugins" => { "rails-ai-context@one" => true }))
        write("a/.claude/settings.json", JSON.generate("enabledPlugins" => { "rails-ai-context@two" => true }))
        write("a/app/.claude/settings.json", JSON.generate("enabledPlugins" => { "rails-ai-context@two" => true }))
        File.write(File.join(ENV.fetch("CLAUDE_CONFIG_DIR"), ".claude.json"),
                   JSON.generate("mcpServers" => { "rac" => { "command" => "rails-ai-context", "args" => [ "serve" ] } },
                                 "projects" => { File.join(app_root, "app") => {} }))

        expect(workspace_doctor.send(:check_mcp_json).fix).to eq(
          "Run `claude mcp remove rac -s user`, or run `claude plugin disable rails-ai-context@two --scope local` here and in app " \
          "and run `claude plugin disable rails-ai-context@one --scope local` in .."
        )
      ensure
        FileUtils.rm_f(File.join(ENV.fetch("CLAUDE_CONFIG_DIR"), ".claude.json"))
      end

      # `--scope local` writes the git root's settings.local.json, which every session in that repository reads.
      it "names one disable for the sessions of one git repository" do
        skip "Claude Code keeps each folder's local settings apart on Windows" if Gem.win_platform?

        FileUtils.rm_f(File.join(@work, ".mcp.json"))
        FileUtils.mkdir_p(File.join(@work, ".git"))
        File.write(File.join(ENV.fetch("CLAUDE_CONFIG_DIR"), ".claude.json"),
                   JSON.generate("mcpServers" => { "rac" => { "command" => "rails-ai-context", "args" => [ "serve" ] } }))

        expect(workspace_doctor.send(:check_mcp_json).fix).to eq(
          "Run `claude mcp remove rac -s user`, or run `claude plugin disable rails-ai-context@rails-ai-context --scope local`"
        )
      ensure
        FileUtils.rm_f(File.join(ENV.fetch("CLAUDE_CONFIG_DIR"), ".claude.json"))
      end

      # A project install counts in its own project alone, so enabling it here changes nothing.
      it "names the install a folder's sessions need where the plugin is installed for another project" do
        FileUtils.rm_f(File.join(@work, ".mcp.json"))
        FileUtils.mkdir_p(File.join(app_root, ".git"))
        File.write(plugin_registry, JSON.generate("version" => 2, "plugins" => {
          "rails-ai-context@rails-ai-context" => [ { "scope" => "project", "projectPath" => @work } ]
        }))

        expect(workspace_doctor.send(:check_mcp_json).fix).to eq(
          "Start Claude Code there, or run `claude plugin install rails-ai-context --marketplace crisnahine/rails-ai-context --scope local`"
        )
      end

      # Typed where the plugin runs, the folder is here.
      it "says here for the folder doctor runs in" do
        FileUtils.rm_f(File.join(@work, ".mcp.json"))
        write("a/.claude/settings.json", plugin_settings(false))
        doctor = described_class.new(RailsAiContext::StaticApp.new(app_root), from: @work)

        expect(doctor.send(:check_mcp_json)).to have_attributes(
          message: a_string_including("only in sessions started here, not in ones started in a"),
          fix: a_string_starting_with("Start Claude Code here")
        )
      end

      it "names the session whose /mcp turned the plugin's server off, where that is not the app's" do
        FileUtils.rm_f(File.join(@work, ".mcp.json"))
        write("a/.claude/settings.json", plugin_settings(false))
        File.write(File.join(ENV.fetch("CLAUDE_CONFIG_DIR"), ".claude.json"), JSON.generate("projects" => {
          @work => { "disabledMcpServers" => [ "plugin:rails-ai-context:rails-ai-context" ] }
        }))

        expect(workspace_doctor.send(:check_mcp_json).fix).to eq(
          "Turn the plugin's server back on with /mcp in a session started in .., " \
          "or run `claude plugin enable rails-ai-context@rails-ai-context --scope local`"
        )
      ensure
        FileUtils.rm_f(File.join(ENV.fetch("CLAUDE_CONFIG_DIR"), ".claude.json"))
      end

      # A session at the git root never loads the app's own .mcp.json, so its /mcp has no such server to turn off.
      it "sends the user to turn a .mcp.json server off in a session that loads it" do
        FileUtils.rm_f(File.join(@work, ".mcp.json"))
        FileUtils.rm_f(File.join(@work, ".claude", "settings.json"))
        FileUtils.rm_f(File.join(app_root, ".claude", "settings.json"))
        FileUtils.mkdir_p(File.join(@work, ".git"))
        write("a/.mcp.json", JSON.generate("mcpServers" => { "rails-ai-context" => { "command" => "rails-ai-context", "args" => [ "serve" ] } }))
        File.write(File.join(ENV.fetch("CLAUDE_CONFIG_DIR"), "settings.json"), plugin_settings)

        expect(workspace_doctor.send(:check_mcp_json).fix).to start_with("Turn `rails-ai-context` off with /mcp in a session started here")
      ensure
        FileUtils.rm_f(File.join(ENV.fetch("CLAUDE_CONFIG_DIR"), "settings.json"))
      end

      # Starting Claude Code there as told would list every tool twice.
      it "names the second servers of the sessions it sends the user to" do
        FileUtils.rm_f(File.join(@work, ".mcp.json"))
        write("a/.claude/settings.json", plugin_settings(false))
        File.write(File.join(ENV.fetch("CLAUDE_CONFIG_DIR"), ".claude.json"), JSON.generate("projects" => {
          @work => { "mcpServers" => { "rac" => { "command" => "rails-ai-context", "args" => [ "serve" ] } } }
        }))

        check = workspace_doctor.send(:check_mcp_json)
        expect(check.message).to include("only in sessions started in ..", "the local scope server `rac` runs the server beside")
        expect(check.fix).to start_with("Run `claude mcp remove rac -s local` in ..")
      ensure
        FileUtils.rm_f(File.join(ENV.fetch("CLAUDE_CONFIG_DIR"), ".claude.json"))
      end

      # A session started in the app runs no server, though one in the folder above would.
      it "warns where the plugin runs only for sessions started in another folder" do
        FileUtils.rm_f(File.join(@work, ".mcp.json"))
        write("a/.claude/settings.json", plugin_settings(false))

        expect(workspace_doctor.send(:check_mcp_json)).to have_attributes(
          status: :warn,
          message: "1 of 1 MCP config needs attention: .mcp.json (Claude Code): the rails-ai-context plugin serves this app only in " \
                   "sessions started in .., not in ones started here",
          fix: "Start Claude Code there, or run `claude plugin enable rails-ai-context@rails-ai-context --scope local`"
        )
      end

      # Enabled and installed for the app's folder, it is the policy there that keeps it off.
      it "names the deny that keeps the plugin off in the app's folder, where it runs from the one above" do
        FileUtils.rm_f(File.join(@work, ".mcp.json"))
        write("a/.claude/settings.local.json", JSON.generate("deniedMcpServers" => [ { "serverName" => "plugin:rails-ai-context:rails-ai-context" } ]))

        expect(workspace_doctor.send(:check_mcp_json).fix).to eq(
          "Start Claude Code there, or remove {\"serverName\":\"plugin:rails-ai-context:rails-ai-context\"} from deniedMcpServers in .claude/settings.local.json"
        )
      end

      it "names no alternative where nothing would turn the plugin on for the app's folder" do
        FileUtils.rm_f(File.join(@work, ".mcp.json"))
        write("a/.claude/settings.json", plugin_settings(false))
        allow(workspace_doctor).to receive(:claude_plugin_switch_on).and_return("")

        expect(workspace_doctor.send(:check_mcp_json).fix).to eq("Start Claude Code there")
      end

      # Doctor typed above the app stands for a session there, which the note about folders inside the app does not reach.
      it "adds no note for a folder above the app where the plugin passes" do
        FileUtils.rm_f([ File.join(@work, ".mcp.json"), File.join(@work, ".claude", "settings.json") ])
        doctor = described_class.new(RailsAiContext::StaticApp.new(app_root), from: @work)

        expect(doctor.send(:check_mcp_json)).to have_attributes(status: :pass, message: "1 of 1 MCP config valid: the rails-ai-context plugin (Claude Code)")
      end

      # A session started in the folder never reads the app's own .mcp.json.
      it "judges a session started in the folder doctor was typed in, above the app, by the configs it reads" do
        FileUtils.rm_f(File.join(@work, ".mcp.json"))
        write("a/.mcp.json", JSON.generate("mcpServers" => { "rails-ai-context" => { "command" => "rails-ai-context", "args" => [ "serve" ] } }))
        FileUtils.rm_rf(File.dirname(plugin_registry))
        doctor = described_class.new(RailsAiContext::StaticApp.new(app_root), from: @work)
        allow(doctor).to receive(:client_path).and_return(bin_dir_with("bundle", "rails-ai-context"))

        expect(doctor.send(:check_mcp_json).message).to end_with("the rails-ai-context plugin (Claude Code): enabled for this app but not installed on this machine")
        expect(workspace_doctor.send(:check_mcp_json).status).to eq(:pass)
      end

      # The folder's own entry for the app serves that session, so the plugin missing there leaves it a server.
      it "passes a session started above the app that the folder's own entry serves" do
        FileUtils.rm_rf(File.dirname(plugin_registry))
        doctor = described_class.new(RailsAiContext::StaticApp.new(app_root), from: @work)
        allow(doctor).to receive(:client_path).and_return(bin_dir_with("bundle", "rails-ai-context"))

        expect(doctor.send(:check_mcp_json)).to have_attributes(status: :pass, message: "1 of 1 MCP config valid")
      end

      # In a repository whose root is the home folder, Claude Code keeps each session folder's local settings apart.
      it "names a disable for each session folder whose local settings Claude Code keeps apart" do
        skip "Claude Code keeps each folder's local settings apart on Windows" if Gem.win_platform?

        FileUtils.rm_f(File.join(@work, ".mcp.json"))
        FileUtils.mkdir_p(File.join(@work, ".git"))
        write("a/app/.claude/settings.json", plugin_settings)
        File.write(File.join(ENV.fetch("CLAUDE_CONFIG_DIR"), ".claude.json"),
                   JSON.generate("mcpServers" => { "rac" => { "command" => "rails-ai-context", "args" => [ "serve" ] } },
                                 "projects" => { File.join(app_root, "app") => {} }))
        disable = "Run `claude mcp remove rac -s user`, or run `claude plugin disable rails-ai-context@rails-ai-context --scope local`"
        expect(workspace_doctor.send(:check_mcp_json).fix).to eq(disable)

        allow(Dir).to receive(:home).and_return(@work)
        expect(described_class.new(RailsAiContext::StaticApp.new(app_root)).send(:check_mcp_json).fix).to eq("#{disable} here and in app")
      ensure
        FileUtils.rm_f(File.join(ENV.fetch("CLAUDE_CONFIG_DIR"), ".claude.json"))
      end

      # Started in a folder of apps, the plugin serves none, so the folder's entry is the only server.
      it "passes the folder's entry when the folder holds more apps" do
        write("b/config/application.rb", "")

        expect(workspace_doctor.send(:check_mcp_json).status).to eq(:pass)
      end
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

    # An engine or a test/dummy app keeps the same files under the same names, and the tools refuse them as they do the app's.
    it "reads an engine's and a test/dummy app's files as it reads the app's" do
      files = {
        ".gitignore" => "/.env*\n/config/*.key\n",
        "engines/admin/config/credentials.yml.enc" => "x\n",
        "engines/admin/config/database.yml" => "test:\n  adapter: sqlite3\n  database: db/test.sqlite3\n",
        "test/dummy/config/storage.yml" => "test:\n  service: Disk\n  root: tmp/storage\n"
      }
      app_with(files) { |dir| expect(gitignore_check_for(dir).status).to eq(:pass) }
      app_with(files.merge("engines/admin/config/master.key" => "x\n")) do |dir|
        check = gitignore_check_for(dir)

        expect(check.status).to eq(:fail)
        expect(check.message).to include("engines/admin/config/master.key not in .gitignore")
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

    # A .gitignore pattern is read from the .gitignore it is in, and git runs
    # in a repository: typed from the folder above the app, a fix spelled from
    # there ignored nothing, and `git rm --cached` found no repository.
    context "typed in the folder above the app" do
      def check_from_above(dir)
        described_class.new(RailsAiContext::StaticApp.new(File.join(dir, "blog")), from: dir).send(:check_security_gitignore)
      end

      it "names the app's own .gitignore, and the pattern as it reads it" do
        Dir.mktmpdir do |dir|
          FileUtils.mkdir_p(File.join(dir, "blog"))
          File.write(File.join(dir, "blog", ".env.local"), "A=1\n")
          File.write(File.join(dir, "blog", ".gitignore"), "log/\n")

          expect(check_from_above(dir)).to have_attributes(message: "blog/.env.local not in .gitignore",
                                                           fix: "Add to blog/.gitignore: `.env.local`")
        end
      end

      it "runs git in the app's repository" do
        Dir.mktmpdir do |dir|
          FileUtils.mkdir_p(File.join(dir, "blog", "config"))
          File.write(File.join(dir, "blog", "config", "master.key"), "x\n")
          File.write(File.join(dir, "blog", ".gitignore"), "/config/*.key\n")
          system("git", "-C", File.join(dir, "blog"), "init", "-q", out: File::NULL, err: File::NULL) or raise "git init failed"
          system("git", "-C", File.join(dir, "blog"), "add", "-f", "config/master.key", out: File::NULL, err: File::NULL) or raise "git add failed"

          expect(check_from_above(dir)).to have_attributes(
            message: "blog/config/master.key is committed",
            fix: "Run `git -C blog rm --cached config/master.key` and rotate it: the history still holds it"
          )
        end
      end
    end

    # Typed in blog/app/models, `git rm --cached .env` stopped at "pathspec
    # '.env' did not match any files", and a .gitignore made there ignores
    # nothing at the root. The report still names the files from the root.
    context "typed in a folder inside the app" do
      it "runs git in the app's root and names its .gitignore from there" do
        Dir.mktmpdir do |dir|
          blog = File.join(File.realpath(dir), "blog")
          FileUtils.mkdir_p(File.join(blog, "app/models"))
          File.write(File.join(blog, ".env"), "A=1\n")
          File.write(File.join(blog, ".gitignore"), "log/\n")
          system("git", "-C", blog, "init", "-q", out: File::NULL, err: File::NULL) or raise "git init failed"
          system("git", "-C", blog, "add", ".env", out: File::NULL, err: File::NULL) or raise "git add failed"

          check = described_class.new(RailsAiContext::StaticApp.new(blog), from: File.join(blog, "app/models")).send(:check_security_gitignore)
          expect(check).to have_attributes(
            message: ".env is committed",
            fix: "Run `git -C ../.. rm --cached .env`, add `.env` to ../../.gitignore, and rotate it: the history still holds it"
          )
        end
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

    # The plugin brings the rules, but files the app already has are still read, and go stale.
    it "skips only the missing files where the plugin is the choice and no AI tools were chosen" do
      allow(RailsAiContext.configuration).to receive(:ai_tools).and_return(nil)
      allow(doctor).to receive(:claude_code).and_return(instance_double(RailsAiContext::ClaudeCodeSettings, plugin_chosen?: true))
      expect(check).to be_nil

      generate
      claude = File.join(@out, "CLAUDE.md")
      File.write(claude, File.read(claude).sub("rails-ai-context v#{RailsAiContext::VERSION}", "rails-ai-context v5.31.0"))
      expect(doctor.send(:check_context_freshness).status).to eq(:warn)
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

    # `bundle install` runs where the Gemfile is: typed in the folder above
    # an app it found none there.
    context "typed in the folder above the app" do
      def gems_from(app, typed)
        described_class.new(RailsAiContext::StaticApp.new(File.join(@top, app)), from: typed).send(:check_gems)
      end

      it "runs bundle install in the app that has its own Gemfile" do
        write("web/Gemfile", %(gem "rails"\n))

        expect(gems_from("web", @top)).to have_attributes(message: "web/Gemfile.lock not found", fix: "Run `cd web && bundle install`")
      end

      it "runs it where a monorepo's shared Gemfile is" do
        FileUtils.mkdir_p(File.join(@top, ".git"))
        write("Gemfile", %(gem "rails"\n))
        write("web/config/boot.rb", %(ENV["BUNDLE_GEMFILE"] ||= File.expand_path("../../Gemfile", __dir__)\n))

        expect(gems_from("web", @top)).to have_attributes(message: "Gemfile.lock not found", fix: "Run `bundle install`")
        expect(gems_from("web", File.join(@top, "web"))).to have_attributes(message: "../Gemfile.lock not found", fix: "Run `cd .. && bundle install`")
      end
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

      # The report names the engine's files from the dummy app's root; the
      # engine a command runs in is further up from a folder inside it.
      it "names the engine as a command reaches it from a folder inside the dummy app" do
        doctor = described_class.new(RailsAiContext::StaticApp.new(dummy), from: File.join(dummy, "app/models"))
        allow(doctor).to receive(:database_states).and_return([ { name: "primary", config: nil, pending: [ { version: "1", name: "X" } ] } ])

        expect(doctor.send(:check_pending_migrations).fix).to eq("Run `RAILS_ENV=#{Rails.env} bin/rails db:migrate` in the engine at ../../../..")
        expect(doctor.send(:check_gems).message).to eq("../../Gemfile.lock found")
      end

      it "names the engine's files from its root when typed in a folder of the engine's own" do
        doctor = described_class.new(RailsAiContext::StaticApp.new(dummy), from: File.join(engine, "app/models"))
        allow(doctor).to receive(:database_states).and_return([ { name: "primary", config: nil, pending: [ { version: "1", name: "X" } ] } ])

        expect(doctor.send(:check_pending_migrations).fix).to eq("Run `RAILS_ENV=#{Rails.env} bin/rails db:migrate` at the engine's root")
        expect(doctor.send(:check_gems).message).to eq("Gemfile.lock found")
        expect(doctor.send(:check_models).message).to eq("2 model files found (1 in the engine)")
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

        # The engine's bundle and suite are where it was typed; the dummy
        # app's own commands run in test/dummy.
        it "runs each command where it belongs" do
          File.delete(File.join(@top, "Gemfile.lock"), File.join(@top, "test/test_helper.rb"), File.join(@top, "test/models/article_test.rb"),
                      File.join(@top, "test/dummy/db/schema.rb"))

          expect(doctor.send(:check_gems)).to have_attributes(message: "Gemfile.lock not found", fix: "Run `bundle install`")
          expect(doctor.send(:check_tests).fix).to eq("Run `rails generate rspec:install` or use default Minitest")
          expect(doctor.send(:check_schema).fix).to eq("Run `cd test/dummy && rails db:schema:dump`")
          # From the dummy app, the engine's suite is two folders up.
          expect(described_class.new(RailsAiContext::StaticApp.new(dummy)).send(:check_tests).fix)
            .to eq("Run `cd ../.. && rails generate rspec:install` or use default Minitest")
        end

        it "names a SQLite database the dummy app reads from its root under test/dummy" do
          config = ActiveRecord::DatabaseConfigurations::HashConfig.new(Rails.env, "primary", { adapter: "sqlite3", database: "storage/development.sqlite3" })
          allow(doctor).to receive(:database_states).and_return([ { name: "primary", config: config, error: RailsAiContext::AppDatabases::Missing.new("no") } ])

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
            fix: "Run `git -C test/dummy rm --cached config/master.key`, add `config/master.key` to test/dummy/.gitignore, " \
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

          # Typed at the engine's root, the dummy app's install runs in the dummy app.
          expect(doctor.send(:check_mcp_json).fix).to eq("Run `cd test/dummy && #{RailsAiContext::InstallMode.command(:install)}` to fix")
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
      configurations = ActiveRecord::DatabaseConfigurations.new(
        Rails.env => { "primary" => ActiveRecord::Base.connection_db_config.configuration_hash,
                       "analytics" => { adapter: "sqlite3", database: File.join(@root, "db/analytics.sqlite3"),
                                        migrations_paths: "db/analytics_migrate" } }
      )
      allow(ActiveRecord::Base).to receive(:configurations).and_return(configurations)
      allow(Rails).to receive(:root).and_return(Pathname.new(@root))
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

    # Its database.yml is read as text, and the booted app's connection is another app's.
    it "skips the check for an app that is not the booted one, and connects to none of its databases" do
      write("config/database.yml", "#{Rails.env}:\n  primary:\n    adapter: sqlite3\n    database: db/app.sqlite3\n")
      write("db/migrate/20240101000000_create_notes.rb", "class CreateNotes < ActiveRecord::Migration[7.1]\nend\n")

      expect(app_doctor.run[:checks].map(&:name)).not_to include("Pending migrations", "Database")
      expect(File.exist?(File.join(@root, "db/app.sqlite3"))).to be(false)
    end

    # A Windows path is absolute from its drive letter on, and read as
    # relative it was named from where doctor was typed.
    it "names a SQLite file given by a Windows path as database.yml gives it" do
      stub_const("File::ALT_SEPARATOR", "\\")
      allow(app_doctor).to receive(:typed_path) { |path| "typed from here: #{path}" }

      expect(app_doctor.send(:database_named, database_named("analytics", "D:/shop/db/analytics.sqlite3")))
        .to eq("D:/shop/db/analytics.sqlite3")
      expect(app_doctor.send(:database_named, database_named("analytics", "db/analytics.sqlite3")))
        .to eq("typed from here: #{File.join(@root, 'db/analytics.sqlite3')}")
    end

    def unreachable(error)
      allow(app_doctor).to receive(:database_states).and_return([
        { name: "primary", config: database_named("primary", "shop_development"), error: error }
      ])
      app_doctor.send(:check_pending_migrations)
    end

    # The pending row used to vanish with no database, so --strict passed.
    it "fails, naming a database that does not exist and the command that makes it" do
      check = unreachable(RailsAiContext::AppDatabases::Missing.new("Database not found: shop_development"))

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

    # Typed in the folder above the app, `bin/rails` there was no file, and
    # config/database.yml none of the app's.
    it "runs the task in the app, and names its settings from where it was typed" do
      above = described_class.new(RailsAiContext::StaticApp.new(@root), from: File.dirname(@root))
      allow(above).to receive(:database_states).and_return([
        { name: "primary", config: database_named("primary", "shop_development"), error: RailsAiContext::AppDatabases::Missing.new("no") },
        { name: "queue", config: database_named("queue", "shop_queue"), error: ActiveRecord::ConnectionNotEstablished.new("refused") }
      ])
      app_dir = File.basename(@root)

      expect(above.send(:check_pending_migrations).fix).to eq(
        "Run `cd #{app_dir} && RAILS_ENV=#{Rails.env} bin/rails db:prepare`; " \
        "Start the database server, or fix its settings in #{app_dir}/config/database.yml"
      )
    end

    # A test environment often keeps a secondary in memory, which only the app's own process holds.
    def with_database_here(name, settings)
      other = ActiveRecord::DatabaseConfigurations::HashConfig.new(Rails.env, name, settings)
      list = RailsAiContext::AppDatabases.build(
        environments: { Rails.env => { "primary" => ActiveRecord::Base.connection_db_config, name => other } },
        current: Rails.env, root: Rails.root.to_s, dumps: []
      )
      allow(RailsAiContext::AppDatabases).to receive(:for).and_return(list)
    end

    it "leaves a database that lives in memory out of the databases it reads" do
      with_database_here("cache", { adapter: "sqlite3", database: ":memory:" })

      checks = doctor.run[:checks]

      expect(checks.find { |check| check.name == "Pending migrations" }).to have_attributes(status: :pass)
      expect(checks.map(&:name)).not_to include("Database")
    end

    it "says which gem to add for a database whose adapter is not in the bundle" do
      with_database_here("warehouse", { adapter: "sqlserver", database: "warehouse" })

      expect(doctor.run[:checks].find { |check| check.name == "Database" }).to have_attributes(
        status: :fail,
        message: "the #{Rails.env} database warehouse (warehouse) cannot be reached: its sqlserver adapter did not load",
        fix: "Add the gem that provides the sqlserver adapter to the Gemfile and run `bundle install`"
      )
    end
  end
  describe "an app folder whose name has glob characters" do
    around do |example|
      Dir.mktmpdir do |base|
        @root = File.join(base, "my[app]")
        FileUtils.mkdir_p(File.join(@root, "app/views/posts"))
        FileUtils.mkdir_p(File.join(@root, "app/models"))
        FileUtils.mkdir_p(File.join(@root, "config/initializers"))
        example.run
      end
    end

    let(:doctor) { described_class.new(RailsAiContext::StaticApp.new(@root)) }

    it "counts its views" do
      File.write(File.join(@root, "app/views/posts/index.html.erb"), "<h1>Posts</h1>\n")

      expect(doctor.send(:check_views).message).to eq("1 file under app/views")
    end

    it "names the folder changed since a context file was written, and not our initializer's" do
      written = File.join(@root, "CLAUDE.md")
      File.write(written, "# context\n")
      File.utime(Time.now - 60, Time.now - 60, written)
      File.write(File.join(@root, "app/models/post.rb"), "class Post\nend\n")
      File.write(File.join(@root, "config/initializers/rails_ai_context.rb"), "\n")

      expect(doctor.send(:staleness_reason, @root, [ "CLAUDE.md" ])).to eq("app/models changed since it was written")
    end
  end
end
