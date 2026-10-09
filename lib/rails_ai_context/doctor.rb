# frozen_string_literal: true

require "find"
require "pathname"

module RailsAiContext
  # Diagnostic checker that validates the environment and reports
  # AI readiness with pass/warn/fail checks and a readiness score.
  class Doctor
    include CountPhrase

    Check = Data.define(:name, :status, :message, :fix)

    CHECKS = %i[
      check_schema
      check_pending_migrations
      check_models
      check_routes
      check_gems
      check_controllers
      check_views
      check_tests
      check_migrations
      check_context_freshness
      check_initializer_guard
      check_mcp_json
      check_codex_env_staleness
      check_mcp_buildable
      check_introspector_health
      check_preset_coverage
      check_ripgrep
      check_prism
      check_brakeman
      check_live_reload
      check_stdio_activation_hygiene
      check_security_gitignore
      check_security_auto_mount
      check_performance_schema_size
      check_performance_view_count
    ].freeze

    ICONS = { pass: "[PASS]", warn: "[WARN]", fail: "[FAIL]" }.freeze
    EMOJI_ICONS = { pass: "✅", warn: "⚠️ ", fail: "❌" }.freeze

    # An icon's character count is not its display width ("✅" is one
    # character and two columns), so the Fix line is indented by a constant
    # rather than by the icon above it.
    FIX_INDENT = " " * 9

    # The report the CLI and the rake task print, so the two say the same
    # thing about the same result.
    def self.report_lines(result, icons: ICONS)
      result[:checks].flat_map do |check|
        lines = [ "  #{icons[check.status]} #{check.name}: #{check.message}" ]
        lines << "#{FIX_INDENT}Fix: #{check.fix}" if check.fix
        lines
      end
    end

    attr_reader :app

    def initialize(app = nil)
      @app = app || Rails.application
    end

    def run
      results = CHECKS.filter_map do |check|
        send(check)
      rescue StandardError, ScriptError => e
        $stderr.puts "[rails-ai-context] Doctor check #{check} failed: #{e.class}: #{e.message}"
        nil
      end
      score = compute_score(results)
      { checks: results, score: score }
    end

    private

    # A standalone install has neither the rake tasks nor the generator, so a
    # fix names the command this install actually has.
    def command(job)
      InstallMode.command(job, standalone: standalone?)
    end

    def standalone?
      return @standalone if defined?(@standalone)

      @standalone = InstallMode.standalone?
    end

    # All configured AI tools; nil (unconfigured) means every tool in the table.
    ALL_AI_TOOLS = Install::AiTool.all.map(&:key).freeze

    def configured_ai_tools
      RailsAiContext.configuration.ai_tools || ALL_AI_TOOLS
    end

    # ── Existence checks ──────────────────────────────────────────────

    def check_schema
      format, path = RailsAiContext::Introspectors::SchemaDumpPath.present(app.root)
      shown = path.to_s.delete_prefix("#{app.root.to_s.chomp('/')}/")
      if format == :ruby
        lines = File.readlines(path).size
        Check.new(name: "Schema", status: :pass, message: "#{shown} found (#{count_phrase(lines, "line")})", fix: nil)
      elsif format == :sql
        size = (File.size(path) / 1024.0).round(1)
        Check.new(name: "Schema", status: :pass, message: "#{shown} found (#{size}KB)", fix: nil)
      else
        Check.new(name: "Schema", status: :warn, message: "No schema file found", fix: "Run `rails db:schema:dump`")
      end
    end

    def check_pending_migrations
      return nil unless defined?(ActiveRecord::Base)

      pending = RailsAiContext::PendingMigrations.live(RailsAiContext::PendingMigrations.migrate_dirs_for(app.root))
      return nil unless pending

      if pending.empty?
        Check.new(name: "Pending migrations", status: :pass, message: "No pending migrations", fix: nil)
      else
        Check.new(name: "Pending migrations", status: :fail,
          message: "#{count_phrase(pending.size, "pending migration")} - schema data will be stale",
          fix: "Run `rails db:migrate`")
      end
    end

    def check_models
      count = Introspectors::SourceScan.paths(app.root, kind: "app/models", skip_concerns: false).count
      if count > 0
        Check.new(name: "Models", status: :pass, message: "#{count_phrase(count, "model file")} found", fix: nil)
      else
        Check.new(name: "Models", status: :warn, message: "No model files", fix: "Generate models with `rails generate model`")
      end
    end

    def check_routes
      routes_path = File.join(app.root, "config/routes.rb")
      if File.exist?(routes_path)
        Check.new(name: "Routes", status: :pass, message: "config/routes.rb found", fix: nil)
      else
        Check.new(name: "Routes", status: :fail, message: "config/routes.rb not found", fix: "Ensure you're in a Rails app root directory")
      end
    end

    def check_gems
      lockfile = GemLock.lockfile_name(app.root)
      if File.exist?(File.join(app.root, lockfile))
        Check.new(name: "Gems", status: :pass, message: "#{lockfile} found", fix: nil)
      else
        Check.new(name: "Gems", status: :warn, message: "#{lockfile} not found", fix: "Run `bundle install`")
      end
    end

    def check_controllers
      count = Introspectors::SourceScan.paths(app.root, kind: "app/controllers", skip_concerns: false).count
      if count > 0
        Check.new(name: "Controllers", status: :pass, message: "#{count_phrase(count, "controller file")} found", fix: nil)
      else
        Check.new(name: "Controllers", status: :warn, message: "No controller files", fix: nil)
      end
    end

    def check_views
      dir = File.join(app.root, "app/views")
      if Dir.exist?(dir)
        count = Dir.glob(File.join(dir, "**/*")).reject { |f| File.directory?(f) }.size
        Check.new(name: "Views", status: :pass, message: "#{count_phrase(count, "file")} under app/views", fix: nil)
      else
        Check.new(name: "Views", status: :warn, message: "No view files", fix: nil)
      end
    end

    def check_tests
      suites = RailsAiContext::TestFramework.suites(app.root)
      if suites.any?
        Check.new(name: "Tests", status: :pass, message: "#{suites.join(", ")} test suite found", fix: nil)
      else
        Check.new(name: "Tests", status: :warn, message: "No test suite found",
          fix: "Run `rails generate rspec:install` or use default Minitest")
      end
    end

    def check_migrations
      count = RailsAiContext::PendingMigrations.migration_files(RailsAiContext::PendingMigrations.migrate_dirs_for(app.root), root: app.root).size
      if count.positive?
        Check.new(name: "Migrations", status: :pass, message: count_phrase(count, "migration file"), fix: nil)
      else
        Check.new(name: "Migrations", status: :warn, message: "No migrations", fix: nil)
      end
    end

    # ── Context file checks ───────────────────────────────────────────

    # Per-tool context path - sentinel checked for the freshness check.
    # Other files generated alongside are assumed in-sync (they're written
    # atomically by the same serializer). For Cursor, `.cursor/rules/` is
    # the sentinel; `.cursorrules` (v5.9.0 legacy fallback) is generated
    # atomically next to it, so checking either proves both are fresh.
    # The first context path is each tool's sentinel: the rest are written
    # atomically beside it, so its freshness proves theirs.
    CONTEXT_FILES = Install::AiTool.all.to_h { |tool| [ tool.key, tool.context_paths.first ] }.freeze

    # Where each tool's MCP config lives, and how to name it in a report.
    def self.mcp_config_checks
      Install::AiTool.all.to_h { |tool|
        path = tool.mcp_config[:path]
        [ tool.key, { path: path, label: "#{path} (#{tool.name})" } ]
      }
    end

    def check_context_freshness
      # An MCP-only install asked for no context files, so their absence is
      # the configuration working, not something to fix.
      return nil unless RailsAiContext.configuration.context_files

      ai_tools = configured_ai_tools

      # Find the first existing context file or split rule directory for configured tools
      context_file = nil
      context_label = nil
      ai_tools.each do |tool|
        filename = CONTEXT_FILES[tool]
        next unless filename

        path = File.join(app.root, filename)
        if File.exist?(path) || Dir.exist?(path)
          context_file = path
          context_label = filename
          break
        end
      end

      unless context_file
        return Check.new(name: "Context files", status: :warn,
          message: "No context files generated",
          fix: "Run `#{command(:context)}`")
      end

      generated_at = if File.directory?(context_file)
        # Split rule directories: use the most recent file's mtime
        Dir.glob(File.join(context_file, "**/*"))
          .reject { |f| File.directory?(f) }
          .map { |f| File.mtime(f) }
          .max || Time.at(0)
      else
        File.mtime(context_file)
      end
      # Freshness is measured over the same scope the watcher and the tool
      # cache use, so a service or a pack cannot change unnoticed.
      stale_dirs = Fingerprinter.changed_since(app.root, generated_at)
        .reject { |dir| only_our_initializer_newer?(dir, generated_at) }

      if stale_dirs.empty?
        Check.new(name: "Context files", status: :pass, message: "#{context_label} is up to date", fix: nil)
      else
        Check.new(name: "Context files", status: :warn,
          message: "#{context_label} may be stale - #{stale_dirs.join(', ')} changed since last generation",
          fix: "Run `#{command(:context)}` to regenerate")
      end
    end

    # Install writes our initializer in the same run that generates the
    # context files, so on its own it never means the context is stale.
    def only_our_initializer_newer?(dir, generated_at)
      return false unless dir == "config"

      newer = Dir.glob(File.join(app.root, dir, Fingerprinter::WATCHED_EXTENSIONS))
        .select { |path| File.mtime(path) > generated_at }

      newer.any? && newer.all? { |path| path.end_with?("initializers/rails_ai_context.rb") }
    end

    # A guard written before the respond_to? check was added only tests
    # `defined?(RailsAiContext)`, which the gemspec's version stub satisfies
    # even outside this gem's Bundler group - `.configure` then raises
    # NoMethodError in that environment. No guard at all fails the same way
    # wherever the gem is not loaded, standalone mode included.
    def check_initializer_guard
      path = File.join(app.root, "config/initializers/rails_ai_context.rb")
      return nil unless File.exist?(path)

      content = File.read(path)
      if Install::InitializerFile.configures?(content) && !Install::InitializerFile.any_guard_before_configure?(content)
        return Check.new(name: "Initializer guard", status: :warn,
          message: "config/initializers/rails_ai_context.rb has no recognised guard around the `configure` block",
          fix: "Wrap it in `if defined?(RailsAiContext) && RailsAiContext.respond_to?(:configure)` - " \
               "without one it raises where the gem is not loaded, such as standalone mode or a group-scoped Gemfile entry")
      end
      return nil unless Install::InitializerFile.bare_guard?(content)

      Check.new(name: "Initializer guard", status: :warn,
        message: "config/initializers/rails_ai_context.rb guards on `defined?(RailsAiContext)` alone",
        fix: "Re-run `#{command(:install)}`, or add `&& RailsAiContext.respond_to?(:configure)` to the guard")
    end

    def check_mcp_json
      if RailsAiContext.configuration.tool_mode == :cli
        return Check.new(name: "MCP configs", status: :pass,
          message: "Skipped (CLI-only mode)", fix: nil)
      end

      ai_tools = configured_ai_tools
      configs = self.class.mcp_config_checks

      # Check at least the Claude Code config (always expected)
      tools_to_check = ai_tools & configs.keys
      tools_to_check = %i[claude] if tools_to_check.empty?

      checks = tools_to_check.map do |tool|
        cfg = configs[tool]
        # An app in a workspace is served from the folder above it.
        full_path = McpConfigGenerator.serving_config(app.root, tool) || File.join(app.root, cfg[:path])
        unless File.exist?(full_path)
          next Check.new(name: cfg[:label], status: :warn,
            message: "No #{cfg[:path]} for MCP auto-discovery",
            fix: "Run `#{command(:install)}`")
        end

        shown = app_relative(full_path)
        if cfg[:path].end_with?(".toml")
          Check.new(name: cfg[:label], status: :pass, message: "#{shown} exists", fix: nil)
        else
          begin
            JSON.parse(File.read(full_path))
            Check.new(name: cfg[:label], status: :pass, message: "#{shown} valid", fix: nil)
          rescue JSON::ParserError => e
            Check.new(name: cfg[:label], status: :fail,
              message: "#{shown} has invalid JSON: #{e.message}",
              fix: "Run `#{command(:install)}` to regenerate")
          end
        end
      end

      # Aggregate all results into a single summary check
      failures = checks.select { |c| c.status != :pass }

      if failures.empty?
        Check.new(name: "MCP configs", status: :pass,
          message: "#{checks.size} of #{count_phrase(checks.size, "MCP config")} valid",
          fix: nil)
      else
        labels = failures.map { |c| c.name }
        worst_status = failures.any? { |c| c.status == :fail } ? :fail : :warn
        Check.new(name: "MCP configs", status: worst_status,
          message: "#{failures.size} of #{count_phrase(checks.size, "MCP config")} #{failures.size == 1 ? "needs" : "need"} attention: #{labels.join(', ')}",
          fix: "Run `#{command(:install)}` to fix")
      end
    end

    def check_codex_env_staleness
      return nil if RailsAiContext.configuration.tool_mode == :cli

      ai_tools = configured_ai_tools
      return nil unless ai_tools.include?(:codex)

      # The app's own config, or the workspace's above it.
      toml_path = McpConfigGenerator.serving_config(app.root, :codex)
      return nil unless toml_path && File.exist?(toml_path)

      # Check if snapshotted GEM_HOME directory still exists on disk.
      # This is version-manager agnostic and OS agnostic - no string format
      # assumptions. If the directory was removed (e.g. Ruby upgrade), the
      # env snapshot is definitely stale. Every server the gem wrote carries
      # one: the app's own, and each app's in a workspace.
      gem_homes = File.read(toml_path).scan(CODEX_ENV_SECTION).filter_map do |(env_section)|
        env_section[/^GEM_HOME\s*=\s*"([^"]+)"/, 1]
      end.uniq
      return nil if gem_homes.empty?

      snapshot_gem_home = gem_homes.find { |dir| !Dir.exist?(dir) }

      if snapshot_gem_home.nil?
        Check.new(name: "Codex env snapshot", status: :pass,
          message: "Codex GEM_HOME (#{gem_homes.first}) exists - env snapshot is current",
          fix: nil)
      else
        Check.new(name: "Codex env snapshot", status: :warn,
          message: "Codex MCP env snapshot is stale - GEM_HOME #{snapshot_gem_home} no longer exists. Re-run the install generator to update.",
          fix: "Run `#{command(:install)}`")
      end
    end

    CODEX_ENV_SECTION = /^\[mcp_servers\.#{McpConfigGenerator::OWN_NAME}\.env\]\s*$(.+?)(?=\n\[|\z)/m

    # How a file the check found reads from the app: its own path, or
    # ../.mcp.json for a workspace's.
    def app_relative(path)
      Pathname.new(path).relative_path_from(Pathname.new(app.root.to_s)).to_s
    rescue ArgumentError
      path.to_s
    end

    def check_mcp_buildable
      Server.new(app).build
      Check.new(name: "MCP server", status: :pass, message: "MCP server builds successfully", fix: nil)
    rescue => e
      Check.new(name: "MCP server", status: :fail,
        message: "MCP server failed: #{e.message}",
        fix: "Check mcp gem: `bundle info mcp`")
    end

    # RubyGems prints "Resolving dependencies..." to STDOUT when activating
    # this gem needs the full resolver (split/incomplete GEM_PATH, conflicting
    # candidate versions). That happens before any gem code runs and corrupts
    # the MCP stdio stream's pure-JSON framing. Re-run the activation the way
    # the standalone binstub does and flag anything that lands on stdout.
    # In-Gemfile installs activate through the lockfile and are immune.
    def check_stdio_activation_hygiene
      return Check.new(name: "MCP stdio hygiene", status: :pass,
        message: "in-Gemfile install activates via bundler (no resolver output)", fix: nil) unless standalone?

      require "open3"
      # An MCP client launches the binstub from a clean shell; simulate that
      # exactly. The booted app's Bundler has mutated this process's env
      # (RUBYOPT gets -rbundler/setup; with a configured bundle path even
      # GEM_HOME/GEM_PATH point into vendor/bundle), so start from Bundler's
      # snapshot of the pre-boot environment when it is available.
      base_env = defined?(Bundler) && Bundler.respond_to?(:original_env) ? Bundler.original_env : ENV.to_h
      %w[RUBYOPT RUBYLIB BUNDLE_GEMFILE BUNDLE_BIN_PATH BUNDLER_SETUP BUNDLE_PATH].each { |k| base_env.delete(k) }
      stdout, _stderr, status = Open3.capture3(
        base_env, Gem.ruby, "--disable-gems", "-e",
        "require 'rubygems'; gem 'rails-ai-context'",
        unsetenv_others: true
      )
      if status.success? && stdout.empty?
        Check.new(name: "MCP stdio hygiene", status: :pass,
          message: "gem activation is silent on stdout", fix: nil)
      elsif stdout.empty?
        Check.new(name: "MCP stdio hygiene", status: :warn,
          message: "gem activation exited #{status.exitstatus} (stdout clean)",
          fix: "Run `gem list rails-ai-context` and reinstall if missing")
      else
        Check.new(name: "MCP stdio hygiene", status: :fail,
          message: "gem activation writes to stdout (#{stdout.lines.first.to_s.strip.truncate(60)}) - this corrupts the MCP stdio stream",
          fix: "GEM_PATH is split or incomplete; use the full `gem env path` (see TROUBLESHOOTING: MCP client reports a JSON parse error)")
      end
    rescue => e
      Check.new(name: "MCP stdio hygiene", status: :warn,
        message: "could not verify activation hygiene: #{e.message.truncate(60)}", fix: nil)
    end

    # ── Introspector health ───────────────────────────────────────────

    def check_introspector_health
      config = RailsAiContext.configuration
      introspector = RailsAiContext::Introspector.new(app)
      failures = []

      # One run, as introspection has: the file lists and stats each introspector asks for are shared.
      RunCache.around do
        config.introspectors.each do |name|
          result = introspector.send(:resolve_introspector, name).call
          failures << [ name.to_s, result[:error].to_s ] if result.is_a?(Hash) && result[:error]
        rescue StandardError, ScriptError => e
          # ScriptError included: a syntax-broken app file must cost one
          # introspector, not the diagnosis the user ran doctor for.
          failures << [ name.to_s, "#{e.class}: #{e.message}" ]
        end
      end

      if failures.empty?
        Check.new(name: "Introspector health", status: :pass,
          message: "All #{count_phrase(config.introspectors.size, "introspector")} return data " \
            "(these feed the #{count_phrase(Server.builtin_tools.size, "MCP tool")})",
          fix: nil)
      else
        Check.new(name: "Introspector health", status: :warn,
          message: "#{count_phrase(failures.size, "introspector")} returned errors: #{failures.map(&:first).join(', ')}",
          fix: introspector_failure_hint(failures))
      end
    rescue StandardError, ScriptError => e
      RailsAiContext.debug_fail(e, nil, label: "check_introspector_health")
    end

    MAX_SHOWN_FAILURES = 3

    def introspector_failure_hint(failures)
      shown = failures.first(MAX_SHOWN_FAILURES).map { |name, message| "#{name}: #{first_error_line(message)}" }
      remaining = failures.size - MAX_SHOWN_FAILURES
      shown << "and #{count_phrase(remaining, "more introspector")}" if remaining.positive?
      shown.join("; ")
    end

    # Plain slicing, not truncate: this runs on the rescue path, where an
    # app without ActiveSupport's core_ext loaded would lose the whole check.
    def first_error_line(message)
      line = message.to_s.lines.first.to_s.strip
      line.length > 120 ? "#{line[0, 117]}..." : line
    end

    def check_preset_coverage
      config = RailsAiContext.configuration
      suggestions = []

      unless config.introspectors.include?(:stimulus)
        stimulus_count = Introspectors::StimulusIntrospector.controller_count(app.root.to_s)
        suggestions << "stimulus (#{count_phrase(stimulus_count, "controller")} found)" if stimulus_count.positive?
      end

      views_dir = File.join(app.root, "app/views")
      if Dir.exist?(views_dir) && !config.introspectors.include?(:views)
        suggestions << "views (app/views/ exists)"
      end

      i18n_dir = File.join(app.root, "config/locales")
      locale_file_count = Dir.exist?(i18n_dir) ? Dir.glob(File.join(i18n_dir, "**/*.{yml,yaml}")).size : 0
      if locale_file_count > 1 && !config.introspectors.include?(:i18n)
        suggestions << "i18n (#{count_phrase(locale_file_count, "locale file")})"
      end

      graphql_dir = File.join(app.root, "app/graphql")
      if Dir.exist?(graphql_dir) && !config.introspectors.include?(:api)
        suggestions << "api (app/graphql/ exists)"
      end

      if suggestions.empty?
        Check.new(name: "Preset coverage", status: :pass,
          message: "#{count_phrase(config.introspectors.size, "introspector")} cover detected features",
          fix: nil)
      else
        Check.new(name: "Preset coverage", status: :warn,
          message: "App has features not in preset: #{suggestions.join(', ')}",
          fix: "Add with `config.introspectors += %i[#{suggestions.map { |s| s.split(' ').first }.join(' ')}]` or use `config.preset = :full`")
      end
    end

    # ── Tool dependencies ─────────────────────────────────────────────

    def check_ripgrep
      if system("which", "rg", out: File::NULL, err: File::NULL)
        Check.new(name: "ripgrep", status: :pass, message: "rg available for fast code search", fix: nil)
      else
        Check.new(name: "ripgrep", status: :warn,
          message: "ripgrep not installed (slower Ruby fallback)",
          fix: "Install: `brew install ripgrep` or `apt install ripgrep`")
      end
    end

    def check_prism
      require "prism"
      Check.new(name: "Prism parser", status: :pass, message: "Prism available for AST-based validation", fix: nil)
    rescue LoadError
      Check.new(name: "Prism parser", status: :warn,
        message: "Prism not installed (validation falls back to subprocess, semantic checks limited)",
        fix: "Add: `gem 'prism'` (included in Ruby 3.3+)")
    end

    # Asked of the scanner rather than `require`: brakeman outside the app's bundle still scans.
    def check_brakeman
      where, version = Tools::SecurityScan.brakeman_location
      locked = GemLock.for(@app.root.to_s).version("brakeman")
      case where
      when :bundle
        Check.new(name: "Brakeman", status: :pass, message: "Brakeman #{version} available for security scanning", fix: nil)
      when :machine
        return Check.new(name: "Brakeman", status: :pass, fix: nil,
          message: "Brakeman #{version} on this machine, and the app's Gemfile.lock carries brakeman #{locked} " \
                   "(rails_security_scan runs it as its own process)") if locked

        Check.new(name: "Brakeman", status: :pass,
          message: "Brakeman #{version} on this machine, outside the app's bundle (rails_security_scan runs it from there)",
          fix: "Add: `gem 'brakeman', group: :development` to scan in this process")
      else
        return Check.new(name: "Brakeman", status: :warn,
          message: "The app's Gemfile.lock carries brakeman #{locked}, but it is not installed",
          fix: "Run `bundle install`") if locked

        Check.new(name: "Brakeman", status: :warn,
          message: "Brakeman not installed (rails_security_scan tool will return install instructions)",
          fix: "Add: `gem 'brakeman', group: :development`")
      end
    end

    def check_live_reload
      require "listen"
      Check.new(name: "Live reload", status: :pass, message: "`listen` gem available", fix: nil)
    rescue LoadError
      Check.new(name: "Live reload", status: :warn,
        message: "`listen` gem not installed (live reload unavailable)",
        fix: "Add: `gem 'listen', group: :development`")
    end

    # ── Security checks ───────────────────────────────────────────────

    def check_security_gitignore
      gitignore_path = File.join(app.root, ".gitignore")
      sensitive_files = present_sensitive_files

      return Check.new(name: "Secrets in .gitignore", status: :pass, message: "No sensitive files found", fix: nil) if sensitive_files.empty?

      gitignore = File.read(gitignore_path) if File.exist?(gitignore_path)
      exposed = gitignore ? sensitive_files.reject { |file| gitignore_covers?(gitignore, file) } : sensitive_files
      never, others = exposed.partition { |file| NEVER_COMMIT.any? { |pattern| File.fnmatch(pattern, file, File::FNM_PATHNAME | File::FNM_DOTMATCH) } }

      if never.any?
        message = gitignore ? never.map { |file| "#{file} not in .gitignore" }.join("; ") : "No .gitignore found - #{never.join(', ')} would be committed"
        message += "; also committed: #{others.join(', ')}" if others.any?
        Check.new(name: "Secrets in .gitignore", status: :fail, message: message,
          fix: "#{gitignore ? 'Add to .gitignore' : 'Create .gitignore with'}: #{never.map { |file| "`#{file}`" }.join(', ')}")
      elsif others.any?
        Check.new(name: "Secrets in .gitignore", status: :warn,
          message: "Committed, and never read by the tools: #{others.join(', ')}",
          fix: "Make sure these hold no secrets, or gitignore them")
      else
        Check.new(name: "Secrets in .gitignore", status: :pass,
          message: "Sensitive files gitignored: #{sensitive_files.join(', ')}", fix: nil)
      end
    end

    # Of the files the tools refuse, those no app commits on purpose; `database.yml`,
    # `credentials.yml.enc` and `.env.development` often are, so they only warn.
    NEVER_COMMIT = %w[
      .env config/master.key config/credentials/*.key config/application.yml .codex/config.toml
      .netrc .pgpass .aws/credentials **/id_rsa **/id_ed25519 **/id_ecdsa **/id_dsa .ssh/*
    ].freeze

    # Every file the tools refuse to read (the one sensitive-pattern list), plus the Codex
    # config our own install writes with this machine's PATH and GEM_HOME. Excluded
    # directories (node_modules, vendor, tmp) are not walked.
    def present_sensitive_files
      root = app.root.to_s
      excluded = RailsAiContext.configuration.excluded_paths.to_set
      found = []
      Find.find(root) do |path|
        relative = path.delete_prefix("#{root}/")
        next if path == root
        if File.directory?(path)
          Find.prune if excluded.include?(relative) || excluded.include?(File.basename(path)) || File.symlink?(path)
          next
        end
        found << relative if SafePath.sensitive?(relative) || relative == ".codex/config.toml"
      end
      found.sort
    rescue SystemCallError
      found.sort
    end

    def gitignore_covers?(content, path)
      GitIgnore.ignored?(GitIgnore.parse(content), path,
                         dir: false, case_insensitive: gitignore_case_insensitive?)
    end

    def gitignore_case_insensitive?
      return @gitignore_case_insensitive if defined?(@gitignore_case_insensitive)

      @gitignore_case_insensitive = GitIgnore.case_insensitive?(app.root)
    end

    def check_security_auto_mount
      config = RailsAiContext.configuration
      if config.auto_mount && defined?(Rails.env) && Rails.env.production?
        Check.new(name: "MCP auto_mount", status: :fail,
          message: "auto_mount is enabled in production - MCP endpoint is publicly accessible",
          fix: "Set `config.auto_mount = false` or restrict to development: `config.auto_mount = Rails.env.development?`")
      else
        Check.new(name: "MCP auto_mount", status: :pass,
          message: config.auto_mount ? "auto_mount enabled (non-production)" : "auto_mount disabled (safe)",
          fix: nil)
      end
    end

    # ── Performance checks ────────────────────────────────────────────

    def check_performance_schema_size
      config = RailsAiContext.configuration
      _, path = RailsAiContext::Introspectors::SchemaDumpPath.present(app.root)
      return nil unless path

      size = File.size(path)
      limit = config.max_schema_file_size
      pct = ((size.to_f / limit) * 100).round

      if pct >= 80
        Check.new(name: "Schema file size", status: :warn,
          message: "#{File.basename(path)} is #{(size / 1_000_000.0).round(1)}MB (#{pct}% of #{(limit / 1_000_000.0).round}MB limit)",
          fix: "Increase `config.max_schema_file_size` in your initializer")
      else
        Check.new(name: "Schema file size", status: :pass,
          message: "#{File.basename(path)} is #{(size / 1024.0).round}KB (within limit)",
          fix: nil)
      end
    end

    def check_performance_view_count
      config = RailsAiContext.configuration
      views_dir = File.join(app.root, "app/views")
      return nil unless Dir.exist?(views_dir)

      templates = Dir.glob(File.join(views_dir, RailsAiContext::ViewFile::MARKUP_GLOB))
      count = templates.size
      total_size = templates.sum { |f| File.size(f) rescue 0 }
      limit = config.max_view_total_size
      pct = ((total_size.to_f / limit) * 100).round

      if pct >= 80
        Check.new(name: "View aggregation size", status: :warn,
          message: "#{count_phrase(count, "erb/haml/slim template")} totaling #{(total_size / 1_000_000.0).round(1)}MB (#{pct}% of #{(limit / 1_000_000.0).round}MB limit for UI pattern extraction)",
          fix: "Increase `config.max_view_total_size`")
      else
        Check.new(name: "View aggregation size", status: :pass,
          message: "#{count_phrase(count, "erb/haml/slim template")} (#{(total_size / 1024.0).round}KB total, within limits)",
          fix: nil)
      end
    end

    # ── Scoring ───────────────────────────────────────────────────────

    def compute_score(results)
      return 0 if results.empty?
      total = results.size * 10
      earned = results.sum do |check|
        case check.status
        when :pass then 10
        when :warn then 5
        else 0
        end
      end
      Percent.floor(earned, total, decimals: 0)
    end
  end
end
