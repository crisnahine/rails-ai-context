# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::ClaudeCodeSettings do
  around do |example|
    Dir.mktmpdir do |dir|
      @dir = File.realpath(dir)
      @root = File.join(@dir, "shop")
      @config = File.join(@dir, "config")
      app(@root)
      FileUtils.mkdir_p(@config)
      write(registry, "version" => 2, "plugins" => { "rails-ai-context@rails-ai-context" => [ { "scope" => "user" } ],
                                                     "rails-ai-context@mirror" => [ { "scope" => "user" } ] })
      example.run
    end
  end

  let(:managed) { File.join(@dir, "managed-settings.json") }
  let(:claude_json) { File.join(@config, ".claude.json") }
  let(:registry) { File.join(@config, "plugins", "installed_plugins.json") }
  let(:settings) { fresh }

  def fresh(root = @root) = described_class.new(root, config_dir: @config, claude_json: claude_json, managed: managed)

  def app(dir)
    FileUtils.mkdir_p(File.join(dir, "config"))
    File.write(File.join(dir, "config", "application.rb"), "")
  end

  def write(path, data)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, JSON.generate(data))
  end

  def plugin(enabled) = { "enabledPlugins" => { "rails-ai-context@rails-ai-context" => enabled } }

  def ours = { "command" => "rails-ai-context", "args" => [ "serve" ] }

  def http(port = 3000) = { "type" => "http", "url" => "http://localhost:#{port}/mcp" }

  def found = settings.duplicates.map { |dup| [ dup.scope, dup.name ] }

  # A marketplace clone that lists the plugin, whose folder is there.
  def marketplace_clone(dir)
    write(File.join(dir, ".claude-plugin", "marketplace.json"), "plugins" => [ { "name" => "rails-ai-context", "source" => "./plugins/rails-ai-context" } ])
    FileUtils.mkdir_p(File.join(dir, "plugins", "rails-ai-context"))
    dir
  end

  def known_marketplace(source) = write(File.join(@config, "plugins", "known_marketplaces.json"), "rails-ai-context" => { "source" => source })

  describe "#plugin?" do
    it "is off when no settings file names the plugin" do
      write(File.join(@root, ".claude", "settings.json"), "enabledPlugins" => { "other@market" => true })

      expect(settings.plugin?).to be(false)
    end

    # Claude Code merges enabledPlugins key by key, the project's over the user's.
    it "reads the user's own settings and a marketplace of any name, under the project's" do
      write(File.join(@config, "settings.json"), "enabledPlugins" => { "rails-ai-context@mirror" => true })
      expect(settings.plugin?).to be(true)
      expect(settings.plugin_id).to eq("rails-ai-context@mirror")

      # A session in the folder above, which holds this app alone, still has the user's.
      write(File.join(@root, ".claude", "settings.json"), "enabledPlugins" => { "rails-ai-context@mirror" => false })
      expect(fresh.plugin?).to be(true)

      app(File.join(@dir, "admin"))
      expect(fresh.plugin?).to be(false)
    end

    # The plugin has no version but the commit it came from, so no constraint list matches it.
    it "takes a list of version constraints as off, as Claude Code does" do
      write(File.join(@root, ".claude", "settings.json"), plugin([ ">=5.37.0" ]))

      expect(settings.plugin?).to be(false)
      expect(settings.plugin_chosen?).to be(false)
    end

    # Claude Code drops the whole file when a value in it fails its schema.
    it "skips a settings file whose enabledPlugins holds a value Claude Code refuses" do
      write(File.join(@config, "settings.json"), plugin(false))
      write(File.join(@root, ".claude", "settings.json"), "enabledPlugins" => { "rails-ai-context@rails-ai-context" => true, "x@y" => "bad" })
      expect(settings.plugin?).to be(false)

      write(File.join(@root, ".claude", "settings.json"), "enabledPlugins" => { "rails-ai-context@rails-ai-context" => true, "x@y" => [ 1 ] })
      expect(fresh.plugin?).to be(false)

      write(File.join(@root, ".claude", "settings.json"), "enabledPlugins" => { "rails-ai-context@rails-ai-context" => true, "x@y" => [ "1.0" ] })
      expect(fresh.plugin?).to be(true)

      # Present but null fails the schema too, where a missing key does not.
      write(File.join(@config, "settings.json"), "enabledPlugins" => nil, "deniedMcpServers" => [ { "serverName" => "plugin:rails-ai-context:rails-ai-context" } ])
      expect(fresh.plugin?).to be(true)
      write(File.join(@config, "settings.json"), "deniedMcpServers" => [ { "serverName" => "plugin:rails-ai-context:rails-ai-context" } ])
      expect(fresh.plugin?).to be(false)
    end

    # Claude Code keeps enforcing the rest of a managed file.
    it "keeps a managed file whose enabledPlugins holds a value Claude Code refuses, less that value" do
      write(File.join(@config, "settings.json"), plugin(true))
      write(File.join(@dir, "managed-settings.d", "10-x.json"), "enabledPlugins" => { "rails-ai-context@rails-ai-context" => false, "x@y" => 1 })
      expect(settings.plugin?).to be(false)

      FileUtils.rm_rf(File.join(@dir, "managed-settings.d"))
      write(managed, "enabledPlugins" => [], "deniedMcpServers" => [ { "serverName" => "plugin:rails-ai-context:rails-ai-context" } ])
      expect(fresh.plugin?).to be(false)
      expect(fresh.blocked_plugin).to have_attributes(rule: :denied, scope: :managed)

      write(managed, "enabledPlugins" => nil, "deniedMcpServers" => [ { "serverName" => "plugin:rails-ai-context:rails-ai-context" } ])
      expect(fresh.blocked_plugin).to have_attributes(rule: :denied, scope: :managed)
    end

    # Claude Code reads local settings from the folder's git root too, writes them
    # there, and lets that file override the folder's own.
    it "reads the local settings of the git root above the app, over the folder's" do
      git_root = File.join(@dir, "repo")
      root = File.join(git_root, "backend")
      app(root)
      FileUtils.mkdir_p(File.join(git_root, ".git"))
      write(File.join(root, ".claude", "settings.json"), plugin(true))
      write(File.join(git_root, ".claude", "settings.local.json"), plugin(false))
      expect(fresh(root).plugin?).to be(false)

      write(File.join(root, ".claude", "settings.local.json"), plugin(true))
      expect(fresh(root).plugin?).to be(false)

      write(File.join(git_root, ".claude", "settings.local.json"), plugin(true))
      write(File.join(root, ".claude", "settings.local.json"), plugin(false))
      expect(fresh(root).plugin?).to be(true)
    end

    # Claude Code keeps the local file in the session's folder where it cannot share one safely.
    it "reads the git root's local settings only off Windows, outside the home folder, in a root this user owns" do
      git_root = File.join(@dir, "repo")
      root = File.join(git_root, "backend")
      app(root)
      FileUtils.mkdir_p(File.join(git_root, ".git"))
      write(File.join(root, ".claude", "settings.json"), plugin(true))
      write(File.join(git_root, ".claude", "settings.local.json"), plugin(false))
      expect(fresh(root).local_settings_dir(root)).to eq(git_root)
      expect(fresh(root).plugin?).to be(false)

      allow(Dir).to receive(:home).and_return(git_root)
      expect(fresh(root).local_settings_dir(root)).to eq(root)
      expect(fresh(root).plugin?).to be(true)
      allow(Dir).to receive(:home).and_call_original

      euid = Process.euid
      allow(Process).to receive(:euid).and_return(euid + 1)
      expect(fresh(root).local_settings_dir(root)).to eq(root)
      allow(Process).to receive(:euid).and_return(euid)
      expect(fresh(root).local_settings_dir(root)).to eq(git_root)

      allow(Gem).to receive(:win_platform?).and_return(true)
      expect(fresh(root).local_settings_dir(root)).to eq(root)
    end

    # Claude Code keys a worktree's project, and the local settings it writes
    # from one, by the main checkout.
    it "reads a git worktree's local settings, toggles and local servers under the main checkout" do
      main = File.join(@dir, "main")
      app(main)
      git = ->(*args) { system("git", "-C", main, "-c", "user.email=a@b.c", "-c", "user.name=a", *args, out: File::NULL, err: File::NULL) }
      skip "git is not available" unless git.("init", "-q")
      git.("add", "-A")
      git.("commit", "-qm", "init")
      tree = File.join(@dir, "tree")
      git.("worktree", "add", "-q", tree)
      expect(File.file?(File.join(tree, ".git"))).to be(true)

      write(File.join(main, ".claude", "settings.local.json"), plugin(true))
      expect(fresh(tree).plugin?).to be(true)
      expect(fresh(tree).project_of(tree)).to eq(main)

      write(claude_json, "projects" => { main => { "mcpServers" => { "rac" => ours } } })
      expect(fresh(tree).duplicates).to contain_exactly(have_attributes(scope: :local, name: "rac", key: main))

      write(claude_json, "projects" => { main => { "disabledMcpServers" => [ "plugin:rails-ai-context:rails-ai-context" ] } })
      expect(fresh(tree).plugin?).to be(false)

      # A gitdir written relative to the worktree reads the same.
      gitdir = File.read(File.join(tree, ".git"))[/gitdir: (.+)/, 1].strip
      File.write(File.join(tree, ".git"), "gitdir: #{Pathname.new(gitdir).relative_path_from(Pathname.new(tree))}\n")
      expect(fresh(tree).project_of(tree)).to eq(main)
    end

    it "reads a worktree of a bare repository under the repository's folder" do
      main = File.join(@dir, "main")
      app(main)
      git = ->(dir, *args) { system("git", "-C", dir, "-c", "user.email=a@b.c", "-c", "user.name=a", *args, out: File::NULL, err: File::NULL) }
      skip "git is not available" unless git.(main, "init", "-q")
      git.(main, "add", "-A")
      git.(main, "commit", "-qm", "init")
      bare = File.join(@dir, "repo.git")
      git.(@dir, "clone", "-q", "--bare", main, bare)
      tree = File.join(@dir, "wt1")
      git.(bare, "worktree", "add", "-q", tree)
      write(File.join(tree, ".claude", "settings.json"), plugin(true))

      expect(fresh(tree).project_of(tree)).to eq(bare)
      write(claude_json, "projects" => { bare => { "mcpServers" => { "rac" => ours } } })
      expect(fresh(tree).duplicates).to contain_exactly(have_attributes(scope: :local, name: "rac", key: bare))

      # Its worktrees share no local settings file: each session folder keeps its own.
      expect(fresh(tree).local_settings_dir(File.join(tree, "config"))).to eq(File.join(tree, "config"))
    end

    # A submodule's .git file names a git dir with no commondir: its own project.
    it "keeps a checkout whose .git file names no shared git dir as its own project" do
      root = File.join(@dir, "sub")
      app(root)
      FileUtils.mkdir_p(File.join(@dir, "modules", "sub"))
      File.write(File.join(root, ".git"), "gitdir: ../modules/sub\n")

      expect(fresh(root).project_of(root)).to eq(root)
    end

    it "lets local settings turn off the project's, and managed settings override both" do
      write(File.join(@root, ".claude", "settings.json"), plugin(true))
      write(File.join(@root, ".claude", "settings.local.json"), plugin(false))
      expect(settings.plugin?).to be(false)

      write(managed, plugin(true))
      expect(fresh.plugin?).to be(true)
    end

    it "reads managed drop-ins after the managed file, and a file saved with a byte order mark" do
      write(managed, plugin(false))
      write(File.join(@dir, "managed-settings.d", "10-plugins.json"), plugin(true))
      expect(settings.plugin?).to be(true)

      FileUtils.rm_rf([ managed, File.join(@dir, "managed-settings.d") ])
      FileUtils.mkdir_p(File.join(@root, ".claude"))
      File.write(File.join(@root, ".claude", "settings.json"), "\uFEFF#{JSON.generate(plugin(true))}")
      expect(fresh.plugin?).to be(true)
    end

    # A machine that never installed a plugin has no registry at all.
    it "is not installed where the config folder has no install registry, and installed in an older registry's shape" do
      write(File.join(@root, ".claude", "settings.json"), plugin(true))
      FileUtils.rm_rf(File.dirname(registry))
      expect(settings.plugin?).to be(false)
      expect(settings.uninstalled_plugin_id).to eq("rails-ai-context@rails-ai-context")

      write(registry, "plugins" => { "rails-ai-context@rails-ai-context" => { "version" => "x" } })
      expect(fresh.plugin?).to be(true)

      # A registry in a shape this cannot read is taken on trust, not as empty.
      File.write(registry, "{")
      expect(fresh.plugin?).to be(true)
    end

    # Claude Code uses a project or local install only in that project's sessions.
    it "counts a project or local install only for the project it was made in" do
      write(File.join(@root, ".claude", "settings.json"), plugin(true))
      write(registry, "version" => 2, "plugins" => { "rails-ai-context@rails-ai-context" => [ { "scope" => "local", "projectPath" => File.join(@dir, "admin") } ] })
      expect(settings.plugin?).to be(false)
      expect(settings.uninstalled_plugin_id).to eq("rails-ai-context@rails-ai-context")

      write(registry, "version" => 2, "plugins" => { "rails-ai-context@rails-ai-context" => [ { "scope" => "project", "projectPath" => @root } ] })
      expect(fresh.plugin?).to be(true)

      # Matched by the project's git root, wherever in it the install ran.
      FileUtils.mkdir_p(File.join(@root, ".git"))
      write(registry, "version" => 2, "plugins" => { "rails-ai-context@rails-ai-context" => [ { "scope" => "local", "projectPath" => File.join(@root, "app") } ] })
      expect(fresh.plugin?).to be(true)
    end

    # Claude Code loads a local marketplace's plugins from that folder, with no install.
    it "counts a plugin from a directory or file marketplace as installed" do
      clone = marketplace_clone(File.join(@dir, "clone"))
      write(File.join(@root, ".claude", "settings.json"), plugin(true))
      write(registry, "version" => 2, "plugins" => {})
      known_marketplace("source" => "directory", "path" => clone)
      expect(settings.plugin?).to be(true)
      expect(settings.local_marketplace?("rails-ai-context@rails-ai-context")).to be(true)

      known_marketplace("source" => "file", "path" => File.join(clone, ".claude-plugin", "marketplace.json"))
      expect(fresh.plugin?).to be(true)

      FileUtils.rm_f(File.join(@config, "plugins", "known_marketplaces.json"))
      write(File.join(@config, "settings.json"),
            "extraKnownMarketplaces" => { "rails-ai-context" => { "source" => { "source" => "file", "path" => File.join(clone, ".claude-plugin", "marketplace.json") } } })
      expect(fresh.plugin?).to be(true)
    end

    # Claude Code runs nothing from a marketplace folder that moved, whatever the registry still records.
    it "counts a local marketplace's plugin as not installed once its folder is gone" do
      clone = File.join(@dir, "clone")
      write(File.join(@root, ".claude", "settings.json"), plugin(true))
      known_marketplace("source" => "directory", "path" => clone)

      expect(settings.plugin?).to be(false)
      expect(settings.missing_marketplace("rails-ai-context@rails-ai-context", @root)).to eq(clone)

      marketplace_clone(clone)
      expect(fresh.plugin?).to be(true)
      expect(fresh.missing_marketplace("rails-ai-context@rails-ai-context", @root)).to be_nil
    end

    # A checkout without the plugin's folder is still there, so adding it again changes nothing.
    it "tells a local marketplace that is there but has no plugin from one that is gone" do
      id = "rails-ai-context@rails-ai-context"
      clone = marketplace_clone(File.join(@dir, "clone"))
      FileUtils.rm_rf(File.join(clone, "plugins"))
      write(File.join(@root, ".claude", "settings.json"), plugin(true))
      known_marketplace("source" => "directory", "path" => clone)

      expect(settings.plugin?).to be(false)
      expect(settings.missing_marketplace(id, @root)).to be_nil
      expect(settings.marketplace_without_plugin(id, @root)).to eq(clone)

      listing = File.join(clone, ".claude-plugin", "marketplace.json")
      known_marketplace("source" => "file", "path" => listing)
      expect(fresh.marketplace_without_plugin(id, @root)).to eq(clone)
      FileUtils.rm_f(listing)
      expect(fresh.missing_marketplace(id, @root)).to eq(listing)
      expect(fresh.marketplace_without_plugin(id, @root)).to be_nil
    end

    # A relative path Claude Code never loads, so the registry decides.
    it "takes a marketplace declared by a relative path as no local marketplace" do
      marketplace_clone(File.join(@root, "mk"))
      write(File.join(@root, ".claude", "settings.json"),
            plugin(true).merge("extraKnownMarketplaces" => { "rails-ai-context" => { "source" => { "source" => "directory", "path" => "./mk" } } }))
      expect(settings.local_marketplace?("rails-ai-context@rails-ai-context")).to be(false)
      expect(settings.plugin?).to be(true)

      write(registry, "version" => 2, "plugins" => {})
      expect(fresh.plugin?).to be(false)
    end

    # Nothing to install on a machine where Claude Code never ran, such as CI:
    # the committed setting is the app's whole Claude Code setup there.
    it "takes the plugin as installed where Claude Code has never run" do
      write(File.join(@root, ".claude", "settings.json"), plugin(true))
      FileUtils.rm_rf(@config)
      expect(settings.absent?).to be(true)
      expect(settings.plugin?).to be(true)

      expect(described_class.new(@root, config_dir: nil, claude_json: nil, managed: managed).plugin?).to be(true)

      write(claude_json, {})
      expect(described_class.new(@root, config_dir: nil, claude_json: claude_json, managed: managed).absent?).to be(false)
    end

    # Enabled in a committed file is not installed on this machine.
    it "needs the plugin in Claude Code's install registry when the registry can be read" do
      write(File.join(@root, ".claude", "settings.json"), plugin(true))
      write(registry, "version" => 2, "plugins" => {})
      expect(settings.plugin?).to be(false)
      expect(settings.uninstalled_plugin_id).to eq("rails-ai-context@rails-ai-context")

      write(registry, "version" => 2, "plugins" => { "rails-ai-context@rails-ai-context" => [ { "scope" => "project" } ] })
      expect(fresh.plugin?).to be(true)
      expect(fresh.uninstalled_plugin_id).to be_nil
    end

    it "is off where /mcp turned the plugin's server off, under the project's git root" do
      git_root = File.join(@dir, "repo")
      root = File.join(git_root, "backend")
      app(root)
      FileUtils.mkdir_p(File.join(git_root, ".git"))
      write(File.join(root, ".claude", "settings.json"), plugin(true))
      expect(fresh(root).plugin?).to be(true)

      write(claude_json, "projects" => { git_root => { "disabledMcpServers" => [ "plugin:rails-ai-context:rails-ai-context" ] } })
      expect(fresh(root).plugin?).to be(false)
    end

    it "finds the folder's toggles under its real path when the app is reached through a link" do
      link = File.join(@dir, "link")
      File.symlink(@root, link)
      write(File.join(@root, ".claude", "settings.json"), plugin(true))
      write(claude_json, "projects" => { @root => { "disabledMcpServers" => [ "plugin:rails-ai-context:rails-ai-context" ] } })

      expect(fresh(link).plugin?).to be(false)
    end

    # Started in a folder above, the plugin serves the one app it holds, by that folder's settings.
    it "reads the settings of a folder above the app that the plugin serves the app from" do
      write(File.join(@dir, ".claude", "settings.json"), plugin(true))
      expect(settings.plugin?).to be(true)

      app(File.join(@dir, "admin"))
      expect(fresh.plugin?).to be(false)
    end

    # A session started in an app that holds this one serves that app, not this one.
    it "leaves out a folder above the app that resolves to another app" do
      outer = File.join(@dir, "outer")
      app(outer)
      root = File.join(outer, "shop")
      app(root)
      write(File.join(outer, ".claude", "settings.json"), plugin(true))

      expect(fresh(root).plugin_sessions).to eq([])
      expect(fresh(outer).plugin_sessions).to eq([ outer ])
    end

    # The binary refuses a bin/rails alone, though the app root resolves to it.
    it "is off for a folder the server refuses to read" do
      engine = File.join(@dir, "engine")
      FileUtils.mkdir_p(File.join(engine, "bin"))
      File.write(File.join(engine, "bin", "rails"), %(ENGINE_PATH = "x"\n))
      write(File.join(engine, ".claude", "settings.json"), plugin(true))

      expect(fresh(engine).plugin?).to be(false)
    end

    # The folder doctor runs in is a session too, which the app's other folders do not tell.
    it "reads the settings of the folder doctor was typed in, inside the app" do
      FileUtils.mkdir_p(File.join(@root, ".git"))
      models = File.join(@root, "app", "models")
      write(File.join(models, ".claude", "settings.json"), plugin(true))
      expect(settings.plugin?).to be(false)

      typed = described_class.new(@root, from: models, config_dir: @config, claude_json: claude_json, managed: managed)
      expect(typed.plugin_sessions).to eq([ models ])
    end

    # A locale that names no encoding tags paths binary, while .claude.json's keys are UTF-8.
    it "compares a folder spelled in another encoding than Claude Code's keys without raising, and finds its own" do
      root = File.join(@dir, "caf\u00e9")
      app(root)
      write(File.join(root, ".claude", "settings.json"), plugin(true))
      write(claude_json, "projects" => { File.join(@dir, "c\u00f3digo") => {} })
      binary = ->(path) { described_class.new(path.b, config_dir: @config, claude_json: claude_json, managed: managed) }
      expect(binary.(root).plugin?).to be(true)

      write(claude_json, "projects" => { root => { "disabledMcpServers" => [ "plugin:rails-ai-context:rails-ai-context" ] } })
      expect(binary.(root).plugin_server_off_in?(root.b)).to be(true)

      # Through a link, only the respelling finds the key the link's own spelling files.
      link = File.join(@dir, "t\u00e9")
      File.symlink(root, link)
      write(claude_json, "projects" => { link => { "disabledMcpServers" => [ "plugin:rails-ai-context:rails-ai-context" ] } })
      expect(binary.(link).plugin_server_off_in?(link.b)).to be(true)
    end

    it "skips a settings file that is not JSON, not an object, or not readable" do
      FileUtils.mkdir_p(File.join(@root, ".claude", "settings.local.json"))
      write(File.join(@root, ".claude", "settings.json"), [ 1 ])
      write(File.join(@config, "settings.json"), plugin(true))

      expect(settings.plugin?).to be(true)
      expect(settings.broken_managed_files).to eq([])
    end

    # Claude Code refuses to start at all while one of them is broken.
    it "names the managed files and drop-ins that hold no JSON object" do
      File.write(managed, "{")
      write(File.join(@dir, "managed-settings.d", "10-a.json"), [ 1 ])
      write(File.join(@dir, "managed-settings.d", "20-b.json"), plugin(true))

      expect(settings.broken_managed_files).to eq([ managed, File.join(@dir, "managed-settings.d", "10-a.json") ])
    end

    it "takes an empty or blank managed file or drop-in as no settings" do
      File.write(managed, "")
      FileUtils.mkdir_p(File.join(@dir, "managed-settings.d"))
      File.write(File.join(@dir, "managed-settings.d", "10-a.json"), "\uFEFF  \n\t")
      write(File.join(@config, "settings.json"), plugin(true))

      expect(settings.broken_managed_files).to eq([])
      expect(settings.plugin?).to be(true)
    end
  end

  describe "#plugin_on_in? and #plugin_sessions" do
    it "names the folders whose sessions run the plugin for this app" do
      write(File.join(@config, "settings.json"), plugin(true))
      write(File.join(@root, ".claude", "settings.json"), plugin(false))

      expect(settings.plugin_on_in?(@root)).to be(false)
      expect(settings.plugin_on_in?(@dir)).to be(true)
      expect(settings.plugin_sessions).to eq([ @dir ])
    end

    # Claude Code starts the server while any marketplace's copy is on.
    it "names every id a session runs the plugin under" do
      write(File.join(@root, ".claude", "settings.json"),
            "enabledPlugins" => { "rails-ai-context@rails-ai-context" => true, "rails-ai-context@mirror" => true })

      expect(settings.plugin_ids_in(@root)).to eq(%w[rails-ai-context@rails-ai-context rails-ai-context@mirror])
      # The last one merged replaces the others' same-named server.
      expect(settings.plugin_id_in(@root)).to eq("rails-ai-context@mirror")
      expect(settings.plugin_id).to eq("rails-ai-context@mirror")
    end
  end

  describe "the plugin enabled but not running" do
    before { write(File.join(@root, ".claude", "settings.json"), plugin(true)) }

    it "names the plugin whose server /mcp turned off everywhere it is on" do
      write(claude_json, "projects" => { @root => { "disabledMcpServers" => [ "plugin:rails-ai-context:rails-ai-context" ] } })

      expect(settings.plugin?).to be(false)
      expect(settings.plugin_chosen?).to be(true)
      expect(settings.switched_off_plugin_id).to eq("rails-ai-context@rails-ai-context")
      expect(settings.uninstalled_plugin_id).to be_nil
    end

    # A teammate's install goes where the setting that enables it is: the user's for
    # their own settings, local beside a committed one, which it then leaves alone.
    it "names the scope an install of an enabled plugin goes in" do
      write(registry, "version" => 2, "plugins" => {})
      expect(settings.install_scope("rails-ai-context@rails-ai-context")).to eq("local")

      FileUtils.rm(File.join(@root, ".claude", "settings.json"))
      write(File.join(@config, "settings.json"), plugin(true))
      expect(fresh.install_scope("rails-ai-context@rails-ai-context")).to eq("user")

      write(managed, plugin(true))
      expect(fresh.install_scope("rails-ai-context@rails-ai-context")).to eq("user")
    end

    it "names the settings that turn the plugin on, which say how to take it out" do
      expect(settings.enabled_plugin_id).to eq("rails-ai-context@rails-ai-context")
      expect(settings.enabled_scope("rails-ai-context@rails-ai-context")).to eq(:project)

      write(File.join(@root, ".claude", "settings.local.json"), plugin(true))
      expect(fresh.enabled_scope("rails-ai-context@rails-ai-context")).to eq(:local)
    end

    # Claude Code removes an install by its own scope and project, whatever the settings that enable it.
    it "names the installs that serve the sessions enabling the plugin" do
      id = "rails-ai-context@rails-ai-context"
      write(registry, "version" => 2, "plugins" => { id => [ { "scope" => "user" } ] })
      expect(settings.installs_for(id)).to eq([ described_class::Install.new(scope: "user", path: nil) ])
      expect(settings.enabled_sessions(id)).to eq([ @root ])

      write(registry, "version" => 2, "plugins" => { id => [
        { "scope" => "local", "projectPath" => File.join(@dir, "admin") }, { "scope" => "project", "projectPath" => @root }, { "scope" => "user" }
      ] })
      expect(fresh.installs_for(id)).to eq([ described_class::Install.new(scope: "project", path: @root), described_class::Install.new(scope: "user", path: nil) ])
      expect(fresh.installed_in?(id, @root)).to be(true)

      write(registry, "version" => 2, "plugins" => {})
      expect(fresh.installs_for(id)).to eq([])
      expect(fresh.enabled_sessions(id)).to eq([])
      expect(fresh.installed_in?(id, @root)).to be(false)
    end

    it "names the settings file whose value holds, and every id the plugin runs under" do
      write(File.join(@root, ".claude", "settings.local.json"), plugin(false))
      expect(settings.setting_for("rails-ai-context@rails-ai-context", @root))
        .to eq([ :local, false, File.join(@root, ".claude", "settings.local.json") ])

      write(File.join(@root, ".claude", "settings.local.json"), "enabledPlugins" => { "rails-ai-context@rails-ai-context" => true, "rails-ai-context@mirror" => true })
      expect(fresh.enabled_plugin_ids).to eq(%w[rails-ai-context@rails-ai-context rails-ai-context@mirror])
    end

    it "names the gem's servers a config holds for this app, under any name" do
      write(File.join(@root, ".mcp.json"), "mcpServers" => { "rac-x" => ours, "other" => { "command" => "x" }, "rails-ai-context" => http,
                                                             "web" => http })

      expect(settings.gem_server_names(File.join(@root, ".mcp.json"), @root)).to eq(%w[rac-x rails-ai-context])
    end

    it "names the sessions whose plugin server /mcp turned off" do
      write(claude_json, "projects" => { @root => { "disabledMcpServers" => [ "plugin:rails-ai-context:rails-ai-context" ] } })

      expect(settings.plugin_off_sessions).to eq([ @root ])
    end

    it "tells a plugin a managed file sets, which no local setting turns off" do
      expect(settings.managed_in?("rails-ai-context@rails-ai-context", @root)).to be(false)

      write(File.join(@dir, "managed-settings.d", "10-plugins.json"), plugin(true))
      expect(fresh.managed_in?("rails-ai-context@rails-ai-context", @root)).to be(true)
    end

    it "tells a plugin the folder's committed settings enable from one only a user's or local settings do" do
      expect(settings.committed_in?(@root)).to be(true)

      FileUtils.rm(File.join(@root, ".claude", "settings.json"))
      write(File.join(@root, ".claude", "settings.local.json"), plugin(true))
      expect(fresh.committed_in?(@root)).to be(false)
      expect(described_class.committed?(@root)).to be(false)

      write(File.join(@root, ".claude", "settings.json"), plugin(true))
      expect(described_class.committed?(@root)).to be(true)
    end
  end

  # Claude Code checks its MCP policy before it starts any server, the plugin's included.
  describe "MCP server policy" do
    let(:install) { File.join(@dir, "cache", "60932514d751") }

    before do
      write(File.join(@root, ".claude", "settings.json"), plugin(true))
      write(registry, "version" => 2, "plugins" => { "rails-ai-context@rails-ai-context" => [ { "scope" => "user", "installPath" => install } ] })
      write(File.join(install, ".mcp.json"),
            "mcpServers" => { "rails-ai-context" => { "command" => "ruby", "args" => [ "--", "${CLAUDE_PLUGIN_ROOT}/scripts/serve.rb" ] } })
    end

    let(:command) { [ "ruby", "--", File.join(install, "scripts", "serve.rb") ] }

    it "blocks the plugin's server by its name in a denylist from any settings file" do
      write(File.join(@config, "settings.json"), "deniedMcpServers" => [ { "serverName" => "plugin:rails-ai-context:rails-ai-context" } ])

      expect(settings.plugin?).to be(false)
      expect(settings.blocked_plugin).to have_attributes(id: "rails-ai-context@rails-ai-context", command: command, rule: :denied, scope: :user)
    end

    # Its name has colons an allowlist entry cannot hold, so only its exact command admits it.
    it "blocks the plugin's server under an allowlist that lists no command starting it" do
      write(managed, "allowedMcpServers" => [ { "serverName" => "github" } ])
      expect(settings.plugin?).to be(false)
      expect(settings.blocked_plugin).to have_attributes(command: command, rule: :allowlist, scope: :managed)

      write(managed, "allowedMcpServers" => [ { "serverCommand" => command } ])
      expect(fresh.plugin?).to be(true)
      expect(fresh.blocked_plugin).to be_nil
    end

    # Claude Code fails closed on the switch: any value but false, "false" or null turns it on.
    it "reads the allowlist from managed settings alone when they say so" do
      write(File.join(@config, "settings.json"), "allowedMcpServers" => [ { "serverCommand" => command } ])
      expect(settings.plugin?).to be(true)

      [ [ true, false ], [ "true", false ], [ 1, false ], [ false, true ], [ "false", true ], [ nil, true ] ].each do |value, admitted|
        write(managed, "allowManagedMcpServersOnly" => value, "allowedMcpServers" => [ { "serverName" => "github" } ])
        expect(fresh.plugin?).to be(admitted), value.inspect
      end
    end

    # Plugin servers still start under the lock, which Claude Code takes from any value but false, null or an Array without mcp.
    it "locks every other server for a managed strictPluginOnlyCustomization that is not false, null or an Array without mcp" do
      [ [ [ "mcp" ], true ], [ "mcp", true ], [ { "mcp" => true }, true ], [ "hooks", true ], [ 0, true ], [ "", true ],
        [ [ "hooks" ], false ], [ false, false ], [ nil, false ] ].each do |value, locked|
        write(managed, "strictPluginOnlyCustomization" => value)

        expect(fresh.server_block("rac", %w[rails-ai-context serve], @root)).to eq(locked ? %i[locked managed] : nil), value.inspect
        expect(fresh.plugin?).to be(true)
      end
    end

    # One serverCommand entry has Claude Code match every stdio server by its command, so a name admits none.
    it "keeps out a server the allowlist names once the list also names a command" do
      write(File.join(@root, ".mcp.json"), "mcpServers" => { "rac" => ours })
      write(File.join(@config, "settings.json"), "allowedMcpServers" => [ { "serverCommand" => command }, { "serverName" => "rac" } ])

      expect(settings.plugin?).to be(true)
      expect(settings.server_block("rac", %w[rails-ai-context serve], @root)).to eq(%i[allowlist user])
      expect(found).to eq([])
    end

    # Claude Code checks a serverCommand rule against the command with ${PWD} expanded too.
    it "matches a serverCommand rule to a server's command as Claude Code expands it" do
      expanded = [ "rails-ai-context", "serve", "--app-path", @root ]
      write(File.join(@root, ".mcp.json"), "mcpServers" => { "rac" => { "command" => "rails-ai-context", "args" => [ "serve", "--app-path", "${PWD}" ] } })
      expect(found).to eq([ [ :project, "rac" ] ])

      write(File.join(@config, "settings.json"), "deniedMcpServers" => [ { "serverCommand" => expanded } ])
      expect(fresh.duplicates).to eq([])

      write(File.join(@config, "settings.json"), "allowedMcpServers" => [ { "serverCommand" => command }, { "serverCommand" => expanded } ])
      expect(fresh.duplicates.map(&:name)).to eq([ "rac" ])
    end

    it "names the settings file that decides, and what blocks the plugin in one session folder" do
      write(File.join(@config, "settings.json"), "allowedMcpServers" => [ { "serverName" => "github" } ])
      write(managed, "allowedMcpServers" => [ { "serverName" => "gitlab" } ])
      expect(settings.blocked_plugin).to have_attributes(rule: :allowlist, scope: :user, path: File.join(@config, "settings.json"))

      # The plugin runs from the folder above, while a deny in the app's local settings holds it back there.
      write(File.join(@config, "settings.json"), plugin(true))
      write(managed, {})
      write(File.join(@root, ".claude", "settings.local.json"), "deniedMcpServers" => [ { "serverName" => "plugin:rails-ai-context:rails-ai-context" } ])
      expect(fresh.plugin_sessions).to eq([ @dir ])
      expect(fresh.block_in(@dir)).to be_nil
      expect(fresh.block_in(@root))
        .to have_attributes(rule: :denied, scope: :local, folder: @root, path: File.join(@root, ".claude", "settings.local.json"))

      # Blocked only in the folder above, it is that session's block.
      write(File.join(@root, ".claude", "settings.local.json"), plugin(false))
      write(File.join(@config, "settings.json"), plugin(true).merge("deniedMcpServers" => [ { "serverName" => "plugin:rails-ai-context:rails-ai-context" } ]))
      expect(fresh.blocked_plugin).to have_attributes(rule: :denied, folder: @dir)
      write(File.join(@config, "settings.json"), plugin(true))
      write(File.join(@root, ".claude", "settings.local.json"), "deniedMcpServers" => [ { "serverName" => "plugin:rails-ai-context:rails-ai-context" } ])

      # Where /mcp turned it off, the policy is not what keeps it from starting.
      write(claude_json, "projects" => { @root => { "disabledMcpServers" => [ "plugin:rails-ai-context:rails-ai-context" ] } })
      expect(fresh.block_in(@root)).to be_nil
      expect(fresh.blocked_plugin).to be_nil
    end

    # Claude Code runs the copy of the id it merges last.
    it "reads the requirement of the copy Claude Code runs where two marketplaces' copies are on" do
      mirror = File.join(@dir, "cache", "mirror")
      write(registry, "version" => 2, "plugins" => { "rails-ai-context@rails-ai-context" => [ { "scope" => "user", "installPath" => install } ],
                                                     "rails-ai-context@mirror" => [ { "scope" => "user", "installPath" => mirror } ] })
      { install => ">= 5.37", mirror => ">= 9" }.each do |dir, bound|
        FileUtils.mkdir_p(File.join(dir, "scripts"))
        File.write(File.join(dir, "scripts", "gem_requirement.rb"), %(GEM_REQUIREMENT = "#{bound}"\n))
      end
      write(File.join(@root, ".claude", "settings.json"), "enabledPlugins" => { "rails-ai-context@rails-ai-context" => true, "rails-ai-context@mirror" => true })
      expect(settings.plugin_gem_requirement).to eq([ ">= 9" ])

      write(File.join(@root, ".claude", "settings.json"), "enabledPlugins" => { "rails-ai-context@mirror" => true, "rails-ai-context@rails-ai-context" => true })
      expect(fresh.plugin_gem_requirement).to eq([ ">= 5.37" ])
    end

    it "admits the plugin's server by no name, and takes an install whose command it cannot read as no evidence" do
      write(managed, "allowedMcpServers" => [ { "serverName" => "plugin:rails-ai-context:rails-ai-context" } ])
      expect(settings.plugin?).to be(false)

      FileUtils.rm(File.join(install, ".mcp.json"))
      expect(fresh.plugin?).to be(true)
      expect(fresh.blocked_plugin).to be_nil
    end

    # Each deny holds on its own, and only an admin lifts a managed one.
    it "names every deny entry that matches, the managed ones first" do
      write(File.join(@config, "settings.json"), "deniedMcpServers" => [ { "serverCommand" => command }, { "serverName" => "github" } ])
      write(managed, "deniedMcpServers" => [ { "serverName" => "plugin:rails-ai-context:rails-ai-context" } ])

      expect(settings.deny_rules("plugin:rails-ai-context:rails-ai-context", command, @root))
        .to eq([ [ :managed, { "serverName" => "plugin:rails-ai-context:rails-ai-context" }, managed ],
                 [ :user, { "serverCommand" => command }, File.join(@config, "settings.json") ] ])
      expect(settings.blocked_plugin).to have_attributes(rule: :denied, scope: :managed, path: managed)
    end

    # One serverCommand entry makes Claude Code admit every stdio server by command alone.
    it "tells an allowlist that names a command from one that names servers alone" do
      write(File.join(@config, "settings.json"), "allowedMcpServers" => [ { "serverName" => "github" } ])
      expect(settings.allowlist_by_command?(@root)).to be(false)

      write(managed, "allowedMcpServers" => [ { "serverCommand" => %w[gh mcp] } ])
      expect(fresh.allowlist_by_command?(@root)).to be(true)
      expect(fresh.server_block("rails-ai-context", %w[rails-ai-context serve], @root)).to eq([ :allowlist, :user ])
    end

    # Deployed, managed-mcp.json names every server Claude Code starts.
    it "starts neither the plugin's nor any other server where managed-mcp.json is deployed" do
      write(File.join(@root, ".mcp.json"), "mcpServers" => { "rac" => ours })
      write(File.join(@dir, "managed-mcp.json"), "mcpServers" => { "github" => { "command" => "gh" } })

      expect(settings.plugin?).to be(false)
      expect(settings.blocked_plugin).to have_attributes(rule: :exclusive, scope: :managed)
      expect(settings.server_block("rac", %w[rails-ai-context serve], @root)).to eq([ :exclusive, :managed ])
      expect(settings.managed_server(@root)).to be_nil

      write(File.join(@dir, "managed-mcp.json"), "mcpServers" => { "rails" => ours })
      expect(fresh.managed_server(@root)).to eq("rails")
    end

    # Claude Code applies a deny and /mcp to managed-mcp.json's servers, an allowlist only where it expands a
    # variable, and never the lock.
    it "starts a managed-mcp.json server for this app unless a deny, /mcp or an allowlist on a variable keeps it off" do
      app(File.join(@dir, "admin"))
      other = { "command" => "rails-ai-context", "args" => [ "serve", "--app-path", File.join(@dir, "admin") ] }
      write(File.join(@dir, "managed-mcp.json"), "mcpServers" => { "admin" => other, "rails" => ours })
      expect(settings.managed_servers(@root)).to eq([ [ "rails", nil, %w[rails-ai-context serve], nil ] ])

      write(managed, "deniedMcpServers" => [ { "serverName" => "rails" } ], "strictPluginOnlyCustomization" => [ "mcp" ])
      expect(fresh.managed_servers(@root).map { |name, held, _| [ name, held ] }).to eq([ [ "rails", [ :denied, :managed ] ] ])
      expect(fresh.managed_server(@root)).to be_nil

      write(managed, "strictPluginOnlyCustomization" => [ "mcp" ], "allowedMcpServers" => [ { "serverName" => "github" } ])
      expect(fresh.managed_server(@root)).to eq("rails")
      variable = { "command" => "rails-ai-context", "args" => [ "serve", "--app-path", "${PWD}" ] }
      write(File.join(@dir, "managed-mcp.json"), "mcpServers" => { "rails" => variable })
      expect(fresh.managed_servers(@root).map { |name, held, _| [ name, held ] }).to eq([ [ "rails", [ :allowlist, :managed ] ] ])

      write(managed, {})
      write(claude_json, "projects" => { @root => { "disabledMcpServers" => [ "rails" ] } })
      expect(fresh.managed_servers(@root).map { |name, held, _| [ name, held ] }).to eq([ [ "rails", [ :off ] ] ])
    end

    it "counts an HTTP entry under the gem's name in managed-mcp.json as this app's server, held by a serverUrl deny" do
      write(File.join(@dir, "managed-mcp.json"), "mcpServers" => { "rails-ai-context" => http, "web" => http })
      expect(settings.managed_servers(@root)).to eq([ [ "rails-ai-context", nil, [], http["url"] ] ])

      write(managed, "deniedMcpServers" => [ { "serverUrl" => "http://localhost:*" } ])
      expect(fresh.managed_servers(@root).map { |name, held, _| [ name, held ] }).to eq([ [ "rails-ai-context", [ :denied, :managed ] ] ])
    end

    # Claude Code compares a serverUrl pattern by scheme, host in any case and port, then the path as a glob,
    # any path where the pattern names none; a pattern that is no URL is a glob per path segment.
    it "denies a remote server whose url a serverUrl pattern matches, as Claude Code reads the pattern" do
      url = "http://localhost:6731/a/mcp"
      held = lambda do |pattern|
        write(managed, "deniedMcpServers" => [ { "serverUrl" => pattern } ])
        !fresh.server_block("web", [], @root, url: url).nil?
      end
      matching = [ "*", "http://localhost:*", "http://LOCALHOST:6731", "*://localhost:6731", "http://localhost:6731/*", "http://*/a/mcp",
                   "http://*:6731/a/*", url, "http://localhost:6731/a/mcp?" ]
      missing = [ "*localhost*", "http://localhost", "https://localhost:6731", "http://localhost:*/mcp", "http://localhost:6731/",
                  "http://other:6731", "http://localhost:6731/a", "http://${HOST}/*", "*:/*" ]

      expect(matching.reject(&held)).to eq([])
      expect(missing.select(&held)).to eq([])
      expect(fresh.server_block("web", [], @root, url: "not a url")).to be_nil
    end

    # Claude Code acts on a marketplace a settings file declares before it records one.
    it "runs a plugin from a directory marketplace the settings declare but Claude Code has not recorded" do
      clone = File.join(@dir, "clone")
      write(File.join(clone, ".claude-plugin", "marketplace.json"), "plugins" => [ { "name" => "rails-ai-context", "source" => "./plugins/rails-ai-context" } ])
      FileUtils.rm_rf(File.dirname(registry))
      FileUtils.mkdir_p(File.join(clone, "plugins", "rails-ai-context"))
      write(File.join(@config, "settings.json"), "extraKnownMarketplaces" => { "rails-ai-context" => { "source" => { "source" => "directory", "path" => clone } } })

      expect(settings.plugin?).to be(true)
      expect(settings.local_marketplace?("rails-ai-context@rails-ai-context")).to be(true)
      expect(settings.marketplace_known?("rails-ai-context@rails-ai-context")).to be(false)
    end

    # A marketplace.json added by its path is read in place too, from the folder above its .claude-plugin/.
    it "names the command a file-source marketplace's plugin starts with" do
      clone = File.join(@dir, "clone")
      write(File.join(clone, ".claude-plugin", "marketplace.json"), "plugins" => [ { "name" => "rails-ai-context", "source" => "./plugins/rails-ai-context" } ])
      write(File.join(clone, "plugins", "rails-ai-context", ".mcp.json"),
            "mcpServers" => { "rails-ai-context" => { "command" => "ruby", "args" => [ "-e", "load 'here'" ] } })
      write(File.join(@config, "plugins", "known_marketplaces.json"),
            "rails-ai-context" => { "source" => { "source" => "file", "path" => File.join(clone, ".claude-plugin", "marketplace.json") }, "installLocation" => clone })
      write(File.join(@config, "settings.json"), "allowedMcpServers" => [ { "serverName" => "github" } ])

      expect(settings.blocked_plugin.command).to eq([ "ruby", "-e", "load 'here'" ])
      expect(settings.marketplace_known?("rails-ai-context@rails-ai-context")).to be(true)
    end

    it "reads every bound the running plugin's requirement names" do
      FileUtils.mkdir_p(File.join(install, "scripts"))
      File.write(File.join(install, "scripts", "gem_requirement.rb"), %(module X\n  GEM_REQUIREMENT = [ ">= 5.37", "< 7" ].freeze\nend\n))

      expect(settings.plugin_gem_requirement).to eq([ ">= 5.37", "< 7" ])
    end

    # The reader takes the one line, so the shipped file has to keep its requirement there.
    it "reads the shipped requirement as the plugin's scripts load it" do
      shipped = File.expand_path("../../../plugins/rails-ai-context/scripts/gem_requirement.rb", __dir__)
      require shipped
      FileUtils.mkdir_p(File.join(install, "scripts"))
      FileUtils.cp(shipped, File.join(install, "scripts"))

      expect(settings.plugin_gem_requirement).to eq(Array(RailsAiContextPlugin::GEM_REQUIREMENT))
    end

    # Claude Code runs a directory marketplace's plugin from that folder, whatever the registry records.
    it "names the command a directory marketplace's plugin starts with" do
      clone = File.join(@dir, "clone")
      write(File.join(clone, ".claude-plugin", "marketplace.json"), "plugins" => [ { "name" => "rails-ai-context", "source" => "./plugins/rails-ai-context" } ])
      write(File.join(clone, "plugins", "rails-ai-context", ".mcp.json"),
            "mcpServers" => { "rails-ai-context" => { "command" => "ruby", "args" => [ "--", "${CLAUDE_PLUGIN_ROOT}/scripts/serve.rb" ] } })
      write(File.join(@config, "plugins", "known_marketplaces.json"), "rails-ai-context" => { "source" => { "source" => "directory", "path" => clone } })
      write(File.join(@config, "settings.json"), "allowedMcpServers" => [ { "serverName" => "github" } ])
      # The registry records a cache copy all the same.
      expect(install).not_to eq(File.join(clone, "plugins", "rails-ai-context"))

      expect(settings.blocked_plugin.command).to eq([ "ruby", "--", File.join(clone, "plugins", "rails-ai-context", "scripts", "serve.rb") ])
    end

    it "tells why a server of the app's would not start" do
      write(File.join(@config, "settings.json"), "allowedMcpServers" => [ { "serverName" => "github" } ])
      expect(settings.server_block("rails-ai-context", %w[rails-ai-context serve], @root)).to eq([ :allowlist, :user ])

      write(File.join(@config, "settings.json"), "allowedMcpServers" => [ { "serverName" => "rails-ai-context" } ])
      expect(fresh.server_block("rails-ai-context", %w[rails-ai-context serve], @root)).to be_nil

      write(managed, "strictPluginOnlyCustomization" => [ "mcp" ])
      expect(fresh.server_block("rails-ai-context", %w[rails-ai-context serve], @root)).to eq([ :locked, :managed ])
    end

    it "leaves out a second server the policy keeps Claude Code from starting" do
      write(File.join(@root, ".mcp.json"), "mcpServers" => { "rails-ai-context" => ours, "rac" => ours })
      write(claude_json, "mcpServers" => { "usr" => ours })
      write(File.join(@config, "settings.json"), "deniedMcpServers" => [ { "serverName" => "rac" }, { "serverCommand" => %w[rails-ai-context serve] } ])
      expect(found).to eq([])

      write(File.join(@config, "settings.json"), {})
      write(managed, "strictPluginOnlyCustomization" => [ "mcp" ])
      expect(fresh.duplicates).to eq([])
    end
  end

  # Claude Code loads no plugin from a marketplace its managed settings reject, whenever it was added.
  describe "managed marketplace policy" do
    let(:github) { { "source" => "github", "repo" => "team/rails-ai-context" } }

    before { write(File.join(@root, ".claude", "settings.json"), plugin(true)) }

    def rule_for(source, policy)
      known_marketplace(source)
      write(managed, policy)
      fresh.blocked_plugin&.rule
    end

    it "blocks the plugin of a marketplace a managed strictKnownMarketplaces leaves out" do
      expect(rule_for(github, {})).to be_nil
      expect(rule_for(github, "strictKnownMarketplaces" => [])).to eq(:marketplace)
      expect(fresh.plugin?).to be(false)
      expect(fresh.blocked_plugin).to have_attributes(scope: :managed, path: managed)

      expect(rule_for(github, "allowedMarketplaces" => [])).to eq(:marketplace)
      expect(rule_for(github, "strictKnownMarketplaces" => [ github ], "allowedMarketplaces" => [])).to be_nil
    end

    # An allowlist takes the owner/repo form alone, owner case and ref as written; an entry's path narrows it.
    it "matches an allowlist entry as Claude Code does" do
      {
        github => nil, { "source" => "github", "repo" => "team/*" } => nil, { "source" => "github", "repo" => "Team/rails-ai-context" } => :marketplace,
        github.merge("ref" => "v1") => :marketplace, github.merge("path" => "x") => :marketplace, { "source" => "github", "repo" => "*" } => :marketplace,
        { "source" => "github", "repo" => "team/rails-*" } => :marketplace,
        { "source" => "git", "url" => "https://github.com/team/rails-ai-context.git" } => :marketplace,
        { "source" => "hostPattern", "hostPattern" => "^github\\.com$" } => nil, { "source" => "hostPattern", "hostPattern" => "^gitlab" } => :marketplace,
        { "source" => "pathPattern", "pathPattern" => ".*" } => :marketplace
      }.each do |entry, rule|
        expect(rule_for(github, "strictKnownMarketplaces" => [ entry ])).to eq(rule), entry.inspect
      end
      expect(rule_for(github.merge("ref" => "v1", "path" => "x"), "strictKnownMarketplaces" => [ github ])).to eq(:marketplace)
      expect(rule_for(github.merge("ref" => "v1", "path" => "x"), "strictKnownMarketplaces" => [ github.merge("ref" => "v1") ])).to be_nil
    end

    # A false block would send the user to an admin for nothing.
    it "takes an entry it cannot read as no evidence" do
      [ { "source" => "npm", "package" => "x" }, { "source" => "hostPattern", "hostPattern" => "(" }, "team/rails-ai-context" ].each do |entry|
        expect(rule_for(github, "strictKnownMarketplaces" => [ entry ])).to be_nil, entry.inspect
        expect(rule_for(github, "blockedMarketplaces" => [ entry ])).to be_nil, entry.inspect
      end
    end

    # A blocklist entry takes any spelling of the repository, in any case, and every ref and path where it names none.
    it "blocks the plugin of a marketplace a managed blockedMarketplaces entry names" do
      ssh = { "source" => "git", "url" => "git@github.com:team/rails-ai-context.git" }
      expect(rule_for(github, "blockedMarketplaces" => [ { "source" => "github", "repo" => "TEAM/*" } ])).to eq(:marketplace)
      expect(rule_for(github.merge("ref" => "main", "path" => "x"), "blockedMarketplaces" => [ github ])).to eq(:marketplace)
      expect(rule_for(ssh, "blockedMarketplaces" => [ github ])).to eq(:marketplace)
      expect(rule_for(github, "blockedMarketplaces" => [ github.merge("ref" => "v1") ])).to be_nil
      expect(rule_for(github, "blockedMarketplaces" => [ { "source" => "github", "repo" => "other/rails-ai-context" } ])).to be_nil
      expect(rule_for(github, "blockedMarketplaces" => [ { "source" => "github", "repo" => "team" } ])).to be_nil

      expect(rule_for(ssh, "strictKnownMarketplaces" => [ github ])).to eq(:marketplace)
      expect(rule_for(ssh, "strictKnownMarketplaces" => [ { "source" => "hostPattern", "hostPattern" => "^github\\.com$" } ])).to be_nil
    end

    it "matches a local marketplace by its exact path or a pathPattern, and never by host" do
      clone = marketplace_clone(File.join(@dir, "clone"))
      local = { "source" => "directory", "path" => clone }
      expect(rule_for(local, "strictKnownMarketplaces" => [ local ])).to be_nil
      expect(rule_for(local, "strictKnownMarketplaces" => [ local.merge("path" => File.join(@dir, "other")) ])).to eq(:marketplace)
      expect(rule_for(local, "strictKnownMarketplaces" => [ { "source" => "pathPattern", "pathPattern" => "^/elsewhere/" } ])).to eq(:marketplace)
      expect(rule_for(local, "strictKnownMarketplaces" => [ { "source" => "pathPattern", "pathPattern" => "^#{Regexp.escape(@dir)}" } ])).to be_nil
      expect(rule_for(local, "strictKnownMarketplaces" => [ { "source" => "hostPattern", "hostPattern" => ".*" } ])).to eq(:marketplace)
      expect(rule_for(github.merge("path" => "x"), "strictKnownMarketplaces" => [ { "source" => "pathPattern", "pathPattern" => ".*" } ])).to eq(:marketplace)
      expect(rule_for(local, "blockedMarketplaces" => [ local ])).to eq(:marketplace)
    end

    it "reads the marketplace policy from managed files alone, drop-ins included" do
      known_marketplace(github)
      write(File.join(@config, "settings.json"), "strictKnownMarketplaces" => [], "blockedMarketplaces" => [ github ])
      expect(fresh.blocked_plugin).to be_nil

      drop_in = File.join(@dir, "managed-settings.d", "10-x.json")
      write(drop_in, "blockedMarketplaces" => [ github ])
      expect(fresh.blocked_plugin).to have_attributes(rule: :marketplace, scope: :managed, path: drop_in)
    end
  end

  describe "#duplicates" do
    before { write(File.join(@root, ".claude", "settings.json"), plugin(true)) }

    it "names the .mcp.json, user and local scope servers that run the gem's server beside the plugin's" do
      write(File.join(@root, ".mcp.json"), "mcpServers" => { "rails-ai-context" => ours, "other" => { "command" => "other" } })
      write(claude_json, "mcpServers" => { "rails-ai-context" => ours },
                         "projects" => { @root => { "mcpServers" => { "rac" => ours } },
                                         "/elsewhere" => { "mcpServers" => { "rails-ai-context" => ours } } })

      expect(settings.duplicates).to contain_exactly(
        have_attributes(scope: :project, name: "rails-ai-context", config: File.join(@root, ".mcp.json"), sessions: [ @root ]),
        have_attributes(scope: :user, name: "rails-ai-context"),
        have_attributes(scope: :local, name: "rac", key: @root)
      )
    end

    it "names a server under any name that runs the gem's server, in any of its command forms" do
      write(claude_json, "mcpServers" => { "rac" => { "command" => "bundle", "args" => %w[exec rails-ai-context serve] },
                                           "path" => { "command" => "/opt/bin/rails-ai-context", "args" => %w[--app-path . serve] },
                                           "rake" => { "command" => "bin/rails", "args" => [ "ai:serve" ] },
                                           "other" => { "command" => "rails-ai-context", "args" => %w[tool schema] } })

      expect(found).to eq([ [ :user, "rac" ], [ :user, "path" ], [ :user, "rake" ] ])
    end

    # Claude Code expands ${VAR} and ${VAR:-default} from its own environment, where
    # CLAUDE_PROJECT_DIR is unset, so the default stands as written, and PWD is the
    # session's folder. Any other form reaches the server as it is.
    it "names a server whose app path is the session's folder through a variable Claude Code expands" do
      app(File.join(@dir, "admin"))
      entry = ->(path) { { "command" => "rails-ai-context", "args" => [ "serve", "--app-path", path ] } }
      write(claude_json, "mcpServers" => { "default" => entry.("${CLAUDE_PROJECT_DIR:-.}"), "pwd" => entry.("${PWD}"),
                                           "pwd_default" => entry.("${PWD:-..}"), "bare" => entry.("${CLAUDE_PROJECT_DIR}"),
                                           "other" => entry.("${CLAUDE_PROJECT_DIR:-../admin}"), "colonless" => entry.("${CLAUDE_PROJECT_DIR-.}"),
                                           "shell" => entry.("$PWD"), "nested" => entry.("${CLAUDE_PROJECT_DIR:-$PWD}") })

      expect(found).to eq([ [ :user, "default" ], [ :user, "pwd" ], [ :user, "pwd_default" ] ])
    end

    # The binary reads an empty app path as the folder it starts in.
    it "names a server whose app path is empty, which serves the app a session in it starts in" do
      write(claude_json, "mcpServers" => { "blank" => { "command" => "rails-ai-context", "args" => [ "serve", "--app-path=" ] } })

      expect(found).to eq([ [ :user, "blank" ] ])
    end

    # Removing it would take another app's server away.
    it "leaves out a user or local scope server named for another app" do
      app(File.join(@dir, "admin"))
      other = { "command" => "rails-ai-context", "args" => [ "serve", "--app-path", File.join(@dir, "admin") ] }
      unreadable = { "command" => "rails-ai-context", "args" => [ "serve", "--app-path", "${APPS}/admin" ] }
      write(claude_json, "mcpServers" => { "admin" => other, "apps" => unreadable },
                         "projects" => { @root => { "mcpServers" => { "admin-local" => other } } })

      expect(found).to eq([])
    end

    it "gathers every session a server doubles the plugin's in" do
      write(File.join(@config, "settings.json"), plugin(true))
      write(claude_json, "mcpServers" => { "rails-ai-context" => ours })

      expect(settings.duplicates).to contain_exactly(have_attributes(scope: :user, sessions: [ @root, @dir ]))
    end

    # Claude Code loads every .mcp.json from the folder it started in up to the
    # filesystem root, and starts each server there.
    it "reads a .mcp.json above the app, counting the entries that serve this app from the session's folder" do
      app(File.join(@dir, "admin"))
      write(File.join(@dir, ".mcp.json"), "mcpServers" => {
        "rails-ai-context" => ours,
        "rails-ai-context-shop" => { "command" => "rails-ai-context", "args" => [ "serve", "--app-path", @root ] },
        "rails-ai-context-admin" => { "command" => "rails-ai-context", "args" => [ "serve", "--app-path", File.join(@dir, "admin") ] }
      })

      expect(found).to eq([ [ :project, "rails-ai-context" ], [ :project, "rails-ai-context-shop" ] ])
    end

    it "leaves out what the session never starts: a server /mcp turned off, or one its settings reject" do
      write(File.join(@root, ".mcp.json"), "mcpServers" => { "rails-ai-context" => ours, "rac" => ours })
      write(File.join(@root, ".claude", "settings.json"), plugin(true).merge("disabledMcpjsonServers" => [ "rac" ]))
      write(claude_json, "mcpServers" => { "user-rac" => ours },
                         "projects" => { @root => { "mcpServers" => { "local-rac" => ours }, "disabledMcpServers" => %w[rails-ai-context user-rac local-rac] } })

      expect(found).to eq([])
    end

    it "is empty where the plugin is off" do
      write(File.join(@root, ".claude", "settings.json"), plugin(false))
      write(claude_json, "mcpServers" => { "rails-ai-context" => ours })

      expect(found).to eq([])
    end

    it "keys a local server by the git root of the folder a session starts in" do
      git_root = File.join(@dir, "repo")
      root = File.join(git_root, "backend")
      app(root)
      FileUtils.mkdir_p(File.join(git_root, ".git"))
      write(File.join(root, ".claude", "settings.json"), plugin(true))
      write(claude_json, "projects" => { git_root => { "mcpServers" => { "rac" => ours } } })

      expect(fresh(root).duplicates).to contain_exactly(have_attributes(scope: :local, name: "rac", key: git_root, sessions: [ root ]))
    end

    it "names an HTTP entry under the gem's names, at user scope under the bare name alone" do
      write(File.join(@root, ".mcp.json"), "mcpServers" => { "rails-ai-context" => http, "web" => http })
      write(claude_json, "mcpServers" => { "rails-ai-context" => http, "rails-ai-context-admin" => http(4000), "rails-ai-context-shop" => http(4001) },
                         "projects" => { @root => { "mcpServers" => { "rails-ai-context-shop" => http } } })

      expect(found).to contain_exactly([ :project, "rails-ai-context" ], [ :user, "rails-ai-context" ], [ :local, "rails-ai-context-shop" ])
    end

    # An HTTP entry carries no --app-path, so another app's workspace name reaches that app's endpoint.
    it "counts a workspace HTTP entry under this app's own name, not another app's" do
      workspace = File.join(@dir, ".mcp.json")
      write(File.join(@root, ".claude", "settings.json"), plugin(true))
      write(workspace, "mcpServers" => { "rails-ai-context-blog" => http(3001) })

      expect(found).to eq([])
      expect(settings.gem_server_names(workspace, @root)).to eq([])

      write(workspace, "mcpServers" => { "rails-ai-context-blog" => http(3001), "rails-ai-context-shop" => http })
      expect(fresh.duplicates.map(&:name)).to eq([ "rails-ai-context-shop" ])
      expect(fresh.gem_server_names(workspace, @root)).to eq([ "rails-ai-context-shop" ])
    end

    # A serverUrl deny holds a remote server, and once the allowlist has a serverUrl entry a remote server must
    # match one: its name no longer admits it. serverCommand entries never touch a remote server.
    it "leaves out an HTTP entry the serverUrl policy keeps off, and keeps one the policy admits" do
      write(File.join(@root, ".mcp.json"), "mcpServers" => { "rails-ai-context" => http })
      policy = lambda do |data|
        write(File.join(@config, "settings.json"), data)
        fresh.duplicates.map(&:name)
      end

      expect(policy.("deniedMcpServers" => [ { "serverUrl" => "http://localhost:*" } ])).to eq([])
      expect(policy.("deniedMcpServers" => [ { "serverCommand" => [] } ])).to eq([ "rails-ai-context" ])
      expect(policy.("allowedMcpServers" => [ { "serverName" => "rails-ai-context" }, { "serverUrl" => "https://other/*" } ])).to eq([])
      expect(policy.("allowedMcpServers" => [ { "serverName" => "rails-ai-context" }, { "serverCommand" => [ "x" ] } ])).to eq([ "rails-ai-context" ])
      expect(policy.("allowedMcpServers" => [ { "serverCommand" => [ "x" ] } ])).to eq([])
      expect(policy.("allowedMcpServers" => [ { "serverUrl" => "http://localhost:3000/*" } ])).to eq([ "rails-ai-context" ])
    end

    it "is empty when Claude Code's own config is missing or unreadable" do
      expect(found).to eq([])

      File.write(claude_json, "not json")
      expect(fresh.duplicates).to eq([])
    end
  end

  describe ".user_config_dir and .user_claude_json" do
    let(:launch) { ENV.fetch("CLAUDE_CONFIG_DIR") }

    it "reads CLAUDE_CONFIG_DIR's .claude.json, else the one beside the home folder's .claude" do
      expect([ described_class.user_config_dir, described_class.user_claude_json ]).to eq([ launch, File.join(launch, ".claude.json") ])

      allow(Dir).to receive(:home).and_return(@dir)
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("CLAUDE_CONFIG_DIR").and_return(nil)
      allow(ENV).to receive(:[]).with("USERPROFILE").and_return(nil)
      expect([ described_class.user_config_dir, described_class.user_claude_json ])
        .to eq([ File.join(@dir, ".claude"), File.join(@dir, ".claude.json") ])
    end

    it "reads the home folder Claude Code reads on Windows, %USERPROFILE%" do
      allow(Gem).to receive(:win_platform?).and_return(true)
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("CLAUDE_CONFIG_DIR").and_return(nil)
      allow(ENV).to receive(:[]).with("USERPROFILE").and_return(@dir)

      expect([ described_class.user_config_dir, described_class.user_claude_json ]).to eq([ File.join(@dir, ".claude"), File.join(@dir, ".claude.json") ])
    end

    # Claude Code takes CLAUDE_CONFIG_DIR from the env block of the managed settings (a drop-in
    # over the file) or the user's too, for settings.json and plugins/ alone; a relative one,
    # set anywhere, leaves each session reading under its own folder.
    it "follows a CLAUDE_CONFIG_DIR the managed or the user's settings set, all but for .claude.json" do
      managed = described_class::MANAGED_SETTINGS
      drop_in = File.join(File.dirname(managed), "managed-settings.d", "10-x.json")
      user = File.join(launch, "settings.json")
      write(user, "env" => { "CLAUDE_CONFIG_DIR" => File.join(@dir, "work") })
      expect([ described_class.user_config_dir, described_class.user_claude_json ]).to eq([ File.join(@dir, "work"), File.join(launch, ".claude.json") ])
      expect(described_class.config_dir_setting).to eq([ File.join(@dir, "work"), user ])

      write(managed, "env" => { "CLAUDE_CONFIG_DIR" => File.join(@dir, "org") })
      expect(described_class.user_config_dir).to eq(File.join(@dir, "org"))
      write(drop_in, "env" => { "CLAUDE_CONFIG_DIR" => File.join(@dir, "team") })
      expect(described_class.user_config_dir).to eq(File.join(@dir, "team"))

      FileUtils.rm_rf([ managed, File.dirname(drop_in) ])
      write(user, "env" => { "CLAUDE_CONFIG_DIR" => "relative" })
      expect([ described_class.user_config_dir, described_class.relative_config_dir?, described_class.config_dir_setting ])
        .to eq([ nil, true, [ "relative", user ] ])

      # A file Claude Code drops whole moves nothing.
      write(user, "env" => { "CLAUDE_CONFIG_DIR" => File.join(@dir, "work") }, "enabledPlugins" => { "x@y" => 1 })
      expect(described_class.user_config_dir).to eq(launch)

      # A managed file loses only the entry.
      write(managed, "env" => { "CLAUDE_CONFIG_DIR" => File.join(@dir, "org") }, "enabledPlugins" => { "x@y" => 1 })
      expect(described_class.config_dir_setting).to eq([ File.join(@dir, "org"), managed ])
    ensure
      FileUtils.rm_rf([ user, managed, File.dirname(drop_in) ].compact)
    end

    # Claude Code reads a value that is no string as text, null as empty.
    it "takes an env-block CLAUDE_CONFIG_DIR that is empty or null as set and relative" do
      user = File.join(launch, "settings.json")
      [ "", nil ].each do |value|
        write(user, "env" => { "CLAUDE_CONFIG_DIR" => value })

        expect([ described_class.relative_config_dir?, described_class.config_dir_setting ]).to eq([ true, [ "", user ] ]), value.inspect
      end
    ensure
      FileUtils.rm_f(user)
    end

    # Node counts a path rooted on the current drive as absolute on Windows, where Ruby asks for a drive letter.
    it "takes a CLAUDE_CONFIG_DIR rooted on the current drive for absolute on Windows, as Claude Code does" do
      allow(Gem).to receive(:win_platform?).and_return(true)
      allow(File).to receive(:absolute_path?) { |path| path.match?(%r{\A([A-Za-z]:[\\/]|[\\/]{2})}) }
      allow(ENV).to receive(:[]).and_call_original
      { "\\cc" => false, "/cc" => false, "C:\\cc" => false, "C:cc" => true, "cc" => true }.each do |value, relative|
        allow(ENV).to receive(:[]).with("CLAUDE_CONFIG_DIR").and_return(value)

        expect(described_class.relative_config_dir?).to be(relative), value
      end
    end

    # Claude Code keeps using its older global config file wherever one is left.
    it "reads the older .config.json in the config folder where one is left" do
      legacy = File.join(ENV.fetch("CLAUDE_CONFIG_DIR"), ".config.json")
      File.write(legacy, "{}")

      expect(described_class.user_claude_json).to eq(legacy)
    ensure
      FileUtils.rm_f(legacy)
    end

    # Claude Code then reads its config under whatever folder a session starts in.
    it "knows no config folder when CLAUDE_CONFIG_DIR is set but not an absolute path" do
      allow(ENV).to receive(:[]).and_call_original
      [ "", "ccrel", "~/x" ].each do |value|
        allow(ENV).to receive(:[]).with("CLAUDE_CONFIG_DIR").and_return(value)

        expect([ described_class.user_config_dir, described_class.user_claude_json, described_class.relative_config_dir? ]).to eq([ nil, nil, true ])
      end
    end
  end
end
