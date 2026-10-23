# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Install::ClaudePluginRemoval do
  let(:config) { ENV.fetch("CLAUDE_CONFIG_DIR") }
  let(:registry) { File.join(config, "plugins", "installed_plugins.json") }
  let(:managed) { RailsAiContext::ClaudeCodeSettings::MANAGED_SETTINGS }
  let(:id) { "rails-ai-context@rails-ai-context" }

  around do |example|
    Dir.mktmpdir do |dir|
      @dir = File.realpath(dir)
      example.run
    ensure
      FileUtils.rm_rf([ File.dirname(registry), File.join(config, "settings.json"), File.join(config, ".claude.json"), File.dirname(managed) ])
    end
  end

  def app(path, git: true)
    root = File.join(@dir, path)
    FileUtils.mkdir_p(File.join(root, "config"))
    File.write(File.join(root, "config", "application.rb"), "")
    FileUtils.mkdir_p(File.join(root, ".git")) if git
    root
  end

  def write(path, data)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, JSON.generate(data))
  end

  # A folder above that held this app alone would be one more place a session serves it from.
  before { app("other", git: false) }

  def installed(*ids) = write(registry, "version" => 2, "plugins" => ids.to_h { |name| [ name, [ { "scope" => "user" } ] ] })

  def on(*ids) = write(File.join(config, "settings.json"), "enabledPlugins" => ids.to_h { |name| [ name, true ] })

  it "asks whoever manages the settings to turn off a plugin they turn on" do
    root = app("shop")
    installed(id)
    write(managed, "enabledPlugins" => { id => true })

    expect(described_class.lines([ root ], cwd: root)).to eq([ "Managed Claude Code settings turn on the rails-ai-context plugin, which runs the " \
                                                              "installed gem: ask whoever manages them to turn it off before you remove the gem." ])
  end

  # Claude Code never ran here, so nothing it installed runs the gem.
  it "says nothing where Claude Code has never run, whatever the app's settings say" do
    root = app("shop")
    write(File.join(root, ".claude", "settings.json"), "enabledPlugins" => { id => true })
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("CLAUDE_CONFIG_DIR").and_return(File.join(@dir, "never"))

    expect(described_class.lines([ root ], cwd: root)).to eq([])
  end

  # The repository's local file is written from any session in it, and every one of them reads it.
  it "names one folder per repository whose sessions run the plugin" do
    skip "Claude Code keeps each folder's local settings apart on Windows" if Gem.win_platform?

    root = app("shop")
    installed(id)
    on(id)
    FileUtils.mkdir_p(File.join(root, "lib"))
    write(File.join(config, ".claude.json"), "projects" => { File.join(root, "lib") => {} })

    expect(described_class.lines([ root ], cwd: root).first).to include("`claude plugin disable #{id} --scope local` turns it off for this app")
  end

  # A disable for one id leaves the other id's copy of the plugin running.
  it "names every id the plugin runs under" do
    root = app("shop")
    installed(id, "rails-ai-context@mirror")
    on(id, "rails-ai-context@mirror")

    expect(described_class.lines([ root ], cwd: root).first).to include("--scope local` turns it off for this app", "`claude plugin disable rails-ai-context@mirror")
  end

  # A directory marketplace runs its plugin with no install, so no uninstall takes it out.
  it "offers no uninstall where a directory marketplace runs the plugin" do
    root = app("shop")
    installed(id)
    on(id)
    write(File.join(config, "plugins", "known_marketplaces.json"), "rails-ai-context" => { "source" => { "source" => "directory", "path" => @dir } })
    write(File.join(@dir, ".claude-plugin", "marketplace.json"), "plugins" => [ { "name" => "rails-ai-context", "source" => "./plugins/rails-ai-context" } ])
    FileUtils.mkdir_p(File.join(@dir, "plugins", "rails-ai-context"))

    expect(described_class.lines([ root ], cwd: root)).to eq([ "The rails-ai-context Claude Code plugin runs the installed gem; take it out before " \
                                                              "the gem: `claude plugin disable #{id} --scope local` turns it off for this app." ])
  end

  # A marketplace added by its marketplace.json path runs in place too.
  it "offers no uninstall where a file marketplace runs the plugin" do
    root = app("shop")
    installed(id)
    on(id)
    write(File.join(config, "plugins", "known_marketplaces.json"),
          "rails-ai-context" => { "source" => { "source" => "file", "path" => File.join(@dir, ".claude-plugin", "marketplace.json") } })
    write(File.join(@dir, ".claude-plugin", "marketplace.json"), "plugins" => [ { "name" => "rails-ai-context", "source" => "./plugins/rails-ai-context" } ])
    FileUtils.mkdir_p(File.join(@dir, "plugins", "rails-ai-context"))

    expect(described_class.lines([ root ], cwd: root).first).not_to include("plugin uninstall")
  end

  # The repository's main checkout holds the local file every session in it reads, the other apps' included.
  it "says a disable in an app below its git root reaches every session in that repository" do
    skip "Claude Code keeps each folder's local settings apart on Windows" if Gem.win_platform?

    repo = File.join(@dir, "mono")
    FileUtils.mkdir_p(File.join(repo, ".git"))
    root = app("mono/shop", git: false)
    installed(id)
    on(id)

    expect(described_class.lines([ root ], cwd: root).first)
      .to include("`claude plugin disable #{id} --scope local` turns it off for every session in the git repository at #{repo},")
  end

  # Outside a git repository, and on Windows, each session folder keeps a local file of its own.
  it "names each session folder's own disable where no repository shares one" do
    root = app("shop", git: false)
    installed(id)
    on(id)
    expect(described_class.lines([ root ], cwd: root).first).to include("--scope local` turns it off for this app,")

    FileUtils.mkdir_p(File.join(root, ".git"))
    FileUtils.mkdir_p(File.join(root, "lib"))
    write(File.join(config, ".claude.json"), "projects" => { File.join(root, "lib") => {} })
    allow(Gem).to receive(:win_platform?).and_return(true)
    expect(described_class.lines([ root ], cwd: root).first)
      .to include("--scope local` run here and in lib turns it off for this app and sessions started there,")
  end

  # managed-mcp.json starts its own servers alone, the plugin's never.
  it "names managed-mcp.json's own server of the gem's, and nothing for a plugin that cannot start" do
    root = app("shop")
    installed(id)
    on(id)
    write(File.join(File.dirname(managed), "managed-mcp.json"), "mcpServers" => {})
    expect(described_class.lines([ root ], cwd: root)).to eq([])

    write(File.join(File.dirname(managed), "managed-mcp.json"), "mcpServers" => { "rails" => { "command" => "rails-ai-context", "args" => [ "serve" ] } })
    expect(described_class.lines([ root ], cwd: root))
      .to eq([ "managed-mcp.json runs the gem's server `rails`: ask whoever manages it to take it out before you remove the gem." ])
  end

  it "names the relative CLAUDE_CONFIG_DIR that leaves each session reading its own folder's plugins" do
    root = app("shop")
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("CLAUDE_CONFIG_DIR").and_return("ccrel")

    expect(described_class.lines([ root ], cwd: root).first).to start_with("CLAUDE_CONFIG_DIR (`ccrel`) is not an absolute path, so each Claude Code session")
  end

  # In a folder of apps one line covers them all where it holds for each; else each names its app.
  it "says one line for a folder of apps it holds for, and names the app where they differ" do
    skip "Claude Code keeps each folder's local settings apart on Windows" if Gem.win_platform?

    work = File.join(@dir, "work")
    FileUtils.mkdir_p(File.join(work, ".git"))
    shop = app("work/shop", git: false)
    blog = app("work/blog", git: false)
    installed(id)
    on(id)
    expect(described_class.lines([ shop, blog ], cwd: work, workspace: true))
      .to eq([ "The rails-ai-context Claude Code plugin runs the installed gem; take it out before the gem: `claude plugin disable #{id} " \
               "--scope local` run in shop turns it off for every session in this git repository, or `claude plugin uninstall #{id} " \
               "--scope user` takes it out everywhere." ])

    FileUtils.rm_f(File.join(config, "settings.json"))
    write(File.join(shop, ".claude", "settings.json"), "enabledPlugins" => { id => true })
    expect(described_class.lines([ shop, blog ], cwd: work, workspace: true))
      .to eq([ "The rails-ai-context Claude Code plugin runs the installed gem; take it out before the gem: `claude plugin disable #{id} " \
               "--scope local` run in shop turns it off for every session in this git repository, or `claude plugin uninstall #{id} " \
               "--scope user` takes it out everywhere." ])
  end
end
