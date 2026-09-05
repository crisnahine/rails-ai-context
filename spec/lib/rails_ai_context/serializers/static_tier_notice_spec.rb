# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

# A file generated without booting the app carries different counts from one
# generated with it, and nothing in the file said which it was.
RSpec.describe "The static-tier notice in generated files" do
  let(:static_context) { IntrospectedFixture.context.merge(tier: "static") }
  let(:booted_context) { IntrospectedFixture.context.merge(tier: "booted") }

  ROOT_SERIALIZERS = [
    RailsAiContext::Serializers::ClaudeSerializer,
    RailsAiContext::Serializers::CopilotSerializer,
    RailsAiContext::Serializers::OpencodeSerializer,
    RailsAiContext::Serializers::MarkdownSerializer
  ].freeze

  ROOT_SERIALIZERS.each do |klass|
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

  [
    RailsAiContext::Serializers::ClaudeRulesSerializer,
    RailsAiContext::Serializers::CursorRulesSerializer,
    RailsAiContext::Serializers::CopilotInstructionsSerializer
  ].each do |klass|
    it "#{klass.name.split('::').last} marks the rules file it writes" do
      Dir.mktmpdir do |dir|
        result = klass.new(static_context).call(dir)
        overview = result[:written].find { |path| File.read(path).include?("Rails 8.0") }

        expect(File.read(overview)).to include(RailsAiContext::Confidence::STATIC)
      end
    end
  end

  it "OpencodeRulesSerializer marks the split AGENTS.md files" do
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "app", "models"))
      FileUtils.mkdir_p(File.join(dir, "app", "controllers"))

      RailsAiContext::Serializers::OpencodeRulesSerializer.new(static_context).call(dir)

      expect(File.read(File.join(dir, "app", "models", "AGENTS.md")))
        .to include(RailsAiContext::Confidence::STATIC)
    end
  end

  it "the JSON dump carries the tier as a key" do
    output = RailsAiContext::Serializers::JsonSerializer.new(static_context).call

    expect(JSON.parse(output)["tier"]).to eq("static")
  end
end
