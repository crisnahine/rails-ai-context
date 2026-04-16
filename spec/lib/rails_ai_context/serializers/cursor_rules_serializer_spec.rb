# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Serializers::CursorRulesSerializer do
  let(:context) do
    {
      app_name: "App", rails_version: "8.0", ruby_version: "3.4",
      schema: { adapter: "postgresql", total_tables: 10 },
      models: { "User" => { associations: [], validations: [], table_name: "users" } },
      routes: { total_routes: 50 },
      gems: {},
      conventions: {},
      controllers: { controllers: { "UsersController" => { actions: %w[index show] } } }
    }
  end

  it "generates .cursor/rules/*.mdc files with YAML frontmatter" do
    Dir.mktmpdir do |dir|
      result = described_class.new(context).call(dir)
      expect(result[:written]).not_to be_empty

      project_rule = File.read(File.join(dir, ".cursor", "rules", "rails-project.mdc"))
      expect(project_rule).to start_with("---")
      expect(project_rule).to include("alwaysApply: true")
      expect(project_rule).to include("MCP tools")
    end
  end

  it "generates models rule with glob" do
    Dir.mktmpdir do |dir|
      described_class.new(context).call(dir)

      models_rule = File.read(File.join(dir, ".cursor", "rules", "rails-models.mdc"))
      expect(models_rule).to include("app/models/**/*.rb")
      expect(models_rule).to include("alwaysApply: false")
      expect(models_rule).to include("User")
    end
  end

  it "generates controllers rule with glob" do
    Dir.mktmpdir do |dir|
      described_class.new(context).call(dir)

      ctrl_rule = File.read(File.join(dir, ".cursor", "rules", "rails-controllers.mdc"))
      expect(ctrl_rule).to include("app/controllers/**/*.rb")
      expect(ctrl_rule).to include("UsersController")
    end
  end

  it "skips models rule when no models" do
    context[:models] = {}
    Dir.mktmpdir do |dir|
      result = described_class.new(context).call(dir)
      expect(result[:written].any? { |f| f.include?("rails-models.mdc") }).to be false
    end
  end

  it "skips controllers rule when no controllers" do
    context[:controllers] = { controllers: {} }
    Dir.mktmpdir do |dir|
      result = described_class.new(context).call(dir)
      expect(result[:written].any? { |f| f.include?("rails-controllers.mdc") }).to be false
    end
  end

  it "generates MCP tools rule as agent-requested (alwaysApply false)" do
    Dir.mktmpdir do |dir|
      described_class.new(context).call(dir)

      tools_rule = File.read(File.join(dir, ".cursor", "rules", "rails-mcp-tools.mdc"))
      expect(tools_rule).to include("alwaysApply: false")
      expect(tools_rule).to include("Tools (#{RailsAiContext::Server::TOOLS.size})")
      expect(tools_rule).to include("rails_get_schema")
      expect(tools_rule).to include("Step-by-step workflows")
    end
  end

  it "skips unchanged files" do
    Dir.mktmpdir do |dir|
      first = described_class.new(context).call(dir)
      second = described_class.new(context).call(dir)
      expect(second[:written]).to be_empty
      expect(second[:skipped].size).to eq(first[:written].size)
    end
  end

  # v5.9.0 regression: real user report during release QA — Cursor chat
  # agent didn't detect rules written only as .cursor/rules/*.mdc. Writing
  # .cursorrules alongside (legacy format) fixed it. Ensure both are
  # produced so neither older Cursor builds nor newer ones miss the rules.
  it "also writes a legacy .cursorrules at the project root" do
    Dir.mktmpdir do |dir|
      result = described_class.new(context).call(dir)
      cursorrules_path = File.join(dir, ".cursorrules")
      expect(result[:written]).to include(cursorrules_path)
      expect(File.exist?(cursorrules_path)).to be true

      content = File.read(cursorrules_path)
      # Plain text / markdown — no YAML frontmatter — so every Cursor
      # build reads it verbatim.
      expect(content).not_to start_with("---")
      # Must surface the gem's presence + name a couple of the MCP tools
      # so the chat agent knows to use them rather than guess.
      expect(content).to include("rails-ai-context")
      expect(content).to include("rails_get_schema")
      expect(content).to include("rails_get_routes")
      expect(content).to include("App")  # app name from context
    end
  end

  # .cursorrules and CLAUDE.md share render_compact_rules from
  # CompactSerializerHelper. They target different AI clients but
  # deliver the same project context — so when one changes, the other
  # changes in lockstep. Ship-time invariant: identical core content
  # between the two files.
  it ".cursorrules mirrors the CLAUDE.md compact-rules pipeline (shared content)" do
    Dir.mktmpdir do |dir|
      described_class.new(context).call(dir)
      cursor_content = File.read(File.join(dir, ".cursorrules"))
      claude_content = RailsAiContext::Serializers::ClaudeSerializer.new(context).call

      # Every major section of CLAUDE.md also appears in .cursorrules,
      # guaranteeing parity across both AI-client targets. Drift between
      # them is the class of bug that leaves one agent with stale rules.
      %w[## Stack ## Key\ models ## Rules ## Architecture].each do |section|
        next unless claude_content.include?(section)
        expect(cursor_content).to include(section),
          ".cursorrules missing section '#{section}' that CLAUDE.md has — shared pipeline drift"
      end
    end
  end

  # Real user concern: pre-existing .cursorrules content must not be
  # destroyed on first install. The gem now wraps its block in
  # `<!-- BEGIN/END rails-ai-context -->` markers (same convention as
  # CLAUDE.md / AGENTS.md / .github/copilot-instructions.md) so user-
  # added content above or below the gem block survives regeneration.
  describe ".cursorrules section markers" do
    it "wraps generated content in BEGIN/END markers so user content is preserved" do
      Dir.mktmpdir do |dir|
        described_class.new(context).call(dir)
        content = File.read(File.join(dir, ".cursorrules"))
        expect(content).to include("<!-- BEGIN rails-ai-context -->")
        expect(content).to include("<!-- END rails-ai-context -->")
      end
    end

    it "preserves user content above the marker block on first install" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, ".cursorrules")
        user_content = "# My hand-written rules\n- Always use 2-space indent\n- Prefer guard clauses\n"
        File.write(path, user_content)

        described_class.new(context).call(dir)

        new_content = File.read(path)
        expect(new_content).to include(user_content),
          "user-written .cursorrules content was destroyed by the install"
        expect(new_content).to include("<!-- BEGIN rails-ai-context -->")
      end
    end

    it "preserves user content above and below the markers on regeneration" do
      Dir.mktmpdir do |dir|
        # First write — gem creates the marker block.
        described_class.new(context).call(dir)
        path = File.join(dir, ".cursorrules")

        # User adds content above and below the gem block.
        gem_block = File.read(path)
        File.write(path, "# Above the gem\n#{gem_block}\n# Below the gem\n")

        # Regenerate — gem must replace ONLY its own block.
        described_class.new(context).call(dir)

        final = File.read(path)
        expect(final).to include("# Above the gem")
        expect(final).to include("# Below the gem")
        expect(final).to include("<!-- BEGIN rails-ai-context -->")
        expect(final).to include("<!-- END rails-ai-context -->")
        # Marker block appears exactly once.
        expect(final.scan("<!-- BEGIN rails-ai-context -->").size).to eq(1)
      end
    end
  end
end
