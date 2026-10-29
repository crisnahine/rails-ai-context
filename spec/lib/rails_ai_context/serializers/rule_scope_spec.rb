# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Serializers::RuleScope do
  let(:always) { described_class.always("Rails project context") }
  let(:models) { described_class.paths("app/models/**/*.rb", description: "ActiveRecord models") }
  let(:schema) { described_class.paths("db/schema.rb", "db/migrate/**", description: "Database tables") }
  let(:on_request) { described_class.on_request("Rails MCP tools reference") }

  def text(scope, tool, **options)
    scope.frontmatter(tool, **options).join("\n")
  end

  describe "Claude Code rules" do
    # A rule with no paths loads at launch; that is Claude Code's "always".
    it "writes nothing for always" do
      expect(always.frontmatter(:claude)).to eq([])
    end

    it "lists the paths" do
      expect(text(schema, :claude)).to eq(%(---\npaths:\n  - "db/schema.rb"\n  - "db/migrate/**"\n---\n))
    end

    it "refuses on request, which Claude Code rules cannot be" do
      expect { on_request.frontmatter(:claude) }.to raise_error(ArgumentError, /claude/)
    end
  end

  describe "Cursor rules" do
    it "applies always with a description" do
      expect(text(always, :cursor)).to eq(%(---\ndescription: "Rails project context"\nalwaysApply: true\n---\n))
    end

    it "attaches by globs" do
      expect(text(models, :cursor)).to eq(%(---\nglobs:\n  - "app/models/**/*.rb"\nalwaysApply: false\n---\n))
    end

    it "is picked by its description on request" do
      expect(text(on_request, :cursor)).to eq(%(---\ndescription: "Rails MCP tools reference"\nalwaysApply: false\n---\n))
    end
  end

  describe "Copilot instructions" do
    it "applies to every file for always" do
      expect(text(always, :copilot, name: "Rails Project Overview")).to eq(
        %(---\napplyTo: "**/*"\nname: "Rails Project Overview"\ndescription: "Rails project context"\n---\n)
      )
    end

    it "joins the paths into one applyTo" do
      expect(text(schema, :copilot, name: "Schema")).to eq(
        %(---\napplyTo: "db/schema.rb,db/migrate/**"\nname: "Schema"\ndescription: "Database tables"\n---\n)
      )
    end

    it "keeps code review out when asked" do
      expect(text(always, :copilot, name: "Tools", exclude_agent: "code-review")).to include(%(excludeAgent: "code-review"\n---))
    end

    it "refuses on request" do
      expect { on_request.frontmatter(:copilot, name: "x") }.to raise_error(ArgumentError, /copilot/)
    end
  end

  # OpenCode loads a nested AGENTS.md when the agent reads a file beside it:
  # the folder is the scope, so the file carries no frontmatter.
  describe "OpenCode nested AGENTS.md" do
    it "writes nothing" do
      expect(models.frontmatter(:opencode)).to eq([])
    end
  end

  it "quotes a description that holds a double quote" do
    scope = described_class.always(%(Rails "MCP" tools))
    expect(text(scope, :cursor)).to include(%(description: "Rails \\"MCP\\" tools"))
  end
end
