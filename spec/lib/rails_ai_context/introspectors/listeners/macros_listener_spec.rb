# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Introspectors::Listeners::MacrosListener do
  it "detects has_secure_password" do
    results = parse_and_dispatch("has_secure_password")
    expect(results.size).to eq(1)
    expect(results.first[:macro]).to eq(:has_secure_password)
  end

  it "detects encrypts with attribute" do
    results = parse_and_dispatch("encrypts :ssn, deterministic: true")
    expect(results.first[:macro]).to eq(:encrypts)
    expect(results.first[:attribute]).to eq("ssn")
    expect(results.first[:options]).to include(deterministic: true)
  end

  it "detects normalizes" do
    results = parse_and_dispatch("normalizes :email, with: ->(e) { e.strip }")
    expect(results.first[:macro]).to eq(:normalizes)
    expect(results.first[:attribute]).to eq("email")
  end

  it "detects has_one_attached" do
    results = parse_and_dispatch("has_one_attached :avatar")
    expect(results.first[:macro]).to eq(:has_one_attached)
    expect(results.first[:attribute]).to eq("avatar")
  end

  it "detects has_many_attached" do
    results = parse_and_dispatch("has_many_attached :documents")
    expect(results.first[:macro]).to eq(:has_many_attached)
    expect(results.first[:attribute]).to eq("documents")
  end

  it "detects has_rich_text" do
    results = parse_and_dispatch("has_rich_text :content")
    expect(results.first[:macro]).to eq(:has_rich_text)
    expect(results.first[:attribute]).to eq("content")
  end

  it "detects broadcasts_to" do
    results = parse_and_dispatch("broadcasts_to :company")
    expect(results.first[:macro]).to eq(:broadcasts_to)
    expect(results.first[:target]).to eq("company")
  end

  it "detects broadcasts_refreshes, which takes no stream" do
    expect(parse_and_dispatch("broadcasts_refreshes").map { |r| r[:macro] }).to eq([ :broadcasts_refreshes ])
  end

  it "detects generates_token_for" do
    results = parse_and_dispatch("generates_token_for :email_verification, expires_in: 2.hours")
    expect(results.first[:macro]).to eq(:generates_token_for)
    expect(results.first[:attribute]).to eq("email_verification")
  end

  it "detects serialize" do
    results = parse_and_dispatch("serialize :preferences")
    expect(results.first[:macro]).to eq(:serialize)
    expect(results.first[:attribute]).to eq("preferences")
  end

  it "detects store" do
    results = parse_and_dispatch("store :settings, accessors: [:theme]")
    expect(results.first[:macro]).to eq(:store)
    expect(results.first[:attribute]).to eq("settings")
  end

  it "detects delegate with to:" do
    results = parse_and_dispatch("delegate :name, :email, to: :user")
    expect(results.first[:macro]).to eq(:delegate)
    expect(results.first[:methods]).to contain_exactly("name", "email")
    expect(results.first[:to]).to eq("user")
  end

  it "detects delegate_missing_to" do
    results = parse_and_dispatch("delegate_missing_to :profile")
    expect(results.first[:macro]).to eq(:delegate_missing_to)
    expect(results.first[:to]).to eq("profile")
  end

  it "detects attribute API declarations" do
    results = parse_and_dispatch("attribute :score, :integer")
    expect(results.first[:macro]).to eq(:attribute)
    expect(results.first[:attribute]).to eq("score")
    expect(results.first[:type]).to eq("integer")
  end

  it "includes confidence tags" do
    results = parse_and_dispatch("encrypts :ssn")
    expect(results.first[:confidence]).to eq("[VERIFIED]")
  end
end

RSpec.describe RailsAiContext::Introspectors::Listeners::MacrosListener, "gem macros" do
  it "reads an aasm block's states, initial state, events and transitions" do
    results = parse_and_dispatch(<<~RUBY)
      class Order < ApplicationRecord
        include AASM
        aasm column: :status do
          state :pending, initial: true
          state :paid, :shipped
          event :pay do
            transitions from: :pending, to: :paid
          end
          event :ship do
            transitions from: [ :paid, :pending ], to: :shipped
          end
        end
      end
    RUBY
    aasm = results.find { |r| r[:macro] == :aasm }
    expect(aasm).to include(column: "status", initial: "pending", states: %w[pending paid shipped])
    expect(aasm[:events]).to eq([
      { name: "pay", transitions: [ { from: %w[pending], to: "paid" } ] },
      { name: "ship", transitions: [ { from: %w[paid pending], to: "shipped" } ] }
    ])
    expect(results.map { |r| r[:macro] }).to eq([ :aasm ])
  end

  it "takes a named machine's column from its name and the first state as initial" do
    results = parse_and_dispatch(<<~RUBY)
      class Job < ApplicationRecord
        aasm :work do
          state :sleeping
          state :running
          event { transitions to: :running }
          transitions to: :sleeping
        end
      end
    RUBY
    expect(results.first).to include(column: "work", initial: "sleeping", states: %w[sleeping running], events: [])
  end

  it "opens a machine only for the class-level aasm DSL, not the aasm reader a method calls" do
    results = parse_and_dispatch(<<~RUBY)
      class Order < ApplicationRecord
        aasm do
          state :pending
        end
        aasm
        def state_label
          aasm.current_state.to_s
        end
      end
    RUBY
    expect(results.map { |r| [ r[:macro], r[:states] ] }).to eq([ [ :aasm, %w[pending] ] ])
  end

  it "records each known gem macro as written, without its block" do
    results = parse_and_dispatch(<<~RUBY)
      class User < ApplicationRecord
        has_paper_trail
        friendly_id :name, use: :slugged
        mount_uploader :avatar, AvatarUploader
        pg_search_scope :search_by_title, against: :title
        monetize :price_cents
        monetize :fee_pence, as: :fee
        acts_as_list scope: :category
        acts_as_tenant :organization
        state_machine :state, initial: :parked do
          event(:ignite) { transition parked: :idling }
        end
      end
    RUBY
    texts = results.select { |r| r[:macro] == :gem_macro }.map { |r| r[:text] }
    expect(texts).to eq([
      "has_paper_trail", "friendly_id :name, use: :slugged", "mount_uploader :avatar, AvatarUploader",
      "pg_search_scope :search_by_title, against: :title", "monetize :price_cents",
      "monetize :fee_pence, as: :fee", "acts_as_list scope: :category",
      "acts_as_tenant :organization", "state_machine :state, initial: :parked"
    ])
    expect(results.find { |r| r[:text] == "has_paper_trail" }[:name]).to eq(:has_paper_trail)
    expect(results.filter_map { |r| r[:adds] }).to eq([ %w[price], %w[fee] ])
  end

  it "folds a gem macro onto one line without its comments or line continuations" do
    results = parse_and_dispatch(<<~RUBY)
      class Txn < ApplicationRecord
        pg_search_scope :search, lambda { |query|
          {
            query: query,
            # Keep in sync
            order_within_rank: 'txns.completed_at DESC, ' \\
                               'txns.created_at DESC'
          }
        }
      end
    RUBY

    expect(results.find { |r| r[:macro] == :gem_macro }[:text]).to eq(
      "pg_search_scope :search, lambda { |query| { query: query, order_within_rank: 'txns.completed_at DESC, ' 'txns.created_at DESC' } }"
    )
  end
end

RSpec.describe RailsAiContext::Introspectors::Listeners::MacrosListener, "model settings" do
  it "reads the class settings that change how the model behaves, as written" do
    results = parse_and_dispatch(<<~RUBY)
      class Post < ApplicationRecord
        self.inheritance_column = :kind
        self.store_full_sti_class = false
        self.strict_loading_by_default = true
        self.implicit_order_column = "published_at"
        self.locking_column = :row_version
        attr_readonly :email_address, :slug
        query_constraints :order_shop_id, :id
      end
    RUBY
    settings = results.select { |r| r[:macro] == :model_setting }.map { |r| [ r[:setting], r[:value] ] }
    expect(settings).to eq([
      [ "inheritance_column", ":kind" ], [ "store_full_sti_class", "false" ], [ "strict_loading_by_default", "true" ],
      [ "implicit_order_column", "\"published_at\"" ], [ "locking_column", ":row_version" ]
    ])
    expect(results.select { |r| r[:macro] == :attr_readonly }.map { |r| r[:attribute] }).to eq(%w[email_address slug])
    expect(results.select { |r| r[:macro] == :query_constraints }.map { |r| r[:attribute] }).to eq(%w[order_shop_id id])
  end
end

RSpec.describe RailsAiContext::Introspectors::Listeners::MacrosListener, "options as written" do
  it "keeps every option of encrypts, normalizes, serialize, generates_token_for and has_secure_password" do
    results = parse_and_dispatch(<<~RUBY)
      class User < ApplicationRecord
        has_secure_password
        has_secure_password :recovery_password, validations: false
        generates_token_for :email_confirmation, expires_in: 2.days do
          email_address
        end
        normalizes :phone, with: ->(p) { p&.delete("^0-9") }, apply_to_nil: true
        encrypts :phone, deterministic: true, ignore_case: true, previous: { deterministic: false }, support_unencrypted_data: true
        serialize :tags_cache, coder: JSON, type: Array
      end
    RUBY
    written = results.map { |r| [ r[:macro], r[:attribute], r[:written] ] }
    expect(written).to eq([
      [ :has_secure_password, "password", {} ],
      [ :has_secure_password, "recovery_password", { validations: "false" } ],
      [ :generates_token_for, "email_confirmation", { expires_in: "2.days" } ],
      [ :normalizes, "phone", { with: "->(p) { p&.delete(\"^0-9\") }", apply_to_nil: "true" } ],
      [ :encrypts, "phone", { deterministic: "true", ignore_case: "true", previous: "{ deterministic: false }", support_unencrypted_data: "true" } ],
      [ :serialize, "tags_cache", { coder: "JSON", type: "Array" } ]
    ])
  end
end

RSpec.describe RailsAiContext::Introspectors::Listeners::MacrosListener, "multibyte source" do
  it "cuts a gem macro at its block by byte offset, past a multibyte label and comment" do
    results = parse_and_dispatch(<<~RUBY)
      class Car < ApplicationRecord
        state_machine :status, initial: :brouillon, label: "état créé" do # étiquette
        end
      end
    RUBY
    expect(results.map { |r| r[:text] }).to eq([ 'state_machine :status, initial: :brouillon, label: "état créé"' ])
  end

  it "cuts a comment out of a call by byte offset, after a multibyte string" do
    results = parse_and_dispatch(<<~RUBY)
      class Car < ApplicationRecord
        has_paper_trail meta: { a: "é" }, # note
          on: [:update]
      end
    RUBY
    expect(results.map { |r| r[:text] }).to eq([ 'has_paper_trail meta: { a: "é" }, on: [:update]' ])
  end
end

RSpec.describe RailsAiContext::Introspectors::Listeners::MacrosListener, "connects_to" do
  it "records the call as written" do
    results = parse_and_dispatch(<<~RUBY)
      class ShardRecord < ApplicationRecord
        self.abstract_class = true
        connects_to shards: {
          shard_one: { writing: :shard_one }
        }
      end
    RUBY
    expect(results.map { |r| r.slice(:macro, :text) }).to eq([ { macro: :connects_to, text: "connects_to shards: { shard_one: { writing: :shard_one } }" } ])
  end

  it "names the case branch a connects_to sits in, and builds no branch text a walk never reads" do
    listener = described_class.new
    source = <<~RUBY
      class ShardRecord < ApplicationRecord
        case ENV["DB"]
        when "a" then connects_to database: { writing: :a }
        end
        def x
          case y
          when 1 then a && b
          end
        end
      end
    RUBY
    RailsAiContext::Introspectors::ListenerRegistration.dispatcher_for(listener).dispatch(Prism.parse(source).value)

    expect(listener.results.map { |r| r[:condition] }).to eq([ %(when ENV["DB"] is "a") ])
    expect(listener.send(:case_branches).values.grep(String)).to be_empty
  end
end

RSpec.describe RailsAiContext::Introspectors::Listeners::MacrosListener, "scope" do
  it "leaves out a macro or setting a method body runs, and keeps one a mixin hook sends to the includer" do
    results = parse_and_dispatch(<<~RUBY)
      class Gadget < ApplicationRecord
        def self.with_lock
          self.locking_column = :temp_lock
          self.ignored_columns += %w[a]
          has_paper_trail
        end
        def touch_all
          encrypts :token
        end
      end
      module Trackable
        def self.included(base)
          base.encrypts :ssn
        end
      end
    RUBY
    expect(results.map { |r| [ r[:macro], r[:attribute] ] }).to eq([ [ :encrypts, "ssn" ] ])
  end

  it "reads the macros a mixin hook's class_eval block declares on the includer" do
    results = parse_and_dispatch(<<~RUBY)
      module Tokened
        def self.included(base)
          base.class_eval do
            serialize :prefs, coder: JSON
            has_secure_token :api_key
            self.ignored_columns += %w[legacy]
            def rotate
              encrypts :never
            end
          end
          encrypts :not_on_includer
        end
      end
    RUBY
    expect(results.map { |r| r[:macro] }).to eq(%i[serialize has_secure_token ignored_columns])
  end

  it "names the class each record is written in, so a nested class keeps its own" do
    results = parse_and_dispatch(<<~RUBY)
      class Gadget < ApplicationRecord
        self.locking_column = :lock_version
        class Part < ApplicationRecord
          self.implicit_order_column = "made_at"
          has_paper_trail
        end
      end
    RUBY
    expect(results.map { |r| [ r[:macro], r[:owner] ] }).to eq([
      [ :model_setting, %w[Gadget] ], [ :model_setting, %w[Gadget Part] ], [ :gem_macro, %w[Gadget Part] ]
    ])
  end
end
