# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Introspectors::Listeners::CallbacksListener do
  it "detects before_save callback" do
    results = parse_and_dispatch("before_save :normalize_email")
    expect(results.size).to eq(1)
    expect(results.first).to include(type: "before_save", method: "normalize_email")
  end

  it "detects after_create callback" do
    results = parse_and_dispatch("after_create :send_welcome")
    expect(results.first).to include(type: "after_create", method: "send_welcome")
  end

  it "detects after_commit with on: option" do
    results = parse_and_dispatch("after_commit :log_change, on: :update")
    expect(results.first[:type]).to eq("after_commit_on_update")
  end

  it "detects multiple callback methods" do
    results = parse_and_dispatch("before_save :normalize_email, :set_defaults")
    expect(results.size).to eq(2)
    methods = results.map { |r| r[:method] }
    expect(methods).to contain_exactly("normalize_email", "set_defaults")
  end

  # Which declaration runs depends on which method bodies run, so the
  # listener keeps every one and the model's chain decides.
  it "keeps every declaration, a redeclared symbol included" do
    results = parse_and_dispatch(<<~RUBY)
      around_create Snowflake
      around_create Snowflake
      before_save :x, if: :a?
      before_save :x, unless: :b?
    RUBY
    expect(results.map { |r| [ r[:type], r[:method], r[:options] ] }).to eq([
      [ "around_create", "Snowflake", {} ], [ "around_create", "Snowflake", {} ],
      [ "before_save", "x", { if: :a? } ], [ "before_save", "x", { unless: :b? } ]
    ])
  end

  it "includes confidence tag" do
    results = parse_and_dispatch("before_save :normalize_email")
    expect(results.first[:confidence]).to eq("[VERIFIED]")
  end

  # `after_commit on: %i[create update] do` is one declaration, one callback.
  it "keeps a multi-event on: as one after_commit with its events" do
    results = parse_and_dispatch("after_commit :sync, on: %i[create update]")
    expect(results.size).to eq(1)
    expect(results.first).to include(type: "after_commit", method: "sync")
    expect(results.first[:options][:on]).to eq(%i[create update])
  end

  it "includes line location" do
    results = parse_and_dispatch("after_destroy :cleanup")
    expect(results.first[:location]).to eq(1)
  end

  it "names a callback whose argument is a class object" do
    results = parse_and_dispatch("around_create Mastodon::Snowflake::Callbacks")
    expect(results.first).to include(type: "around_create", method: "Mastodon::Snowflake::Callbacks")
    expect(results.first[:confidence]).to eq("[VERIFIED]")
  end

  it "detects the touch, initialize and find callbacks" do
    results = parse_and_dispatch(<<~RUBY)
      after_touch :bust
      after_initialize :set_from_account
      after_find :log
    RUBY
    expect(results.map { |r| r[:type] }).to contain_exactly("after_touch", "after_initialize", "after_find")
  end

  # A lambda has no name to print, and its source slice spans lines - it
  # would break the bullet it lands in.
  it "reports a lambda argument as an inline block" do
    results = parse_and_dispatch("before_save ->(rec) { rec.slug = rec.title }")
    expect(results.first).to include(type: "before_save", method: "[inline_block]")
    expect(results.first[:confidence]).to eq("[INFERRED]")
  end

  it "lists every positional argument Rails registers, the block first as normalize_callback_params puts it" do
    results = parse_and_dispatch(<<~RUBY)
      before_save :stamp, AuditTrail.new
      after_commit AuditTrail, -> { notify }
      after_save(:a) { b }
    RUBY
    expect(results.map { |r| [ r[:type], r[:method] ] }).to eq([
      %w[before_save stamp], %w[before_save AuditTrail.new],
      %w[after_commit AuditTrail], [ "after_commit", "[inline_block]" ],
      [ "after_save", "[inline_block]" ], %w[after_save a]
    ])
  end

  # define_model_callbacks takes keywords, so a braced hash stays in args as a filter.
  it "keeps a braced hash as a filter on a define_model_callbacks macro" do
    results = parse_and_dispatch("before_save :x, { if: :y }")
    expect(results.map { |r| r[:method] }).to eq([ "x", "{ if: :y }" ])
  end

  it "reads a trailing braced hash as the options of before_validation and after_validation" do
    results = parse_and_dispatch("before_validation :x, { on: :create }\nafter_validation :y, { if: :z }")
    expect(results.map { |r| [ r[:method], r[:options] ] }).to eq([ [ "x", { on: :create } ], [ "y", { if: :z } ] ])
  end

  it "reads a trailing braced hash as the options of the commit and rollback macros" do
    results = parse_and_dispatch("after_commit :x, { on: :create }\nafter_rollback :y, { if: :z }\nafter_create_commit :w, {}")
    expect(results.map { |r| [ r[:type], r[:method] ] }).to eq([ %w[after_commit_on_create x], %w[after_rollback y], %w[after_create_commit w] ])
  end

  # Keywords after it are what extract_options! takes, so the braced hash is still a filter.
  it "keeps a braced hash followed by keywords as a filter" do
    results = parse_and_dispatch("after_commit :x, { on: :create }, if: :y")
    expect(results.map { |r| r[:method] }).to eq([ "x", "{ on: :create }" ])
  end

  it "reports every proc spelling as an inline block, Proc.new included" do
    results = parse_and_dispatch("before_save Proc.new { touch }\nbefore_save proc { x }\nbefore_save ::Proc.new { y }\nbefore_save lambda { z }")
    expect(results.map { |r| r[:method] }).to eq([ "[inline_block]" ] * 4)
  end

  it "records the declared macro name alongside the resolved type" do
    results = parse_and_dispatch("after_commit :sync, on: :create")
    expect(results.first).to include(name: "after_commit", type: "after_commit_on_create")
  end

  # `after_commit on: :create` has no target at all; reporting a block that
  # is not in the source made every renderer print "runs a block here".
  it "reports nothing for a macro that carries only keyword options" do
    expect(parse_and_dispatch("after_commit on: :create")).to be_empty
    expect(parse_and_dispatch("after_save unless: :skip?")).to be_empty
  end

  it "reads an option off an enclosing with_options block" do
    results = parse_and_dispatch(<<~RUBY)
      with_options if: :published? do
        after_save :notify
      end

      after_save :touch_tracker
    RUBY

    scoped, plain = results.partition { |r| r[:method] == "notify" }.map(&:first)
    expect(scoped[:options]).to include(if: :published?)
    expect(plain[:options]).not_to include(:if)
  end

  it "keeps a lambda condition as the line wrote it" do
    results = parse_and_dispatch(%(after_create :notify, if: -> { category == "vomit" }))

    expect(results.first[:options]).to eq(if: %(-> { category == "vomit" }))
  end

  # A block has no method whose body could be shown, so detail:"full" printed
  # the marker alone.
  it "keeps an inline block's declaration, at the file's indentation, as its source" do
    results = parse_and_dispatch(<<~RUBY)
      class Review
        after_create_commit -> { broadcast_prepend_to [product, :reviews], target: "reviews" }
        before_save do
          self.slug ||= title.parameterize
        end
        after_save :notify
      end
    RUBY

    lambda_cb, block_cb, named = results
    expect(lambda_cb).to include(source: %(  after_create_commit -> { broadcast_prepend_to [product, :reviews], target: "reviews" }),
                                 location: 2, end_location: 2)
    expect(block_cb).to include(source: "  before_save do\n    self.slug ||= title.parameterize\n  end", location: 3, end_location: 5)
    expect(named).not_to include(:source)
  end

  # turbo-rails declares the commit callbacks itself, so the model's file
  # names none of them.
  it "lists each commit callback a turbo-rails broadcast macro declares" do
    results = parse_and_dispatch("broadcasts_refreshes\nbroadcasts_to :room, inserts_by: :prepend\nbroadcasts_refreshes_to :board\n")

    expect(results.map { |r| [ r[:type], r[:method], r[:runs] ] }).to eq([
      [ "after_create_commit", "broadcasts_refreshes (turbo-rails)", "broadcast_refresh_later_to" ],
      [ "after_update_commit", "broadcasts_refreshes (turbo-rails)", "broadcast_refresh_later" ],
      [ "after_destroy_commit", "broadcasts_refreshes (turbo-rails)", "broadcast_refresh" ],
      [ "after_create_commit", "broadcasts_to (turbo-rails)", "broadcast_action_later_to" ],
      [ "after_update_commit", "broadcasts_to (turbo-rails)", "broadcast_replace_later_to" ],
      [ "after_destroy_commit", "broadcasts_to (turbo-rails)", "broadcast_remove_to" ],
      [ "after_commit", "broadcasts_refreshes_to (turbo-rails)", "broadcast_refresh_later_to" ]
    ])
    expect(results[3]).to include(name: "broadcasts_to", options: {}, source: "broadcasts_to :room, inserts_by: :prepend", location: 2)
  end
end
