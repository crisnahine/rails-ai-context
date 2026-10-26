# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "json"
require "fileutils"

RSpec.describe RailsAiContext::Install::Uninstall do
  let(:said) { [] }
  let(:surface) { RailsAiContext::Install::Surface.new(->(text, level) { said << [ level, text ] }, ->(_prompt) { }, nil) }
  let(:json_note) { "# rails-ai-context (JSON cache - markdown files should be committed)" }
  let(:codex_note) { "# rails-ai-context (embeds this machine's Ruby PATH/GEM_HOME - do not share)" }

  around do |example|
    Dir.mktmpdir do |dir|
      @root = File.realpath(dir)
      example.run
    end
  end

  def write(relative, content, root: @root)
    path = File.join(root, relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, content)
    path
  end

  def app(root = @root)
    write("config/application.rb", "module X\n  class Application < Rails::Application\n  end\nend\n", root: root)
    write("Gemfile", "gem \"rails\"\n", root: root)
  end

  # Every file under the root with its bytes, .git aside.
  def tree(root = @root)
    Dir.glob("**/*", File::FNM_DOTMATCH, base: root).sort.filter_map do |relative|
      path = File.join(root, relative)
      [ relative, File.binread(path) ] if File.file?(path) && !relative.start_with?(".git/")
    end.to_h
  end

  def uninstall(**options)
    described_class.call(surface, root: @root, **options)
  end

  it "removes the recorded config, the JSON cache and the initializer, edited or not" do
    app
    write(".rails-ai-context.yml", "ai_tools:\n- claude\n# my note\n")
    write(".ai-context.json", "{}")
    write("config/initializers/rails_ai_context.rb", "RailsAiContext.configure { |c| c.mine = true }\n")

    expect(uninstall).to be(true)

    expect(tree.keys).to eq(%w[Gemfile config/application.rb])
    expect(said).to eq([ [ :ok, "  Removed .rails-ai-context.yml" ], [ :ok, "  Removed .ai-context.json" ],
                         [ :ok, "  Removed config/initializers/rails_ai_context.rb" ] ])
  end

  it "leaves an app it was never installed in as it is, and says nothing" do
    app
    write(".gitignore", "*.log\n.ai-context.json\n")
    write("config/initializers/rails_ai.rb", "# mine\n")
    write(".mcp.json", JSON.generate("mcpServers" => { "mine" => { "command" => "x" } }))
    before = tree

    expect(uninstall).to be(false)

    expect(tree).to eq(before)
    expect(said).to be_empty
  end

  describe "the .gitignore lines" do
    it "go with their notes and the blank line above, and the user's lines stay" do
      app
      write(".gitignore", "*.log\n\n#{json_note}\n.ai-context.json\n\n#{codex_note}\n.codex/config.toml\n/tmp\n")

      expect(uninstall).to be(true)

      expect(File.read(File.join(@root, ".gitignore"))).to eq("*.log\n/tmp\n")
      expect(said).to eq([ [ :ok, "  Removed the rails-ai-context lines from .gitignore" ] ])
    end

    it "go when an earlier release wrote the note with a Unicode dash, and when the file ends without a newline" do
      app
      write(".gitignore", "*.log\n\n# rails-ai-context (JSON cache \u2014 markdown files should be committed)\n.ai-context.json")

      expect(uninstall).to be(true)

      expect(File.binread(File.join(@root, ".gitignore"))).to eq("*.log\n")
    end

    it "go from a file with Windows line endings" do
      app
      write(".gitignore", "*.log\r\n\r\n#{json_note}\r\n.ai-context.json\r\n/tmp\r\n")

      expect(uninstall).to be(true)

      expect(File.binread(File.join(@root, ".gitignore"))).to eq("*.log\r\n/tmp\r\n")
    end

    it "stay when the user ignored the path under a note of their own" do
      app
      write(".gitignore", "# local caches\n.ai-context.json\n.codex/config.toml\n")

      expect(uninstall).to be(false)

      expect(File.read(File.join(@root, ".gitignore"))).to eq("# local caches\n.ai-context.json\n.codex/config.toml\n")
    end
  end

  describe "an MCP config" do
    it "loses the gem's entry and keeps the user's server" do
      app
      write(".mcp.json", JSON.generate("mcpServers" => { "mine" => { "command" => "x" } }))
      RailsAiContext::Install::Program.write_mcp_configs(surface, tools: %i[claude], tool_mode: :mcp, root: @root, standalone: true)
      expect(JSON.parse(File.read(File.join(@root, ".mcp.json")))["mcpServers"].keys).to eq(%w[mine rails-ai-context])

      expect(uninstall).to be(true)

      expect(JSON.parse(File.read(File.join(@root, ".mcp.json")))["mcpServers"]).to eq("mine" => { "command" => "x" })
    end

    it "goes when the gem's entry was all it held" do
      app
      RailsAiContext::Install::Program.write_mcp_configs(surface, tools: %i[claude cursor], tool_mode: :mcp, root: @root, standalone: true)
      expect(tree.keys).to include(".mcp.json", ".cursor/mcp.json")

      expect(uninstall).to be(true)

      expect(tree.keys).to eq(%w[Gemfile config/application.rb])
    end

    it "loses an HTTP entry under the gem's name, which no install wrote but only the gem's endpoint answers" do
      app
      write(".mcp.json", JSON.generate("mcpServers" => {
        "rails-ai-context" => { "type" => "http", "url" => "http://localhost:3000/mcp" }, "mine" => { "url" => "http://x" }
      }))

      expect(uninstall).to be(true)

      expect(JSON.parse(File.read(File.join(@root, ".mcp.json")))["mcpServers"].keys).to eq(%w[mine])
    end

    it "loses a Codex HTTP entry under the gem's name too, and keeps the user's" do
      app
      write(".codex/config.toml", %([mcp_servers.rails-ai-context]\nurl = "http://localhost:6029/mcp"\n\n) +
                                  %([mcp_servers.other]\ncommand = "other"\n))

      expect(uninstall).to be(true)

      expect(File.read(File.join(@root, ".codex/config.toml"))).to eq(%([mcp_servers.other]\ncommand = "other"\n))
    end
    # SETUP.md tells users to write the Docker entry under the gem's name; what a user wrote stays, and is named.
    it "keeps an entry a user wrote under the gem's name, and names it with its file" do
      app
      docker = { "command" => "docker", "args" => %w[compose run --rm web bundle exec rails-ai-context serve] }
      write(".mcp.json", JSON.generate("mcpServers" => {
        "rails-ai-context" => docker,
        "rails-ai-context-x" => { "command" => "docker", "args" => %w[exec -i web rails-ai-context serve] },
        "rails-ai-context-y" => { "command" => "rails-ai-context", "args" => %w[serve --app-path y] },
        "rails-ai-context-z" => { "command" => "rails-ai-context", "args" => %w[serve --app-path z], "env" => { "RAILS_ENV" => "test" } }
      }))

      kept = []
      uninstall(kept: kept)

      expect(kept).to eq([ { file: ".mcp.json", name: "rails-ai-context", starts: true }, { file: ".mcp.json", name: "rails-ai-context-x", starts: true },
                           { file: ".mcp.json", name: "rails-ai-context-z", starts: true } ])
      expect(JSON.parse(File.read(File.join(@root, ".mcp.json")))["mcpServers"].keys).to eq(%w[rails-ai-context rails-ai-context-x rails-ai-context-z])
      expect(said).to include([ :ok, "  Removed rails-ai-context-y from .mcp.json" ],
                              [ :warn, "Left `rails-ai-context` in .mcp.json: its command is not one rails-ai-context writes, " \
                                       "so remove it by hand if it should go" ],
                              [ :warn, "Left `rails-ai-context-x` in .mcp.json: its command is not one rails-ai-context writes, " \
                                       "so remove it by hand if it should go" ],
                              [ :warn, "Left `rails-ai-context-z` in .mcp.json: it holds env.RAILS_ENV, which rails-ai-context never " \
                                       "writes, so remove it by hand if it should go" ])
    end
  end

  describe "the pre-commit hook" do
    before do
      app
      system("git", "init", "-q", @root, out: File::NULL, err: File::NULL)
    end

    let(:hook) { File.join(@root, ".git", "hooks", "pre-commit") }
    let(:script) { RailsAiContext::Install::ValidationHook.script([ "." ], standalone: true) }

    it "goes when it is as the install wrote it" do
      write(".git/hooks/pre-commit", script)

      expect(uninstall).to be(true)

      expect(File.exist?(hook)).to be(false)
      expect(said).to eq([ [ :ok, "  Removed the pre-commit hook #{hook}" ] ])
    end

    it "stays when it was changed by hand, and is named" do
      write(".git/hooks/pre-commit", "#{script}echo mine\n")

      expect(uninstall).to be(false)

      expect(File.read(hook)).to eq("#{script}echo mine\n")
      expect(said).to eq([ [ :warn, "#{hook} still runs rails-ai-context - it was changed by hand, so remove that part yourself" ] ])
    end

    it "stays when it is the user's own" do
      write(".git/hooks/pre-commit", "#!/bin/sh\nbundle exec rubocop\n")

      expect(uninstall).to be(false)

      expect(File.read(hook)).to eq("#!/bin/sh\nbundle exec rubocop\n")
      expect(said).to be_empty
    end
  end

  it "names a mounted engine by file and line and leaves config/routes.rb alone" do
    app
    routes = "Rails.application.routes.draw do\n  # mount RailsAiContext::Engine, at: \"/old\"\n  mount RailsAiContext::Engine, at: \"/mcp\"\nend\n"
    write("config/routes.rb", routes)

    expect(uninstall).to be(false)

    expect(File.read(File.join(@root, "config/routes.rb"))).to eq(routes)
    expect(said).to eq([ [ :warn, "config/routes.rb:3 mounts RailsAiContext::Engine - delete that line" ] ])
  end

  it "clears every app of a folder of apps, and the folder's own MCP config and .gitignore" do
    apps = %w[a b].map { |name| File.join(@root, name) }
    apps.each do |dir|
      app(dir)
      write(".rails-ai-context.yml", "ai_tools:\n- claude\n", root: dir)
      write(".gitignore", "*.log\n\n#{json_note}\n.ai-context.json\n", root: dir)
    end
    write(".gitignore", "\n#{codex_note}\n.codex/config.toml\n")
    write(".mcp.json", JSON.generate("mcpServers" => {
      "rails-ai-context-a" => { "command" => "rails-ai-context", "args" => [ "serve", "--app-path", "a" ] },
      "mine" => { "command" => "x" }
    }))

    expect(uninstall(app_roots: apps)).to be(true)

    expect(tree.except(".mcp.json")).to eq(
      ".gitignore" => "",
      "a/.gitignore" => "*.log\n", "a/Gemfile" => "gem \"rails\"\n", "a/config/application.rb" => File.read(File.join(apps[0], "config/application.rb")),
      "b/.gitignore" => "*.log\n", "b/Gemfile" => "gem \"rails\"\n", "b/config/application.rb" => File.read(File.join(apps[1], "config/application.rb"))
    )
    expect(JSON.parse(tree.fetch(".mcp.json"))["mcpServers"].keys).to eq(%w[mine])
    expect(said).to include([ :ok, "  Removed a/.rails-ai-context.yml" ], [ :ok, "  Removed b/.rails-ai-context.yml" ])
  end

  it "deletes and edits nothing a symlinked directory carries out of the app, and names what it left" do
    Dir.mktmpdir do |outside|
      outside = File.realpath(outside)
      app
      write("claude/rules/rails-schema.md", "<!-- rails-ai-context:auto-generated -->\n# Schema\n", root: outside)
      write("github/copilot-instructions.md", "<!-- BEGIN rails-ai-context -->\nx\n<!-- END rails-ai-context -->\nmine\n", root: outside)
      write("cursor/rules/rails-project.mdc", "---\nalwaysApply: true\n---\n", root: outside)
      write("initializers/rails_ai_context.rb", "RailsAiContext.configure { }\n", root: outside)
      File.symlink(File.join(outside, "claude"), File.join(@root, ".claude"))
      File.symlink(File.join(outside, "github"), File.join(@root, ".github"))
      File.symlink(File.join(outside, "cursor"), File.join(@root, ".cursor"))
      File.symlink(File.join(outside, "initializers"), File.join(@root, "config/initializers"))
      before = tree(outside)

      uninstall

      expect(tree(outside)).to eq(before)
      expect(said.select { |level, _| level == :warn }.map(&:last).join("\n"))
        .to include("config/initializers/rails_ai_context.rb").and include(".cursor/rules/")
        .and include(".claude/rules/").and include(".github/copilot-instructions.md")
      expect(said.map(&:last).join("\n")).not_to include("check its permissions")
    end
  end

  it "edits no .gitignore a symlink carries out of the app, and names it" do
    Dir.mktmpdir do |outside|
      outside = File.realpath(outside)
      app
      write("gitignore", "*.log\n\n#{json_note}\n.ai-context.json\n", root: outside)
      File.symlink(File.join(outside, "gitignore"), File.join(@root, ".gitignore"))

      uninstall

      expect(File.binread(File.join(outside, "gitignore"))).to eq("*.log\n\n#{json_note}\n.ai-context.json\n")
      expect(said).to include([ :warn, "Left .gitignore as it is - it is a symlink or behind one, which this run does not follow" ])
    end
  end

  it "names a rules folder that is itself a symlink and holds the gem's files, and deletes nothing through it" do
    Dir.mktmpdir do |outside|
      outside = File.realpath(outside)
      app
      write("rules/rails-schema.md", "<!-- rails-ai-context:auto-generated -->\n# Schema\n", root: outside)
      write("team-rules/house-style.md", "# Ours\n", root: outside)
      FileUtils.mkdir_p(File.join(@root, ".claude"))
      FileUtils.mkdir_p(File.join(@root, ".cursor"))
      File.symlink(File.join(outside, "rules"), File.join(@root, ".claude/rules"))
      File.symlink(File.join(outside, "team-rules"), File.join(@root, ".cursor/rules"))
      before = tree(outside)

      uninstall

      expect(tree(outside)).to eq(before)
      warned = said.select { |level, _| level == :warn }.map(&:last).join("\n")
      expect(warned).to include("Left .claude/rules/ as it is - it is a symlink or behind one, which this run does not follow")
      expect(warned).not_to include("check its permissions")
      expect(warned).not_to include(".cursor/rules/")
    end
  end

  it "finds nothing to do on a second run" do
    app
    write(".rails-ai-context.yml", "ai_tools:\n- claude\n")
    write(".gitignore", "*.log\n\n#{json_note}\n.ai-context.json\n")
    RailsAiContext::Install::Program.write_mcp_configs(surface, tools: %i[claude], tool_mode: :mcp, root: @root, standalone: true)
    expect(uninstall).to be(true)
    after_first = tree
    said.clear

    expect(uninstall).to be(false)

    expect(tree).to eq(after_first)
    expect(said).to be_empty
  end
end
