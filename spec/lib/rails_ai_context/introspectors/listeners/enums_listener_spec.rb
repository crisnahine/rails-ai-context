# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Introspectors::Listeners::EnumsListener do
  it "keeps a computed enum's values as their source" do
    expect(parse_and_dispatch("enum :status, Statuses.to_h").first[:values]).to eq("Statuses.to_h")
    expect(parse_and_dispatch("enum kind: KINDS").first[:values]).to eq("KINDS")
    expect(parse_and_dispatch("enum priority: %i[low high].freeze").first[:values]).to eq({ low: 0, high: 1 })
  end

  it "detects Rails 7+ enum syntax" do
    results = parse_and_dispatch("enum :role, { admin: 0, member: 1 }")
    expect(results.size).to eq(1)
    expect(results.first[:name]).to eq("role")
    expect(results.first[:values]).to include(admin: 0, member: 1)
  end

  it "names an escaped enum by what the symbol means, not by its source text" do
    results = parse_and_dispatch(%q(enum :"order\u0020status", { open: 0 }))
    expect(results.first[:name]).to eq("order status")
  end

  it "detects Rails 7+ enum with prefix option" do
    results = parse_and_dispatch("enum :status, { active: 0, inactive: 1 }, prefix: true")
    expect(results.first[:options]).to include(prefix: true)
  end

  it "detects legacy enum syntax" do
    results = parse_and_dispatch("enum status: { draft: 0, published: 1 }")
    expect(results.first[:name]).to eq("status")
    expect(results.first[:values]).to include(draft: 0, published: 1)
  end

  it "includes confidence tag" do
    results = parse_and_dispatch("enum :role, { admin: 0 }")
    expect(results.first[:confidence]).to eq("[VERIFIED]").or eq("[INFERRED]")
  end

  it "normalizes array-style enum values to hash" do
    results = parse_and_dispatch("enum :role, [:admin, :member, :guest]")
    expect(results.first[:values]).to eq({ admin: 0, member: 1, guest: 2 })
  end

  it "includes line location" do
    results = parse_and_dispatch("enum :role, { admin: 0 }")
    expect(results.first[:location]).to eq(1)
  end

  it "detects legacy enum with _prefix option" do
    results = parse_and_dispatch("enum status: { draft: 0, published: 1 }, _prefix: true")
    expect(results.first[:name]).to eq("status")
    expect(results.first[:options]).to include(_prefix: true)
  end

  it "detects legacy enum with _suffix option" do
    results = parse_and_dispatch("enum role: { admin: 0, member: 1 }, _suffix: :type")
    expect(results.first[:name]).to eq("role")
    expect(results.first[:options]).to include(_suffix: :type)
  end
end
