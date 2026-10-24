# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Introspectors::RenderedRecord do
  around do |example|
    Dir.mktmpdir("rendered-record") do |root|
      @root = root
      FileUtils.mkdir_p(File.join(root, "app/models"))
      File.write(File.join(root, "app/models/comment.rb"), <<~RUBY)
        class Comment < ApplicationRecord
          belongs_to :commentable, polymorphic: true
          belongs_to :author, class_name: "::Blog::User"
        end
      RUBY
      example.run
    end
  end

  it "follows a namespaced class_name to that model's default partial" do
    model, = described_class.resolve("comment.author", @root)

    expect(model).to eq("blog/user")
    expect(described_class.partial_path(model, @root)).to eq("blog/users/user")
  end

  it "reads a receiver that is no model by the records the next name holds" do
    expect(described_class.resolve("current_user.comments.recent", @root)).to eq([ "comment", true ])
    expect(described_class.resolve("current_account.widgets", @root)).to be_nil
  end

  it "reads a receiver kept outside the model directories, a service or presenter, by the next name" do
    { "app/services/cart.rb" => "class Cart\n  def items = Comment.all\nend\n",
      "app/presenters/search.rb" => "class Search\n  def results = Comment.all\nend\n" }.each do |path, source|
      FileUtils.mkdir_p(File.dirname(File.join(@root, path)))
      File.write(File.join(@root, path), source)
    end

    expect(described_class.resolve("carts.comments", @root)).to eq([ "comment", true ])
    expect(described_class.resolve("cart.comments", @root)).to eq([ "comment", true ])
    expect(described_class.resolve("search.comments", @root)).to eq([ "comment", true ])
  end

  def models(files)
    files.each do |name, source|
      FileUtils.mkdir_p(File.dirname(File.join(@root, "app/models/#{name}.rb")))
      File.write(File.join(@root, "app/models/#{name}.rb"), source)
    end
  end

  it "credits nothing for a through association whose hop's model has no file here" do
    models("user" => "class User < ApplicationRecord\n  has_many :posts\n  has_many :feedback, through: :posts, source: :comments\nend\n")

    expect(described_class.resolve("user.feedback", @root)).to be_nil
    expect(described_class.resolve("user.posts", @root)).to eq([ "post", true ])
  end

  it "reads the hop's model from whichever autoload root holds it, a pack's included" do
    models("user" => "class User < ApplicationRecord\n  has_many :posts\n  has_many :comments, through: :posts\nend\n")
    FileUtils.mkdir_p(File.join(@root, "packs/blog/app/models"))
    File.write(File.join(@root, "packs/blog/app/models/post.rb"),
               "class Post < ApplicationRecord\n  has_many :comments, class_name: \"Remark\"\nend\n")

    expect(described_class.resolve("user.comments", @root)).to eq([ "remark", true ])
  end

  it "credits nothing for a through association whose source no file or ancestor declares, as Rails raises on it" do
    models("project" => "class Project < ApplicationRecord\n  has_many :mappings\n  has_many :types, through: :mappings\nend\n",
           "mapping" => "class Mapping < ApplicationRecord\n  belongs_to :variant\nend\n")

    expect(described_class.resolve("project.types", @root)).to be_nil
  end

  it "derives a through association's class when a concern's included block declares the hop" do
    models("order" => "class Order < ApplicationRecord\n  include Subscribable\n  has_many :readers, through: :subscriptions\nend\n",
           "concerns/subscribable" => "module Subscribable\n  extend ActiveSupport::Concern\n  included do\n    has_many :subscriptions\n  end\nend\n",
           "subscription" => "class Subscription < ApplicationRecord\n  belongs_to :reader\nend\n")

    expect(described_class.resolve("order.readers", @root)).to eq([ "reader", true ])
  end

  it "derives a through association's class when the source is declared on an STI parent" do
    models("group" => "class Group < ApplicationRecord\n  has_many :memberships\n  has_many :members, through: :memberships\nend\n",
           "membership" => "class Membership < BaseMembership\nend\n",
           "base_membership" => "class BaseMembership < ApplicationRecord\n  belongs_to :member\nend\n")

    expect(described_class.resolve("group.members", @root)).to eq([ "member", true ])
  end

  it "reads the class_name an STI parent declares for the source" do
    models("group" => "class Group < ApplicationRecord\n  has_many :memberships\n  has_many :members, through: :memberships\nend\n",
           "membership" => "class Membership < BaseMembership\nend\n",
           "base_membership" => "class BaseMembership < ApplicationRecord\n  belongs_to :member, class_name: \"User\"\nend\n")

    expect(described_class.resolve("group.members", @root)).to eq([ "user", true ])
  end

  it "reads an acronym parent model under its own name, as the app's inflector spells it" do
    models("page" => "class Page < ApplicationRecord\nend\n",
           "link" => "class Link < ApplicationRecord\n  belongs_to :target, class_name: \"Page\"\nend\n",
           "base_page" => "class BasePage < ApplicationRecord\n  self.abstract_class = true\n  has_many :links\nend\n",
           "html_page" => "class HTMLPage < BasePage\nend\n",
           "child_page" => "class ChildPage < HTMLPage\n  has_many :targets, through: :links\nend\n")
    FileUtils.mkdir_p(File.join(@root, "config/initializers"))
    File.write(File.join(@root, "config/initializers/zeitwerk.rb"),
               "Rails.autoloaders.each { |loader| loader.inflector.inflect(\"html_page\" => \"HTMLPage\") }\n")

    resolved = RailsAiContext::RunCache.around_app(RailsAiContext::StaticApp.new(@root)) { described_class.resolve("child_page.targets", @root) }
    expect(resolved).to eq([ "page", true ])
  end

  it "reads a model whose constant only the app's Zeitwerk inflector spells, reached as a receiver or an association target" do
    models("site" => "class Site < ApplicationRecord\n  has_many :pages, class_name: \"HTMLPage\"\n  has_many :page_links, through: :pages, source: :links\nend\n",
           "base_page" => "class BasePage < ApplicationRecord\n  self.abstract_class = true\n  has_many :links\nend\n",
           "html_page" => "class HTMLPage < BasePage\n  def to_partial_path = \"pages/html\"\nend\n",
           "link" => "class Link < ApplicationRecord\n  belongs_to :page, class_name: \"HTMLPage\"\nend\n")
    FileUtils.mkdir_p(File.join(@root, "config/initializers"))
    File.write(File.join(@root, "config/initializers/zeitwerk.rb"),
               "Rails.autoloaders.each { |loader| loader.inflector.inflect(\"html_page\" => \"HTMLPage\") }\n")

    partials = RailsAiContext::RunCache.around_app(RailsAiContext::StaticApp.new(@root)) do
      %w[html_page.links site.page_links site.pages link.page].map do |chain|
        model, = described_class.resolve(chain, @root)
        model && described_class.partial_path(model, @root)
      end
    end
    expect(partials).to eq(%w[links/link links/link pages/html pages/html])
  end

  it "reads the hop's class off the concern that declares it" do
    models("order" => "class Order < ApplicationRecord\n  include Subscribable\n  has_many :readers, through: :subscriptions\nend\n",
           "concerns/subscribable" => "module Subscribable\n  extend ActiveSupport::Concern\n  included do\n" \
                                      "    has_many :subscriptions, class_name: \"Follow\"\n  end\nend\n",
           "follow" => "class Follow < ApplicationRecord\n  belongs_to :reader, class_name: \"User\"\nend\n")

    expect(described_class.resolve("order.readers", @root)).to eq([ "user", true ])
  end

  it "credits nothing for a hop no file, included concern or parent model declares" do
    models("order" => "class Order < ApplicationRecord\n  include Comparable\n  has_many :readers, through: :subscriptions\nend\n",
           "group" => "class Group < ApplicationRecord\n  has_many :memberships\n  has_many :members, through: :memberships\nend\n",
           "membership" => "class Membership < ApplicationRecord\n  class Error < StandardError\n  end\nend\n")

    expect(described_class.resolve("order.readers", @root)).to be_nil
    expect(described_class.resolve("group.members", @root)).to be_nil
  end

  it "credits nothing for a hop missing from an owner that includes and inherits nothing" do
    models("order" => "class Order < ApplicationRecord\n  has_many :readers, through: :subscriptions\nend\n")

    expect(described_class.resolve("order.readers", @root)).to be_nil
  end

  it "resolves nothing through a source the hop's model declares polymorphic" do
    models("post" => "class Post < ApplicationRecord\n  has_many :taggings\n  has_many :taggables, through: :taggings, source: :taggable\nend\n",
           "tagging" => "class Tagging < ApplicationRecord\n  belongs_to :taggable, polymorphic: true\nend\n")

    expect(described_class.resolve("post.taggables", @root)).to be_nil
  end

  it "reads class_name ahead of source_type on a through association, as Rails does" do
    models("post" => "class Post < ApplicationRecord\n  has_many :taggings\n" \
                     "  has_many :stories, through: :taggings, source: :taggable, source_type: \"Article\", class_name: \"Story\"\n" \
                     "  has_many :articles, through: :taggings, source: :taggable, source_type: \"Article\"\nend\n")

    expect(described_class.resolve("post.stories", @root)).to eq([ "story", true ])
    expect(described_class.resolve("post.articles", @root)).to eq([ "article", true ])
  end

  it "reads a through association's class off its source on the model the hop reaches" do
    { "post" => "class Post < ApplicationRecord\n  has_many :subscriptions\n  has_many :taggings\n" \
                "  has_many :readers, through: :subscriptions\n  has_many :tags, through: :taggings\nend\n",
      "subscription" => "class Subscription < ApplicationRecord\n  belongs_to :reader, class_name: \"User\"\nend\n",
      "tagging" => "class Tagging < ApplicationRecord\n  belongs_to :tag\nend\n" }.each do |name, source|
      File.write(File.join(@root, "app/models/#{name}.rb"), source)
    end

    expect(described_class.resolve("post.readers", @root)).to eq([ "user", true ])
    expect(described_class.resolve("post.tags", @root)).to eq([ "tag", true ])
  end

  it "keeps a singular association's name as Rails does, singularizing only a collection's" do
    File.write(File.join(@root, "app/models/post.rb"),
               "class Post < ApplicationRecord\n  belongs_to :preferences\n  has_many :comments\nend\n")

    expect(described_class.resolve("post.preferences", @root)).to eq([ "preferences", false ])
    expect(described_class.resolve("post.comments", @root)).to eq([ "comment", true ])
  end

  it "resolves nothing through a polymorphic association or an unknown call on one record" do
    expect(described_class.resolve("comment.commentable", @root)).to be_nil
    expect(described_class.resolve("comment.summary", @root)).to be_nil
    expect(described_class.resolve("comments.recent", @root)).to eq([ "comment", true ])
  end

  it "walks a concern and finds a parent model's file once in a run, however many models reach them" do
    models("group" => "class Group < ApplicationRecord\n  has_many :memberships\n  has_many :invites\n" \
                      "  has_many :members, through: :memberships\n  has_many :guests, through: :invites\nend\n",
           "membership" => "class Membership < BaseMembership\n  include Tracked\nend\n",
           "invite" => "class Invite < BaseMembership\n  include Tracked\nend\n",
           "base_membership" => "class BaseMembership < ApplicationRecord\n  self.abstract_class = true\n  belongs_to :member\n  belongs_to :guest\nend\n",
           "concerns/tracked" => "module Tracked\n  extend ActiveSupport::Concern\n  included do\n    has_many :tracks\n  end\nend\n")
    walks = 0
    allow(RailsAiContext::Introspectors::SourceIntrospector).to receive(:walk).and_wrap_original do |original, path, *rest|
      walks += 1 if path.to_s.end_with?("concerns/tracked.rb")
      original.call(path, *rest)
    end
    allow(RailsAiContext::PathResolver).to receive(:file_for_constant).and_call_original

    resolved = RailsAiContext::RunCache.around do
      memo = {}
      [ described_class.resolve("group.members", @root, memo), described_class.resolve("group.guests", @root, memo) ]
    end

    expect(resolved).to eq([ [ "member", true ], [ "guest", true ] ])
    expect(walks).to eq(1)
    expect(RailsAiContext::PathResolver).to have_received(:file_for_constant).with(@root, "BaseMembership").once
  end
end
