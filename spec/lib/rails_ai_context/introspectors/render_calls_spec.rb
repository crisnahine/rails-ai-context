# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Introspectors::RenderCalls do
  describe ".render_locals" do
    it "reads a locals hash a trailing modifier follows" do
      expect(described_class.render_locals(%("posts/post", { post: @post } if @post))).to eq(%w[post])
    end

    # Rails reads a braced options hash as it reads bare keywords.
    it "reads the locals and record of a braced options hash" do
      expect(described_class.render_locals(%({ partial: "row", locals: { a: 1 } }))).to eq(%w[a])
      expect(described_class.render_locals(%({ partial: "row", collection: @rows }))).to eq(%w[row row_counter row_iteration])
      expect(described_class.render_locals(%({ object: @row, partial: "row" }))).to eq(%w[row])
    end
  end

  # A partial's layout and a collection's spacer are partials Rails renders too.
  describe ".render_calls" do
    it "reads the locals of an ERB render with no parentheses and a hash broken across lines" do
      content = %(<%= render partial: "y", locals: {\n  b: 2,\n  c: 3\n} %>)
      args = described_class.render_calls(content, path: "a.html.erb").first[1]

      expect(described_class.render_locals(args)).to eq(%w[b c])
    end
  end

  describe ".rendered_names" do
    def names(content)
      described_class.render_calls(content).flat_map { |_, args, block| described_class.rendered_names(args, block: block) }
    end

    it "reads the layout of a partial render and a collection's spacer, in every render form" do
      expect(names(%(<%= render partial: "posts/row", layout: "posts/frame" %>))).to eq(%w[posts/row posts/frame])
      expect(names(%(<%= render(:partial => "posts/row", :layout => "posts/frame") %>))).to eq(%w[posts/row posts/frame])
      expect(names(%(<%= render partial: "posts/row",\n  collection: @posts, spacer_template: "posts/spacer" %>)))
        .to eq(%w[posts/row posts/spacer])
      expect(names(%(<%= render(partial: "x", collection: @xs, :spacer_template => "posts/spacer") %>))).to eq(%w[x posts/spacer])
      expect(names(%(<%= render layout: "posts/frame" do %>body<% end %>))).to eq(%w[posts/frame])
      expect(names(%(<%= render template: "posts/show", layout: "posts/frame" do %>body<% end %>))).to eq(%w[posts/frame])
      expect(names(%(<%= render({ template: "posts/show" }) %>))).to eq(%w[posts/show])
      expect(names(%(<%= render({ partial: "posts/row", layout: "posts/frame" }) %>))).to eq(%w[posts/row posts/frame])
      expect(names(%(<%= render({ layout: "posts/frame" }) do %>body<% end %>))).to eq(%w[posts/frame])
      expect(names(%(<%= render(layout: "posts/frame", &blk) %>\n<%= render layout: "posts/box", &:itself %>))).to eq(%w[posts/frame posts/box])
      expect(names(%(<%= render partial: "posts/row", layout: "posts/frame" if a&&b %>))).to eq(%w[posts/row posts/frame])
    end

    # Ruby binds an unparenthesised `{` to the call as a block, never as an options hash.
    it "names no partial for a brace block on a call without parentheses" do
      expect(names(%(<%= render { "body" } %>))).to eq([])
      expect(described_class.render_calls(%(<%= render { "body" } %>)).map(&:last)).to eq([ true ])
    end

    it "reads an unclosed paren no further than the call's own tag or continued lines" do
      read = []
      allow(RailsAiContext::Brackets).to receive(:span).and_wrap_original { |original, text, *rest, **options| read << text.length; original.call(text, *rest, **options) }
      padding = "<p>text</p>\n" * 5_000
      expect(names("<%= render( %>\n#{padding}<%= render \"posts/row\" %>")).to include("posts/row")
      haml = described_class.render_calls("= render(\n#{padding}= render \"posts/row\"", path: "a.html.haml")
      expect(haml.flat_map { |_, args, block| described_class.rendered_names(args, block: block) }).to include("posts/row")
      expect(read.max).to be < 100
      expect(names(%(render(\n  partial: "posts/row"\n)\n))).to eq(%w[posts/row])
    end

    it "reads a jbuilder, builder or ruby template's multi-line call as Ruby, through its brackets" do
      %w[a.json.jbuilder a.xml.builder a.html.ruby a.rb].each do |path|
        calls = described_class.render_calls(%(json.x render(\n  partial: "posts/row"\n)\n), path: path)
        expect(calls.flat_map { |_, args, block| described_class.rendered_names(args, block: block) }).to eq(%w[posts/row]), path
      end
    end

    # A template's layout is a layout; after a positional name the hash is locals.
    it "reads no layout of a template render and no key of a positional render's locals" do
      expect(names(%(<%= render template: "posts/show", layout: "admin" %>))).to eq(%w[posts/show])
      expect(names(%(<%= render "posts/row", layout: "posts/frame", spacer_template: "posts/spacer" %>))).to eq(%w[posts/row])
      expect(names(%(<%= render partial: "posts/row", locals: { layout: "posts/frame" } %>))).to eq(%w[posts/row])
    end
  end

  describe ".partial_names" do
    def names(content)
      described_class.render_calls(content).flat_map { |_, args, block| described_class.partial_names(args, block: block) }
    end

    it "reads the partials a call renders and never a template" do
      expect(names(%(<%= render partial: "posts/row", layout: "posts/frame" %>))).to eq(%w[posts/row posts/frame])
      expect(names(%(<%= render "posts/row" %>))).to eq(%w[posts/row])
      expect(names(%(<%= render template: "posts/show", layout: "admin" %>))).to eq([])
    end

    # RenderingHelper#render renders a hash's layout: as the partial when the call has a block.
    it "reads a view's block-form render layout: as a partial" do
      expect(names(%(<%= render layout: "posts/frame" do %>body<% end %>))).to eq(%w[posts/frame])
      expect(names(%(<%= render(layout: "posts/frame", locals: { a: 1 }) do %>body<% end %>))).to eq(%w[posts/frame])
      expect(names(%(<%= render inline: "<p>x</p>", layout: "admin" %>))).to eq([])
    end

    # The block form merges `partial: options[:layout]`, so the hash's own partial: is never read.
    it "reads only the layout of a block-form render that also names a partial or a template" do
      expect(names(%(<%= render(partial: "posts/row", layout: "posts/frame") { "x" } %>))).to eq(%w[posts/frame])
      expect(names(%(<%= render partial: "posts/row", layout: "posts/frame" do -%>x<% end %>))).to eq(%w[posts/frame])
      expect(names(%(<%= render template: "posts/show", layout: "posts/frame" do %>x<% end %>))).to eq(%w[posts/frame])
      expect(names(%(<%= render layout: "posts/frame" %>))).to eq([])
    end
  end

  describe ".form_builders" do
    it "reads no builder off a `fields` that is not a helper call: prose, a hash key or a symbol before a block" do
      [
        %(<p>Edit the fields</p><% @posts.each do |post| %>),
        %(<p>Edit the fields here</p><% @posts.each do |post| %>),
        %(<% Report.new(fields: cols).rows.each do |row| %>),
        %(<% %i[fields tags].each do |kind| %>),
        %(<% table fields: cols do |row| %>),
        %(<% card :fields do |item| %>),
        %(<% track :form_for do |event| %>),
        %(<% custom_fields :x do |row| %>),
        %(<% audit_form_with @post do |row| %>),
        %(<% %i(fields tags).each do |kind| %>),
        %(<% { list: fields }.each do |pair| %>)
      ].each { |content| expect(described_class.form_builders(content)).to eq({}), content }
    end

    it "reads no builder off a form helper called on a receiver, or a fields local assigned or chained on" do
      [
        %(<% presenter.form_with url: "/x" do |item| %>),
        %(<% fields = report.columns; fields.each do |field| %>),
        %(<% fields .each do |field| %>)
      ].each { |content| expect(described_class.form_builders(content)).to eq({}), content }
    end

    it "takes the helper's own block, never a brace block inside its arguments" do
      expect(described_class.form_builders(%(<%= form_with model: Post.new, url: "/x" do |f| %>) +
                                           %(<%= f.fields_for :comments, [Comment.new].reject { |c| c.nil? } do |cf| %>)))
        .to eq("f" => "form", "cf" => "form")
      expect(described_class.form_builders(%(<%= form_with model: Post.new, url: "/x", data: { ids: [1].map { |c| c } } do |f| %>)))
        .to eq("f" => "form")
      expect(described_class.form_builders(%(<%= form_with url: "/x", local: todo | done do |f| %>))).to eq("f" => "form")
      expect(described_class.form_builders(%(<%= fields_for :tags, # not do |z| here,\n  Tag.all do |tf| %>))).to eq("tf" => "form")
      expect(described_class.form_builders(%(<%= f.fields_for "items".to_sym do |item| %>))).to eq("item" => "form")
    end

    # Ruby reads a call's parenthesised arguments across lines, so the block after the closing paren is the helper's.
    it "reads the block of a helper whose parenthesised arguments span lines" do
      expect(described_class.form_builders(%(<%= form_with(\n  model: @post\n) do |f| %>\n  <%= render f %>\n<% end %>)))
        .to eq("f" => "form")
      expect(described_class.form_builders(%(<%= f.fields_for(\n  :comments\n) do |cf| %>))).to eq("cf" => "form")
      expect(described_class.form_builders(%(<%= form_with(\n  model: @post\n).then do |x| %>))).to eq({})
    end

    it "reads an unclosed paren no further than the helper's own tag or continued lines" do
      read = []
      allow(RailsAiContext::Brackets).to receive(:span).and_wrap_original { |original, text, *rest, **options| read << text.length; original.call(text, *rest, **options) }
      padding = "<p>text</p>\n" * 5_000
      expect(described_class.form_builders("<%= form_with( %>\n#{padding}<%= form_with model: @post do |f| %>")).to eq("f" => "form")
      expect(described_class.form_builders("= form_with(\n#{padding}= form_with model: @post do |f|", path: "a.html.haml")).to eq("f" => "form")
      expect(read.max).to be < 100
    end

    # A Ruby view has no tag to end the call, so its brackets do.
    it "reads the block of a Phlex view's helper whose parenthesised arguments span lines" do
      phlex = "form_with(\n  model: @post\n) do |f|\n  render f\nend\n"
      expect(described_class.form_builders(phlex, path: "app/views/posts/form.rb")).to eq("f" => "form")
      expect(described_class.form_builders(phlex)).to eq("f" => "form")
    end

    it "reads simple_form's helpers, and fields_for on a receiver the view does not name, as builders" do
      expect(described_class.form_builders(%(<%= simple_form_for @post do |f| %><%= simple_fields_for :comments do |cf| %>)))
        .to eq("f" => "form", "cf" => "form")
      expect(described_class.form_builders(%(<%= form.fields_for :comments do |cf| %>))).to eq("cf" => "form")
      expect(described_class.form_builders(%(<%= @form.fields_for :comments do |cf| %>))).to eq("cf" => "form")
    end

    it "reads a receiver's fields as a builder call only when the receiver is a builder, as FormBuilder alone defines it" do
      [
        %(<% @post.fields(:visible).each do |field| %>),
        %(<% Post.fields(:x).each do |post| %>),
        %(<% @survey.fields :public do |field| %>)
      ].each { |content| expect(described_class.form_builders(content)).to eq({}), content }
      expect(described_class.form_builders(%(<%= form_with model: @post do |post| %><% @post.fields(:visible).each do |field| %>)))
        .to eq("post" => "form")
      expect(described_class.form_builders(%(<%= form_with model: @post, builder: WidgetFormBuilder do |f| %><%= f.fields :extra do |ef| %>)))
        .to eq("f" => "widget_form", "ef" => "widget_form")
    end

    it "reads fields on a bare local as a builder call when its block binds to fields, as a builder handed to a partial is" do
      [
        %(<%= f.fields :address do |address| %>),
        %(<%= f.fields(:address) do |address| %>),
        %(<%= f.fields(:address) { |address| %>)
      ].each { |content| expect(described_class.form_builders(content)).to eq("address" => "form"), content }
      [
        %(<% post.fields(:visible).each do |field| %>),
        %(<% post.itself.fields :x do |field| %>),
        %(<% Post.where(a: 1).fields :x do |post| %>),
        %(<% Post.where(a: 1).fields(:x).each do |post| %>),
        %(<% post.fields(:visible)&.each do |field| %>),
        %(<% Shop::form.fields :x do |field| %>)
      ].each { |content| expect(described_class.form_builders(content)).to eq({}), content }
    end

    it "reads no builder off fields on a local the template binds itself, unless a builder helper's block binds it" do
      [
        %(<% post = Post.new %><% post.fields :visible do |field| %>),
        %(<% post ||= Post.new %><% post.fields(:visible) do |field| %>),
        %(<% [Post.new].each do |post| %><% post.fields(:x) { |field| %><% } %><% end %>),
        %(<% @posts.each_with_index { |post, i| %><% post.fields :x do |field| %>)
      ].each { |content| expect(described_class.form_builders(content)).to eq({}), content }
      expect(described_class.form_builders(%(<%= form_with model: @post do |post| %><%= post.fields :extra do |ef| %>)))
        .to eq("post" => "form", "ef" => "form")
      [
        %(<% if f == other %><% f.fields :a do |a| %>),
        %(<% @f = 1; obj.f = 2 %><% f.fields :a do |a| %>),
        %(<button f="other"></button><% f.fields :a do |a| %>)
      ].each { |content| expect(described_class.form_builders(content)).to eq("a" => "form"), content }
      expect(described_class.form_builders(%(<% f.fields :a do |a| %><%= a.fields :b do |bb| %>))).to eq("a" => "form", "bb" => "form")
    end

    it "binds a local only where the template's Ruby does: never in a script or text, a block's parameter only inside it" do
      [
        %(<%= form.fields :x do |y| %>\n<script>const form = document.querySelector("form");</script>),
        %(<% [1].each do |f| %><% end %>\n<%= f.fields :x do |y| %>),
        %(<% fmt = ->(f) { f } %><%= f.fields :x do |y| %>),
        %(<% title = "f = 1" %><%= f.fields :x do |y| %>)
      ].each { |content| expect(described_class.form_builders(content)).to eq("y" => "form"), content }
    end

    it "binds a local only in a HAML or Slim template's Ruby, never in an attribute" do
      {
        %(button form=dom_id(@p)\n= form.fields :x do |y|\n  = render y\n) => "a.html.slim",
        %(%input(form=fid)\n= form.fields :x do |y|\n  = render y\n) => "a.html.haml"
      }.each { |content, path| expect(described_class.form_builders(content, path: path)).to eq("y" => "form"), content }
      expect(described_class.form_builders("%p Hi\n- post = Post.new\n- post.fields :v do |field|\n  = render field\n", path: "a.html.haml")).to eq({})
    end

    it "reads a local assigned a builder as that builder, with its class" do
      expect(described_class.form_builders(%(<%= form_with model: @post, builder: WidgetFormBuilder do |form| %><% f = form %><%= f.fields :x do |ef| %>)))
        .to eq("form" => "widget_form", "ef" => "widget_form")
      expect(described_class.form_builders(%(<% f = form %><%= f.fields :x do |ef| %>))).to eq("ef" => "form")
      expect(described_class.form_builders(%(<% post = Post.new %><% f = post %><% f.fields :x do |field| %>))).to eq({})
      expect(described_class.form_builders(%(<% f = form %><% f = Post.new %><% f.fields :x do |field| %>))).to eq({})
    end
  end
end
