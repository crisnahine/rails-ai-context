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

  it "reports a missing directory instead of dropping the file silently" do
    Dir.mktmpdir do |dir|
      result = described_class.new(context).call(dir)

      expect(result[:not_applicable]).to eq(
        File.join(dir, "app", "models", "AGENTS.md") => "app/models not present",
        File.join(dir, "app", "controllers", "AGENTS.md") => "app/controllers not present"
      )
      expect(Dir.exist?(File.join(dir, "app"))).to be false
    end
  end
end
