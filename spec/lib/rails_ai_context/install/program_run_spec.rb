# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "json"
require "fileutils"

# The one install order every entry runs: init, init in a folder of apps,
# the generator and the first `rails ai:context`. Each entry hands in its
# own steps (boot, record, hook, context) and the program calls them at
# their place, so a recording surface and block see the whole order.
RSpec.describe RailsAiContext::Install::Program, ".run" do
  let(:marked_block) { "<!-- BEGIN rails-ai-context -->\ngenerated\n<!-- END rails-ai-context -->\n" }

  around do |example|
    Dir.mktmpdir do |dir|
      @root = File.realpath(dir)
      example.run
    end
  end

  # Records every line said, every question asked and every step called, in order.
  let(:events) { [] }
  let(:surface) do
    RailsAiContext::Install::Surface.new(->(text, level) { events << [ :say, level, text ] },
                                         ->(prompt) { events << [ :ask, prompt ] && "" }, nil)
  end

  def answers(**given)
    described_class::Answers.new(**{ prune: false, defaults: true }.merge(given))
  end

  def write(relative, content, root: @root)
    path = File.join(root, relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, content)
    path
  end

  def rails_app(root)
    write("config/application.rb", "module X\n  class Application < Rails::Application\n  end\nend\n", root: root)
    write("Gemfile", "", root: root)
    write("Gemfile.lock", "GEM\n  remote: https://rubygems.org/\n  specs:\n    rails (8.0.0)\n\n", root: root)
  end

  def run(given = answers, root: @root)
    described_class.run(given, surface: surface, root: root) do |step, install|
      events << [ :step, step ]
      RailsAiContext::Install::SelectionRecord.write(install.tools, root: root, initializer: false,
                                                                    extra_yaml: { "tool_mode" => install.setup.tool_mode.to_s,
                                                                                  "context_files" => install.setup.context_files }) if step == :record
    end
  end

  def position(&match)
    events.index(&match) or raise "no such event in #{events.inspect}"
  end

  it "asks every question before any step, then removes, records, writes the configs, the .gitignore, the hook and the context" do
    rails_app(@root)
    write(".rails-ai-context.yml", "ai_tools:\n- claude\n- cursor\ntool_mode: mcp\ncontext_files: true\n")
    write(".cursorrules", marked_block)
    write(".gitignore", "*.log\n")

    install = run(answers(tools: %i[claude], prune: true))

    steps = events.select { |event| event.first == :step }.map(&:last)
    expect(steps).to eq(%i[boot record hook context])
    removed = position { |event| event[2].to_s.include?("Removed .cursorrules") }
    config = position { |event| event[2].to_s.include?("Created/Updated .mcp.json") }
    ignored = position { |event| event[2].to_s.include?("Updated .gitignore") }
    expect(position { |event| event.first == :say && event[2].start_with?("These AI tools were removed") })
      .to be < position { |event| event == [ :step, :boot ] }
    expect(position { |event| event == [ :step, :boot ] }).to be < removed
    expect(removed).to be < position { |event| event == [ :step, :record ] }
    expect(position { |event| event == [ :step, :record ] }).to be < config
    expect(config).to be < ignored
    expect(ignored).to be < position { |event| event == [ :step, :hook ] }
    expect(install).to have_attributes(tools: %i[claude], previous: %i[claude cursor], removed_context: false, held: [])
    expect(install.setup.to_a).to eq([ :mcp, true ])
  end

  it "asks about the legacy files through the surface and removes them after the boot, with the other removals" do
    rails_app(@root)
    legacy = write(".claude/rules/rails-ui-patterns.md", "# stale")
    removed_at = nil

    described_class.run(answers(tools: %i[claude], prune: true), surface: surface, root: @root) do |step, _install|
      events << [ :step, step ]
      removed_at ||= step unless File.exist?(legacy)
    end

    expect(events).to include([ :say, :plain, "Legacy files detected (removed in v5.0.0):" ])
    expect(position { |event| event[2].to_s.include?("Removed .claude/rules/rails-ui-patterns.md") })
      .to be > position { |event| event == [ :step, :boot ] }
    expect(removed_at).to eq(:record)
  end

  it "keeps the recorded tools and setup on a re-run that takes every default" do
    rails_app(@root)
    write(".rails-ai-context.yml", "ai_tools:\n- cursor\ntool_mode: cli\ncontext_files: true\n")

    install = run

    expect(install.tools).to eq(%i[cursor])
    expect(install.setup.to_a).to eq([ :cli, true ])
    expect(File.exist?(File.join(@root, ".cursor/mcp.json"))).to be(false)
  end

  it "keeps a dropped tool's files on the default answer, and removes them under prune" do
    rails_app(@root)
    write(".rails-ai-context.yml", "ai_tools:\n- claude\n- cursor\n")
    write(".cursorrules", marked_block)

    run(answers(tools: %i[claude]))
    expect(File.exist?(File.join(@root, ".cursorrules"))).to be(true)

    write(".rails-ai-context.yml", "ai_tools:\n- claude\n- cursor\n")
    run(answers(tools: %i[claude], prune: true))
    expect(File.exist?(File.join(@root, ".cursorrules"))).to be(false)
  end

  it "takes the gem out of the MCP configs on a switch to the CLI setup under prune" do
    rails_app(@root)
    write(".mcp.json", JSON.generate("mcpServers" => { "rails-ai-context" => { "command" => "rails-ai-context", "args" => [ "serve" ] } }))

    run(answers(tools: %i[claude], setup: described_class.setup_for(:cli), prune: true))

    expect(File.exist?(File.join(@root, ".mcp.json"))).to be(false)
  end

  it "takes the generated context files out on a switch to MCP only under prune, and keeps them on the default answer" do
    rails_app(@root)
    write("CLAUDE.md", marked_block)
    mcp_only = described_class.setup_for(:mcp_only)

    install = run(answers(tools: %i[claude], setup: mcp_only))
    expect(File.exist?(File.join(@root, "CLAUDE.md"))).to be(true)
    expect(install.removed_context).to be(false)
    expect(events.map(&:last).join("\n")).to include("would go stale")

    install = run(answers(tools: %i[claude], setup: mcp_only, prune: true))
    expect(File.exist?(File.join(@root, "CLAUDE.md"))).to be(false)
    expect(install.removed_context).to be(true)
    expect(File.read(File.join(@root, ".mcp.json"))).to include("rails-ai-context")
  end

  it "names a context file whose markers do not pair up on a switch to MCP only, and leaves it as it is" do
    rails_app(@root)
    unpaired = "#{marked_block}<!-- BEGIN rails-ai-context -->\nmine\n"
    write("CLAUDE.md", unpaired)

    install = run(answers(tools: %i[claude], setup: described_class.setup_for(:mcp_only), prune: true))

    expect(File.read(File.join(@root, "CLAUDE.md"))).to eq(unpaired)
    expect(events).to include([ :say, :plain, "  CLAUDE.md" ])
    expect(events).to include([ :say, :warn, "Could not remove the generated section from CLAUDE.md " \
                                             "(#{RailsAiContext::ManagedBlock::UNPAIRED})" ])
    expect(install.removed_context).to be(true)
  end

  # A selection read through a record that will not read is every tool, and
  # each file written for it would be one the user never picked.
  [ [ "invalid YAML", "ai_tools: [claude\ntool_mode: mcp\n", /invalid YAML at line/ ],
    [ "a list", "- claude\n", /holds no `key: value` settings/ ] ].each do |shape, record, reason|
    it "stops before it asks or writes anything when the record is #{shape}, and names it" do
      rails_app(@root)
      write(".rails-ai-context.yml", record)
      write(".cursorrules", marked_block)
      write(".gitignore", "*.log\n")
      before = Dir.glob("**/*", File::FNM_DOTMATCH, base: @root).sort.to_h { |name| [ name, File.file?(File.join(@root, name)) && File.binread(File.join(@root, name)) ] }

      expect { run(answers(tools: %i[claude], prune: true)) }
        .to raise_error(described_class::RecordRefused, /\A\.rails-ai-context\.yml cannot be read \(.*#{reason.source}.*\), so nothing was changed/)

      expect(events).to eq([])
      after = Dir.glob("**/*", File::FNM_DOTMATCH, base: @root).sort.to_h { |name| [ name, File.file?(File.join(@root, name)) && File.binread(File.join(@root, name)) ] }
      expect(after).to eq(before)
    end
  end

  # A record that will not read is found before any question, since the
  # answers default from it.
  {
    "a link that leads nowhere" => [
      ->(path) { File.delete(path) && File.symlink(File.join(File.dirname(path), "gone.yml"), path) },
      "cannot be read (it is a symlink or behind one, which this run does not follow: it leads nowhere)"
    ],
    "a link to itself" => [
      ->(path) { File.delete(path) && File.symlink(path, path) },
      "cannot be read (it is a symlink or behind one, which this run does not follow: too many levels of symbolic links)"
    ],
    "a folder" => [ ->(path) { File.delete(path) && Dir.mkdir(path) }, "cannot be read (is a directory)" ]
  }.each do |shape, (make, reason)|
    it "stops before it asks or writes anything when the record is #{shape}, and says why in plain words" do
      skip "links need privileges on Windows" if Gem.win_platform? && shape.include?("link")
      rails_app(@root)
      make.call(write(".rails-ai-context.yml", "ai_tools:\n- cursor\n"))

      expect { run(answers(tools: %i[claude])) }
        .to raise_error(described_class::RecordRefused, ".rails-ai-context.yml #{reason}, so nothing was changed. " \
                                                     "Fix it, or move it aside, and run this again.")
      expect(events).to eq([])
      expect(Dir.children(@root).sort).to eq(%w[.rails-ai-context.yml Gemfile Gemfile.lock config])
    end
  end

  # The files would be written for the new selection and the record would
  # still name the old one, so the next run disagrees with them. A record
  # the answers leave as it is takes no write, so nothing refuses it.
  {
    "read-only" => [ ->(path) { File.chmod(0o444, path) }, "cannot be written (its permissions do not allow it)" ],
    "a link out of the app" => [
      lambda { |path|
        outside = File.join(Dir.mktmpdir, "record.yml")
        File.write(outside, File.read(path))
        File.delete(path)
        File.symlink(outside, path)
      },
      "cannot be written (it is a symlink or behind one, which this run does not follow: it leads out of the app)"
    ],
    "in a folder this run cannot write" => [ ->(path) { File.chmod(0o555, File.dirname(path)) }, "cannot be written (its permissions do not allow it)" ]
  }.each do |shape, (make, reason)|
    context "when the record is #{shape}" do
      before do
        skip "links need privileges on Windows" if Gem.win_platform? && shape.include?("link")
        rails_app(@root)
        write(".cursorrules", marked_block)
        @path = write(".rails-ai-context.yml", "ai_tools:\n- cursor\ntool_mode: mcp\ncontext_files: true\n")
        make.call(@path)
        skip "this user writes read-only files" if shape != "a link out of the app" && File.writable?(@path) && File.writable?(@root)
      end

      after do
        File.chmod(0o755, @root)
        File.chmod(0o644, @path) if @path && File.file?(@path)
      end

      it "stops before any step or removal when the answers change it, and says why in plain words" do
        expect { run(answers(tools: %i[claude], prune: true)) }
          .to raise_error(described_class::RecordRefused, ".rails-ai-context.yml #{reason}, so nothing was changed. " \
                                                       "Fix it, or move it aside, and run this again.")
        expect(events.select { |event| event.first == :step }).to eq([])
        expect(Dir.children(@root).sort).to eq(%w[.cursorrules .rails-ai-context.yml Gemfile Gemfile.lock config])
        expect(File.read(File.join(@root, ".cursorrules"))).to eq(marked_block)
        expect(File.read(@path)).to eq("ai_tools:\n- cursor\ntool_mode: mcp\ncontext_files: true\n")
      end

      # In a folder it cannot write, every other file of the run would fail too.
      next if shape == "in a folder this run cannot write"

      it "goes through when the answers leave it as it is, and writes nothing to it" do
        install = run(answers(tools: %i[cursor], setup: described_class.setup_for(:mcp)))

        expect(install.tools).to eq(%i[cursor])
        expect(events.select { |event| event.first == :step }.map(&:last)).to eq(%i[boot record hook context])
        expect(File.read(@path)).to eq("ai_tools:\n- cursor\ntool_mode: mcp\ncontext_files: true\n")
      end
    end
  end

  it "stops before any step when there is no record and its folder cannot take one" do
    rails_app(@root)
    File.chmod(0o555, @root)
    skip "this user writes read-only folders" if File.writable?(@root)

    expect { run(answers(tools: %i[claude])) }
      .to raise_error(described_class::RecordRefused, /\A\.rails-ai-context\.yml cannot be written \(its permissions do not allow it\)/)
    expect(events.select { |event| event.first == :step }).to eq([])
  ensure
    File.chmod(0o755, @root)
  end

  # The initializer wins on read, so a selection the YAML took and it did not would not be the one in force.
  context "when the initializer is read-only and sets the selection" do
    let(:initializer_text) do
      "RailsAiContext.configure do |config|\n  config.ai_tools = %i[claude]\n  config.tool_mode = :mcp\nend\n"
    end

    before do
      rails_app(@root)
      @initializer = write("config/initializers/rails_ai_context.rb", initializer_text)
      File.chmod(0o444, @initializer)
      skip "this user writes read-only files" if File.writable?(@initializer)
    end

    after { File.chmod(0o644, @initializer) }

    it "stops before any step when the answers change a line it holds, and names it" do
      expect { run(answers(tools: %i[cursor], setup: described_class.setup_for(:mcp_only))) }
        .to raise_error(described_class::RecordRefused,
                        "config/initializers/rails_ai_context.rb cannot be written (its permissions do not allow it), and the " \
                        "selection it holds takes precedence, so nothing was changed. Fix it, or move it aside, and run this again.")
      expect(events.select { |event| event.first == :step }).to eq([])
      expect(Dir.children(@root).sort).to eq(%w[Gemfile Gemfile.lock config])
    end

    it "goes through when the answers leave its lines as they are, a key it has no line for included" do
      install = run(answers(tools: %i[claude], setup: described_class.setup_for(:mcp)))

      expect(install.tools).to eq(%i[claude])
      expect(File.read(@initializer)).to eq(initializer_text)
    end
  end

  it "writes no MCP config when the selection is empty" do
    rails_app(@root)

    install = run(answers(tools: []))

    expect(install.tools).to eq([])
    expect(Dir.children(@root).sort).to eq(%w[.rails-ai-context.yml Gemfile Gemfile.lock config])
    expect(events.select { |event| event.first == :say }.map(&:last)).not_to include(a_string_matching(/Created\/Updated/))
  end

  describe ".run_workspace" do
    def run_workspace(given = answers)
      described_class.run_workspace(given, surface: surface, root: @root, roots: %w[a b].map { |app| File.join(@root, app) }) do |step, install, app|
        events << [ :step, step, app&.path ]
        next unless step == :record

        RailsAiContext::Install::SelectionRecord.write(install.tools, root: app.root, initializer: false,
                                                                      extra_yaml: { "tool_mode" => install.setup.tool_mode.to_s,
                                                                                    "context_files" => install.setup.context_files })
      end
    end

    before do
      rails_app(File.join(@root, "a"))
      rails_app(File.join(@root, "b"))
    end

    it "records each app and marks its .gitignore, then writes one server per app in the folder's config, then the context" do
      write(".gitignore", "*.log\n", root: File.join(@root, "b"))

      install = run_workspace(answers(tools: %i[claude]))

      expect(File.read(File.join(@root, "b", ".gitignore"))).to include(".ai-context.json")
      expect(events).to include([ :say, :ok, "Updated b/.gitignore" ])

      expect(events.select { |event| event.first == :step }.map { |event| event.drop(1) })
        .to eq([ [ :record, "a" ], [ :record, "b" ], [ :context, nil ] ])
      expect(JSON.parse(File.read(File.join(@root, ".mcp.json")))["mcpServers"].keys).to eq(%w[rails-ai-context-a rails-ai-context-b])
      expect(install.apps.map(&:path)).to eq(%w[a b])
      expect(install.configured.map(&:path)).to eq(%w[a b])
    end

    it "removes each app's legacy files under prune with the other removals, before any app is recorded" do
      write(".claude/rules/rails-ui-patterns.md", "# stale", root: File.join(@root, "b"))

      run_workspace(answers(tools: %i[claude], prune: true))

      expect(File.exist?(File.join(@root, "b", ".claude/rules/rails-ui-patterns.md"))).to be(false)
      expect(position { |event| event[2] == "  Removed b/.claude/rules/rails-ui-patterns.md" })
        .to be < position { |event| event.first == :step && event[1] == :record }
    end

    it "refuses to guess a setup when the apps recorded different ones and nothing was asked, and changes nothing" do
      write(".rails-ai-context.yml", "ai_tools:\n- claude\ntool_mode: cli\n", root: File.join(@root, "a"))
      write(".rails-ai-context.yml", "ai_tools:\n- claude\ntool_mode: mcp\ncontext_files: false\n", root: File.join(@root, "b"))

      expect { run_workspace }.to raise_error(ArgumentError, /recorded different setups .*--mcp, --cli or --mcp-only/)
      expect(File.exist?(File.join(@root, ".mcp.json"))).to be(false)

      run_workspace(answers(setup: described_class.setup_for(:cli)))
      expect(File.read(File.join(@root, "a", ".rails-ai-context.yml"))).to include("tool_mode: cli")
    end

    it "stops before it asks or writes anything when one app's record will not read, naming it from the folder" do
      write(".rails-ai-context.yml", "ai_tools: [claude\n", root: File.join(@root, "b"))

      expect { run_workspace(answers(tools: %i[claude])) }
        .to raise_error(described_class::RecordRefused, %r{\Ab/\.rails-ai-context\.yml cannot be read})

      expect(events).to eq([])
      expect(File.exist?(File.join(@root, "a", ".rails-ai-context.yml"))).to be(false)
      expect(File.exist?(File.join(@root, ".mcp.json"))).to be(false)
    end

    it "stops before it writes anything when one app's record cannot take the answers, naming it from the folder" do
      path = write(".rails-ai-context.yml", "ai_tools:\n- cursor\n", root: File.join(@root, "b"))
      File.chmod(0o444, path)
      skip "this user writes read-only files" if File.writable?(path)

      expect { run_workspace(answers(tools: %i[claude])) }
        .to raise_error(described_class::RecordRefused, %r{\Ab/\.rails-ai-context\.yml cannot be written \(its permissions do not allow it\)})
      expect(events.select { |event| event.first == :step }).to eq([])
      expect(File.exist?(File.join(@root, "a", ".rails-ai-context.yml"))).to be(false)
      expect(File.exist?(File.join(@root, ".mcp.json"))).to be(false)
    ensure
      File.chmod(0o644, path) if path
    end

    it "takes each app's generated context files out on a switch to MCP only under prune" do
      write("CLAUDE.md", marked_block, root: File.join(@root, "a"))
      write("CLAUDE.md", marked_block, root: File.join(@root, "b"))

      run_workspace(answers(tools: %i[claude], setup: described_class.setup_for(:mcp_only), prune: true))

      expect(File.exist?(File.join(@root, "a", "CLAUDE.md"))).to be(false)
      expect(File.exist?(File.join(@root, "b", "CLAUDE.md"))).to be(false)
    end

    it "removes the per-app servers an earlier init wrote beside the committed plugin's router under prune" do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("CLAUDE_CONFIG_DIR").and_return(File.join(@root, "never-ran"))
      write(".claude/settings.json", JSON.generate("enabledPlugins" => { "rails-ai-context@rails-ai-context" => true }))
      entry = ->(app) { { "command" => "rails-ai-context", "args" => [ "serve", "--app-path", app ] } }
      write(".mcp.json", JSON.generate("mcpServers" => { "rails-ai-context-a" => entry.("a"), "rails-ai-context-b" => entry.("b"),
                                                         "mine" => { "command" => "x" } }))

      run_workspace(answers(tools: %i[claude], prune: true))

      expect(JSON.parse(File.read(File.join(@root, ".mcp.json")))["mcpServers"].keys).to eq(%w[mine])
    end
  end
end
