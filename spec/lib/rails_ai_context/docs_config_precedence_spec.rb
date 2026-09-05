# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "yaml"

pages = %w[STANDALONE.md TROUBLESHOOTING.md FAQ.md GUIDE.md].freeze

# Four pages told a reader the initializer outranks .rails-ai-context.yml and
# that the file is skipped whenever one runs. v5.25.0 made it a key-by-key
# merge and only docs/CONFIGURATION.md was updated, so the doc set answered
# the same question two ways. Pin the claim to the code, not to itself.
RSpec.describe "config precedence in the docs" do
  def flat(page)
    File.read(File.expand_path("../../../docs/#{page}", __dir__)).gsub(/\s+/, " ")
  end

  pages.each do |page|
    describe page do
      let(:text) { flat(page) }

      it "does not claim the initializer outranks the YAML file" do
        expect(text).not_to match(/initializer (takes (priority|precedence)|wins|overrides)/i)
      end

      it "does not claim the YAML file is skipped" do
        expect(text).not_to match(/(YAML|\.rails-ai-context\.yml)[^.]{0,80}is skipped/i)
      end

      # A negative assertion alone goes green on a reword that is still wrong.
      it "states the merge or points at the one page that does" do
        expect(text).to match(/CONFIGURATION\.md#precedence|key by key/i)
      end
    end
  end

  # The prose above is only worth pinning if it matches what the loader does.
  it "keeps a YAML key the configure block never assigned" do
    RailsAiContext.configuration = RailsAiContext::Configuration.new

    Dir.mktmpdir do |dir|
      File.write(File.join(dir, ".rails-ai-context.yml"),
                 YAML.dump({ "skip_tools" => %w[rails_get_engines], "server_name" => "from-yaml" }))

      RailsAiContext::Configuration.load_config_file!(dir)
      RailsAiContext.configure { |c| c.server_name = "from-block" }

      expect(RailsAiContext.configuration.skip_tools).to eq(%w[rails_get_engines])
      expect(RailsAiContext.configuration.server_name).to eq("from-block")
    end
  ensure
    RailsAiContext.configuration = RailsAiContext::Configuration.new
  end
end
