# frozen_string_literal: true

require "shellwords"
require_relative "entry_boot"
require_relative "../safe_path"

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
      Result = Struct.new(:root, :walked, :below, :base, :explicit, :cwd, keyword_init: true) do
        # A folder that is no app and holds apps below it: what `init` sets
        # up as a whole, where every other command needs exactly one.
        def workspace?
          below.any?
        end
      end

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
          lines << "  #{command_line([ "rails-ai-context", "--app-path", display(root, cwd), *rest ])}"
        end
        lines
      end

      # Words as a shell reads them: Shellwords' escaping, but for an `=`
      # inside a word, which every shell reads as itself there, and a name
      # that is not UTF-8 is escaped byte by byte rather than refused.
      def self.command_line(words)
        words = words.map { |word| word.dup.force_encoding(Encoding::UTF_8) }
        words = words.map(&:b) unless words.all?(&:valid_encoding?)
        words.map do |word|
          next "''" if word.empty?

          escaped = word.gsub(%r{[^A-Za-z0-9_\-.,:+/@=\n]}) { |char| "\\#{char}" }.gsub("\n", "'\n'")
          # zsh expands a word that starts with `=`.
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
      # against someone else's Gemfile.lock.
      def self.bundle_warning(root, cwd)
        return nil unless ENV["BUNDLE_BIN_PATH"] && defined?(::Bundler) && ::Bundler.respond_to?(:default_gemfile)

        # Bundler's path comes from ENV, which a C locale tags binary whatever
        # the default; spelled in the app's encoding, it joins its name.
        given = ::Bundler.default_gemfile.to_s.dup.force_encoding(root.encoding)
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
        "[rails-ai-context] WARNING: #{where} boots against the bundle of #{bundle_gemfile} under bundle exec, " \
          "not its own. Run it without bundle exec#{inside}, or point BUNDLE_GEMFILE at the app's Gemfile."
      rescue StandardError
        nil
      end

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
