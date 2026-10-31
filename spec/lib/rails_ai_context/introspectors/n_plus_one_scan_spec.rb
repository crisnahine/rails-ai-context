# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe RailsAiContext::Introspectors::NPlusOneScan do
  def risks_in(files, models)
    Dir.mktmpdir do |dir|
      files.each do |name, source|
        FileUtils.mkdir_p(File.dirname(File.join(dir, name)))
        File.write(File.join(dir, name), source)
      end
      described_class.new(dir, models).call
    end
  end

  let(:models) do
    {
      "Post" => { associations: [ { name: "user", type: "belongs_to" } ] },
      "User" => { associations: [ { name: "posts", type: "has_many" } ] }
    }
  end

  # ActionView reads the strict locals up to the `)` that closes the comment, so a call in a default does not end it.
  it "reads a strict locals default written after a default that calls a method" do
    risks = risks_in({
      "app/controllers/posts_controller.rb" => "class PostsController < ApplicationController\n  def index\n    @posts = Post.all\n  end\nend\n",
      "app/views/posts/index.html.erb" => "<%= render partial: \"posts/card\", collection: @posts, as: :post %>\n",
      "app/views/posts/_card.html.erb" => "<%# locals: (post:, heading: t(\".heading\"), show_author: false) -%>\n" \
                                          "<% if show_author %><%= post.user.name %><% end %>\n"
    }, models)

    expect(risks).to be_empty
  end

  it "does not read a word inside a scope's SQL string as a call to the scope of that name" do
    scoped = models.merge("Post" => models["Post"].merge(scopes: [
      { name: "recent", body: "where(\"source = 'syndicated'\")" }, { name: "syndicated", body: "includes(:user)" }
    ]))

    risks = risks_in({
      "app/controllers/posts_controller.rb" => "class PostsController < ApplicationController\n  def index\n    @posts = Post.recent\n  end\nend\n",
      "app/views/posts/index.html.erb" => "<% @posts.each do |post| %><%= post.user.name %><% end %>\n"
    }, scoped)

    expect(risks.map { |r| r.values_at(:model, :association, :risk) }).to eq([ [ "Post", "user", "high" ] ])
  end
end
