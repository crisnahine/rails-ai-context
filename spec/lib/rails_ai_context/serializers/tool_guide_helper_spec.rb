# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe RailsAiContext::Serializers::ToolGuideHelper do
  let(:test_class) do
    Class.new do
      include RailsAiContext::Serializers::ToolGuideHelper
      # Make private methods accessible for testing
      public :cli_cmd, :serve_cmd, :tool_call_inline, :install_form
    end
  end

  let(:helper) { test_class.new }

  before { RailsAiContext.configuration.tool_mode = :mcp }
  after  { RailsAiContext.configuration.tool_mode = :mcp }

  describe "#tool_call" do
    # The MCP client lists the tools; the intro names the command fallback once.
    it "renders the MCP call alone in :mcp mode" do
      result = helper.tool_call("rails_get_schema(table:\"users\")", "rails 'ai:tool[schema]' table=users")
      expect(result).to eq("→ `rails_get_schema(table:\"users\")`")
    end

    it "renders only CLI in :cli mode" do
      RailsAiContext.configuration.tool_mode = :cli
      result = helper.tool_call("rails_get_schema(table:\"users\")", "rails 'ai:tool[schema]' table=users")
      expect(result).to include("rails 'ai:tool[schema]'")
      expect(result).not_to include("MCP:")
    end

    # The configuration refuses an unknown mode, so this is a stand-in for a
    # caller that hands the helper one anyway.
    it "renders only MCP for unknown mode" do
      allow(helper).to receive(:tool_mode).and_return(:unknown)
      result = helper.tool_call("rails_get_schema(table:\"users\")", "rails 'ai:tool[schema]' table=users")
      expect(result).to include("rails_get_schema")
      expect(result).not_to include("CLI:")
    end
  end

  describe "#tool_mode" do
    it "returns the configured tool mode" do
      RailsAiContext.configuration.tool_mode = :cli
      expect(helper.tool_mode).to eq(:cli)
    end
  end

  describe "#tools_header" do
    it "includes the tool count and when to use them, plainly" do
      expect(helper.tools_header).to eq("## Tools (#{RailsAiContext::Server.exposed_tools.size}): use them before reading files")
    end
  end

  describe "#tools_intro" do
    it "mentions MCP tools in :mcp mode" do
      lines = helper.tools_intro
      expect(lines.join("\n")).to include("MCP tools")
    end

    it "mentions introspection tools in :cli mode" do
      RailsAiContext.configuration.tool_mode = :cli
      lines = helper.tools_intro
      expect(lines.join("\n")).to include("introspection tools")
      expect(lines.join("\n")).not_to include("MCP tools")
    end

    it "points at the rake task by default (in-Gemfile install)" do
      lines = helper.tools_intro
      expect(lines.join("\n")).to include("rails ai:serve")
    end

    context "standalone install (gem missing from Gemfile.lock)" do
      let(:tmpdir) { Dir.mktmpdir }

      before do
        File.write(File.join(tmpdir, "Gemfile.lock"), "GEM\n  remote: https://rubygems.org/\n  specs:\n    rails (7.1.0)\n")
        allow(Rails).to receive(:root).and_return(Pathname.new(tmpdir))
      end

      after { FileUtils.remove_entry(tmpdir) }

      it "points at the rails-ai-context CLI binary instead of the rake task" do
        lines = helper.tools_intro
        expect(lines.join("\n")).to include("rails-ai-context serve")
        expect(lines.join("\n")).not_to include("rails ai:serve")
      end
    end
  end

  describe "a custom tool in a built-in's place" do
    let(:custom) do
      Class.new(MCP::Tool) do
        tool_name "rails_get_schema"
        description "The app's own schema tool."
      end
    end

    before { allow(helper).to receive(:exposed_tools).and_return([ custom, RailsAiContext::Tools::GetModelDetails ]) }

    it "is listed, and no step or rule gives it the built-in's arguments" do
      expect(helper.tools_name_list.join("\n")).to include("`rails_get_schema`")
      expect(helper.served?("rails_get_schema")).to be(false)
      expect(helper.served?("rails_get_model_details")).to be(true)
      expect(helper.tools_rules_section.join("\n")).to include("`rails_get_model_details(model:\"X\")`")
      expect(helper.tools_rules_section.join("\n")).not_to include("rails_get_schema")
    end
  end

  describe "#tools_name_list" do
    it "returns a compact list of all tool names" do
      lines = helper.tools_name_list
      text = lines.join("\n")
      expect(text).to include("rails_get_context")
      expect(text).to include("rails_diagnose")
      expect(text).to include("rails_session_context")
    end

    it "includes a count header" do
      lines = helper.tools_name_list
      expect(lines.first).to match(/All \d+ tools/)
    end
  end

  describe "#tools_anti_hallucination_section" do
    it "renders the 6-rule protocol when enabled (default)" do
      lines = helper.tools_anti_hallucination_section
      text = lines.join("\n")
      expect(text).to include("Anti-Hallucination Protocol")
      expect(text).to include("Verify before you write")
      expect(text).to include("Mark every assumption")
      expect(text).to include("Training data describes average Rails")
      expect(text).to include("Check the inheritance chain")
      expect(text).to include("Empty tool output is information")
      expect(text).to include("Stale context lies")
    end

    it "sends the stack check to the conventions and gems config sections the app serves" do
      text = helper.tools_anti_hallucination_section.join("\n")
      expect(text).to include('Check `rails_get_config(section:"conventions")` and `rails_get_config(section:"gems")` before')

      saved = RailsAiContext.configuration.skip_tools
      RailsAiContext.configuration.skip_tools = %w[rails_get_conventions]
      expect(test_class.new.tools_anti_hallucination_section.join("\n")).to include('Check `rails_get_config(section:"gems")` before')
    ensure
      RailsAiContext.configuration.skip_tools = saved
    end

    it "returns empty array when anti_hallucination_rules is false" do
      original = RailsAiContext.configuration.anti_hallucination_rules
      RailsAiContext.configuration.anti_hallucination_rules = false
      expect(helper.tools_anti_hallucination_section).to eq([])
    ensure
      RailsAiContext.configuration.anti_hallucination_rules = original
    end
  end

  describe "#render_tools_guide_compact" do
    it "assembles a compact guide without the full table" do
      lines = helper.render_tools_guide_compact
      text = lines.join("\n")
      expect(text).to include("Tools (#{RailsAiContext::Server::TOOLS.size})")
      expect(text).to include("power tool")
      # An MCP client lists the tools itself.
      expect(text).not_to include("All #{RailsAiContext::Server::TOOLS.size} tools")
      expect(text).not_to include("| MCP |")
      expect(text).not_to include("| CLI |")
    end

    it "includes the anti-hallucination protocol by default" do
      text = helper.render_tools_guide_compact.join("\n")
      expect(text).to include("Anti-Hallucination Protocol")
    end

    it "omits the protocol when anti_hallucination_rules is false" do
      original = RailsAiContext.configuration.anti_hallucination_rules
      RailsAiContext.configuration.anti_hallucination_rules = false
      text = helper.render_tools_guide_compact.join("\n")
      expect(text).not_to include("Anti-Hallucination Protocol")
    ensure
      RailsAiContext.configuration.anti_hallucination_rules = original
    end
  end

  describe "#api_only?" do
    it "is false when the includer has no context to inspect" do
      expect(helper.api_only?).to be false
    end

    context "with a context-aware includer" do
      let(:context_class) do
        Class.new do
          include RailsAiContext::Serializers::ToolGuideHelper
          attr_accessor :context

          def initialize(context)
            @context = context
          end
        end
      end

      it "is true when context[:api][:api_only] is true" do
        instance = context_class.new(api: { api_only: true })
        expect(instance.api_only?).to be true
      end

      it "is true when conventions architecture includes api_only" do
        instance = context_class.new(conventions: { architecture: %w[api_only] })
        expect(instance.api_only?).to be true
      end

      it "is false for a regular Hotwire app" do
        instance = context_class.new(api: { api_only: false }, conventions: { architecture: %w[hotwire] })
        expect(instance.api_only?).to be false
      end

      # A failed section carries no architecture, whatever else is in it.
      it "is false when the conventions section failed" do
        instance = context_class.new(conventions: { error: "boom", architecture: %w[api_only] })
        expect(instance.api_only?).to be false
      end
    end
  end

  describe "#tools_workflow_section" do
    let(:context_class) do
      Class.new do
        include RailsAiContext::Serializers::ToolGuideHelper
        attr_accessor :context

        def initialize(context)
          @context = context
        end
      end
    end

    it "includes the view-editing workflow for a regular app" do
      instance = context_class.new(conventions: { architecture: %w[hotwire] })
      text = instance.tools_workflow_section.join("\n")
      expect(text).to include("Build or modify a view")
      expect(text).not_to include("Modify a JSON endpoint")
    end

    it "swaps in the JSON-endpoint workflow for an API-only app" do
      instance = context_class.new(api: { api_only: true })
      text = instance.tools_workflow_section.join("\n")
      expect(text).to include("Modify a JSON endpoint")
      expect(text).not_to include("Build or modify a view")
    end
  end

  describe "#cli_cmd" do
    it "generates zsh-safe rake command without params" do
      expect(helper.cli_cmd("schema")).to eq("rails 'ai:tool[schema]'")
    end

    it "generates zsh-safe rake command with params" do
      expect(helper.cli_cmd("schema", "table=users")).to eq("rails 'ai:tool[schema]' table=users")
    end

    context "when the gem is not in the app's Gemfile.lock (standalone install)" do
      let(:tmpdir) { Dir.mktmpdir }

      before do
        File.write(File.join(tmpdir, "Gemfile.lock"), <<~LOCK)
          GEM
            remote: https://rubygems.org/
            specs:
              rails (7.1.0)

          DEPENDENCIES
            rails
        LOCK
        allow(Rails).to receive(:root).and_return(Pathname.new(tmpdir))
      end

      after { FileUtils.remove_entry(tmpdir) }

      it "generates the CLI binary form instead of the rake form" do
        expect(helper.cli_cmd("schema", "table=users")).to eq("rails-ai-context tool schema table=users")
      end
    end

    context "when the gem is in the app's Gemfile.lock (in-Gemfile install)" do
      let(:tmpdir) { Dir.mktmpdir }

      before do
        File.write(File.join(tmpdir, "Gemfile.lock"), <<~LOCK)
          GEM
            remote: https://rubygems.org/
            specs:
              rails (7.1.0)
              rails-ai-context (5.13.0)

          DEPENDENCIES
            rails
            rails-ai-context
        LOCK
        allow(Rails).to receive(:root).and_return(Pathname.new(tmpdir))
      end

      after { FileUtils.remove_entry(tmpdir) }

      it "keeps generating the rake form" do
        expect(helper.cli_cmd("schema", "table=users")).to eq("rails 'ai:tool[schema]' table=users")
      end
    end
  end

  describe "#install_form" do
    let(:tmpdir) { Dir.mktmpdir }
    let(:bundled) { "GEM\n  remote: https://rubygems.org/\n  specs:\n    rails-ai-context (5.13.0)\n" }

    before { allow(Rails).to receive(:root).and_return(Pathname.new(tmpdir)) }
    after  { FileUtils.remove_entry(tmpdir) }

    it "is the rake tasks when the Gemfile.lock lists rails-ai-context" do
      File.write(File.join(tmpdir, "Gemfile.lock"), bundled)
      expect(helper.install_form).to eq(:tasks)
    end

    it "is standalone when the Gemfile.lock does not list rails-ai-context" do
      File.write(File.join(tmpdir, "Gemfile.lock"), "GEM\n  remote: https://rubygems.org/\n  specs:\n    rails (7.1.0)\n")
      expect(helper.install_form).to eq(:standalone)
      expect(helper.cli_cmd("schema")).to eq("rails-ai-context tool schema")
    end

    it "defaults to the rake tasks (in-Gemfile) when there is no Gemfile.lock and the Gemfile cannot be read in full" do
      File.write(File.join(tmpdir, "Gemfile"), "gemspec\n")
      expect(helper.install_form).to eq(:tasks)
    end

    # A mountable engine's root: the rake tasks run in its dummy app as
    # app:ai:*, so `rails 'ai:tool[...]'` and `rails ai:serve` do not exist there.
    it "is the binary in the bundle at a gem's root, which has no app of its own" do
      File.write(File.join(tmpdir, "Gemfile.lock"), bundled)
      File.write(File.join(tmpdir, "shelf.gemspec"), "")
      expect(helper.install_form).to eq(:bundled)
      expect(helper.cli_cmd("schema", "table=users")).to eq("bundle exec rails-ai-context tool schema table=users")
      expect(helper.serve_cmd).to eq("bundle exec rails-ai-context serve")
    end

    it "is the rake tasks for an app that also ships a gemspec" do
      File.write(File.join(tmpdir, "Gemfile.lock"), bundled)
      File.write(File.join(tmpdir, "shop.gemspec"), "")
      FileUtils.mkdir_p(File.join(tmpdir, "config"))
      File.write(File.join(tmpdir, "config/application.rb"), "")
      expect(helper.install_form).to eq(:tasks)
    end

    it "memoizes the result for the lifetime of the instance" do
      File.write(File.join(tmpdir, "Gemfile.lock"), "GEM\n  remote: https://rubygems.org/\n  specs:\n    rails (7.1.0)\n")
      expect(helper.install_form).to eq(:standalone)

      File.write(File.join(tmpdir, "Gemfile.lock"), bundled)
      expect(helper.install_form).to eq(:standalone), "expected the memoized value to stick within one instance"
    end
  end

  describe "#tool_call_inline" do
    it "returns the MCP call alone in :mcp mode" do
      result = helper.tool_call_inline("rails_get_context", "model:\"Post\"", "context", "model=Post")
      expect(result).to eq("`rails_get_context(model:\"Post\")`")
    end

    it "returns only CLI in :cli mode" do
      RailsAiContext.configuration.tool_mode = :cli
      result = helper.tool_call_inline("rails_get_context", "model:\"Post\"", "context", "model=Post")
      expect(result).to include("rails 'ai:tool[context]'")
      expect(result).not_to include("rails_get_context(model:")
    end
  end
end
