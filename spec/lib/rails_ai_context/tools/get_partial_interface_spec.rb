# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Tools::GetPartialInterface do
  before { described_class.reset_cache! }

  # A partial's name was globbed as written: `{a,b}` was a choice, and each one doubled the lookups.
  describe "a name holding glob characters" do
    it "reads it as a name" do
      expect(described_class.call(partial: "posts/form").content.first[:text]).to start_with("# Partial: posts/_form")
      [ "{posts,x}/form", "posts/{form,x}", "{form,x}", "posts/_form*" ].each do |name|
        expect(described_class.call(partial: name).content.first[:text]).to start_with("Partial '#{name}' not found."), name
      end
    end

    it "answers one full of brace groups in the time any other takes", :cpu_timed do
      names = [ "{a,b}" * 24, "posts/#{'{a,b}' * 24}", "#{'{a,b}' * 24}/form" ]
      texts = nil
      expect(cpu_seconds { texts = names.map { |name| described_class.call(partial: name).content.first[:text] } }).to be < 5
      names.zip(texts).each { |name, text| expect(text).to include("not found."), name }
    end
  end

  describe "an instance variable or a method named like a local" do
    around do |example|
      Dir.mktmpdir("ivar-local") do |dir|
        @root = dir
        FileUtils.mkdir_p(File.join(dir, "app/views/shared"))
        FileUtils.mkdir_p(File.join(dir, "app/views/posts"))
        File.write(File.join(dir, "app/views/shared/_badge.html.erb"),
                   "<%= user.name %>\n<% if @user.admin? %>Admin<% end %>\n<%= @user&.email %> <%= post.user.avatar %>\n" \
                   "<%= user&.title %> <%= user&.to_s %>\n")
        File.write(File.join(dir, "app/views/posts/index.html.erb"), %(<%= render "shared/badge", user: current_user %>\n))
        example.run
      end
    end

    before do
      allow(RailsAiContext).to receive(:default_app).and_return(RailsAiContext::StaticApp.new(@root))
      allow(described_class).to receive(:cached_context).and_return({})
    end

    it "credits the local only with the calls made on the local itself, by . or &., less conversions" do
      text = described_class.call(partial: "shared/badge").content.first[:text]

      expect(text).to include("- **user** - calls: name, title\n")
    end
  end

  describe "an implicit render of a collection or record" do
    around do |example|
      Dir.mktmpdir("implicit-render") do |dir|
        @root = dir
        views = File.join(dir, "app/views")
        %w[admin/posts posts sessions shared].each { |d| FileUtils.mkdir_p(File.join(views, d)) }
        FileUtils.mkdir_p(File.join(dir, "app/models"))
        File.write(File.join(views, "admin/posts/index.html.erb"), "<%= render @posts %>\n")
        File.write(File.join(views, "admin/posts/_post.html.erb"), "<%= post.title %>\n")
        File.write(File.join(views, "posts/show.html.erb"), "<h1>Post</h1>\n\n<%= render @post %>\n")
        File.write(File.join(views, "posts/_post.html.erb"), "<%= post.title %>\n")
        File.write(File.join(views, "sessions/index.html.erb"), "<%= render @sessions %>\n")
        File.write(File.join(views, "shared/_session_row.html.erb"), "<%= session_row.id %>\n")
        File.write(File.join(dir, "app/models/session.rb"),
                   "class Session < ApplicationRecord\n  def to_partial_path\n    \"shared/session_row\"\n  end\nend\n")
        example.run
      end
    end

    before do
      allow(RailsAiContext).to receive(:default_app).and_return(RailsAiContext::StaticApp.new(@root))
      allow(described_class).to receive(:cached_context).and_return({})
    end

    def rendered_from(name)
      described_class.call(partial: name).content.first[:text][/## Rendered From.*?(?=\n\n|\z)/m]
    end

    it "credits a namespaced view to the partial under its namespace" do
      expect(rendered_from("admin/posts/post")).to eq("## Rendered From (1)\n- `app/views/admin/posts/index.html.erb:1`")
      expect(rendered_from("posts/post")).to eq("## Rendered From (1)\n- `app/views/posts/show.html.erb:3`")
    end

    it "credits a form builder rendered bare to the form partial beside the view, as Rails looks a bare name up" do
      FileUtils.mkdir_p(File.join(@root, "app/views/admin/widgets"))
      File.write(File.join(@root, "app/views/admin/widgets/edit.html.erb"), "<%= form_with model: @widget do |form| %>\n<%= render form %>\n<% end %>\n")
      File.write(File.join(@root, "app/views/admin/widgets/_form.html.erb"), "<%= form.text_field :name %>\n")

      expect(rendered_from("admin/widgets/form")).to eq("## Rendered From (1)\n- `app/views/admin/widgets/edit.html.erb:2`")
    end

    it "credits a form builder block parameter of any name to the form partial, as FormBuilder#to_partial_path names it" do
      FileUtils.mkdir_p(File.join(@root, "app/views/admin/widgets"))
      File.write(File.join(@root, "app/views/admin/widgets/edit.html.erb"), "<%= form_with model: @widget do |f| %>\n<%= render f %>\n<% end %>\n")
      File.write(File.join(@root, "app/views/admin/widgets/_form.html.erb"), "<%= form.text_field :name %>\n")

      expect(rendered_from("admin/widgets/form")).to eq("## Rendered From (1)\n- `app/views/admin/widgets/edit.html.erb:2`")
    end

    it "credits a form builder a brace block names to the form partial" do
      FileUtils.mkdir_p(File.join(@root, "app/views/admin/widgets"))
      File.write(File.join(@root, "app/views/admin/widgets/edit.html.erb"), %(<%= form_with(model: @widget, url: "/x") { |g| concat render(g) } %>\n))
      File.write(File.join(@root, "app/views/admin/widgets/_form.html.erb"), "<%= form.text_field :name %>\n")

      expect(rendered_from("admin/widgets/form")).to eq("## Rendered From (1)\n- `app/views/admin/widgets/edit.html.erb:1`")
    end

    it "credits a builder's block that follows a brace block inside the helper's arguments to the form partial" do
      FileUtils.mkdir_p(File.join(@root, "app/views/admin/widgets"))
      File.write(File.join(@root, "app/views/admin/widgets/edit.html.erb"),
                 %(<%= form_with model: @widget, url: "/x" do |f| %><%= f.fields_for :parts, [Part.new].reject { |c| c.nil? } do |cf| %>\n<%= render cf %>\n) +
                 %(<% end %><% end %>\n<%= form_with model: @widget, url: "/x", data: { ids: [1].map { |c| c } } do |g| %>\n<%= render g %>\n<% end %>\n))
      File.write(File.join(@root, "app/views/admin/widgets/_form.html.erb"), "<%= form.text_field :name %>\n")

      expect(rendered_from("admin/widgets/form")).to eq("## Rendered From (2)\n- `app/views/admin/widgets/edit.html.erb:2`\n- `app/views/admin/widgets/edit.html.erb:5`")
    end

    it "credits a record's fields iterated or given a block to the record's partial, never the form partial" do
      FileUtils.mkdir_p(File.join(@root, "app/views/admin/fields"))
      FileUtils.mkdir_p(File.join(@root, "app/views/admin/widgets"))
      File.write(File.join(@root, "app/models/field.rb"), "class Field < ApplicationRecord; end\n")
      File.write(File.join(@root, "app/views/admin/fields/_field.html.erb"), "<%= field.id %>\n")
      File.write(File.join(@root, "app/views/admin/widgets/_form.html.erb"), "<%= form.text_field :name %>\n")
      File.write(File.join(@root, "app/views/admin/widgets/show.html.erb"),
                 "<% @widget.fields(:visible).each do |field| %>\n<%= render field %>\n<% end %>\n" \
                 "<% @survey.fields :public do |field| %>\n<%= render field %>\n<% end %>\n")

      expect(rendered_from("admin/widgets/form")).to be_nil
      expect(rendered_from("admin/fields/field")).to eq("## Rendered From (2)\n- `app/views/admin/widgets/show.html.erb:2`\n- `app/views/admin/widgets/show.html.erb:5`")
    end

    it "credits fields on a builder handed to a partial as a local to the form partial" do
      FileUtils.mkdir_p(File.join(@root, "app/views/admin/widgets"))
      File.write(File.join(@root, "app/views/admin/widgets/edit.html.erb"),
                 %(<%= form_with model: @widget, url: "/x" do |f| %><%= render "address_fields", f: f %><% end %>\n))
      File.write(File.join(@root, "app/views/admin/widgets/_address_fields.html.erb"),
                 "<%= f.fields :address do |address| %>\n<%= render address %>\n<% end %>\n")
      File.write(File.join(@root, "app/views/admin/widgets/_form.html.erb"), "<%= form.text_field :name %>\n")

      expect(rendered_from("admin/widgets/form")).to eq("## Rendered From (1)\n- `app/views/admin/widgets/_address_fields.html.erb:2`")
    end

    it "credits fields on a local the view assigns or a plain block binds to the record's partial" do
      FileUtils.mkdir_p(File.join(@root, "app/views/admin/fields"))
      FileUtils.mkdir_p(File.join(@root, "app/views/admin/widgets"))
      File.write(File.join(@root, "app/models/field.rb"), "class Field < ApplicationRecord; end\n")
      File.write(File.join(@root, "app/views/admin/fields/_field.html.erb"), "<%= field.id %>\n")
      File.write(File.join(@root, "app/views/admin/widgets/_form.html.erb"), "<%= form.text_field :name %>\n")
      File.write(File.join(@root, "app/views/admin/widgets/show.html.erb"),
                 "<% widget = Widget.new %><% widget.fields :visible do |field| %>\n<%= render field %>\n<% end %>\n" \
                 "<% [Widget.new].each do |item| %><% item.fields(:x) { |field| %>\n<%= render field %>\n<% } %><% end %>\n")

      expect(rendered_from("admin/widgets/form")).to be_nil
      expect(rendered_from("admin/fields/field")).to eq("## Rendered From (2)\n- `app/views/admin/widgets/show.html.erb:2`\n- `app/views/admin/widgets/show.html.erb:5`")
    end

    it "credits fields on a builder handed in, or assigned one, to the form partial, whatever a script or another block binds" do
      FileUtils.mkdir_p(File.join(@root, "app/views/admin/widgets"))
      File.write(File.join(@root, "app/views/admin/widgets/_form.html.erb"), "<%= form.text_field :name %>\n")
      File.write(File.join(@root, "app/views/admin/widgets/_inner6.html.erb"),
                 %(<%= form.fields :extra do |ef| %>\n<%= render ef %>\n<% end %>\n<script>const form = document.querySelector("form");</script>\n))
      File.write(File.join(@root, "app/views/admin/widgets/_inner7.html.erb"),
                 "<% [1].each do |f| %><% end %>\n<%= f.fields :extra do |ef| %>\n<%= render ef %>\n<% end %>\n")
      File.write(File.join(@root, "app/views/admin/widgets/_slim.html.slim"), "button form=dom_id(@p)\n= form.fields :extra do |ef|\n  = render ef\n")
      File.write(File.join(@root, "app/views/admin/widgets/q1.html.erb"),
                 %(<%= form_with model: @widget, url: "/x" do |form| %><% f = form %><%= f.fields :extra do |ef| %>\n<%= render ef %>\n<% end %><% end %>\n))

      expect(rendered_from("admin/widgets/form")).to eq(
        "## Rendered From (4)\n- `app/views/admin/widgets/_inner6.html.erb:2`\n- `app/views/admin/widgets/_inner7.html.erb:3`\n" \
        "- `app/views/admin/widgets/_slim.html.slim:3`\n- `app/views/admin/widgets/q1.html.erb:2`"
      )
    end

    it "reads no form builder off a commented-out helper, as the view scan reads none" do
      File.write(File.join(@root, "app/views/posts/list.html.erb"),
                 "<%# form_with model: @post do |post| %>\n<% @posts.each do |post| %><%= render post %><% end %>\n")

      expect(rendered_from("posts/post")).to include("`app/views/posts/list.html.erb:2`")
    end

    it "credits a record's default partial kept in another view root, as Rails looks it up in every root" do
      FileUtils.mkdir_p(File.join(@root, "config"))
      File.write(File.join(@root, "config/application.rb"), "config.paths[\"app/views\"] << \"enterprise/app/views\"\n")
      FileUtils.mkdir_p(File.join(@root, "enterprise/app/views/admin/reports"))
      FileUtils.mkdir_p(File.join(@root, "app/views/admin/widgets"))
      File.write(File.join(@root, "enterprise/app/views/admin/reports/_report.html.erb"), "<%= report.id %>\n")
      File.write(File.join(@root, "app/views/admin/widgets/show.html.erb"), "<%= render @reports %>\n")
      allow(RailsAiContext::ViewFile).to receive(:each).and_call_original

      expect(rendered_from("admin/reports/report")).to eq("## Rendered From (1)\n- `app/views/admin/widgets/show.html.erb:1`")
      expect(RailsAiContext::ViewFile).to have_received(:each).with(@root, "**/_*").once
    end

    it "credits no partial named after a record ivar, as Rails never looks one up by the ivar's name" do
      FileUtils.mkdir_p(File.join(@root, "app/views/admin/widgets"))
      File.write(File.join(@root, "app/views/admin/widgets/show.html.erb"), "<%= render @warnings %>\n")
      File.write(File.join(@root, "app/views/admin/widgets/_warnings.html.erb"), "x\n")

      expect(rendered_from("admin/widgets/warnings")).to be_nil
    end

    it "follows a to_partial_path the model defines" do
      expect(rendered_from("shared/session_row")).to eq("## Rendered From (1)\n- `app/views/sessions/index.html.erb:1`")
      expect(rendered_from("session_row")).to eq("## Rendered From (1)\n- `app/views/sessions/index.html.erb:1`")
    end

    it "reads to_partial_path only off the model's own class, not a class nested in its file" do
      File.write(File.join(@root, "app/models/post.rb"),
                 "class Post < ApplicationRecord\n  class Row\n    def to_partial_path = \"shared/session_row\"\n  end\nend\n")

      expect(rendered_from("posts/post")).to eq("## Rendered From (1)\n- `app/views/posts/show.html.erb:3`")
    end

    it "drops the namespace when the app turns the prefix off" do
      FileUtils.mkdir_p(File.join(@root, "config"))
      File.write(File.join(@root, "config/application.rb"), <<~RUBY)
        module Demo
          class Application < Rails::Application
            config.action_view.prefix_partial_path_with_controller_namespace = false
          end
        end
      RUBY

      expect(rendered_from("admin/posts/post")).to be_nil
      expect(rendered_from("posts/post")).to include("app/views/admin/posts/index.html.erb:1", "app/views/posts/show.html.erb:3")
    end

    it "reads the prefix setting from a nested initializer, once per call however many view roots there are" do
      FileUtils.mkdir_p(File.join(@root, "config/initializers/views"))
      File.write(File.join(@root, "config/application.rb"), "config.paths[\"app/views\"] << \"app/views/extra\"\n")
      FileUtils.mkdir_p(File.join(@root, "app/views/extra"))
      File.write(File.join(@root, "config/initializers/views/partials.rb"),
                 "Rails.application.config.action_view.prefix_partial_path_with_controller_namespace = false\n")
      allow(RailsAiContext::Introspectors::SourceIntrospector).to receive(:walk).and_call_original

      expect(rendered_from("posts/post")).to include("app/views/admin/posts/index.html.erb:1")
      expect(RailsAiContext::Introspectors::SourceIntrospector).to have_received(:walk)
        .with(File.join(@root, "config/application.rb"), hash_including(:setting)).once
    end

    it "reads the prefix set on ActionView::Base, directly or in an on_load(:action_view) block" do
      FileUtils.mkdir_p(File.join(@root, "config/initializers"))
      File.write(File.join(@root, "config/initializers/pp.rb"), "ActionView::Base.prefix_partial_path_with_controller_namespace = false\n")
      expect(rendered_from("admin/posts/post")).to be_nil

      File.write(File.join(@root, "config/initializers/pp.rb"),
                 "ActiveSupport.on_load(:action_view) { self.prefix_partial_path_with_controller_namespace = false }\n")
      expect(rendered_from("admin/posts/post")).to be_nil
    end

    it "reads the environment file RACK_ENV names when RAILS_ENV is unset, as Rails does" do
      FileUtils.mkdir_p(File.join(@root, "config/environments"))
      File.write(File.join(@root, "config/environments/production.rb"),
                 "Rails.application.configure do\n  config.action_view.prefix_partial_path_with_controller_namespace = false\nend\n")
      allow(RailsAiContext).to receive(:static_tier?).and_return(true)
      saved = ENV.to_h.slice("RAILS_ENV", "RACK_ENV")
      begin
        ENV.delete("RAILS_ENV")
        ENV["RACK_ENV"] = "production"
        expect(rendered_from("admin/posts/post")).to be_nil
        expect(rendered_from("posts/post")).to include("app/views/admin/posts/index.html.erb:1")
      ensure
        ENV.delete("RACK_ENV")
        ENV.update(saved)
      end
    end

    it "asks ActionView::Base when the app is booted" do
      allow(RailsAiContext).to receive(:default_app).and_return(Struct.new(:root).new(Pathname.new(@root)))
      allow(ActionView::Base).to receive(:prefix_partial_path_with_controller_namespace).and_return(false)

      expect(rendered_from("admin/posts/post")).to be_nil
      expect(rendered_from("posts/post")).to include("app/views/admin/posts/index.html.erb:1")
    end

    it "credits an association collection to the partial of the records it holds" do
      File.write(File.join(@root, "app/models/post.rb"), "class Post < ApplicationRecord\n  has_many :comments\nend\n")
      FileUtils.mkdir_p(File.join(@root, "app/views/admin/comments"))
      File.write(File.join(@root, "app/views/admin/posts/show.html.erb"), "<%= render @post.comments %>\n")
      File.write(File.join(@root, "app/views/admin/comments/_comment.html.erb"), "<%= comment.body %>\n")

      expect(rendered_from("admin/comments/comment")).to eq("## Rendered From (1)\n- `app/views/admin/posts/show.html.erb:1`")
      expect(rendered_from("admin/posts/post")).to eq("## Rendered From (1)\n- `app/views/admin/posts/index.html.erb:1`")
    end

    it "reads an association's class_name, and keeps the records a trailing call was made on" do
      File.write(File.join(@root, "app/models/post.rb"),
                 "class Post < ApplicationRecord\n  has_many :comments\n  has_many :replies, class_name: \"Comment\"\nend\n")
      FileUtils.mkdir_p(File.join(@root, "app/views/pages"))
      FileUtils.mkdir_p(File.join(@root, "app/views/comments"))
      File.write(File.join(@root, "app/views/comments/_comment.html.erb"), "<%= comment.body %>\n")
      File.write(File.join(@root, "app/views/pages/home.html.erb"),
                 "<%= render @posts.first %>\n<%= render @post.comments.reverse %>\n<%= render @post.replies %>\n<%= render @post.firsts %>\n")

      expect(rendered_from("comments/comment")).to eq("## Rendered From (2)\n- `app/views/pages/home.html.erb:2`\n- `app/views/pages/home.html.erb:3`")
      expect(rendered_from("posts/post")).to include("app/views/pages/home.html.erb:1")
      expect(rendered_from("posts/post")).not_to include("home.html.erb:4")
    end

    it "credits a chain on a receiver that is no model to the partial of the records it names" do
      File.write(File.join(@root, "app/models/post.rb"), "class Post < ApplicationRecord\nend\n")
      FileUtils.mkdir_p(File.join(@root, "app/views/users"))
      File.write(File.join(@root, "app/views/users/show.html.erb"), "<%= render current_user.posts %>\n<%= render current_account.widgets %>\n")

      expect(rendered_from("posts/post")).to include("app/views/users/show.html.erb:1")
      expect(rendered_from("posts/post")).not_to include("users/show.html.erb:2")
    end

    it "reads the plain partial before a sibling for a locale the app makes available" do
      File.write(File.join(@root, "app/views/posts/_post.es-419.html.erb"), "<%= publicacion.titulo %>\n")
      allow(described_class).to receive(:cached_context).and_return(i18n: { available_locales: %w[en es-419] })

      expect(described_class.call(partial: "posts/post").content.first[:text]).to start_with("# Partial: posts/_post.html.erb")
    end

    it "counts a partial under a view root declared inside app/views once" do
      FileUtils.mkdir_p(File.join(@root, "config"))
      File.write(File.join(@root, "config/application.rb"), "config.paths[\"app/views\"].unshift(\"app/views/custom\")\n")
      FileUtils.mkdir_p(File.join(@root, "app/views/custom/notes"))
      File.write(File.join(@root, "app/views/custom/notes/_badge.html.erb"), "<%= badge %>\n")
      File.write(File.join(@root, "app/views/custom/notes/index.html.erb"), "<%= render \"notes/badge\", badge: 1 %>\n")

      text = described_class.call(partial: "badge").content.first[:text]
      expect(text).not_to include("matches 2 files")
      expect(rendered_from("notes/badge")).to eq("## Rendered From (1)\n- `app/views/custom/notes/index.html.erb:1` - locals: badge")
    end
  end

  # The view resolver renders a pack linked into packs/ from elsewhere in the
  # monorepo; its partials are named the way the app spells them.
  describe "a partial in a pack linked in from the app's repository" do
    around do |example|
      Dir.mktmpdir("linked-pack") do |repo|
        @repo = File.realpath(repo)
        @root = File.join(@repo, "apps/web")
        views = File.join(@repo, "packages/billing-pack/app/views/invoices")
        FileUtils.mkdir_p([ File.join(@repo, ".git"), views, File.join(@root, "packs"), File.join(@root, "app/views/home") ])
        File.write(File.join(views, "_invoice.html.erb"), "<%= invoice.number %>\n")
        File.write(File.join(views, "index.html.erb"), "<%= render \"invoices/invoice\", invoice: @invoice %>\n")
        File.write(File.join(@root, "app/views/home/index.html.erb"), "<h1>Home</h1>\n")
        File.symlink("../../../packages/billing-pack", File.join(@root, "packs/billing"))
        example.run
      end
    end

    before do
      allow(RailsAiContext).to receive(:default_app).and_return(RailsAiContext::StaticApp.new(@root))
      allow(described_class).to receive(:cached_context).and_return({})
    end

    it "names the partial, its file and its render sites as the app spells them" do
      text = described_class.call(partial: "invoices/invoice").content.first[:text]

      expect(text).to start_with("# Partial: invoices/_invoice.html.erb\n")
      expect(text).to include("**File:** `packs/billing/app/views/invoices/_invoice.html.erb`")
      expect(text).to include("- `packs/billing/app/views/invoices/index.html.erb:1` - locals: invoice")
      expect(text).to include(%(rails_get_view(path:"invoices/_invoice.html.erb")))
      expect(text).not_to include(@repo)
    end
  end

  describe "a strict locals comment in each form Rails accepts" do
    around do |example|
      Dir.mktmpdir("strict-locals") do |dir|
        @root = dir
        notes = File.join(dir, "app/views/notes")
        FileUtils.mkdir_p(notes)
        File.write(File.join(notes, "_dash.html.erb"), %(<%# locals: (title:, tone: "plain") -%>\n<p class="<%= tone %>"><%= title %></p>\n))
        File.write(File.join(notes, "_paren.html.erb"), %(<%# locals: (title: t(".heading"), tone: "plain") %>\n<p class="<%= tone %>"><%= title %></p>\n))
        File.write(File.join(notes, "_none.html.erb"), "<%# locals: () %>\n<p>static</p>\n")
        example.run
      end
    end

    before do
      allow(RailsAiContext).to receive(:default_app).and_return(RailsAiContext::StaticApp.new(@root))
      allow(described_class).to receive(:cached_context).and_return({})
    end

    def interface(name)
      described_class.call(partial: "notes/#{name}").content.first[:text]
    end

    it "reads a comment that ends in -%>" do
      expect(interface("dash")).to include("**Declared locals** (Rails 7.1+ magic comment): title, tone")
    end

    it "reads a default that has parentheses" do
      expect(interface("paren")).to include("**Declared locals** (Rails 7.1+ magic comment): title, tone")
    end

    it "names a keyword rest, which lets any other local through" do
      File.write(File.join(@root, "app/views/notes/_rest.html.erb"), "<%# locals: (title:, **opts) %>\n<%= title %>\n")

      expect(interface("rest")).to include("**Declared locals** (Rails 7.1+ magic comment): title, **opts")
    end

    it "degrades on a partial whose bytes are not valid UTF-8" do
      File.binwrite(File.join(@root, "app/views/notes/_bad.html.erb"), "<%# locals: (title:) %>\n\xFF\xFE<%= title %>\n".b)

      expect(interface("bad")).to include("**Declared locals** (Rails 7.1+ magic comment): title")
    end

    # `+` sorts before `.`, and Rails renders the plain file for a request with no variant.
    it "reads the plain partial ahead of a variant beside it" do
      File.write(File.join(@root, "app/views/notes/_post.html+mobile.erb"), "<%# locals: (compact:) %>\n<%= compact %>\n")
      File.write(File.join(@root, "app/views/notes/_post.html.erb"), "<%# locals: (title:) %>\n<%= title %>\n")

      text = interface("post")
      expect(text).to include("app/views/notes/_post.html.erb", "**Declared locals** (Rails 7.1+ magic comment): title")
      expect(text).not_to include("# Partial: notes/_post.html+mobile.erb")
    end

    it "says an empty list rejects every local" do
      text = interface("none")

      expect(text).to include("**Declared locals** (Rails 7.1+ magic comment): none, so passing any local raises")
      expect(text).not_to include("No local variables detected")
    end
  end

  # Two of the app's three partials are `.text.erb`, and the resolver's fixed
  # extension list refused the name its own Available list had just printed.
  describe "a partial outside the html.erb extension list" do
    around do |example|
      Dir.mktmpdir("partial-interface") do |dir|
        @root = dir
        FileUtils.mkdir_p(File.join(dir, "app/views/reports/ai_data"))
        FileUtils.mkdir_p(File.join(dir, "app/views/pdfs"))
        File.write(File.join(dir, "app/views/reports/ai_data/_header.text.erb"),
                   "<%= title %> for order <%= order.number %>\n")
        File.write(File.join(dir, "app/views/reports/ai_data/summary.text.erb"),
                   "<%= render partial: 'reports/ai_data/header', locals: { order: @order, title: 'summary' } -%>\n")
        File.write(File.join(dir, "app/views/pdfs/_summary_fields.html.erb"),
                   (1..18).map { |i| "<p><%= prediction.field_#{format('%02d', i)} %></p>" }.join("\n") + "\n")
        example.run
      end
    end

    before do
      allow(RailsAiContext).to receive(:default_app).and_return(RailsAiContext::StaticApp.new(@root))
      allow(described_class).to receive(:cached_context).and_return({})
    end

    it "says unbooted on a miss that the views of the engine a test/dummy runs in are not read" do
      allow(RailsAiContext).to receive(:static_tier?).and_return(true)
      allow(RailsAiContext::PathResolver).to receive(:test_root).and_return("/engine")

      text = described_class.call(partial: "b3eng/widgets/widget").content.first[:text]
      expect(text).to include("_The views of the engine this app runs in are read only with the app booted._")
    end

    it "refuses a partial linked from outside the app as an error, and never offers it" do
      Dir.mktmpdir do |outside|
        File.write(File.join(outside, "leak.html.erb"), "<%= outside_secret_local %>\n")
        File.symlink(File.join(outside, "leak.html.erb"), File.join(@root, "app/views/pdfs/_leak.html.erb"))

        result = described_class.call(partial: "pdfs/leak")
        expect(result.error?).to be(true)
        expect(result.content.first[:text]).to start_with("Path not allowed: pdfs/leak")
        expect(result.content.first[:text]).not_to include("outside_secret_local")

        missing = described_class.call(partial: "pdfs/nope").content.first[:text]
        expect(missing).to include("pdfs/summary_fields")
        expect(missing).not_to include("pdfs/leak")
      end
    end

    it "offers only templates as available partials" do
      File.write(File.join(@root, "app/views/pdfs/_banner.png"), "not a template")
      FileUtils.mkdir_p(File.join(@root, "app/views/pdfs/_bits"))

      text = described_class.call(partial: "missing/thing").content.first[:text]
      available = text[/^Available: .*$/]

      expect(available).to include("pdfs/summary_fields")
      expect(available).not_to include("pdfs/banner")
      expect(available).not_to include("pdfs/bits")
    end

    it "resolves a .text.erb partial by its Rails name" do
      text = described_class.call(partial: "reports/ai_data/header").content.first[:text]

      expect(text).not_to include("not found")
      expect(text).to include("reports/ai_data/_header.text.erb")
    end

    it "finds a render(partial:) call written with parentheses, on one line or over several" do
      File.write(File.join(@root, "app/views/reports/ai_data/split.text.erb"), <<~ERB)
        Report
        <%= render(
              partial: "reports/ai_data/header",
              locals: { title: @title }
            ) %>
        <%= render(partial: "reports/ai_data/header", locals: { order: @order }) %>
      ERB

      text = described_class.call(partial: "reports/ai_data/header", detail: "full").content.first[:text]

      expect(text).to include("`app/views/reports/ai_data/split.text.erb:2` - locals: title")
      expect(text).to include("`app/views/reports/ai_data/split.text.erb:6` - locals: order")
    end

    it "ends a snippet at the call's own last line" do
      File.write(File.join(@root, "app/views/reports/ai_data/badge.text.haml"),
                 "%div\n  = render \"reports/ai_data/header\", title: 1\n  %p next line\n")

      text = described_class.call(partial: "reports/ai_data/header", detail: "full").content.first[:text]

      expect(text).to include("app/views/reports/ai_data/badge.text.haml:2")
      expect(text).not_to include("next line")
    end

    it "counts a render nested in another render's arguments as one site" do
      File.write(File.join(@root, "app/views/reports/ai_data/nested.text.erb"),
                 "<%= render \"reports/ai_data/header\", a: render(\"reports/ai_data/header\") %>\n")

      text = described_class.call(partial: "reports/ai_data/header", detail: "full").content.first[:text]

      expect(text.scan("nested.text.erb:1").size).to eq(1)
    end

    it "says how many calls the list left out" do
      text = described_class.call(partial: "pdfs/summary_fields").content.first[:text]

      expect(text).to include("...and 8 more")
    end
  end

  describe "a partial that calls the app's own helpers" do
    around do |example|
      Dir.mktmpdir("partial-interface") do |dir|
        @root = dir
        FileUtils.mkdir_p(File.join(dir, "app/views/layouts"))
        File.write(File.join(dir, "app/views/layouts/_head.html.erb"),
                   "<%= theme_color_meta_tags %>\n<%= canonical_link_tag %>\n<%= admin_badge %>\n<%= title %>\n")
        FileUtils.mkdir_p(File.join(dir, "app/helpers"))
        File.write(File.join(dir, "app/helpers/application_helper.rb"),
                   "module ApplicationHelper\n  include CanonicalURL::Helpers\n\n  def theme_color_meta_tags = nil\nend\n")
        FileUtils.mkdir_p(File.join(dir, "plugins/chat/app/helpers"))
        FileUtils.mkdir_p(File.join(dir, "plugins/chat/app/models"))
        File.write(File.join(dir, "plugins/chat/plugin.rb"), "# plugin\n")
        File.write(File.join(dir, "plugins/chat/app/helpers/badges_helper.rb"),
                   "module BadgesHelper\n  def admin_badge = nil\nend\n")
        FileUtils.mkdir_p(File.join(dir, "lib"))
        File.write(File.join(dir, "lib/canonical_url.rb"),
                   "module CanonicalURL\n  module Helpers\n    def canonical_link_tag(url = nil) = nil\n  end\nend\n")
        FileUtils.mkdir_p(File.join(dir, "config/initializers"))
        File.write(File.join(dir, "config/initializers/inflections.rb"), "ActiveSupport::Inflector.inflections(:en) { |inflect| inflect.acronym 'URL' }\n")
        RailsAiContext::PathResolver.clear_code_roots
        example.run
      end
    end

    before do
      allow(RailsAiContext).to receive(:default_app).and_return(RailsAiContext::StaticApp.new(@root))
      allow(RailsAiContext).to receive(:static_tier?).and_return(true)
      allow(described_class).to receive(:cached_context).and_return({})
    end

    it "reads a call to a helper the app defines, in app/helpers or a lib module they include, as no local" do
      text = described_class.call(partial: "layouts/head").content.first[:text]
      locals = text[/## Local Variables\n(.*?)\n\n/m, 1].to_s

      expect(locals).to include("title")
      expect(locals).not_to include("canonical_link_tag", "theme_color_meta_tags", "admin_badge")
    end
  end

  # bazaar's notification partial listed dom_id and mark_read_notification_path
  # as locals and missed the model that broadcasts it; reviews/review missed
  # its create.turbo_stream.erb; ledger's jbuilder partial found no local and
  # no render call at all.
  describe "a partial rendered outside a render call" do
    around do |example|
      Dir.mktmpdir("partial-sites") do |dir|
        @root = dir
        views = File.join(dir, "app/views")
        %w[notifications reviews api/v1/invoices].each { |d| FileUtils.mkdir_p(File.join(views, d)) }
        FileUtils.mkdir_p(File.join(dir, "app/models"))
        File.write(File.join(views, "notifications/_notification.html.erb"),
                   %(<div id="<%= dom_id(notification) %>" data-url="<%= mark_read_notification_path(notification) %>">\n) +
                   %(  <%= notification.message %> <%= root_path %>\n</div>\n))
        File.write(File.join(dir, "app/models/notification.rb"), <<~RUBY)
          class Notification < ApplicationRecord
            after_create_commit do
              broadcast_prepend_to [user, :notifications], target: "notifications",
                partial: "notifications/notification", locals: { notification: self }
            end
          end
        RUBY
        File.write(File.join(views, "reviews/_review.html.erb"), "<%= review.body %>\n")
        File.write(File.join(views, "reviews/create.turbo_stream.erb"),
                   %(<%= turbo_stream.prepend "reviews", partial: "reviews/review", locals: { review: @review } %>\n))
        File.write(File.join(views, "api/v1/invoices/_invoice.json.jbuilder"),
                   "json.extract! invoice, :id, :number\njson.lines invoice.invoice_lines do |line|\n  json.extract! line, :id\nend\n")
        File.write(File.join(views, "api/v1/invoices/index.json.jbuilder"),
                   %(json.array! @invoices, partial: "api/v1/invoices/invoice", as: :invoice\n))
        File.write(File.join(views, "api/v1/invoices/show.json.jbuilder"),
                   %(json.partial! "api/v1/invoices/invoice", invoice: @invoice\n))
        example.run
      end
    end

    before do
      allow(RailsAiContext).to receive(:default_app).and_return(RailsAiContext::StaticApp.new(@root))
      allow(described_class).to receive(:cached_context).and_return({})
    end

    def text_for(name)
      described_class.call(partial: name).content.first[:text]
    end

    it "reads no helper, route helper or method call as a local" do
      locals = text_for("notifications/notification")[/## Local Variables\n(.*?)\n\n/m, 1]

      expect(locals).to eq("- **notification** - calls: message")
    end

    it "finds the model that broadcasts the partial" do
      expect(text_for("notifications/notification")).to include("- `app/models/notification.rb:3` - locals: notification")
    end

    it "finds a turbo_stream action that renders the partial" do
      expect(text_for("reviews/review")).to include("- `app/views/reviews/create.turbo_stream.erb:1` - locals: review")
    end

    it "reads a jbuilder partial's locals and the jbuilder calls that render it" do
      text = text_for("api/v1/invoices/invoice")

      expect(text).to include("- **invoice** - calls: invoice_lines")
      expect(text).not_to include("**line**")
      expect(text).to include("- `app/views/api/v1/invoices/index.json.jbuilder:1` - locals: invoice")
      expect(text).to include("- `app/views/api/v1/invoices/show.json.jbuilder:1` - locals: invoice")
    end

    it "reads no partial named only in a Ruby comment, in a model or a jbuilder view" do
      File.write(File.join(@root, "app/models/notice.rb"), <<~RUBY)
        class Notice < ApplicationRecord
          # after_create_commit { broadcast_prepend_to "notices", partial: "notifications/notification" }
        end
      RUBY
      File.write(File.join(@root, "app/views/api/v1/invoices/legacy.json.jbuilder"),
                 %(# json.partial! "api/v1/invoices/invoice", invoice: @invoice\njson.id 1\n))

      expect(text_for("notifications/notification")).not_to include("notice.rb")
      expect(text_for("api/v1/invoices/invoice")).not_to include("legacy.json.jbuilder")
    end

    it "reads no partial named in an ERB comment or as a key of another helper's hash" do
      File.write(File.join(@root, "app/views/reviews/archived.turbo_stream.erb"),
                 %(<%# turbo_stream.append "reviews", partial: "reviews/review" %>\n<%= link_to "x", "#", data: { partial: "reviews/review" } %>\n))

      expect(text_for("reviews/review")).not_to include("archived.turbo_stream.erb")
    end
  end

  # RenderingHelper#render: after a positional name the hash that follows is
  # the locals whole, so a `locals:` key there is one local named `locals`.
  describe "render calls whose locals Rails reads by its own rules" do
    around do |example|
      Dir.mktmpdir("partial-render-locals") do |dir|
        @root = dir
        views = File.join(dir, "app/views")
        %w[posts shared].each { |d| FileUtils.mkdir_p(File.join(views, d)) }
        File.write(File.join(views, "posts/index.html.erb"), %(<%= render "posts/form",\n      post: @post,\n      title: "x" %>\n))
        File.write(File.join(views, "posts/edit.html.erb"), %(<%= render "posts/form", post: @post, opts: { size: 1 } %>\n))
        File.write(File.join(views, "posts/show.html.erb"), %(<%= render "shared/badge", locals: { user: current_user } %>\n))
        File.write(File.join(views, "posts/_form.html.erb"), "<p><%= post.title %></p>\n")
        File.write(File.join(views, "shared/_badge.html.erb"), "<p>badge</p>\n")
        example.run
      end
    end

    before do
      allow(RailsAiContext).to receive(:default_app).and_return(RailsAiContext::StaticApp.new(@root))
      allow(described_class).to receive(:cached_context).and_return({})
    end

    def site_locals(name)
      described_class.call(partial: name).content.first[:text].scan(/^- `(app\/[^`]+)` - locals: (.*)$/).to_h
    end

    it "names a multi-line call's keys, a nested hash's owner only, and a positional locals: as one local" do
      expect(site_locals("posts/form")).to eq(
        "app/views/posts/edit.html.erb:1" => "post, opts",
        "app/views/posts/index.html.erb:1" => "post, title"
      )
      expect(site_locals("shared/badge")).to eq("app/views/posts/show.html.erb:1" => "locals")
    end
  end

  # ObjectRenderer names the record after `as:` or the partial, and
  # CollectionRenderer#retrieve_variable adds its _counter and _iteration.
  # A bare name is looked up under the controller's prefixes: its own folder, then application.
  describe "records rendered into a partial and a bare name found in application" do
    around do |example|
      Dir.mktmpdir("partial-record-locals") do |dir|
        @root = dir
        views = File.join(dir, "app/views")
        %w[posts application].each { |d| FileUtils.mkdir_p(File.join(views, d)) }
        File.write(File.join(views, "posts/index.html.erb"), <<~ERB)
          <%= render partial: "posts/item", collection: @items %>
          <%= render partial: "posts/item", object: @item %>
          <%= render "flash", notice: @notice %>
        ERB
        File.write(File.join(views, "posts/_item.html.erb"), "<p>x</p>\n")
        File.write(File.join(views, "application/_flash.html.erb"), "<p>x</p>\n")
        example.run
      end
    end

    before do
      allow(RailsAiContext).to receive(:default_app).and_return(RailsAiContext::StaticApp.new(@root))
      allow(described_class).to receive(:cached_context).and_return({})
    end

    def site_locals(name)
      described_class.call(partial: name).content.first[:text].scan(/^- `(app\/[^`]+)` - locals: (.*)$/).to_h
    end

    it "names the record local Rails gives the partial, and finds a bare name's application partial" do
      expect(site_locals("posts/item")).to eq(
        "app/views/posts/index.html.erb:1" => "item, item_counter, item_iteration",
        "app/views/posts/index.html.erb:2" => "item"
      )
      expect(site_locals("application/flash")).to eq("app/views/posts/index.html.erb:3" => "notice")
    end
  end

  # The blog's html and json post partials each listed the other's callers
  # and locals.
  describe "partials that share a name across formats or directories" do
    around do |example|
      Dir.mktmpdir("partial-formats") do |dir|
        @root = dir
        views = File.join(dir, "app/views")
        %w[posts comments].each { |d| FileUtils.mkdir_p(File.join(views, d)) }
        FileUtils.mkdir_p(File.join(dir, "app/models"))
        File.write(File.join(views, "posts/_post.html.erb"), "<%= post.title %><%= show_author %>\n")
        File.write(File.join(views, "posts/_post.json.jbuilder"), "json.extract! post, :id, :title\n")
        File.write(File.join(views, "posts/index.html.erb"),
                   %(<% @posts.each do |post| %>\n  <%= render "posts/post", post: post, show_author: true %>\n<% end %>\n))
        File.write(File.join(views, "posts/index.json.jbuilder"), %(json.array! @posts, partial: "posts/post", as: :post\n))
        File.write(File.join(views, "posts/show.json.jbuilder"), %(json.partial! "posts/post", post: @post\n))
        File.write(File.join(views, "posts/create.turbo_stream.erb"),
                   %(<%= turbo_stream.prepend "posts", partial: "posts/post", locals: { post: @post } %>\n))
        File.write(File.join(dir, "app/models/post.rb"), <<~RUBY)
          class Post < ApplicationRecord
            after_create_commit -> { broadcast_prepend_to "posts", partial: "posts/post", locals: { post: self } }
          end
        RUBY
        File.write(File.join(views, "posts/_form.html.erb"), "<%= post.title %>\n")
        File.write(File.join(views, "comments/_form.html.erb"), "<%= comment.body %>\n")
        File.write(File.join(views, "posts/new.html.erb"), %(<%= render "form", post: @post %>\n))
        File.write(File.join(views, "posts/show.html.erb"), %(<%= render "comments/form", post: @post, comment: @comment %>\n))
        example.run
      end
    end

    before do
      allow(RailsAiContext).to receive(:default_app).and_return(RailsAiContext::StaticApp.new(@root))
      allow(described_class).to receive(:cached_context).and_return({})
    end

    def sites_and_locals(name)
      text = described_class.call(partial: name).content.first[:text]
      [ text.scan(/^- `(app\/[^`]+)`/).flatten, text[/## Local Variables\n(.*?)\n\n/m, 1].scan(/\*\*(\w+)\*\*/).flatten ]
    end

    it "gives the html partial the html, turbo_stream and broadcast sites" do
      sites, locals = sites_and_locals("posts/post")

      expect(sites).to eq(%w[app/views/posts/create.turbo_stream.erb:1 app/views/posts/index.html.erb:2 app/models/post.rb:2])
      expect(locals).to eq(%w[post show_author])
    end

    it "gives the json partial the jbuilder sites alone" do
      sites, locals = sites_and_locals("posts/_post.json.jbuilder")

      expect(sites).to eq(%w[app/views/posts/index.json.jbuilder:1 app/views/posts/show.json.jbuilder:1])
      # json.array! renders its collection through CollectionRenderer, which adds the counter and iteration.
      expect(locals).to eq(%w[post post_counter post_iteration])
    end

    it "reads json.partial!'s locals from its parentheses when a modifier follows them" do
      views = File.join(@root, "app/views")
      File.write(File.join(views, "posts/_card.json.jbuilder"), "json.title card.title\n")
      File.write(File.join(views, "posts/card.json.jbuilder"), %(json.partial!("posts/card", card: @post) if @post\n))

      text = described_class.call(partial: "posts/_card.json.jbuilder").content.first[:text]

      expect(text).to include("`app/views/posts/card.json.jbuilder:1` - locals: card")
    end

    # JbuilderTemplate#_render_partial_with_options:
    # options[:locals] ||= options.except(:partial, :as, :collection, :cached)
    it "reads json.partial!'s hash form keys beside partial: as its locals" do
      views = File.join(@root, "app/views")
      File.write(File.join(views, "posts/_card.json.jbuilder"), "json.title card.title\n")
      File.write(File.join(views, "posts/card.json.jbuilder"), <<~JBUILDER)
        json.partial! partial: "posts/card", card: @post, cached: true
        json.partial!(partial: "posts/card", card: @post, extra: 1)
        json.partial! partial: "posts/card", locals: { card: @post }, ignored: 1
        json.data { json.partial! "posts/card", card: @post }
        json.array! @posts, partial: "posts/card", as: :card, extra: 1
      JBUILDER

      text = described_class.call(partial: "posts/_card.json.jbuilder").content.first[:text]

      expect(text).to include("`app/views/posts/card.json.jbuilder:1` - locals: card\n")
      expect(text).to include("`app/views/posts/card.json.jbuilder:2` - locals: card, extra\n")
      expect(text).to include("`app/views/posts/card.json.jbuilder:3` - locals: card\n")
      expect(text).to include("`app/views/posts/card.json.jbuilder:4` - locals: card\n")
      expect(text).to include("`app/views/posts/card.json.jbuilder:5` - locals: extra, card, card_counter, card_iteration\n")
    end

    it "reads a jbuilder call's own method, never one named in its trailing comment" do
      File.write(File.join(@root, "app/views/posts/cards.json.jbuilder"),
                 %(json.cards @posts, partial: "posts/post", as: :post # replaced json.partial!\n))

      text = described_class.call(partial: "posts/_post.json.jbuilder").content.first[:text]

      expect(text).to include("- `app/views/posts/cards.json.jbuilder:1` - locals: post\n")
    end

    # The blog's posts/form claimed the render of comments/form in posts/show.
    it "reads a name with a directory as that directory's partial" do
      expect(sites_and_locals("posts/form")).to eq([ %w[app/views/posts/new.html.erb:1], %w[post] ])
      expect(sites_and_locals("comments/form").first).to eq(%w[app/views/posts/show.html.erb:1])
    end

    it "credits a render only to the partial it names, never to a string another option holds" do
      File.write(File.join(@root, "app/views/comments/index.html.erb"), %(<%= render "comments/form_fields", label: "form" %>\n))

      expect(sites_and_locals("comments/form").first).to eq(%w[app/views/posts/show.html.erb:1])
    end

    # Every site in Ruby read as html, so `formats: [:json]` in a controller
    # was listed under the html partial and left off the json one it renders.
    it "reads a controller's render by the format it names, its respond_to block or the request" do
      FileUtils.mkdir_p(File.join(@root, "app/controllers"))
      File.write(File.join(@root, "app/controllers/cards_controller.rb"), <<~RUBY)
        class CardsController < ApplicationController
          def json_card
            render partial: "posts/post", locals: { post: Post.first }, formats: [ :json ]
          end

          def either_card
            respond_to do |wants|
              wants.html { render partial: "posts/post", locals: { post: Post.first } }
              wants.json { render partial: "posts/post", locals: { post: Post.first } }
            end
          end

          def bare_card
            render partial: "posts/post", locals: { post: Post.first }
          end

          def stream_card
            render turbo_stream: turbo_stream.replace("card", partial: "posts/post", locals: { post: Post.first })
          end
        end
      RUBY

      html = sites_and_locals("posts/post").first.grep(/cards_controller/)
      json = sites_and_locals("posts/_post.json.jbuilder").first.grep(/cards_controller/)

      expect(html).to eq(%w[app/controllers/cards_controller.rb:8 app/controllers/cards_controller.rb:14 app/controllers/cards_controller.rb:18])
      expect(json).to eq(%w[app/controllers/cards_controller.rb:3 app/controllers/cards_controller.rb:9 app/controllers/cards_controller.rb:14])
    end

    # A `format:` local read as the format to look the partial up in, so
    # both calls that render the date partial were dropped and it answered
    # "No render calls found". Rails reads only `formats:`, and only among
    # the options of the hash form.
    it "reads `format:` and every key inside `locals:` as a local, never as a format" do
      FileUtils.mkdir_p(File.join(@root, "app/views/shared"))
      FileUtils.mkdir_p(File.join(@root, "app/controllers"))
      File.write(File.join(@root, "app/views/shared/_date.html.erb"),
                 "<%# locals: (date:, format: :long) %>\n<time><%= l(date, format: format) %></time>\n")
      File.write(File.join(@root, "app/views/posts/_dates.html.erb"), <<~ERB)
        <p><%= render "shared/date", date: @post.created_at, format: :short %></p>
        <p><%= render partial: "shared/date", locals: { date: @post.updated_at, format: :long } %></p>
      ERB
      File.write(File.join(@root, "app/controllers/stamps_controller.rb"), <<~RUBY)
        class StampsController < ApplicationController
          def show
            render partial: "shared/date", locals: { date: Time.current, formats: [ :json ] }
          end
        end
      RUBY

      expect(sites_and_locals("shared/date").first)
        .to eq(%w[app/views/posts/_dates.html.erb:1 app/views/posts/_dates.html.erb:2 app/controllers/stamps_controller.rb:3])
    end

    # `render "posts/post", formats: [:json]` hands the html partial a local
    # named formats; only `render partial: ..., formats:` looks up json.
    it "reads `formats:` as the lookup format only among the options of the hash form" do
      File.write(File.join(@root, "app/views/posts/feed.html.erb"), <<~ERB)
        <%= render "posts/post", post: @post, formats: [:json] %>
        <%= render formats: [:json], partial: "posts/post", locals: { post: @post } %>
        <%= render(:partial => "posts/post", :formats => %i[json], :locals => { :post => @post }) %>
      ERB

      html = sites_and_locals("posts/post").first.grep(/feed/)
      json = sites_and_locals("posts/_post.json.jbuilder").first.grep(/feed/)

      expect(html).to eq(%w[app/views/posts/feed.html.erb:1])
      expect(json).to eq(%w[app/views/posts/feed.html.erb:2 app/views/posts/feed.html.erb:3])
    end

    it "reads no `formats:` out of a string the call passes" do
      File.write(File.join(@root, "app/views/posts/notes.html.erb"),
                 %(<%= render partial: "posts/post", locals: { post: @post }, title: "formats: [:json] only" %>\n))

      expect(sites_and_locals("posts/post").first.grep(/notes/)).to eq(%w[app/views/posts/notes.html.erb:1])
      expect(sites_and_locals("posts/_post.json.jbuilder").first.grep(/notes/)).to eq([])
    end

    it "reads no `partial:` out of a string beside a name given first, so `formats:` stays a local" do
      File.write(File.join(@root, "app/views/posts/hints.html.erb"),
                 %(<%= render "posts/post", post: @post, hint: "partial: 'posts/post'", formats: [:json] %>\n))

      expect(sites_and_locals("posts/post").first.grep(/hints/)).to eq(%w[app/views/posts/hints.html.erb:1])
      expect(sites_and_locals("posts/_post.json.jbuilder").first.grep(/hints/)).to eq([])
    end

    it "leaves a controller's render to the request when a Turbo Stream builder is only named in a comment" do
      FileUtils.mkdir_p(File.join(@root, "app/controllers"))
      File.write(File.join(@root, "app/controllers/cards_controller.rb"), <<~RUBY)
        class CardsController < ApplicationController
          def show
            render partial: "posts/post", locals: { post: Post.first } # replaces turbo_stream.append
          end
        end
      RUBY

      expect(sites_and_locals("posts/post").first.grep(/cards_controller/)).to eq(%w[app/controllers/cards_controller.rb:3])
      expect(sites_and_locals("posts/_post.json.jbuilder").first.grep(/cards_controller/)).to eq(%w[app/controllers/cards_controller.rb:3])
    end
  end

  describe "the standard and full renderings" do
    around do |example|
      Dir.mktmpdir("partial-render") do |dir|
        @root = dir
        FileUtils.mkdir_p(File.join(dir, "app/views/widgets"))
        File.write(File.join(dir, "app/views/widgets/_card.html.erb"), <<~ERB)
          <%# locals: (widget:, size:) %>
          <div class="<%= size %>"><%= widget.title %><%= widget.body %></div>
        ERB
        File.write(File.join(dir, "app/views/widgets/index.html.erb"),
                   "<%= render \"widgets/card\", widget: @widget, size: \"lg\" %>\n")
        example.run
      end
    end

    before do
      allow(RailsAiContext).to receive(:default_app).and_return(RailsAiContext::StaticApp.new(@root))
      allow(described_class).to receive(:cached_context).and_return({})
    end

    it "renders the standard detail byte for byte" do
      text = described_class.call(partial: "widgets/card", detail: "standard").content.first[:text]

      expect(text).to eq(<<~MD.chomp)
        # Partial: widgets/_card.html.erb

        **File:** `app/views/widgets/_card.html.erb` (2 lines)
        **Declared locals** (Rails 7.1+ magic comment): widget, size

        ## Local Variables
        - **size**
        - **widget** - calls: body, title

        ## Rendered From (1)
        - `app/views/widgets/index.html.erb:1` - locals: widget, size

        _Next: `rails_get_view(path:"widgets/_card.html.erb")` for full file content_
      MD
    end

    it "renders the full detail byte for byte" do
      text = described_class.call(partial: "widgets/card", detail: "full").content.first[:text]

      expect(text).to eq(<<~MD.chomp)
        # Partial: widgets/_card.html.erb

        **File:** `app/views/widgets/_card.html.erb` (2 lines)
        **Declared locals** (Rails 7.1+ magic comment): widget, size

        ## Local Variables
        - **size**
        - **widget** - calls: body, title

        ## Rendered From (1)
        - `app/views/widgets/index.html.erb:1` - locals: widget, size
          ```erb
          <%= render "widgets/card", widget: @widget, size: "lg" %>
          ```

        ## Source
        ```erb
        <%# locals: (widget:, size:) %>
        <div class="<%= size %>"><%= widget.title %><%= widget.body %></div>

        ```
      MD
    end

    it "caps the render-site list per detail level" do
      (1..26).each do |i|
        File.write(File.join(@root, "app/views/widgets/page#{format('%02d', i)}.html.erb"),
                   "<%= render \"widgets/card\", widget: @widget, size: \"lg\" %>\n")
      end

      standard = described_class.call(partial: "widgets/card", detail: "standard").content.first[:text]
      full = described_class.call(partial: "widgets/card", detail: "full").content.first[:text]

      expect(standard.scan("- `app/views/widgets/").size).to eq(15)
      expect(full.scan("- `app/views/widgets/").size).to eq(25)
      expect(standard).to include("_...and 12 more_")
      expect(full).to include("_...and 2 more_")
    end

    it "says so when nothing renders the partial and it declares no locals" do
      File.write(File.join(@root, "app/views/widgets/_bare.html.erb"), "<p>hi</p>\n")

      text = described_class.call(partial: "widgets/bare", detail: "standard").content.first[:text]

      expect(text).to include("_No local variables detected in this partial._")
      expect(text).to include("_No render calls found for this partial._")
    end

    it "leaves both notes out of the full rendering" do
      File.write(File.join(@root, "app/views/widgets/_bare.html.erb"), "<p>hi</p>\n")

      text = described_class.call(partial: "widgets/bare", detail: "full").content.first[:text]

      expect(text).not_to include("_No local variables detected")
      expect(text).not_to include("_No render calls found")
    end
  end

  describe ".call" do
    it "analyzes a partial with magic comment locals" do
      result = described_class.call(partial: "posts/form")
      text = result.content.first[:text]
      expect(text).to be_a(String)
      expect(text.length).to be > 0
      expect(text).to include("post")
      expect(text).to include("url")
    end

    it "reports a partial over the size cap" do
      allow(RailsAiContext.configuration).to receive(:max_file_size).and_return(10)

      result = described_class.call(partial: "posts/form")
      expect(result.content.first[:text]).to include("Partial file too large")
    end

    it "shows summary detail level" do
      result = described_class.call(partial: "posts/form", detail: "summary")
      text = result.content.first[:text]
      expect(text).to include("Locals:")
      expect(text).to include("Rendered from:")
    end

    it "shows standard detail with method calls on locals" do
      result = described_class.call(partial: "posts/post", detail: "standard")
      text = result.content.first[:text]
      expect(text).to include("Local Variables")
      # post.title and post.body are called in the partial
      expect(text).to include("post")
    end

    it "shows full detail with source code" do
      result = described_class.call(partial: "posts/form", detail: "full")
      text = result.content.first[:text]
      expect(text).to include("Source")
      expect(text).to include("form_with")
    end

    it "handles underscore-prefixed partial names" do
      result = described_class.call(partial: "posts/_form")
      text = result.content.first[:text]
      expect(text).to include("post")
    end

    it "finds render sites for the partial" do
      result = described_class.call(partial: "posts/form", detail: "standard")
      text = result.content.first[:text]
      # edit.html.erb renders the form partial
      expect(text).to include("Rendered From")
    end

    # Every Rails app has several `_form`, and answering a bare name with the
    # first one in sorted order gave one directory's locals for another's.
    it "asks which one instead of picking a bare name's first match" do
      views_dir = Rails.root.join("app", "views")
      dirs = %w[gpi_a gpi_b].map { |d| views_dir.join("#{d}_#{Process.pid}") }
      dirs.each do |dir|
        FileUtils.mkdir_p(dir)
        File.write(dir.join("_ambiguous_widget.html.erb"), "<%= widget %>")
      end

      text = described_class.call(partial: "ambiguous_widget").content.first[:text]

      expect(text).to include("matches")
      dirs.each { |dir| expect(text).to include("#{File.basename(dir)}/_ambiguous_widget.html.erb") }
    ensure
      dirs&.each { |dir| FileUtils.rm_rf(dir) }
    end

    it "returns not-found for unknown partial" do
      result = described_class.call(partial: "nonexistent/widget")
      text = result.content.first[:text]
      expect(text).to include("not found")
    end

    it "does not list the same partial twice when it exists under multiple extensions" do
      views_dir = Rails.root.join("app", "views")
      dir = views_dir.join("gpi_dup_#{Process.pid}")
      FileUtils.mkdir_p(dir)
      File.write(dir.join("_widget.html.erb"), "<%= widget %>")
      File.write(dir.join("_widget.json.jbuilder"), "json.name widget.name")

      result = described_class.call(partial: "nonexistent/widget")
      text = result.content.first[:text]
      candidate = "gpi_dup_#{Process.pid}/widget"

      expect(text.scan(candidate).size).to eq(1)
    ensure
      FileUtils.rm_rf(dir) if defined?(dir)
    end

    it "returns helpful message when partial is nil" do
      result = described_class.call(partial: nil)
      text = result.content.first[:text]
      expect(text).to include("`partial` parameter is required")
    end

    it "returns helpful message when partial is empty string" do
      result = described_class.call(partial: "")
      text = result.content.first[:text]
      expect(text).to include("`partial` parameter is required")
    end

    it "returns helpful message when partial is whitespace only" do
      result = described_class.call(partial: "   ")
      text = result.content.first[:text]
      expect(text).to include("`partial` parameter is required")
    end

    it "prevents path traversal" do
      result = described_class.call(partial: "../../../etc/passwd")
      text = result.content.first[:text]
      expect(text).to include("not allowed")
    end

    it "blocks caller-supplied sensitive names BEFORE filesystem stat (existence oracle)" do
      # Without the early sensitive_file? check, resolve_partial_path would
      # stat each candidate for `.env` / `master.key` and the not-found vs
      # access-denied message would leak whether the file exists under
      # app/views/. The fix rejects sensitive names before any File.exist?.
      result = described_class.call(partial: ".env")
      text = result.content.first[:text]
      expect(text).to match(/not allowed/)
      expect(text).to include("sensitive")

      result2 = described_class.call(partial: "config/master.key")
      text2 = result2.content.first[:text]
      expect(text2).to match(/not allowed/)
      expect(text2).to include("sensitive")
    end

    it "detects magic comment locals in status_badge partial" do
      result = described_class.call(partial: "shared/status_badge")
      text = result.content.first[:text]
      expect(text).to include("status")
      expect(text).to include("size")
    end

    it "extracts method calls on locals" do
      result = described_class.call(partial: "posts/post", detail: "standard")
      text = result.content.first[:text]
      # _post.html.erb calls post.title and post.body
      if text.include?("calls:")
        expect(text).to match(/title|body/)
      end
    end

    context "when the app is API-only" do
      it "reports API-only apps as not applicable instead of an empty listing" do
        Dir.mktmpdir("rac_gpi_api_only") do |tmp|
          allow(described_class).to receive(:cached_context).and_return(api: { api_only: true })
          allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(tmp)))

          result = described_class.call(partial: "shared/status_badge")
          text = result.content.first[:text]
          expect(text).to include("Not applicable")
          expect(text).to include("API-only")
        end
      end

      it "checks a directory only when one is named, never the label" do
        Dir.mktmpdir("rac_gpi_api_only") do |tmp|
          FileUtils.mkdir_p(File.join(tmp, "Stimulus"))
          FileUtils.mkdir_p(File.join(tmp, "app/views"))
          allow(described_class).to receive(:cached_context).and_return(api: { api_only: true })
          allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(tmp)))

          expect(described_class.send(:api_only_note, "Stimulus")).to include("Not applicable")
          expect(described_class.send(:api_only_note, "views", dir: "app/views")).to be_nil
        end
      end
    end
  end

  # ERB sends text, HTML comments and `<%#` comments to the page; only the tags' Ruby runs.
  describe "the Ruby a partial's template runs" do
    around do |example|
      Dir.mktmpdir("partial-template-ruby") do |dir|
        @root = dir
        FileUtils.mkdir_p(File.join(dir, "app/views/articles"))
        example.run
      end
    end

    before do
      allow(RailsAiContext).to receive(:default_app).and_return(RailsAiContext::StaticApp.new(@root))
      allow(described_class).to receive(:cached_context).and_return({})
    end

    def locals_of(name, source)
      File.write(File.join(@root, "app/views/articles/_#{name}.html.erb"), source)
      described_class.call(partial: "articles/#{name}").content.first[:text][/## Local Variables\n(.*?)(?:\n\n|\z)/m, 1]
    end

    it "keeps a local named like a block parameter of a commented-out loop" do
      expect(locals_of("row", "<%# @articles.each do |row| %>\n<%= row.title %>\n")).to eq("- **row** - calls: title")
    end

    it "reads no variable the template assigns itself as a local" do
      expect(locals_of("total", "<% total = items.size %>\n<p><%= total %> <%= total.to_s %></p>\n<%= items.first %>\n"))
        .to eq("- **items** - calls: first, size")
    end

    it "reads a local_assigns key only from Ruby, never from an HTML comment" do
      expect(locals_of("guard", "<!-- local_assigns[:ghost] local_assigns.fetch(:phantom) -->\n<%= local_assigns.fetch(:tone, :plain) %>\n<%= user.name %>\n"))
        .to eq("- **tone**\n- **user** - calls: name")
    end

    it "reads a defined? guard only from Ruby, never from page text or a string" do
      expect(locals_of("defined", %(<p>Guard with defined?(ghost) first</p>\n<% if defined?(compact) %><%= "defined?(phantom)" %><% end %>\n)))
        .to eq("- **compact**")
    end

    it "credits a local only with calls its Ruby makes, never one in a comment, a string or page text" do
      source = %(<%# article.author.name was shown here %>\n<p>See article.summary</p>\n<p><%= t("article.byline") %> <%= article.title %></p>\n)
      expect(locals_of("byline", source)).to eq("- **article** - calls: title")
    end
  end

  describe "extract_local_variable_references" do
    def locals_in(source)
      described_class.send(:extract_local_variable_references, source)
    end

    it "sees a local rendered through a raw output tag" do
      expect(locals_in("<%== title %>\n")).to include("title")
    end

    it "still sees a local rendered through an escaping tag" do
      expect(locals_in("<%= title %>\n")).to include("title")
    end

    it "ignores a commented-out tag body" do
      expect(locals_in("<%# title %>\n")).not_to include("title")
    end
  end
end
