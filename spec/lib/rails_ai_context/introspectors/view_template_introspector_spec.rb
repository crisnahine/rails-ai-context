# frozen_string_literal: true

require "spec_helper"
require "open3"
require "tmpdir"
require "fileutils"

RSpec.describe RailsAiContext::Introspectors::ViewTemplateIntrospector do
  let(:introspector) { described_class.new(Rails.application) }

  describe "#call" do
    subject(:result) { introspector.call }

    it "does not return an error" do
      expect(result).not_to have_key(:error)
    end

    it "returns templates hash" do
      expect(result[:templates]).to be_a(Hash)
    end

    it "returns partials hash" do
      expect(result[:partials]).to be_a(Hash)
    end

    it "discovers templates in posts directory" do
      expect(result[:templates].keys).to include("posts/index.html.erb")
      expect(result[:templates].keys).to include("posts/show.html.erb")
    end

    it "excludes partials from templates" do
      template_names = result[:templates].keys
      expect(template_names.none? { |n| File.basename(n).start_with?("_") }).to be true
    end

    it "discovers partials" do
      expect(result[:partials].keys).to include("posts/_post.html.erb")
    end

    it "counts lines for templates" do
      index = result[:templates]["posts/index.html.erb"]
      expect(index[:lines]).to be > 0
    end

    it "extracts partial references from templates" do
      index = result[:templates]["posts/index.html.erb"]
      expect(index[:partials]).to be_an(Array)
    end

    it "extracts stimulus references from templates" do
      show = result[:templates]["posts/show.html.erb"]
      expect(show[:stimulus]).to be_an(Array)
    end

    it "excludes layouts from templates" do
      template_names = result[:templates].keys
      expect(template_names.none? { |n| n.include?("layouts/") }).to be true
    end

    describe "phlex views" do
      it "discovers Phlex view templates" do
        expect(result[:templates].keys).to include("articles/show.rb")
      end

      it "marks Phlex views with phlex: true" do
        phlex_template = result[:templates]["articles/show.rb"]
        expect(phlex_template[:phlex]).to be true
      end

      it "extracts component renders from Phlex views" do
        phlex_template = result[:templates]["articles/show.rb"]
        expect(phlex_template[:components]).to include("Components::Articles::ArticleUser")
        expect(phlex_template[:components]).to include("Components::Likes::Button")
        expect(phlex_template[:components]).to include("Components::Comments::CommentHeader")
        expect(phlex_template[:components]).to include("Components::Comments::CommentForm")
        expect(phlex_template[:components]).to include("Components::Comments::Comment")
        expect(phlex_template[:components]).to include("RubyUI::Heading")
      end

      it "extracts helper calls from Phlex views" do
        phlex_template = result[:templates]["articles/show.rb"]
        expect(phlex_template[:helpers]).to include("link_to")
        expect(phlex_template[:helpers]).to include("image_tag")
        expect(phlex_template[:helpers]).to include("content_for")
        expect(phlex_template[:helpers]).to include("dom_id")
      end

      it "extracts stimulus controllers from Phlex views" do
        phlex_template = result[:templates]["articles/show.rb"]
        expect(phlex_template[:stimulus]).to include("infinite_scroll")
        expect(phlex_template[:stimulus]).to include("clipboard")
        expect(phlex_template[:stimulus]).to include("reply_form")
      end

      it "does not mark ERB templates as phlex" do
        erb_template = result[:templates]["posts/index.html.erb"]
        expect(erb_template[:phlex]).to be_nil
      end

      it "counts lines for Phlex views" do
        phlex_template = result[:templates]["articles/show.rb"]
        expect(phlex_template[:lines]).to be > 0
      end
    end

    describe "ui_patterns removal (v5.0.0)" do
      it "does not expose a ui_patterns key" do
        expect(result).not_to have_key(:ui_patterns)
      end
    end
  end

  describe "#extract_partial_refs" do
    it "detects the Rails 7+ bare local-variable render form (render article)" do
      source = <<~ERB
        <% @articles.each do |article| %>
          <%= render article %>
        <% end %>
      ERB
      expect(introspector.send(:extract_partial_refs, source)).to include("article")
    end

    it "detects the bare form wrapped in parens (render(article))" do
      source = "<%= render(article) %>"
      expect(introspector.send(:extract_partial_refs, source)).to include("article")
    end

    it "reads render @post.comments as the partial the records the association holds render, as partial_interface does" do
      refs = introspector.send(:extract_partial_refs, "<%= render @post.comments %>\n<%= render @posts if @posts.any? -%>")
      expect(refs).to contain_exactly("comments/comment", "posts/post")
    end

    # A trailing scope or Enumerable call keeps the records it was called on.
    it "names the records under a trailing call, and no name for a chain on something that is no model" do
      source = "<%= render @posts.first %>\n<%= render @post.comments.reverse %>\n<%= render current_account.widgets %>"
      expect(introspector.send(:extract_partial_refs, source)).to contain_exactly("posts/post", "comments/comment")
    end

    it "names the records a class_name association holds, not the association" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "app/models"))
        File.write(File.join(root, "app/models/post.rb"), "class Post < ApplicationRecord\n  has_many :replies, class_name: \"Comment\"\n  belongs_to :starter, class_name: \"Comment\"\n  has_many :staff, class_name: \"Employee\"\nend\n")
        File.write(File.join(root, "app/models/comment.rb"), "class Comment < ApplicationRecord; end\n")
        File.write(File.join(root, "app/models/employee.rb"), "class Employee < ApplicationRecord; end\n")
        refs = described_class.new(RailsAiContext::StaticApp.new(root)).send(:extract_partial_refs, "<%= render @post.replies %>\n<%= render @post.starter %>\n<%= render @post.staff %>\n<%= render @posts %>")
        expect(refs).to contain_exactly("comments/comment", "employees/employee", "posts/post")
      end
    end

    it "names the partial a model's own to_partial_path gives, for a constant only the app's Zeitwerk inflector spells" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "app/models"))
        FileUtils.mkdir_p(File.join(root, "config/initializers"))
        File.write(File.join(root, "app/models/html_page.rb"), "class HTMLPage < ApplicationRecord\n  def to_partial_path = \"pages/html\"\nend\n")
        File.write(File.join(root, "config/initializers/zeitwerk.rb"),
                   "Rails.autoloaders.each { |loader| loader.inflector.inflect(\"html_page\" => \"HTMLPage\") }\n")
        refs = RailsAiContext::RunCache.around_app(RailsAiContext::StaticApp.new(root)) do
          described_class.new(RailsAiContext::StaticApp.new(root)).send(:extract_partial_refs, "<%= render @html_pages %>")
        end
        expect(refs).to eq([ "pages/html" ])
      end
    end

    it "keeps a lone local whose class the app does not declare as written, as Rails reads a form builder's partial" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "app/views/admin/widgets"))
        File.write(File.join(root, "app/views/admin/widgets/edit.html.erb"), "<%= form_with model: @widget do |form| %>\n<%= render form %>\n<% end %>\n")
        refs = described_class.new(RailsAiContext::StaticApp.new(root)).call[:templates]["admin/widgets/edit.html.erb"][:partials]
        expect(refs).to eq([ "form" ])
      end
    end

    it "reads a form builder block parameter of any name as the partial its builder's to_partial_path names" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "app/views/admin/widgets"))
        File.write(File.join(root, "app/views/admin/widgets/edit.html.erb"), <<~ERB)
          <%= form_with model: @widget do |f| %><%= render f %><% end %>
          <%= form_for @widget,
                builder: Admin::WidgetFormBuilder do |builder| %><%= render(builder) %><% end %>
          <% @survey.fields.each do |field| %><%= render field %><% end %>
        ERB
        refs = described_class.new(RailsAiContext::StaticApp.new(root)).call[:templates]["admin/widgets/edit.html.erb"][:partials]
        expect(refs).to eq([ "form", "widget_form", "field" ])
      end
    end

    it "reads a brace block's builder and a builder's own fields and fields_for, which keep the form's builder class" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "app/views/admin/posts"))
        File.write(File.join(root, "app/views/admin/posts/edit.html.erb"), <<~ERB)
          <%= form_with(model: Post.new, url: "/x") { |g| %><%= render g %><% } %>
          <%= form_with(model: Post.new, url: "/x", builder: ReportFormBuilder) { |b| render b } %>
          <%= form_with model: Post.new, url: "/x" do |f| %><%= f.fields :extra do |ef| %><%= render ef %><% end %><% end %>
          <%= form_for Post.new, url: "/x", builder: WidgetFormBuilder do |w| %><%= w.fields_for :comments do |cf| %><%= render cf %><% end %><% end %>
        ERB
        refs = described_class.new(RailsAiContext::StaticApp.new(root)).call[:templates]["admin/posts/edit.html.erb"][:partials]
        expect(refs).to eq([ "form", "report_form", "widget_form" ])
      end
    end

    it "reads a builder's block past a brace block inside the helper's arguments, as Ruby binds the do block to the helper" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "app/views/admin/posts"))
        File.write(File.join(root, "app/views/admin/posts/edit.html.erb"), <<~ERB)
          <%= form_with model: Post.new, url: "/x" do |f| %><%= f.fields_for :comments, [Comment.new].reject { |c| c.nil? } do |cf| %><%= render cf %><% end %><% end %>
          <%= form_with model: Post.new, url: "/x", data: { ids: [1].map { |c| c } } do |g| %><%= render g %><% end %>
        ERB
        refs = described_class.new(RailsAiContext::StaticApp.new(root)).call[:templates]["admin/posts/edit.html.erb"][:partials]
        expect(refs).to eq([ "form" ])
      end
    end

    it "reads a record's fields iterated or given a block as the records it yields, never a form builder" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "app/models"))
        FileUtils.mkdir_p(File.join(root, "app/views/admin/posts"))
        FileUtils.mkdir_p(File.join(root, "app/views/admin/fields"))
        File.write(File.join(root, "app/models/field.rb"), "class Field < ApplicationRecord; end\n")
        File.write(File.join(root, "app/models/post.rb"), "class Post < ApplicationRecord; end\n")
        File.write(File.join(root, "app/views/admin/fields/_field.html.erb"), "<%= field.id %>\n")
        File.write(File.join(root, "app/views/admin/posts/_post.html.erb"), "<%= post.id %>\n")
        File.write(File.join(root, "app/views/admin/posts/show.html.erb"), <<~ERB)
          <% @post.fields(:visible).each do |field| %><%= render field %><% end %>
          <% Post.fields(:x).each do |post| %><%= render post %><% end %>
          <% @survey.fields :public do |field| %><%= render field %><% end %>
        ERB
        refs = described_class.new(RailsAiContext::StaticApp.new(root)).call[:templates]["admin/posts/show.html.erb"][:partials]
        expect(refs).to eq([ "admin/fields/field", "admin/posts/post" ])
      end
    end

    it "reads fields on a builder handed to a partial as a local as the builder's, and a local record's chained fields as records" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "app/models"))
        FileUtils.mkdir_p(File.join(root, "app/views/admin/posts"))
        FileUtils.mkdir_p(File.join(root, "app/views/admin/fields"))
        File.write(File.join(root, "app/models/field.rb"), "class Field < ApplicationRecord; end\n")
        File.write(File.join(root, "app/views/admin/fields/_field.html.erb"), "<%= field.id %>\n")
        File.write(File.join(root, "app/views/admin/posts/_form.html.erb"), "<%= form.text_field :name %>\n")
        File.write(File.join(root, "app/views/admin/posts/_address_fields.html.erb"),
                   "<%= f.fields :address do |address| %><%= render address %><% end %>\n" \
                   "<% post = Post.new %><% post.fields(:visible).each do |field| %><%= render field %><% end %>\n")
        refs = described_class.new(RailsAiContext::StaticApp.new(root)).call[:partials]["admin/posts/_address_fields.html.erb"][:partials]
        expect(refs).to eq([ "form", "admin/fields/field" ])
      end
    end

    it "reads fields on a local the template assigns or a plain block binds as the record's, never the builder's" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "app/models"))
        FileUtils.mkdir_p(File.join(root, "app/views/admin/posts"))
        FileUtils.mkdir_p(File.join(root, "app/views/admin/fields"))
        File.write(File.join(root, "app/models/field.rb"), "class Field < ApplicationRecord; end\n")
        File.write(File.join(root, "app/views/admin/fields/_field.html.erb"), "<%= field.id %>\n")
        File.write(File.join(root, "app/views/admin/posts/_form.html.erb"), "<%= form.text_field :name %>\n")
        {
          "r1" => "<% post = Post.new %><% post.fields :visible do |field| %><%= render field %><% end %>\n",
          "r2" => "<% post = Post.new %><% post.fields(:visible) do |field| %><%= render field %><% end %>\n",
          "r3" => "<% [Post.new].each do |post| %><% post.fields(:x) { |field| %><%= render field %><% } %><% end %>\n"
        }.each { |name, erb| File.write(File.join(root, "app/views/admin/posts/#{name}.html.erb"), erb) }
        templates = described_class.new(RailsAiContext::StaticApp.new(root)).call[:templates]
        %w[r1 r2 r3].each { |name| expect(templates["admin/posts/#{name}.html.erb"][:partials]).to eq([ "admin/fields/field" ]), name }
      end
    end

    it "reads fields on a builder handed in, or assigned one, as the builder's, whatever a script or another block binds" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "app/views/admin/posts"))
        File.write(File.join(root, "app/views/admin/posts/_form.html.erb"), "<%= form.text_field :name %>\n")
        {
          "_inner6.html.erb" => %(<%= form.fields :extra do |ef| %><%= render ef %><% end %>\n<script>const form = document.querySelector("form");</script>\n),
          "_inner7.html.erb" => "<% [1].each do |f| %><% end %>\n<%= f.fields :extra do |ef| %><%= render ef %><% end %>\n",
          "_slim.html.slim" => "button form=dom_id(@p)\n= form.fields :extra do |ef|\n  = render ef\n",
          "q1.html.erb" => %(<%= form_with model: Post.new, url: "/x" do |form| %><% f = form %><%= f.fields :extra do |ef| %><%= render ef %><% end %><% end %>\n)
        }.each { |name, source| File.write(File.join(root, "app/views/admin/posts", name), source) }
        result = described_class.new(RailsAiContext::StaticApp.new(root)).call
        %w[_inner6.html.erb _inner7.html.erb _slim.html.slim].each { |name| expect(result[:partials]["admin/posts/#{name}"][:partials]).to eq([ "form" ]), name }
        expect(result[:templates]["admin/posts/q1.html.erb"][:partials]).to eq([ "form" ])
      end
    end

    it "reads no partial off a file beside the views that no template handler renders" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "app/views/admin/posts"))
        File.write(File.join(root, "app/views/admin/posts/index.html.erb"), "<% Post.all.each do |post| %><%= render post %><% end %>\n")
        File.write(File.join(root, "app/views/admin/posts/_post.html.erb.orig"), "<%= post.id %>\n")
        refs = described_class.new(RailsAiContext::StaticApp.new(root)).call[:templates]["admin/posts/index.html.erb"][:partials]
        expect(refs).to eq([ "post" ])
      end
    end

    it "reads a loop variable after prose naming fields as the record it is, not a form builder" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "app/views/admin/posts"))
        File.write(File.join(root, "app/views/admin/posts/text.html.erb"), "<p>All fields</p><% @posts.each do |post| %><%= render post %><% end %>\n")
        File.write(File.join(root, "app/views/admin/posts/_post.html.erb"), "<%= post.id %>\n")
        refs = described_class.new(RailsAiContext::StaticApp.new(root)).call[:templates]["admin/posts/text.html.erb"][:partials]
        expect(refs).to eq([ "admin/posts/post" ])
      end
    end

    it "reads a lone record ivar whose class has no file here as that class's default partial, prefixed as Rails prefixes it" do
      Dir.mktmpdir do |root|
        %w[admin/widgets admin/posts posts].each { |dir| FileUtils.mkdir_p(File.join(root, "app/views", dir)) }
        File.write(File.join(root, "app/views/admin/widgets/show.html.erb"), "<%= render @posts %>\n")
        File.write(File.join(root, "app/views/admin/posts/_post.html.erb"), "<%= post.id %>\n")
        File.write(File.join(root, "app/views/posts/_post.html.erb"), "<%= post.id %>\n")
        static = RailsAiContext::StaticApp.new(root)
        expect(described_class.new(static).call[:templates]["admin/widgets/show.html.erb"][:partials]).to eq([ "admin/posts/post" ])

        FileUtils.mkdir_p(File.join(root, "config"))
        File.write(File.join(root, "config/application.rb"),
                   "class App < Rails::Application\n  config.action_view.prefix_partial_path_with_controller_namespace = false\nend\n")
        expect(described_class.new(static).call[:templates]["admin/widgets/show.html.erb"][:partials]).to eq([ "posts/post" ])
      end
    end

    it "names no partial for a lone record ivar when no model file names its class and its default partial is not on disk" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "app/views/admin/widgets"))
        File.write(File.join(root, "app/views/admin/widgets/show.html.erb"), "<%= render @warnings %>\n")
        File.write(File.join(root, "app/views/admin/widgets/_warnings.html.erb"), "x\n")
        refs = described_class.new(RailsAiContext::StaticApp.new(root)).call[:templates]["admin/widgets/show.html.erb"][:partials]
        expect(refs).to eq([])
      end
    end

    it "reads a lone local whose class has no model file as that class's default partial when the partial is on disk" do
      Dir.mktmpdir do |root|
        %w[admin/widgets admin/posts].each { |dir| FileUtils.mkdir_p(File.join(root, "app/views", dir)) }
        File.write(File.join(root, "app/views/admin/widgets/show.html.erb"), "<% Post.all.each do |post| %><%= render post %><% end %>\n")
        File.write(File.join(root, "app/views/admin/widgets/_post.html.erb"), "<%= post.id %>\n")
        File.write(File.join(root, "app/views/admin/posts/_post.html.erb"), "<%= post.id %>\n")
        refs = described_class.new(RailsAiContext::StaticApp.new(root)).call[:templates]["admin/widgets/show.html.erb"][:partials]
        expect(refs).to eq([ "admin/posts/post" ])
      end
    end

    it "reads a lone name's class in the view folder's namespace first, as Ruby finds it from a controller nested in that module" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "app/views/admin/widgets"))
        FileUtils.mkdir_p(File.join(root, "app/models/admin"))
        FileUtils.mkdir_p(File.join(root, "config"))
        File.write(File.join(root, "app/models/audit_entry.rb"), "class AuditEntry < ApplicationRecord\nend\n")
        File.write(File.join(root, "app/models/admin/audit_entry.rb"), "class Admin::AuditEntry < ApplicationRecord\nend\n")
        File.write(File.join(root, "app/views/admin/widgets/show.html.erb"), "<%= render @audit_entries %>\n")
        File.write(File.join(root, "config/application.rb"),
                   "class App < Rails::Application\n  config.action_view.prefix_partial_path_with_controller_namespace = false\nend\n")
        refs = described_class.new(RailsAiContext::StaticApp.new(root)).call[:templates]["admin/widgets/show.html.erb"][:partials]
        expect(refs).to eq([ "admin/audit_entries/audit_entry" ])
      end
    end

    it "reads a lone name's class only from the model directories, so a service under the view's namespace holds no records" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "app/views/admin/widgets"))
        FileUtils.mkdir_p(File.join(root, "app/services/admin"))
        FileUtils.mkdir_p(File.join(root, "app/models"))
        FileUtils.mkdir_p(File.join(root, "config"))
        File.write(File.join(root, "app/models/comment.rb"), "class Comment < ApplicationRecord\nend\n")
        File.write(File.join(root, "app/services/admin/comment.rb"), "module Admin\n  class Comment\n  end\nend\n")
        File.write(File.join(root, "app/views/admin/widgets/show.html.erb"), "<%= render @comments %>\n")
        File.write(File.join(root, "config/application.rb"),
                   "class App < Rails::Application\n  config.action_view.prefix_partial_path_with_controller_namespace = false\nend\n")
        refs = described_class.new(RailsAiContext::StaticApp.new(root)).call[:templates]["admin/widgets/show.html.erb"][:partials]
        expect(refs).to eq([ "comments/comment" ])
      end
    end

    it "prefixes a record's partial with the namespace of the view's folder, unless the app turns that off" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "app/views/admin/posts"))
        FileUtils.mkdir_p(File.join(root, "config"))
        FileUtils.mkdir_p(File.join(root, "app/models"))
        File.write(File.join(root, "app/models/comment.rb"), "class Comment < ApplicationRecord\nend\n")
        File.write(File.join(root, "app/views/admin/posts/show.html.erb"), "<%= render @comments %>\n")
        static = RailsAiContext::StaticApp.new(root)
        expect(described_class.new(static).call[:templates]["admin/posts/show.html.erb"][:partials]).to eq([ "admin/comments/comment" ])

        File.write(File.join(root, "config/application.rb"),
                   "class App < Rails::Application\n  config.action_view.prefix_partial_path_with_controller_namespace = false\nend\n")
        expect(described_class.new(static).call[:templates]["admin/posts/show.html.erb"][:partials]).to eq([ "comments/comment" ])
      end
    end

    it "reads a chain on a receiver that is no model from the records it names, when the app has that model" do
      expect(introspector.send(:extract_partial_refs, "<%= render current_user.comments.recent %>")).to eq([ "comments/comment" ])
      expect(introspector.send(:extract_partial_refs, "<%= render current_account.widgets %>")).to be_empty
    end

    it "still detects render @ivar" do
      source = "<%= render @post %>"
      expect(introspector.send(:extract_partial_refs, source)).to include("posts/post")
    end

    it "does not mistake keyword-argument hashes for a bare local render" do
      source = <<~ERB
        <%= render partial: "article", locals: { article: article } %>
        <%= render json: { ok: true } %>
        <%= render layout: false %>
      ERB
      refs = introspector.send(:extract_partial_refs, source)
      expect(refs).to include("article")
      expect(refs).not_to include("json")
      expect(refs).not_to include("layout")
      expect(refs).not_to include("partial")
      expect(refs).not_to include("locals")
    end

    it "does not match a symbol action render (render :new)" do
      source = "<%= render :new %>"
      expect(introspector.send(:extract_partial_refs, source)).to be_empty
    end
  end

  describe ".phlex_view?" do
    it "is false when the class and view_template appear only in comments" do
      expect(described_class.phlex_view?("app/views/posts/x.rb", "# class A < B\n# def view_template\n")).to be(false)
    end
  end

  describe ".extract_phlex_component_renders" do
    it "reads no component out of a comment" do
      expect(described_class.extract_phlex_component_renders("# render OldComponent.new\nrender NewComponent.new\n")).to eq(%w[NewComponent])
    end
  end

  describe ".extract_phlex_helper_calls" do
    it "reads no helper out of a comment or a string the view prints" do
      source = %(# uses link_to later\nh1 { "Edit tag" }\nplain dom_id(@post)\n)

      expect(described_class.extract_phlex_helper_calls(source)).to eq(%w[dom_id])
    end
  end

  describe ".ivars_in" do
    it "reads the ivars a template uses" do
      expect(described_class.ivars_in("<%= @post.title %> <%= @user %>")).to eq(%w[post user])
    end

    it "reads a code tag whose first line is a Ruby comment" do
      expect(described_class.ivars_in("<%\n  # the list\n  items = @posts.select(&:published?)\n%>")).to eq(%w[posts])
      expect(described_class.ivars_in("<% # note\n @x.each do |y| %>")).to eq(%w[x])
    end

    it "reads no ivar out of a Ruby comment inside a code tag" do
      expect(described_class.ivars_in("<% x = 1 # @ghost %>", path: "a.html.erb")).to eq([])
      expect(described_class.ivars_in("<%\n  # @legacy = 1\n%>", path: "a.html.erb")).to eq([])
    end

    it "reads no ivar out of a comment in a Ruby view" do
      template = "class Show < Phlex::HTML\n  # uses @label\n  def view_template = h1 { @post.title } # and @other\nend\n"

      expect(described_class.ivars_in(template, path: "app/views/posts/show.rb")).to eq(%w[post])
    end

    it "drops the locals ERB sets itself" do
      expect(described_class.ivars_in("<%= @output_buffer %><%= @post %>")).to eq(%w[post])
    end

    it "does not read an email address as an ivar" do
      expect(described_class.ivars_in("Mail us at user@example.com")).to eq([])
    end

    # `:'@1x'` is a symbol literal naming a Paperclip style, and a Ruby ivar
    # cannot start with a digit.
    it "does not read a quoted symbol starting with a digit as an ivar" do
      expect(described_class.ivars_in("= image_tag file&.url(:'@1x'), alt: @post.title")).to eq(%w[post])
    end

    # A chat handle inside a quoted Ruby string is text the template prints,
    # not a variable the controller assigns.
    it "does not read a word inside a quoted string as an ivar" do
      template = "<%= status.include?('sent') ? '' : '<@U12345ABC> ' %>\nOwner: <@<%= owner.id %>>\n"

      expect(described_class.ivars_in(template, path: "notify.text.erb")).to eq([])
    end

    it "does not read one inside a double-quoted string either" do
      expect(described_class.ivars_in(%(<%= "ping @U12345ABC" %>))).to eq([])
    end

    # Interpolation is code, and an ivar read inside it is a real read.
    it "still reads an ivar interpolated into a string" do
      expect(described_class.ivars_in(%(<%= "hello #{'#'}{@user.name}" %>))).to eq(%w[user])
    end

    # Ruby interpolates `"#@ivar"` too, and an escaped `\#{` is text.
    it "reads an ivar interpolated by its sigil and none behind an escaped interpolation" do
      expect(described_class.ivars_in(%(<%= "by #{'#'}@author" %>))).to eq(%w[author])
      expect(described_class.ivars_in(%(<%= "\\#{'#'}{@shown}" %>))).to eq([])
    end

    # A quote inside the interpolation does not end the string around it.
    it "reads an ivar in an interpolation that has a quoted string of its own" do
      expect(described_class.ivars_in(%(<%= "var x = '#{'#'}{render(@thing, { as: "row" })}';" %>))).to eq(%w[thing])
      expect(described_class.ivars_in(%(= js "var x = '#{'#'}{render(@thing, { as: "row" })}';"\n), path: "a.html.haml")).to eq(%w[thing])
    end

    # An unclosed quote before many interpolations doubled the time per interpolation,
    # and a run of opened ones was tried again from every quote.
    it "reads a line of unclosed strings and interpolations in a fraction of a second", :cpu_timed do
      [ %(<%= "x #{'#{a} ' * 30}%>), %(<%= #{'"#{' * 30_000} %>) ].each do |template|
        expect(cpu_seconds { described_class.ivars_in(template, path: "a.html.erb") }).to be < 2
      end
    end

    it "reads 100,000 characters of a non-ASCII string with interpolations in ERB and in a HAML attribute hash in a fraction of a second", :cpu_timed do
      text = "日本\#{@a}語" * 10_000
      { %(<%= "#{text}" %>) => "a.html.erb", %(%a{title: "#{text}"}\n) => "a.html.haml" }.each do |template, path|
        ivars = nil
        expect(cpu_seconds { ivars = described_class.ivars_in(template, path: path) }).to be < 1
        expect(ivars).to eq(%w[a])
      end
    end

    # A HAML or Slim template is not Ruby: its prose carries apostrophes, and
    # treating those as string quotes swallows everything between them.
    it "keeps reading ivars in a template whose prose has apostrophes" do
      template = "%p Don't stop\n= @user.name\n%p We can't win\n= @order.total\n"

      expect(described_class.ivars_in(template, path: "app/views/posts/show.html.haml")).to eq(%w[order user])
    end

    # Ruby in a HAML or Slim view sits in attribute lists, object refs,
    # multi-line hashes, continued calls and filters, not only after `=`.
    it "reads ivars wherever a HAML or Slim view writes Ruby" do
      {
        "a.html.haml" => [ "%a(href=@url) Link\n", %w[url] ],
        "b.html.haml" => [ "%div[@post]\n", %w[post] ],
        "c.html.haml" => [ "%a{href: foo,\n   title: @bar}\n", %w[bar] ],
        "d.html.haml" => [ %(= link_to "x",\n    @thing_path\n), %w[thing_path] ],
        "e.html.haml" => [ "= call_me(@a, |\n    @b) |\n", %w[a b] ],
        "f.html.haml" => [ ":ruby\n  x = @filtered\n", %w[filtered] ],
        "g.html.slim" => [ %(= link_to "x", \\\n  @thing\n), %w[thing] ],
        "h.html.slim" => [ "div *@attrs\n", %w[attrs] ],
        "i.html.slim" => [ "a href=@url = @title\n", %w[title url] ]
      }.each do |name, (template, ivars)|
        expect(described_class.ivars_in(template, path: "app/views/posts/#{name}")).to eq(ivars), name
      end
    end

    # Page text, a tag name and a comment are markup: only what the text
    # interpolates is code.
    it "reads no ivar from a HAML or Slim view's text, tags or comments" do
      {
        "a.html.haml" => [ "%p Write to info@example.com or follow @shop\n%h1= @post.title\n%p Hi \#{@user.name}\n", %w[post user] ],
        "b.html.haml" => [ "/ ask @admin\n-# @hidden\n  @hidden_too\n\\= @escaped\n%p== Hi \#{@name}, @nobody\n", %w[name] ],
        "c.html.haml" => [ "%p Total: \#@count\n%a(title=\"By \#{@author.name} for @team\") Link\n", %w[author count] ],
        "d.html.haml" => [ ":javascript\n  var shop = '@shop', id = \#{@post.id};\n:erb\n  <%= @erb %> and @text\n", %w[erb post] ],
        "e.html.haml" => [ "!!! 5\n%html{lang: @locale}\n  %p Follow @shop |\n    on the web |\n", %w[locale] ],
        "f.html.slim" => [ "p Write to info@example.com or follow @shop\nh1 = @post.title\np Hi \#{@user.name}\n", %w[post user] ],
        "g.html.slim" => [ "/ ask @admin\n  and @hidden\n| Follow @shop and \#{@user.name}\n  on the web @team\n", %w[user] ],
        "h.html.slim" => [ "p Hello @no\n  more text @no_either\n- if @show\n  li: a href=@link Link to @nothing\n", %w[link show] ],
        "i.html.slim" => [ "a href=\"/u/\#{@user.id}\" title=\"@no\" Link\na(href=@url\n  title=@title) Link\n", %w[title url user] ],
        "j.html.slim" => [ "javascript:\n  var shop = '@shop', id = \#{@post.id};\nruby:\n  x = @ruby\n", %w[post ruby] ]
      }.each do |name, (template, ivars)|
        expect(described_class.ivars_in(template, path: "app/views/posts/#{name}")).to eq(ivars.sort), name
      end
    end

    # A line the HAML or Slim reader cannot place is read whole, so no Ruby in it is lost.
    it "reads a HAML or Slim line it cannot parse whole" do
      expect(described_class.ivars_in("%a{href: @unclosed\n", path: "app/views/posts/a.html.haml")).to eq(%w[unclosed])
      expect(described_class.ivars_in("&nbsp; @kept\n", path: "app/views/posts/a.html.slim")).to eq(%w[kept])
    end

    # Two ERB comments with apostrophes in them are not one string literal,
    # and reading them as one deleted every ivar in between.
    it "keeps reading ivars around apostrophes in ERB comments" do
      template = "<% # don't do this %>\n<h1><%= @user.name %></h1>\n<% # it won't work %>\n<p><%= @order.total %></p>\n"

      expect(described_class.ivars_in(template, path: "app/views/posts/show.html.erb")).to eq(%w[order user])
    end

    # A Jbuilder or Builder template is Ruby from the first line, so a
    # handle in a quoted string is text there too.
    it "does not read a word inside a quoted string in a Ruby template" do
      %w[show.json.jbuilder feed.xml.builder index.html.ruby].each do |name|
        template = %(json.note "ping @U12345ABC"\njson.title @post.title\n)

        expect(described_class.ivars_in(template, path: "app/views/posts/#{name}")).to eq(%w[post]), name
      end
    end

    # Whichever quote opens first owns the literal: an apostrophe inside a
    # double-quoted string paired with the next single quote on the line and
    # swallowed the ivar between them.
    it "reads an ivar beside a double-quoted string holding an apostrophe" do
      template = %(<%= link_to "Don't delete", post_path(@post), class: 'btn' %>)

      expect(described_class.ivars_in(template, path: "app/views/posts/show.html.erb")).to eq(%w[post])
    end

    it "still reads ivars that legally start with an underscore or a capital" do
      expect(described_class.ivars_in("<%= @_private %><%= @Thing %>")).to eq(%w[Thing _private])
    end

    it "does not read a class variable as an ivar" do
      expect(described_class.ivars_in("<%= @@count %>")).to eq([])
    end

    # `@page` is a CSS at-rule, not an ivar the controller assigned.
    it "reads only the Ruby inside ERB tags" do
      erb = "<style>@page { size: A4; }</style>\n<%= render partial: 'x', locals: { p: @prediction } %>"

      expect(described_class.ivars_in(erb)).to eq(%w[prediction])
    end

    it "still reads a template with no ERB tags" do
      expect(described_class.ivars_in("%h1= @post.title")).to eq(%w[post])
    end
  end

  # Only app/views/layouts holds layouts. Testing the path on disk dropped an
  # Admin::LayoutsController's templates, and every template of an app checked
  # out under a folder named layouts.
  describe "a folder named layouts outside app/views/layouts" do
    around do |example|
      Dir.mktmpdir("view-templates") do |dir|
        @root = File.join(dir, "layouts/shop")
        { "layouts/application.html.erb" => "<%= yield %>\n",
          "posts/index.html.erb" => "<%= @posts.size %>\n",
          "admin/layouts/index.html.erb" => "<%= @layouts.size %>\n" }.each do |relative, body|
          FileUtils.mkdir_p(File.dirname(File.join(@root, "app/views", relative)))
          File.write(File.join(@root, "app/views", relative), body)
        end
        example.run
      end
    end

    it "lists every template but the layouts" do
      templates = described_class.new(RailsAiContext::StaticApp.new(@root)).call[:templates]

      expect(templates.keys.sort).to eq([ "admin/layouts/index.html.erb", "posts/index.html.erb" ])
    end
  end

  # An app that keeps a logo or a seed file under app/views had them counted
  # as templates, with ivar names read out of the image's bytes.
  describe "a file under app/views that no handler renders" do
    around do |example|
      Dir.mktmpdir("view-templates") do |dir|
        @root = dir
        FileUtils.mkdir_p(File.join(dir, "app/views/pdfs"))
        File.write(File.join(dir, "app/views/pdfs/summary.html.erb"), "<style>@page { size: A4; }</style>\n")
        File.write(File.join(dir, "app/views/pdfs/_fields.html.erb"), "<p><%= prediction.profit %></p>\n")
        File.binwrite(File.join(dir, "app/views/pdfs/logo.png"), "\x89PNG\r\n\x1A\n@alpha@beta".b)
        File.write(File.join(dir, "app/views/pdfs/notes.txt"), "Lorem ipsum\n")
        example.run
      end
    end

    let(:result) { described_class.new(RailsAiContext::StaticApp.new(@root)).call }

    it "counts only the templates" do
      expect(result[:templates].keys).to eq([ "pdfs/summary.html.erb" ])
      expect(result[:partials].keys).to eq([ "pdfs/_fields.html.erb" ])
    end

    # Unbooted there is no handler registry to ask, so a template a gem
    # renders has to be on the static floor or the app reads as having fewer
    # views than it has.
    it "keeps a template whose handler comes from a gem" do
      File.write(File.join(@root, "app/views/pdfs/index.rabl"), "object @post\n")

      expect(described_class.new(RailsAiContext::StaticApp.new(@root)).call[:templates].keys)
        .to include("pdfs/index.rabl")
    end

    it "reads no ivars out of an image" do
      expect(result[:templates]["pdfs/summary.html.erb"][:ivars]).to eq([])
    end
  end

  describe "a HAML view written with hashrocket data attributes" do
    it "reads the controllers it names" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "app/views/widgets"))
        File.write(File.join(root, "app/views/widgets/show.html.haml"),
                   %(%div{ "data-controller" => "hello" }\n%span{ :"data-controller" => "clip board" }\n))
        app = double("app", root: Pathname.new(root))

        stimulus = described_class.new(app).call[:templates]["widgets/show.html.haml"][:stimulus]

        expect(stimulus).to contain_exactly("hello", "clip", "board")
      end
    end
  end

  describe "a view calling url_for with a Rails controller" do
    it "does not read the routing controller as a Stimulus controller" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "app/views/widgets"))
        File.write(File.join(root, "app/views/widgets/index.html.erb"),
                   %(<%= link_to "Back", url_for(controller: "admin/editions", action: "index") %>\n) +
                   %(<div <%= tag.attributes(data: { controller: "hello" }) %>></div>\n))
        app = double("app", root: Pathname.new(root))

        stimulus = described_class.new(app).call[:templates]["widgets/index.html.erb"][:stimulus]

        expect(stimulus).to contain_exactly("hello")
      end
    end

    it "does not read url_for's controller: inside a data hash as a Stimulus controller" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "app/views/widgets"))
        File.write(File.join(root, "app/views/widgets/index.html.erb"),
                   %(<%= link_to "x", "#", data: { turbo_frame: "f", url: url_for(controller: "users") } %>\n) +
                   %(<%= tag.div data: { url: url_for(controller: "posts"), controller: "hello" } %>\n))
        app = double("app", root: Pathname.new(root))

        stimulus = described_class.new(app).call[:templates]["widgets/index.html.erb"][:stimulus]

        expect(stimulus).to contain_exactly("hello")
      end
    end
  end

  describe "a comment in the markup" do
    def templates_in(root)
      described_class.new(double("app", root: Pathname.new(root))).call[:templates]
    end

    it "reads no partial out of a HAML comment" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "app/views/admin"))
        File.write(File.join(root, "app/views/admin/create.turbo_stream.haml"),
                   "-# Pre-render the form\n= turbo_stream.replace \"x\" do\n  = render \"admin/form\"\n")

        expect(templates_in(root)["admin/create.turbo_stream.haml"][:partials]).to eq([ "admin/form" ])
      end
    end

    it "reads nothing out of the lines a HAML comment block covers" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "app/views/admin"))
        File.write(File.join(root, "app/views/admin/index.html.haml"),
                   "-# old markup\n  = render \"admin/legacy\"\n  %div{ \"data-controller\" => \"legacy\" }\n= render \"admin/current\"\n")

        entry = templates_in(root)["admin/index.html.haml"]

        expect(entry[:partials]).to eq([ "admin/current" ])
        expect(entry[:stimulus]).to eq([])
      end
    end

    it "reads no partial out of an ERB comment" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "app/views/admin"))
        File.write(File.join(root, "app/views/admin/show.html.erb"),
                   "<%# render \"admin/old\" and @stale_ivar %>\n<%= render \"admin/new\" %>\n")

        entry = templates_in(root)["admin/show.html.erb"]

        expect(entry[:partials]).to eq([ "admin/new" ])
        expect(entry[:ivars]).to eq([])
      end
    end

    # ERB inside an HTML comment still runs, so its render still happens.
    it "reads no Stimulus controller out of an HTML comment, and still reads the ERB inside it" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "app/views/admin"))
        File.write(File.join(root, "app/views/admin/edit.html.erb"),
                   %(<!-- <div data-controller="ghost"></div> <%= render "admin/kept" %> -->\n<div data-controller="real"></div>\n))

        entry = templates_in(root)["admin/edit.html.erb"]

        expect(entry[:stimulus]).to eq([ "real" ])
        expect(entry[:partials]).to eq([ "admin/kept" ])
      end
    end

    it "reads no slot out of a Ruby comment inside a code tag" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "app/views/admin"))
        File.write(File.join(root, "app/views/admin/card.html.erb"), %(<% # renders_one :header %>\n<% renders_many :items %>\n))

        expect(templates_in(root)["admin/card.html.erb"][:slots]).to eq([ "items" ])
      end
    end

    it "reads no partial key out of a Ruby comment inside a code tag" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "app/views/admin"))
        File.write(File.join(root, "app/views/admin/list.html.erb"), %(<% x = 1 # render partial: "old" %>\n<%= render "admin/new" %>\n))

        expect(templates_in(root)["admin/list.html.erb"][:partials]).to eq([ "admin/new" ])
      end
    end

    it "reads no component render out of a Ruby comment in a Phlex view" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "app/views/admin"))
        File.write(File.join(root, "app/views/admin/show.rb"),
                   "class Views::Admin::Show < Views::Base\n  def view_template\n    # render OldComponent.new\n    render NewComponent.new\n  end\nend\n")

        expect(templates_in(root)["admin/show.rb"][:partials]).to eq([ "NewComponent" ])
      end
    end
  end

  describe "a partial's fields and helpers" do
    def partial_entry(source)
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "app/views/posts"))
        File.write(File.join(root, "app/views/posts/_card.html.erb"), source)
        return described_class.new(double("app", root: Pathname.new(root))).call[:partials]["posts/_card.html.erb"]
      end
    end

    # ERB inside an HTML comment still runs; the comment's own text and page prose do not.
    it "reads model fields only from the Ruby the partial runs" do
      source = %(<!-- @user.legacy_field -->\n<p>Ping @support.desk</p>\n<!-- <%= @post.headline %> -->\n<%= @post.title %>\n)

      expect(partial_entry(source)[:fields]).to contain_exactly("headline", "title")
    end

    it "reads helper calls only from the Ruby the partial runs, not its strings" do
      source = %(<!-- render_badge -->\n<%= t(".format_hint") %>\n<!-- <%= format_price(1) %> -->\n<%= render_avatar(@user) %>\n)

      expect(partial_entry(source)[:helpers]).to contain_exactly("format_price", "render_avatar")
    end
  end

  describe ".stimulus_identifiers reading action descriptors" do
    {
      %(<a data-action="backlogs--work-package#openSplitPane:prevent">) => %w[backlogs--work-package],
      %(<a data-action="click->menu#toggle:stop:once">) => %w[menu],
      %(<input data-action="keydown.enter->search#submit keydown.ctrl+s->search#save">) => %w[search],
      %(<div data-action="click->tabs#show keydown.esc->modal#close:prevent">) => %w[tabs modal],
      %(<%= link_to "x", data: { action: "resize@window->chart#redraw:passive" } %>) => %w[chart]
    }.each do |markup, identifiers|
      it "reads #{identifiers.join(' and ')} from #{markup}" do
        expect(described_class.stimulus_identifiers(markup)).to include(*identifiers)
      end
    end

    it "reads no identifier out of an unquoted word#word in prose" do
      expect(described_class.stimulus_identifiers(%(<p>see users#show for the page</p>))).to eq([])
    end

    it "reads no identifier out of a Ruby comment" do
      source = %(# See "posts#index" for more\nclass Card\n  def data = { action: "card#open" }\nend\n)

      expect(described_class.stimulus_identifiers(source, ruby: true)).to eq([ "card" ])
    end

    it "reads no identifier out of prose with a hash in it" do
      expect(described_class.stimulus_identifiers(%(<p>Issue #42 and C# code</p>))).to eq([])
    end

    it "reads a heredoc line that starts with # in a Ruby view" do
      source = %(HTML = <<~H\n  # <div data-controller="chart"></div>\nH\n)

      expect(described_class.stimulus_identifiers(source, ruby: true)).to eq([ "chart" ])
    end

    it "reads a controller helper's identifier only where Ruby calls the helper" do
      markup = %(<% hint = "call body_controller('ghost')" %>\n<% content_controller "real" %>\n)
      ruby = %(class Page\n  HINT = "content_controller('ghost')"\n  def call = body_controller("real")\nend\n)

      expect(described_class.stimulus_identifiers(markup)).to eq([ "real" ])
      expect(described_class.stimulus_identifiers(%(<%= a %><%= b %><%= c %><%= d %><% content_controller "late" %>))).to eq([ "late" ])
      expect(described_class.stimulus_identifiers(%(<p>content_controller("text")</p><% x = 1 %>))).to eq([])
      expect(described_class.stimulus_identifiers(ruby, ruby: true)).to eq([ "real" ])
    end
  end

  describe "the partials a render call names" do
    def partials_in(name, source)
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "app/views/products"))
        File.write(File.join(root, "app/views/products", name), source)
        return described_class.new(double("app", root: Pathname.new(root))).call[:templates]["products/#{name}"][:partials]
      end
    end

    {
      "render with parentheses and a keyword" => [ "create.turbo_stream.haml",
        %(- row = render(partial: 'variant_row', formats: :html,\n    locals: { f: f })\n= render(partial: 'admin/shared/flashes', locals: { flashes: flash })\n),
        %w[variant_row admin/shared/flashes] ],
      "a positional string with and without parentheses" => [ "show.html.erb",
        %(<%= render 'header' %>\n<%= render("footer", locals: {}) %>\n), %w[header footer] ],
      "partial: after collection:" => [ "index.html.erb",
        %(<%= render collection: @items, partial: "item" %>\n), %w[item] ],
      "a keyword argument spread over lines without parentheses" => [ "edit.html.slim",
        %(= render partial: "form",\n  locals: { product: @product }\n), %w[form] ],
      "a template and a hashrocket partial" => [ "new.html.erb",
        %(<%= render template: "products/base" %>\n<%= render :partial => "legacy" %>\n), %w[products/base legacy] ],
      # bazaar's reviews/create.turbo_stream.erb listed only reviews/form.
      "a turbo_stream action's partial" => [ "update.turbo_stream.erb",
        %(<%= turbo_stream.replace @product, partial: "products/product", locals: { product: @product } %>\n), %w[products/product] ],
      "jbuilder's json.partial! and json.array! partial:" => [ "index.json.jbuilder",
        %(json.array! @products, partial: "products/product", as: :product\njson.partial! "shared/meta", page: 1\n),
        %w[products/product shared/meta] ]
    }.each do |label, (name, source, expected)|
      it "reads #{label}" do
        expect(partials_in(name, source)).to include(*expected)
      end
    end

    it "reads no partial out of a keyword nested inside another argument" do
      source = %(<%= render(ModalComponent.new(template: "big")) %>\n<%= render "form", locals: { template: "edit", partial: "y" } %>\n)

      expect(partials_in("nested.html.erb", source)).to contain_exactly("form", "ModalComponent")
    end

    it "reads no partial out of a key in another helper's hash argument" do
      source = %(<%= link_to "Teaser", teaser_path, data: { partial: "teaser" } %>\n) +
               %(<% @products.each { |product| %><%= turbo_stream.replace product, partial: "products/row" %><% } %>\n)

      expect(partials_in("teaser.html.erb", source)).to eq([ "products/row" ])
    end

    it "keeps reading past an escaped quote in an argument" do
      expect(partials_in("escaped.html.erb", %{<%= render(object: "a \\" (b", partial: "real") %>\n})).to eq([ "real" ])
    end

    it "does not read a partial name built at runtime" do
      expect(partials_in("preview.html.erb", %(<%= render(partial: "mailer/\#{@system_email}") %>\n))).to eq([])
    end

    it "does not read a JavaScript render method in an inline script" do
      expect(partials_in("captcha.html.erb", %(<script>turnstile.render('#turnstile-container', {});</script>\n)))
        .to eq([])
    end

    it "does not read a string that is not an argument to render" do
      expect(partials_in("form.html.erb", %(<%= form_with layout: "horizontal" %>\n<%= render product %>\n)))
        .to eq([ "product" ])
    end
  end

  describe ".ruby_identifiers and the shared parse cache" do
    it "parses once without filling the cache other introspectors reuse" do
      RailsAiContext::AstCache.clear

      found = described_class.ruby_identifiers(%(class Card\n  def call = tag.div(data: { controller: "card" })\nend\n))

      expect(found).to eq([ "card" ])
      expect(RailsAiContext::AstCache.size).to eq(0)
    end

    it "works in a fresh process where nothing has loaded Prism yet" do
      script = %(require "rails_ai_context"; print RailsAiContext::Introspectors::ViewTemplateIntrospector) +
               %(.ruby_identifiers(%q(x = tag.div(data: { controller: "card" }))).join)
      out, err, status = Open3.capture3(RbConfig.ruby, "-I", File.expand_path("../../../../lib", __dir__), "-e", script)

      expect([ out, status.success? ]).to eq([ "card", true ]), err
    end

    it "does not parse a file that names no data hash at all" do
      allow(Prism).to receive(:parse).and_call_original

      described_class.ruby_identifiers(%(redirect_to controller: "posts"\n))

      expect(Prism).not_to have_received(:parse)
    end
  end

  describe ".stimulus_identifiers reading action values only" do
    it "reads an action after an apostrophe in the page text" do
      markup = %(<p>Don't worry</p>\n<button data-action="click->modal#open">x</button>\n<p>It's fine.</p>\n)

      expect(described_class.stimulus_identifiers(markup)).to eq([ "modal" ])
    end

    it "reads an action from a HAML hash, a data hash and an app's own *_actions key" do
      markup = %(%a{ "data-action" => "click->menu#toggle" }\n) +
               %(<%= link_to "x", "/", data: { action: "tabs#show" } %>\n) +
               %(<%= render ConfirmModal.new(confirm_actions: "click->modal#close") %>\n)

      expect(described_class.stimulus_identifiers(markup)).to contain_exactly("menu", "tabs", "modal")
    end

    it "reads action keys in markup by the same rule as in Ruby" do
      markup = %(<%= render Autocompleter.new(hiddenFieldAction: "change->reporting--page#select") %>\n) +
               %(<%= route_list(action: "posts#index") %>\n) +
               %(<%= link_to "x", "/", data: { action: "tabs#show" } %>\n)
      ruby = %(class Page\n  def a = render(Autocompleter.new(hiddenFieldAction: "change->reporting--page#select"))\n) +
             %(  def b = route_list(action: "posts#index")\n  def c = link_to("x", "/", data: { action: "tabs#show" })\nend\n)

      expect(described_class.stimulus_identifiers(markup)).to contain_exactly("reporting--page", "tabs")
      expect(described_class.stimulus_identifiers(ruby, ruby: true)).to contain_exactly("reporting--page", "tabs")
    end

    it "reads no descriptor from a quoted value that is not an action" do
      markup = %(<a title="see users#show here" href="<%= url_for("posts#index") %>">x</a>\n)

      expect(described_class.stimulus_identifiers(markup)).to eq([])
    end

    it "reads Ruby actions under a camelCase key, in either branch of a conditional, and a controller set in a variable" do
      source = %(class Filter\n) +
               %(  def args = { hiddenFieldAction: "change->reporting--page#select" }\n) +
               %(  def act = (action = outlet? ? "check-all#all:stop" : "checkable#all:stop")\n) +
               %(  def initialize = @data_controller = "modal \#{@options.delete(:extra)}".squish\n) +
               %(  def reflex = { data: { reflex: "click->user#accept" } }\n) +
               %(end\n)

      expect(described_class.stimulus_identifiers(source, ruby: true))
        .to contain_exactly("reporting--page", "check-all", "checkable", "modal")
    end

    it "reads an action constant, and no route list under a bare actions: key" do
      source = %(class Scopes\n  REFRESH_ACTION = "change->refresh-on-form-changes#trigger"\n) +
               %(  SCOPES = { write: { actions: %w[posts#create topics#update] } }\nend\n)

      expect(described_class.stimulus_identifiers(source, ruby: true)).to eq([ "refresh-on-form-changes" ])
    end

    it "reads a bare action: key outside a data hash only when it has an event or an option" do
      source = %(class Panel\n  def button = { action: "click->meetings--submit#intercept" }\n) +
               %(  def scopes\n    actions = %w[list#category_feed list#latest_feed]\n  end\nend\n)

      expect(described_class.stimulus_identifiers(source, ruby: true)).to eq([ "meetings--submit" ])
    end

    it "reads Ruby actions through the AST, so a trailing comment names nothing" do
      source = %(class Card\n  def call = tag.div(data: { action: "card#open" }) # see "posts#index"\n) +
               %(  def link = url_for("users#show")\nend\n)

      expect(described_class.stimulus_identifiers(source, ruby: true)).to eq([ "card" ])
    end
  end
end
