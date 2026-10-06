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
        attribute :price, MoneyType.new
        alias_attribute :login, :email
        has_one_attached :avatar
        has_rich_text :bio
      end
    RUBY

    expect(text).to include("- `attribute` :nickname (string, default: \"anon\"), :score (integer), :price (MoneyType.new)")
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

  it "lists a default scope defined as a class method, the form the Rails docs describe" do
    text = details_for("Tag", "tag.rb" => <<~RUBY, "badge.rb" => <<~BADGE)
      class Tag < ApplicationRecord
        def self.default_scope
          where.not(name: nil)
        end
      end
    RUBY
      class Badge < ApplicationRecord
        class << self
          def default_scope = where(active: true)
        end
      end
    BADGE

    expect(text).to include("- `default_scope` → where.not(name: nil) _(applies to every query on Tag)_")
    expect(described_class.call(model: "Badge").content.first[:text]).to include("- `default_scope` → where(active: true) _(applies to every query on Badge)_")
  end

  it "does not list a default scope a nested class or module declares" do
    text = details_for("Tag", "tag.rb" => <<~RUBY)
      class Tag < ApplicationRecord
        class Archived < Tag
          default_scope { where(archived: true) }
        end
        class Finder
          def self.default_scope = :nope
        end
        module Helpers
          class << self
            def default_scope = 1
          end
        end
      end
    RUBY

    expect(text).not_to include("default_scope")
  end

  it "lists a base's default scope ahead of the model's own, the order Rails stacks them, and the model's named scope over the base's" do
    text = details_for("Category", "application_record.rb" => <<~BASE, "category.rb" => <<~RUBY)
      class ApplicationRecord < ActiveRecord::Base
        primary_abstract_class
        default_scope { order(:id) }
        scope :recent, -> { order(created_at: :desc) }
      end
    BASE
      class Category < ApplicationRecord
        default_scope { where(name: "x") }
        scope :recent, -> { where(recent: true) }
      end
    RUBY

    expect(text).to match(/`default_scope` → order\(:id\).*\n- `default_scope` → where\(name: "x"\)/)
    expect(text).to include("`recent` → where(recent: true)")
    expect(text).not_to include("order(created_at: :desc)")
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
        "profile.rb" => "class Profile < ApplicationRecord\n  belongs_to :user, required: false\n  belongs_to :owner\n  belongs_to :team, optional: true, required: true\nend\n",
        "ticket.rb" => "class Ticket < ApplicationRecord\n  belongs_to :order, query_constraints: [:shop_id, :order_id], optional: true\n  has_many :lines, query_constraints: [:shop_id, :ticket_id]\nend\n"
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
      expect(profile).to include("- `belongs_to` **team** (fk: team_id)")
      expect(ticket).to include("- `belongs_to` **order** [optional] (fk: (shop_id, order_id))")
      expect(ticket).to include("- `has_many` **lines** (query_constraints: [:shop_id, :ticket_id])")
    end
  end

  it "prints the foreign key a has_many or has_one declares" do
    text = details_for("Person", "person.rb" => <<~RUBY)
      class Person < ApplicationRecord
        has_many :photos, :foreign_key => :author_id, :dependent => :destroy
        has_one :profile, foreign_key: "owner_id"
        has_many :posts
      end
    RUBY

    expect(text).to include("- `has_many` **photos** dependent: destroy (foreign_key: :author_id)")
    expect(text).to include("- `has_one` **profile** (foreign_key: owner_id)")
    expect(text).to include("- `has_many` **posts**\n")
  end

  it "lists the block of a validate that names a method too, since Rails runs both" do
    text = details_for("Override", "override.rb" => <<~RUBY)
      class Override < ApplicationRecord
        validate :set_id, unless: :concrete? do |record|
          record.errors.add(:set_id, "must be nil") if record.set_id
        end
      end
    RUBY

    expect(text).to include("- **Custom:** block (unless: :concrete?) → record.errors.add(:set_id, \"must be nil\") if record.set_id")
    expect(text).to include("- **Custom:** `set_id` (unless: :concrete?)")
  end

  it "prints the default of an enum whose values are a constant" do
    text = details_for("Amendment", "amendment.rb" => <<~RUBY)
      class Amendment < ApplicationRecord
        STATES = { draft: 0, accepted: 20 }.freeze
        enum :state, STATES, default: "draft"
      end
    RUBY

    expect(text).to include("- `state`: `STATES` (computed) default: draft")
  end

  it "prints the prefixed methods of a legacy array enum" do
    text = details_for("Ticket", "ticket.rb" => <<~RUBY)
      class Ticket < ApplicationRecord
        enum status: [:open, :closed], _prefix: true, _default: :open
      end
    RUBY

    expect(text).to include("status_open?, status_closed?")
    expect(text).to include("- `status`: open(0), closed(1) [integer]")
    expect(text).not_to include("values are computed")
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

    it "drops a callback object the model skips, whatever event the parent named with on:" do
      post = details_for("Post", files.merge(
        "application_record.rb" => "class ApplicationRecord < ActiveRecord::Base\n  primary_abstract_class\n  after_commit AuditTrail, on: :create\nend\n",
        "post.rb" => "class Post < ApplicationRecord\n  skip_callback :commit, :after, AuditTrail\nend\n"
      ))

      expect(post).not_to include("AuditTrail")
    end
  end

  it "names a callback object as the object, not as a method or a block" do
    text = details_for("Post", "post.rb" => <<~RUBY)
      class Post < ApplicationRecord
        after_commit AuditTrail
        before_validation PostNormalizer.new
        before_save -> { touch_later }
      end
    RUBY

    expect(text).to include("- `after_commit`: AuditTrail\n")
    expect(text).to include("- `before_validation`: PostNormalizer.new\n")
    expect(text).to include("- `before_save`: [inline_block]")
  end

  it "prints an enum's default and the method names its prefix or suffix gives" do
    text = details_for("Post", "post.rb" => <<~RUBY)
      class Post < ApplicationRecord
        enum :status, { active: 0, archived: 1 }, default: :active
        enum :kind, { lead: 0, customer: 1 }, prefix: true
        enum :tone, { warm: 0, cold: 1 }, suffix: :tone
        enum source: { web: 0, "in store": 1 }, _prefix: :from
      end
    RUBY

    expect(text).to include("- `status`: active(0), archived(1) [integer] default: active\n")
    expect(text).to include("- `kind`: lead(0), customer(1) [integer] methods: kind_lead?, kind_customer?\n")
    expect(text).to include("- `tone`: warm(0), cold(1) [integer] methods: warm_tone?, cold_tone?\n")
    expect(text).to include("- `source`: web(0), in store(1) [integer] methods: from_web?, from_in_store?")
  end

  it "reads half-written declarations without raising" do
    text = details_for("Odd", "odd.rb" => <<~RUBY)
      class Odd < ApplicationRecord
        alias_attribute :lonely
        skip_callback
        skip_callback :save
        default_scope Scoper
        validate do
        end
        has_many :things do
        end
        enum :level, Levels.to_h, prefix: compute_prefix
        enum :tier, { low: 0 }, suffix: compute_suffix
        after_save AuditTrail
      end
    RUBY

    expect(text).to include("- `default_scope` → [INFERRED] _(applies to every query on Odd)_")
    expect(text).to include("- **Custom:** block\n")
    expect(text).to include("- `has_many` **things**\n")
    expect(text).to include("- `after_save`: AuditTrail")
    expect(text).to include("- `tier`: low(0) [integer] methods: [INFERRED] (the prefix or suffix is computed)")
    expect(text).not_to include("alias_attribute")
  end

  it "names the methods a prefixed delegate defines, and marks a private one" do
    text = details_for("Gadget", "gadget.rb" => <<~RUBY)
      class Gadget < ApplicationRecord
        delegate :name, to: :owner, prefix: true
        delegate :email, to: :owner, prefix: :contact, private: true
        delegate :title, to: :owner
        delegate :size, to: :owner, prefix: compute_prefix
        delegate :lost, prefix: true
        delegate
      end
    RUBY

    expect(text).to include("- delegate :name to: :owner → owner_name\n")
    expect(text).to include("- delegate :email to: :owner → contact_email (private)\n")
    expect(text).to include("- delegate :title to: :owner\n")
    expect(text).to include("- delegate :size to: :owner → [INFERRED] (the prefix is computed)\n")
    expect(text).not_to include("_lost")
  end

  it "groups store keys under their column with the accessor names Rails defines" do
    text = details_for("User", "user.rb" => <<~RUBY)
      class User < ApplicationRecord
        store :settings, accessors: [:theme, :locale], coder: JSON
        store_accessor :preferences, :color, :font, prefix: :pref
        store_accessor :preferences, :size, suffix: true
        store_accessor :meta, [:a], prefix: true
        store :blob
        store_accessor :odd, :x, prefix: compute_prefix
      end
    RUBY

    expect(text).to include("- `store` :settings (theme, locale), :preferences (pref_color, pref_font, size_preferences), " \
                            ":meta (meta_a), :blob, :odd ([INFERRED]: the prefix or suffix is computed)\n")
  end

  describe "ignored_columns" do
    def details_with_schema(model, files, columns)
      Dir.mktmpdir do |dir|
        files.each do |name, source|
          path = File.join(dir, "app", "models", name)
          FileUtils.mkdir_p(File.dirname(path))
          File.write(path, source)
        end
        models = RailsAiContext::Introspectors::ModelIntrospector.new(RailsAiContext::StaticApp.new(dir)).static_call
        schema = { tables: { "users" => { columns: columns.map { |c| { name: c, type: "string" } } } } }
        allow(described_class).to receive(:cached_context).and_return({ models: models, schema: schema })
        described_class.call(model: model).content.first[:text]
      end
    end

    it "leaves an ignored column out of Columns and says the model drops it" do
      text = details_with_schema("User", { "user.rb" => <<~RUBY }, %w[name legacy_col])
        class User < ApplicationRecord
          self.ignored_columns += ["legacy_col"]
        end
      RUBY

      expect(text).to include("- **name** | string")
      expect(text).not_to include("- **legacy_col**")
      expect(text).to include("**Ignored columns:** `legacy_col` _(the model cannot read or write them)_")
    end

    it "applies a base's assignment before a subclass adds to it" do
      files = {
        "application_record.rb" => "class ApplicationRecord < ActiveRecord::Base\n  primary_abstract_class\n  self.ignored_columns = %w[old]\nend\n",
        "user.rb" => "class User < ApplicationRecord\n  self.ignored_columns += %i[legacy_col]\nend\n"
      }
      text = details_with_schema("User", files, %w[name old legacy_col])

      expect(text).to include("**Ignored columns:** `old`, `legacy_col`")
      expect(text).not_to include("- **old**")
    end

    it "says when the ignored list is computed" do
      text = details_with_schema("User", { "user.rb" => <<~RUBY }, %w[name legacy_col])
        class User < ApplicationRecord
          self.ignored_columns = LEGACY
          self.ignored_columns +=
        end
      RUBY

      expect(text).to include("- **legacy_col** | string")
      expect(text).to include("**Ignored columns:** [INFERRED] (computed in the source)")
    end
  end

  it "reads delegated_type as the polymorphic belongs_to it declares, and lists has_secure_token and nested attributes" do
    text = details_for("Note", "note.rb" => <<~RUBY)
      class Note < ApplicationRecord
        delegated_type :noteable, types: %w[Memo Reminder], dependent: :destroy
        has_secure_token :share_token
        has_secure_token
        has_many :comments
        has_many :tags
        accepts_nested_attributes_for :comments, :tags, allow_destroy: true
        delegated_type
        accepts_nested_attributes_for
      end
    RUBY

    expect(text).to include("- `belongs_to` **noteable** [polymorphic] dependent: destroy (delegated types: Memo, Reminder) (fk: noteable_id)\n")
    expect(text).to include("- `has_secure_token` :share_token, :token\n")
    expect(text).to include("- `accepts_nested_attributes_for` :comments, :tags (allow_destroy: true)\n")
  end

  it "names the expression a delegated_type's types come from when the source holds no literal list" do
    text = details_for("Entry", "entry.rb" => "class Entry < ApplicationRecord\n  delegated_type :entryable, types: Entryable::TYPES\nend\n")

    expect(text).to include("- `belongs_to` **entryable** [polymorphic] (delegated types: from `Entryable::TYPES`, not read statically) (fk: entryable_id)\n")
  end

  it "reads a delegated_type's types from the booted model when the source holds no literal list" do
    introspector = RailsAiContext::Introspectors::ModelIntrospector.new(Rails.application)
    model = double("Entry", entryable_types: %w[Memo Reminder])
    source = { type: "belongs_to", name: :entryable, delegated: true, delegated_types_source: "Entryable::TYPES", options: { polymorphic: "true" } }

    detail = introspector.send(:with_declared_options, { type: "belongs_to", name: "entryable" }, source, model)

    expect(detail[:delegated_types]).to eq(%w[Memo Reminder])
    expect(detail).not_to have_key(:delegated_types_source)
  end
end
