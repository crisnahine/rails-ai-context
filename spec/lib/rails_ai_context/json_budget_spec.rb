# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::JsonBudget do
  def cap(chars)
    allow(RailsAiContext.configuration).to receive(:max_tool_response_chars).and_return(chars)
  end

  # Mirrors SchemaIntrospector#call: scalars and one dominant :tables hash,
  # with two of the scalars sitting after it in insertion order.
  let(:schema) do
    {
      adapter: "postgresql",
      tables: 40.times.to_h { |t|
        [ "table_#{t}", { columns: 10.times.map { |c| { name: "col_#{c}", type: "string", null: false } },
                          primary_key: "id" } ]
      },
      total_tables: 40,
      schema_version: "20260731120000"
    }
  end

  it "pretty-prints a payload that fits" do
    cap(200_000)
    expect(RailsAiContext::JsonBudget.for_resource({ a: 1 })).to eq(JSON.pretty_generate({ a: 1 }))
  end

  it "returns parseable JSON that fits the cap" do
    cap(4_000)
    text = RailsAiContext::JsonBudget.for_resource(schema)

    expect(text.length).to be <= 4_000
    expect { JSON.parse(text) }.not_to raise_error
  end

  it "keeps every surviving element whole" do
    cap(4_000)
    kept = JSON.parse(RailsAiContext::JsonBudget.for_resource(schema))["tables"]

    expect(kept.size).to be_between(1, 39)
    kept.each_value do |table|
      expect(table["primary_key"]).to eq("id")
      expect(table["columns"].size).to eq(10)
    end
  end

  it "keeps the scalar keys that say how much is missing" do
    cap(4_000)
    parsed = JSON.parse(RailsAiContext::JsonBudget.for_resource(schema))

    # total_tables and schema_version sit AFTER the dominant :tables hash;
    # without hoisting they would be the first things dropped.
    expect(parsed["adapter"]).to eq("postgresql")
    expect(parsed["total_tables"]).to eq(40)
    expect(parsed["schema_version"]).to eq("20260731120000")
  end

  it "reports what it dropped" do
    cap(4_000)
    note = JSON.parse(RailsAiContext::JsonBudget.for_resource(schema))["_truncated"]

    expect(note["reason"]).to eq("response_size_cap")
    expect(note["max_chars"]).to eq(4_000)
    expect(note["original_chars"]).to eq(JSON.pretty_generate(schema).length)
    expect(note["hint"]).to include("rails_get_*")
    expect(note["clipped"]).to include(hash_including("path" => "tables", "total" => 40))
  end

  it "spends the budget on the collection that dominates" do
    cap(1_500)
    data = { filtered_by: "posts", total_routes: 300,
             routes: 300.times.map { |i| { verb: "GET", path: "/posts/#{i}" } } }
    parsed = JSON.parse(RailsAiContext::JsonBudget.for_resource(data))

    expect(parsed["filtered_by"]).to eq("posts")
    expect(parsed["total_routes"]).to eq(300)
    expect(parsed["routes"].size).to be_between(1, 299)
    expect(parsed["routes"]).to all(include("verb" => "GET"))
  end

  it "moves a non-object payload under a data key" do
    cap(600)
    parsed = JSON.parse(RailsAiContext::JsonBudget.for_resource(200.times.map { |i| { id: i } }))

    expect(parsed["data"].first).to eq({ "id" => 0 })
    expect(parsed["_truncated"]["reason"]).to eq("response_size_cap")
  end

  it "cuts an oversized string value in place with a marker" do
    cap(600)
    parsed = JSON.parse(RailsAiContext::JsonBudget.for_resource({ source: "x" * 5_000 }))

    expect(parsed["source"]).to end_with("... (truncated)")
    expect(parsed["source"].length).to be < 5_000
  end

  # Two things make this the case that bites: a SYMBOL key, since Hash#merge
  # would already replace a string one, and an assertion on the emitted text,
  # since JSON.parse silently keeps the last of two identical keys and would
  # hide the duplicate entirely.
  it "does not emit a duplicate key when the payload owns _truncated" do
    cap(600)
    text = RailsAiContext::JsonBudget.for_resource({ _truncated: "mine", rows: (1..500).to_a })

    expect(text.scan('"_truncated"').size).to eq(1)
    expect(JSON.parse(text)["_truncated"]["reason"]).to eq("response_size_cap")
  end

  # A cap just above the dominant collection's own encoded size used to make
  # the reducer drop it whole and return a report with no data at all.
  it "never trades the whole payload for its own truncation report" do
    data = { routes: 300.times.map { |i| { verb: "GET", path: "/p/#{i}", name: "n#{i}" } } }
    pretty = JSON.pretty_generate(data).length

    (1_000..pretty).step(7) do |chars|
      cap(chars)
      parsed = JSON.parse(RailsAiContext::JsonBudget.for_resource(data))
      expect(parsed["routes"]).to be_present, "cap #{chars} returned no routes"
    end
  end

  it "drops the indentation before it drops data" do
    data = { rows: 400.times.map { |i| { id: i, name: "row_#{i}" } } }
    # A cap between the compact and pretty sizes is satisfied by compact
    # output alone, so nothing is lost and nothing is reported as lost.
    cap(JSON.generate(data).length + 10)
    parsed = JSON.parse(RailsAiContext::JsonBudget.for_resource(data))

    expect(parsed["rows"].size).to eq(400)
    expect(parsed).not_to have_key("_truncated")
  end

  it "labels clip counts with their unit" do
    cap(600)
    note = JSON.parse(RailsAiContext::JsonBudget.for_resource({ source: "x" * 5_000 }))["_truncated"]

    expect(note["clipped"]).to include(hash_including("path" => "source", "unit" => "chars"))
    expect(note["hint"]).to include("... (truncated)")
  end

  it "still parses when the cap is too small for any payload" do
    cap(20)
    expect(JSON.parse(RailsAiContext::JsonBudget.for_resource(schema))).to eq({ "_truncated" => true })
  end
end
