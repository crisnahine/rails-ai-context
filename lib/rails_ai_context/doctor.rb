# frozen_string_literal: true

require "find"

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

      @standalone = InstallMode.standalone?(root: app.root)
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

    # One MCP config's answer. A config with a `problem` is named beside it in
    # the summary, and configs that share one are named together;
    # `unparseable` is the config as shown, when the install cannot merge into it.
    ConfigVerdict = Data.define(:label, :status, :problem, :fix, :unparseable)

    def check_mcp_json
      if RailsAiContext.configuration.tool_mode == :cli
        return Check.new(name: "MCP configs", status: :pass,
          message: "Skipped (CLI-only mode)", fix: nil)
      end

      verdicts = mcp_tools_to_check.map { |tool| mcp_config_verdict(tool) }
      failures = verdicts.reject { |verdict| verdict.status == :pass }

      if failures.empty?
        return Check.new(name: "MCP configs", status: :pass,
          message: "#{verdicts.size} of #{count_phrase(verdicts.size, "MCP config")} valid",
          fix: nil)
      end

      said = failures.group_by(&:problem).map do |problem, group|
        labels = group.map(&:label).join(", ")
        problem ? "#{labels}: #{problem}" : labels
      end
      unparseable = failures.filter_map(&:unparseable)
      fixes = ([ (unparseable_fix(unparseable) if unparseable.any?) ] + failures.reject(&:unparseable).map(&:fix)).compact.uniq
      Check.new(name: "MCP configs", status: failures.any? { |verdict| verdict.status == :fail } ? :fail : :warn,
        message: "#{failures.size} of #{count_phrase(verdicts.size, "MCP config")} #{failures.size == 1 ? "needs" : "need"} " \
                 "attention: #{said.join('; ')}",
        fix: fixes.join("; "))
    end

    # Check at least the Claude Code config (always expected)
    def mcp_tools_to_check
      tools = configured_ai_tools & self.class.mcp_config_checks.keys
      tools.empty? ? %i[claude] : tools
    end

    # The config a tool reads for this app, judged as the install would merge
    # into it and as its client would start the server it names.
    def mcp_config_verdict(tool)
      cfg = self.class.mcp_config_checks[tool]
      label = cfg[:label]
      install_fix = "Run `#{command(:install)}` to fix"
      # An app in a workspace is served from the folder above it, whose
      # config, if it cannot be read, is the one to fix.
      full_path = mcp_config_path(tool)
      unless File.exist?(full_path)
        return ConfigVerdict.new(label: label, status: :warn, problem: nil, fix: install_fix, unparseable: nil)
      end

      # ../.mcp.json for a workspace's.
      shown = Install::Program.relative_to(full_path, app.root)
      unless cfg[:path].end_with?(".toml")
        # An empty file is one install fills.
        text, = McpConfigGenerator.json_text(full_path)
        return ConfigVerdict.new(label: label, status: :warn, problem: nil, fix: install_fix, unparseable: nil) if text.strip.empty?

        data = McpConfigGenerator.read_json(full_path)
        # The install merges only into an object, with an object under
        # the tool's servers key, and leaves anything else as it is.
        root_key = McpConfigGenerator::TOOL_CONFIGS.fetch(tool)[:root_key]
        if !data.is_a?(Hash) || (!data[root_key].nil? && !data[root_key].is_a?(Hash))
          return ConfigVerdict.new(label: label, status: :fail, problem: nil, fix: nil, unparseable: shown)
        end
      end

      entries = serving_entries(tool, full_path)
      if entries.empty?
        return ConfigVerdict.new(label: label, status: :warn, problem: "holds no rails-ai-context server", fix: install_fix,
                                 unparseable: nil)
      end

      # An entry under the gem's name that runs something else (an HTTP one)
      # is its owner's to judge.
      status, problem, fix = entries.select { |entry| entry[:own] }.filter_map { |entry| entry_trouble(entry, tool, full_path, shown) }
                                    .min_by { |trouble| trouble.first == :fail ? 0 : 1 }
      ConfigVerdict.new(label: label, status: status || :pass, problem: problem, fix: fix, unparseable: nil)
    rescue JSON::ParserError
      ConfigVerdict.new(label: label, status: :fail, problem: nil, fix: nil, unparseable: shown)
    rescue SystemCallError, IOError => e
      ConfigVerdict.new(label: label, status: :warn, problem: "cannot be read: #{e.message}", fix: install_fix, unparseable: nil)
    end

    def mcp_config_path(tool)
      McpConfigGenerator.serving_config(app.root, tool) || McpConfigGenerator.unreadable_config_above(app.root, tool) ||
        File.join(app.root, self.class.mcp_config_checks[tool][:path])
    end

    # The folder a config sits in, which its client starts the server from.
    def mcp_config_folder(tool, path)
      path.delete_suffix(McpConfigGenerator::TOOL_CONFIGS.fetch(tool)[:path]).chomp("/")
    end

    # The entries under the gem's names in a config that serve this app: the
    # app's own config's, or a workspace's that point --app-path at the app.
    def serving_entries(tool, path)
      folder = mcp_config_folder(tool, path)
      variable = McpConfigGenerator::TOOL_CONFIGS.fetch(tool)[:folder_variable]
      target = SafePath.canonical(app.root.to_s)
      McpConfigGenerator.named_entries(path, tool).select do |entry|
        SafePath.canonical(McpConfigGenerator.entry_app_root(entry[:argv], variable, folder) || folder) == target
      end
    end

    # Why one of the gem's entries cannot start the server for this app, or
    # starts a copy of the gem other than the app's: [status, problem, fix],
    # nil when it starts the right one. Fast on purpose: the command is
    # looked up, never run.
    def entry_trouble(entry, tool, config_path, shown)
      argv = entry[:argv]
      folder = mcp_config_folder(tool, config_path)
      line = "`#{argv.take_while { |arg| !arg.start_with?("--app-path") }.join(' ')}`"
      rerun = "Run #{install_command(shown)} to fix"
      # Codex sets the PATH its env snapshot holds, which the snapshot check reads.
      path, where = entry_path_variable(entry, tool)
      found = path.nil? || executable_on?(argv.first.to_s, path, folder)
      missing = "#{line} cannot start - `#{argv.first}` is not on #{where}"

      if argv[0] == "bundle" && argv[1] == "exec"
        return [ :fail, missing, "Make `bundle` reachable from #{where}" ] unless found

        bundle = entry_bundle(entry, tool, folder) or return nil
        lock, gemfile, lock_shown = bundle
        return [ :fail, "#{line} cannot start - #{lock_shown} has no rails-ai-context", rerun ] if lock_lacks_gem?(lock)

        spec = bundled_gem_spec(gemfile) if argv[2] == "rails-ai-context"
        if spec && !spec.executables.include?("rails-ai-context")
          return [ :fail, "#{line} cannot start - the bundle's rails-ai-context at #{spec.full_gem_path} lists no `rails-ai-context` executable",
                   "Point the Gemfile at a rails-ai-context whose gemspec lists `exe/rails-ai-context` (a git checkout, or a release), " \
                   "then run `bundle install`" ]
        end
      elsif File.basename(argv[0].to_s) == "rails-ai-context"
        lock = GemLock.for(app.root)
        if lock.present?("rails-ai-context")
          bundled = "#{GemLock.bundle(app.root).lock_label} carries rails-ai-context #{lock.version("rails-ai-context")}"
          return [ :fail, "#{missing}, while #{bundled}", rerun ] unless found

          return [ :warn, "#{line} starts the gem installed outside the app's bundle, while #{bundled}", rerun ]
        end
        return [ :fail, missing, "Run `gem install rails-ai-context` for the Ruby on #{where}" ] unless found
      elsif !found
        return [ :fail, missing, rerun ]
      end
      nil
    end

    # The PATH an entry's server is started with, and how to name it: its
    # own env's when it sets one, else the client's. nil when it cannot be
    # read here: a variable the tool expands, or a Codex snapshot, which
    # check_codex_env_staleness reads.
    def entry_path_variable(entry, tool)
      set = entry[:env]["PATH"]
      return [ client_path, "PATH" ] if set.nil?
      return [ nil, "the PATH its env sets" ] if tool == :codex || set.include?("$")

      [ set, "the PATH its env sets" ]
    end

    # The PATH a client hands the server it starts: the shell's, before
    # Bundler put its own directories ahead of it.
    def client_path
      env = defined?(Bundler) && Bundler.respond_to?(:original_env) ? Bundler.original_env : ENV.to_h
      env["PATH"].to_s
    end

    # Whether `command` would start: a path is read from the folder the server
    # starts in, a bare name from PATH, as the client's spawn finds it.
    def executable_on?(command, path, folder)
      return false if command.empty?

      candidates = if command.include?("/") || (File::ALT_SEPARATOR && command.include?(File::ALT_SEPARATOR))
        [ File.expand_path(command, folder) ]
      else
        path.split(File::PATH_SEPARATOR).reject(&:empty?).map { |dir| File.join(File.expand_path(dir, folder), command) }
      end
      extensions = Gem.win_platform? ? [ "", *ENV.fetch("PATHEXT", ".EXE;.BAT;.CMD").split(";") ] : [ "" ]
      candidates.product(extensions).any? { |file, ext| File.file?("#{file}#{ext}") && File.executable?("#{file}#{ext}") }
    end

    # The bundle `bundle exec` reads for an entry: the Gemfile its env names,
    # else the app's own, which for an app with none is the one its
    # config/boot.rb names, as Bundler finds it walking up. nil when it
    # cannot be told. [lock, Gemfile, lockfile as shown] otherwise.
    def entry_bundle(entry, tool, folder)
      named = entry[:env]["BUNDLE_GEMFILE"]
      dir = if named
        gemfile = McpConfigGenerator.entry_path(named, McpConfigGenerator::TOOL_CONFIGS.fetch(tool)[:folder_variable], folder)
        return nil unless gemfile && File.basename(gemfile) == GemLock.gemfile_name(File.dirname(gemfile))

        File.dirname(gemfile)
      else
        folder
      end
      bundle = GemLock.bundle(dir)
      shown = SafePath.canonical(dir) == SafePath.canonical(app.root.to_s) ? bundle.lock_label : Install::Program.relative_to(File.join(bundle.dir, bundle.lock_label), app.root)
      [ GemLock.for(dir), bundle.gemfile, shown ]
    end

    # Known to lack the gem: a lockfile without it, or with none yet, a
    # Gemfile that names every gem it holds and not this one.
    def lock_lacks_gem?(lock)
      return !lock.present?("rails-ai-context") unless lock.missing?

      gems = lock.gemfile_gems
      !gems.nil? && !gems.include?("rails-ai-context")
    end

    # This process's copy of the gem, when it runs in the bundle `gemfile`
    # belongs to: only then is its gemspec the one `bundle exec` reads.
    def bundled_gem_spec(gemfile)
      return nil unless gemfile && defined?(Bundler) && Bundler.respond_to?(:default_gemfile)
      return nil unless SafePath.canonical(Bundler.default_gemfile.to_s) == SafePath.canonical(gemfile)

      Gem.loaded_specs["rails-ai-context"]
    rescue StandardError
      nil
    end

    # A workspace's config above the app is written by `init` run in the
    # workspace, never by this app's install.
    def install_command(shown)
      shown.start_with?("../") ? "`rails-ai-context init` in the folder that holds #{shown}" : "`#{command(:install)}`"
    end

    # Install leaves a config it cannot parse, or merge into, as it is, so
    # running it alone would change nothing there. A workspace's config above the app is
    # written by `init` run in the workspace, never by this app's install.
    def unparseable_fix(paths)
      run = if paths.any? { |path| path.start_with?("../") }
        "`rails-ai-context init` in the folder that holds #{paths.one? ? 'it' : 'them'}"
      else
        "`#{command(:install)}`"
      end
      "Make #{paths.join(', ')} valid JSON holding an object (the install leaves a file it cannot merge into as it is), " \
        "then run #{run}"
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
      # env snapshot is definitely stale.
      gem_homes = codex_gem_homes(toml_path)
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

    # Every server the gem wrote carries a snapshot: the app's own, and each
    # app's in a workspace. Read the way the generator reads the file, so a
    # section is the gem's by the same rule and any byte reads in any locale.
    def codex_gem_homes(path)
      lines = McpConfigGenerator.split_bom(SafeFile.read_text(path)).first.lines
      McpConfigGenerator::Toml.own_sections(lines).filter_map do |range, name|
        McpConfigGenerator::Toml.sub_table(lines, range, name, "env")["GEM_HOME"]
      end.uniq
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
    # In-Gemfile installs activate through the lockfile and are immune, unless
    # a config starts the binary installed outside the bundle all the same.
    def check_stdio_activation_hygiene
      unless standalone? || serves_installed_binary?
        return Check.new(name: "MCP stdio hygiene", status: :pass,
          message: "in-Gemfile install activates via bundler (no resolver output)", fix: nil)
      end

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

    # Whether a config this app is served from starts the `rails-ai-context`
    # binary itself, which activates the gem through RubyGems.
    def serves_installed_binary?
      return false if RailsAiContext.configuration.tool_mode == :cli

      mcp_tools_to_check.any? do |tool|
        path = McpConfigGenerator.serving_config(app.root, tool) or next false
        serving_entries(tool, path).any? { |entry| entry[:own] && File.basename(entry[:argv].first.to_s) == "rails-ai-context" }
      rescue SystemCallError, IOError, JSON::ParserError
        false
      end
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
