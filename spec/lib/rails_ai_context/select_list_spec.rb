# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::SelectList do
  let(:tables) { { "src" => { columns: [ { name: "k", type: "integer" }, { name: "s", type: "text" }, { name: "b", type: "boolean" } ] } } }

  def types(items, adapter)
    described_class.columns("SELECT #{items} FROM src", tables, adapter: adapter).map { |c| [ c[:name], c[:type] ] }
  end

  # PostgreSQL 17 types every one of these boolean (CREATE TABLE dst AS SELECT ... FROM src; format_type of each column).
  PREDICATES = [
    "k = 1", "k <> 1", "k != 1", "k < 1", "k > 1", "k <= 1", "k >= 1", "k IS DISTINCT FROM 1", "k IS NOT DISTINCT FROM 1",
    "k IS NULL", "k IS NOT NULL", "k IN (1, 2)", "k NOT IN (1)", "s LIKE 'x'", "s NOT LIKE 'x'", "s ILIKE 'x'", "s SIMILAR TO 'x'",
    "k BETWEEN 1 AND 2", "k NOT BETWEEN 1 AND 2", "NOT b", "b AND b", "b OR b", "EXISTS (SELECT 1)", "k + 1 = 2", "b IS TRUE",
    "k ISNULL", "k NOTNULL", "(k = 1)", "k = 1 AND k = 2"
  ].freeze

  it "types a select item whose top-level operator is a comparison or a boolean predicate boolean, as PostgreSQL does" do
    found = PREDICATES.each_with_index.map { |item, i| types("#{item} AS a#{i}", :postgresql).first }
    expect(found).to eq(PREDICATES.each_index.map { |i| [ "a#{i}", "boolean" ] })
  end

  it "names an unaliased predicate ?column? and keeps the FROM of IS DISTINCT FROM inside it, on PostgreSQL" do
    expect(types("k IS DISTINCT FROM 1 dd, k = 1, k", :postgresql)).to eq([ %w[dd boolean], %w[?column? boolean], %w[k integer] ])
  end

  it "leaves a computed item that is no predicate untyped, a comparison inside parentheses, a CASE or a string among them" do
    items = [ "k + 1", "(k = 1)::int", "CASE WHEN k = 1 THEN 1 END", "'a = b' || s", "data -> 'k'", "k << 1", "coalesce(k = 1, false)" ]
    expect(items.each_with_index.map { |item, i| types("#{item} AS a#{i}", :postgresql).first.last }).to eq([ nil ] * items.size)
  end

  # PostgreSQL 16 names an unaliased cast after the last part of its type name; a dot inside quotes is part of a name.
  it "names a cast after the last part of its type, a quoted part with a dot or a doubled quote in it whole" do
    casts = { "1::int" => "int4", "1::pg_catalog.int8" => "int8", %(1::public."my""t") => 'my"t', %(1::"a.b"."c.d") => "c.d",
              "1::double precision" => "float8", "1::numeric(10, 2)" => "numeric", %(1::"x.y") => "x.y", "1::character varying(10)[]" => "varchar" }

    expect(casts.keys.map { |cast| described_class.columns("SELECT #{cast} FROM src", tables, adapter: :postgresql).first[:name] }).to eq(casts.values)
  end

  # Ruby 3.1 took 4 s for 16000 quotes with the type name found by an unanchored pattern, and 77 s for 64000.
  it "finds the last part of a type name in linear time on a long run of quotes" do
    expect do
      Timeout.timeout(2) { [ '"' * 64_000 + " x(", '"a""' * 16_000 + " x(", "a." * 32_000 + '"' * 3 ].each { |type| described_class.send(:postgres_type_name, type) } }
    end.not_to raise_error
  end

  # MySQL 9.6 types a comparison or a boolean predicate int (SHOW CREATE TABLE of the same CREATE TABLE ... AS).
  it "types a predicate integer on MySQL" do
    items = [ "k = 1", "k <> 1", "k < 1", "k IS NULL", "k IS NOT NULL", "k IN (1, 2)", "s LIKE 'x'", "k BETWEEN 1 AND 2", "NOT b", "b AND b",
              "b OR b", "EXISTS (SELECT 1)", "k <=> 1", "k = 1 AND k = 2" ]
    expect(items.each_with_index.map { |item, i| types("#{item} AS a#{i}", :mysql).first }).to eq(items.each_index.map { |i| [ "a#{i}", "integer" ] })
  end

  it "reads a MySQL string a backslash escapes a quote in as one string, no predicate in it" do
    expect(types(%q("x\" = y" AS a, 'p    expect(types("k = 1 AS a, k IS NULL AS b", :sqlite)).to eq([ [ "a", nil ], [ "b", nil ] ])
  end
end
 OR q' AS b), :mysql).map(&:last)).to eq([ nil, "string" ])
  end

  it "leaves a predicate untyped on SQLite, which gives an expression column no type" do
    expect(types("k = 1 AS a, k IS NULL AS b", :sqlite)).to eq([ [ "a", nil ], [ "b", nil ] ])
  end
end
