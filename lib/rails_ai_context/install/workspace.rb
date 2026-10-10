# frozen_string_literal: true

require "digest"
require "pathname"

module RailsAiContext
  module Install
    # A folder an editor or agent is opened at that is no Rails app and holds
    # apps one or two levels down (CONTEXT.md, Workspace). AI tools read their
    # MCP config from the opened folder only, so the workspace's own configs
    # carry one server per app, each pointed at its app by a relative
    # --app-path, while each app keeps its own .rails-ai-context.yml and
    # context files, since that is where its server reads them.
    module Workspace
      PREFIX = "#{McpConfigGenerator::SERVER_NAME}-"

      # Tools put the server's name in front of each tool's, and cap the
      # result: Cursor drops a tool whose server and tool names pass 60
      # characters together, Codex up to v0.100 capped mcp__<server>__<tool>
      # at 64, and the longest built-in tool name is 27. A longer app name
      # keeps its start and gains a hash of its path, so it stays unique.
      MAX_SERVER_NAME = 30

      # root is absolute; path is root relative to the workspace, as the
      # entry's --app-path names it. gemfile is the Gemfile the app's bundle
      # reads, absolute, and gemfile_path that relative to the workspace;
      # both are nil when the app has none bundle exec could find.
      App = Struct.new(:root, :path, :server_name, :standalone, :gemfile, :gemfile_path, keyword_init: true) do
        # The app's MCP entry. An in-Gemfile app's names its bundle's Gemfile,
        # which bundle exec, started in the workspace, would never find.
        def server
          McpConfigGenerator::Server.new(name: server_name, standalone: standalone, app_path: path,
                                         gemfile: standalone ? nil : gemfile_path, announce: announced_name)
        end

        # The entry's name with the app first, so that the 13 characters VS
        # Code keeps of it tell one app's tools from another's.
        def announced_name
          "#{server_name.delete_prefix(PREFIX)}-#{McpConfigGenerator::SERVER_NAME}"
        end
      end

      module_function

      # @param dir [String] the workspace, absolute
      # @param roots [Array<String>] the app roots below it, absolute
      # @return [Array<App>] in the order given
      def apps(dir, roots)
        paths = roots.map { |root| root.delete_prefix("#{dir.delete_suffix('/')}/") }
        names = server_names(paths)
        roots.zip(paths).map do |root, path|
          gemfile = bundle_gemfile(root)
          App.new(root: root, path: path, server_name: names.fetch(path), standalone: InstallMode.standalone?(root: root),
                  gemfile: gemfile, gemfile_path: gemfile && relative(gemfile, dir))
        end
      end

      # The Gemfile the app's bundle reads, in GemLock's order: the app's own
      # when it is locked or nothing else is named, else the one its
      # config/boot.rb names, inside a repository or not, else the one
      # bundle exec run inside the app would find. Each is named as it is
      # written, never through a link it may be, since Bundler names the
      # lockfile after the path it is given. nil when there is none, and the
      # entry then names none either.
      def bundle_gemfile(root)
        own = File.join(root, GemLock.gemfile_name(root))
        boot = GemLock.boot_gemfile(root)
        boot = nil unless boot && File.file?(boot)
        return own if File.file?(own) && (boot.nil? || File.file?(File.join(root, GemLock.lockfile_name(root))))

        boot || nearest_gemfile(root)
      end

      # Bundler's own search: gems.rb, then Gemfile, in the app and in each
      # directory above it.
      def nearest_gemfile(root)
        dir = root
        loop do
          found = %w[gems.rb Gemfile].map { |name| File.join(dir, name) }.find { |path| File.file?(path) }
          return found if found

          parent = File.dirname(dir)
          return nil if parent == dir

          dir = parent
        end
      end

      # A path as the workspace's config spells it: from the workspace as
      # written where it lies below it, else from both sides resolved, so a
      # symlinked temp or home directory does not turn it into a walk
      # through the filesystem root. A Gemfile's own name is never resolved:
      # Bundler takes the lockfile's name from the path it is given, so a
      # Gemfile linked in from elsewhere keeps the lockfile beside the link.
      def relative(path, dir)
        below = path.delete_prefix("#{dir.delete_suffix('/')}/")
        return below unless below == path

        resolved = File.join(SafePath.canonical(File.dirname(path)), File.basename(path))
        Pathname.new(resolved).relative_path_from(Pathname.new(SafePath.canonical(dir))).to_s
      end

      # One stable name per app path: the folder's name, or its whole path
      # where two apps share a folder name, so adding an app elsewhere never
      # renames one that has no twin. A name that is still taken gets a
      # number, in path order, and a name too long for the clients keeps its
      # start and gains a short hash of the path.
      #
      # @param paths [Array<String>] app paths relative to the workspace
      # @return [Hash{String => String}] path => server name
      def server_names(paths)
        base = paths.to_h { |path| [ path, slug(File.basename(path)) ] }
        twins = base.values.tally.select { |_, count| count > 1 }.keys
        wanted = paths.to_h { |path| [ path, twins.include?(base[path]) ? slug(path) : base[path] ] }

        used = []
        names = {}
        paths.sort.each do |path|
          name = fit(wanted[path], path)
          number = 1
          name = fit(wanted[path], path, "-#{number += 1}") while used.include?(name)
          used << name
          names[path] = PREFIX + name
        end
        paths.to_h { |path| [ path, names[path] ] }
      end

      # Whether `name` is one server_names gives the app at `path` (relative
      # to the workspace) alongside some other set of apps: its folder's name
      # or its whole path, shortened where that was needed, numbered where it
      # was taken. Two folders named outside ASCII both come out `app`, so
      # the gem numbers its own names, and a numbered one it never claimed
      # stayed behind when its app went: two servers for one app, or one
      # that names no folder.
      def generated_name?(name, path)
        rest = name.delete_prefix(PREFIX)
        return false if rest == name

        number = rest[/-(\d+)\z/, 1]
        suffixes = [ "" ]
        suffixes << "-#{number}" if number && number.to_i >= 2
        [ slug(File.basename(path)), slug(path) ].uniq.any? do |base|
          suffixes.any? { |suffix| rest == fit(base, path, suffix) }
        end
      end

      # Letters, digits, `_` and `-`: what every client accepts in a server
      # name, Codex's bare TOML key included. Read as bytes, so a folder
      # named in Latin-1 slugs like any other.
      def slug(text)
        slug = text.b.gsub(/[^A-Za-z0-9_-]+/n, "-").gsub(/-{2,}/, "-").delete_prefix("-").delete_suffix("-")
        slug.empty? ? "app" : slug.force_encoding(Encoding::UTF_8)
      end

      # Each numbered try differs from every other in its suffix, so the
      # search for a free name ends.
      def fit(slug, path, suffix = "")
        room = MAX_SERVER_NAME - PREFIX.size - suffix.size
        return slug + suffix if slug.size <= room

        hash = Digest::SHA256.hexdigest(path)[0, 6]
        "#{slug[0, [ room - hash.size - 1, 1 ].max].delete_suffix('-')}-#{hash}#{suffix}"
      end
    end
  end
end
