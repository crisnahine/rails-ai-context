# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Introspectors::Listeners::AssociationsListener do
  it "detects belongs_to" do
    results = parse_and_dispatch("belongs_to :user")
    expect(results.size).to eq(1)
    expect(results.first).to include(type: "belongs_to", name: :user)
  end

  it "detects has_many with options" do
    results = parse_and_dispatch("has_many :posts, dependent: :destroy")
    expect(results.first).to include(type: "has_many", name: :posts)
    expect(results.first[:options]).to include(dependent: :destroy)
  end

  it "reads an option off an enclosing with_options block" do
    results = parse_and_dispatch(<<~RUBY)
      with_options dependent: :destroy do
        has_many :statuses
      end

      has_many :mentions
    RUBY

    inside, outside = results.partition { |r| r[:name] == :statuses }.map(&:first)
    expect(inside[:options]).to include(dependent: :destroy)
    expect(outside[:options]).not_to include(:dependent)
  end

  it "lets the association's own option win over the enclosing one" do
    results = parse_and_dispatch(<<~RUBY)
      with_options dependent: :destroy do
        has_many :statuses, dependent: :nullify
      end
    RUBY

    expect(results.first[:options]).to include(dependent: :nullify)
  end

  # with_options instance_evals a zero-arity block but CALLS one that takes a
  # parameter, so only calls on that parameter are re-sent with the options.
  it "reads the options off the block parameter the merger is passed to" do
    results = parse_and_dispatch(<<~RUBY)
      with_options dependent: :destroy do |assoc|
        assoc.has_many :tags
      end
    RUBY

    expect(results.first).to include(type: "has_many", name: :tags)
    expect(results.first[:options]).to include(dependent: :destroy)
  end

  it "gives a receiverless association inside a block-parameter with_options nothing" do
    results = parse_and_dispatch(<<~RUBY)
      with_options dependent: :destroy do |assoc|
        has_many :mentions
      end
    RUBY

    expect(results.first).to include(name: :mentions)
    expect(results.first[:options]).not_to include(:dependent)
  end

  it "ignores a call on a receiver no with_options block named" do
    results = parse_and_dispatch(<<~RUBY)
      other.has_many :tags
    RUBY

    expect(results).to be_empty
  end

  it "restores the enclosing options after the block ends" do
    results = parse_and_dispatch(<<~RUBY)
      with_options dependent: :destroy do
        has_many :statuses
      end

      with_options autosave: true do
        has_many :favourites
      end

      has_many :mentions
    RUBY

    by_name = results.to_h { |r| [ r[:name], r[:options] ] }
    expect(by_name[:statuses]).to eq(dependent: :destroy)
    expect(by_name[:favourites]).to eq(autosave: true)
    expect(by_name[:mentions]).to eq({})
  end

  it "merges nested with_options blocks, the inner one winning" do
    results = parse_and_dispatch(<<~RUBY)
      with_options dependent: :destroy, autosave: true do
        with_options dependent: :nullify do
          has_many :statuses
        end
      end
    RUBY

    expect(results.first[:options]).to eq(dependent: :nullify, autosave: true)
  end

  it "detects has_one" do
    results = parse_and_dispatch("has_one :profile, dependent: :destroy")
    expect(results.first).to include(type: "has_one", name: :profile)
  end

  it "detects has_and_belongs_to_many" do
    results = parse_and_dispatch("has_and_belongs_to_many :tags")
    expect(results.first).to include(type: "has_and_belongs_to_many", name: :tags)
  end

  it "spells the macro the way the booted tier does" do
    results = parse_and_dispatch("has_many :posts")
    expect(results.first[:type]).to be_a(String)
  end

  it "ignores method calls with a receiver" do
    results = parse_and_dispatch("self.has_many :posts")
    expect(results).to be_empty
  end

  it "marks static-arg associations as VERIFIED" do
    results = parse_and_dispatch("belongs_to :user, optional: true")
    expect(results.first[:confidence]).to eq("[VERIFIED]")
  end

  it "marks dynamic-arg associations as INFERRED" do
    results = parse_and_dispatch("has_many :items, class_name: compute_class")
    expect(results.first[:confidence]).to eq("[INFERRED]")
  end

  it "includes line location" do
    results = parse_and_dispatch("has_many :posts")
    expect(results.first[:location]).to eq(1)
  end

  # Discourse's Searchable concern names one association per model with an
  # interpolated symbol; `[INFERRED]` is not a name anything can look up.
  it "names an interpolated association with the line the file wrote" do
    results = parse_and_dispatch('has_one :"#{name.underscore}_search_data", dependent: :destroy')

    expect(results.first[:name]).to eq('="#{name.underscore}_search_data"'.sub("=", ":"))
    expect(results.first[:options]).to include(dependent: :destroy)
  end

  # Discourse writes `class_name: "#{name}CustomField"`; the marker names no
  # class, and the line does.
  it "keeps a computed class_name as the line the file wrote" do
    results = parse_and_dispatch('has_many :_custom_fields, class_name: "#{name}CustomField"')

    expect(results.first[:options][:class_name]).to eq('"#{name}CustomField"')
  end

  # OpenProject's has_details_table concern writes `belongs_to owner_name`
  # with a local. As text it reads exactly like `belongs_to :owner_name`, so
  # the record has to say which it was.
  it "marks a name held in a local as computed" do
    results = parse_and_dispatch("belongs_to owner_name, class_name: owner_class")

    expect(results.first[:name]).to eq("owner_name")
    expect(results.first[:computed_name]).to be(true)
  end

  it "leaves a literal name unmarked" do
    results = parse_and_dispatch("belongs_to :owner")

    expect(results.first).not_to have_key(:computed_name)
  end

  # OpenProject's `has_details_table do ... end` class_evals its block on a
  # detail class; `tap` and `silence` run theirs on this one. Nothing tells them apart.
  it "keeps a declaration inside a block passed to an unknown method, marked" do
    results = parse_and_dispatch(<<~RUBY)
      has_details_table(foreign_key: :principal_id) do
        belongs_to :parent
      end
      Menu.define do
        has_many :items
      end
      ActiveSupport::Deprecation.silence do
        belongs_to :legacy
      end
      tap do
        has_many :tapped
      end
      belongs_to :owner
    RUBY

    expect(results.to_h { |r| [ r[:name], r[:scope_uncertain] ] })
      .to eq(parent: true, items: true, legacy: true, tapped: true, owner: nil)
  end

  it "still reads the blocks that run on the class itself" do
    results = parse_and_dispatch(<<~RUBY)
      included do
        belongs_to :a
      end
      concerning :Tagging do
        included { has_many :b }
      end
      class_eval { has_one :c }
      %i[d e].each do |name|
        has_many name
      end
    RUBY

    expect(results.map { |r| r[:name] }).to eq([ :a, :b, :c, "name" ])
    expect(results.none? { |r| r[:scope_uncertain] }).to be(true)
  end

  it "reads a class_eval sent to the parameter of an included hook" do
    results = parse_and_dispatch(<<~RUBY)
      def self.included(base)
        base.class_eval do
          belongs_to :a
        end
      end
    RUBY

    expect(results.map { |r| r[:name] }).to eq([ :a ])
  end
end

RSpec.describe RailsAiContext::Introspectors::Listeners::AssociationsListener, "acts_as_tenant" do
  # acts_as_tenant calls `belongs_to tenant, scope, **valid_options`, the tenant defaulting to :account.
  it "reads the belongs_to acts_as_tenant declares" do
    results = parse_and_dispatch(<<~RUBY)
      class Ticket < ApplicationRecord
        acts_as_tenant :organization, optional: true, has_global_records: true
      end
      class Note < ApplicationRecord
        acts_as_tenant
      end
    RUBY
    expect(results.map { |r| r.slice(:type, :name, :options) }).to eq([
      { type: "belongs_to", name: :organization, options: { optional: true } },
      { type: "belongs_to", name: :account, options: {} }
    ])
  end
end
