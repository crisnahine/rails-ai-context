# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

# Every serializer, driven over a context real introspectors produced. The
# per-file specs pin wording against hand-built hashes; this pins the one
# thing those cannot: that no serializer reads a shape production does not
# make.
RSpec.describe "Serializers against a real introspected context" do
  let(:context) { IntrospectedFixture.context }

  [
    RailsAiContext::Serializers::ClaudeSerializer,
    RailsAiContext::Serializers::CopilotSerializer,
    RailsAiContext::Serializers::OpencodeSerializer,
    RailsAiContext::Serializers::MarkdownSerializer,
    RailsAiContext::Serializers::JsonSerializer
  ].each do |klass|
    it "#{klass.name.split('::').last} renders it" do
      output = klass.new(context).call
      expect(output).to be_a(String)
      expect(output).not_to be_empty
    end
  end

  [
    RailsAiContext::Serializers::ClaudeRulesSerializer,
    RailsAiContext::Serializers::CursorRulesSerializer,
    RailsAiContext::Serializers::CopilotInstructionsSerializer
  ].each do |klass|
    it "#{klass.name.split('::').last} writes its rule files from it" do
      Dir.mktmpdir do |dir|
        result = klass.new(context).call(dir)
        expect(result[:written]).not_to be_empty
        result[:written].each do |path|
          expect(File.read(path)).not_to be_empty
        end
      end
    end
  end

  it "OpencodeRulesSerializer writes the split AGENTS.md pair when the app dirs exist" do
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "app", "models"))
      FileUtils.mkdir_p(File.join(dir, "app", "controllers"))

      result = RailsAiContext::Serializers::OpencodeRulesSerializer.new(context).call(dir)
      expect(result[:written].map { |p| p.sub("#{dir}/", "") })
        .to match_array(%w[app/models/AGENTS.md app/controllers/AGENTS.md])
    end
  end
end
