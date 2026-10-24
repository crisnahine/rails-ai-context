# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Introspectors::RenderCalls do
  describe ".render_locals" do
    it "reads a locals hash a trailing modifier follows" do
      expect(described_class.render_locals(%("posts/post", { post: @post } if @post))).to eq(%w[post])
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
