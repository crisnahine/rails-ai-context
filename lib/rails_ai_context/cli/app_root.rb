# frozen_string_literal: true

require "rbconfig"
require "shellwords"
require_relative "entry_boot"
require_relative "../safe_path"
require_relative "../version"

module RailsAiContext
  module CLI
    # Which app a command reads, decided once and before anything reads
    # Dir.pwd: --app-path as given, else the current directory (or, when it
    # holds source alone, the app it sits in), else the nearest app above it
    # (the way bin/rails and Bundler find theirs), else the one app a level or
    # two below it. Stdlib only, like EntryBoot: the answer is needed before
    # the gem entry may load. Never prints and never exits; the binary relays
    # the lines.
    module AppRoot
      # root is the app the command reads, nil when there is no single one.
      # walked is nil when root is the directory the caller stood in or
      # named, else :up or :down. below lists the apps under `base`, a
      # directory that is no app: the one the caller stood in when it has no
      # app above it either, or the one --app-path named. Without
      # --app-path, one app below is root; several leave root nil. cwd is
      # where the caller stood.
      # Set on the run a handoff starts, so the bundled copy never hands off again.
      HANDOFF_ENV = "RAILS_AI_CONTEXT_HANDOFF"

      Handoff = Struct.new(:env, :version, keyword_init: true)

      Result = Struct.new(:root, :walked, :below, :base, :explicit, :cwd, keyword_init: true) do
        # A folder that is no app and holds apps below it: what `init` sets
        # up as a whole, where every other command needs exactly one.
        def workspace?
          below.any?
        end
      end

      # What a session started in a folder serves: kind :app (root), :apps (apps) or :none (reason), with the walk behind it.
      Target = Struct.new(:kind, :root, :apps, :reason, :resolution, keyword_init: true)

      TargetApp = Struct.new(:root, :name, keyword_init: true)

      def self.target(start_folder)
        result = resolve(cwd: start_folder)
        if result.root.nil?
          return Target.new(kind: :none, apps: [], reason: "#{start_folder} holds no Rails app.", resolution: result) if result.below.empty?

          return Target.new(kind: :apps, apps: target_apps(result.below, start_folder), resolution: result)
        end
        return Target.new(kind: :app, root: result.root, apps: [], resolution: result) if EntryBoot.app_present?(result.root, allow_source_only: true)

        # A monorepo's root runs the app its bin/rails boots, as a folder holding that one app: init sets it up from the root,
        # whose .mcp.json a session started there reads (ADR-0005).
        booted = binstub_app(result.root) || dummy_below(result.root)
        if booted
          walk = Result.new(root: booted, walked: :down, below: [ booted ], base: result.root, explicit: false, cwd: result.cwd)
          return Target.new(kind: :app, root: booted, apps: [], resolution: walk)
        end

        Target.new(kind: :none, apps: [], resolution: result,
                   reason: "#{result.root} has a bin/rails but no app source: no config/application.rb, config/environment.rb or app/**/*.rb.")
      end

      # Each app's name is its workspace server name without the prefix, so two apps never share one.
      def self.target_apps(roots, base)
        require_relative "../install/ai_tool"
        require_relative "../mcp_config_generator"
        require_relative "../install/workspace"
        paths = roots.map { |root| display(root, base) }
        names = Install::Workspace.server_names(paths)
        roots.zip(paths).map { |root, path| TargetApp.new(root: root, name: names.fetch(path).delete_prefix(Install::Workspace::PREFIX)) }
          .sort_by(&:name)
      end
      private_class_method :target_apps

      # The app below root that its bin/rails names as APP_PATH, nil for none.
      def self.binstub_app(root)
        app = app_path_dir(root)
        app if app && app != root && SafePath.contained?(app.b, root.b) && EntryBoot.app_present?(app, allow_source_only: true)
      end
      private_class_method :binstub_app

      # An engine's test/dummy or spec/dummy app, as dummy_app finds one where bin/rails names none (Rails 4.2 and 5.0 wrote no APP_PATH).
      def self.dummy_below(root)
        [ File.join(root, "test", "dummy"), File.join(root, "spec", "dummy") ].find { |dir| EntryBoot.app_present?(dir, allow_source_only: true) }
      end
      private_class_method :dummy_below

      # The folder bin/rails's APP_PATH names, nil where it names none.
      def self.app_path_dir(root)
        named, anchor = File.binread(File.join(root, "bin", "rails"), 4096)
          .match(/^\s*APP_PATH\s*=\s*File\.expand_path\(\s*["']([^"'#]+)["']\s*,\s*(__dir__|__FILE__)\s*\)/)&.captures
        # Rails 5.1 expanded from __FILE__, which starts at bin/rails itself rather than at bin/.
        base = anchor == "__FILE__" ? File.join(root, "bin", "rails") : File.join(root, "bin")
        named && File.dirname(File.expand_path(named.force_encoding(root.encoding), base), 2)
      rescue SystemCallError, IOError
        nil
      end
      private_class_method :app_path_dir

      def self.resolve(cwd:, app_path: nil)
        # Every path handed back is spelled in the caller's encoding, which a
        # shell's argument may not share.
        app_path = app_path.dup.force_encoding(cwd.encoding) if app_path && app_path.encoding != cwd.encoding
        if app_path
          # Named outright, it is never walked: a folder of apps is set up by
          # init and listed to every other command, never quietly swapped
          # for the one app inside it.
          root = File.expand_path(app_path, cwd)
          below = Dir.exist?(root) && !EntryBoot.app_present?(root, allow_source_only: true) ? walk_down(root) : []
          return Result.new(root: root, walked: nil, below: below, base: root, explicit: true, cwd: cwd)
        end

        if EntryBoot.app_present?(cwd, allow_source_only: true)
          # A tree that is only source - a packwerk pack, an engine kept as
          # code - belongs to the app it sits in, when it sits in one.
          above = app_root?(cwd) ? nil : walk_up(File.dirname(cwd))
          return Result.new(root: above, walked: :up, below: [], base: cwd, explicit: false, cwd: cwd) if above

          return Result.new(root: cwd, walked: nil, below: [], base: cwd, explicit: false, cwd: cwd)
        end

        if (above = walk_up(cwd))
          return Result.new(root: above, walked: :up, below: [], base: cwd, explicit: false, cwd: cwd)
        end

        below = walk_down(cwd)
        Result.new(root: below.one? ? below.first : nil, walked: below.one? ? :down : nil, below: below, base: cwd,
                   explicit: false, cwd: cwd)
      end

      # The nearest app root at or above dir. The test is stricter than the
      # one a command applies to the directory it stands in: app/**/*.rb
      # alone passes a packwerk pack and this gem's own repo, and a walk that
      # stopped there would never reach the host app.
      def self.walk_up(dir)
        homes = home_dirs
        loop do
          return dir if !homes.include?(dir.b) && !excluded?(dir) && app_root?(dir)

          parent = File.dirname(dir)
          # The filesystem root is its own dirname, a Windows drive root too.
          return nil if parent == dir

          dir = parent
        end
      end

      # Apps one or two levels down, by config/application.rb only - an engine
      # or a pack has app/ and would read as an app on the looser test. Never
      # from $HOME or a directory above it (the filesystem root, /Users): two
      # levels from there reach ~/Documents, and on macOS listing it raises a
      # folder-access prompt.
      def self.walk_down(dir)
        return [] if File.dirname(dir) == dir
        return [] if home_dirs.any? { |home| SafePath.contained?(home, dir.b) }

        # Hidden directories (.git, .claude/worktrees) are left out by the
        # glob itself, and an unreadable one yields nothing rather than raising.
        roots = Dir.glob("{*,*/*}/config/application.rb", base: dir).sort
          .reject { |hit| (segments(hit) & WALK_DOWN_DROPPED).any? }
          .map { |hit| File.join(dir, File.dirname(hit, 2).dup.force_encoding(dir.encoding)) }
        # A symlink loop or a Capistrano `current` link names one app twice.
        roots = roots.uniq { |root| real(root).b }
        roots.reject { |root| roots.any? { |other| other != root && SafePath.contained?(root.b, other.b) } }
      end

      WALK_DOWN_DROPPED = %w[node_modules vendor tmp].freeze

      # Rails' AppLoader takes the first bin/rails or script/rails that boots
      # an app or an engine, and an engine's spec/ walks up to the engine.
      def self.rails_binstub?(dir)
        %w[bin/rails script/rails].any? do |stub|
          path = File.join(dir, stub)
          File.file?(path) && File.binread(path, 4096).match?(/(APP|ENGINE)_PATH/)
        rescue SystemCallError, IOError
          false
        end
      end
      private_class_method :rails_binstub?

      # A gem's own source and a JS package are never the app a command means.
      # Walking up from inside one keeps going to the app that holds it.
      def self.excluded?(dir)
        names = segments(dir)
        return true if names.include?("node_modules")
        return true if names.each_cons(2).include?(%w[vendor bundle])
        return false unless defined?(Gem) && Gem.respond_to?(:path)

        # An empty entry - GEM_PATH=":$HOME/.gem" - would read as the
        # filesystem root and exclude everything.
        Gem.path.any? do |gem_dir|
          next false unless gem_dir.is_a?(String) && File.absolute_path?(gem_dir) && File.dirname(gem_dir) != gem_dir

          SafePath.contained?(dir.b, gem_dir.b)
        end
      end
      private_class_method :excluded?

      # A path's names as bytes: a directory named in another encoding than
      # UTF-8 is still a directory, and only ASCII names are looked for.
      def self.segments(path)
        path.b.split("/")
      end
      private_class_method :segments

      # Dir.home falls back to the passwd entry when HOME is unset and raises
      # only when that fails too; an empty or relative HOME comes back as is.
      # As bytes, like every path compared here: a locale that names no
      # encoding tags paths binary or US-ASCII, and the gem's own are UTF-8.
      def self.home_dirs
        home = Dir.home
        return [] unless home && !home.empty? && File.absolute_path?(home)

        [ File.expand_path(home).b, real(home).b ].uniq
      rescue ArgumentError
        []
      end
      private_class_method :home_dirs

      def self.real(path)
        SafePath.canonical(path)
      end
      private_class_method :real

      def self.app_root?(dir)
        (EntryBoot.rails_config?(dir) || rails_binstub?(dir)) && !EntryBoot.other_framework?(dir)
      end
      private_class_method :app_root?

      # The app an engine's root boots for it: the dummy app its bin/rails
      # names as APP_PATH, else test/dummy or spec/dummy. nil for a root with
      # a config/environment.rb of its own, and for one with no dummy app.
      def self.dummy_app(root)
        return nil if File.exist?(File.join(root, "config", "environment.rb"))

        candidates = [ app_path_dir(root), File.join(root, "test", "dummy"), File.join(root, "spec", "dummy") ].compact
        candidates.find { |dir| File.exist?(File.join(dir, "config", "environment.rb")) }
      end

      # Under the caller's directory a path reads relative to it, the way it
      # is typed; anywhere else it stays absolute.
      def self.display(path, cwd)
        return "." if path == cwd
        return path unless path.start_with?("#{cwd}/")

        path.delete_prefix("#{cwd}/")
      end

      # A path as an --app-path value: one that starts with a dash is read as
      # an option, so it is spelled from the current directory.
      def self.option_path(path)
        path.start_with?("-") ? "./#{path}" : path
      end

      def self.notice(result, cwd)
        "[rails-ai-context] using app at #{display(result.root, cwd).delete_suffix("/")}/"
      end

      # `argv` is the command line as typed, which every suggested command
      # repeats behind its own --app-path, in place of any it carried.
      def self.several_apps(result, cwd, argv)
        rest = without_app_path(argv)
        lines = [ "Error: #{result.base} is no Rails app, and holds #{result.below.size} below it. Name one with --app-path:" ]
        result.below.each do |root|
          lines << "  #{command_line([ "rails-ai-context", "--app-path", option_path(display(root, cwd)), *rest ])}"
        end
        lines
      end

      # Words as a shell reads them, as a person would type them: letters
      # outside ASCII stay as they are, a word holding a space or another
      # character a shell reads is single-quoted, and a word holding a single
      # quote, or a name that is not UTF-8, is escaped character by character
      # (byte by byte for the latter) rather than refused.
      def self.command_line(words)
        words = words.map { |word| word.dup.force_encoding(Encoding::UTF_8) }
        text = words.all?(&:valid_encoding?)
        words = words.map(&:b) unless text
        words.map do |word|
          next "''" if word.empty?
          # zsh expands a word that starts with `=`.
          next word if text && word.match?(%r{\A[\p{L}\p{M}\p{N}_\-.,:+/@][\p{L}\p{M}\p{N}_\-.,:+/@=]*\z})
          next "'#{word}'" if text && !word.include?("'")

          escaped = word.gsub(%r{[^A-Za-z0-9_\-.,:+/@=\n]}n) { |char| "\\#{char}" }.gsub("\n", "'\n'")
          escaped.start_with?("=") ? "\\#{escaped}" : escaped
        end.join(" ")
      end

      def self.without_app_path(argv)
        kept = []
        value_next = false
        argv.each do |arg|
          if value_next
            value_next = false
          elsif arg == "--app-path"
            value_next = true
          elsif !arg.start_with?("--app-path=")
            kept << arg
          end
        end
        kept
      end
      private_class_method :without_app_path

      # A wrong --app-path still fails, but a path inside an app names it.
      def self.app_above_hint(root, cwd)
        return nil unless Dir.exist?(root)

        above = walk_up(root) or return nil
        return nil if above == root

        shown = display(above, cwd)
        "#{root} is inside the app at #{shown}: pass --app-path #{command_line([ shown ])}"
      end

      # A workspace entry's --app-path is relative to the folder the client was
      # opened at. A client launched inside one of the apps still reads the
      # workspace's config above it, but starts the server where it was
      # launched, so the path misses: name the folder it was written for.
      def self.relative_path_hint(app_path, cwd)
        return nil if app_path.nil? || app_path.start_with?("~") || File.absolute_path?(app_path)

        dir = cwd
        loop do
          parent = File.dirname(dir)
          return nil if parent == dir

          dir = parent
          next unless EntryBoot.app_present?(File.expand_path(app_path, dir), allow_source_only: true)

          return "--app-path #{app_path} is read from #{cwd}; it names an app from #{dir}. " \
                 "A workspace's MCP configs expect the client to be started in the workspace folder."
        end
      end

      # Under bundle exec the bundle is already chosen. One whose Gemfile is in
      # the app or below it is the app's own - a dual-boot Gemfile.next, an
      # Appraisal gemfiles/ entry, a Gemfile linked in from a shared one - and
      # so is the one an app with no Gemfile names in its config/boot.rb (a
      # monorepo's shared bundle), or any bundle above such an app (an
      # engine's dummy app). Otherwise an app with a Gemfile of its own boots
      # against someone else's Gemfile.lock. An inherited BUNDLE_GEMFILE picks
      # the bundle the same way: config/boot.rb sets it only when it is unset.
      def self.bundle_warning(root, cwd)
        # A handoff's child runs the Gemfile the parent already checked.
        return nil if ENV[HANDOFF_ENV]

        bundled = ENV["BUNDLE_BIN_PATH"]
        if bundled
          return nil unless defined?(::Bundler) && ::Bundler.respond_to?(:default_gemfile)

          given = ::Bundler.default_gemfile.to_s
        else
          return nil if ENV["BUNDLE_GEMFILE"].to_s.empty?

          given = File.expand_path(ENV["BUNDLE_GEMFILE"])
        end
        # Bundler's path comes from ENV, which a C locale tags binary whatever
        # the default; spelled in the app's encoding, it joins its name.
        given = given.dup.force_encoding(root.encoding)
        bundle_gemfile = real(given)
        real_root = real(root)
        # Bundler looks for gems.rb before Gemfile.
        own = %w[gems.rb Gemfile].map { |name| File.join(root, name) }.find { |path| File.file?(path) }
        return nil if SafePath.contained?(given.b, root.b) || SafePath.contained?(bundle_gemfile.b, real_root.b)
        return nil if own && real(own).b == bundle_gemfile.b
        return nil if own.nil? && (SafePath.contained?(real_root.b, File.dirname(bundle_gemfile).b) || boot_bundle?(root, bundle_gemfile))

        # Standing in the app, only a BUNDLE_GEMFILE someone set picks another
        # bundle, so the way out is the variable.
        where, inside = root == cwd ? [ "This app", "" ] : [ "#{display(root, cwd).delete_suffix('/')}/", " or from inside the app" ]
        unless bundled
          return "[rails-ai-context] WARNING: #{where} boots against #{bundle_gemfile}, which BUNDLE_GEMFILE names, " \
                 "not its own Gemfile. Unset BUNDLE_GEMFILE, or point it at the app's Gemfile."
        end

        "[rails-ai-context] WARNING: #{where} boots against the bundle of #{bundle_gemfile} under bundle exec, " \
          "not its own. Run it without bundle exec#{inside}, or point BUNDLE_GEMFILE at the app's Gemfile."
      rescue StandardError
        nil
      end

      # When the app's own bundle carries another copy of rails-ai-context,
      # the run the binary hands the command to: that copy, as `bundle exec`
      # runs it, which is the copy the app's MCP configs start. Run from here
      # instead, two copies met in one process - this one loads its first
      # files before the boot, the bundle's load the rest over them ("already
      # initialized constant") - and the command ran half of each.
      #
      # nil when this process is that copy, under bundle exec or as the same
      # installed files, and when the bundled copy cannot be found installed:
      # a bundle not installed yet fails to boot, which the static tier
      # answers, where bundle exec would only fail.
      def self.bundled_handoff(root)
        return nil if ENV["BUNDLE_BIN_PATH"] || ENV[HANDOFF_ENV]

        gemfile, lock = gem_bundle(root)
        return nil unless lock

        version = lock.version("rails-ai-context")
        copy = bundled_copy(lock.source("rails-ai-context"), version, gemfile)
        return nil if copy.nil? || real(copy).b == real(OWN_COPY).b

        Handoff.new(env: { "BUNDLE_GEMFILE" => File.expand_path(gemfile), HANDOFF_ENV => "1" }, version: version)
      rescue StandardError
        nil
      end

      # A BUNDLE_GEMFILE someone set (a dual boot's Gemfile.next) picks the bundle, as it does for bundle exec;
      # resolve_app_root! has already made it absolute.
      def self.gem_bundle(root)
        require_relative "../gem_lock"
        named = ENV["BUNDLE_GEMFILE"].to_s
        gemfile = named.empty? ? GemLock.bundle(root).gemfile : named
        return nil unless gemfile && File.file?(gemfile) && lock_names_gem?(gemfile)

        lock = named.empty? ? GemLock.for(root) : GemLock.for_gemfile(gemfile, root)
        [ gemfile, lock ] if lock&.version("rails-ai-context")
      end
      private_class_method :gem_bundle

      # Whether the app's lockfile names this gem, by its text: most apps never
      # lock it, and parsing a Gemfile takes a second on a machine with many gems.
      def self.lock_names_gem?(gemfile)
        lock = GemLock.lockfile_for(gemfile)
        File.file?(lock) && File.read(lock).include?("rails-ai-context")
      rescue SystemCallError, IOError
        false
      end

      # Whether the app's lockfile names the version this process runs, so the lockfile, not an
      # update, decides the copy that serves it. Where it names another, that copy is handed the
      # run, or is not to be found and this one serves.
      def self.pinned?(root, version = RailsAiContext::VERSION)
        _, lock = gem_bundle(root)
        lock&.version("rails-ai-context") == version
      rescue StandardError
        false
      end

      # This copy's root, as a bundle would name it.
      OWN_COPY = File.expand_path("../../..", __dir__)

      # How long `bundle check` gets. A Gemfile edited since its lock was
      # written sends Bundler to the network to resolve it again.
      BUNDLE_CHECK_SECONDS = 5

      # Whether bundle exec would start: every gem the app locks installed,
      # answered by `bundle check`, which writes nothing with --dry-run. A
      # bundle not installed yet only fails under bundle exec, where this copy
      # answers from source. Polled rather than timed out with Timeout, a gem
      # an app can pin, which nothing may load before the app's bundle does.
      def self.bundle_ready?(env, root, bundle: Gem.bin_path("bundler", "bundle"), seconds: BUNDLE_CHECK_SECONDS)
        pid = Process.spawn(env, RbConfig.ruby, bundle, "check", "--dry-run", chdir: root, in: File::NULL, out: File::NULL, err: File::NULL)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
        loop do
          _, status = Process.waitpid2(pid, Process::WNOHANG)
          return status.success? if status

          if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
            Process.kill("KILL", pid)
            Process.waitpid(pid)
            return false
          end
          sleep 0.05
        end
      rescue SystemCallError, Gem::Exception
        false
      end

      # The directory the bundle loads the gem from: a path source's, or the
      # installed gem a rubygems source resolves to, only under the bundle's own
      # path where it has one, as bundle exec loads it. A git checkout is nil:
      # its install is not seen from here.
      def self.bundled_copy(source, version, gemfile)
        case source&.first
        when :path
          dir = File.expand_path(source[1].to_s, File.dirname(gemfile))
          dir if File.file?(File.join(dir, "rails-ai-context.gemspec"))
        when :gem
          path = bundle_path(gemfile)
          return vendored_copy(gemfile, path, version) if path

          Gem::Specification.find_all_by_name("rails-ai-context", "= #{version}").first&.full_gem_path
        end
      end
      private_class_method :bundled_copy

      # A copy installed under the bundle's own path, which no Gem path outside the bundle sees.
      def self.vendored_copy(gemfile, path, version)
        copy = File.join(File.expand_path(path, File.dirname(gemfile)), RUBY_ENGINE, RbConfig::CONFIG["ruby_version"], "gems",
                         "rails-ai-context-#{version}")
        copy if File.file?(File.join(copy, "lib", "rails_ai_context.rb"))
      rescue ArgumentError, SystemCallError, IOError
        nil
      end
      private_class_method :vendored_copy

      # Where Bundler installs the bundle, as its Settings#path decides; nil for system gems, which the
      # Gem path already holds. The first level that names a path or system gems decides; only then does
      # a deployment mean vendor/bundle, and Bundler 5 puts a bundle with neither under .bundle.
      def self.bundle_path(gemfile)
        own = ".bundle" if File.read(GemLock.lockfile_for(gemfile))[/^BUNDLED WITH\r?\n\s+(\d+)\./, 1].to_i >= 5
        levels = bundle_levels(File.dirname(gemfile))
        levels.each do |level|
          path, system, shared = level.values_at("BUNDLE_PATH", "BUNDLE_PATH__SYSTEM", "BUNDLE_DISABLE_SHARED_GEMS")
          next if path.nil? && system.nil? && shared.nil?
          return nil if bundle_true?(system) || (shared && !bundle_true?(shared))

          return path || own
        end
        bundle_true?(levels.filter_map { |level| level["BUNDLE_DEPLOYMENT"] }.first) ? "vendor/bundle" : own
      rescue ArgumentError, SystemCallError, IOError
        nil
      end
      private_class_method :bundle_path

      # Bundler's settings as it ranks them: the app's config, the environment, then the user's. The
      # files are read as text, since YAML is a gem an app's bundle pins.
      def self.bundle_levels(dir)
        env = ENV.to_h.select { |key, _| key.start_with?("BUNDLE_") }
        return [ env ] if ENV["BUNDLE_IGNORE_CONFIG"]

        app = ENV["BUNDLE_APP_CONFIG"].to_s
        user = ENV.values_at("BUNDLE_CONFIG", "BUNDLE_USER_CONFIG").find { |file| !file.to_s.empty? } ||
               File.join(ENV["BUNDLE_USER_HOME"].to_s.empty? ? File.join(Dir.home, ".bundle") : ENV["BUNDLE_USER_HOME"], "config")
        local, global = [ File.join(app.empty? ? File.join(dir, ".bundle") : File.expand_path(app, dir), "config"), user ].map do |file|
          File.file?(file) ? bundle_settings(File.read(file)) : {}
        end
        [ local, env, global ]
      end
      private_class_method :bundle_levels

      # A settings file read as Bundler's YAMLSerializer reads it: one optional space after the colon, a matching
      # pair of quotes, then a comment cut off a value that does not start with one.
      def self.bundle_settings(text)
        text.split(/\r?\n/).each_with_object({}) do |line, settings|
          key, _, value = line.match(/\A(BUNDLE_[A-Z0-9_]+):(?=\s|\z) ?(['"]?)(.*)\2\z/)&.captures
          next unless key

          value = value.split("#", 2).first.strip if value.include?("#") && !value.start_with?("#")
          settings[key] = value
        end
      end
      private_class_method :bundle_settings

      # A Bundler boolean setting: anything but an empty or false-like word is true.
      def self.bundle_true?(value)
        !value.nil? && !value.match?(/\A(false|f|no|n|0|)\z/i)
      end
      private_class_method :bundle_true?

      # Whether config/boot.rb points Bundler at this Gemfile.
      def self.boot_bundle?(root, gemfile)
        require_relative "../gem_lock"
        named = GemLock.boot_gemfile(root)
        !named.nil? && real(named).b == gemfile.b
      end
      private_class_method :boot_bundle?
    end
  end
end
