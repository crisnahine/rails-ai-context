# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe RailsAiContext::ViewFile do
  around do |example|
    Dir.mktmpdir("view-file") do |dir|
      @root = File.realpath(dir)
      FileUtils.mkdir_p(File.join(@root, "app/views/posts"))
      FileUtils.mkdir_p(File.join(@root, "app/views/posts/index"))
      File.write(File.join(@root, "app/views/posts/index.html.erb"), "<h1>Posts</h1>\n")
      File.write(File.join(@root, "app/views/posts/index.json.jbuilder"), "json.posts []\n")
      File.write(File.join(@root, "app/views/posts/show.turbo_stream.erb"), "<turbo-stream/>\n")
      File.write(File.join(@root, "app/views/master.key"), "0123456789abcdef\n")
      example.run
    end
  end

  describe ".locate" do
    it "resolves an app/views-relative path with its extension" do
      result = described_class.locate(@root, "posts/index.html.erb")

      expect(result.refusal).to be_nil
      expect(result.relative).to eq("posts/index.html.erb")
      expect(result.realpath).to eq(File.join(@root, "app/views/posts/index.html.erb"))
    end

    it "accepts the repo-relative spelling too" do
      expect(described_class.locate(@root, "app/views/posts/index.html.erb").relative).to eq("posts/index.html.erb")
    end

    # An agent addresses a template by its logical name. Several formats can
    # exist; the page is the one it almost always means.
    it "resolves an extension-less path, preferring an html format" do
      expect(described_class.locate(@root, "posts/index").relative).to eq("posts/index.html.erb")
    end

    it "resolves an extension-less path to the only format there is" do
      expect(described_class.locate(@root, "posts/show").relative).to eq("posts/show.turbo_stream.erb")
    end

    it "does not let a same-named directory satisfy the extension-less lookup" do
      expect(described_class.locate(@root, "posts/index").realpath).to end_with("index.html.erb")
    end

    it "answers missing for a template that is not there" do
      expect(described_class.locate(@root, "posts/nope").refusal).to eq(:missing)
    end

    it "refuses traversal and sensitive names before any stat" do
      expect(described_class.locate(@root, "../config/master.key").refusal).to eq(:traversal)
      expect(described_class.locate(@root, "posts/master.key").refusal).to eq(:sensitive)
      expect(described_class.locate(@root, "master").refusal).to eq(:missing)
    end
  end

  describe ".read" do
    it "returns the template content" do
      content, result = described_class.read(@root, "posts/index")

      expect(content).to eq("<h1>Posts</h1>\n")
      expect(result.relative).to eq("posts/index.html.erb")
    end
  end
end
