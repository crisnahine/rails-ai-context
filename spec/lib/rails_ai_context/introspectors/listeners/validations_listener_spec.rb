# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Introspectors::Listeners::ValidationsListener do
  # `validates :notes, presence: false` turns a validator off; it declares none.
  it "reads a validator option set to false as no validator" do
    expect(parse_and_dispatch("validates :notes, presence: false, allow_nil: true")).to eq([])
    expect(parse_and_dispatch("validates :email, uniqueness: false, length: { maximum: 5 }").map { |r| r[:kind] }).to eq(%w[length])
  end

  it "detects validates with presence" do
    results = parse_and_dispatch("validates :email, presence: true")
    expect(results.size).to eq(1)
    expect(results.first[:kind]).to eq("presence")
    expect(results.first[:attributes]).to eq([ "email" ])
  end

  it "splits multiple validation kinds" do
    results = parse_and_dispatch("validates :email, presence: true, uniqueness: true")
    kinds = results.map { |r| r[:kind] }
    expect(kinds).to contain_exactly("presence", "uniqueness")
  end

  it "detects multiple attributes" do
    results = parse_and_dispatch("validates :first_name, :last_name, presence: true")
    expect(results.first[:attributes]).to contain_exactly("first_name", "last_name")
  end

  it "detects validates_presence_of" do
    results = parse_and_dispatch("validates_presence_of :title")
    expect(results.first[:kind]).to eq("presence")
    expect(results.first[:attributes]).to eq([ "title" ])
  end

  it "detects custom validate" do
    results = parse_and_dispatch("validate :check_constraints")
    expect(results.first[:kind]).to eq("custom")
    expect(results.first[:attributes]).to eq([ "check_constraints" ])
  end

  it "detects multiple custom validates" do
    results = parse_and_dispatch("validate :check_a, :check_b")
    expect(results.size).to eq(2)
    methods = results.flat_map { |r| r[:attributes] }
    expect(methods).to contain_exactly("check_a", "check_b")
  end

  it "names absence as the kind, not the macro" do
    results = parse_and_dispatch("validates :followers_url, absence: true")
    expect(results.first[:kind]).to eq("absence")
    expect(results.first[:options]).to eq({})
  end

  it "gives a rule that names two kinds on one attribute a row each" do
    results = parse_and_dispatch("validates :uri, absence: true, exclusion: { in: [''] }")
    expect(results.map { |r| r[:kind] }).to contain_exactly("absence", "exclusion")
    expect(results.find { |r| r[:kind] == "exclusion" }[:options]).to eq({ in: [ "" ] })
    expect(results.find { |r| r[:kind] == "absence" }[:options]).to eq({})
  end

  it "names an app's own validator by the option key that carries it" do
    results = parse_and_dispatch("validates :note, note_length: { maximum: 5 }, if: :local?")
    expect(results.first[:kind]).to eq("note_length")
    expect(results.first[:options]).to eq({ if: :local?, maximum: 5 })
  end

  it "keeps a shared option off the kinds" do
    results = parse_and_dispatch("validates_length_of :title, maximum: 5, on: :create")
    expect(results.map { |r| r[:kind] }).to eq([ "length" ])
    expect(results.first[:options]).to eq({ maximum: 5, on: :create })
  end

  it "includes confidence tag" do
    results = parse_and_dispatch("validates :email, presence: true")
    expect(results.first[:confidence]).to eq("[VERIFIED]")
  end

  it "reads an option off an enclosing with_options block" do
    results = parse_and_dispatch(<<~RUBY)
      with_options on: :create_and_create_standard_variant do
        validates :enterprise_id, presence: true
      end

      validates :name, presence: true
    RUBY

    scoped, plain = results.partition { |r| r[:attributes] == [ "enterprise_id" ] }.map(&:first)
    expect(scoped[:options]).to include(on: :create_and_create_standard_variant)
    expect(plain[:options]).not_to include(:on)
  end

  it "reads an option off a with_options block that takes a parameter" do
    results = parse_and_dispatch(<<~RUBY)
      with_options on: :publish do |publishing|
        publishing.validates :summary, presence: true
      end
    RUBY

    expect(results.first[:options]).to include(on: :publish)
  end

  # The walk read nothing for `validates_with`, so the static tier dropped a
  # validation the model has.
  it "records validates_with with the validator it names" do
    results = parse_and_dispatch("validates_with RecordValidator, on: :create")

    expect(results.first).to include(kind: "validates_with", validator: "RecordValidator", attributes: [])
    expect(results.first[:options]).to eq(on: :create)
  end

  # A gem's macro (validates_timeliness's `validates_date`) is a validation the
  # model declares; it is listed as that macro, with its options.
  it "records a plugin validates_ macro under its own name" do
    results = parse_and_dispatch(<<~RUBY)
      validates_date :date_of_birth,
                     presence: true,
                     if: ->(d) { d.approved? && d.id? }
    RUBY

    expect(results.first).to include(kind: "validates_date", attributes: [ "date_of_birth" ])
    expect(results.first[:options]).to eq(presence: true, if: "->(d) { d.approved? && d.id? }")
  end

  # Rails' `validates` takes a trailing hash expression as its options
  # (`extract_options!`): the attribute is the literal, the options are computed.
  it "reads a trailing non-literal argument after a literal attribute as the options" do
    results = RailsAiContext::Introspectors::SourceIntrospector.walk_source(
      "class Post\n  validates :title, rules.merge(if: :published?)\nend\n", { validations: described_class }
    )[:validations]

    expect(results.map { |v| v.slice(:kind, :attributes, :computed_attributes, :options_source) }).to eq(
      [ { kind: "validates", attributes: [ "title" ], options_source: "rules.merge(if: :published?)" } ]
    )
  end

  # state_machines evaluates a state's block on the model, so reflection lists the validator.
  it "reads a validation inside a state_machine state block, unmarked" do
    results = parse_and_dispatch(<<~RUBY)
      state_machine :status, initial: :new do
        state :done do
          validates :finished_at, presence: true
        end
      end
    RUBY

    expect(results.map { |r| r[:attributes] }).to eq([ [ "finished_at" ] ])
    expect(results.first).not_to have_key(:scope_uncertain)
  end
end
