# frozen_string_literal: true

require "json"
require "rbconfig"

module RailsAiContext
  # What Claude Code's own settings and config say about the gem's server for
  # one app. Claude Code decides per session, by the folder it started in; the
  # sessions that matter are those started where the plugin serves this app.
  class ClaudeCodeSettings
    # shortcut: the managed file and its drop-ins only, not an MDM profile or the Windows registry; read those once someone deploys the plugin that way.
    MANAGED_SETTINGS = if Gem.win_platform?
      "C:/Program Files/ClaudeCode/managed-settings.json"
    elsif RbConfig::CONFIG["host_os"].match?(/darwin/)
      "/Library/Application Support/ClaudeCode/managed-settings.json"
    else
      "/etc/claude-code/managed-settings.json"
    end

    PLUGIN_SERVER = "plugin:rails-ai-context:rails-ai-context"

    # A server of the gem's that sessions started in `sessions` would start
    # beside the plugin's: from the .mcp.json at `config`, or the user's or
    # local scope, the local one kept under the project `key`.
    Duplicate = Data.define(:scope, :name, :config, :key, :sessions)

    # Both live under CLAUDE_CONFIG_DIR when it is set, else in the home folder.
    def self.user_config_dir
      config_dir || File.join(Dir.home, ".claude")
    rescue ArgumentError
      nil
    end

    def self.user_claude_json
      config_dir ? File.join(config_dir, ".claude.json") : File.join(Dir.home, ".claude.json")
    rescue ArgumentError
      nil
    end

    def self.config_dir
      dir = ENV["CLAUDE_CONFIG_DIR"]
      dir unless dir.to_s.empty?
    end
    private_class_method :config_dir

    def initialize(root, config_dir: self.class.user_config_dir, claude_json: self.class.user_claude_json, managed: MANAGED_SETTINGS)
      @root = root
      @config_dir = config_dir
      @claude_json = claude_json
      @managed = managed
      @serves = {}
      @settings = {}
    end

    # Whether the rails-ai-context plugin serves this app in some session.
    def plugin?
      !plugin_id.nil?
    end

    # The plugin's id as Claude Code names it, from whichever marketplace.
    def plugin_id
      sessions.lazy.filter_map { |folder| running_plugin_id(folder) }.first
    end

    # Whether a session started in that folder runs the plugin for this app.
    def plugin_on_in?(folder)
      !plugin_id_in(folder).nil?
    end

    # The plugin's id in a session started in that folder, nil where it does not run there.
    def plugin_id_in(folder)
      running_plugin_id(folder) if serves_from?(folder)
    end

    # Whether a session started in that folder has the plugin enabled and installed, running or not.
    def plugin_enabled_in?(folder)
      serves_from?(folder) && enabled_plugin_ids(folder).any? { |id| installed?(id) }
    end

    # Whether /mcp turned the plugin's server off for a session started in that folder.
    def plugin_server_off_in?(folder)
      serves_from?(folder) && turned_off?(folder)
    end

    # The folders whose sessions run the plugin for this app.
    def plugin_sessions
      sessions.select { |folder| running_plugin_id(folder) }
    end

    # The id of a plugin a session enables but this machine never installed.
    def uninstalled_plugin_id
      sessions.lazy.flat_map { |folder| enabled_plugin_ids(folder) }.find { |id| !installed?(id) }
    end

    # Every server of the gem's a session with the plugin on would also start.
    def duplicates
      found = plugin_sessions.flat_map do |folder|
        off = off_in(folder)
        project = mcp_json_files(folder).flat_map do |path|
          duplicates_in(read(path), folder, scope: :project, config: path) { |name| mcpjson_disabled?(name, folder) || off.include?(name) }
        end
        project +
          duplicates_in(claude_config, folder, scope: :user) { |name| off.include?(name) } +
          duplicates_in(project(folder), folder, scope: :local, key: project_key(folder)) { |name| off.include?(name) }
      end
      found.group_by { |dup| [ dup.scope, dup.name, dup.config, dup.key ] }.map do |_, group|
        group.first.with(sessions: group.flat_map(&:sessions).uniq)
      end
    end

    private

    # The app, the two folders above it (as deep as a walk down reaches), and
    # the folders Claude Code keeps projects for, where the plugin serves this app.
    def sessions
      @sessions ||= [ @root, File.dirname(@root), File.dirname(@root, 2), *hash_or_empty(claude_config["projects"]).keys ]
                    .uniq.select { |folder| related?(folder) && serves_from?(folder) }
    end

    def running_plugin_id(folder)
      enabled_plugin_ids(folder).find { |id| installed?(id) } unless turned_off?(folder)
    end

    # The servers of the gem's for this app that a holder's mcpServers names, unless the block skips them.
    def duplicates_in(holder, folder, scope:, config: nil, key: nil)
      servers_in(holder).filter_map do |name, entry|
        next if yield(name) || !serves_this_app?(entry, folder)

        Duplicate.new(scope: scope, name: name, config: config, key: key, sessions: [ folder ])
      end
    end

    def enabled_plugin_ids(folder)
      enabled = settings_for(folder).each_with_object({}) { |data, merged| merged.merge!(hash_or_empty(data["enabledPlugins"])) }
      enabled.select { |id, on| id.start_with?("rails-ai-context@") && (on == true || on.is_a?(Array)) }.keys
    end

    # Installed where the install registry lists it, or taken on trust where
    # the registry is there but cannot be read. A machine that never installed
    # a plugin has no registry.
    def installed?(id)
      return true if registry.nil?

      entry = registry[id]
      entry.is_a?(Array) ? entry.any? : entry.is_a?(Hash)
    end

    def registry
      return @registry if defined?(@registry)

      path = @config_dir && File.join(@config_dir, "plugins", "installed_plugins.json")
      @registry = if path.nil? then nil
      elsif !File.exist?(path) then {}
      else
        plugins = read(path)&.dig("plugins")
        plugins.is_a?(Hash) ? plugins : nil
      end
    end

    def turned_off?(folder)
      off_in(folder).include?(PLUGIN_SERVER)
    end

    # The servers /mcp turned off for the project a session in that folder belongs to.
    def off_in(folder)
      Array(project(folder)["disabledMcpServers"])
    end

    def mcpjson_disabled?(name, folder)
      (settings_for(folder) + [ project(folder) ]).any? { |data| Array(data["disabledMcpjsonServers"]).include?(name) }
    end

    # Whether the plugin, started in that folder, serves this app, and the server would read it.
    def serves_from?(folder)
      @serves.fetch(folder) do
        served = CLI::AppRoot.resolve(cwd: File.expand_path(folder)).root
        @serves[folder] = !served.nil? && CLI::EntryBoot.app_present?(served, allow_source_only: true) &&
                          SafePath.canonical(served) == SafePath.canonical(@root)
      end
    rescue SystemCallError, ArgumentError
      @serves[folder] = false
    end

    # A server Claude Code starts in the session's folder: one naming no app
    # serves the app the session's folder resolves to, which is this one. One
    # whose app path cannot be read here (a variable in it) is not judged ours,
    # so no fix ever removes another app's server.
    def serves_this_app?(entry, folder)
      argv = McpConfigGenerator.json_argv(entry).map(&:to_s)
      folder_variable = nil
      named = McpConfigGenerator.entry_app_root(argv, folder_variable, folder)
      # The binary reads an empty app path as the folder it starts in.
      named ||= folder if argv.include?("--app-path=") || argv.each_cons(2).include?([ "--app-path", "" ])
      return SafePath.canonical(named) == SafePath.canonical(@root) if named

      argv.none? { |arg| arg == "--app-path" || arg.start_with?("--app-path=") }
    end

    def mcp_json_files(folder)
      dir = File.expand_path(folder)
      files = []
      loop do
        files << File.join(dir, ".mcp.json") if File.file?(File.join(dir, ".mcp.json"))
        break if File.dirname(dir) == dir

        dir = File.dirname(dir)
      end
      files
    end

    # The servers of the gem's an mcpServers object names, under any name and in any form.
    def servers_in(holder)
      hash_or_empty(hash_or_empty(holder)["mcpServers"]).select { |name, entry| own?(name, entry) }
    end

    # The user's, the folder's project file, the local files of its git root
    # and of the folder, then managed settings.
    def settings_for(folder)
      local_root = project_key(folder)
      @settings[folder] ||= [ (File.join(@config_dir, "settings.json") if @config_dir),
                              File.join(folder, ".claude", "settings.json"),
                              (File.join(local_root, ".claude", "settings.local.json") unless local_root == File.expand_path(folder)),
                              File.join(folder, ".claude", "settings.local.json"),
                              @managed, *Dir.glob(File.join(File.dirname(@managed.to_s), "managed-settings.d", "*.json")).sort ]
                            .compact.filter_map { |path| read(path) }
    end

    def project(folder)
      projects = hash_or_empty(claude_config["projects"])
      hash_or_empty(projects[project_key(folder)] || projects[real(project_key(folder))])
    end

    def project_key(folder)
      @project_keys ||= {}
      @project_keys[folder] ||= SafePath.git_root(File.expand_path(folder)) || File.expand_path(folder)
    end

    def claude_config
      @claude_config ||= (@claude_json && read(@claude_json)) || {}
    end

    # The app, a folder inside it, or one above it: the only folders the plugin could serve it from.
    def related?(folder)
      folder = SafePath.canonical(folder)
      root = SafePath.canonical(@root)
      SafePath.contained?(root, folder) || SafePath.contained?(folder, root)
    rescue SystemCallError, ArgumentError
      false
    end

    # Wider than McpConfigGenerator.own_entry?, which judges entries the gem
    # wrote: a server added by hand may run the binary from any path, put
    # `serve` after other flags, or run the rake task.
    def own?(name, entry)
      argv = McpConfigGenerator.unwrapped_argv(McpConfigGenerator.json_argv(entry))
      at = argv.index { |arg| File.basename(arg.tr("\\", "/"), ".*") == "rails-ai-context" }
      McpConfigGenerator.own_entry?(name, argv) || (!at.nil? && argv.drop(at + 1).include?("serve")) || argv.include?("ai:serve")
    end

    def real(folder)
      File.realpath(folder)
    rescue SystemCallError
      folder
    end

    def hash_or_empty(value) = value.is_a?(Hash) ? value : {}

    def read(path)
      data = JSON.parse(File.read(path, mode: "r:BOM|UTF-8"))
      data.is_a?(Hash) ? data : nil
    rescue SystemCallError, IOError, JSON::ParserError, EncodingError
      nil
    end
  end
end
