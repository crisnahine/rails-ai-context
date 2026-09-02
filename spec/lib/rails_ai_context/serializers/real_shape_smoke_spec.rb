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
      # A section that resolved names the fixture's five models. A key no
      # introspector emits empties the section instead of failing, so the
      # count is what says the read landed.
      expect(output).to match(/Models[ :(]+7/) unless klass == RailsAiContext::Serializers::JsonSerializer
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

        models_file = result[:written].find { |path| path.include?("models") }
        expect(File.read(models_file)).to match(/Models \(7\)/)
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
      expect(File.read(File.join(dir, "app", "models", "AGENTS.md"))).to include("Models (7)")
    end
  end

  # One controller set for every surface: a listing that counts what the
  # configuration hides answers a different number than the tool beside it.
  describe "the configured controllers" do
    around do |example|
      RailsAiContext.configuration.excluded_controllers += %w[Api::V1::BaseController]
      example.run
    ensure
      RailsAiContext.configuration.excluded_controllers -= %w[Api::V1::BaseController]
    end

    it "MarkdownSerializer leaves it out of the count and the listing" do
      output = RailsAiContext::Serializers::MarkdownSerializer.new(context).call
      expect(output).to include("## Controllers (1)")
      expect(output).not_to include("Api::V1::BaseController")
    end

    it "CursorRulesSerializer leaves it out of the count" do
      Dir.mktmpdir do |dir|
        RailsAiContext::Serializers::CursorRulesSerializer.new(context).call(dir)
        text = File.read(File.join(dir, ".cursor", "rules", "rails-controllers.mdc"))
        expect(text).to include("# Controllers (1)")
        expect(text).not_to include("Api::V1::BaseController")
      end
    end

    it "CopilotInstructionsSerializer leaves it out of the count" do
      Dir.mktmpdir do |dir|
        RailsAiContext::Serializers::CopilotInstructionsSerializer.new(context).call(dir)
        text = File.read(File.join(dir, ".github", "instructions", "rails-controllers.instructions.md"))
        expect(text).to include("# Controllers (1)")
        expect(text).not_to include("Api::V1::BaseController")
      end
    end

    it "OpencodeRulesSerializer leaves it out of the count" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models"))
        FileUtils.mkdir_p(File.join(dir, "app", "controllers"))
        RailsAiContext::Serializers::OpencodeRulesSerializer.new(context).call(dir)
        text = File.read(File.join(dir, "app", "controllers", "AGENTS.md"))
        expect(text).to include("# Controllers (1)")
        expect(text).not_to include("Api::V1::BaseController")
      end
    end

    # Seeded through the shared cache the tools already read, so the tool runs
    # over the same fixture context as the serializers above with nothing
    # stubbed. spec_helper clears that cache in a config-level before(:each),
    # so the seeding has to be a before hook, not an around one.
    it "rails_get_controllers leaves it out of the listing and the count" do
      cache = RailsAiContext::Tools::BaseTool::SHARED_CACHE
      cache[:context] = context.deep_dup
      cache[:timestamp] = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      text = RailsAiContext::Tools::GetControllers.call(detail: "summary").content.first[:text]

      expect(text).to include("Controllers (1)")
      expect(text).not_to include("Api::V1::BaseController")
    ensure
      RailsAiContext::Tools::BaseTool.reset_cache!
    end
  end
end
