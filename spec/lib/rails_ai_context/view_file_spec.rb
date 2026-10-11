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

  describe ".each with a template linked from outside the app" do
    it "lists the app's own templates and not the linked one" do
      Dir.mktmpdir do |outside|
        File.write(File.join(outside, "leak.html.erb"), "<%= @outside_secret %>\n")
        File.symlink(File.join(outside, "leak.html.erb"), File.join(@root, "app/views/posts/leak.html.erb"))

        expect(described_class.each(@root).map(&:last)).to contain_exactly(
          "posts/index.html.erb", "posts/index.json.jbuilder", "posts/show.turbo_stream.erb", "master.key"
        )
      end
    end

    it "lists no link that resolves nowhere" do
      File.symlink("missing.html.erb", File.join(@root, "app/views/posts/_dangling.html.erb"))

      expect(described_class.each(@root).map(&:last)).not_to include("posts/_dangling.html.erb")
    end
  end

  # The view resolver renders a directory linked into app/views from
  # elsewhere in the repository.
  describe ".each with a directory linked in from the app's repository" do
    it "lists its templates under the name the app gives them" do
      FileUtils.mkdir_p(File.join(@root, ".git"))
      Dir.mktmpdir("shared-views", @root) do |shared|
        FileUtils.mkdir_p(File.join(shared, "invoices"))
        File.write(File.join(shared, "invoices/_invoice.html.erb"), "<%= invoice.id %>\n")
        File.symlink(File.join(shared, "invoices"), File.join(@root, "app/views/invoices"))

        expect(described_class.each(@root).map(&:last)).to include("invoices/_invoice.html.erb")
      end
    end
  end

  describe ".fence" do
    it "labels a template by the handler that renders it" do
      fences = %w[
        posts/index.html.erb pages/about.html reports/export.csv feed.atom posts/show.html.haml
        posts/index.json.jbuilder sitemap.xml.builder pwa/service-worker.js notes/body.text
      ].to_h { |name| [ name, described_class.fence(name) ] }

      expect(fences).to eq(
        "posts/index.html.erb" => "erb", "pages/about.html" => "html", "reports/export.csv" => "csv",
        "feed.atom" => "atom", "posts/show.html.haml" => "haml", "posts/index.json.jbuilder" => "ruby",
        "sitemap.xml.builder" => "ruby", "pwa/service-worker.js" => "js", "notes/body.text" => "text"
      )
    end
  end

  describe ".format_of" do
    it "reads the format a template's name gives, past a locale and a variant, and none where it gives none" do
      formats = %w[
        posts/_post.html.erb posts/_post.json.jbuilder posts/create.turbo_stream.erb
        posts/_post.fr.html+phone.erb posts/_post.erb posts/_post.jbuilder posts/_post.en.erb
      ].to_h { |name| [ name, described_class.format_of(name) ] }

      expect(formats).to eq(
        "posts/_post.html.erb" => "html", "posts/_post.json.jbuilder" => "json",
        "posts/create.turbo_stream.erb" => "turbo_stream", "posts/_post.fr.html+phone.erb" => "html",
        "posts/_post.erb" => nil, "posts/_post.jbuilder" => nil, "posts/_post.en.erb" => nil
      )
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

  describe ".alternate_of" do
    it "names the variant and the locale of the template a file renders for, as Rails parses them" do
      expect(described_class.alternate_of("posts/show.html+mobile.erb")).to eq("`mobile` variant of `show`")
      expect(described_class.alternate_of("posts/show.fr.html.erb")).to eq("`fr` locale of `show`")
      expect(described_class.alternate_of("posts/show.pt-BR.html+phone.erb")).to eq("`pt-BR` locale, `phone` variant of `show`")
      expect(described_class.alternate_of("posts/show+tablet.erb")).to eq("`tablet` variant of `show`")
    end

    # actionview's resolver unions I18n.available_locales with the two-letter form.
    it "reads a locale the app makes available in any spelling" do
      expect(described_class.alternate_of("posts/index.zh-Hant.html.erb", %w[zh-Hant es-419])).to eq("`zh-Hant` locale of `index`")
      expect(described_class.alternate_of("posts/show.es-419.html.erb", %w[zh-Hant es-419])).to eq("`es-419` locale of `show`")
      expect(described_class.alternate_of("posts/index.zh-Hant.html.erb")).to be_nil
    end

    it "leaves a plain template, a format that looks like a locale and an odd name alone" do
      expect(described_class.alternate_of("posts/show.html.erb")).to be_nil
      expect(described_class.alternate_of("posts/show.js.erb")).to be_nil
      expect(described_class.alternate_of("posts/show.erb")).to be_nil
      expect(described_class.alternate_of("posts/_form.html.erb")).to be_nil
      expect(described_class.alternate_of("")).to be_nil
      expect(described_class.alternate_of(nil)).to be_nil
    end
  end

  describe ".mime_type" do
    it "names the language of the source, not what it renders" do
      {
        "posts/index.html.erb" => "text/x-erb",
        "posts/_post.json.jbuilder" => "text/x-ruby",
        "feeds/index.atom.builder" => "text/x-ruby",
        "components/card.rb" => "text/x-ruby",
        "posts/show.html.haml" => "text/x-haml",
        "posts/show.html.slim" => "text/x-slim",
        "pages/about.md" => "text/markdown",
        "pages/terms.html" => "text/html",
        "pages/legal.html.raw" => "text/html",
        "exports/report.csv" => "text/csv",
        "posts/show.html.weird" => "text/plain"
      }.each { |path, type| expect(described_class.mime_type(path)).to eq(type), path }
    end
  end
end
