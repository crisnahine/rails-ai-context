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

  describe ".each with a view path the app declares" do
    before do
      FileUtils.mkdir_p(File.join(@root, "config"))
      File.write(File.join(@root, "config/application.rb"), <<~RUBY)
        class Application < Rails::Application
          config.paths["app/views"].unshift(Rails.root.join("app/views/custom").to_s)
          config.paths["app/views"] << "enterprise/app/views"
        end
      RUBY
      FileUtils.mkdir_p(File.join(@root, "app/views/custom/posts"))
      File.write(File.join(@root, "app/views/custom/posts/show.html.erb"), "<h1>Post</h1>\n")
      File.write(File.join(@root, "app/views/custom/posts/index.html.erb"), "<h1>Custom</h1>\n")
      FileUtils.mkdir_p(File.join(@root, "enterprise/app/views/reports"))
      File.write(File.join(@root, "enterprise/app/views/reports/index.html.erb"), "<h1>Reports</h1>\n")
    end

    it "names a template by the root Rails finds it under, the prepended root first" do
      listed = described_class.each(@root).to_h { |path, relative| [ relative, path ] }

      expect(listed["posts/show.html.erb"]).to eq(File.join(@root, "app/views/custom/posts/show.html.erb"))
      expect(listed["posts/index.html.erb"]).to eq(File.join(@root, "app/views/custom/posts/index.html.erb"))
      expect(listed["reports/index.html.erb"]).to eq(File.join(@root, "enterprise/app/views/reports/index.html.erb"))
      expect(listed.keys.grep(%r{\Acustom/})).to be_empty
    end

    it "ignores a declared root outside the app" do
      File.write(File.join(@root, "config/application.rb"), "config.paths[\"app/views\"] << \"\#{config.root}/../shared/views\"\n")

      expect(RailsAiContext::PathResolver.view_dirs(@root)).to eq([ File.join(@root, "app/views") ])
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

  describe ".template?" do
    it "counts a file whose last extension is a format, which Rails renders with the raw handler" do
      expect(described_class.template?("pwa/service-worker.js")).to be(true)
      expect(described_class.template?("pages/about.text")).to be(true)
    end

    it "still leaves out binary assets and extension-less files" do
      expect(described_class.template?("posts/_logo.png")).to be(false)
      expect(described_class.template?("posts/README")).to be(false)
    end
  end
end
