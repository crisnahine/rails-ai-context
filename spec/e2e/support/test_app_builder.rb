# frozen_string_literal: true

module E2E
  # Builds a fresh Rails application for e2e testing. Supports the three
  # install paths documented in CLAUDE.md #36:
  #
  #   :in_gemfile  — add gem line to Gemfile, bundle, run generator
  #   :standalone  — build gem, install to isolated GEM_HOME, run `rails-ai-context init`
  #   :zero_config — same GEM_HOME setup, but no init/generator — just serve with defaults
  class TestAppBuilder
    BASE_RAILS_NEW_FLAGS = %w[
      --skip-bundle --skip-git --skip-spring --skip-listen
      --skip-javascript --skip-test --skip-system-test --skip-bootsnap
      --skip-dev-gems --skip-rubocop --skip-ci --skip-kamal --skip-solid
      --skip-thruster --skip-docker
    ].freeze

    attr_reader :app_path, :install_path, :gem_home, :database

    def initialize(parent_dir:, name:, install_path:, database: :sqlite3)
      @app_path     = File.join(parent_dir, name)
      @install_path = install_path
      @gem_home     = File.join(parent_dir, "gemhome-#{name}")
      @database     = database
    end

    def rails_new_flags
      BASE_RAILS_NEW_FLAGS + [ "--database=#{database}" ]
    end

    # Build the app + install the gem per the chosen path.
    # Raises with captured output on any step failure.
    #
    # Order matters: Gemfile → bundle → scaffold, because bin/rails boots
    # through Bundler and fails if Gemfile.lock is missing or stale.
    def build!
      run_rails_new!

      case install_path
      when :in_gemfile
        add_gem_to_gemfile!
        bundle_install!
        scaffold_sample_model!
        run_install_generator!
      when :standalone
        # Build + install the gem into an isolated GEM_HOME first, so the
        # `rails-ai-context` binary is available. Then bundle the bare app
        # (without the gem in the Gemfile), scaffold, and run `init`.
        build_and_install_gem!
        bundle_install!
        scaffold_sample_model!
        run_cli_init!
      when :zero_config
        build_and_install_gem!
        bundle_install!
        scaffold_sample_model!
        # NO init / NO generator — just the isolated gem + bare app.
      else
        raise ArgumentError, "unknown install_path: #{install_path}"
      end

      self
    end

    # Environment for subprocess calls that need Bundler (bundle install,
    # bin/rails, bin/rails generate). Points Bundler at the test app's
    # Gemfile while clearing the outer project's Bundler context. Does NOT
    # override GEM_HOME — bundler resolves gems from the system gem set,
    # which has rails/sqlite3/etc. pre-installed.
    #
    # CLI calls (version/doctor/tool/serve) use `cli_env` instead, which
    # extends this with the isolated GEM_PATH + PATH for standalone paths.
    def env
      base = {
        "RAILS_ENV" => "test",
        "DISABLE_SPRING" => "true",
        "BUNDLE_GEMFILE" => File.join(app_path, "Gemfile"),
        "BUNDLE_BIN_PATH" => nil,
        "BUNDLER_SETUP" => nil,
        "RUBYOPT" => nil,
        "RUBYLIB" => nil
      }
      return base unless isolated_gem_home?
      # For standalone + zero_config: also make the isolated CLI binary
      # resolvable. PATH prepend puts gem_home/bin ahead of system bin;
      # GEM_PATH append lets RubyGems find the installed gem at run time.
      base.merge(
        "PATH"     => "#{File.join(gem_home, 'bin')}:#{ENV['PATH']}",
        "GEM_PATH" => "#{gem_home}:#{ENV['GEM_PATH']}"
      )
    end

    # Does the gem need a dedicated GEM_HOME (not from Bundler)?
    def isolated_gem_home?
      install_path == :standalone || install_path == :zero_config
    end

    private

    def run_rails_new!
      FileUtils.mkdir_p(File.dirname(app_path))
      cmd = [ "rails", "new", app_path, *rails_new_flags ]
      stdout, stderr, status = Open3.capture3(*cmd)
      unless status.success?
        raise "rails new failed:\n  STDOUT:\n#{stdout}\n  STDERR:\n#{stderr}"
      end
      # Postgres `rails new` writes a database.yml that points at unix-socket
      # localhost:5432 and a default db name of `<app>_development`. CI's
      # postgres service exposes credentials via env vars; rewrite the
      # database.yml to honor PGHOST/PGUSER/PGPASSWORD when provided.
      configure_postgres_yml! if database == :postgresql
    end

    def configure_postgres_yml!
      yml_path = File.join(app_path, "config", "database.yml")
      return unless File.exist?(yml_path)
      File.write(yml_path, <<~YAML)
        default: &default
          adapter: postgresql
          encoding: unicode
          host: <%= ENV.fetch("PGHOST") { "localhost" } %>
          port: <%= ENV.fetch("PGPORT") { 5432 } %>
          username: <%= ENV.fetch("PGUSER") { "postgres" } %>
          password: <%= ENV.fetch("PGPASSWORD") { "" } %>
          pool: 5

        development:
          <<: *default
          database: rails_ai_context_e2e_dev_<%= ENV.fetch("E2E_DB_SUFFIX") { "0" } %>

        test:
          <<: *default
          database: rails_ai_context_e2e_test_<%= ENV.fetch("E2E_DB_SUFFIX") { "0" } %>
      YAML
    end

    # Generate one model + one controller so schema/model/routes tools
    # actually have content to introspect.
    def scaffold_sample_model!
      in_app("bin/rails", "generate", "scaffold", "Post", "title:string", "body:text", "published:boolean")
      in_app("bin/rails", "db:migrate")
    end

    def add_gem_to_gemfile!
      gemfile = File.join(app_path, "Gemfile")
      File.open(gemfile, "a") do |f|
        f.puts
        f.puts %(gem "rails-ai-context", path: "#{GEM_ROOT}")
      end
    end

    def bundle_install!
      in_app("bundle", "install", "--quiet")
    end

    def run_install_generator!
      in_app("bin/rails", "generate", "rails_ai_context:install", "--quiet",
             stdin_input: generator_stdin_input)
    end

    # Run `rails-ai-context init` from inside the app — pre-loads the gem
    # without needing a Gemfile entry (CLAUDE.md #33).
    def run_cli_init!
      cli_bin = File.join(gem_home, "bin", "rails-ai-context")
      in_app(cli_bin, "init", stdin_input: generator_stdin_input)
    end

    # The install generator asks three interactive questions via Thor's
    # `ask(...)`: (1) which AI tools to install, (2) tool_mode (MCP vs CLI),
    # (3) pre-commit hook. Feed the answers that maximize coverage:
    #   "a"  → all 5 AI clients get config files
    #   "1"  → MCP + CLI fallback mode (also generates the config files)
    #   "n"  → no pre-commit hook (hook is orthogonal to the e2e surface)
    def generator_stdin_input
      "a\n1\nn\n"
    end

    # Build the .gem artefact and install it into an isolated GEM_HOME
    # so standalone / zero_config paths never touch the system gem set.
    #
    # Must run with a *clean* env — the outer RSpec process runs under
    # Bundler, so Bundler env vars (BUNDLE_GEMFILE, BUNDLER_SETUP, RUBYOPT,
    # RUBYLIB) leak into subprocesses and cause `gem install` to resolve
    # against the gem-under-test's Gemfile instead of the isolated GEM_HOME
    # (producing a `Bundler::GemNotFound` on every dev-dependency).
    def build_and_install_gem!
      FileUtils.mkdir_p(gem_home)

      build_out, status = Open3.capture2e(unbundled_env, "gem", "build", "rails-ai-context.gemspec", chdir: GEM_ROOT)
      raise "gem build failed:\n#{build_out}" unless status.success?

      gemfile_name = build_out[/File:\s*(\S+)/, 1] || Dir.glob(File.join(GEM_ROOT, "rails-ai-context-*.gem")).max_by { |f| File.mtime(f) }
      gem_path = File.absolute_path(gemfile_name, GEM_ROOT)
      raise "could not find built .gem artefact (looked for #{gem_path})" unless File.exist?(gem_path)

      install_env = unbundled_env.merge(
        "GEM_HOME" => gem_home,
        "GEM_PATH" => gem_home
      )
      # --ignore-dependencies is critical: without it, `gem install` pulls
      # the LATEST railties/activesupport that satisfy our `>= 7.1, < 9.0`
      # constraint into the isolated gem_home. If the test app is pinned
      # to Rails 7.1/7.2/8.0 but the isolated dir has 8.1.x, `rails-ai-
      # context init` crashes with `:compile_methods is blank (KeyError)`
      # — activesupport 8.1 config options the app's Rails doesn't know
      # about. Skipping deps forces transitive gems (railties, activesupport,
      # mcp, thor, zeitwerk, prism, concurrent-ruby) to resolve from the
      # app's gem set at run time via GEM_PATH (which prepends gem_home
      # and appends ENV["GEM_PATH"] — see `env`).
      install_out, install_status = Open3.capture2e(install_env, "gem", "install", gem_path,
                                                     "--install-dir", gem_home,
                                                     "--bindir", File.join(gem_home, "bin"),
                                                     "--no-document",
                                                     "--ignore-dependencies",
                                                     "--conservative")
      unless install_status.success?
        raise "gem install failed (isolated):\n#{install_out}"
      end
    end

    # Drop every Bundler env var from the subprocess. Equivalent to
    # `Bundler.with_unbundled_env` but at the Open3 env-hash level so
    # we keep one layer of subprocess (no nested shell).
    def unbundled_env
      {
        "BUNDLE_GEMFILE"   => nil,
        "BUNDLE_BIN_PATH"  => nil,
        "BUNDLE_PATH"      => nil,
        "BUNDLER_SETUP"    => nil,
        "BUNDLER_VERSION"  => nil,
        "RUBYOPT"          => nil,
        "RUBYLIB"          => nil
      }
    end

    # Execute a command inside the app directory with merged env.
    # Raises with captured output on failure.
    # Pass `stdin_input:` to feed answers to interactive prompts.
    def in_app(*cmd, env_extra: {}, stdin_input: nil)
      merged = env.merge(env_extra.compact)
      opts = { chdir: app_path }
      opts[:stdin_data] = stdin_input if stdin_input
      out, status = Open3.capture2e(merged, *cmd, **opts)
      unless status.success?
        raise "command failed: #{cmd.inspect}\n#{out}"
      end
      out
    end
  end
end
