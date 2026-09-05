# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

# A file generated without booting the app carries different counts from one
# generated with it, and nothing in the file said which it was.
RSpec.describe "The static-tier notice in generated files" do
  let(:static_context) { IntrospectedFixture.context.merge(tier: "static") }
  let(:booted_context) { IntrospectedFixture.context.merge(tier: "booted") }

  # Read off the tables the generator dispatches through, so a serializer
  # added there joins this contract without being typed in here. A local, not
  # a constant: one assigned inside a describe block lands on Object.
  root_serializers = (RailsAiContext::Serializers::ContextFileSerializer::ROOT_SERIALIZERS.values.uniq -
    [ RailsAiContext::Serializers::JsonSerializer ]) + [ RailsAiContext::Serializers::MarkdownSerializer ]

  root_serializers.each do |klass|
    it "#{klass.name.split('::').last} says the answer is static, near the top" do
      output = klass.new(static_context).call

      expect(output.lines.first(12).join).to include(RailsAiContext::Confidence::STATIC)
      expect(output).to include("counts can differ from a booted run")
    end

    it "#{klass.name.split('::').last} says nothing new when the app booted" do
      expect(klass.new(booted_context).call).not_to include(RailsAiContext::Confidence::STATIC)
    end
  end

  it "the full-mode Claude file says it too" do
    RailsAiContext.configuration.context_mode = :full
    output = RailsAiContext::Serializers::ClaudeSerializer.new(static_context).call

    expect(output.lines.first(12).join).to include(RailsAiContext::Confidence::STATIC)
  ensure
    RailsAiContext.configuration.context_mode = :compact
  end

  # OpenCode's rules serializer writes into app/models and app/controllers
  # rather than a rules directory, so it is exercised on its own below.
  rules_serializers = RailsAiContext::Serializers::ContextFileSerializer::RULES_SERIALIZERS.values.uniq -
    [ RailsAiContext::Serializers::OpencodeRulesSerializer ]

  rules_serializers.each do |klass|
    it "#{klass.name.split('::').last} marks the rules file it writes" do
      Dir.mktmpdir do |dir|
        result = klass.new(static_context).call(dir)
        overview = result[:written].find { |path| File.read(path).include?("Rails 8.0") }

        expect(File.read(overview)).to include(RailsAiContext::Confidence::STATIC)
      end
    end

    # Two adjacent non-blank lines are one paragraph, so a notice written
    # under the version line renders as part of it.
    it "#{klass.name.split('::').last} keeps the notice in its own paragraph" do
      Dir.mktmpdir do |dir|
        result = klass.new(static_context).call(dir)
        overview = result[:written].find { |path| File.read(path).include?("Rails 8.0") }
        lines = File.read(overview).lines.map(&:chomp)
        at = lines.index { |line| line.include?(RailsAiContext::Confidence::STATIC) }

        # A notice on the first line would make lines[at - 1] the last line of
        # the file, and the guard would pass on the arrangement it rejects.
        expect(at).to be > 0
        expect(lines[at - 1]).to eq("")
        expect(lines[at + 1]).to eq("")
      end
    end

    # Only the overview file carried the notice. The models, controllers,
    # schema and component files state counts that move between tiers, and a
    # reader holding one of them could not tell which tier wrote it.
    it "#{klass.name.split('::').last} marks every file whose counts move between tiers" do
      Dir.mktmpdir do |dir|
        result = klass.new(static_context).call(dir)
        app_files = result[:written].reject { |path| path.include?("mcp-tools") }

        expect(app_files.size).to be > 1
        app_files.each do |path|
          expect(File.read(path)).to include(RailsAiContext::Confidence::STATIC), "#{path} has no static notice"
        end
      end
    end

    it "#{klass.name.split('::').last} marks none of them when the app booted" do
      Dir.mktmpdir do |dir|
        result = klass.new(booted_context).call(dir)

        result[:written].each do |path|
          expect(File.read(path)).not_to include(RailsAiContext::Confidence::STATIC), "#{path} claims to be static"
        end
      end
    end
  end

  it "OpencodeRulesSerializer marks every split AGENTS.md it writes" do
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "app", "models"))
      FileUtils.mkdir_p(File.join(dir, "app", "controllers"))

      result = RailsAiContext::Serializers::OpencodeRulesSerializer.new(static_context).call(dir)

      expect(result[:written].size).to be > 1
      result[:written].each do |path|
        expect(File.read(path)).to include(RailsAiContext::Confidence::STATIC), "#{path} has no static notice"
      end
    end
  end

  # The two lists above are derived from the generator's own tables; this is
  # the guard that they still name every serializer it runs.
  it "covers every serializer the generator dispatches to" do
    dispatched = (RailsAiContext::Serializers::ContextFileSerializer::ROOT_SERIALIZERS.values +
      RailsAiContext::Serializers::ContextFileSerializer::RULES_SERIALIZERS.values).uniq
    covered = root_serializers + rules_serializers +
      [ RailsAiContext::Serializers::JsonSerializer, RailsAiContext::Serializers::OpencodeRulesSerializer ]

    expect(dispatched - covered).to be_empty
  end

  it "the JSON dump carries the tier as a key" do
    output = RailsAiContext::Serializers::JsonSerializer.new(static_context).call

    expect(JSON.parse(output)["tier"]).to eq("static")
  end

  it "leaves no name of its own on Object" do
    expect(Object.const_defined?(:ROOT_SERIALIZERS)).to be(false)
  end
end
