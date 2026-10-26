# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Introspectors::ModelRecord do
  let(:verified) { RailsAiContext::Confidence::VERIFIED }
  let(:facts) do
    described_class::Facts.new(
      data: {
        callbacks: [ { type: :before_save, method: "normalize", options: { if: "active?" } } ],
        scopes: [ { name: "recent", body: "-> { order(:id) }", required_params: [], location: 3, owner: [ "Post" ], confidence: verified },
                  { name: "default_scope", default: true, body: "{ where(live: true) }", location: 4, confidence: verified } ],
        validations: [ { kind: "custom", attributes: [ "check" ], options: { on: :create } } ],
        enums: [ { name: "state", options: { prefix: true } } ],
        conditional: [], foreign: []
      },
      unread: [], bases_unread: [ "LegacyRecord" ], hidden: [], file: "app/models/post.rb", rails_version: "8.0.1",
      macros: { encryption_details: [ { field: "token", options: {} } ], ignored_columns: [ "old" ], own_connection: true }
    )
  end

  def tier(adapter, **values)
    adapter.new(table: RailsAiContext::Introspectors::TableName::Answer.new(table: "posts", primary_key: "id"),
                associations: [ { name: "user", type: "belongs_to", confidence: verified } ], validations: [], enums: {},
                concerns: [], class_methods: %w[search], instance_methods: %w[title], source_instance_methods: %w[title], **values)
  end

  it "builds one shape from the walked source, whichever tier answers the rest" do
    booted = described_class.build(facts, tier(described_class::Reflection, ignored_columns: [ "legacy" ], own_connection: nil))
    static = described_class.build(facts, tier(described_class::StaticCandidates, confidence: RailsAiContext::Confidence::STATIC,
                                                                                  ignored_columns: [ "old" ], own_connection: true,
                                                                                  patches_unread: %w[Billing::Patches::PostPatch]))

    expect(booted).to include(table_name: "posts", primary_key: "id", file: "app/models/post.rb", callbacks: { "before_save" => [ "normalize" ] },
                              callback_conditions: { "before_save" => [ { if: "active?" } ] }, custom_validates: [ "check" ],
                              custom_validate_conditions: { "check" => { on: :create } }, enum_options: { "state" => { prefix: true } },
                              scopes: [ { name: "recent", body: "-> { order(:id) }", required_params: [], confidence: verified } ],
                              default_scopes: [ { body: "{ where(live: true) }", confidence: verified } ], bases_unread: [ "LegacyRecord" ],
                              encryption_details: [ { field: "token", options: {} } ], class_method_count: 1, instance_methods: %w[title],
                              ignored_columns: [ "legacy" ])
    expect(booted).not_to have_key(:own_connection)
    expect(static.keys - booted.keys).to eq(%i[confidence patches_unread own_connection])
    expect(booted.keys - static.keys).to eq([])
  end

  it "lets no static record claim more than the tier, and leaves the booted ones as reflection gave them" do
    booted = described_class.build(facts, tier(described_class::Reflection))
    static = described_class.build(facts, tier(described_class::StaticCandidates))

    expect([ booted, static ].map { |record| record[:associations].first[:confidence] }).to eq([ verified, RailsAiContext::Confidence::STATIC ])
    expect(static[:scopes].first[:confidence]).to eq(RailsAiContext::Confidence::STATIC)
  end

  it "answers no table, and who sets it, where the source computes one" do
    answer = RailsAiContext::Introspectors::TableName::Answer.new(set_by: "Archive.table_name")
    record = described_class.build(facts, tier(described_class::StaticCandidates, table: answer))

    expect(record).to include(table_set_by: "Archive.table_name")
    expect(record).not_to have_key(:table_name)
  end

  it "caps the method lists the payload carries and counts the whole set" do
    many = Array.new(described_class::PAYLOAD_METHOD_CAP + 2) { |i| "m#{i}" }
    record = described_class.build(facts, tier(described_class::Reflection, instance_methods: many, class_methods: many))

    expect([ record[:instance_methods].size, record[:instance_method_count] ]).to eq([ described_class::PAYLOAD_METHOD_CAP, many.size ])
    expect([ record[:class_methods].size, record[:class_method_count] ]).to eq([ described_class::PAYLOAD_METHOD_CAP, many.size ])
  end
end
