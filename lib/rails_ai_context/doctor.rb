# frozen_string_literal: true

module RailsAiContext
  # Diagnostic checker that validates the environment and reports
  # AI readiness with pass/warn/fail checks and a readiness score.
  class Doctor
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
      check_mcp_json
      check_codex_env_staleness
      check_mcp_buildable
      check_introspector_health
      check_preset_coverage
      check_ripgrep
      check_prism
      check_brakeman
      check_live_reload
      check_security_gitignore
      check_security_auto_mount
      check_performance_schema_size
      check_performance_view_count
    ].freeze

    attr_reader :app

    def initialize(app = nil)
      @app = app || Rails.application
    end

    def run
      results = CHECKS.filter_map do |check|
        send(check)
      rescue StandardError => e
        $stderr.puts "[rails-ai-context] Doctor check #{check} failed: #{e.class}: #{e.message}"
        nil
      end
      score = compute_score(results)
      { checks: results, score: score }
    end

    private

    # All configured AI tools, defaulting to all 5 when nil (unconfigured).
    ALL_AI_TOOLS = %i[claude cursor copilot opencode codex].freeze

    def configured_ai_tools
      RailsAiContext.configuration.ai_tools || ALL_AI_TOOLS
    end

    # ── Existence checks ──────────────────────────────────────────────

    def check_schema
      schema_path = File.join(app.root, "db/schema.rb")
      structure_path = File.join(app.root, "db/structure.sql")
      if File.exist?(schema_path)
        lines = File.readlines(schema_path).size
        Check.new(name: "Schema", status: :pass, message: "db/schema.rb found (#{lines} lines)", fix: nil)
      elsif File.exist?(structure_path)
        size = (File.size(structure_path) / 1024.0).round(1)
        Check.new(name: "Schema", status: :pass, message: "db/structure.sql found (#{size}KB)", fix: nil)
      else
        Check.new(name: "Schema", status: :warn, message: "No schema file found", fix: "Run `rails db:schema:dump`")
      end
    end

    def check_pending_migrations
      return nil unless defined?(ActiveRecord::Base) && ActiveRecord::Base.connected?

      context = ActiveRecord::MigrationContext.new(File.join(app.root, "db/migrate"))
      pending = if context.respond_to?(:pending_migrations)
        # Rails 7.1+
        context.pending_migrations
      else
        # Rails 7.0 and earlier
        ActiveRecord::Migrator.new(:up, context.migrations).pending_migrations
      end
      if pending.empty?
        Check.new(name: "Pending migrations", status: :pass, message: "No pending migrations", fix: nil)
      else
        Check.new(name: "Pending migrations", status: :fail,
          message: "#{pending.size} pending migration(s) — schema data will be stale",
          fix: "Run `rails db:migrate`")
      end
    rescue => e
      $stderr.puts "[rails-ai-context] check_pending_migrations failed: #{e.message}" if ENV["DEBUG"]
      # Can't check pending migrations in this environment
      nil
    end

    def check_models
      models_dir = File.join(app.root, "app/models")
      if Dir.exist?(models_dir) && Dir.glob(File.join(models_dir, "**/*.rb")).any?
        count = Dir.glob(File.join(models_dir, "**/*.rb")).size
        Check.new(name: "Models", status: :pass, message: "#{count} model files found", fix: nil)
      else
        Check.new(name: "Models", status: :warn, message: "No model files in app/models/", fix: "Generate models with `rails generate model`")
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
      lock_path = File.join(app.root, "Gemfile.lock")
      if File.exist?(lock_path)
        Check.new(name: "Gems", status: :pass, message: "Gemfile.lock found", fix: nil)
      else
        Check.new(name: "Gems", status: :warn, message: "Gemfile.lock not found", fix: "Run `bundle install`")
      end
    end

    def check_controllers
      dir = File.join(app.root, "app/controllers")
      if Dir.exist?(dir) && Dir.glob(File.join(dir, "**/*.rb")).any?
        count = Dir.glob(File.join(dir, "**/*.rb")).size
        Check.new(name: "Controllers", status: :pass, message: "#{count} controller files found", fix: nil)
      else
        Check.new(name: "Controllers", status: :warn, message: "No controller files", fix: nil)
      end
    end

    def check_views
      dir = File.join(app.root, "app/views")
      if Dir.exist?(dir)
        count = Dir.glob(File.join(dir, "**/*")).reject { |f| File.directory?(f) }.size
        Check.new(name: "Views", status: :pass, message: "#{count} view files found", fix: nil)
      else
        Check.new(name: "Views", status: :warn, message: "No view files", fix: nil)
      end
    end

    def check_tests
      if Dir.exist?(File.join(app.root, "spec")) || Dir.exist?(File.join(app.root, "test"))
        framework = Dir.exist?(File.join(app.root, "spec")) ? "RSpec" : "Minitest"
        Check.new(name: "Tests", status: :pass, message: "#{framework} test directory found", fix: nil)
      else
        Check.new(name: "Tests", status: :warn, message: "No test directory found",
          fix: "Run `rails generate rspec:install` or use default Minitest")
      end
    end

    def check_migrations
      migrate_dir = File.join(app.root, "db/migrate")
      if Dir.exist?(migrate_dir) && Dir.glob(File.join(migrate_dir, "*.rb")).any?
        count = Dir.glob(File.join(migrate_dir, "*.rb")).size
        Check.new(name: "Migrations", status: :pass, message: "#{count} migration files", fix: nil)
      else
        Check.new(name: "Migrations", status: :warn, message: "No migrations", fix: nil)
      end
    end

    # ── Context file checks ───────────────────────────────────────────

    # Per-tool context path — sentinel checked for the freshness check.
    # Other files generated alongside are assumed in-sync (they're written
    # atomically by the same serializer). For Cursor, `.cursor/rules/` is
    # the sentinel; `.cursorrules` (v5.9.0 legacy fallback) is generated
    # atomically next to it, so checking either proves both are fresh.
    CONTEXT_FILES = {
      claude:   "CLAUDE.md",
      cursor:   ".cursor/rules",
      opencode: "AGENTS.md",
      codex:    "AGENTS.md",
      copilot:  ".github/copilot-instructions.md"
    }.freeze

    def check_context_freshness
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
          fix: "Run `rails ai:context`")
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
      # Check if any source file changed after context was generated.
      # Exclude our own initializer — it's written during install and would
      # always appear newer than context files generated in the same run.
      stale_dirs = %w[app/models app/controllers app/views config db/migrate].select do |dir|
        full = File.join(app.root, dir)
        Dir.exist?(full) && Dir.glob(File.join(full, "**/*.rb"))
          .reject { |f| f.end_with?("initializers/rails_ai_context.rb") }
          .any? { |f| File.mtime(f) > generated_at }
      end

      if stale_dirs.empty?
        Check.new(name: "Context files", status: :pass, message: "#{context_label} is up to date", fix: nil)
      else
        Check.new(name: "Context files", status: :warn,
          message: "#{context_label} may be stale — #{stale_dirs.join(', ')} changed since last generation",
          fix: "Run `rails ai:context` to regenerate")
      end
    end

    def check_mcp_json
      if RailsAiContext.configuration.tool_mode == :cli
        return Check.new(name: "MCP configs", status: :pass,
          message: "Skipped (CLI-only mode)", fix: nil)
      end

      ai_tools = configured_ai_tools
      configs = {
        claude:   { path: ".mcp.json",         label: ".mcp.json (Claude Code)" },
        cursor:   { path: ".cursor/mcp.json",  label: ".cursor/mcp.json (Cursor)" },
        copilot:  { path: ".vscode/mcp.json",  label: ".vscode/mcp.json (VS Code/Copilot)" },
        opencode: { path: "opencode.json",     label: "opencode.json (OpenCode)" },
        codex:    { path: ".codex/config.toml", label: ".codex/config.toml (Codex CLI)" }
      }

      # Check at least the Claude Code config (always expected)
      tools_to_check = ai_tools & configs.keys
      tools_to_check = %i[claude] if tools_to_check.empty?

      checks = tools_to_check.map do |tool|
        cfg = configs[tool]
        full_path = File.join(app.root, cfg[:path])
        unless File.exist?(full_path)
          next Check.new(name: cfg[:label], status: :warn,
            message: "No #{cfg[:path]} for MCP auto-discovery",
            fix: "Run `rails generate rails_ai_context:install`")
        end

        if cfg[:path].end_with?(".toml")
          Check.new(name: cfg[:label], status: :pass, message: "#{cfg[:path]} exists", fix: nil)
        else
          begin
            JSON.parse(File.read(full_path))
            Check.new(name: cfg[:label], status: :pass, message: "#{cfg[:path]} valid", fix: nil)
          rescue JSON::ParserError => e
            Check.new(name: cfg[:label], status: :fail,
              message: "#{cfg[:path]} has invalid JSON: #{e.message}",
              fix: "Run `rails generate rails_ai_context:install` to regenerate")
          end
        end
      end

      # Aggregate all results into a single summary check
      failures = checks.select { |c| c.status != :pass }

      if failures.empty?
        Check.new(name: "MCP configs", status: :pass,
          message: "#{checks.size} of #{checks.size} MCP config(s) valid",
          fix: nil)
      else
        labels = failures.map { |c| c.name }
        worst_status = failures.any? { |c| c.status == :fail } ? :fail : :warn
        Check.new(name: "MCP configs", status: worst_status,
          message: "#{failures.size} of #{checks.size} MCP config(s) need attention: #{labels.join(', ')}",
          fix: "Run `rails generate rails_ai_context:install` to fix")
      end
    end

    def check_codex_env_staleness
      return nil if RailsAiContext.configuration.tool_mode == :cli

      ai_tools = configured_ai_tools
      return nil unless ai_tools.include?(:codex)

      toml_path = File.join(app.root, ".codex/config.toml")
      return nil unless File.exist?(toml_path)

      content = File.read(toml_path)
      match = content.match(/^\[mcp_servers\.rails-ai-context\.env\]\s*$(.+?)(?=\n\[|\z)/m)
      return nil unless match

      env_section = match[1]

      # Check if snapshotted GEM_HOME directory still exists on disk.
      # This is version-manager agnostic and OS agnostic — no string format
      # assumptions. If the directory was removed (e.g. Ruby upgrade), the
      # env snapshot is definitely stale.
      gem_home_match = env_section.match(/^GEM_HOME\s*=\s*"([^"]+)"/)
      return nil unless gem_home_match

      snapshot_gem_home = gem_home_match[1]

      if Dir.exist?(snapshot_gem_home)
        Check.new(name: "Codex env snapshot", status: :pass,
          message: "Codex GEM_HOME (#{snapshot_gem_home}) exists — env snapshot is current",
          fix: nil)
      else
        Check.new(name: "Codex env snapshot", status: :warn,
          message: "Codex MCP env snapshot is stale — GEM_HOME #{snapshot_gem_home} no longer exists. Re-run the install generator to update.",
          fix: "Run `rails generate rails_ai_context:install` or `rails-ai-context init`")
      end
    end

    def check_mcp_buildable
      Server.new(app).build
      Check.new(name: "MCP server", status: :pass, message: "MCP server builds successfully", fix: nil)
    rescue => e
      Check.new(name: "MCP server", status: :fail,
        message: "MCP server failed: #{e.message}",
        fix: "Check mcp gem: `bundle info mcp`")
    end

    # ── Introspector health ───────────────────────────────────────────

    def check_introspector_health
      config = RailsAiContext.configuration
      errors = []

      config.introspectors.each do |name|
        begin
          result = RailsAiContext::Introspector.new(app).send(:resolve_introspector, name).call
          errors << name.to_s if result.is_a?(Hash) && result[:error]
        rescue => e
          errors << "#{name} (#{e.message.truncate(50)})"
        end
      end

      if errors.empty?
        Check.new(name: "Introspector health", status: :pass,
          message: "All #{config.introspectors.size} introspectors return data",
          fix: nil)
      else
        Check.new(name: "Introspector health", status: :warn,
          message: "#{errors.size} introspector(s) returned errors: #{errors.join(', ')}",
          fix: "Check if the app has the required features (e.g., stimulus needs app/javascript/controllers/)")
      end
    rescue => e
      $stderr.puts "[rails-ai-context] check_introspector_health failed: #{e.message}" if ENV["DEBUG"]
      nil
    end

    def check_preset_coverage
      config = RailsAiContext.configuration
      suggestions = []

      stimulus_dir = File.join(app.root, "app/javascript/controllers")
      if Dir.exist?(stimulus_dir) && Dir.glob(File.join(stimulus_dir, "**/*_controller.{js,ts}")).any? && !config.introspectors.include?(:stimulus)
        suggestions << "stimulus (#{Dir.glob(File.join(stimulus_dir, '**/*_controller.{js,ts}')).size} controllers found)"
      end

      views_dir = File.join(app.root, "app/views")
      if Dir.exist?(views_dir) && !config.introspectors.include?(:views)
        suggestions << "views (app/views/ exists)"
      end

      i18n_dir = File.join(app.root, "config/locales")
      if Dir.exist?(i18n_dir) && Dir.glob(File.join(i18n_dir, "**/*.{yml,yaml}")).size > 1 && !config.introspectors.include?(:i18n)
        suggestions << "i18n (#{Dir.glob(File.join(i18n_dir, '**/*.{yml,yaml}')).size} locale files)"
      end

      graphql_dir = File.join(app.root, "app/graphql")
      if Dir.exist?(graphql_dir) && !config.introspectors.include?(:api)
        suggestions << "api (app/graphql/ exists)"
      end

      if suggestions.empty?
        Check.new(name: "Preset coverage", status: :pass,
          message: "#{config.introspectors.size} introspectors cover detected features",
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

    def check_brakeman
      require "brakeman"
      Check.new(name: "Brakeman", status: :pass, message: "Brakeman available for security scanning", fix: nil)
    rescue LoadError
      Check.new(name: "Brakeman", status: :warn,
        message: "Brakeman not installed (rails_security_scan tool will return install instructions)",
        fix: "Add: `gem 'brakeman', group: :development`")
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
      issues = []
      gitignore_path = File.join(app.root, ".gitignore")
      gitignore = File.exist?(gitignore_path) ? File.read(gitignore_path) : ""

      env_path = File.join(app.root, ".env")
      if File.exist?(env_path) && !gitignore.include?(".env")
        issues << ".env exists but not in .gitignore"
      end

      master_key = File.join(app.root, "config/master.key")
      if File.exist?(master_key) && !gitignore.include?("master.key")
        issues << "config/master.key not in .gitignore"
      end

      if issues.empty?
        Check.new(name: "Secrets in .gitignore", status: :pass, message: "Sensitive files properly gitignored", fix: nil)
      else
        Check.new(name: "Secrets in .gitignore", status: :fail,
          message: issues.join("; "),
          fix: "Add to .gitignore: `.env`, `config/master.key`")
      end
    end

    def check_security_auto_mount
      config = RailsAiContext.configuration
      if config.auto_mount && defined?(Rails.env) && Rails.env.production?
        Check.new(name: "MCP auto_mount", status: :fail,
          message: "auto_mount is enabled in production — MCP endpoint is publicly accessible",
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
      schema_path = File.join(app.root, "db/schema.rb")
      structure_path = File.join(app.root, "db/structure.sql")

      path = File.exist?(schema_path) ? schema_path : (File.exist?(structure_path) ? structure_path : nil)
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

      count = Dir.glob(File.join(views_dir, "**/*.{erb,haml,slim}")).size
      total_size = Dir.glob(File.join(views_dir, "**/*.{erb,haml,slim}")).sum { |f| File.size(f) rescue 0 }
      limit = config.max_view_total_size
      pct = ((total_size.to_f / limit) * 100).round

      if pct >= 80
        Check.new(name: "View aggregation size", status: :warn,
          message: "#{count} view files totaling #{(total_size / 1_000_000.0).round(1)}MB (#{pct}% of #{(limit / 1_000_000.0).round}MB limit for UI pattern extraction)",
          fix: "Increase `config.max_view_total_size` or `config.max_view_file_size`")
      else
        Check.new(name: "View aggregation size", status: :pass,
          message: "#{count} view files (#{(total_size / 1024.0).round}KB total, within limits)",
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
      ((earned.to_f / total) * 100).round
    end
  end
end
