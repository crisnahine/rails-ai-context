# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Serializers::OpencodeRulesSerializer do
  let(:context) do
    {
      models: {
        "User" => { table_name: "users", associations: [ { type: "has_many", name: "posts" } ], validations: [ { kind: "presence" } ] },
        "Post" => { table_name: "posts", associations: [ { type: "belongs_to", name: "user" } ], validations: [] }
      },
      controllers: {
        controllers: {
          "UsersController" => { actions: [ { name: "index" }, { name: "show" }, { name: "create" } ] },
          "PostsController" => { actions: [ { name: "index" }, { name: "show" } ] }
        }
      }
    }
  end

  it "generates app/models/AGENTS.md and app/controllers/AGENTS.md" do
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "app", "models"))
      FileUtils.mkdir_p(File.join(dir, "app", "controllers"))

      result = described_class.new(context).call(dir)

      expect(result[:written].size).to eq(2)

      models_file = File.join(dir, "app", "models", "AGENTS.md")
      expect(File.exist?(models_file)).to be true
      content = File.read(models_file)
      expect(content).to include("User")
      expect(content).to include("Post")
      expect(content).to include("rails_get_model_details")
      expect(content).to include("has_many :posts")

      controllers_file = File.join(dir, "app", "controllers", "AGENTS.md")
      expect(File.exist?(controllers_file)).to be true
      content = File.read(controllers_file)
      expect(content).to include("UsersController")
      expect(content).to include("PostsController")
      expect(content).to include("rails_get_controllers")
      expect(content).to include("index")
    end
  end

  it "skips unchanged files" do
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "app", "models"))
      FileUtils.mkdir_p(File.join(dir, "app", "controllers"))

      first = described_class.new(context).call(dir)
      expect(first[:written].size).to eq(2)

      second = described_class.new(context).call(dir)
      expect(second[:written]).to be_empty
      expect(second[:skipped].size).to eq(2)
    end
  end

  it "skips models file when no models" do
    context[:models] = {}
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "app", "models"))
      FileUtils.mkdir_p(File.join(dir, "app", "controllers"))

      result = described_class.new(context).call(dir)
      expect(result[:written].size).to eq(1) # controllers only
    end
  end

  it "skips controllers file when no controllers" do
    context[:controllers] = { controllers: {} }
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "app", "models"))
      FileUtils.mkdir_p(File.join(dir, "app", "controllers"))

      result = described_class.new(context).call(dir)
      expect(result[:written].size).to eq(1) # models only
    end
  end

  it "skips directories that do not exist" do
    Dir.mktmpdir do |dir|
      # No app/models/ or app/controllers/ directories
      result = described_class.new(context).call(dir)
      expect(result[:written]).to be_empty
      expect(result[:skipped]).to be_empty
    end
  end

  it "names the files it did not generate and why" do
    context[:models] = {}
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "app", "models"))
      FileUtils.mkdir_p(File.join(dir, "app", "controllers"))

      result = described_class.new(context).call(dir)

      expect(result[:not_applicable]).to eq(File.join(dir, "app", "models", "AGENTS.md") => "no models")
    end
  end

  # Teams write app/models/AGENTS.md by hand for OpenCode and Codex, and every
  # run replaced it with the listing: no prompt, no backup, no warning.
  describe "a per-directory AGENTS.md the user wrote" do
    let(:mine) { "# Our model rules\n\nNever call Post.destroy_all.\n" }
    let(:generated_note) { "> #{RailsAiContext::Install::Cleanup::GENERATED_NOTE}" }

    def models_file(dir)
      File.join(dir, "app", "models", "AGENTS.md")
    end

    def write_mine(dir)
      FileUtils.mkdir_p(File.join(dir, "app", "models"))
      File.write(models_file(dir), mine)
    end

    it "keeps the user's text and adds the listing as a marked block" do
      Dir.mktmpdir do |dir|
        write_mine(dir)

        result = described_class.new(context).call(dir)
        content = File.read(models_file(dir))

        expect(result[:written]).to include(models_file(dir))
        expect(content).to end_with(mine)
        expect(content).to start_with("#{RailsAiContext::Serializers::SectionMarkerWriter::BEGIN_MARKER}\n# ActiveRecord Models (2)")
        expect(content).to include("has_many :posts", RailsAiContext::Serializers::SectionMarkerWriter::END_MARKER)
      end
    end

    it "claims the block, not the file" do
      Dir.mktmpdir do |dir|
        write_mine(dir)

        described_class.new(context).call(dir)
        content = File.read(models_file(dir))

        expect(content).not_to include(generated_note)
        expect(content).to include("> #{RailsAiContext::Serializers::SectionMarkerWriter::BLOCK_NOTE}")
      end
    end

    it "replaces only its block on the next run" do
      Dir.mktmpdir do |dir|
        write_mine(dir)
        described_class.new(context).call(dir)
        File.write(models_file(dir), File.read(models_file(dir)) + "Added later.\n")

        context[:models]["Tag"] = { table_name: "tags", associations: [], validations: [] }
        described_class.new(context).call(dir)
        content = File.read(models_file(dir))

        expect(content).to include("# ActiveRecord Models (3)", "Never call Post.destroy_all.", "Added later.")
        expect(content.scan(RailsAiContext::Serializers::SectionMarkerWriter::BEGIN_MARKER).size).to eq(1)
      end
    end

    it "rewrites a file it generated whole, whole" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models"))
        described_class.new(context).call(dir)
        expect(File.read(models_file(dir))).to include(generated_note)

        context[:models]["Tag"] = { table_name: "tags", associations: [], validations: [] }
        described_class.new(context).call(dir)
        content = File.read(models_file(dir))

        expect(content).to start_with("# ActiveRecord Models (3)")
        expect(content).not_to include(RailsAiContext::Serializers::SectionMarkerWriter::BEGIN_MARKER)
      end
    end

    it "leaves the user's text as it was once the AI tool is dropped" do
      Dir.mktmpdir do |dir|
        write_mine(dir)
        described_class.new(context).call(dir)

        outcome = RailsAiContext::Install::Cleanup.remove(tools: %i[opencode codex], keeping: [], root: dir)

        expect(File.read(models_file(dir))).to eq(mine)
        expect(outcome[:trimmed]).to include("app/models/AGENTS.md")
      end
    end
  end

  it "reports a missing directory instead of dropping the file silently" do
    Dir.mktmpdir do |dir|
      allow(Rails).to receive(:root).and_return(Pathname.new(dir))

      result = described_class.new(context).call(dir)

      expect(result[:not_applicable]).to eq(
        File.join(dir, "app", "models", "AGENTS.md") => "app/models not present",
        File.join(dir, "app", "controllers", "AGENTS.md") => "app/controllers not present"
      )
      expect(Dir.exist?(File.join(dir, "app"))).to be false
    end
  end

  # With config.output_dir elsewhere, the app has app/models; only the output
  # dir lacks it, and "app/models not present" said otherwise.
  it "says it is the output_dir that lacks the directory, when the app has it" do
    Dir.mktmpdir do |app|
      Dir.mktmpdir do |out|
        FileUtils.mkdir_p(File.join(app, "app", "models"))
        allow(Rails).to receive(:root).and_return(Pathname.new(app))

        result = described_class.new(context).call(out)

        expect(result[:not_applicable]).to eq(
          File.join(out, "app", "models", "AGENTS.md") => "no app/models under output_dir",
          File.join(out, "app", "controllers", "AGENTS.md") => "app/controllers not present"
        )
        expect(Dir.exist?(File.join(out, "app"))).to be false
      end
    end
  end
end
