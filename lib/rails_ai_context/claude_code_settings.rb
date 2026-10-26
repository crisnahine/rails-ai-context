# frozen_string_literal: true

require "rbconfig"
require "uri"
require_relative "cli/app_root"
require_relative "polyfill/data"
require_relative "mcp_config_generator"

# json is a gem an app's bundle pins, so it loads when first named, after that bundle.
autoload :JSON, "json"

module RailsAiContext
  # What Claude Code's own settings and config say about the gem's server for
  # one app. Claude Code decides per session, by the folder it started in; the
  # sessions that matter are those started where the plugin serves this app.
  class ClaudeCodeSettings
    # shortcut: the managed file and its drop-ins only, merged as if all in force; server-managed (console) settings, an
    # MDM profile and the Windows registry are not read. Read those once someone deploys the plugin that way.
    MANAGED_SETTINGS = if Gem.win_platform?
      "C:/Program Files/ClaudeCode/managed-settings.json"
    elsif RbConfig::CONFIG["host_os"].match?(/darwin/)
      "/Library/Application Support/ClaudeCode/managed-settings.json"
    else
      "/etc/claude-code/managed-settings.json"
    end

    PLUGIN_SERVER = "plugin:rails-ai-context:rails-ai-context"

    # A server of the gem's that sessions started in `sessions` would start beside the plugin's.
    Duplicate = Data.define(:scope, :name, :config, :key, :sessions)

    # A plugin the MCP or marketplace policy keeps from starting in a session started in `folder`: `path` is
    # the settings file that decides, `command` the line an allowlist entry has to name, nil when unknown.
    Blocked = Data.define(:id, :command, :rule, :scope, :folder, :path)

    # The install Claude Code's registry records, at its scope and project.
    Install = Data.define(:scope, :path)

    # Whether the plugin the committed settings turn on runs in a session started in a folder. cause is nil where it
    # runs, else :managed_mcp, :turned_off (scope and path name the winning file) or :not_running (doctor names why).
    PluginServing = Data.define(:runs, :cause, :scope, :path, :duplicates) do
      def runs? = runs
    end

    # The folder of settings.json and plugins/, nil where a relative CLAUDE_CONFIG_DIR leaves it unknown.
    def self.user_config_dir
      value, = config_dir_setting
      return launch_config_dir if value.nil?

      absolute_dir?(value) ? value : nil
    end

    # .claude.json stays with the folder Claude Code was launched with, and
    # Claude Code keeps using its older .config.json wherever one is left.
    def self.user_claude_json
      dir = launch_config_dir or return nil
      legacy = File.join(dir, ".config.json")
      return legacy if File.exist?(legacy)

      ENV["CLAUDE_CONFIG_DIR"] ? File.join(dir, ".claude.json") : File.join(home, ".claude.json")
    rescue ArgumentError
      nil
    end

    # Set but not absolute, empty included, it sends Claude Code to read its config under
    # whatever folder each session starts in, which no one reading from here can name.
    def self.relative_config_dir?
      value, = config_dir_setting
      !value.nil? && !absolute_dir?(value)
    end

    # A managed file's env block (the last drop-in first) wins over the launch folder's settings.json, and both over the shell.
    def self.config_dir_setting
      shell = ENV["CLAUDE_CONFIG_DIR"]
      launch = launch_config_dir
      files = [ *managed_files(MANAGED_SETTINGS).reverse.map { |path| [ path, :managed ] }, *([ [ File.join(launch, "settings.json"), :user ] ] if launch) ]
      files.each do |path, scope|
        value = env_config_dir(path, scope)
        return [ value, path ] if value
      end
      [ shell, nil ] unless shell.nil?
    end

    # Claude Code goes by Node's rule, which on Windows takes a path rooted on the current drive
    # (\x or /x) as absolute where Ruby asks for a drive letter.
    def self.absolute_dir?(dir)
      File.absolute_path?(dir) || (Gem.win_platform? && dir.match?(%r{\A[\\/]}))
    end

    # A managed settings file and its drop-ins, in the order Claude Code merges them.
    def self.managed_files(managed)
      return [] unless managed

      drop_ins = File.join(File.dirname(managed), "managed-settings.d")
      [ managed, *Dir.glob("*.json", base: drop_ins).sort.map { |name| File.join(drop_ins, name) } ]
    end

    def self.launch_config_dir
      shell = ENV["CLAUDE_CONFIG_DIR"]
      return File.join(home, ".claude") if shell.nil?

      shell if absolute_dir?(shell)
    rescue ArgumentError
      nil
    end
    private_class_method :launch_config_dir

    # Claude Code's home on Windows is %USERPROFILE%, which Ruby prefers only to an unset HOME.
    def self.home
      profile = ENV["USERPROFILE"].to_s
      Gem.win_platform? && !profile.empty? ? profile : Dir.home
    end
    private_class_method :home

    # A settings file Claude Code drops moves nothing. A value that is no string, null included, it reads as text.
    def self.env_config_dir(path, scope)
      env = settings_file(path, scope)&.dig("env")
      return nil unless env.is_a?(Hash) && env.key?("CLAUDE_CONFIG_DIR")

      value = env["CLAUDE_CONFIG_DIR"]
      value.is_a?(String) ? value : value.to_s
    end
    private_class_method :env_config_dir

    # A settings file as Claude Code takes it: one whose enabledPlugins fails its schema it drops whole, a managed one less what fails.
    # shortcut: only enabledPlugins is checked, though Claude Code drops a non-managed file for any schema error; check more keys once one misleads.
    def self.settings_file(path, scope)
      data = path && read_json(path) or return nil
      return data unless data.key?("enabledPlugins")

      plugins = data["enabledPlugins"]
      valid = (plugins.is_a?(Hash) ? plugins : {}).select { |_, on| on == true || on == false || (on.is_a?(Array) && on.all?(String)) }
      return data.merge("enabledPlugins" => valid) if scope == :managed

      plugins.is_a?(Hash) && valid.size == plugins.size ? data : nil
    end

    def self.read_json(path)
      data = JSON.parse(File.read(path, mode: "r:BOM|UTF-8"))
      data.is_a?(Hash) ? data : nil
    rescue SystemCallError, IOError, JSON::ParserError, EncodingError
      nil
    end

    # Whether the app's committed project settings turn the plugin on for
    # everyone who opens it there.
    def self.committed?(root)
      !committed_id(root).nil?
    end

    def self.committed_id(root)
      new(root, config_dir: nil, claude_json: nil, managed: nil).committed_id(root)
    end

    def initialize(root, from: nil, config_dir: self.class.user_config_dir, claude_json: self.class.user_claude_json, managed: MANAGED_SETTINGS)
      @root = root
      @from = from
      @config_dir = config_dir
      @claude_json = claude_json
      @managed = managed
      @serves = {}
      @settings = {}
      @project_keys = {}
    end

    # Whether the rails-ai-context plugin serves this app in some session.
    def plugin?
      !plugin_id.nil?
    end

    # The plugin's id as Claude Code names it, from whichever marketplace: of several, the last
    # merged, whose copy Claude Code runs.
    def plugin_id
      sessions.lazy.filter_map { |folder| running_ids(folder).last }.first
    end

    # Whether a session started in that folder runs the plugin for this app.
    def plugin_on_in?(folder)
      !plugin_id_in(folder).nil?
    end

    # Every id the plugin runs under in a session started in that folder:
    # Claude Code starts its server while any one of them is on.
    def plugin_ids_in(folder)
      serves_from?(folder) ? running_ids(folder) : []
    end

    # Whether a session started in that folder has the plugin enabled and installed, running or not.
    def plugin_enabled_in?(folder)
      serves_from?(folder) && installed_ids(folder).any?
    end

    # Whether /mcp turned the plugin's server off for a session started in that folder.
    def plugin_server_off_in?(folder)
      serves_from?(folder) && turned_off?(folder)
    end

    # The folders whose sessions run the plugin for this app.
    def plugin_sessions
      sessions.select { |folder| running_ids(folder).any? }
    end

    # Whether some session that would serve this app enables the plugin,
    # whether or not it is installed, on in /mcp, or let through by policy.
    def plugin_chosen?
      !enabled_plugin_id.nil?
    end

    # The id such a session enables the plugin under, nil where none does.
    def enabled_plugin_id
      sessions.lazy.flat_map { |folder| enabled_ids(folder) }.first
    end

    # The settings that turn the plugin on, as :user, :project, :local or
    # :managed: the last file Claude Code merges that sets the id.
    def enabled_scope(id)
      folder = sessions.find { |session| enabled_ids(session).include?(id) } or return nil
      setting_scope(id, folder)
    end

    # The id of a plugin a session enables but this machine never installed for it.
    def uninstalled_plugin_id
      sessions.lazy.flat_map { |folder| enabled_ids(folder).reject { |id| installed?(id, folder) } }.first
    end

    # The id of an installed plugin a session enables but whose server /mcp turned off there.
    def switched_off_plugin_id
      sessions.lazy.flat_map { |folder| turned_off?(folder) ? installed_ids(folder) : [] }.first
    end

    # An enabled, installed plugin whose server Claude Code's MCP policy keeps from starting.
    def blocked_plugin
      sessions.lazy.filter_map { |folder| block_in(folder) }.first
    end

    # What keeps the enabled, installed plugin's server from starting in a session started in that folder, nil where nothing does.
    def block_in(folder)
      return nil if !serves_from?(folder) || turned_off?(folder)

      installed_ids(folder).lazy.filter_map do |id|
        command = plugin_command(id, folder)
        rule, scope, path = plugin_block(id, command, folder)
        Blocked.new(id: id, command: command, rule: rule, scope: scope, folder: folder, path: path) if rule
      end.first
    end

    # The folders whose sessions have that plugin id enabled and installed, its server on in /mcp or not.
    def enabled_sessions(id)
      sessions.select { |folder| installed_ids(folder).include?(id) }
    end

    # The folders whose sessions have the plugin enabled and installed, and its server turned off in /mcp.
    def plugin_off_sessions
      sessions.select { |folder| turned_off?(folder) && installed_ids(folder).any? }
    end

    # Why Claude Code's MCP policy keeps a session started in that folder from
    # starting the named server, as [rule, scope], nil where it starts it.
    def server_block(name, argv, folder, url: nil)
      block(name, argv, folder, url: url)&.first(2)
    end

    # Every deniedMcpServers entry that names the server, its command or, for a remote one, its url, as
    # [scope, entry, path], the managed ones first: each holds on its own, and only an admin lifts those.
    def deny_rules(name, command, folder, url: nil)
      commands = commands_of(command, folder)
      scoped_settings(folder).reverse.flat_map do |scope, data, path|
        rules(data["deniedMcpServers"]).select do |rule|
          rule["serverName"] == name || (url ? url_match?(rule["serverUrl"], url) : commands.include?(rule["serverCommand"]))
        end.map { |rule| [ scope, rule, path ] }
      end
    end

    # Whether an allowlist in force names a command, after which Claude Code admits every stdio server by command alone.
    def allowlist_by_command?(folder)
      allowlists(scoped_settings(folder)).any? { |_, data| rules(data["allowedMcpServers"]).any? { |rule| rule.key?("serverCommand") } }
    end

    # Whether an allowlist in force names a url, after which Claude Code admits every remote server by url alone.
    def allowlist_by_url?(folder)
      allowlists(scoped_settings(folder)).any? { |_, data| rules(data["allowedMcpServers"]).any? { |rule| rule.key?("serverUrl") } }
    end

    # The file an :allowlist block names: the first list in force, as #allowlist_block takes its scope from.
    def allowlist_file(folder)
      allowlists(scoped_settings(folder)).first&.last
    end

    # Whether a session started in that folder serves this app and enables the plugin, installed or not.
    def plugin_chosen_in?(folder)
      serves_from?(folder) && enabled_ids(folder).any?
    end

    # Every id the plugin is enabled and installed under in a session that would serve this app.
    def enabled_plugin_ids
      sessions.flat_map { |folder| installed_ids(folder) }.uniq
    end

    # The names of the gem's servers that the config at path holds for this app, as a session in that folder reads them.
    def gem_server_names(path, folder)
      servers_in(read(path)).select { |_, entry| serves_this_app?(entry, folder) }.keys
    end

    # Whether the plugin is installed for the project of a session started in that folder.
    def installed_in?(id, folder)
      installed?(id, folder)
    end

    # The registry installs that serve the sessions enabling that id: Claude
    # Code removes an install by its own scope and project.
    def installs_for(id)
      return [] unless registry.is_a?(Hash)

      folders = enabled_sessions(id)
      Array(registry[id]).select { |install| install.is_a?(Hash) && folders.any? { |folder| installed_for?(install, folder) } }
                         .map { |install| Install.new(scope: install["scope"] || "user", path: install["projectPath"]) }.uniq
    end

    # Where an install of an enabled plugin belongs: the user's scope where user or managed settings
    # enable it, else local, which leaves a committed project file as it is.
    def install_scope(id)
      %i[user managed].include?(enabled_scope(id)) ? "user" : "local"
    end

    # Whether a managed settings file sets the plugin there, which no local setting can turn off.
    def managed_in?(id, folder)
      scoped_settings(folder).any? { |scope, data| scope == :managed && hash_or_empty(data["enabledPlugins"]).key?(id) }
    end

    # The one answer init and doctor render. Only a winning true turns a plugin on: a local or managed false, a
    # version list or any other value turns the committed one off.
    def serving(folder)
      return PluginServing.new(runs: false, cause: :managed_mcp, scope: nil, path: nil, duplicates: duplicates) if managed_mcp

      scope, value, path = setting_for(committed_id(folder), folder)
      if %i[local managed].include?(scope) && value != true
        return PluginServing.new(runs: false, cause: :turned_off, scope: scope, path: path, duplicates: duplicates)
      end

      runs = absent? || plugin_on_in?(folder)
      PluginServing.new(runs: runs, cause: (:not_running unless runs), scope: nil, path: nil, duplicates: duplicates)
    end

    # Whether the project settings a session started in that folder reads,
    # the committed .claude/settings.json, enable the plugin.
    def committed_in?(folder)
      !committed_id(folder).nil?
    end

    # The id those committed settings enable the plugin under.
    def committed_id(folder)
      scoped_settings(folder).filter_map { |scope, data| turned_on(data).first if scope == :project }.first
    end

    # The gem requirement of the plugin copy that runs for this app, every
    # bound scripts/gem_requirement.rb names; nil where it cannot be read.
    # Read as text, never run: the plugin's folder can come from a repository's committed settings.
    def plugin_gem_requirement
      folder = plugin_sessions.first or return nil
      root = plugin_root(plugin_id_in(folder), folder) or return nil
      bounds = File.read(File.join(root, "scripts", "gem_requirement.rb"), 4096)[/GEM_REQUIREMENT\s*=\s*(.+)$/, 1].to_s.scan(/"([^"]+)"/).flatten
      bounds unless bounds.empty?
    rescue SystemCallError, IOError
      nil
    end

    # Whether Claude Code has recorded the marketplace the id comes from, so an install needs no source.
    def marketplace_known?(id)
      !recorded_marketplaces[id.split("@", 2).last].nil?
    end

    # Whether Claude Code runs the plugin from a marketplace it reads in place, with no install at all.
    def local_marketplace?(id, folder = @root)
      !local_marketplace(id, folder).nil?
    end

    # The local marketplace's folder once it is gone, or a file source's marketplace.json once that is.
    def missing_marketplace(id, folder)
      dir = local_marketplace(id, folder) or return nil
      return dir unless File.directory?(dir)
      return nil if marketplace(id, folder).dig("source", "source") == "directory"

      listing = File.join(dir, ".claude-plugin", "marketplace.json")
      listing unless File.file?(listing)
    end

    # The local marketplace's folder where it is there but Claude Code finds no plugin in it to load.
    def marketplace_without_plugin(id, folder)
      dir = local_marketplace(id, folder) or return nil
      dir unless missing_marketplace(id, folder) || local_plugin?(id, folder)
    end

    # The folder whose .claude/settings.local.json wins for a session started in `folder`: the repository's main
    # checkout, but the session's own folder on Windows, in a home-folder or bare repository, or one another user owns.
    def local_settings_dir(folder)
      here = File.expand_path(folder)
      root = SafePath.git_root(here)
      return here if root.nil? || Gem.win_platform?

      main = main_checkout(root)
      main && !home?(main) && owned?(main) ? main : here
    end

    # Managed files that are there but hold no JSON object, which keep Claude Code from starting at all.
    # Claude Code reads an empty or blank one as no settings.
    def broken_managed_files
      managed_files.select do |path|
        !File.read(path, mode: "r:BOM|UTF-8").b.strip.empty? && read(path).nil?
      rescue SystemCallError, IOError
        false
      end
    end

    # The project Claude Code files a folder's local settings and servers under.
    def project_of(folder)
      project_key(folder)
    end

    # Where managed-mcp.json sits beside the managed settings, Claude Code
    # starts that file's servers alone: no plugin's, user's, project's or local one.
    def managed_mcp
      return @managed_mcp if defined?(@managed_mcp)

      path = @managed && File.join(File.dirname(@managed), "managed-mcp.json")
      @managed_mcp = path && File.file?(path) ? path : nil
    end

    # The url Claude Code connects a remote server at from that folder, expanded as it expands one.
    def server_url(url, folder)
      expanded(url.to_s, folder)
    end

    # The name of the gem's server in managed-mcp.json that a session started in that folder starts for this app.
    def managed_server(folder)
      managed_servers(folder).find { |_, held, _| held.nil? }&.first
    end

    # The gem's servers in managed-mcp.json that serve this app, with what keeps each off there. A deny holds,
    # and an allowlist only for an entry Claude Code expands a variable in; the lock does not.
    def managed_servers(folder)
      path = managed_mcp or return []
      servers_in(read(path)).select { |_, entry| serves_this_app?(entry, folder) }.map do |name, entry|
        command = McpConfigGenerator.json_argv(entry).map(&:to_s)
        url = url_of(name, entry, folder)
        denied = deny_rules(name, command, folder, url: url).first
        held = if off_in(folder).include?(name) then [ :off ]
        elsif denied then [ :denied, denied.first ]
        elsif JSON.generate(entry).include?("${") then allowlist_block(name, command, scoped_settings(folder), folder, url: url)&.first(2)
        end
        [ name, held, command, url ]
      end
    end

    # Whether Claude Code never ran here, as on CI: no config folder and no .claude.json, so nothing
    # can be installed and an app's committed setting is its whole setup.
    def absent?
      return @absent if defined?(@absent)

      @absent = (@config_dir.nil? || !File.directory?(@config_dir)) && !(@claude_json && File.exist?(@claude_json))
    end

    # Every server of the gem's a session with the plugin on would also start.
    def duplicates
      found = plugin_sessions.flat_map do |folder|
        off = off_in(folder)
        project = mcp_json_files(folder).flat_map do |path|
          duplicates_in(read(path), folder, scope: :project, config: path) { |name| mcpjson_disabled?(name, folder) || off.include?(name) }
        end
        project +
          duplicates_in(claude_config, folder, scope: :user, user: true) { |name| off.include?(name) } +
          duplicates_in(project(folder), folder, scope: :local, key: project_key(folder)) { |name| off.include?(name) }
      end
      found.group_by { |dup| [ dup.scope, dup.name, dup.config, dup.key ] }.map do |_, group|
        group.first.with(sessions: group.flat_map(&:sessions).uniq)
      end
    end

    private

    # The plugin's id in a session started in that folder, nil where it does not run there.
    def plugin_id_in(folder)
      plugin_ids_in(folder).last
    end

    # The scope of the last settings file a session started in that folder
    # merges that sets the id, which is the one whose value holds.
    def setting_scope(id, folder)
      setting_for(id, folder)&.first
    end

    # That last file as [scope, value, path].
    def setting_for(id, folder)
      scope, data, path = scoped_settings(folder).reverse.find { |_, file| hash_or_empty(file["enabledPlugins"]).key?(id) }
      [ scope, data["enabledPlugins"][id], path ] if scope
    end

    # The folders a session serving this app could start in: the app, the two above it (as deep as a walk
    # down reaches), the one the command was typed in, and the projects Claude Code keeps.
    def sessions
      @sessions ||= [ @root, File.dirname(@root), File.dirname(@root, 2), *(@from && File.expand_path(@from.to_s)),
                      *hash_or_empty(claude_config["projects"]).keys ]
                    .uniq.select { |folder| related?(folder) && serves_from?(folder) }
    end

    def running_ids(folder)
      return [] if turned_off?(folder)

      installed_ids(folder).reject { |id| plugin_blocked?(id, folder) }
    end

    def installed_ids(folder)
      enabled_ids(folder).select { |id| installed?(id, folder) }
    end

    def enabled_ids(folder)
      merged = scoped_settings(folder).each_with_object({}) { |(_, data), all| all.merge!(hash_or_empty(data["enabledPlugins"])) }
      turned_on("enabledPlugins" => merged)
    end

    # The plugin's ids a settings object turns on. Only `true` does: a list of
    # version constraints never matches a plugin versioned by commit.
    def turned_on(data)
      hash_or_empty(data["enabledPlugins"]).select { |id, on| id.start_with?("rails-ai-context@") && on == true }.keys
    end

    # The servers of the gem's for this app that a holder's mcpServers names,
    # unless the block skips them or Claude Code's policy never starts them.
    def duplicates_in(holder, folder, scope:, config: nil, key: nil, user: false)
      servers_in(holder, user: user).filter_map do |name, entry|
        next if yield(name) || !serves_this_app?(entry, folder)
        next if block(name, McpConfigGenerator.json_argv(entry).map(&:to_s), folder, url: url_of(name, entry, folder))

        Duplicate.new(scope: scope, name: name, config: config, key: key, sessions: [ folder ])
      end
    end

    # Taken on trust where Claude Code never ran or its registry cannot be read; none at all means never installed.
    # A local marketplace decides alone: Claude Code runs its plugin with no install, and nothing once it is gone.
    def installed?(id, folder)
      return true if absent?
      return local_plugin?(id, folder) if local_marketplace(id, folder)
      return true if registry.nil?

      entry = registry[id]
      return entry.is_a?(Hash) unless entry.is_a?(Array)

      entry.any? { |install| install.is_a?(Hash) && installed_for?(install, folder) }
    end

    # A project or local install serves that project's sessions only, matched
    # by the project's git root wherever in it the install ran.
    def installed_for?(install, folder)
      return true unless %w[project local].include?(install["scope"])

      path = install["projectPath"]
      return true unless path.is_a?(String) && !path.empty?

      SafePath.canonical(project_key(path)).b == SafePath.canonical(project_key(folder)).b
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

    # The marketplace an id comes from: as Claude Code recorded it, else as the settings a
    # session in that folder reads declare it, which Claude Code acts on before it records it.
    def marketplace(id, folder)
      name = id.split("@", 2).last
      entry = recorded_marketplaces[name]
      entry ||= scoped_settings(folder).reverse.lazy.filter_map { |_, data| hash_or_empty(data["extraKnownMarketplaces"])[name] }.first
      entry.is_a?(Hash) ? entry : nil
    end

    def recorded_marketplaces
      @recorded_marketplaces ||= (@config_dir && read(File.join(@config_dir, "plugins", "known_marketplaces.json"))) || {}
    end

    # Where the plugin's files are for that folder's sessions: a local marketplace's own folder,
    # which Claude Code runs it from whatever the registry says, else the registry's install.
    def plugin_root(id, folder)
      if (source = local_marketplace(id, folder))
        listed = hash_or_empty(read(File.join(source, ".claude-plugin", "marketplace.json")))["plugins"]
        entry = Array(listed).find { |plugin| plugin.is_a?(Hash) && plugin["name"] == id.split("@", 2).first }
        return entry && entry["source"].is_a?(String) ? File.expand_path(entry["source"], source) : nil
      end

      installs = registry.is_a?(Hash) ? Array(registry[id]) : []
      installs.find { |entry| entry.is_a?(Hash) && installed_for?(entry, folder) && entry["installPath"].is_a?(String) }&.dig("installPath")
    end

    # The folder of a marketplace Claude Code reads in place: a directory, or the folder above the
    # .claude-plugin/ of a marketplace.json added by its path. Claude Code loads nothing from a relative one.
    def local_marketplace(id, folder)
      entry = marketplace(id, folder) or return nil
      source = hash_or_empty(entry["source"])
      path = source["path"]
      return nil unless %w[directory file].include?(source["source"]) && path.is_a?(String) && self.class.absolute_dir?(path)

      source["source"] == "directory" ? path : (entry["installLocation"] || File.dirname(path, 2)).to_s
    end

    def local_plugin?(id, folder)
      root = plugin_root(id, folder)
      !root.nil? && File.directory?(root)
    end

    # The command line Claude Code starts the plugin's server with, as that
    # install's own .mcp.json writes it.
    def plugin_command(id, folder)
      root = plugin_root(id, folder) or return nil
      server = hash_or_empty(hash_or_empty(read(File.join(root, ".mcp.json")))["mcpServers"])["rails-ai-context"]
      argv = McpConfigGenerator.json_argv(server).map { |arg| arg.to_s.gsub("${CLAUDE_PLUGIN_ROOT}") { root } }
      argv.empty? ? nil : argv
    end

    def plugin_blocked?(id, folder)
      !plugin_block(id, plugin_command(id, folder), folder).nil?
    end

    def plugin_block(id, command, folder)
      marketplace_block(id, folder) || block(PLUGIN_SERVER, command, folder, plugin: true)
    end

    # Claude Code loads no plugin from a marketplace a managed blockedMarketplaces entry names, or a managed
    # strictKnownMarketplaces leaves out. An entry this cannot read is no evidence either way.
    def marketplace_block(id, folder)
      source = marketplace(id, folder)&.dig("source")
      return nil unless source.is_a?(Hash)

      managed = scoped_settings(folder).select { |scope, _, _| scope == :managed }
      denied = managed.find { |_, data, _| Array(data["blockedMarketplaces"]).any? { |entry| marketplace_match(entry, source, block: true) } }
      return [ :marketplace, :managed, denied.last ] if denied

      lists = managed.filter_map { |_, data, path| (list = allowed_marketplaces(data)) && [ list, path ] }
      return nil if lists.empty? || !lists.flat_map(&:first).all? { |entry| marketplace_match(entry, source, block: false) == false }

      [ :marketplace, :managed, lists.first.last ]
    end

    # The canonical key wins over its alias in one file.
    def allowed_marketplaces(data)
      list = data.key?("strictKnownMarketplaces") ? data["strictKnownMarketplaces"] : data["allowedMarketplaces"]
      list if list.is_a?(Array)
    end

    # Whether a strictKnownMarketplaces or blockedMarketplaces entry matches a marketplace source, nil for a form this does not know.
    def marketplace_match(entry, source, block:)
      return nil unless entry.is_a?(Hash)

      kind = source["source"]
      case entry["source"]
      when "github" then github_match(entry, source, block)
      when "git" then kind == "git" && entry["url"].is_a?(String) && entry["url"] == source["url"] && git_fields_match(entry, source, block)
      when "url" then kind == "url" && entry["url"].is_a?(String) && entry["url"] == source["url"]
      when "file", "directory" then kind == entry["source"] && entry["path"].is_a?(String) && entry["path"] == source["path"]
      when "hostPattern" then pattern_match(entry["hostPattern"], marketplace_host(source))
      when "pathPattern" then pattern_match(entry["pathPattern"], (source["path"] if %w[file directory].include?(kind)))
      when "skills-dir" then false
      end
    end

    # An allowlist takes the owner/repo form alone, by case and ref; a blocklist any spelling of the
    # github.com repository, in any case and, where it names none, at any ref.
    def github_match(entry, source, block)
      return nil unless entry["repo"].is_a?(String)

      # An entry wildcarding anything but the whole name matches no real repository, as Claude Code ignores it.
      owner, name = entry["repo"].split("/", 2)
      return false if name.nil?

      repo = source["source"] == "github" ? source["repo"] : (github_repo(source["url"]) if block && source["source"] == "git")
      return false unless repo.is_a?(String)

      their_owner, their_name = repo.split("/", 2)
      same = ->(mine, theirs) { block ? mine.casecmp?(theirs.to_s) : mine == theirs }
      same.(owner, their_owner) && (name == "*" || same.(name, their_name)) && git_fields_match(entry, source, block)
    end

    def git_fields_match(entry, source, block)
      ref = block && !entry.key?("ref") ? true : entry["ref"] == source["ref"]
      ref && (!entry.key?("path") || entry["path"] == source["path"])
    end

    def github_repo(url)
      url.to_s[%r{\A(?:[a-z][a-z0-9+.-]*://)?(?:[^@/]+@)?github\.com[:/]([^/]+/[^/]+?)(?:\.git)?/?\z}i, 1]
    end

    # The host Claude Code matches a hostPattern against; a file or directory source has none.
    def marketplace_host(source)
      url = source["url"].to_s
      case source["source"]
      when "github" then "github.com"
      when "url" then URI.parse(url).host
      when "git" then url.match?(%r{\A[a-z][a-z0-9+.-]*://}i) ? URI.parse(url).host : url[/\A[^@\/:]+@([^:\/]+):/, 1]
      end
    rescue URI::Error
      nil
    end

    def pattern_match(pattern, text)
      return nil unless pattern.is_a?(String)

      !text.nil? && Regexp.new(pattern).match?(text)
    rescue RegexpError
      nil
    end

    # [rule, scope, path] of the MCP policy that keeps the server from starting there, nil where none does. A plugin
    # server's name holds colons no allowlist entry can, so only its exact command admits it; an unknown one is no evidence.
    def block(name, command, folder, plugin: false, url: nil)
      return [ :exclusive, :managed, managed_mcp ] if managed_mcp

      denied = deny_rules(name, command, folder, url: url).first
      return [ :denied, denied[0], denied[2] ] if denied

      files = scoped_settings(folder)
      lock = mcp_lock(files)
      return [ :locked, :managed, lock ] if !plugin && lock

      allowlist_block(name, command, files, folder, plugin: plugin, url: url)
    end

    # A remote server is held to the list's serverUrl entries where it has any, else to its name; serverCommand ones never touch it.
    def allowlist_block(name, command, files, folder, plugin: false, url: nil)
      lists = allowlists(files)
      return nil if lists.empty?

      allowed = lists.flat_map { |_, data| rules(data["allowedMcpServers"]) }
      by = url ? "serverUrl" : "serverCommand"
      if url
        return nil if allowed.any? { |rule| url_match?(rule["serverUrl"], url) }
      else
        commands = commands_of(command, folder)
        return nil if allowed.any? { |rule| commands.include?(rule["serverCommand"]) }
        return nil if plugin && command.nil?
      end
      return nil if !plugin && allowed.none? { |rule| rule.key?(by) } && allowed.any? { |rule| rule["serverName"] == name }

      # Managed files merge last, so the first list is a user's, project's or local one wherever there is one.
      scope, _, path = lists.first
      [ :allowlist, scope, path ]
    end

    # Claude Code checks a serverCommand rule against the command as written and as it expands it.
    def commands_of(command, folder)
      command ? [ command, command.map { |arg| expanded(arg, folder) } ].uniq : []
    end

    # The managed file that locks MCP to plugins: Claude Code fails closed on any value but an Array
    # without mcp, false or null, so 0 and "" lock too.
    def mcp_lock(files)
      files.find do |scope, data, _|
        lock = data["strictPluginOnlyCustomization"]
        scope == :managed && (lock.is_a?(Array) ? lock.include?("mcp") : ![ nil, false ].include?(lock))
      end&.last
    end

    # The files whose allowedMcpServers merge into the list in force: every file's, or the managed files' alone
    # where one sets allowManagedMcpServersOnly to anything but false, "false" or null, as Claude Code fails closed.
    def allowlists(files)
      only_managed = files.any? { |scope, data| scope == :managed && ![ false, "false", nil ].include?(data["allowManagedMcpServersOnly"]) }
      files.select { |scope, data| (!only_managed || scope == :managed) && data.key?("allowedMcpServers") }
    end

    def rules(value)
      value.is_a?(Array) ? value.select { |rule| rule.is_a?(Hash) } : []
    end

    def turned_off?(folder)
      off_in(folder).include?(PLUGIN_SERVER)
    end

    # The servers /mcp turned off for the project a session in that folder belongs to.
    def off_in(folder)
      Array(project(folder)["disabledMcpServers"])
    end

    def mcpjson_disabled?(name, folder)
      (scoped_settings(folder).map { |_, data| data } + [ project(folder) ]).any? { |data| Array(data["disabledMcpjsonServers"]).include?(name) }
    end

    # Whether the plugin, started in that folder, serves this app, and the server would read it.
    def serves_from?(folder)
      @serves.fetch(folder) do
        target = CLI::AppRoot.target(File.expand_path(folder))
        served = target.kind == :app ? [ target.root ] : target.apps.map(&:root)
        @serves[folder] = served.any? { |root| SafePath.canonical(root).b == SafePath.canonical(@root).b }
      end
    rescue SystemCallError, ArgumentError
      @serves[folder] = false
    end

    # A server Claude Code starts in the session's folder: one naming no app
    # serves the app the session's folder resolves to, which is this one. One
    # whose app path cannot be read here (a variable in it) is not judged ours,
    # so no fix ever removes another app's server.
    def serves_this_app?(entry, folder)
      argv = McpConfigGenerator.json_argv(entry).map { |arg| expanded(arg.to_s, folder) }
      folder_variable = nil
      named = McpConfigGenerator.entry_app_root(argv, folder_variable, folder)
      # The binary reads an empty app path as the folder it starts in.
      named ||= folder if argv.include?("--app-path=") || argv.each_cons(2).include?([ "--app-path", "" ])
      return SafePath.canonical(named).b == SafePath.canonical(@root).b if named

      argv.none? { |arg| arg == "--app-path" || arg.start_with?("--app-path=") }
    end

    # Claude Code expands ${VAR} and ${VAR:-default} from its own environment, where CLAUDE_PROJECT_DIR is
    # unset and PWD is the session's folder; any other form reaches the server as written.
    def expanded(arg, folder)
      arg.gsub(/\$\{CLAUDE_PROJECT_DIR:-([^}$]*)\}/, '\1').gsub(/\$\{PWD(?::-[^}]*)?\}/) { folder }
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

    # The servers of the gem's an mcpServers object names, under any name and in any form. An HTTP entry names no
    # app, so it counts under the bare name or this app's workspace name only, and at user scope the bare name alone.
    def servers_in(holder, user: false)
      remote = user ? [ McpConfigGenerator::SERVER_NAME ] : [ McpConfigGenerator::SERVER_NAME, workspace_name ]
      hash_or_empty(hash_or_empty(holder)["mcpServers"]).select do |name, entry|
        own?(name, entry) || (McpConfigGenerator.http_entry?(name, entry) && remote.include?(name))
      end
    end

    def workspace_name
      @workspace_name ||= RailsAiContext::Install::Workspace.server_names([ File.basename(@root) ]).values.first
    end

    # The url Claude Code connects a remote server at, nil for a stdio one.
    def url_of(name, entry, folder)
      expanded(entry["url"].to_s, folder) if McpConfigGenerator.http_entry?(name, entry)
    end

    WILDCARD = "zzwildcardzz"
    private_constant :WILDCARD

    # Claude Code's serverUrl match: scheme, host (any case, `*` spanning dots) and port, then the path and
    # query as a glob, any path where the pattern names none. One that is no URL is a glob per path segment.
    def url_match?(pattern, url)
      return false unless pattern.is_a?(String)
      return true if pattern == "*"

      target = URI.parse(url)
      return false unless target.host

      path = (target.path.empty? ? "/" : target.path) + (target.query.to_s.empty? ? "" : "?#{target.query}")
      shape, any_port = url_pattern(pattern)
      return segments_match?(pattern, "#{target.scheme}://#{target.host}#{explicit_port(target)&.then { |port| ":#{port}" }}#{path}") unless shape

      return false unless shape.scheme == WILDCARD || shape.scheme.casecmp?(target.scheme)

      host = shape.host.delete_suffix(".").downcase
      return false unless glob(host.gsub(WILDCARD, "*"), target.host.delete_suffix(".").downcase)
      return false unless any_port || (explicit_port(shape).nil? && host.include?(WILDCARD)) || explicit_port(shape) == explicit_port(target)

      query = shape.query.to_s.empty? ? "" : "?#{shape.query}"
      return true if [ "", "/" ].include?(shape.path.to_s) && query.empty? && !pattern.end_with?("/")

      glob("#{shape.path}#{query}".gsub(WILDCARD, "*"), path)
    rescue URI::Error, ArgumentError
      false
    end

    # The pattern as a URL with each `*` held by a placeholder, and whether its port is a wildcard; nil where it is no URL.
    def url_pattern(pattern)
      text = pattern.gsub("*", WILDCARD)
      fixed = text.sub(/:#{WILDCARD}(?=[\/?#]|\z)/o, ":0")
      uri = parsed_uri(text)
      any_port = uri.nil? && fixed != text
      uri ||= parsed_uri(fixed) if any_port
      [ uri, any_port ] if uri&.host
    end

    def parsed_uri(text)
      URI.parse(text)
    rescue URI::Error
      nil
    end

    def explicit_port(uri)
      uri.port unless uri.port == uri.default_port
    end

    def glob(pattern, text)
      Regexp.new("\\A#{pattern.split('*', -1).map { |part| Regexp.escape(part) }.join('.*')}\\z", Regexp::MULTILINE).match?(text)
    end

    def segments_match?(pattern, text)
      parts = pattern.split("/", -1)
      texts = text.split("/", -1)
      parts.size == texts.size && parts.zip(texts).all? { |part, each| glob(part, each) }
    end

    # The settings files a session started in that folder reads, as [scope, data, path], in Claude
    # Code's merge order: the local file of #local_settings_dir comes after the folder's own, and wins.
    def scoped_settings(folder)
      @settings[folder] ||= begin
        here = File.expand_path(folder)
        local_root = local_settings_dir(folder)
        [ [ :user, (File.join(@config_dir, "settings.json") if @config_dir) ],
          [ :project, File.join(here, ".claude", "settings.json") ],
          [ :local, File.join(here, ".claude", "settings.local.json") ],
          [ :local, (File.join(local_root, ".claude", "settings.local.json") unless local_root == here) ],
          *managed_files.map { |path| [ :managed, path ] } ]
          .filter_map { |scope, path| (data = self.class.settings_file(path, scope)) && [ scope, data, path ] }
      end
    end

    def managed_files
      self.class.managed_files(@managed)
    end

    def project(folder)
      projects = hash_or_empty(claude_config["projects"])
      key = project_key(folder)
      hash_or_empty(projects[utf8(key)] || projects[utf8(real(key))])
    end

    # A folder's git root, or a linked worktree's repository, else the folder.
    def project_key(folder)
      @project_keys[folder] ||= begin
        dir = File.expand_path(folder)
        root = SafePath.git_root(dir)
        root ? repository_of(root) : dir
      end
    end

    # A linked worktree's repository: a main checkout's .git, filed under that checkout, or a bare
    # repository, filed under its own folder.
    def repository_of(root)
      shared = common_dir(root) or return root
      File.basename(shared) == ".git" ? File.dirname(shared) : shared
    end

    # The checkout whose local settings a worktree shares; a bare repository's worktree shares none.
    def main_checkout(root)
      shared = common_dir(root) or return root
      File.dirname(shared) if File.basename(shared) == ".git"
    end

    # A linked worktree's commondir, nil for a checkout of its own. A submodule's git dir has none.
    def common_dir(root)
      dot_git = File.join(root, ".git")
      return nil unless File.file?(dot_git)

      gitdir = File.read(dot_git, 4096)[/\Agitdir:\s*(.+?)\s*$/, 1] or return nil
      gitdir = File.expand_path(gitdir, root)
      common = File.join(gitdir, "commondir")
      File.expand_path(File.read(common, 4096).strip, gitdir) if File.file?(common)
    rescue SystemCallError, IOError, ArgumentError
      nil
    end

    def home?(dir)
      SafePath.canonical(dir).b == SafePath.canonical(Dir.home).b
    rescue ArgumentError, SystemCallError
      false
    end

    # Claude Code checks the root itself, and its .git and .claude entries as they are, links included.
    def owned?(dir)
      paths = [ File.join(dir, ".git"), File.join(dir, ".claude") ].select { |path| File.exist?(path) || File.symlink?(path) }
      [ File.stat(dir), *paths.map { |path| File.lstat(path) } ].all? { |stat| stat.uid == Process.euid }
    rescue SystemCallError
      false
    end

    def claude_config
      @claude_config ||= (@claude_json && read(@claude_json)) || {}
    end

    # The app, a folder inside it, or one above it: the only folders the plugin could serve it from.
    def related?(folder)
      folder = SafePath.canonical(folder).b
      root = SafePath.canonical(@root).b
      SafePath.contained?(root, folder) || SafePath.contained?(folder, root)
    rescue SystemCallError, ArgumentError
      false
    end

    # Wider than McpConfigGenerator.own_entry?, which judges entries the gem
    # wrote: a server added by hand runs the gem's server however it is spelled.
    def own?(name, entry)
      argv = McpConfigGenerator.unwrapped_argv(McpConfigGenerator.json_argv(entry))
      McpConfigGenerator.own_entry?(name, argv) || McpConfigGenerator.runs_gem?(argv)
    end

    def real(folder)
      File.realpath(folder)
    rescue SystemCallError
      folder
    end

    # .claude.json's keys are UTF-8; a path a locale tagged binary matches one only respelled.
    def utf8(path)
      text = path.dup.force_encoding(Encoding::UTF_8)
      text.valid_encoding? ? text : path
    end

    def hash_or_empty(value) = value.is_a?(Hash) ? value : {}

    def read(path)
      self.class.read_json(path)
    end
  end
end
