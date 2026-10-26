# frozen_string_literal: true

require "spec_helper"

# Each expected column is what schema.rb shows for the declared one, read from a real dump made by that Rails version
# against that database (PostgreSQL 17, MySQL 9.6, SQLite 3) unless the row says otherwise.
RSpec.describe RailsAiContext::Introspectors::DumpedColumn do
  def dumped(declared, family, rails_version = "8.0.5")
    described_class.call({ name: "c" }.merge(declared), family: family, rails_version: rails_version).except(:name)
  end

  # [family, declared, the column schema.rb shows], on Rails 8.0
  ROWS = [
    # A type as a dump spells it.
    [ :postgresql, { sql_type: "smallint" }, { type: "integer", limit: 2 } ],
    [ :postgresql, { sql_type: "bigint" }, { type: "bigint" } ],
    [ :postgresql, { sql_type: "character varying(10)" }, { type: "string", limit: 10 } ],
    [ :postgresql, { sql_type: "numeric" }, { type: "decimal" } ],
    [ :postgresql, { sql_type: "numeric(5,0)" }, { type: "decimal", precision: 5 } ],
    [ :postgresql, { sql_type: "numeric(5,2)", stored_default: "1.555" }, { type: "decimal", precision: 5, scale: 2, default: "1.56" } ],
    [ :postgresql, { sql_type: "numeric(5,0)", stored_default: "'-2.5'::numeric" }, { type: "decimal", precision: 5, default: "-2" } ],
    # schema.rb writes precision: nil for a datetime with no precision, which the others leave out (schema_precision, 7.0 to 8.1).
    [ :postgresql, { sql_type: "timestamp without time zone" }, { type: "datetime", precision: nil } ],
    [ :postgresql, { sql_type: "timestamp" }, { type: "datetime", precision: nil } ],
    [ :postgresql, { sql_type: "timestamp(0) without time zone" }, { type: "datetime", precision: 0 } ],
    [ :postgresql, { sql_type: "timestamp with time zone" }, { type: "timestamptz" } ],
    [ :postgresql, { sql_type: "time without time zone" }, { type: "time" } ],
    [ :postgresql, { sql_type: "timestamp(6) without time zone", stored_default: "CURRENT_TIMESTAMP" }, { type: "datetime", default: '-> { "CURRENT_TIMESTAMP" }' } ],
    [ :postgresql, { sql_type: "time(3) without time zone" }, { type: "time", precision: 3 } ],
    [ :postgresql, { sql_type: "real" }, { type: "float", limit: 24 } ],
    [ :postgresql, { sql_type: "double precision" }, { type: "float" } ],
    [ :postgresql, { sql_type: "boolean", stored_default: "true" }, { type: "boolean", default: "true" } ],
    [ :postgresql, { sql_type: "integer", stored_default: "7" }, { type: "integer", default: "7" } ],
    [ :postgresql, { sql_type: "character varying[]", stored_default: "'{}'::character varying[]" }, { type: "string", array: true, default: "[]" } ],
    [ :postgresql, { sql_type: "character varying(10)[]", stored_default: %q('{a,"b c"}'::character varying[]) },
      { type: "string", limit: 10, array: true, default: '["a", "b c"]' } ],
    [ :postgresql, { sql_type: "integer[]", stored_default: "'{1,2}'::integer[]" }, { type: "integer", array: true, default: "[1, 2]" } ],
    [ :postgresql, { sql_type: "jsonb", stored_default: "'{}'::jsonb" }, { type: "jsonb", default: "{}" } ],
    [ :postgresql, { sql_type: "public.mood", enum_type: "mood", stored_default: "'happy'::public.mood" }, { type: "enum", enum_type: "mood", default: "happy" } ],
    [ :postgresql, { sql_type: "uuid", stored_default: "gen_random_uuid()", null: false }, { type: "uuid", null: false, default: '-> { "gen_random_uuid()" }' } ],
    [ :postgresql, { sql_type: "date", stored_default: "now()" }, { type: "date", default: '-> { "now()" }' } ],
    [ :postgresql, { sql_type: "integer", stored_default: "(1 + 1)" }, { type: "integer" } ],
    [ :postgresql, { sql_type: "bit(3)" }, { type: "bit", limit: 3 } ],
    [ :postgresql, { sql_type: "bit varying(8)" }, { type: "bit_varying", limit: 8 } ],
    [ :postgresql, { sql_type: "money" }, { type: "money", scale: 2 } ],
    [ :postgresql, { type: "interval", precision: 3 }, { type: "interval", precision: 3 } ],
    [ :postgresql, { sql_type: "interval(3)" }, { type: "interval", precision: 3 } ],
    [ :postgresql, { sql_type: "character varying", collation: "C", comment: "a code" }, { type: "string", collation: "C", comment: "a code" } ],
    [ :mysql, { sql_type: "tinyint" }, { type: "integer", limit: 1 } ],
    [ :mysql, { sql_type: "tinyint(1)", stored_default: "'1'" }, { type: "boolean", default: "true" } ],
    [ :mysql, { sql_type: "varchar(255)" }, { type: "string" } ],
    [ :mysql, { sql_type: "decimal(10,0)" }, { type: "decimal", precision: 10 } ],
    [ :mysql, { sql_type: "decimal(5,2)", stored_default: "'1.56'" }, { type: "decimal", precision: 5, scale: 2, default: "1.56" } ],
    [ :mysql, { sql_type: "datetime" }, { type: "datetime", precision: nil } ],
    [ :mysql, { sql_type: "datetime(0)" }, { type: "datetime", precision: nil } ],
    [ :mysql, { sql_type: "datetime(6)" }, { type: "datetime" } ],
    [ :mysql, { sql_type: "timestamp" }, { type: "timestamp" } ],
    [ :mysql, { sql_type: "time(0)" }, { type: "time" } ],
    [ :mysql, { sql_type: "datetime(3)" }, { type: "datetime", precision: 3 } ],
    [ :mysql, { sql_type: "double" }, { type: "float", limit: 53 } ],
    [ :mysql, { sql_type: "float" }, { type: "float" } ],
    [ :mysql, { sql_type: "mediumtext" }, { type: "text", size: "medium" } ],
    [ :mysql, { sql_type: "varbinary(100)" }, { type: "binary", limit: 100 } ],
    [ :mysql, { sql_type: "tinyblob" }, { type: "binary", size: "tiny" } ],
    [ :mysql, { sql_type: "int unsigned", stored_default: "'0'" }, { type: "integer", unsigned: true, default: "0" } ],
    [ :mysql, { sql_type: "decimal(6,2) unsigned" }, { type: "decimal", precision: 6, scale: 2, unsigned: true } ],
    [ :mysql, { sql_type: "enum('a','b')", stored_default: "'a'" }, { type: "enum('a','b')", default: "a" } ],
    [ :mysql, { sql_type: "enum('signed','unsigned')" }, { type: "enum('signed','unsigned')" } ],
    [ :mysql, { sql_type: "year", stored_default: "'2024'" }, { type: "integer", default: "2024" } ],
    [ :mysql, { sql_type: "varchar(255)", collation: "utf8mb4_bin", comment: "the code" }, { type: "string", collation: "utf8mb4_bin", comment: "the code" } ],
    [ :sqlite, { sql_type: "integer(8)" }, { type: "integer", limit: 8 } ],
    [ :sqlite, { sql_type: "varchar(255)" }, { type: "string", limit: 255 } ],
    [ :sqlite, { sql_type: "decimal(5)" }, { type: "decimal", precision: 5 } ],
    [ :sqlite, { sql_type: "decimal(5,0)", stored_default: "-2" }, { type: "decimal", precision: 5, default: "-2" } ],
    [ :sqlite, { sql_type: "text(70000)" }, { type: "text", limit: 70000 } ],
    [ :sqlite, { sql_type: "blob(100)" }, { type: "binary", limit: 100 } ],
    [ :sqlite, { sql_type: "boolean", stored_default: "0" }, { type: "boolean", default: "false" } ],
    [ :sqlite, { sql_type: "datetime(0)" }, { type: "datetime", precision: 0 } ],
    [ :sqlite, { sql_type: "datetime" }, { type: "datetime", precision: nil } ],
    [ :sqlite, { sql_type: "timestamp" }, { type: "datetime", precision: nil } ],
    [ :sqlite, { sql_type: "datetime(6)" }, { type: "datetime" } ],
    [ :sqlite, { sql_type: "time" }, { type: "time" } ],
    [ :sqlite, { sql_type: "float(24)" }, { type: "float", limit: 24 } ],
    [ :sqlite, { sql_type: "varchar", collation: "NOCASE" }, { type: "string", collation: "NOCASE" } ],
    # A type as a migration declares it, or as the connection reads it.
    [ :postgresql, { type: "integer", limit: 8 }, { type: "bigint" } ],
    [ :postgresql, { type: "integer", limit: 1 }, { type: "integer", limit: 2 } ],
    [ :postgresql, { type: "string", limit: 255 }, { type: "string", limit: 255 } ],
    [ :postgresql, { type: "decimal", precision: 5, scale: 2, default: "1.555" }, { type: "decimal", precision: 5, scale: 2, default: "1.56" } ],
    [ :postgresql, { type: "decimal", precision: 5, default: -2.5 }, { type: "decimal", precision: 5, default: "-2" } ],
    [ :postgresql, { type: "datetime", precision: 6 }, { type: "datetime" } ],
    # A precision: nil given, or the connection's nil, is the datetime with no precision; none given is the default 6.
    [ :postgresql, { type: "datetime", precision: nil }, { type: "datetime", precision: nil } ],
    [ :postgresql, { type: "datetime" }, { type: "datetime" } ],
    [ :postgresql, { type: "datetime", precision: 3 }, { type: "datetime", precision: 3 } ],
    [ :postgresql, { type: "timestamptz", precision: nil }, { type: "timestamptz" } ],
    [ :postgresql, { type: "time", precision: nil }, { type: "time" } ],
    [ :sqlite, { type: "datetime", precision: nil }, { type: "datetime", precision: nil } ],
    [ :sqlite, { type: "datetime" }, { type: "datetime" } ],
    [ :postgresql, { type: "timestamptz", precision: 3 }, { type: "timestamptz", precision: 3 } ],
    [ :postgresql, { type: "float", limit: 53 }, { type: "float" } ],
    [ :postgresql, { type: "text", limit: 70000 }, { type: "text" } ],
    [ :postgresql, { type: "binary", limit: 100 }, { type: "binary" } ],
    [ :postgresql, { type: "boolean", default: "0" }, { type: "boolean", default: "false" } ],
    [ :postgresql, { type: "boolean", default: "t" }, { type: "boolean", default: "true" } ],
    [ :postgresql, { type: "bit", limit: 3 }, { type: "bit", limit: 3 } ],
    [ :postgresql, { type: "money" }, { type: "money", scale: 2 } ],
    [ :postgresql, { type: "string", array: true, default: [] }, { type: "string", array: true, default: "[]" } ],
    [ :postgresql, { type: "string", limit: 10, array: true, default: %q({a,"b c"}) }, { type: "string", limit: 10, array: true, default: '["a", "b c"]' } ],
    [ :postgresql, { type: "integer", array: true, default: [ 1, 2 ] }, { type: "integer", array: true, default: "[1, 2]" } ],
    [ :postgresql, { type: "enum", enum_type: "mood", default: "happy" }, { type: "enum", enum_type: "mood", default: "happy" } ],
    [ :postgresql, { type: "string", collation: "C", comment: "a code" }, { type: "string", collation: "C", comment: "a code" } ],
    [ :postgresql, { type: "integer", unsigned: true, size: :medium }, { type: "integer" } ],
    [ :postgresql, { type: "date", default_sql: "now()" }, { type: "date", default: '-> { "now()" }' } ],
    [ :postgresql, { type: "boolean", default_sql: "true" }, { type: "boolean", default: "true" } ],
    [ :postgresql, { type: "datetime", default_function: "CURRENT_TIMESTAMP" }, { type: "datetime", default: '-> { "CURRENT_TIMESTAMP" }' } ],
    [ :mysql, { type: "integer", limit: 8 }, { type: "bigint" } ],
    [ :mysql, { type: "integer", limit: 1 }, { type: "integer", limit: 1 } ],
    [ :mysql, { type: "string", limit: 255 }, { type: "string" } ],
    [ :mysql, { type: "decimal" }, { type: "decimal", precision: 10 } ],
    [ :mysql, { type: "decimal", precision: 5, scale: 2, default: "1.555" }, { type: "decimal", precision: 5, scale: 2, default: "1.56" } ],
    [ :mysql, { type: "datetime", precision: 0 }, { type: "datetime", precision: nil } ],
    [ :mysql, { type: "datetime", precision: nil }, { type: "datetime", precision: nil } ],
    [ :mysql, { type: "datetime" }, { type: "datetime" } ],
    [ :mysql, { type: "timestamp", precision: 0 }, { type: "timestamp" } ],
    [ :mysql, { type: "time", precision: 0 }, { type: "time" } ],
    [ :mysql, { type: "float", limit: 24 }, { type: "float" } ],
    [ :mysql, { type: "float", limit: 53 }, { type: "float", limit: 53 } ],
    [ :mysql, { type: "text", limit: 70000 }, { type: "text", size: "medium" } ],
    [ :mysql, { type: "text", size: :medium }, { type: "text", size: "medium" } ],
    [ :mysql, { type: "binary", size: :tiny }, { type: "binary", size: "tiny" } ],
    [ :mysql, { type: "binary", limit: 100 }, { type: "binary", limit: 100 } ],
    [ :mysql, { type: "binary", limit: 70000 }, { type: "binary", size: "medium" } ],
    [ :mysql, { type: "boolean", default: "1" }, { type: "boolean", default: "true" } ],
    [ :mysql, { type: "integer", unsigned: true, default: 0 }, { type: "integer", unsigned: true, default: "0" } ],
    [ :mysql, { type: "unsigned_integer" }, { type: "integer", unsigned: true } ],
    [ :mysql, { type: "string", collation: "utf8mb4_bin", comment: "the code" }, { type: "string", collation: "utf8mb4_bin", comment: "the code" } ],
    [ :mysql, { type: "string", array: true }, { type: "string" } ],
    [ :mysql, { type: "string", default_sql: "'it''s'" }, { type: "string", default: "it's" } ],
    # An e-notation number is a double, which MySQL rounds half to even into an integer; an exact one half away from zero.
    [ :mysql, { type: "integer", default_sql: "2.5e0" }, { type: "integer", default: "2" } ],
    [ :mysql, { type: "integer", default_sql: "3.5e0" }, { type: "integer", default: "4" } ],
    [ :mysql, { type: "integer", default_sql: "2.5" }, { type: "integer", default: "3" } ],
    [ :mysql, { type: "integer", limit: 8, default_sql: "-2.5e0" }, { type: "bigint", default: "-2" } ],
    [ :mysql, { type: "boolean", default_sql: "0.5e0" }, { type: "boolean", default: "false" } ],
    [ :sqlite, { type: "integer", limit: 8 }, { type: "integer", limit: 8 } ],
    [ :sqlite, { type: "string", limit: 255 }, { type: "string", limit: 255 } ],
    [ :sqlite, { type: "text", limit: 70000 }, { type: "text", limit: 70000 } ],
    [ :sqlite, { type: "decimal", precision: 5, scale: 2, default: "1.555" }, { type: "decimal", precision: 5, scale: 2, default: "1.56" } ],
    [ :sqlite, { type: "boolean", default: "0" }, { type: "boolean", default: "false" } ],
    [ :sqlite, { type: "text", size: :medium }, { type: "text" } ],
    [ :sqlite, { type: "string", default_sql: "'x'" }, { type: "string", default: "x" } ],
    [ :sqlite, { type: "datetime", default_sql: "CURRENT_TIMESTAMP" }, { type: "datetime", default: '-> { "CURRENT_TIMESTAMP" }' } ]
  ].freeze

  ROWS.each do |family, declared, expected|
    it "writes #{declared.inspect} on #{family} as #{expected.inspect}" do
      expect(dumped(declared, family)).to eq(expected)
    end
  end

  it "reads each column it writes back as itself, so a later statement can write it again" do
    ROWS.each do |family, declared, expected|
      again = expected.except(:default).merge(expected.key?(:default) ? { default: expected[:default] } : {})
      expect(dumped(again, family)).to eq(expected), "#{family} #{declared.inspect}"
    end
  end

  # [family, Rails version, declared, the column that version's schema.rb shows]
  [
    # PostgreSQL's real reads as limit 24 from 7.2.2.1 (postgresql_adapter.rb:655); 7.1 reads it as the bare float.
    [ :postgresql, "7.1.5", { sql_type: "real" }, { type: "float" } ],
    [ :postgresql, "7.2.2", { sql_type: "real" }, { type: "float", limit: 24 } ],
    [ :postgresql, "7.1.5", { type: "float", limit: 24 }, { type: "float" } ],
    # SQLite reads a TRUE default as a boolean from 8.1.4, as that text on 8.1.0, and as no default before.
    [ :sqlite, "8.1.4", { sql_type: "boolean", stored_default: "TRUE" }, { type: "boolean", default: "true" } ],
    [ :sqlite, "8.1.0", { sql_type: "integer", stored_default: "TRUE" }, { type: "integer", default: "0" } ],
    [ :sqlite, "7.1.5", { sql_type: "boolean", stored_default: "TRUE" }, { type: "boolean" } ],
    # Rails 7.0 reads a quoted SQLite literal holding a | as one; 7.1 on as no default.
    [ :sqlite, "7.0.8", { sql_type: "varchar", stored_default: "'a|b'" }, { type: "string", default: "a|b" } ],
    [ :sqlite, "7.1.5", { sql_type: "varchar", stored_default: "'a|b'" }, { type: "string" } ],
    # SQLite keeps a statement's expression as written, so a proc's SQL reads back as a dump's would.
    [ :sqlite, "7.1.5", { type: "string", default_sql: "'a|b'" }, { type: "string" } ]
  ].each do |family, rails_version, declared, expected|
    it "writes #{declared.inspect} on #{family} under Rails #{rails_version} as #{expected.inspect}" do
      expect(dumped(declared, family, rails_version)).to eq(expected)
    end
  end

  # Each row as PostgreSQL 13 to 17 read it back (pg_get_expr of the default): quote_ident leaves bare only a name of
  # lowercase letters, digits and underscores that starts with a letter or underscore.
  [
    [ "a_seq", "a_seq" ], [ "Odd_seq", %("Odd_seq") ], [ "a$b_seq", %("a$b_seq") ], [ "a$", %("a$") ], [ "$x", %("$x") ], [ "1a_seq", %("1a_seq") ],
    # A keyword other than an unreserved one is quoted: reserved (user, order), column-name (int, time) and type-or-function (left).
    [ "user", %("user") ], [ "select", %("select") ], [ "table", %("table") ], [ "int", %("int") ], [ "time", %("time") ], [ "left", %("left") ],
    [ "order", %("order") ], [ "limit", %("limit") ], [ "all", %("all") ], [ "analyse", %("analyse") ], [ "key", "key" ], [ "name", "name" ],
    [ "type", "type" ], [ "value", "value" ], [ "public.user", %(public."user") ],
    # The 13 words a release after 13 quotes (16 added 5, 17 added 8): the list is the union of 13 to 17.
    *%w[json json_array json_arrayagg json_exists json_object json_objectagg json_query json_scalar json_serialize json_table json_value merge_action system_user]
      .map { |word| [ word, %("#{word}") ] },
    [ "a-b_seq", %("a-b_seq") ], [ %(other."x.y_seq"), %(other."x.y_seq") ], [ %("x.y".z_seq), %("x.y".z_seq) ], [ "é_seq", %("é_seq") ], [ %("a""b_seq"), %("a""b_seq") ], [ "a b", %("a b") ], [ "public.a$b_seq", %(public."a$b_seq") ]
  ].each do |sequence, regclass|
    it "writes the default of sequence #{sequence} as nextval('#{regclass}'::regclass)" do
      expect(described_class.nextval_default(sequence)).to eq(%(-> { #{"nextval('#{regclass.gsub("'", "''")}'::regclass)".inspect} }))
    end
  end

  it "reads the sequence a nextval default names back as the joined name it was written from, public left off" do
    [ "orders_id_seq", %(other."x.y_seq"), %("x.y".z_seq), %("a""b_seq") ].each do |sequence|
      expect(described_class.nextval_sequence(described_class.nextval_default(sequence))).to eq(sequence)
    end
    expect(described_class.nextval_sequence(described_class.nextval_default("public.orders_id_seq"))).to eq("orders_id_seq")
  end

  it "keeps the marks a caller settles: a serial's own sequence, MySQL's auto_increment and a YEAR" do
    expect(dumped({ sql_type: "serial" }, :postgresql)).to eq(type: "serial", null: false, own_sequence: true)
    expect(dumped({ sql_type: "bigserial", primary_key: true }, :postgresql)).to eq(type: "bigint", null: false, own_sequence: true)
    expect(dumped({ sql_type: "serial" }, :mysql)).to eq(type: "bigint", unsigned: true, null: false, auto_increment: true)
    expect(dumped({ type: "year", default: 24 }, :mysql)).to eq(type: "integer", year: true, default: "2024")
    expect(dumped({ type: "year", default_sql: "2.5e0" }, :mysql)).to eq(type: "integer", year: true, default: "2002")
  end
end
