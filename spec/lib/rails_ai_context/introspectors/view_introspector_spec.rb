# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Introspectors::ViewIntrospector do
  let(:introspector) { described_class.new(Rails.application) }

  describe "#call" do
    subject(:result) { introspector.call }

    it "does not return an error" do
      expect(result).not_to have_key(:error)
    end

    it "discovers layouts as hashes with name key" do
      names = result[:layouts].map { |l| l[:name] }
      expect(names).to include("application.html.erb")
      names.each do |name|
        expect(name).not_to include("/")
      end
    end

    it "does not include directories in layouts" do
      result[:layouts].each do |layout|
        full_path = File.join(Rails.root, "app/views/layouts", layout[:name])
        expect(File.file?(full_path)).to be(true), "Expected #{layout[:name]} to be a file, not a directory"
      end
    end

    context "with a partial under app/views/layouts" do
      let(:partial) { File.join(Rails.root, "app/views/layouts/_vi_footer.html.erb") }

      before { File.write(partial, "<footer></footer>\n") }
      after { FileUtils.rm_f(partial) }

      it "reads it as a partial, not as a layout" do
        expect(result[:layouts].map { |l| l[:name] }).not_to include("_vi_footer.html.erb")
        expect(result[:partials][:per_controller]["layouts"]).to include("_vi_footer.html.erb")
      end
    end

    it "discovers templates grouped by controller" do
      expect(result[:templates]).to have_key("posts")
      expect(result[:templates]["posts"]).to include("index.html.erb")
      expect(result[:templates]["posts"]).to include("show.html.erb")
    end

    context "with a non-template file whose name starts with an underscore" do
      let(:asset_path) { File.join(Rails.root, "app/views/posts/_logo.png") }
      let(:dir_path) { File.join(Rails.root, "app/views/posts/_bits") }

      before do
        File.binwrite(asset_path, "\x89PNG\r\n")
        FileUtils.mkdir_p(dir_path)
      end

      after do
        FileUtils.rm_f(asset_path)
        FileUtils.rm_rf(dir_path)
      end

      it "does not list it as a partial" do
        listed = result[:partials][:per_controller]["posts"].to_a
        expect(listed).not_to include("_logo.png")
        expect(listed).not_to include("_bits")
      end
    end

    it "excludes partials from templates" do
      result[:templates].each do |_controller, templates|
        templates.each do |t|
          expect(t).not_to start_with("_")
        end
      end
    end

    it "excludes layouts from templates" do
      expect(result[:templates]).not_to have_key("layouts")
    end

    it "discovers partials in per_controller" do
      expect(result[:partials][:per_controller]).to have_key("posts")
      expect(result[:partials][:per_controller]["posts"]).to include("_post.html.erb")
    end

    it "returns shared partials as sorted array" do
      expect(result[:partials][:shared]).to be_an(Array)
    end

    it "extracts helpers with methods" do
      helper_files = result[:helpers].map { |h| h[:file] }
      expect(helper_files).to include("application_helper.rb", "posts_helper.rb")

      app_helper = result[:helpers].find { |h| h[:file] == "application_helper.rb" }
      expect(app_helper[:methods]).to include("page_title")

      posts_helper = result[:helpers].find { |h| h[:file] == "posts_helper.rb" }
      expect(posts_helper[:methods]).to include("post_excerpt")
    end

    it "detects erb template engine" do
      expect(result[:template_engines]).to include("erb")
    end

    it "discovers view components from app/components" do
      expect(result[:view_components]).to include("alert_component", "card_component")
    end

    it "detects form builders used in views" do
      expect(result[:form_builders_detected]).to be_a(Hash)
      expect(result[:form_builders_detected]["form_with"]).to be >= 1
    end

    it "returns component_usage as array" do
      expect(result[:component_usage]).to be_an(Array)
    end

    context "with component render calls in views" do
      let(:fixture_view) { File.join(Rails.root, "app/views/posts/components_test.html.erb") }

      before do
        File.write(fixture_view, <<~ERB)
          <%= render AlertComponent.new(message: "Hello") %>
          <%= render CardComponent.new(title: "World") %>
        ERB
      end

      after { FileUtils.rm_f(fixture_view) }

      it "detects component usage from render calls" do
        expect(result[:component_usage]).to include("AlertComponent", "CardComponent")
      end
    end
  end

  describe "views under an in-repo plugin" do
    def introspect(root)
      described_class.new(RailsAiContext::StaticApp.new(root)).call
    end

    around do |example|
      Dir.mktmpdir do |root|
        @root = root
        FileUtils.mkdir_p(File.join(root, "app/views/posts"))
        File.write(File.join(root, "app/views/posts/index.html.erb"), "<%= form_with url: '/' %>\n")
        FileUtils.mkdir_p(File.join(root, "plugins/chat/app/views/user_notifications"))
        FileUtils.mkdir_p(File.join(root, "plugins/chat/app/models"))
        File.write(File.join(root, "plugins/chat/plugin.rb"), "# plugin\n")
        File.write(File.join(root, "plugins/chat/app/views/user_notifications/chat_summary.html.haml"),
                   "= simple_form_for @chat do |f|\n  = render ChatCardComponent.new\n")
        File.write(File.join(root, "plugins/chat/app/views/user_notifications/_row.html.haml"), "%div row\n")
        RailsAiContext::PathResolver.clear_code_roots
        example.run
      end
    end

    it "counts the plugin's template under its own controller" do
      expect(introspect(@root)[:templates]["user_notifications"]).to eq([ "chat_summary.html.haml" ])
    end

    it "counts the plugin's partial" do
      expect(introspect(@root)[:partials][:per_controller]["user_notifications"]).to eq([ "_row.html.haml" ])
    end

    it "reads the plugin's template engine, form builder and component" do
      result = introspect(@root)

      expect(result[:template_engines]).to include("haml")
      expect(result[:form_builders_detected]).to include("simple_form_for")
      expect(result[:component_usage]).to include("ChatCardComponent")
    end
  end

  describe "what a layout yields" do
    def yields_for(name, source)
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "app/views/layouts"))
        File.write(File.join(root, "app/views/layouts", name), source)
        layouts = described_class.new(RailsAiContext::StaticApp.new(root)).call[:layouts]
        return layouts.first[:yields]
      end
    end

    it "reads the main yield and named ones in ERB, whatever wraps them" do
      source = <<~ERB
        <% right_side = (yield :right_side).presence %>
        <% if content_for?(:head) %><%= yield(:head) %><% end %>
        <p>These results yield nothing.</p>
        <%# yield :commented_out %>
        <main><%= yield %></main>
      ERB

      expect(yields_for("application.html.erb", source)).to eq([ "right_side", "head", "(main)" ])
    end

    it "does not read a content_for that sets content as one the layout yields" do
      source = %(<% content_for :title, "Home" %>\n<% content_for :js do %>x<% end %>\n<%= content_for(:head) %><%= yield %>\n)

      expect(yields_for("setter.html.erb", source)).to eq([ "head", "(main)" ])
    end

    it "reads no parenthesised content_for with a block or a value as a yield, in any template" do
      erb = %(<% content_for(:head) do %>x<% end %>\n<% content_for(:foot) { "x" } %>\n<% content_for("title", "Home") %>\n<%= yield %>\n)

      expect(yields_for("parens.html.erb", erb)).to eq([ "(main)" ])
      expect(yields_for("parens.html.haml", "- content_for(:bar) do\n  x\n= yield\n")).to eq([ "(main)" ])
      expect(yields_for("parens.html.slim", "- content_for(:bar) do\n  | x\n== yield\n")).to eq([ "(main)" ])
    end

    it "reads no yield out of HAML or Slim prose" do
      expect(yields_for("prose.html.haml", "%p Crops yield more\nFarms yield - and grow\n%main= yield :body\n")).to eq([ "body" ])
      expect(yields_for("prose.html.slim", "p Crops yield more\nmain == yield(:body)\n")).to eq([ "body" ])
    end

    it "reads a yield inside a HAML attribute hash or a Slim attribute value" do
      expect(yields_for("meta.html.haml", %(%meta{content: content_for?(:description) ? yield(:description) : "x"}\n)))
        .to eq([ "description" ])
      expect(yields_for("meta.html.slim", %(meta property="og:image" content=yield(:image)\n))).to eq([ "image" ])
    end

    it "reads HAML" do
      expect(yields_for("admin.html.haml", "%head= yield :head\n%body\n  = yield\n-# = yield :old\n"))
        .to eq([ "head", "(main)" ])
    end

    it "reads Slim" do
      expect(yields_for("bare.html.slim", "- if content_for?(:foot)\n  == yield(:foot)\nmain == yield\n"))
        .to eq([ "foot", "(main)" ])
    end
  end
end
