# frozen_string_literal: true

require "json"
require "find"
require "fileutils"
require "open3"
require "rbconfig"
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
      check_settings_read
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

    # `from` is the directory the command was typed in, where every command
    # a fix gives runs, and which every path the report names is named
    # from: an engine's root, above its test/dummy, names the dummy app's
    # views test/dummy/app/views and the engine's lockfile Gemfile.lock.
    # Inside the app, or inside the engine its test/dummy runs in, paths are
    # named from that root instead. Unsaid, it is the app's root.
    def initialize(app = nil, from: nil)
      @app = app || Rails.application
      @from = from
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
      in_app(InstallMode.command(job, standalone: standalone?))
    end

    # The app as a command typed where doctor was reaches it (`blog` from its
    # parent folder, `test/dummy` from an engine's root, `../..` from its
    # app/models), ready for a shell; nil typed at its root.
    def typed_app
      return @typed_app if defined?(@typed_app)

      @typed_app = typed_at?(app.root) ? nil : shell_path(app.root)
    end

    # Where the command was typed, which every command a fix gives runs from.
    def typed_dir
      @from&.to_s || app.root.to_s
    end

    def typed_at?(dir)
      SafePath.canonical(dir.to_s) == SafePath.canonical(typed_dir)
    end

    # A place a fix sends the reader - a folder a command runs in, a file to
    # edit - named from where doctor was typed, where the reader acts on it.
    # Inside the app that is not the app's root, which the rest of the
    # report names its files from.
    def fix_path(path)
      Install::Program.relative_to(path.to_s, typed_dir)
    end

    # A directory as a command typed where doctor was reaches it, ready for a shell.
    def shell_path(dir)
      CLI::AppRoot.command_line([ CLI::AppRoot.option_path(fix_path(dir)) ])
    end

    # One of the app's own commands, as typed where doctor was. Typed
    # anywhere but the folder it runs in - the app's root, or `dir` - it goes
    # there first: the binary with --app-path, anything else after a cd. A
    # folder inside the app is no exception: `bin/rails` is no file there,
    # and git reads a path from it. Bare, it ran in the wrong folder, or in
    # none.
    def in_app(command, dir: app.root.to_s)
      if command.start_with?("rails-ai-context ")
        return typed_app ? command.sub("rails-ai-context ", "rails-ai-context --app-path #{typed_app} ") : command
      end
      return command if typed_at?(dir)

      "cd #{shell_path(dir)} && #{command}"
    end

    # A git command run in the app's repository, from wherever doctor was
    # typed: outside the app, that place may be in no repository at all.
    def git_command(args)
      typed_app ? "git -C #{typed_app} #{args}" : "git #{args}"
    end

    def standalone?
      return @standalone if defined?(@standalone)

      @standalone = InstallMode.standalone?(root: app.root)
    end

    # A job on the install, as typed where it runs. At an engine's root,
    # where the rake tasks run in the dummy app as app:ai:*, that is the
    # binary - the engine's bundle's, or the standalone one - or the
    # generator, and the fix says where.
    def install_job(job)
      return "`#{command(job)}`" unless engine_install?

      "`#{InstallMode.command(job, form: InstallMode.form(root: install_root))}`#{at_engine}"
    end

    # Where the report's paths are named from: where the command was typed,
    # unless that is the app's root or a directory inside it, or the root of
    # the engine its test/dummy runs in or a directory inside that, where a
    # reader names those files from that root.
    def display_base
      @display_base ||= begin
        typed = SafePath.canonical(typed_dir)
        [ app.root.to_s, *PathResolver.enclosing_engine_roots(app.root.to_s) ]
          .find { |root| SafePath.contained?(typed, SafePath.canonical(root)) } || typed_dir
      end
    end

    # A path as the reader types it where the command was typed.
    def typed_path(path)
      Install::Program.relative_to(path.to_s, display_base)
    end

    # Where the engine an engine's test/dummy runs in is, as a place a
    # command runs: " at the engine's root" typed there or in a folder of
    # the engine's own, " in the engine at ../.." typed in the dummy app,
    # and as far up as it is from a folder inside the dummy app.
    def at_engine
      engines = PathResolver.enclosing_engine_roots(app.root.to_s)
      return "" if engines.empty?
      return " at the engine's root" if engines.include?(display_base)

      " in the engine at #{engines.map { |engine| fix_path(engine) }.join(', ')}"
    end

    # Where the install this app is served by lives: the app's root, or for
    # an engine's dummy app the engine's, where the installer run there puts
    # the MCP configs, .rails-ai-context.yml and the context files, and
    # where an editor opened at the engine runs every command. A dummy app
    # with an install of its own, and none at the engine's root, keeps its own.
    def install_root
      @install_root ||= begin
        root = app.root.to_s
        engine = PathResolver.enclosing_engine_roots(root).first
        engine && (installed_at?(engine) || !installed_at?(root)) ? engine : root
      end
    end

    def installed_at?(dir)
      [ Configuration::CONFIG_FILENAME, "config/initializers/rails_ai_context.rb" ].any? { |file| File.exist?(File.join(dir, file)) }
    end

    def engine_install?
      install_root != app.root.to_s
    end

    # The settings the install runs with: the app's, or at an engine's root
    # the .rails-ai-context.yml there, which is all its commands read - the
    # dummy app's configuration is not the engine's.
    def install_config
      @install_config ||= engine_install? ? config_at(install_root) : RailsAiContext.configuration
    end

    def config_at(dir)
      UnbootedSettings.read(dir).config
    end

    # All configured AI tools; nil (unconfigured) means every tool in the table.
    ALL_AI_TOOLS = Install::AiTool.all.map(&:key).freeze

    def configured_ai_tools
      install_config.ai_tools || ALL_AI_TOOLS
    end

    # ── Existence checks ──────────────────────────────────────────────

    def check_schema
      format, path = RailsAiContext::Introspectors::SchemaDumpPath.present(app.root)
      shown = typed_path(path) if path
      if format == :ruby
        lines = File.readlines(path).size
        Check.new(name: "Schema", status: :pass, message: "#{shown} found (#{count_phrase(lines, "line")})", fix: nil)
      elsif format == :sql
        size = (File.size(path) / 1024.0).round(1)
        Check.new(name: "Schema", status: :pass, message: "#{shown} found (#{size}KB)", fix: nil)
      else
        Check.new(name: "Schema", status: :warn, message: "No schema file found", fix: "Run `#{in_app("rails db:schema:dump")}`")
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
        AppDatabases.for(app.root).here.select(&:tasks).map do |db|
          dirs = db.primary ? primary_migrate_dirs : db.migrate_dirs
          { name: db.name, config: db.config, **db.pending_migrations(dirs) }
        end.reject { |state| AppDatabases::NotBooted === state[:error] || AppDatabases::InMemory === state[:error] }
      rescue StandardError => e
        RailsAiContext.debug_fail(e, [], label: "database_states")
      end
    end

    def unreachable_database_check(databases, pending)
      env = RailsAiContext.environment_name
      missing, failing = databases.select { |db| db[:error] }.partition { |db| db[:error].is_a?(AppDatabases::Missing) }
      shown = ->(db) { databases.one? ? database_named(db[:config]) : "#{db[:name]} (#{database_named(db[:config])})" }
      said = []
      if missing.any?
        said << "the #{env} #{missing.one? ? "database" : "databases"} #{missing.map(&shown).join(' and ')} " \
                "#{missing.one? ? "does" : "do"} not exist"
      end
      failing.each do |db|
        said << "the #{env} database #{shown.(db)} cannot be reached: #{first_error_line(db[:error].is_a?(AppDatabases::Unreachable) ? db[:error].reason : db[:error].message)}"
      end
      said << pending_phrase(pending, databases) if pending.any?

      fixes = []
      fixes << "Run `#{database_task("db:prepare")}`#{where_tasks_run}" if missing.any? || pending.any?
      unloaded, down = failing.partition { |db| db[:error].is_a?(AppDatabases::AdapterMissing) }
      fixes.concat(unloaded.map { |db| db[:error].advice.chomp(".") }.uniq)
      fixes << "Start the database server, or fix its settings in #{fix_path(File.join(app.root.to_s, "config/database.yml"))}" if down.any?
      Check.new(name: "Database", status: :fail, message: said.join("; "), fix: fixes.join("; "))
    end

    # A database task as typed where it runs: in an engine's test/dummy, at
    # the engine's root, whose db tasks add the engine's own migrations
    # (from the dummy itself, Rails lists them as NO FILE). The engine
    # forwards db:migrate to its dummy, and db:prepare only as app:db:prepare.
    def database_task(task)
      env = RailsAiContext.environment_name
      task = "app:#{task}" if task == "db:prepare" && engine_roots_shown.any?
      typed = "#{"RAILS_ENV=#{env} " unless env == "development"}bin/rails #{task}"
      # The engine's tasks say where they run in words (where_tasks_run).
      engine_roots_shown.any? ? typed : in_app(typed)
    end

    def where_tasks_run
      at_engine
    end

    # The engines an engine's test/dummy runs in, named from where doctor was
    # typed: ../.. from the dummy app, . at the engine's root.
    def engine_roots_shown
      @engine_roots_shown ||= PathResolver.enclosing_engine_roots(app.root.to_s).map { |engine| typed_path(engine) }
    end

    # A database as database.yml names it; a SQLite file given relative to
    # the app's root, as the adapter reads it, named from where doctor was typed.
    def database_named(db_config)
      name = db_config.database.to_s
      DatabaseFile.root_relative?(db_config) ? typed_path(File.expand_path(name, app.root.to_s)) : name
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
        Check.new(name: "Models", status: :warn, message: "No model files", fix: "Generate models with `#{in_app("rails generate model")}`")
      end
    end

    def check_routes
      routes_path = File.join(app.root, "config/routes.rb")
      if File.exist?(routes_path)
        Check.new(name: "Routes", status: :pass, message: "#{typed_path(routes_path)} found", fix: nil)
      else
        Check.new(name: "Routes", status: :fail, message: "#{typed_path(routes_path)} not found", fix: "Ensure you're in a Rails app root directory")
      end
    end

    # The bundle the tools read: the app's own lockfile, or with none, the
    # one its config/boot.rb names (a monorepo's shared Gemfile, an engine's
    # for its test/dummy), read inside the app's git repository only.
    def check_gems
      bundle = GemLock.bundle(app.root)
      if bundle.lockfile && File.file?(bundle.lockfile)
        Check.new(name: "Gems", status: :pass, message: "#{typed_path(bundle.lockfile)} found", fix: nil)
      elsif bundle.outside
        Check.new(name: "Gems", status: :warn, message: GemLock.for(app.root).reason, fix: nil)
      else
        Check.new(name: "Gems", status: :warn, message: "#{typed_path(lockfile_path(bundle))} not found",
          fix: "Run `#{in_app("bundle install", dir: bundle.dir)}`")
      end
    end

    # A bundle's lockfile, or where it goes: a shared Gemfile's that is not
    # there yet has no path of its own.
    def lockfile_path(bundle)
      bundle.lockfile || File.join(bundle.dir, File.basename(bundle.lock_label))
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
      dirs = PathResolver.view_dirs(app.root.to_s)
      if dirs.any?
        count = dirs.sum { |dir| PathResolver.glob(dir, "**/*").count { |path| File.file?(path) } }
        shown = dirs.map { |dir| typed_path(dir) }
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
        engine = typed_path(suite_root)
        where = if suite_root == app.root.to_s then ""
        elsif engine == "." then " (the engine's)"
        else " (the engine's, at #{engine})"
        end
        Check.new(name: "Tests", status: :pass, message: "#{suites.join(", ")} test suite found#{where}", fix: nil)
      elsif (unread = GemLock.for(app.root).unread_bundle) && TestFramework.unread_gemfile(app.root)
        Check.new(name: "Tests", status: :warn, message: "No test suite in the app, and #{unread}, so the suite there is not read", fix: nil)
      else
        Check.new(name: "Tests", status: :warn, message: "No test suite found",
          fix: "Run `#{in_app("rails generate rspec:install", dir: suite_root)}` or use default Minitest")
      end
    end

    # A kind of app code where the tools read it: SourceScan's directories,
    # and in an engine's test/dummy the engine's own, which the booted tools
    # load. [every file, the engine's]
    def source_file_counts(kind)
      own = Introspectors::SourceScan.paths(app.root, kind: kind, skip_concerns: false).count
      in_engine = PathResolver.enclosing_engine_roots(app.root.to_s).sum { |engine| Dir.glob(File.join(kind, "**", "*.rb"), base: engine).size }
      [ own + in_engine, in_engine ]
    end

    def engine_share(count)
      return "" unless count.positive?

      engine_roots_shown == [ "." ] ? " (#{count} in the engine)" : " (#{count} in the engine at #{engine_roots_shown.join(', ')})"
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
      databases = AppDatabases.for(app.root)
      { databases.primary&.name || "primary" => primary_migrate_dirs }.merge(databases.secondaries.to_h { |db| [ db.name, db.migrate_dirs ] })
    end

    # ── Context file checks ───────────────────────────────────────────

    # Each tool's context files and rule directories, and the files it no longer writes.
    CONTEXT_PATHS = Install::AiTool.all.to_h { |tool| [ tool.key, tool.owned_paths ] }.freeze

    # Where each tool's MCP config lives, and how to name it in a report.
    MCP_CONFIG_CHECKS = Install::AiTool.all.to_h { |tool|
      path = tool.mcp_config[:path]
      [ tool.key, { path: path, name: tool.name, label: "#{path} (#{tool.name})", folder_variable: tool.mcp_config[:folder_variable] }.freeze ]
    }.freeze
    private_constant :MCP_CONFIG_CHECKS

    def self.mcp_config_checks = MCP_CONFIG_CHECKS

    def check_context_freshness
      # An MCP-only install asked for no context files, so their absence is
      # the configuration working, not something to fix.
      return nil unless install_config.context_files

      # Where the files are written: config.output_dir, else the install's root.
      output_dir = install_config.output_dir || install_root
      present = configured_ai_tools.flat_map { |tool| CONTEXT_PATHS.fetch(tool, []) }.uniq
        .select { |relative| File.exist?(File.join(output_dir, relative)) }
      if present.empty?
        # Nor where the plugin is the only choice, which brings the rules itself; files
        # the app has still go stale, so only their absence passes.
        return nil if install_config.ai_tools.nil? && plugin_choice?

        return Check.new(name: "Context files", status: :warn,
          message: "No context files generated#{at_engine if engine_install?}",
          fix: "Run #{install_job(:context)}")
      end

      # A context file is stale when the run the fix names would rewrite it,
      # which is never true of a file that run leaves alone however old it
      # is, and always true of one an older version of the gem wrote.
      run = context_file_run(output_dir)
      # Named from where doctor was typed, or in full for an output_dir outside the install's root.
      inside = SafePath.inside?(output_dir.to_s, install_root)
      first = ->(files) { inside ? typed_path(File.join(output_dir, files.first)) : File.join(output_dir, files.first) }
      shown = ->(files) { "#{first.(files)}#{" and #{count_phrase(files.size - 1, "more context file")}" if files.size > 1}" }
      if run[:error]
        return Check.new(name: "Context files", status: :warn,
          message: "#{shown.(present)}: a dry run of #{install_job(:context)} failed, so whether " \
                   "#{present.one? ? "it is" : "they are"} up to date is not known (#{run[:error]})",
          fix: "Run #{install_job(:context)} to see what it says")
      end

      stale = run[:written]
      if stale.empty?
        fresh = run[:skipped].presence || present
        return Check.new(name: "Context files", status: :pass,
          message: "#{shown.(fresh)} #{fresh.one? ? "is" : "are"} up to date", fix: nil)
      end

      Check.new(name: "Context files", status: :warn,
        message: "#{shown.(stale)} #{stale.one? ? "is" : "are"} out of date: #{staleness_reason(output_dir, stale)}",
        fix: "Run #{install_job(:context)} to regenerate")
    end

    # The context files run through the writers the context command runs,
    # into a copy of them, so the copy says which files that run would
    # rewrite and nothing in the app is touched. Paths relative to the
    # output directory; the JSON dump is no AI tool's file.
    #
    # @return [Hash] { written: [paths a run rewrites], skipped: [paths it leaves] }, or { error: why }
    def context_file_run(output_dir)
      config = RailsAiContext.configuration
      Dir.mktmpdir("rails-ai-context-doctor") do |scratch|
        copy_context_files(output_dir, scratch)
        next context_command_run(output_dir, scratch) if engine_install?

        previous = config.output_dir
        result = begin
          config.output_dir = scratch
          RailsAiContext.generate_context(app, context: introspection)
        ensure
          config.output_dir = previous
        end
        # A file the run would remove, or take its block out of, changes as a rewrite does.
        changed = result.values_at(:written, :removed, :trimmed).flatten.compact
        { written: changed, skipped: result[:skipped] }.transform_values do |paths|
          paths.map { |path| path.delete_prefix("#{scratch}/") } - [ ".ai-context.json" ]
        end
      end
    end

    # How long the context command gets at an engine's root, where it runs
    # as its own process: it reads the engine's source and boots nothing.
    CONTEXT_RUN_SECONDS = 120

    # At an engine's root the context command is the binary run there, which
    # reads the engine's source with no app booted - not what this process,
    # the dummy app booted, would write. So that command itself runs, into
    # the copy, and a file whose bytes it changed is one a run would rewrite.
    def context_command_run(output_dir, scratch)
      env = {}
      form = InstallMode.form(root: install_root)
      env["BUNDLE_GEMFILE"] = GemLock.bundle(install_root).gemfile.to_s if form == :bundled
      argv = InstallMode.command(:context, form: form).split + [ "--no-mcp-refresh", "--output-dir", scratch ]
      log = File.join(scratch, ".rails-ai-context-doctor.log")
      run = -> { Process.spawn(env, *argv, chdir: install_root, in: File::NULL, out: log, err: log) }
      pid = defined?(Bundler) && Bundler.respond_to?(:with_unbundled_env) ? Bundler.with_unbundled_env(&run) : run.call
      status = wait_for(pid, CONTEXT_RUN_SECONDS)
      unless status&.success?
        said = File.exist?(log) ? File.readlines(log, chomp: true).map(&:strip).reject(&:empty?).last : nil
        return { error: status ? first_error_line(said || "it exited #{status.exitstatus}") : "no answer in #{CONTEXT_RUN_SECONDS} seconds" }
      end

      # The app's files too: one the run removed is in the app and not the copy.
      files = configured_ai_tools.flat_map { |tool| CONTEXT_PATHS.fetch(tool, []) }.uniq
        .flat_map { |relative| files_under(scratch, relative) + files_under(output_dir, relative) }.uniq
      written, skipped = files.partition { |relative| !same_file?(File.join(scratch, relative), File.join(output_dir, relative)) }
      { written: written, skipped: skipped }
    rescue SystemCallError => e
      { error: e.message }
    end

    # A process's status once it ends, or nil when it has not by then, when
    # it is killed: a context run that hangs must not hold doctor open.
    def wait_for(pid, seconds)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
      loop do
        _, status = Process.waitpid2(pid, Process::WNOHANG)
        return status if status
        break if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

        sleep 0.1
      end
      Process.kill("KILL", pid)
      Process.waitpid(pid)
      nil
    rescue Errno::ESRCH, Errno::ECHILD
      nil
    end

    # A context path's files, relative to the directory it sits in: the file
    # itself, or every file a rule directory holds.
    def files_under(dir, relative)
      path = File.join(dir, relative)
      return [ relative ] if File.file?(path)

      Dir.glob("**/*", File::FNM_DOTMATCH, base: path).select { |file| File.file?(File.join(path, file)) }.map { |file| File.join(relative, file) }
    end

    def same_file?(one, other)
      File.file?(one) && File.file?(other) && FileUtils.compare_file(one, other)
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
      changed = oldest ? Fingerprinter.changed_since(install_root, oldest).reject { |dir| only_our_initializer_newer?(dir, oldest) } : []
      changed = changed.map { |dir| typed_path(File.join(install_root, dir)) }
      return "#{changed.join(', ')} changed since #{stale.one? ? "it was" : "they were"} written" if changed.any?

      "a regeneration would write #{stale.one? ? "it" : "them"}"
    end

    # Install writes our initializer in the same run that generates the
    # context files, so on its own it never explains a stale one.
    def only_our_initializer_newer?(dir, generated_at)
      return false unless dir == "config"

      newer = PathResolver.glob(File.join(install_root, dir), Fingerprinter::WATCHED_EXTENSIONS)
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
          message: "#{typed_path(path)} has no recognised guard around the `configure` block",
          fix: "Wrap it in `if defined?(RailsAiContext) && RailsAiContext.respond_to?(:configure)` - " \
               "without one it raises where the gem is not loaded, such as standalone mode or a group-scoped Gemfile entry")
      end
      return nil unless Install::InitializerFile.bare_guard?(content)

      Check.new(name: "Initializer guard", status: :warn,
        message: "#{typed_path(path)} guards on `defined?(RailsAiContext)` alone",
        fix: "Re-run `#{command(:install)}`, or add `&& RailsAiContext.respond_to?(:configure)` to the guard")
    end

    # A line of the app's Ruby that no tier without a boot can follow, with what answers in its place.
    def check_settings_read
      notes = UnbootedSettings.read(app.root).notes
      return nil if notes.empty?

      Check.new(name: "Settings read without a boot", status: :warn, message: notes.join("; "),
                fix: "Write the value as a literal, or set it in .rails-ai-context.yml, which every tier reads")
    end

    # One MCP config's answer. A config with a `problem` is named beside it in
    # the summary, and configs that share one are named together. `unmergeable`
    # is unmergeable_fix's item for a config the install cannot merge into.
    ConfigVerdict = Data.define(:label, :status, :problem, :fix, :unmergeable) do
      def initialize(unmergeable: nil, **rest)
        super(unmergeable: unmergeable, **rest)
      end
    end

    def check_mcp_json
      # CLI-only mode writes no MCP config, which leaves the plugin's server to Claude Code.
      cli = install_config.tool_mode == :cli
      if cli && !plugin_choice?
        return Check.new(name: "MCP configs", status: :pass,
          message: "Skipped (CLI-only mode)", fix: nil)
      end

      verdicts = (cli ? [ [ :claude, false ] ] : mcp_tools_to_check).filter_map { |tool, optional| mcp_config_verdict(tool, optional: optional) }
      failures = verdicts.reject { |verdict| verdict.status == :pass }

      if failures.empty?
        plugin = verdicts.find { |verdict| verdict.label == CLAUDE_PLUGIN_LABEL }
        note = typed_session_note if plugin
        return Check.new(name: "MCP configs", status: :pass,
          message: "#{verdicts.size} of #{count_phrase(verdicts.size, "MCP config")} valid#{": #{plugin.label}" if plugin}#{"; #{note}" if note}",
          fix: nil)
      end

      said = failures.group_by(&:problem).map do |problem, group|
        labels = group.map(&:label).join(", ")
        problem ? "#{labels}: #{problem}" : labels
      end
      unmergeable, others = failures.partition(&:unmergeable)
      fixes = if unmergeable.size > 1
        [ unmergeable_fix(unmergeable.map(&:unmergeable)), *others.filter_map(&:fix) ].uniq
      else
        failures.filter_map(&:fix).uniq
      end
      Check.new(name: "MCP configs", status: failures.any? { |verdict| verdict.status == :fail } ? :fail : :warn,
        message: "#{failures.size} of #{count_phrase(verdicts.size, "MCP config")} #{failures.size == 1 ? "needs" : "need"} " \
                 "attention: #{said.join('; ')}",
        fix: fixes.join("; "))
    end

    # Each config to judge, with whether it counts only when broken: Claude Code's always counts where the
    # plugin is chosen, and with no AI tools chosen the plugin is the choice, so the others count only when broken.
    def mcp_tools_to_check
      plugin = plugin_choice?
      if install_config.ai_tools.nil? && plugin
        return [ [ :claude, false ], *(self.class.mcp_config_checks.keys - %i[claude]).map { |tool| [ tool, true ] } ]
      end

      tools = configured_ai_tools & self.class.mcp_config_checks.keys
      tools |= %i[claude] if plugin
      (tools.empty? ? %i[claude] : tools).map { |tool| [ tool, false ] }
    end

    CLAUDE_PLUGIN_LABEL = "the rails-ai-context plugin (Claude Code)"
    # A local marketplace's folder, once gone, is added again from wherever it now is.
    MARKETPLACE_READD = "add the marketplace again from its folder with `claude plugin marketplace add <folder>`"
    # One that is there but lacks the plugin needs a checkout that has it; added again as it is, it still lacks it.
    MARKETPLACE_UPDATE = "check out a version that has plugins/rails-ai-context, or add the marketplace from one that does"

    # The config a tool reads for this app, judged as the install would merge
    # into it and as its client would start the server it names; nil for an
    # optional one with nothing of the gem's in it.
    def mcp_config_verdict(tool, optional: false)
      cfg = self.class.mcp_config_checks[tool]
      install_fix = "Run #{install_job(:install)} to fix"
      # An app in a workspace is served from the folder above it, whose
      # config, if it cannot be read, is the one to fix.
      full_path = mcp_config_path(tool)
      label = "#{typed_path(full_path)} (#{cfg[:name]})"
      plugin = tool == :claude && claude_code.plugin_chosen?
      # A session started in the config's folder is the one this config serves.
      folder = mcp_config_folder(tool, full_path)
      broken = tool == :claude ? claude_code.broken_managed_files : []
      if broken.any?
        return ConfigVerdict.new(label: "#{broken.join(", ")} (Claude Code)", status: :fail,
                                 problem: "Claude Code will not start until #{broken.join(" and ")} #{broken.one? ? "is" : "are"} fixed",
                                 fix: "Ask whoever manages your Claude Code settings to fix #{broken.one? ? "it" : "them"}")
      end
      return claude_managed_mcp_verdict(folder) if tool == :claude && claude_code.managed_mcp

      # Unread, Claude Code's own config may hold a plugin or server that doubles this one.
      unread = tool == :claude && ClaudeCodeSettings.relative_config_dir?
      return claude_config_dir_verdict(CLAUDE_PLUGIN_LABEL) if unread && plugin
      # Typed above the app, a session started there never reads the app's own .mcp.json: where it enables
      # the plugin, which does not run there, and no .mcp.json it reads serves the app, it has no server.
      if tool == :claude && typed_above_app? && claude_code.plugin_chosen_in?(typed_dir) && !claude_code.plugin_on_in?(typed_dir) && !served_from?(typed_dir)
        return claude_plugin_missing(label, typed_dir)
      end

      # The install writes no Claude Code server where the committed settings turn the plugin on.
      committed = tool == :claude && claude_code.committed_in?(folder)

      missing = lambda do
        return nil if optional
        return claude_config_dir_verdict(label) if unread
        return claude_plugin_missing(label, folder) if plugin

        turned_off = claude_plugin_turned_off(folder) if tool == :claude && claude_code.committed_in?(folder)
        turned_off || ConfigVerdict.new(label: label, status: :warn, problem: nil, fix: install_fix)
      end
      return missing.call unless File.exist?(full_path)

      # Where the install would leave the file, or the gem's entry in it, as
      # it is, the edit by hand it names instead is the fix: sent to run the
      # install, the reader was told the same thing again.
      verdict = install_verdict(tool, full_path)
      shape = nil
      by_hand = nil
      if cfg[:path].end_with?(".toml")
        hand = toml_by_hand(verdict, full_path)
        unless verdict.readable
          return ConfigVerdict.new(label: label, status: :fail, problem: verdict.reason,
                                   fix: hand || "Run #{install_command(full_path)} to fix")
        end
        if verdict.action == :refuse
          shape = [ :warn, verdict.reason, hand ]
          by_hand = "#{hand}: #{verdict.reason}"
        end
      else
        # An empty file is one install fills.
        return missing.call if verdict.action == :write

        unless verdict.readable
          # Saved or mended, the next install merges into it. Where the committed settings turn the plugin on, it never
          # does, and a file that does not name the gem holds no server of it to remove.
          after = if !committed then :run
          elsif claude_code.plugin_on_in?(folder) && File.binread(full_path).include?(McpConfigGenerator::SERVER_NAME)
            :remove
          end
          item = [ verdict, full_path, after ]
          return ConfigVerdict.new(label: label, status: :fail, problem: verdict.reason, fix: unmergeable_fix([ item ]), unmergeable: item)
        end
        by_hand = "#{verdict.by_hand(fix_path(full_path))}: #{verdict.reason}, so the install leaves it as it is" if verdict.action == :refuse
      end

      entries = serving_entries(verdict, tool, full_path)
      # Claude Code never starts a server its MCP policy blocks.
      blocked, entries = entries.partition { |entry| claude_code.server_block(entry[:name], entry[:argv].map(&:to_s), folder, url: remote_url(entry, folder)) } if tool == :claude
      return missing.call if entries.empty? && (plugin || optional || committed)
      return claude_server_blocked(label, blocked.first, folder) if entries.empty? && blocked&.any?
      if entries.empty?
        return ConfigVerdict.new(label: label, status: :warn, problem: shape&.[](1) || "holds no rails-ai-context server",
                                 fix: shape&.[](2) || by_hand || install_fix)
      end

      # An entry under the gem's name that runs something else (an HTTP one)
      # is its owner's to judge. Where the plugin serves, a broken entry is one more server to remove.
      troubles = entries.select { |entry| entry[:own] }.filter_map do |entry|
        hand = committed_fix(entry[:name], full_path, folder) if committed
        # The install rewrites only the names it writes, so a hand-named entry is mended by hand.
        hand ||= "Fix or remove `#{entry[:name]}` in #{fix_path(full_path)} by hand" if entry[:hand]
        trouble = entry_trouble(entry, tool, full_path, by_hand || hand)
        trouble && committed && claude_code.plugin_on_in?(folder) ? [ :warn, trouble[1], hand ] : trouble
      end
      status, problem, fix = [ *troubles, shape ].compact.min_by { |trouble| trouble.first == :fail ? 0 : 1 }
      if status.nil? && tool == :claude && claude_code.plugin?
        verdict = claude_plugin_verdict(label)
        # Passing where the plugin runs, every entry here is off or blocked and the plugin is what serves.
        return verdict.status == :pass && claude_code.plugin_on_in?(folder) ? verdict.with(label: CLAUDE_PLUGIN_LABEL) : verdict
      end
      return claude_config_dir_verdict(label) if status.nil? && unread

      ConfigVerdict.new(label: label, status: status || :pass, problem: problem, fix: fix)
    rescue SystemCallError, IOError => e
      ConfigVerdict.new(label: label, status: :warn, problem: "cannot be read: #{e.message}", fix: install_fix)
    end

    # What the install's write does with this config, as it would run for this app. In a workspace's config the
    # app's entry keeps the name it has there, which only the write's own read of the file says.
    def install_verdict(tool, path)
      writer = ->(name) { McpConfigGenerator.new(tools: [ tool ], output_dir: mcp_config_folder(tool, path), servers: [ install_server(tool, path, name) ]) }
      verdict = writer.(nil).verdict(tool, path)
      return verdict unless workspace_config?(path)

      name = serving_entries(verdict, tool, path).first&.dig(:name)
      name ? writer.(name).verdict(tool, path) : verdict
    end

    # A Codex config's edit by hand, with the install run that then keeps the entry current, where one does.
    def toml_by_hand(verdict, path)
      hand = verdict.by_hand(fix_path(path), next_run: false)
      hand && verdict.next_run ? "#{hand} and run #{install_command(path)}" : hand
    end

    # The server the install writes for this app into a config: the app's
    # own, in the form its bundle calls for, or in a workspace's config the
    # app's entry there, under `name` where it has one.
    def install_server(tool, path, name = nil)
      standalone = InstallMode.standalone?(root: install_root)
      return McpConfigGenerator::Server.new(name: McpConfigGenerator::SERVER_NAME, standalone: standalone) unless workspace_config?(path)

      app = Install::Workspace.apps(mcp_config_folder(tool, path), [ install_root ]).first
      app.server_name = name if name
      app.server
    end

    # The edits configs the install cannot merge into need, in one sentence:
    # files needing the same edit named together, then what follows it.
    # `items` are [verdict, path, after], `after` :run, :remove or nil.
    def unmergeable_fix(items)
      items.group_by(&:last).map do |after, group|
        edits = group.group_by { |verdict, _, _| verdict.by_hand("\0", next_run: false) }.values.map do |same|
          same.first.first.by_hand(same.map { |_, path, _| fix_path(path) }.join(", "), next_run: false)
        end
        them = group.one? ? "it" : "them"
        tail = case after
        when :run
          run = group.any? { |_, path, _| workspace_config?(path) } ? "`rails-ai-context init` in the folder that holds #{them}" : install_job(:install)
          ", then run #{run}"
        when :remove then ", then remove the gem's server from #{them}; the rails-ai-context plugin serves this app"
        end
        "#{edits.first}#{edits.drop(1).map { |edit| " and #{edit.sub(/\A\w/, &:downcase)}" }.join}#{tail}"
      end.join("; ")
    end

    def mcp_config_path(tool)
      McpConfigGenerator.serving_config(install_root, tool) || McpConfigGenerator.unreadable_config_above(install_root, tool) ||
        File.join(install_root, self.class.mcp_config_checks[tool][:path])
    end

    def claude_code
      @claude_code ||= ClaudeCodeSettings.new(install_root, from: typed_dir)
    end

    def typed_above_app?
      typed = SafePath.canonical(typed_dir)
      root = SafePath.canonical(install_root)
      typed != root && SafePath.contained?(root, typed)
    end

    # Whether a .mcp.json a session started in that folder reads, there or above, runs a server of the gem's for this app.
    def served_from?(folder)
      dir = File.expand_path(folder)
      loop do
        path = File.join(dir, ".mcp.json")
        return true if File.file?(path) && claude_code.gem_server_names(path, folder).any?
        return false if File.dirname(dir) == dir

        dir = File.dirname(dir)
      end
    end

    # A session started where doctor was typed, inside the app, is one the plugin that passes may not reach.
    def typed_session_note
      typed = SafePath.canonical(typed_dir)
      inside = [ app.root.to_s, install_root ].any? { |root| SafePath.contained?(typed, SafePath.canonical(root)) }
      return nil if !inside || claude_code.plugin_on_in?(typed_dir)

      steps = claude_plugin_switch_on(typed_dir)
      "a session started here would not run it: #{steps}" unless steps.empty?
    end

    # The install writes no Claude Code server where the committed settings turn the plugin on, so a .mcp.json entry is fixed
    # by hand: removed where the plugin runs, else mended or the plugin turned back on.
    def committed_fix(name, path, folder)
      return "Remove `#{name}` from #{fix_path(path)}; the rails-ai-context plugin serves this app" if claude_code.plugin_on_in?(folder)

      on = claude_plugin_turned_off(folder)&.fix || claude_plugin_switch_on(folder, claude_code.committed_id(folder))
      "Fix `#{name}` in #{fix_path(path)} by hand#{", or #{on.sub(/\A\w/, &:downcase)}" unless on.empty?}"
    end

    # The Claude Code plugin is the app's choice where a session enables it,
    # or where its committed settings do, whatever one user turned off.
    def plugin_choice?
      claude_code.plugin_chosen? || claude_code.committed_in?(install_root)
    end

    # Where the plugin is the app's choice and no .mcp.json entry serves the app: running here, only elsewhere,
    # or what stops it, most basic first. The install's own fix would add the second server the plugin replaces.
    def claude_plugin_missing(label, folder)
      warning = ->(problem, fix) { ConfigVerdict.new(label: CLAUDE_PLUGIN_LABEL, status: :warn, problem: problem, fix: fix) }
      return claude_plugin_verdict(CLAUDE_PLUGIN_LABEL) if claude_code.plugin_on_in?(folder)
      return claude_plugin_elsewhere(label, folder) if claude_code.plugin?

      if (id = claude_code.uninstalled_plugin_id)
        if (gone = claude_code.missing_marketplace(id, folder))
          return warning.("Claude Code loads the plugin from #{gone}, which is gone", MARKETPLACE_READD.sub(/\A\w/, &:upcase))
        end
        if (bare = claude_code.marketplace_without_plugin(id, folder))
          return warning.("the marketplace at #{bare} has no rails-ai-context plugin", MARKETPLACE_UPDATE.sub(/\A\w/, &:upcase))
        end
        return warning.("enabled for this app but not installed on this machine", "Run #{plugin_install_command(id)}")
      end
      if (blocked = claude_code.blocked_plugin)
        problem = blocked.rule == :marketplace ? "Claude Code's managed marketplace policy keeps it from loading" : "Claude Code's MCP policy keeps its server from starting"
        return warning.(problem, plugin_policy_fix(blocked))
      end

      off = one_per_project(claude_code.plugin_off_sessions)
      step = "Turn the plugin's server back on with /mcp in a session started #{started_in(off)}"
      return warning.("its server is turned off in /mcp", step) if off.any? { |session| SafePath.canonical(session) == SafePath.canonical(folder) }

      here = claude_plugin_switch_on(folder, claude_code.switched_off_plugin_id)
      warning.("its server is turned off in /mcp", here.empty? ? step : "#{step}, or #{here}")
    end

    # Where managed-mcp.json is deployed, Claude Code starts its servers and
    # no other, neither the plugin's nor one in any .mcp.json.
    def claude_managed_mcp_verdict(folder)
      managed = claude_code.managed_mcp
      label = "#{managed} (Claude Code)"
      held = claude_code.managed_servers(folder)
      servers = ClaudeCodeSettings.read_json(managed)&.dig("mcpServers")
      servers = {} unless servers.is_a?(Hash)
      # The one that starts is judged as a .mcp.json entry is, and only whoever manages the file can edit it;
      # an HTTP entry is its endpoint's to judge.
      if (name, _, _, url = held.find { |_, why, _| why.nil? })
        return ConfigVerdict.new(label: label, status: :pass, problem: nil, fix: nil) if url

        server = servers[name]
        env = server.is_a?(Hash) && server["env"].is_a?(Hash) ? server["env"].transform_values(&:to_s) : {}
        entry = { name: name, argv: McpConfigGenerator.json_argv(server).map(&:to_s), env: env, own: true }
        status, problem, fix = entry_trouble(entry, :claude, managed, by_settings("fix `#{name}` in #{managed}", :managed).sub(/\A\w/, &:upcase), folder: folder)
        return ConfigVerdict.new(label: label, status: status || :pass, problem: problem, fix: fix)
      end

      name, (rule, scope), command, url = held.first
      if name
        problem = "Claude Code does not start `#{name}`, its server for this app: #{rule == :off ? "/mcp turned it off" : "the MCP policy keeps it off"}"
        fix = rule == :off ? "Turn `#{name}` back on with /mcp in a session started #{started_in([ folder ])}" : policy_fix(rule, scope, name, command, folder, url: url)
        return ConfigVerdict.new(label: label, status: :warn, problem: problem, fix: fix)
      end

      # Beside another app's server, an entry naming no app would start there too, so this one names the app, under a free name.
      argv = %w[rails-ai-context serve]
      name = McpConfigGenerator::SERVER_NAME
      if servers.key?(name) || servers.any? { |_, server| McpConfigGenerator.json_argv(server).any? { |arg| File.basename(arg.to_s.tr("\\", "/"), ".*") == name } }
        argv += [ "--app-path", install_root ]
        base = name = Install::Workspace.server_names([ File.basename(install_root) ]).values.first
        number = 1
        name = "#{base}-#{number += 1}" while servers.key?(name)
      end
      argv = McpConfigGenerator.platform_argv(argv)
      entry = JSON.generate(name => { "command" => argv.first, "args" => argv.drop(1) })
      ConfigVerdict.new(label: label, status: :warn,
                        problem: "it names every MCP server Claude Code starts on this machine, and none of them serves this app",
                        fix: "Have whoever manages your Claude Code settings add #{entry} to its mcpServers")
    end

    # Empty or relative, CLAUDE_CONFIG_DIR has Claude Code read its settings and plugins under
    # whatever folder a session starts in, so nothing here says what a session runs.
    def claude_config_dir_verdict(label)
      value, source = ClaudeCodeSettings.config_dir_setting
      where = source ? " in the env block of #{source}" : ""
      problem = if value.empty?
        "CLAUDE_CONFIG_DIR#{where} is set but empty, so Claude Code reads its settings and plugins from whatever folder a session starts in"
      else
        "CLAUDE_CONFIG_DIR (`#{value}`)#{where} is not an absolute path, so Claude Code reads its settings and plugins from that path " \
          "under whatever folder a session starts in"
      end
      fix = if source then "set CLAUDE_CONFIG_DIR#{where} to the absolute path of the folder Claude Code keeps its settings in, or remove it"
      elsif value.empty? then "unset CLAUDE_CONFIG_DIR, or set it to the absolute path of the folder Claude Code keeps its settings in"
      else "set CLAUDE_CONFIG_DIR to the absolute path of the folder Claude Code keeps its settings in"
      end
      managed = source && ClaudeCodeSettings.managed_files(ClaudeCodeSettings::MANAGED_SETTINGS).include?(source)
      ConfigVerdict.new(label: label, status: :warn, problem: problem, fix: by_settings(fix, managed ? :managed : :user).sub(/\A\w/, &:upcase))
    end

    # The committed settings turn the plugin on and winning ones turn it off for this user, where the
    # install writes no server, so its fix would change nothing.
    def claude_plugin_turned_off(folder)
      id = claude_code.committed_id(folder)
      verdict = claude_code.serving(folder)
      return nil unless verdict.cause == :turned_off

      scope = verdict.scope
      path = verdict.path

      # Not installed for that folder, the local install turns it on as well.
      fix = if scope == :managed then "Have whoever manages your Claude Code settings turn it on"
      elsif claude_code.installed_in?(id, folder) then "Run `claude plugin enable #{id} --scope local`#{run_in([ folder ])}"
      else "Run #{plugin_install_command(id, scope: "local")}#{run_in([ folder ])}"
      end
      named = settings_named(scope, path)
      ConfigVerdict.new(label: CLAUDE_PLUGIN_LABEL, status: :warn,
                        problem: "the app's .claude/settings.json turns it on, and #{named} #{scope == :local ? "turns" : "turn"} it off for you",
                        fix: fix)
    end

    # A server of the app's that Claude Code's MCP policy keeps from starting.
    def claude_server_blocked(label, entry, folder)
      argv = entry[:argv].map(&:to_s)
      url = remote_url(entry, folder)
      rule, scope = claude_code.server_block(entry[:name], argv, folder, url: url)
      ConfigVerdict.new(label: label, status: :warn, problem: "Claude Code's MCP policy keeps `#{entry[:name]}` from starting",
                        fix: policy_fix(rule, scope, entry[:name], argv, folder, url: url))
    end

    # The url a remote entry connects at from that folder, nil for a stdio one.
    def remote_url(entry, folder)
      claude_code.server_url(entry[:url], folder) if entry[:url]
    end

    # The change that lets the server start, in the settings that hold the rule: every deny that
    # names it, the plugin where only plugins may start, or the allowlist entry that admits it
    # without turning every other stdio server to matching by command.
    def policy_fix(rule, scope, name, command, folder, plugin: false, url: nil)
      case rule
      when :denied
        claude_code.deny_rules(name, command, folder, url: url).group_by { |where, _, path| [ where, settings_named(where, path) ] }.map do |(where, named), rules|
          by_settings("remove #{rules.map { |_, entry| JSON.generate(entry) }.join(" and ")} from deniedMcpServers in #{named}", where)
        end.join(", and ").sub(/\A\w/, &:upcase)
      when :locked
        "Run #{plugin_install_command(claude_code.enabled_plugin_id || "rails-ai-context@rails-ai-context")}, whose server this lock still starts, " \
          "or have whoever manages your Claude Code settings lift strictPluginOnlyCustomization's mcp lock, which lets only plugin and managed servers start"
      else
        by_command = claude_code.allowlist_by_command?(folder)
        # Once a list matches a url, a remote server is admitted by its url alone, so a name is offered while none does.
        entry = if url && (claude_code.allowlist_by_url?(folder) || !name.match?(/\A[A-Za-z0-9_-]+\z/)) then JSON.generate("serverUrl" => url)
        elsif url then JSON.generate("serverName" => name)
        elsif plugin || by_command || !name.match?(/\A[A-Za-z0-9_-]+\z/)
          command ? JSON.generate("serverCommand" => command) : "an entry naming the command that starts it"
        else
          JSON.generate("serverName" => name)
        end
        note = plugin && command && !by_command ? ", and a serverCommand entry for each stdio server it admits by name, since then every one matches by command" : ""
        by_settings("add #{entry} to allowedMcpServers in #{settings_named(scope, claude_code.allowlist_file(folder))}#{note}", scope).sub(/\A\w/, &:upcase)
      end
    end

    # What lets the plugin's server start where a block holds it.
    def plugin_policy_fix(blocked)
      return marketplace_fix(blocked) if blocked.rule == :marketplace

      policy_fix(blocked.rule, blocked.scope, ClaudeCodeSettings::PLUGIN_SERVER, blocked.command, blocked.folder, plugin: true)
    end

    # A managed marketplace gate, which only whoever manages the settings can open, in the file that sets it.
    # shortcut: a file holding both gates is read as the blocklist's, though only its allowlist may hold the marketplace back;
    # name the key the block came from once Blocked carries it.
    def marketplace_fix(blocked)
      marketplace = blocked.id.split("@", 2).last
      data = ClaudeCodeSettings.read_json(blocked.path) || {}
      step = if Array(data["blockedMarketplaces"]).any?
        "take the entry that names the #{marketplace} marketplace out of blockedMarketplaces in #{blocked.path}"
      else
        "add the #{marketplace} marketplace's source to #{data.key?("strictKnownMarketplaces") ? "strictKnownMarketplaces" : "allowedMarketplaces"} in #{blocked.path}"
      end
      by_settings(step, :managed).sub(/\A\w/, &:upcase)
    end

    # A change in managed settings is for whoever manages them to make.
    def by_settings(step, scope)
      scope == :managed ? "have whoever manages your Claude Code settings #{step}" : step
    end

    # A project or local file by its path from where doctor ran, which may be a parent folder's or the repository's.
    def settings_named(scope, path)
      case scope
      when :user then "your user settings"
      when :managed then "the managed settings"
      else fix_path(path)
      end
    end

    # Claude Code's verdict where the plugin serves the app: a pass, unless a
    # server of the gem's that a session also starts would list every tool again.
    def claude_plugin_verdict(label)
      problem, fix = duplicates_said
      ConfigVerdict.new(label: label, status: problem ? :warn : :pass, problem: problem, fix: fix)
    end

    # [problem, fix] for the gem's servers beside the plugin's, nil where none: a committed plugin's .mcp.json
    # entry goes, while one user's plugin turns the team's entry off for that user alone.
    def duplicates_said(disable: true)
      duplicates = claude_code.duplicates
      return nil if duplicates.empty?

      places, removals = duplicates.map do |dup|
        case dup.scope
        when :project
          committed = dup.sessions.all? { |session| claude_code.committed_in?(session) }
          [ "`#{dup.name}` in #{typed_path(dup.config)}",
            committed ? "remove `#{dup.name}` from #{fix_path(dup.config)}" : "turn `#{dup.name}` off with /mcp in a session started #{started_in(one_per_project(dup.sessions))}" ]
        when :user then [ "the user scope server `#{dup.name}`", "run `claude mcp remove #{dup.name} -s user`" ]
        else [ "the local scope server `#{dup.name}`", "run `claude mcp remove #{dup.name} -s local`#{run_in([ dup.key ])}" ]
        end
      end.transpose.map(&:uniq)
      # Claude Code starts one server per name in a session, from the scope that wins.
      sessions = duplicates.flat_map { |dup| dup.sessions.map { |session| [ session, dup.name ] } }.uniq.map(&:first)
      times = sessions.tally.values.max + 1
      problem = "#{places.join(" and ")} #{places.one? ? "runs" : "run"} the server beside the rails-ai-context plugin, " \
                "so Claude Code lists every tool #{times == 2 ? "twice" : "#{times} times"}"
      fix = removals.join(" and ").sub(/\A\w/, &:upcase)
      disables = plugin_disables(sessions) if disable
      [ problem, disables ? "#{fix}, or #{disables}" : fix ]
    end

    # Turning the plugin off instead, unless a session would keep two servers or managed settings turn it
    # on: one `--scope local` per repository, for every id it runs under there, since any one starts it.
    def plugin_disables(sessions)
      return nil unless sessions.tally.values.all?(1)
      return nil if sessions.any? { |session| claude_code.plugin_ids_in(session).any? { |id| claude_code.managed_in?(id, session) } }

      # Run where a session that enables it starts: Claude Code reads the setting there, and writes the local file that wins there.
      projects = sessions.group_by { |session| claude_code.local_settings_dir(session) }
                         .map { |_, group| [ group.first, group.flat_map { |session| claude_code.plugin_ids_in(session) }.uniq ] }
      projects.group_by(&:last).map do |ids, pairs|
        "run #{ids.map { |id| "`claude plugin disable #{id} --scope local`" }.join(" and ")}#{run_in(pairs.map(&:first))}"
      end.join(" and ")
    end

    # One session folder per project: a /mcp switch is kept for the whole
    # project, and only a session that loads the server can flip it.
    def one_per_project(sessions)
      sessions.group_by { |session| claude_code.project_of(session) }.map { |_, group| group.first }
    end

    # Session folders as a fix names them: here, or in a folder from where doctor ran.
    def started_in(folders)
      folders.map { |folder| fix_path(folder) }.uniq.map { |place| place == "." ? "here" : "in #{place}" }.join(" and ")
    end

    # The plugin serves this app, but not in a session started where its config is.
    def claude_plugin_elsewhere(label, folder)
      runs = started_in(claude_code.plugin_sessions)
      problem = "the rails-ai-context plugin serves this app only in sessions started #{runs}, not in ones started #{started_in([ folder ])}"
      start = [ "start Claude Code #{runs == "here" ? "here" : "there"}", claude_plugin_switch_on(folder) ].reject(&:empty?).join(", or ")
      fix = start.sub(/\A\w/, &:upcase)
      # Started there as told, the session would list every tool again.
      duplicate, removal = duplicates_said(disable: false)
      problem, fix = "#{problem}, where #{duplicate}", "#{removal}; then #{start}" if duplicate
      ConfigVerdict.new(label: label, status: :warn, problem: problem, fix: fix)
    end

    # What a session started in that folder needs to run the plugin: an install for its project, which
    # enables it too, else enabling it, else lifting the policy that blocks it, and its server back on in /mcp.
    def claude_plugin_switch_on(folder, id = claude_code.plugin_id)
      where = run_in([ folder ])
      steps = []
      if id && !claude_code.installed_in?(id, folder)
        bare = claude_code.marketplace_without_plugin(id, folder)
        steps << if claude_code.missing_marketplace(id, folder)
          MARKETPLACE_READD
        elsif bare
          "the marketplace at #{bare} has no rails-ai-context plugin: #{MARKETPLACE_UPDATE}"
        else
          "run #{plugin_install_command(id, scope: "local")}#{where}"
        end
      elsif id && !claude_code.plugin_enabled_in?(folder)
        steps << "run `claude plugin enable #{id} --scope local`#{where}"
      elsif (blocked = claude_code.block_in(folder))
        steps << plugin_policy_fix(blocked).sub(/\A\w/, &:downcase)
      end
      steps << "turn the plugin's server back on with /mcp in a session started#{where.empty? ? " here" : where}" if claude_code.plugin_server_off_in?(folder)
      steps.join(", then ")
    end

    # A marketplace Claude Code recorded needs no source, this repository's is named after the plugin,
    # and another has to be added first. The scope is, unless said, the one that leaves a committed file alone.
    def plugin_install_command(id, scope: claude_code.install_scope(id))
      return "`claude plugin install #{id} --scope #{scope}`" if claude_code.marketplace_known?(id)

      plugin, marketplace = id.split("@", 2)
      return "`claude plugin install #{plugin} --marketplace crisnahine/rails-ai-context --scope #{scope}`" if marketplace == plugin

      "`claude plugin marketplace add` for the #{marketplace} marketplace, then `claude plugin install #{id} --scope #{scope}`"
    end

    # Where to run a command, when that is not where doctor ran alone.
    def run_in(folders)
      folders.map { |folder| fix_path(folder) }.uniq == [ "." ] ? "" : " #{started_in(folders)}"
    end

    # The folder a config sits in, which its client starts the server from.
    def mcp_config_folder(tool, path)
      path.delete_suffix(self.class.mcp_config_checks.fetch(tool)[:path]).chomp("/")
    end

    # The entries under the gem's names in a config that serve this app: the
    # app's own config's (at an engine's root, the engine's), or a
    # workspace's that point --app-path at the app.
    # Claude Code's own also counts a server the gem's under any other name, as the install and the duplicate check do.
    def serving_entries(verdict, tool, path)
      entries = Array(verdict.existing)
      entries += hand_named_entries(path, mcp_config_folder(tool, path), entries.map { |entry| entry[:name] }) if tool == :claude
      target = SafePath.canonical(install_root)
      entries.select { |entry| SafePath.canonical(entry[:app]) == target }
    end

    # Names the install never reads, so its verdict holds none of them.
    def hand_named_entries(path, folder, named)
      servers = ClaudeCodeSettings.read_json(path)&.dig("mcpServers")
      (claude_code.gem_server_names(path, folder) - named).map do |name|
        env = servers[name]["env"]
        argv = McpConfigGenerator.json_argv(servers[name]).map(&:to_s)
        { name: name, argv: argv, env: env.is_a?(Hash) ? env.transform_values(&:to_s) : {}, own: true, hand: true,
          app: McpConfigGenerator.entry_app_root(argv, self.class.mcp_config_checks.fetch(:claude)[:folder_variable], folder) || folder }
      end
    end

    # Why one of the gem's entries cannot start the server for this app, or
    # starts a copy of the gem other than the app's: [status, problem, fix],
    # nil when it starts the right one. Fast on purpose: the command is
    # looked up, never run. A fix that rewrites the entry is the install,
    # or, where the install leaves the file as it is, the edit `by_hand`.
    # `folder` is where the client starts the server: the config's own, but a session's for managed-mcp.json.
    def entry_trouble(entry, tool, config_path, by_hand = nil, folder: mcp_config_folder(tool, config_path))
      argv = McpConfigGenerator.unwrapped_argv(entry[:argv])
      line = "`#{argv.take_while { |arg| !arg.start_with?("--app-path") }.join(' ')}`"
      rerun = by_hand || "Run #{install_command(config_path)} to fix"
      # Codex sets the PATH its env snapshot holds, which the snapshot check reads.
      path, where = entry_path_variable(entry, tool)
      found = path.nil? || executable_on?(argv.first.to_s, path, folder)
      # A command named by its path is no PATH lookup, so no install puts it there.
      qualified = argv.first.to_s.include?("/") || (Gem.win_platform? && argv.first.to_s.include?("\\"))
      missing = "#{line} cannot start - `#{argv.first}` #{qualified ? "is not an executable file" : "is not on #{where}"}"
      # A config is committed, and one written on the other platform starts
      # the server the way that platform's clients need.
      if Array(entry[:argv]).size != argv.size && !McpConfigGenerator.windows_shell?
        return [ :fail, "#{line} cannot start - it runs through `cmd /c`, Windows' shell, which is not here", rerun ]
      end
      if bare_batch?(entry, argv, path, folder)
        return [ :warn, "#{line} may not start - `#{argv.first}` is a batch file, which a client that starts its server " \
                        "without a shell does not run", rerun ]
      end

      if argv[0] == "bundle" && argv[1] == "exec"
        return [ :fail, missing, "Make `bundle` reachable from #{where}" ] unless found

        bundle = entry_bundle(entry, tool, folder) or return nil
        lock, gemfile, lock_shown = bundle
        return [ :fail, "#{line} cannot start - #{lock_shown} has no rails-ai-context", rerun ] if lock_lacks_gem?(lock)

        spec = bundled_gem_spec(gemfile) if argv[2] == "rails-ai-context"
        if spec && !spec.executables.include?("rails-ai-context")
          return [ :fail, "#{line} cannot start - the bundle's rails-ai-context at #{spec.full_gem_path} lists no `rails-ai-context` executable",
                   "Point the Gemfile at a rails-ai-context whose gemspec lists `exe/rails-ai-context` (a git checkout, or a release), " \
                   "then run `#{in_app("bundle install", dir: File.dirname(gemfile))}`" ]
        end
      elsif File.basename(argv[0].to_s) == "rails-ai-context"
        lock = GemLock.for(install_root)
        if lock.present?("rails-ai-context")
          bundled = "#{typed_path(GemLock.bundle(install_root).lockfile)} carries rails-ai-context #{lock.version("rails-ai-context")}"
          return [ :fail, "#{missing}, while #{bundled}", rerun ] unless found

          return [ :warn, "#{line} needs the gem installed outside the app's bundle, while #{bundled}", rerun ]
        end
        return [ :fail, missing, qualified ? rerun : "Run `gem install rails-ai-context` for the Ruby on #{where}" ] unless found
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
      original_variable("PATH").to_s
    end

    # A variable as this process had it before Bundler changed any. The copy
    # is a plain Hash, and Windows keeps its names in any case: PATH is
    # `Path` there.
    def original_variable(name)
      env = defined?(Bundler) && Bundler.respond_to?(:original_env) ? Bundler.original_env : ENV.to_h
      return env[name] if env.key?(name) || !Gem.win_platform?

      env.find { |key, _| key.casecmp?(name) }&.last
    end

    # Whether, on Windows, an entry runs a batch file without the `cmd /c`
    # the install starts one through: a gem's executable there is a .bat
    # file, which a client starting its server without a shell may not run
    # at all. PATH is the one the server gets, a Codex snapshot's included.
    def bare_batch?(entry, argv, path, folder)
      return false unless McpConfigGenerator.windows_shell? && Array(entry[:argv]).size == argv.size

      path ||= entry[:env]["PATH"]
      !path.nil? && !path.include?("$") && batch_only?(argv.first.to_s, path, folder)
    end

    # Whether `command` is a batch file: one named so, or a bare name PATH
    # finds only as a .bat or .cmd file. A spawn without a shell looks for
    # the .exe and .com of a bare name, never its .bat.
    def batch_only?(command, path, folder)
      return false if command.empty?
      return true if File.extname(command).match?(/\A\.(bat|cmd)\z/i)
      return false if command.match?(%r{[/\\]}) || File.extname(command).match?(/\A\.(exe|com)\z/i)

      dirs = path.split(File::PATH_SEPARATOR).reject(&:empty?).map { |dir| File.expand_path(dir, folder) }
      on_path = ->(extensions) { dirs.product(extensions).any? { |dir, ext| File.file?(File.join(dir, "#{command}#{ext}")) } }
      !on_path.(%w[.exe .com]) && on_path.(%w[.bat .cmd])
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
        gemfile = McpConfigGenerator.entry_path(named, self.class.mcp_config_checks.fetch(tool)[:folder_variable], folder)
        return nil unless gemfile && File.basename(gemfile) == GemLock.gemfile_name(File.dirname(gemfile))

        File.dirname(gemfile)
      else
        folder
      end
      bundle = GemLock.bundle(dir)
      [ GemLock.for(dir), bundle.gemfile, typed_path(lockfile_path(bundle)) ]
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
    def install_command(config_path)
      workspace_config?(config_path) ? "`rails-ai-context init` in the folder that holds #{fix_path(config_path)}" : install_job(:install)
    end

    # A config above the install's root: a workspace's.
    def workspace_config?(config_path)
      Install::Program.relative_to(config_path, install_root).start_with?("../")
    end

    def check_codex_env_staleness
      return nil if install_config.tool_mode == :cli

      ai_tools = configured_ai_tools
      return nil unless ai_tools.include?(:codex)

      # The app's own config (an engine's, at its root), or the workspace's above it.
      toml_path = McpConfigGenerator.serving_config(install_root, :codex)
      return nil unless toml_path && File.exist?(toml_path)

      # Every server the gem wrote carries a snapshot: the app's own, and each
      # app's in a workspace. Read the way the generator reads the file, so a
      # section is the gem's by the same rule and any byte reads in any locale.
      verdict = install_verdict(:codex, toml_path)
      snapshots = Array(verdict.existing).select do |entry|
        entry[:own] && entry[:env].values_at("PATH", "GEM_HOME", "GEM_PATH").any?
      end
      return nil if snapshots.empty?

      shown = typed_path(toml_path)
      # The install writes a fresh snapshot, unless it leaves the file, or
      # the gem's entry in it, as it is: then the edit by hand comes first.
      fix = verdict.action == :refuse ? "#{toml_by_hand(verdict, toml_path)}: #{verdict.reason}" : "Run #{install_command(toml_path)}"
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

      # So is a directory its GEM_PATH lists, which the generator saves too -
      # unless this environment's GEM_PATH lists it as well: RubyGems passes
      # over a directory that is not there, and init would save it again.
      gem_path = snapshots.flat_map { |entry| entry[:env]["GEM_PATH"].to_s.split(File::PATH_SEPARATOR) }.reject(&:empty?).uniq
      missing = gem_path.reject { |dir| Dir.exist?(dir) }
      if (gone = (missing - current_gem_path).first)
        return Check.new(name: "Codex env snapshot", status: :warn,
          message: "Codex MCP env snapshot is stale - GEM_PATH names #{gone}, which no longer exists", fix: fix)
      end

      reached = snapshots.filter_map { |entry| McpConfigGenerator.unwrapped_argv(entry[:argv]).first if entry[:env]["PATH"] }.uniq
      found = []
      found << "its PATH reaches #{reached.map { |command| "`#{command}`" }.join(', ')}" if reached.any?
      found << "GEM_HOME (#{gem_homes.first}) exists" if gem_homes.any?
      found << "every directory on its GEM_PATH exists" if gem_path.any? && missing.empty?
      sentence = found.size > 2 ? "#{found[0..-2].join(', ')}, and #{found.last}" : found.join(", and ")
      Check.new(name: "Codex env snapshot", status: :pass,
        message: "Codex env snapshot in #{shown} is current#{": #{sentence}" if found.any?}", fix: nil)
    end

    # The GEM_PATH this environment has, before Bundler changed it: what init
    # would save in a snapshot now.
    def current_gem_path
      original_variable("GEM_PATH").to_s.split(File::PATH_SEPARATOR).reject(&:empty?)
    end

    # Codex starts a server with the PATH its snapshot saved in place of its
    # own, and rbenv or asdf save nothing else, so a Ruby that has moved shows
    # as a command that PATH no longer reaches. The first gone directory on it
    # is usually that Ruby's. [server name, command, gone directory] or nil.
    def unreached_command(entry, folder)
      path = entry[:env]["PATH"] or return nil
      command = McpConfigGenerator.unwrapped_argv(entry[:argv]).first.to_s
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
        fix: "Check mcp gem: `#{in_app("bundle info mcp")}`")
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
      # The plugin starts the gem installed for that Ruby, never a bundle's
      # copy, and only at the version its own requirement names.
      plugin = plugin_activation
      requirement = claude_code.plugin_gem_requirement if plugin
      activate = "gem 'rails-ai-context'#{requirement&.map { |bound| ", #{bound.inspect}" }&.join}"
      stdout, stderr, status = Open3.capture3(
        base_env, Gem.ruby, "--disable-gems", "-e",
        "require 'rubygems'; begin; #{activate}; rescue Gem::LoadError => e; warn e.message.lines.first; exit 1; end",
        unsetenv_others: true
      )
      if status.success? && stdout.empty?
        Check.new(name: "MCP stdio hygiene", status: :pass,
          message: "gem activation is silent on stdout", fix: nil)
      elsif stdout.empty? && plugin
        said = plugin == :warn ? "once Claude Code runs here, the rails-ai-context plugin needs" : "the rails-ai-context plugin starts"
        Check.new(name: "MCP stdio hygiene", status: plugin,
          message: "#{said} the gem installed for #{Gem.ruby}, which did not activate: #{stderr.strip.truncate(200)}",
          fix: "Run `#{CLI::AppRoot.command_line([ Gem.ruby, File.join(RbConfig::CONFIG["bindir"], "gem"), "install", "rails-ai-context" ])}`")
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
      return true if plugin_activation
      return false if install_config.tool_mode == :cli

      mcp_tools_to_check.any? do |tool, _|
        path = McpConfigGenerator.serving_config(install_root, tool) or next false
        serving_entries(install_verdict(tool, path), tool, path).any? do |entry|
          entry[:own] && File.basename(McpConfigGenerator.unwrapped_argv(entry[:argv]).first.to_s) == "rails-ai-context"
        end
      rescue SystemCallError, IOError, JSON::ParserError
        false
      end
    end

    # How a gem the plugin cannot activate counts: a failure, but a warning where Claude Code never ran, as on CI,
    # since no plugin starts there until it does. nil where no plugin serves the app.
    def plugin_activation
      return nil unless claude_code.plugin?

      claude_code.absent? ? :warn : :fail
    end

    # ── Introspector health ───────────────────────────────────────────

    # The one introspection the health check and the context files' dry run both read.
    def introspection
      @introspection ||= RailsAiContext.introspect(app)
    end

    def check_introspector_health
      config = RailsAiContext.configuration
      names = config.introspectors.map(&:to_s)
      failures = Array(introspection[:_warnings]).filter_map do |warning|
        [ warning[:introspector], warning[:error].to_s ] if names.include?(warning[:introspector])
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
        suggestions << "views (#{typed_path(views_dir)}/ exists)"
      end

      i18n_dir = File.join(app.root, "config/locales")
      locale_file_count = Dir.exist?(i18n_dir) ? Dir.glob("**/*.{yml,yaml}", base: i18n_dir).size : 0
      if locale_file_count > 1 && !config.introspectors.include?(:i18n)
        suggestions << "i18n (#{count_phrase(locale_file_count, "locale file")})"
      end

      graphql_dir = File.join(app.root, "app/graphql")
      if Dir.exist?(graphql_dir) && !config.introspectors.include?(:api)
        suggestions << "api (#{typed_path(graphql_dir)}/ exists)"
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
      if Executable.on_path?("rg")
        Check.new(name: "ripgrep", status: :pass, message: "rg available for fast code search", fix: nil)
      else
        Check.new(name: "ripgrep", status: :warn,
          message: "ripgrep not installed (slower Ruby fallback)",
          fix: "Install: `brew install ripgrep`, `apt install ripgrep` or `winget install BurntSushi.ripgrep.MSVC`")
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

    # Asked of the scanner rather than `require`: brakeman outside the app's
    # bundle still scans, run the way the scan runs it, which is asked too.
    def check_brakeman
      where, version = Tools::SecurityScan.brakeman_location
      locked = GemLock.for(@app.root.to_s).version("brakeman")
      case where
      when :bundle
        Check.new(name: "Brakeman", status: :pass, message: "Brakeman #{version} available for security scanning", fix: nil)
      when :machine
        if (failure = Tools::SecurityScan.unbundled_failure)
          return Check.new(name: "Brakeman", status: :warn,
            message: "Brakeman #{version} is on this machine, outside the app's bundle, but rails_security_scan cannot run it there: #{failure}",
            fix: locked ? "Run `#{in_app("bundle install")}`, then `bundle exec brakeman` in the app to see what it says" : "Add: `gem 'brakeman', group: :development` to scan in this process")
        end

        return Check.new(name: "Brakeman", status: :pass, fix: nil,
          message: "Brakeman #{version} on this machine, and the app's Gemfile.lock carries brakeman #{locked} " \
                   "(rails_security_scan runs it as its own process)") if locked

        Check.new(name: "Brakeman", status: :pass,
          message: "Brakeman #{version} on this machine, outside the app's bundle (rails_security_scan runs it from there)",
          fix: "Add: `gem 'brakeman', group: :development` to scan in this process")
      else
        return Check.new(name: "Brakeman", status: :warn,
          message: "The app's Gemfile.lock carries brakeman #{locked}, but it is not installed",
          fix: "Run `#{in_app("bundle install")}`") if locked

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
    #
    # Inside a git repository git says what a commit takes: a file it tracks
    # already, which no ignore rule takes back out, or one no rule covers -
    # in any .gitignore up to the repository's root, info/exclude or the
    # global excludes. Outside one, the app's .gitignore is read.
    def check_security_gitignore
      gitignore_path = File.join(app.root, ".gitignore")
      gitignore = File.read(gitignore_path) if File.exist?(gitignore_path)
      files = present_sensitive_files.reject { |file| matches_any?(ENCRYPTED, file) }
      git = git_view(files)
      tracked, covered = git || [ [], gitignore ? files.select { |file| gitignore_covers?(gitignore, file) } : [] ]
      exposed = files.select { |file| tracked.include?(file) || !covered.include?(file) }
      never, others = exposed.partition { |file| matches_any?(NEVER_COMMIT, file) }
      configs, others = others.partition { |file| matches_any?(SECRET_HOLDING_CONFIGS, file) }
      literal = configs.filter_map { |file| (where = literal_secret(file)) && [ file, where ] }
      # Each file named from where doctor was typed. A fix keeps the app's own
      # spelling: a .gitignore pattern is read from the .gitignore it is in,
      # and git runs in the app's repository.
      see = ->(file) { typed_path(File.join(app.root.to_s, file)) }
      shown_literal = literal.map { |file, where| "#{see.(file)} (#{where})" }.join(", ")
      # Outside git nothing says whether a file is tracked, and the old word stands.
      others_committed = git ? others & tracked : others

      if never.any?
        committed, unignored = never.partition { |file| tracked.include?(file) }
        said = []
        said << "#{committed.map(&see).join(', ')} #{committed.one? ? "is" : "are"} committed" if committed.any?
        if unignored.any?
          said << (git || gitignore ? unignored.map { |file| "#{see.(file)} not in .gitignore" }.join("; ") : "No .gitignore found - #{unignored.map(&see).join(', ')} would be committed")
        end
        said << "a literal secret in #{shown_literal}" if literal.any?
        said << "also committed: #{others_committed.map(&see).join(', ')}" if others_committed.any?
        said << "also not gitignored: #{(others - others_committed).map(&see).join(', ')}" if (others - others_committed).any?
        fixes = []
        fixes << uncommit_fix(committed, committed - covered) if committed.any?
        fixes << "#{gitignore ? "Add to #{ignore_file}" : "Create #{ignore_file} with"}: #{unignored.map { |file| "`#{file}`" }.join(', ')}" if unignored.any?
        Check.new(name: "Secrets in .gitignore", status: :fail, message: said.join("; "), fix: fixes.join("; "))
      elsif literal.any?
        committed = literal.map(&:first) & tracked
        which = if committed.empty? then "which .gitignore does not cover"
        elsif committed.size == literal.size then "which #{committed.one? ? "is" : "are"} committed"
        else "committed or not gitignored"
        end
        Check.new(name: "Secrets in .gitignore", status: :warn,
          message: "A literal secret in #{shown_literal}, #{which}",
          fix: "Read it from the environment or credentials (`password: <%= ENV[\"DATABASE_PASSWORD\"] %>`), or gitignore the file" \
               "#{" and run `#{uncommit_command(committed)}`" if committed.any?}")
      elsif others.any?
        said = []
        said << "Committed, and never read by the tools: #{others_committed.map(&see).join(', ')}" if others_committed.any?
        said << "#{said.empty? ? "Not" : "not"} gitignored, and never read by the tools: #{(others - others_committed).map(&see).join(', ')}" if (others - others_committed).any?
        Check.new(name: "Secrets in .gitignore", status: :warn, message: said.join("; "),
          fix: "Make sure these hold no secrets, or gitignore them#{" and run `#{git_command("rm --cached")}` on the committed ones" if git && others_committed.any?}")
      else
        secrets = files.select { |file| matches_any?(NEVER_COMMIT, file) }
        Check.new(name: "Secrets in .gitignore", status: :pass,
          message: secrets.any? ? "Secret files gitignored: #{secrets.map(&see).join(', ')}" : "No secret files found", fix: nil)
      end
    end

    # A committed secret stays in the history git keeps, so taking it out of
    # the index is half the fix: whoever can read the repository has it.
    def uncommit_fix(committed, unignored)
      ignore = unignored.any? ? ", add #{unignored.map { |file| "`#{file}`" }.join(', ')} to #{ignore_file}," : ""
      "Run `#{uncommit_command(committed)}`#{ignore} and rotate #{committed.one? ? "it" : "them"}: " \
        "the history still holds #{committed.one? ? "it" : "them"}"
    end

    # `git rm --cached` of files named from the app's root, run in its repository.
    def uncommit_command(files)
      git_command("rm --cached #{CLI::AppRoot.command_line(files.map { |file| CLI::AppRoot.option_path(file) })}")
    end

    # The app's own .gitignore, as named where doctor was typed, which its
    # patterns, spelled from the app's root, are read from.
    def ignore_file
      fix_path(File.join(app.root.to_s, ".gitignore"))
    end

    # [tracked, covered by an ignore rule] among files (relative to the app
    # root), as git answers inside the repository the app is in; nil outside
    # one, or without git. A rule covers a file whether or not git tracks it.
    def git_view(files)
      # No pathspec at all would list every file git tracks.
      return [ [], [] ] if files.empty?

      root = app.root.to_s
      out, status = Open3.capture2("git", "--literal-pathspecs", "ls-files", "-z", "--", *files, chdir: root, err: File::NULL)
      return nil unless status.success?

      tracked = out.split("\0")
      out, status = Open3.capture2("git", "check-ignore", "--no-index", "-z", "--stdin",
                                   stdin_data: files.join("\0"), chdir: root, err: File::NULL)
      # 1 is none covered; anything past it, no answer.
      return nil unless [ 0, 1 ].include?(status.exitstatus)

      [ tracked, out.split("\0") ]
    rescue SystemCallError, IOError
      nil
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

    # A URL that carries a password.
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
        return "`#{key}` on line #{number}" if Redaction.secret_name?(key) || unquoted.match?(URL_PASSWORD)
      end
      nil
    end

    # Read as SafePath.sensitive? reads a pattern, so a file the tools refuse lands in the list that names it,
    # an engine's or a test/dummy app's included.
    def matches_any?(patterns, file)
      basename = File.basename(file)
      patterns.any? { |pattern| SafePath.compile_pattern(pattern).match(file, basename, file.downcase, basename.downcase) }
    end

    # Every file the tools refuse to read (the one sensitive-pattern list), plus the Codex
    # config our own install writes with this machine's PATH and GEM_HOME. Excluded
    # directories (node_modules, vendor, tmp) are not walked.
    def present_sensitive_files
      root = app.root.to_s
      excluded = ExcludedPaths.matcher(root, RailsAiContext.configuration.excluded_paths)
      found = []
      Find.find(root) do |path|
        relative = path.delete_prefix("#{root}/")
        next if path == root
        if File.directory?(path)
          Find.prune if excluded.call(relative, true) || File.symlink?(path)
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

      templates = PathResolver.glob(views_dir, RailsAiContext::ViewFile::MARKUP_GLOB)
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
