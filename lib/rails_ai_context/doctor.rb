# frozen_string_literal: true

require "find"
require "fileutils"
require "tmpdir"

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
      check_security_http_endpoint
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

    # One run, as introspection has: the introspector health check and the
    # context files' dry run read the same file lists and stats.
    def run
      results = RunCache.around do
        CHECKS.filter_map do |check|
          send(check)
        rescue StandardError, ScriptError => e
          $stderr.puts "[rails-ai-context] Doctor check #{check} failed: #{e.class}: #{e.message}"
          nil
        end
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

    # Every database the app migrates is asked, as db:migrate:status asks
    # it. One that does not exist or does not answer is a finding of its own:
    # no migration can be read from it, and every tool that reads the
    # database answers from files alone.
    def check_pending_migrations
      return nil unless defined?(ActiveRecord::Base)

      databases = database_states
      return nil if databases.empty?

      pending = databases.flat_map { |db| Array(db[:pending]).map { db[:name] } }
      return unreachable_database_check(databases, pending) if databases.any? { |db| db[:error] }

      if pending.empty?
        Check.new(name: "Pending migrations", status: :pass, message: "No pending migrations", fix: nil)
      else
        Check.new(name: "Pending migrations", status: :fail,
          message: "#{pending_phrase(pending, databases)} - schema data will be stale",
          fix: "Run `#{database_task("db:migrate")}`#{where_tasks_run}")
      end
    end

    # "2 pending migrations", and in an app of several databases, in which.
    def pending_phrase(pending, databases)
      phrase = count_phrase(pending.size, "pending migration")
      return phrase if databases.one?

      by_database = pending.tally
      return "#{phrase} in #{by_database.keys.first}" if by_database.one?

      "#{phrase} (#{by_database.map { |name, count| "#{count} in #{name}" }.join(', ')})"
    end

    # Each database the app migrates in this environment, through its own
    # connection: [{ name:, config:, pending: or error: }], none without a
    # database configuration to read.
    def database_states
      return @database_states if defined?(@database_states)

      @database_states = begin
        primary = ActiveRecord::Base.connection_db_config.name
        ActiveRecord::Base.configurations.configs_for(env_name: RailsAiContext.environment_name).map do |db_config|
          own = db_config.name == primary
          dirs = own ? primary_migrate_dirs : PendingMigrations.migrate_dirs_of(app.root, db_config.name)
          { name: db_config.name, config: db_config, **MigrationStatus.of_database(db_config, dirs, primary: own) }
        end
      rescue StandardError => e
        RailsAiContext.debug_fail(e, [], label: "database_states")
      end
    end

    def unreachable_database_check(databases, pending)
      env = RailsAiContext.environment_name
      missing, failing = databases.select { |db| db[:error] }.partition { |db| db[:error].is_a?(ActiveRecord::NoDatabaseError) }
      shown = ->(db) { databases.one? ? db[:config].database.to_s : "#{db[:name]} (#{db[:config].database})" }
      said = []
      if missing.any?
        said << "the #{env} #{missing.one? ? "database" : "databases"} #{missing.map(&shown).join(' and ')} " \
                "#{missing.one? ? "does" : "do"} not exist"
      end
      failing.each { |db| said << "the #{env} database #{shown.(db)} cannot be reached: #{first_error_line(db[:error].message)}" }
      said << pending_phrase(pending, databases) if pending.any?

      fixes = []
      fixes << "Run `#{database_task("db:prepare")}`#{where_tasks_run}" if missing.any? || pending.any?
      fixes << "Start the database server, or fix its settings in config/database.yml" if failing.any?
      Check.new(name: "Database", status: :fail, message: said.join("; "), fix: fixes.join("; "))
    end

    # A database task as typed where it runs: in an engine's test/dummy, at
    # the engine's root, whose db tasks add the engine's own migrations
    # (from the dummy itself, Rails lists them as NO FILE). The engine
    # forwards db:migrate to its dummy, and db:prepare only as app:db:prepare.
    def database_task(task)
      env = RailsAiContext.environment_name
      task = "app:#{task}" if task == "db:prepare" && engine_roots_shown.any?
      "#{"RAILS_ENV=#{env} " unless env == "development"}bin/rails #{task}"
    end

    def where_tasks_run
      engine_roots_shown.empty? ? "" : " in the engine at #{engine_roots_shown.join(', ')}"
    end

    # The engines an engine's test/dummy runs in, as the app root reaches them (../..).
    def engine_roots_shown
      @engine_roots_shown ||= PathResolver.enclosing_engine_roots(app.root.to_s).map { |engine| Install::Program.relative_to(engine, app.root) }
    end

    # The primary's migrations directories, and in an engine's test/dummy
    # the engine's db/migrate too, which the engine's db:migrate runs against
    # the dummy's database.
    def primary_migrate_dirs
      PendingMigrations.migrate_dirs_for(app.root) + PathResolver.enclosing_engine_roots(app.root.to_s).map { |engine| File.join(engine, "db/migrate") }
    end

    def check_models
      count, in_engine = source_file_counts("app/models")
      if count > 0
        Check.new(name: "Models", status: :pass, message: "#{count_phrase(count, "model file")} found#{engine_share(in_engine)}", fix: nil)
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

    # The bundle the tools read: the app's own lockfile, or with none, the
    # one its config/boot.rb names (a monorepo's shared Gemfile, an engine's
    # for its test/dummy), read inside the app's git repository only.
    def check_gems
      bundle = GemLock.bundle(app.root)
      if bundle.lockfile && File.file?(bundle.lockfile)
        Check.new(name: "Gems", status: :pass, message: "#{bundle.lock_label} found", fix: nil)
      elsif bundle.outside
        Check.new(name: "Gems", status: :warn, message: GemLock.for(app.root).reason, fix: nil)
      else
        Check.new(name: "Gems", status: :warn, message: "#{bundle.lock_label} not found", fix: "Run `bundle install`")
      end
    end

    def check_controllers
      count, in_engine = source_file_counts("app/controllers")
      if count > 0
        Check.new(name: "Controllers", status: :pass, message: "#{count_phrase(count, "controller file")} found#{engine_share(in_engine)}", fix: nil)
      else
        Check.new(name: "Controllers", status: :warn, message: "No controller files", fix: nil)
      end
    end

    # Every directory the tools read views from: app/views, a pack's, and in
    # an engine's test/dummy the engine's.
    def check_views
      dirs = PathResolver.view_dirs(app.root)
      if dirs.any?
        count = dirs.sum { |dir| Dir.glob(File.join(dir, "**/*")).count { |f| File.file?(f) } }
        shown = dirs.map { |dir| dir.delete_prefix(SafePath.dir_prefix(app.root.to_s)) }
        shown = dirs.map { |dir| Install::Program.relative_to(dir, app.root) } if shown.any? { |dir| dir.start_with?("/") }
        Check.new(name: "Views", status: :pass, message: "#{count_phrase(count, "file")} under #{shown.join(', ')}", fix: nil)
      else
        Check.new(name: "Views", status: :warn, message: "No view files", fix: nil)
      end
    end

    # The suite the tools read: the app's own, or the engine's its test/dummy runs in.
    def check_tests
      suite_root = PathResolver.test_root(app.root.to_s)
      suites = RailsAiContext::TestFramework.suites(suite_root)
      if suites.any?
        where = suite_root == app.root.to_s ? "" : " (the engine's, at #{PathResolver.suite_relative(app.root.to_s, ".")})"
        Check.new(name: "Tests", status: :pass, message: "#{suites.join(", ")} test suite found#{where}", fix: nil)
      elsif (unread = GemLock.for(app.root).unread_bundle) && TestFramework.unread_gemfile(app.root)
        Check.new(name: "Tests", status: :warn, message: "No test suite in the app, and #{unread}, so the suite there is not read", fix: nil)
      else
        Check.new(name: "Tests", status: :warn, message: "No test suite found",
          fix: "Run `rails generate rspec:install` or use default Minitest")
      end
    end

    # A kind of app code where the tools read it: SourceScan's directories,
    # and in an engine's test/dummy the engine's own, which the booted tools
    # load. [every file, the engine's]
    def source_file_counts(kind)
      own = Introspectors::SourceScan.paths(app.root, kind: kind, skip_concerns: false).count
      in_engine = PathResolver.enclosing_engine_roots(app.root.to_s).sum { |engine| Dir.glob(File.join(engine, kind, "**", "*.rb")).size }
      [ own + in_engine, in_engine ]
    end

    def engine_share(count)
      count.positive? ? " (#{count} in the engine at #{engine_roots_shown.join(', ')})" : ""
    end

    # Every database's migrations, a file two of them share counted once.
    def check_migrations
      files = migration_dirs_by_database.transform_values { |dirs| migration_files_in(dirs) }
      total = files.values.flatten.uniq.size
      unless total.positive?
        return Check.new(name: "Migrations", status: :warn, message: "No migrations", fix: nil)
      end

      where = files.select { |_, paths| paths.any? }.map { |name, paths| "#{paths.size} in #{name}" }
      app_dir = SafePath.dir_prefix(app.root.to_s)
      message = count_phrase(total, "migration file")
      message += " (#{where.join(', ')})" if files.size > 1
      message += engine_share(files.values.flatten.uniq.count { |path| !path.start_with?(app_dir) })
      Check.new(name: "Migrations", status: :pass, message: message, fix: nil)
    end

    # The migration files under dirs, each read inside the tree it belongs
    # to: the app's, or that of the engine its test/dummy runs in.
    def migration_files_in(dirs)
      app_dir = SafePath.dir_prefix(app.root.to_s)
      engines = PathResolver.enclosing_engine_roots(app.root.to_s)
      dirs.flat_map do |dir|
        tree = dir.start_with?(app_dir) ? app.root : engines.find { |engine| dir.start_with?(SafePath.dir_prefix(engine)) } || app.root
        PendingMigrations.migration_files(dir, root: tree).map { |file| file[:path] }
      end
    end

    # Each database's migrations directories, by the name database.yml gives it.
    def migration_dirs_by_database
      primary = DatabaseYml.primary_name(app.root) || "primary"
      secondaries = DatabaseYml.task_secondaries(app.root).keys.to_h { |name| [ name, PendingMigrations.migrate_dirs_of(app.root, name) ] }
      { primary => primary_migrate_dirs }.merge(secondaries)
    end

    # ── Context file checks ───────────────────────────────────────────

    # Each tool's context files and rule directories, root file first.
    CONTEXT_PATHS = Install::AiTool.all.to_h { |tool| [ tool.key, tool.context_paths ] }.freeze

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

      # Where the files are written: config.output_dir, else the app root.
      output_dir = RailsAiContext.configuration.output_dir_for(app)
      present = configured_ai_tools.flat_map { |tool| CONTEXT_PATHS.fetch(tool, []) }.uniq
        .select { |relative| File.exist?(File.join(output_dir, relative)) }
      if present.empty?
        return Check.new(name: "Context files", status: :warn,
          message: "No context files generated",
          fix: "Run `#{command(:context)}`")
      end

      # A context file is stale when the run the fix names would rewrite it,
      # which is never true of a file that run leaves alone however old it
      # is, and always true of one an older version of the gem wrote.
      run = context_file_run(output_dir)
      stale = run[:written]
      # Named from the app root, or in full for an output_dir outside it.
      first = ->(files) { File.join(output_dir, files.first).delete_prefix("#{app.root.to_s.chomp('/')}/") }
      shown = ->(files) { "#{first.(files)}#{" and #{count_phrase(files.size - 1, "more context file")}" if files.size > 1}" }
      if stale.empty?
        fresh = run[:skipped].presence || present
        return Check.new(name: "Context files", status: :pass,
          message: "#{shown.(fresh)} #{fresh.one? ? "is" : "are"} up to date", fix: nil)
      end

      Check.new(name: "Context files", status: :warn,
        message: "#{shown.(stale)} #{stale.one? ? "is" : "are"} out of date: #{staleness_reason(output_dir, stale)}",
        fix: "Run `#{command(:context)}` to regenerate")
    end

    # The context files run through the writers the context command runs,
    # into a copy of them, so the copy says which files that run would
    # rewrite and nothing in the app is touched. Paths relative to the
    # output directory; the JSON dump is no AI tool's file.
    #
    # @return [Hash] { written: [paths a run rewrites], skipped: [paths it leaves] }
    def context_file_run(output_dir)
      config = RailsAiContext.configuration
      Dir.mktmpdir("rails-ai-context-doctor") do |scratch|
        copy_context_files(output_dir, scratch)
        previous = config.output_dir
        result = begin
          config.output_dir = scratch
          RailsAiContext.generate_context(app)
        ensure
          config.output_dir = previous
        end
        result.slice(:written, :skipped).transform_values do |paths|
          paths.map { |path| path.delete_prefix("#{scratch}/") } - [ ".ai-context.json" ]
        end
      end
    end

    # Every context file and rule directory there is, and each directory one
    # of them would go in: a writer leaves a file out where its directory is
    # missing (app/models/AGENTS.md without app/models).
    def copy_context_files(output_dir, scratch)
      (CONTEXT_PATHS.values.flatten.uniq + [ ".ai-context.json" ]).each do |relative|
        source = File.join(output_dir, relative)
        target = File.join(scratch, relative)
        next unless File.directory?(File.dirname(source))

        FileUtils.mkdir_p(File.dirname(target))
        FileUtils.cp_r(source, File.dirname(target)) if File.exist?(source)
      end
    end

    # The version an older gem stamped the files with, else the directories
    # holding a file newer than the oldest of them, else what is known: a
    # run would write them (a file not there yet, a changed config).
    def staleness_reason(output_dir, stale)
      paths = stale.map { |relative| File.join(output_dir, relative) }.select { |path| File.file?(path) }
      written_by = paths.lazy.filter_map { |path| SafeFile.read(path)&.[](/generated by rails-ai-context v(\d\S*)/i, 1) }.first
      if written_by && written_by != RailsAiContext::VERSION
        return "written by rails-ai-context v#{written_by}, this is v#{RailsAiContext::VERSION}"
      end

      oldest = paths.map { |path| File.mtime(path) }.min
      changed = oldest ? Fingerprinter.changed_since(app.root, oldest).reject { |dir| only_our_initializer_newer?(dir, oldest) } : []
      return "#{changed.join(', ')} changed since #{stale.one? ? "it was" : "they were"} written" if changed.any?

      "a regeneration would write #{stale.one? ? "it" : "them"}"
    end

    # Install writes our initializer in the same run that generates the
    # context files, so on its own it never explains a stale one.
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
        text, _, problem = McpConfigGenerator.json_text(full_path)
        # An empty file is one install fills.
        if problem.nil? && text.strip.empty?
          return ConfigVerdict.new(label: label, status: :warn, problem: nil, fix: install_fix, unparseable: nil)
        end

        problem ||= json_config_problem(text, tool)
        return ConfigVerdict.new(label: label, status: :fail, problem: problem, fix: nil, unparseable: shown) if problem
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
    rescue SystemCallError, IOError => e
      ConfigVerdict.new(label: label, status: :warn, problem: "cannot be read: #{e.message}", fix: install_fix, unparseable: nil)
    end

    # Why the install would leave a JSON config as it is, in the words the
    # install uses: it does not parse (or holds comments), or it holds no
    # object to merge into, at the top or under the tool's servers key.
    def json_config_problem(text, tool)
      data = JSON.parse(text)
      root_key = McpConfigGenerator::TOOL_CONFIGS.fetch(tool)[:root_key]
      if !data.is_a?(Hash) then "it is JSON but not an object"
      elsif !data[root_key].nil? && !data[root_key].is_a?(Hash) then %("#{root_key}" is not an object)
      end
    rescue JSON::ParserError => e
      McpConfigGenerator.parse_problem(e, text)
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

          return [ :warn, "#{line} needs the gem installed outside the app's bundle, while #{bundled}", rerun ]
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

      # Every server the gem wrote carries a snapshot: the app's own, and each
      # app's in a workspace. Read the way the generator reads the file, so a
      # section is the gem's by the same rule and any byte reads in any locale.
      snapshots = McpConfigGenerator.named_entries(toml_path, :codex).select do |entry|
        entry[:own] && (entry[:env]["PATH"] || entry[:env]["GEM_HOME"])
      end
      return nil if snapshots.empty?

      shown = Install::Program.relative_to(toml_path, app.root)
      fix = "Run #{install_command(shown)}"
      unreached = snapshots.filter_map { |entry| unreached_command(entry, mcp_config_folder(:codex, toml_path)) }
      if unreached.any?
        said = unreached.group_by { |_, command, gone| [ command, gone ] }.map do |(command, gone), group|
          "the PATH saved for #{group.map(&:first).join(' and ')} no longer reaches `#{command}`#{" (#{gone} is gone)" if gone}"
        end
        return Check.new(name: "Codex env snapshot", status: :fail,
          message: "Codex MCP env snapshot in #{shown} is stale - #{said.join('; ')}", fix: fix)
      end

      # A GEM_HOME the snapshot names that is gone (e.g. Ruby upgraded) is stale
      # whatever the version manager: no string format assumptions.
      gem_homes = snapshots.filter_map { |entry| entry[:env]["GEM_HOME"] }.uniq
      if (gone = gem_homes.find { |dir| !Dir.exist?(dir) })
        return Check.new(name: "Codex env snapshot", status: :warn,
          message: "Codex MCP env snapshot is stale - GEM_HOME #{gone} no longer exists", fix: fix)
      end

      reached = snapshots.filter_map { |entry| entry[:argv].first if entry[:env]["PATH"] }.uniq
      found = []
      found << "its PATH reaches #{reached.map { |command| "`#{command}`" }.join(', ')}" if reached.any?
      found << "GEM_HOME (#{gem_homes.first}) exists" if gem_homes.any?
      Check.new(name: "Codex env snapshot", status: :pass,
        message: "Codex env snapshot in #{shown} is current: #{found.join(', and ')}", fix: nil)
    end

    # Codex starts a server with the PATH its snapshot saved in place of its
    # own, and rbenv or asdf save nothing else, so a Ruby that has moved shows
    # as a command that PATH no longer reaches. The first gone directory on it
    # is usually that Ruby's. [server name, command, gone directory] or nil.
    def unreached_command(entry, folder)
      path = entry[:env]["PATH"] or return nil
      command = entry[:argv].first.to_s
      return nil if executable_on?(command, path, folder)

      [ entry[:name], command, path.split(File::PATH_SEPARATOR).find { |dir| !dir.empty? && !Dir.exist?(File.expand_path(dir, folder)) } ]
    end

    def check_mcp_buildable
      Server.new(app).build
      if (pinned = unsupported_pin("mcp"))
        return Check.new(name: "MCP server", status: :warn, message: "MCP server builds, but #{pinned}", fix: bundle_update_fix("mcp"))
      end

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
      if (pinned = unsupported_pin("prism"))
        return Check.new(name: "Prism parser", status: :warn, message: pinned, fix: bundle_update_fix("prism"))
      end

      Check.new(name: "Prism parser", status: :pass, message: "Prism #{Prism::VERSION} available for AST-based validation", fix: nil)
    rescue LoadError
      Check.new(name: "Prism parser", status: :warn,
        message: "Prism not installed (validation falls back to subprocess, semantic checks limited)",
        fix: "Add: `gem 'prism'` (included in Ruby 3.3+)")
    end

    # A dependency the app's bundle pins outside what this gem needs, said as
    # the binary warns of it at boot: the app's copy is the one loaded, since
    # two copies in one process would each load half of it. nil when none is.
    def unsupported_pin(name)
      dependency = Gem.loaded_specs["rails-ai-context"]&.runtime_dependencies&.find { |dep| dep.name == name } or return nil
      loaded = Gem.loaded_specs[name] or return nil
      return nil if dependency.requirement.satisfied_by?(loaded.version)

      "the app locks #{name} #{loaded.version}; this gem needs #{name} #{dependency.requirement}, so the tools that use it may fail"
    end

    def bundle_update_fix(name)
      "Run `bundle update #{name}` in the app, after relaxing any pin its Gemfile puts on #{name}"
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
        fix: standalone? ? "Run: `gem install listen`" : "Add: `gem 'listen', group: :development`")
    end

    # ── Security checks ───────────────────────────────────────────────

    # Of the files the tools refuse to read, the ones that are secret: a key,
    # an environment file, a machine's own credentials, and a config file
    # only where it holds a secret as a literal. An encrypted credentials
    # file is committed by design; its key is what stays out.
    def check_security_gitignore
      gitignore_path = File.join(app.root, ".gitignore")
      gitignore = File.read(gitignore_path) if File.exist?(gitignore_path)
      files = present_sensitive_files.reject { |file| matches_any?(ENCRYPTED, file) }
      exposed = gitignore ? files.reject { |file| gitignore_covers?(gitignore, file) } : files
      never, others = exposed.partition { |file| matches_any?(NEVER_COMMIT, file) }
      configs, others = others.partition { |file| matches_any?(SECRET_HOLDING_CONFIGS, file) }
      literal = configs.filter_map { |file| (where = literal_secret(file)) && "#{file} (#{where})" }

      if never.any?
        message = gitignore ? never.map { |file| "#{file} not in .gitignore" }.join("; ") : "No .gitignore found - #{never.join(', ')} would be committed"
        message += "; a literal secret in #{literal.join(', ')}" if literal.any?
        message += "; also committed: #{others.join(', ')}" if others.any?
        Check.new(name: "Secrets in .gitignore", status: :fail, message: message,
          fix: "#{gitignore ? 'Add to .gitignore' : 'Create .gitignore with'}: #{never.map { |file| "`#{file}`" }.join(', ')}")
      elsif literal.any?
        Check.new(name: "Secrets in .gitignore", status: :warn,
          message: "A literal secret in #{literal.join(', ')}, which .gitignore does not cover",
          fix: "Read it from the environment or credentials (`password: <%= ENV[\"DATABASE_PASSWORD\"] %>`), or gitignore the file")
      elsif others.any?
        Check.new(name: "Secrets in .gitignore", status: :warn,
          message: "Committed, and never read by the tools: #{others.join(', ')}",
          fix: "Make sure these hold no secrets, or gitignore them")
      else
        secrets = files.select { |file| matches_any?(NEVER_COMMIT, file) }
        Check.new(name: "Secrets in .gitignore", status: :pass,
          message: secrets.any? ? "Secret files gitignored: #{secrets.join(', ')}" : "No secret files found", fix: nil)
      end
    end

    # Secret by what they are, so no app commits them on purpose. Rails'
    # own .gitignore leaves out every .env file and every key.
    NEVER_COMMIT = %w[
      .env .env.* config/master.key config/credentials/*.key config/application.yml .codex/config.toml
      .netrc .pgpass .aws/credentials **/id_rsa **/id_ed25519 **/id_ecdsa **/id_dsa .ssh/*
    ].freeze

    # Encrypted, and committed by design.
    ENCRYPTED = %w[config/credentials.yml.enc config/credentials/*.yml.enc config/secrets*.yml.enc].freeze

    # Committed in most apps, and a secret only where one is written in as a
    # literal rather than read from the environment or credentials.
    SECRET_HOLDING_CONFIGS = %w[
      config/database.yml config/secrets*.yml config/cable.yml config/storage.yml config/mongoid.yml config/redis.yml
      config/settings.local.yml config/settings/*.local.yml
    ].freeze

    # A key that names a secret, and a URL that carries a password.
    SECRET_KEY = /password|passwd|secret|token|private_key|api_key|access_key/i
    URL_PASSWORD = %r{\A[a-z][\w+.-]*://[^:@/\s]*:[^@/\s]+@}i
    # What a key can hold that is no secret written in: ERB, an alias, a
    # block scalar, nothing, or a number or a switch.
    NOT_LITERAL = /\A(?:<%|\*|[|>]|~\z|null\z|""\z|''\z|\d+(?:\.\d+)?\z|(?:true|false|yes|no|on|off)\z)/i

    # Where a config file sets a secret to a literal value ("`password` on
    # line 12"), or nil. Read line by line, since ERB keeps the file from
    # parsing as YAML until it runs.
    def literal_secret(file)
      content = SafeFile.read(File.join(app.root, file)) or return nil
      content.each_line.with_index(1) do |line, number|
        key, value = line.chomp.match(/\A\s*-?\s*["']?([\w-]+)["']?\s*:\s*(.*?)\s*(?:\s#.*)?\z/)&.captures
        next if key.nil? || value.empty? || value.match?(NOT_LITERAL) || value.include?("<%")

        unquoted = value.delete_prefix('"').delete_suffix('"').delete_prefix("'").delete_suffix("'")
        return "`#{key}` on line #{number}" if key.match?(SECRET_KEY) || unquoted.match?(URL_PASSWORD)
      end
      nil
    end

    def matches_any?(patterns, file)
      patterns.any? { |pattern| File.fnmatch(pattern, file, File::FNM_PATHNAME | File::FNM_DOTMATCH) }
    end

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

    # The endpoint inside the app - the mounted engine and auto_mount - refuses
    # in production unless the app sets allow_http_in_production. With it set,
    # auto_mount answers before routing, where an app keeps its authentication,
    # so nothing can guard it; the engine can sit behind a routes constraint.
    def check_security_http_endpoint
      config = RailsAiContext.configuration
      name = "MCP HTTP endpoint"
      if config.allow_http_in_production && config.auto_mount
        Check.new(name: name, status: :fail,
          message: "auto_mount answers every tool in production and staging, before any authentication (allow_http_in_production is on)",
          fix: "Turn off `allow_http_in_production`, or replace auto_mount with the engine mounted behind your app's authentication")
      elsif config.allow_http_in_production
        Check.new(name: name, status: :warn,
          message: "allow_http_in_production is on: a mounted engine answers every tool in production and staging",
          fix: "Keep the mount behind your app's authentication, and turn the option off if production does not need it")
      else
        Check.new(name: name, status: :pass,
          message: config.auto_mount ? "auto_mount enabled; refused outside development and test" : "Refused outside development and test (allow_http_in_production is off)",
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
