# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Introspectors::SqliteVirtualTables do
  let(:connection) { ActiveRecord::Base.connection }

  around do |example|
    connection.execute("CREATE VIRTUAL TABLE svt_fts USING fts5 (title, body)")
    example.run
  ensure
    connection.execute("DROP TABLE IF EXISTS svt_fts")
  end

  it "reads each virtual table's module and arguments" do
    expect(described_class.of(connection)).to include("svt_fts" => [ "fts5", "title, body" ])
  end

  it "hides the virtual table and the shadow tables it owns" do
    hidden = described_class.hidden(connection)

    expect(hidden).to include("svt_fts", "svt_fts_data", "svt_fts_config")
    expect(hidden & connection.tables.grep_v(/_fts/)).to eq([])
  end

  it "falls back to the virtual tables alone when the SQLite has no pragma_table_list" do
    allow(connection).to receive(:select_values).and_raise(ActiveRecord::StatementInvalid)

    expect(described_class.hidden(connection)).to include("svt_fts")
    expect(described_class.hidden(connection)).not_to include("svt_fts_data")
  end
end
