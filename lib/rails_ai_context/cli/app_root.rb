# frozen_string_literal: true

require "shellwords"
require_relative "entry_boot"

module RailsAiContext
  module CLI
    # Which app a command reads, decided once and before anything reads
    # Dir.pwd: --app-path as given, else the current directory, else the
    # nearest app above it (the way bin/rails and Bundler find theirs), else
    # the one app a level or two below it. Stdlib only, like EntryBoot: the
    # answer is needed before the gem entry may load. Never prints and never
    # exits; the binary relays the lines.
    module AppRoot
      # root is the app the command reads, nil when there is no single one.
      # walked is nil when root is the directory the caller stood in or
      # named, else :up or :down. below lists the apps under `base`, a
      # directory that is no app: the one the caller stood in when it has no
      # app above it either, or the one --app-path named. Without
      # --app-path, one app below is root; several leave root nil.
      Result = Struct.new(:root, :walked, :below, :base, :explicit, keyword_init: true) do
        # A folder that is no app and holds apps below it: what `init` sets
        # up as a whole, where every other command needs exactly one.
        def workspace?
          below.any?
        end
      end

      def self.resolve(cwd:, app_path: nil)
        if app_path
          # Named outright, it is never walked: a folder of apps is set up by
          # init and listed to every other command, never quietly swapped
          # for the one app inside it.
          root = File.expand_path(app_path, cwd)
          below = Dir.exist?(root) && !EntryBoot.app_present?(root, allow_source_only: true) ? walk_down(root) : []
          return Result.new(root: root, walked: nil, below: below, base: root, explicit: true)
        end

        if EntryBoot.app_present?(cwd, allow_source_only: true)
          # A tree that is only source - a packwerk pack, an engine kept as
          # code - belongs to the app it sits in, when it sits in one.
          above = app_root?(cwd) ? nil : walk_up(File.dirname(cwd))
          return Result.new(root: above, walked: :up, below: [], base: cwd, explicit: false) if above

          return Result.new(root: cwd, walked: nil, below: [], base: cwd, explicit: false)
        end

        if (above = walk_up(cwd))
          return Result.new(root: above, walked: :up, below: [], base: cwd, explicit: false)
        end

        below = walk_down(cwd)
        Result.new(root: below.one? ? below.first : nil, walked: below.one? ? :down : nil, below: below, base: cwd,
                   explicit: false)
      end

      # The nearest app root at or above dir. The test is stricter than the
      # one a command applies to the directory it stands in: app/**/*.rb
      # alone passes a packwerk pack and this gem's own repo, and a walk that
      # stopped there would never reach the host app.
      def self.walk_up(dir)
        homes = home_dirs
        loop do
          return dir if !homes.include?(dir) && !excluded?(dir) && app_root?(dir)

          parent = File.dirname(dir)
          # The filesystem root is its own dirname, a Windows drive root too.
          return nil if parent == dir

          dir = parent
        end
      end

      # Apps one or two levels down, by config/application.rb only - an engine
      # or a pack has app/ and would read as an app on the looser test. Never
      # from the filesystem root or $HOME: on macOS listing ~/Documents can
      # raise a folder-access prompt.
      def self.walk_down(dir)
        return [] if File.dirname(dir) == dir || home_dirs.include?(dir)

        # Hidden directories (.git, .claude/worktrees) are left out by the
        # glob itself, and an unreadable one yields nothing rather than raising.
        roots = Dir.glob("{*,*/*}/config/application.rb", base: dir).sort
          .reject { |hit| (hit.split("/") & WALK_DOWN_DROPPED).any? }
          .map { |hit| File.join(dir, File.dirname(hit, 2)) }
        # A symlink loop or a Capistrano `current` link names one app twice.
        roots = roots.uniq { |root| real(root) }
        roots.reject { |root| roots.any? { |other| other != root && root.start_with?("#{other}/") } }
      end

      WALK_DOWN_DROPPED = %w[node_modules vendor tmp].freeze

      # Rails' AppLoader takes the first bin/rails or script/rails that boots
      # an app or an engine, and an engine's spec/ walks up to the engine.
      def self.rails_binstub?(dir)
        %w[bin/rails script/rails].any? do |stub|
          path = File.join(dir, stub)
          File.file?(path) && File.read(path, 4096).match?(/(APP|ENGINE)_PATH/)
        rescue SystemCallError, IOError
          false
        end
      end
      private_class_method :rails_binstub?

      # A gem's own source and a JS package are never the app a command means.
      # Walking up from inside one keeps going to the app that holds it.
      def self.excluded?(dir)
        segments = dir.split("/")
        return true if segments.include?("node_modules")
        return true if segments.each_cons(2).include?(%w[vendor bundle])
        return false unless defined?(Gem) && Gem.respond_to?(:path)

        Gem.path.any? { |gem_dir| dir == gem_dir || dir.start_with?("#{gem_dir}/") }
      end
      private_class_method :excluded?

      # Dir.home falls back to the passwd entry when HOME is unset and raises
      # only when that fails too; an empty or relative HOME comes back as is.
      def self.home_dirs
        home = Dir.home
        return [] unless home && !home.empty? && File.absolute_path?(home)

        [ File.expand_path(home), real(home) ].uniq
      rescue ArgumentError
        []
      end
      private_class_method :home_dirs

      def self.real(path)
        File.realpath(path)
      rescue SystemCallError
        path
      end
      private_class_method :real

      def self.app_root?(dir)
        marked = File.exist?(File.join(dir, "config", "application.rb")) ||
          File.exist?(File.join(dir, "config", "environment.rb")) ||
          rails_binstub?(dir)
        marked && !EntryBoot.other_framework?(dir)
      end
      private_class_method :app_root?

      # Under the caller's directory a path reads relative to it, the way it
      # is typed; anywhere else it stays absolute.
      def self.display(path, cwd)
        return "." if path == cwd
        return path unless path.start_with?("#{cwd}/")

        path.delete_prefix("#{cwd}/")
      end

      def self.notice(result, cwd)
        "[rails-ai-context] using app at #{display(result.root, cwd).delete_suffix("/")}/"
      end

      # `argv` is the command line as typed, which every suggested command
      # repeats behind its own --app-path, in place of any it carried.
      def self.several_apps(result, cwd, argv)
        rest = without_app_path(argv)
        lines = [ "Error: No Rails app found in #{result.base}, and #{result.below.size} below it. Name one with --app-path:" ]
        result.below.each do |root|
          lines << "  #{[ "rails-ai-context", "--app-path", display(root, cwd), *rest ].shelljoin}"
        end
        lines
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
        "#{root} is inside the app at #{shown}: pass --app-path #{shown.shellescape}"
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

      # Under bundle exec the bundle is already chosen: an app with a Gemfile
      # of its own other than that one, or with none and outside it, boots
      # against someone else's Gemfile.lock.
      def self.bundle_warning(root, cwd)
        return nil unless ENV["BUNDLE_BIN_PATH"] && defined?(::Bundler) && ::Bundler.respond_to?(:default_gemfile)

        bundle_gemfile = real(::Bundler.default_gemfile.to_s)
        # Bundler looks for gems.rb before Gemfile.
        own = %w[gems.rb Gemfile].map { |name| File.join(root, name) }.find { |path| File.file?(path) }
        bundle_dir = File.dirname(bundle_gemfile)
        return nil if own ? real(own) == bundle_gemfile : real(root).start_with?("#{bundle_dir}/") || real(root) == bundle_dir

        "[rails-ai-context] WARNING: #{display(root, cwd).delete_suffix('/')}/ boots against the bundle of #{bundle_gemfile} " \
          "under bundle exec, not its own. Run the command from inside the app, or point BUNDLE_GEMFILE at the app's Gemfile."
      rescue StandardError
        nil
      end
    end
  end
end
