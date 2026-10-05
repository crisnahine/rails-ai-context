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
end
