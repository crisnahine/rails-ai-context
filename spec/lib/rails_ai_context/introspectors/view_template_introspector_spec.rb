# frozen_string_literal: true

require "spec_helper"

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
end
