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

    it "reads render @post.comments as the records the association holds, as partial_interface does" do
      refs = introspector.send(:extract_partial_refs, "<%= render @post.comments %>\n<%= render @notes if @notes.any? -%>")
      expect(refs).to contain_exactly("comments", "notes")
    end

    # A trailing scope or Enumerable call keeps the records it was called on.
    it "names the records under a trailing call, and no name for a chain on something that is no model" do
      source = "<%= render @posts.first %>\n<%= render @post.comments.reverse %>\n<%= render current_account.widgets %>"
      expect(introspector.send(:extract_partial_refs, source)).to contain_exactly("posts", "comments")
    end

    it "names the records a class_name association holds, not the association" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "app/models"))
        File.write(File.join(root, "app/models/post.rb"), "class Post < ApplicationRecord\n  has_many :replies, class_name: \"Comment\"\n  belongs_to :starter, class_name: \"Comment\"\nend\n")
        File.write(File.join(root, "app/models/comment.rb"), "class Comment < ApplicationRecord; end\n")
        refs = described_class.new(RailsAiContext::StaticApp.new(root)).send(:extract_partial_refs, "<%= render @post.replies %>\n<%= render @post.starter %>")
        expect(refs).to contain_exactly("comments", "comment")
      end
    end

    it "reads a chain on a receiver that is no model from the records it names, when the app has that model" do
      expect(introspector.send(:extract_partial_refs, "<%= render current_user.comments.recent %>")).to eq([ "comments" ])
      expect(introspector.send(:extract_partial_refs, "<%= render current_account.widgets %>")).to be_empty
    end

    it "still detects render @ivar" do
      source = "<%= render @article %>"
      expect(introspector.send(:extract_partial_refs, source)).to include("article")
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

  describe ".ivars_in" do
    it "reads the ivars a template uses" do
      expect(described_class.ivars_in("<%= @post.title %> <%= @user %>")).to eq(%w[post user])
    end

    it "reads a code tag whose first line is a Ruby comment" do
      expect(described_class.ivars_in("<%\n  # the list\n  items = @posts.select(&:published?)\n%>")).to eq(%w[posts])
      expect(described_class.ivars_in("<% # note\n @x.each do |y| %>")).to eq(%w[x])
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

    # A HAML or Slim template is not Ruby: its prose carries apostrophes, and
    # treating those as string quotes swallows everything between them.
    it "keeps reading ivars in a template whose prose has apostrophes" do
      template = "%p Don't stop\n= @user.name\n%p We can't win\n= @order.total\n"

      expect(described_class.ivars_in(template, path: "app/views/posts/show.html.haml")).to eq(%w[order user])
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
        %(<%= render template: "products/base" %>\n<%= render :partial => "legacy" %>\n), %w[products/base legacy] ]
    }.each do |label, (name, source, expected)|
      it "reads #{label}" do
        expect(partials_in(name, source)).to include(*expected)
      end
    end

    it "reads no partial out of a keyword nested inside another argument" do
      source = %(<%= render(ModalComponent.new(template: "big")) %>\n<%= render "form", locals: { template: "edit", partial: "y" } %>\n)

      expect(partials_in("nested.html.erb", source)).to contain_exactly("form", "ModalComponent")
    end

    it "keeps reading past an escaped quote in an argument" do
      expect(partials_in("escaped.html.erb", %{<%= render("a \\" (b", partial: "real") %>\n})).to eq([ "real" ])
    end

    it "does not read a partial name built at runtime" do
      expect(partials_in("preview.html.erb", %(<%= render(partial: "mailer/\#{@system_email}") %>\n))).to eq([])
    end

    it "does not read a JavaScript render method in an inline script" do
      expect(partials_in("captcha.html.erb", %(<script>turnstile.render('#turnstile-container', {});</script>\n)))
        .to eq([])
    end

    it "does not read a string that is not an argument to render" do
      expect(partials_in("form.html.erb", %(<%= form_with layout: "horizontal" %>\n<%= render @products %>\n)))
        .to eq([ "products" ])
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
