# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Presets do
  describe "DEFINITIONS" do
    it "defines the architecture, debugging, and migration presets" do
      expect(described_class::DEFINITIONS.keys).to contain_exactly("architecture", "debugging", "migration")
    end

    it "gives every preset a description and a non-empty tool list" do
      described_class::DEFINITIONS.each_value do |preset|
        expect(preset[:desc]).to be_a(String)
        expect(preset[:desc]).not_to be_empty
        expect(preset[:tools]).to be_an(Array)
        expect(preset[:tools]).not_to be_empty
      end
    end

    it "only references tools that resolve to a real registered tool (same lookup the rake task and CLI use)" do
      described_class::DEFINITIONS.each do |preset_name, preset|
        preset[:tools].each do |tool_spec|
          expect { RailsAiContext::CLI::ToolRunner.new(tool_spec[:name], tool_spec[:params]) }
            .not_to raise_error, "#{preset_name} preset references unknown tool '#{tool_spec[:name]}'"
        end
      end
    end

    it "excludes tools that require a caller-supplied target and would only emit a not-provided error with no params" do
      argument_hungry_tools = %w[migration_advisor validate analyze_feature]

      described_class::DEFINITIONS.each_value do |preset|
        tool_names = preset[:tools].map { |t| t[:name] }
        expect(tool_names & argument_hungry_tools).to be_empty
      end
    end
  end

  describe ".run" do
    it "runs every tool in the preset, framing on err and tool output on out" do
      out = StringIO.new
      err = StringIO.new
      expect(described_class.run("migration", out: out, err: err)).to be true

      expect(err.string).to include("Preset: migration")
      expect(err.string.scan(/^Running: /).size).to eq(3)
      expect(out.string).not_to be_empty
    end

    it "answers false for a name that matches no preset and prints nothing" do
      out = StringIO.new
      err = StringIO.new
      expect(described_class.run("nope", out: out, err: err)).to be false
      expect(out.string).to be_empty
    end

    it "keeps going when one tool raises" do
      allow(RailsAiContext::CLI::ToolRunner).to receive(:new).and_wrap_original do |m, name, params, **kw|
        raise "boom" if name == "runtime_info"
        m.call(name, params, **kw)
      end
      err = StringIO.new
      described_class.run("migration", out: StringIO.new, err: err)
      expect(err.string).to include("[error] runtime_info: boom")
    end

    it "answers false when every tool raised, so the preset produced nothing" do
      allow(RailsAiContext::CLI::ToolRunner).to receive(:new).and_raise("boom")
      err = StringIO.new

      expect(described_class.run("migration", out: StringIO.new, err: err)).to be false
      expect(err.string.scan(/\[error\]/).size).to eq(3)
    end
  end

  # The exit status both surfaces answer with is one rule; each spelling its
  # own list is how they drift.
  describe ".ok?" do
    it "answers whether an outcome is a success" do
      expect(described_class.ok?(:listed)).to be true
      expect(described_class.ok?(:ran)).to be true
      expect(described_class.ok?(:unknown)).to be false
      expect(described_class.ok?(:failed)).to be false
    end

    it "is what the CLI and the rake task read, rather than a list of their own" do
      root = File.expand_path("../../..", __dir__)
      [ "exe/rails-ai-context", "lib/rails_ai_context/tasks/rails_ai_context.rake" ].each do |relative|
        source = File.read(File.join(root, relative))
        expect(source).to include("Presets.ok?(outcome)"), relative
        expect(source).not_to include("%i[listed ran]"), relative
      end
    end
  end

  describe ".resolve" do
    it "answers the definition key for a name in any case or spacing" do
      expect(described_class.resolve("Migration ")).to eq("migration")
      expect(described_class.resolve("migration")).to eq("migration")
    end

    it "answers nil for a name no preset carries" do
      expect(described_class.resolve("nope")).to be_nil
      expect(described_class.resolve(nil)).to be_nil
    end
  end

  describe ".dispatch" do
    let(:invocation) { ->(key) { "rails-ai-context preset #{key}" } }

    it "puts the listing on out and answers :listed for a bare invocation" do
      out = StringIO.new
      err = StringIO.new

      expect(described_class.dispatch(nil, invocation: invocation, out: out, err: err)).to eq(:listed)
      expect(out.string).to include("Available presets:")
      expect(out.string).to include("rails-ai-context preset architecture")
      expect(err.string).to be_empty
    end

    it "frames a rejected name and its listing on err, echoing what was typed" do
      out = StringIO.new
      err = StringIO.new

      expect(described_class.dispatch("BOGUS", invocation: invocation, out: out, err: err)).to eq(:unknown)
      expect(err.string).to start_with("Unknown preset: BOGUS\n\n")
      expect(err.string).to include("Available presets:")
      expect(out.string).to be_empty
    end

    it "runs the preset under the normalized key and answers :ran" do
      allow(described_class).to receive(:run).and_return(true)
      out = StringIO.new
      err = StringIO.new

      expect(described_class.dispatch("Migration ", invocation: invocation, out: out, err: err)).to eq(:ran)
      expect(described_class).to have_received(:run).with("migration", out: out, err: err)
    end

    it "answers :failed when every tool in the preset raised" do
      allow(RailsAiContext::CLI::ToolRunner).to receive(:new).and_raise("boom")

      expect(described_class.dispatch("migration", invocation: invocation, out: StringIO.new, err: StringIO.new))
        .to eq(:failed)
    end

    it "yields the resolved key before running, so a caller can boot first" do
      allow(described_class).to receive(:run).and_return(true)
      booted = []

      described_class.dispatch("migration", invocation: invocation, out: StringIO.new, err: StringIO.new) do |key|
        booted << key
      end

      expect(booted).to eq([ "migration" ])
    end

    it "does not yield for a name no preset carries" do
      yielded = false

      described_class.dispatch("nope", invocation: invocation, out: StringIO.new, err: StringIO.new) { yielded = true }

      expect(yielded).to be false
    end
  end

  describe ".listing" do
    it "renders one line per preset in the caller's invocation form" do
      text = described_class.listing(invocation: ->(key) { "rails-ai-context preset #{key}" })
      expect(text).to include("rails-ai-context preset architecture")
      expect(text.lines.size).to eq(described_class::DEFINITIONS.size + 2)
    end
  end
end
