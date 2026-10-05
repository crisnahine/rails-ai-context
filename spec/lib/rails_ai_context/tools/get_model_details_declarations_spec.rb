# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

# What a model's own declarations say, read off the source the way both tiers
# read it, then printed by the tool.
RSpec.describe RailsAiContext::Tools::GetModelDetails do
  before { described_class.reset_cache! }

  def details_for(model, files)
    Dir.mktmpdir do |dir|
      files.each do |name, source|
        path = File.join(dir, "app", "models", name)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, source)
      end
      models = RailsAiContext::Introspectors::ModelIntrospector.new(RailsAiContext::StaticApp.new(dir)).static_call
      allow(described_class).to receive(:cached_context).and_return({ models: models })
      described_class.call(model: model).content.first[:text]
    end
  end

  it "prints attribute, alias_attribute and has_rich_text declarations" do
    text = details_for("User", "user.rb" => <<~RUBY)
      class User < ApplicationRecord
        attribute :nickname, :string, default: "anon"
        attribute :score, :integer
        alias_attribute :login, :email
        has_one_attached :avatar
        has_rich_text :bio
      end
    RUBY

    expect(text).to include("- `attribute` :nickname (string, default: \"anon\"), :score (integer)")
    expect(text).to include("- `alias_attribute` :login → :email")
    expect(text).to include("- `has_rich_text` :bio")
  end

  it "lists a default scope with the scopes, since it filters every query" do
    text = details_for("User", "user.rb" => <<~RUBY, "account.rb" => <<~ACCOUNT)
      class User < ApplicationRecord
        default_scope { where(discarded_at: nil) }
        scope :recent, -> { order(created_at: :desc) }
      end
    RUBY
      class Account < ApplicationRecord
        default_scope -> { where.not(state: "banned") }, all_queries: true
      end
    ACCOUNT

    expect(text).to include("## Scopes\n- `default_scope` → where(discarded_at: nil) _(applies to every query on User)_\n- `recent`")

    account = described_class.call(model: "Account").content.first[:text]
    expect(account).to include("- `default_scope` → where.not(state: \"banned\") (all_queries: true) _(applies to every query on Account)_")
  end

  describe "association options" do
    let(:files) do
      {
        "user.rb" => <<~RUBY,
          class User < ApplicationRecord
            belongs_to :account, counter_cache: true, touch: true, optional: true
            has_many :comments, as: :commentable
            has_many :posts, before_add: :check_limit, after_remove: :log_removal, extend: RecentFinder
            has_many :sessions do
              def active = where(active: true)
            end
          end
        RUBY
        "account.rb" => <<~RUBY,
          class Account < ApplicationRecord
            has_many :users, inverse_of: :account, strict_loading: true
            has_many :old_users, class_name: "User", deprecated: true
          end
        RUBY
        "profile.rb" => "class Profile < ApplicationRecord\n  belongs_to :user, required: false\n  belongs_to :owner\nend\n",
        "ticket.rb" => "class Ticket < ApplicationRecord\n  belongs_to :order, query_constraints: [:shop_id, :order_id], optional: true\nend\n"
      }
    end

    it "prints the options, callbacks and extensions an association declares" do
      user = details_for("User", files)

      expect(user).to include("- `belongs_to` **account** [optional] (counter_cache: true, touch: true) (fk: account_id)")
      expect(user).to include("- `has_many` **comments** (as: :commentable)")
      expect(user).to include("- `has_many` **posts** (before_add: :check_limit, after_remove: :log_removal, extend: RecentFinder)")
      expect(user).to include("- `has_many` **sessions** extension methods: active")

      account = described_class.call(model: "Account").content.first[:text]
      expect(account).to include("- `has_many` **users** (inverse_of: :account, strict_loading: true)")
      expect(account).to include("- `has_many` **old_users** (class: User) (deprecated: true)")
    end

    it "reads required: false as optional and query_constraints: as the foreign key" do
      details_for("Profile", files)

      profile = described_class.call(model: "Profile").content.first[:text]
      ticket = described_class.call(model: "Ticket").content.first[:text]

      expect(profile).to include("- `belongs_to` **user** [optional] (fk: user_id)")
      expect(profile).to include("- `belongs_to` **owner** (fk: owner_id)")
      expect(ticket).to include("- `belongs_to` **order** [optional] (fk: (shop_id, order_id))")
    end
  end

  it "lists a validate block as a custom validation" do
    text = details_for("User", "user.rb" => <<~RUBY)
      class User < ApplicationRecord
        validate :not_reserved
        validate on: :create do
          errors.add(:name, "bad") if name == "bad"
        end
      end
    RUBY

    expect(text).to include("- **Custom:** `not_reserved`\n- **Custom:** block (on: :create) → errors.add(:name, \"bad\") if name == \"bad\"")
  end

  describe "skip_callback" do
    let(:files) do
      {
        "application_record.rb" => <<~RUBY,
          class ApplicationRecord < ActiveRecord::Base
            primary_abstract_class
            before_save :stamp_audit
            after_commit :notify
          end
        RUBY
        "post.rb" => <<~RUBY,
          class Post < ApplicationRecord
            skip_callback :save, :before, :stamp_audit
            skip_callback :commit, :after, :notify, if: :draft?
          end
        RUBY
        "comment.rb" => "class Comment < ApplicationRecord\nend\n"
      }
    end

    it "drops a callback the model skips, and keeps a conditional skip as unless" do
      post = details_for("Post", files)
      comment = described_class.call(model: "Comment").content.first[:text]

      expect(post).not_to include("stamp_audit")
      expect(post).to include("- `after_commit`: :notify (unless: :draft?)")
      expect(comment).to include("- `before_save`: :stamp_audit")
    end
  end
end
