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
      # entry's --app-path names it. An in-Gemfile app's gemfile is the one
      # its bundle reads - its own, or the one its config/boot.rb names, a
      # monorepo's shared Gemfile - absolute, and gemfile_path is that
      # relative to the workspace.
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
                  gemfile: gemfile, gemfile_path: relative(gemfile, dir))
        end
      end

      # The Gemfile the app's bundle reads, by GemLock's answer: the app's
      # own, else the one its config/boot.rb points Bundler at.
      def bundle_gemfile(root)
        found = GemLock.bundle(root).gemfile
        found && File.file?(found) ? found : File.join(root, GemLock.gemfile_name(root))
      end

      # A path as the workspace's config spells it: from the workspace, with
      # both sides resolved, so a symlinked temp or home directory does not
      # turn it into a walk through the filesystem root.
      def relative(path, dir)
        Pathname.new(resolved(path)).relative_path_from(Pathname.new(resolved(dir))).to_s
      end

      # The real path, or for a file not there yet its directory's.
      def resolved(path)
        return File.realpath(path) if File.exist?(path)

        dir = File.dirname(path)
        File.join(File.exist?(dir) ? File.realpath(dir) : File.expand_path(dir), File.basename(path))
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
      # or its whole path, shortened where that was needed. A numbered name is
      # not claimed: `rails-ai-context-api-2` is as likely a second entry
      # somebody made by hand.
      def generated_name?(name, path)
        rest = name.delete_prefix(PREFIX)
        return false if rest == name

        [ slug(File.basename(path)), slug(path) ].uniq.any? { |base| rest == fit(base, path) }
      end

      # Letters, digits, `_` and `-`: what every client accepts in a server
      # name, Codex's bare TOML key included.
      def slug(text)
        slug = text.gsub(/[^A-Za-z0-9_-]+/, "-").gsub(/-{2,}/, "-").delete_prefix("-").delete_suffix("-")
        slug.empty? ? "app" : slug
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
