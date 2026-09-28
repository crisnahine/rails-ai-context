# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe RailsAiContext::Serializers::CopilotSerializer do
  describe "compact mode" do
    before { RailsAiContext.configuration.context_mode = :compact }
    after { RailsAiContext.configuration.context_mode = :compact }

    it "generates compact output with MCP tool references" do
      context = {
        app_name: "App", rails_version: "8.0", ruby_version: "3.4",
        schema: { adapter: "postgresql", total_tables: 10 },
        models: { "User" => { associations: [ { type: "has_many", name: "posts" } ], validations: [] } },
        routes: { total_routes: 50, by_controller: { "users" => [] } },
        gems: {}, conventions: {}
      }

      output = described_class.new(context).call
      expect(output).to include("Copilot Context")
      expect(output).to include("MCP tools")
      expect(output).to include("rails_get_schema")
    end

    it "includes model associations" do
      context = {
        app_name: "App", rails_version: "8.0", ruby_version: "3.4",
        models: { "User" => { associations: [ { type: "has_many", name: "posts" } ] } },
        schema: {}, routes: {}, gems: {}, conventions: {}
      }

      output = described_class.new(context).call
      expect(output).to include("has_many :posts")
    end

    # An empty entry must survive as a blank line between sections.
    it "leaves a blank line between the title and the first section" do
      output = described_class.new(serializer_context).call

      expect(output).to start_with("# TestApp - Copilot Context\n\n> Rails")
      expect(output).to include("\n\n## Stack")
    end

    # A private API app measured 152 non-blank lines in the managed block
    # against a budget of 150: the BEGIN/END markers were added after the trim.
    # They are part of what the gem writes, so they come out of the budget.
    it "counts the markers, so the written block never exceeds the budget" do
      allow(RailsAiContext.configuration).to receive(:claude_max_lines).and_return(20)

      Dir.mktmpdir do |dir|
        path = File.join(dir, "CLAUDE.md")
        RailsAiContext::Serializers::SectionMarkerWriter.write_with_markers(
          path, described_class.new(serializer_context).call
        )

        block = File.read(path).lines
        expect(block.first).to start_with("<!-- BEGIN rails-ai-context -->")
        expect(block.grep_v(/\A\s*\z/).size).to be <= 20
      end
    end

    it "caps the file at the configured compact line budget" do
      allow(RailsAiContext.configuration).to receive(:claude_max_lines).and_return(20)

      output = described_class.new(serializer_context).call

      # Two lines under the budget: the writer's BEGIN/END markers spend them,
      # and a heading the cut left bare goes with its body, which can land the
      # output one line lower again.
      expect(output.lines.grep_v(/\A\s*\z/).size).to be_between(17, 18)
      expect(output).to end_with("_Context trimmed. Use MCP tools for full details._")
    end
  end

  describe "test command" do
    before { RailsAiContext.configuration.context_mode = :compact }
    after  { RailsAiContext.configuration.context_mode = :compact }

    let(:base_context) do
      {
        app_name: "App", rails_version: "8.0", ruby_version: "3.4",
        schema: {}, models: {}, routes: {}, gems: {}, conventions: {}
      }
    end

    it "uses rails test for minitest projects" do
      output = described_class.new(base_context.merge(tests: { framework: "minitest" })).call
      expect(output).to include("rails test")
      expect(output).not_to include("bundle exec rspec")
    end

    it "uses bundle exec rspec for rspec projects" do
      output = described_class.new(base_context.merge(tests: { framework: "rspec" })).call
      expect(output).to include("bundle exec rspec")
      expect(output).not_to include("rails test")
    end

    it "defaults to rails test when framework is unknown" do
      output = described_class.new(base_context).call
      expect(output).to include("rails test")
    end
  end

  describe "full mode" do
    before { RailsAiContext.configuration.context_mode = :full }
    after { RailsAiContext.configuration.context_mode = :compact }

    it "delegates to FullCopilotSerializer (MarkdownSerializer)" do
      context = {
        app_name: "App", rails_version: "8.0", ruby_version: "3.4",
        generated_at: Time.now.iso8601
      }
      output = described_class.new(context).call
      expect(output).to be_a(String)
      expect(output).to include("Copilot Instructions")
    end

    # The tier note sits on its own line and every sibling header follows it
    # with the prose directly. Copilot's kept a blank line there too, so the
    # rendered header carried two.
    it "leaves one blank line between the header block and the prose" do
      context = {
        app_name: "App", rails_version: "8.0", ruby_version: "3.4",
        generated_at: Time.now.iso8601
      }
      output = described_class.new(context).call

      expect(output).to include("v#{RailsAiContext::VERSION}\n\nUse this context")
    end
  end

  # The regenerate line at the foot of the file is read by whoever opens it;
  # a standalone install has no rake task to run.
  describe "the regenerate command in the footer" do
    around do |example|
      RailsAiContext.configuration.context_mode = :full
      example.run
    ensure
      RailsAiContext.configuration.context_mode = :compact
    end

    let(:minimal) do
      { app_name: "App", rails_version: "8.0", ruby_version: "3.4", schema: {}, models: {},
        routes: {}, gems: {}, conventions: {} }
    end

    it "names the binary in a standalone install" do
      allow(RailsAiContext::InstallMode).to receive(:standalone?).and_return(true)
      output = described_class.new(minimal).call

      expect(output).to include("Run `rails-ai-context context` to regenerate.")
      expect(output).not_to include("rails ai:context")
    end

    it "names the rake task where the app bundles the gem" do
      allow(RailsAiContext::InstallMode).to receive(:standalone?).and_return(false)

      expect(described_class.new(minimal).call).to include("Run `rails ai:context` to regenerate.")
    end
  end
end
