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

  def found = settings.duplicates.map { |dup| [ dup.scope, dup.name ] }

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

    it "takes a list of version constraints as on" do
      write(File.join(@root, ".claude", "settings.json"), plugin([ ">=5.37.0" ]))

      expect(settings.plugin?).to be(true)
    end

    # Claude Code reads local settings from the folder's git root too, and writes them there.
    it "reads the local settings of the git root above the app" do
      git_root = File.join(@dir, "repo")
      root = File.join(git_root, "backend")
      app(root)
      FileUtils.mkdir_p(File.join(git_root, ".git"))
      write(File.join(root, ".claude", "settings.json"), plugin(true))
      write(File.join(git_root, ".claude", "settings.local.json"), plugin(false))

      expect(fresh(root).plugin?).to be(false)
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

    # The binary refuses a bin/rails alone, though the app root resolves to it.
    it "is off for a folder the server refuses to read" do
      engine = File.join(@dir, "engine")
      FileUtils.mkdir_p(File.join(engine, "bin"))
      File.write(File.join(engine, "bin", "rails"), %(ENGINE_PATH = "x"\n))
      write(File.join(engine, ".claude", "settings.json"), plugin(true))

      expect(fresh(engine).plugin?).to be(false)
    end

    it "skips a settings file that is not JSON, not an object, or not readable" do
      FileUtils.mkdir_p(File.join(@root, ".claude", "settings.local.json"))
      write(File.join(@root, ".claude", "settings.json"), [ 1 ])
      write(File.join(@config, "settings.json"), plugin(true))
      File.write(managed, "{")

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
                         "projects" => { @root => { "disabledMcpServers" => %w[rails-ai-context user-rac] } })

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

    it "is empty when Claude Code's own config is missing or unreadable" do
      expect(found).to eq([])

      File.write(claude_json, "not json")
      expect(fresh.duplicates).to eq([])
    end
  end

  describe ".user_config_dir and .user_claude_json" do
    it "reads CLAUDE_CONFIG_DIR's .claude.json, else the one beside the home folder's .claude" do
      expect([ described_class.user_config_dir, described_class.user_claude_json ])
        .to eq([ ENV.fetch("CLAUDE_CONFIG_DIR"), File.join(ENV.fetch("CLAUDE_CONFIG_DIR"), ".claude.json") ])

      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("CLAUDE_CONFIG_DIR").and_return("")
      expect([ described_class.user_config_dir, described_class.user_claude_json ])
        .to eq([ File.join(Dir.home, ".claude"), File.join(Dir.home, ".claude.json") ])
    end
  end
end
