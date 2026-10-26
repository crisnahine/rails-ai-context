# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

# The migrations migration_advisor writes, run up and down on a real database: the column comes back as schema.rb had
# it. SQLite always runs; PostgreSQL and MySQL run when RAC_TEST_PG_URL and RAC_TEST_MYSQL_URL (or RAC_TEST_MARIADB_URL) are set.
RSpec.describe RailsAiContext::Tools::MigrationAdvisor do
  let(:conn) { RacAdvisorRecord.connection }

  before do
    stub_const("RacAdvisorRecord", Class.new(ActiveRecord::Base) { self.abstract_class = true })
    RacAdvisorRecord.establish_connection(database_url)
    conn.drop_table(:rac_people, if_exists: true)
    conn.drop_table(:rac_owners, if_exists: true)
    conn.create_table(:rac_owners)
    @root = Dir.mktmpdir
    FileUtils.mkdir_p(File.join(@root, "config"))
    File.write(File.join(@root, "config", "database.yml"), "#{RailsAiContext.environment_name}:\n  adapter: #{conn.adapter_name.downcase}\n  database: x\n")
    allow(described_class).to receive(:rails_app).and_return(RailsAiContext::StaticApp.new(@root))
  end

  after do
    conn.drop_table(:rac_people, if_exists: true)
    conn.drop_table(:rac_owners, if_exists: true)
    RacAdvisorRecord.remove_connection
    FileUtils.rm_rf(@root)
  end

  # The table's schema.rb lines, and the context the static tier reads from them.
  def dumped
    out = StringIO.new
    ActiveRecord::SchemaDumper.dump(ActiveRecord.version >= Gem::Version.new("7.2") ? conn.pool : conn, out)
    [ out.string[/^  create_table "rac_people".*?^  end$/m], *out.string.scan(/^  add_(?:foreign_key|check_constraint) "rac_people".*$/) ].join("\n")
  end

  # Composite foreign keys came in Rails 7.1, and so did the dump's validate: false.
  def rails71?
    ActiveRecord.version >= Gem::Version.new("7.1")
  end

  # A named not-valid foreign key, a composite one, a one- and a two-column index, a partial one where the database has
  # them, an expression index, and a valid and a not-valid check, all on the columns the shared examples remove.
  def add_dependents(partial: true)
    conn.add_column :rac_owners, :code, :string, limit: 20
    conn.add_index :rac_owners, %i[id code], unique: true, name: "owner_pair"
    conn.add_reference :rac_people, :rac_owner, foreign_key: { name: "fk_people_owner", validate: false }
    conn.add_column :rac_people, :owner_code, :string, limit: 20
    conn.add_foreign_key :rac_people, :rac_owners, column: %i[rac_owner_id owner_code], primary_key: %i[id code], name: "fk_people_pair" if rails71?
    conn.add_column :rac_people, :qty, :integer
    conn.add_column :rac_people, :tag, :string, limit: 20
    conn.add_index :rac_people, :qty, name: "one_qty"
    conn.add_index :rac_people, %i[tag qty], name: "two_tag_qty", order: { qty: :desc }
    conn.add_index :rac_people, :tag, name: "pos_tag", where: "qty > 0" if partial
    conn.add_index :rac_people, "(qty + 1)", name: "plus_one" unless conn.respond_to?(:mariadb?) && conn.mariadb?
    conn.add_check_constraint :rac_people, "qty > 0", name: "k_qty"
    conn.add_check_constraint :rac_people, "qty < 1000", name: "k_late", validate: false
  end

  # The column's line and every index, check and foreign key line of the table, which the column's removal can take, and
  # each key's name and columns and each check's validated state as the connection reads them.
  def table_shape(name)
    keys = conn.foreign_keys(:rac_people).map { |fk| [ fk.name.to_s, Array(fk.column).map(&:to_s), (fk.validate? if rails71?) ] }
    checks = conn.check_constraints(:rac_people).map { |c| [ c.name.to_s, (c.validate? if rails71?) ] }
    [ dumped[/^    t\.\S+ "#{name}".*$/], *dumped.scan(/^    t\.(?:index|check_constraint) .*$/).sort, *dumped.scan(/^  add_(?:foreign_key|check_constraint) .*$/).sort,
      keys.sort_by(&:inspect), checks.sort ]
  end

  def context
    FileUtils.mkdir_p(File.join(@root, "db"))
    File.write(File.join(@root, "db", "schema.rb"), "ActiveRecord::Schema[7.0].define(version: 1) do\n#{dumped}\nend\n")
    { schema: RailsAiContext::Introspectors::SchemaIntrospector.new(RailsAiContext::StaticApp.new(@root)).static_call, models: {} }
  end

  # Runs the migration the advisor writes up, then down, on the connection.
  def advise_and_run(ways: %i[up down], **params)
    allow(described_class).to receive(:cached_context).and_return(context)
    text = described_class.call(**params).content.first[:text]
    code = text[/```ruby\n(.*?)```/m, 1] or raise "no migration in #{text}"
    name = code[/class (\w+)/, 1]
    holder = Module.new
    holder.module_eval(code)
    migration = holder.const_get(name)
    ways.each { |way| migration.new.tap { |m| m.verbose = false }.exec_migration(conn, way) }
    code
  end

  # The column's line and the checks that name it: MariaDB keeps a json column as longtext with a json_valid check.
  def column_line(name)
    [ dumped[/^    t\.\S+ "#{name}".*$/], *dumped.scan(/^    t\.check_constraint .*\b#{name}\b.*$/) ]
  end

  # The migration's up leaves the table as the database's own drop of the column does: MySQL refuses that drop while a
  # composite key or an expression index uses the column, so the plain drop removes those first, as the up does.
  shared_examples "an up that drops what the database drops" do |columns|
    columns.each do |name|
      it "leaves after remove_column #{name} runs up what dropping #{name} leaves" do
        allow(described_class).to receive(:cached_context).and_return(context)
        code = described_class.call(action: "remove_column", table: "rac_people", column: name).content.first[:text][/```ruby\n(.*?)```/m, 1]
        migration = Module.new.tap { |m| m.module_eval(code) }.const_get(code[/class (\w+)/, 1])
        run = ->(way) { migration.new.tap { |m| m.verbose = false }.exec_migration(conn, way) }
        run.(:up)
        advised = table_shape(name)
        run.(:down)
        refused = 0
        begin
          conn.remove_column :rac_people, name
        rescue ActiveRecord::StatementInvalid => e
          raise unless conn.adapter_name.match?(/mysql|trilogy/i) && (refused += 1) < 4

          # The up removes these first, so the plain drop does the same before it runs again. MariaDB names the key's index.
          if e.message.include?("needed in a foreign key constraint")
            conn.foreign_keys(:rac_people).select { |fk| Array(fk.column).include?(name) }.map(&:name).uniq.each { |key| conn.remove_foreign_key :rac_people, name: key }
          elsif e.message.include?("has a functional index dependency")
            conn.indexes(:rac_people).select { |idx| idx.columns.is_a?(String) && idx.columns.include?(name) }.each { |idx| conn.remove_index :rac_people, name: idx.name }
          else
            raise
          end
          retry
        end
        expect(advised).to eq(table_shape(name))
      end
    end
  end

  # Each foreign key on the table with its columns, from the server's own catalog: Rails 7.0 reads a composite key as one
  # key per column on MySQL and on its first column only on PostgreSQL.
  def server_keys
    if conn.adapter_name.match?(/postg/i)
      conn.select_rows("SELECT conname, pg_get_constraintdef(oid) FROM pg_constraint WHERE conrelid = 'rac_people'::regclass AND contype = 'f' ORDER BY conname")
    else
      conn.select_rows("SELECT CONSTRAINT_NAME, GROUP_CONCAT(COLUMN_NAME ORDER BY ORDINAL_POSITION) FROM information_schema.KEY_COLUMN_USAGE " \
                       "WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'rac_people' AND REFERENCED_TABLE_NAME IS NOT NULL GROUP BY CONSTRAINT_NAME ORDER BY 1")
    end
  end

  # The composite key as structure.sql gives it, which a Rails 7.0 app's schema.rb and connection cannot.
  shared_examples "a composite key the rollback restores" do
    it "removes the composite key with owner_code and adds it back on the way down" do
      conn.execute("ALTER TABLE rac_people ADD CONSTRAINT fk_people_pair FOREIGN KEY (rac_owner_id, owner_code) REFERENCES rac_owners (id, code)") unless rails71?
      before = server_keys
      pair = { from_table: "rac_people", to_table: "rac_owners", column: %w[rac_owner_id owner_code], primary_key: %w[id code], name: "fk_people_pair" }
      composite = context.tap do |ctx|
        keys = ctx[:schema][:tables]["rac_people"][:foreign_keys]
        keys.reject! { |fk| fk[:name] == "fk_people_pair" }
        keys << pair
      end
      allow(described_class).to receive(:cached_context).and_return(composite)
      code = described_class.call(action: "remove_column", table: "rac_people", column: "owner_code").content.first[:text][/```ruby\n(.*?)```/m, 1]
      migration = Module.new.tap { |m| m.module_eval(code) }.const_get(code[/class (\w+)/, 1])
      migration.new.tap { |m| m.verbose = false }.exec_migration(conn, :up)
      expect(server_keys.map(&:first)).to eq(before.map(&:first) - [ "fk_people_pair" ])
      migration.new.tap { |m| m.verbose = false }.exec_migration(conn, :down)
      expect(server_keys).to eq(before)
    end
  end

  # A name the dump hides (fk_rails_ and ten hex digits) is still the name the server holds; the 7.0 SQL drops it by that name.
  shared_examples "a composite key the schema hides the name of" do
    it "drops and restores the key by the name the server has" do
      conn.remove_foreign_key :rac_people, name: "fk_people_pair" if rails71?
      conn.execute("ALTER TABLE rac_people ADD CONSTRAINT fk_rails_0123456789 FOREIGN KEY (rac_owner_id, owner_code) REFERENCES rac_owners (id, code)")
      before = server_keys
      pair = { from_table: "rac_people", to_table: "rac_owners", column: %w[rac_owner_id owner_code], primary_key: %w[id code], actual_name: "fk_rails_0123456789" }
      composite = context.tap do |ctx|
        ctx[:rails_version] = "7.0.10"
        # Rails 7.0 dumps the key it reads one column at a time; those halves are the key this example replaces.
        ctx[:schema][:tables]["rac_people"][:foreign_keys].reject! { |fk| Array(fk[:column]).map(&:to_s).include?("owner_code") }
        ctx[:schema][:tables]["rac_people"][:foreign_keys] << pair
      end
      allow(described_class).to receive(:cached_context).and_return(composite)
      code = described_class.call(action: "remove_column", table: "rac_people", column: "owner_code").content.first[:text][/```ruby\n(.*?)```/m, 1]
      expect(code).to include("fk_rails_0123456789")
      migration = Module.new.tap { |m| m.module_eval(code) }.const_get(code[/class (\w+)/, 1])
      migration.new.tap { |m| m.verbose = false }.exec_migration(conn, :up)
      expect(server_keys.map(&:first)).to eq(before.map(&:first) - [ "fk_rails_0123456789" ])
      migration.new.tap { |m| m.verbose = false }.exec_migration(conn, :down)
      expect(server_keys).to eq(before)
    end
  end

  shared_examples "a rollback that restores the column" do |columns|
    columns.each do |name|
      it "restores #{name} as schema.rb had it after remove_column runs up and down" do
        before = table_shape(name)
        advise_and_run(action: "remove_column", table: "rac_people", column: name)
        expect(table_shape(name)).to eq(before)
      end
    end
  end

  describe "on SQLite" do
    let(:database_url) { "sqlite3::memory:" }

    before do
      conn.create_table(:rac_people) do |t|
        t.string :code, limit: 20, default: "x", null: false
        t.boolean :flag, default: false
        t.decimal :amount, precision: 8, scale: 2, default: "1.5"
        t.string :kind, collation: "NOCASE"
      end
      add_dependents
    end

    it_behaves_like "a rollback that restores the column", %w[code flag amount kind qty rac_owner_id owner_code]

    it "changes a string column to an integer and back" do
      before = column_line("code")
      advise_and_run(action: "change_type", table: "rac_people", column: "code", type: "integer")
      expect(column_line("code")).to eq(before)
    end
  end

  describe "on PostgreSQL", skip: (ENV["RAC_TEST_PG_URL"] ? false : "set RAC_TEST_PG_URL to run the advisor's migrations on PostgreSQL") do
    let(:database_url) { ENV.fetch("RAC_TEST_PG_URL") }

    before do
      conn.execute("DROP TYPE IF EXISTS rac_mood")
      conn.execute("CREATE TYPE rac_mood AS ENUM ('happy', 'meh')")
      conn.create_table(:rac_people) do |t|
        t.column :mood, :rac_mood, default: "happy"
        t.string :tags, array: true, default: []
        t.string :short_tags, limit: 10, array: true, default: [ "a", "b c" ]
        t.jsonb :meta, default: {}
        t.jsonb :prefs, default: { "a" => nil, "b" => [ 1, nil ] }
        t.bit :flags, limit: 3
        t.string :code, comment: "a code", collation: "C"
        t.string :digits, default: "12"
      end
      add_dependents
    end

    after do
      conn.drop_table(:rac_people, if_exists: true)
      conn.drop_table(:rac_owners, if_exists: true)
      conn.execute("DROP TYPE IF EXISTS rac_mood")
    end

    it_behaves_like "a rollback that restores the column", %w[mood tags short_tags meta prefs flags code qty rac_owner_id owner_code]
    it_behaves_like "an up that drops what the database drops", %w[qty rac_owner_id]
    it_behaves_like "a composite key the rollback restores"
    it_behaves_like "a composite key the schema hides the name of"

    it "restores a jsonb default holding null that the connection reads as JSON text" do
      before = column_line("prefs")
      introspector = RailsAiContext::Introspectors::SchemaIntrospector.new(RailsAiContext::StaticApp.new(@root))
      allow(introspector).to receive(:connection).and_return(conn)
      booted = { schema: { adapter: "postgresql", tables: { "rac_people" => { columns: introspector.send(:extract_columns, "rac_people") } } }, models: {} }
      allow(described_class).to receive(:cached_context).and_return(booted)
      code = described_class.call(action: "remove_column", table: "rac_people", column: "prefs").content.first[:text][/```ruby\n(.*?)```/m, 1]
      expect(code).to include("default: #{{ "a" => nil, "b" => [ 1, nil ] }.inspect}")
      holder = Module.new.tap { |m| m.module_eval(code) }
      migration = holder.const_get(code[/class (\w+)/, 1])
      %i[up down].each { |way| migration.new.tap { |m| m.verbose = false }.exec_migration(conn, way) }
      expect(column_line("prefs")).to eq(before)
    end

    it "casts a string column to an integer with using:, and back" do
      before = column_line("digits")
      code = advise_and_run(action: "change_type", table: "rac_people", column: "digits", type: "integer")
      expect(code).to include(%(using: "digits::integer"))
      expect(column_line("digits")).to eq(before)
    end
  end

  mysql_url = ENV.fetch("RAC_TEST_MYSQL_URL") { ENV["RAC_TEST_MARIADB_URL"] }
  describe "on MySQL or MariaDB", skip: (mysql_url ? false : "set RAC_TEST_MYSQL_URL or RAC_TEST_MARIADB_URL to run the advisor's migrations on MySQL or MariaDB") do
    let(:database_url) { mysql_url }

    before do
      conn.create_table(:rac_people) do |t|
        t.column :kind, "enum('a','b')", default: "a"
        t.bigint :visits, unsigned: true, default: 0
        t.text :bio, size: :medium
        t.string :code, comment: "the code", collation: "utf8mb4_bin"
        t.string :digits, default: "12"
        t.json :data
      end
      add_dependents(partial: false)
    end

    it_behaves_like "a rollback that restores the column", %w[kind visits bio code data qty rac_owner_id owner_code]
    it_behaves_like "an up that drops what the database drops", %w[qty rac_owner_id]
    it_behaves_like "a composite key the rollback restores"
    it_behaves_like "a composite key the schema hides the name of"

    it "changes a string column to an integer and back" do
      before = column_line("digits")
      advise_and_run(action: "change_type", table: "rac_people", column: "digits", type: "integer")
      expect(column_line("digits")).to eq(before)
    end

    it "changes a json column to a string and back" do
      before = column_line("data")
      advise_and_run(action: "change_type", table: "rac_people", column: "data", type: "string")
      expect(column_line("data")).to eq(before)
    end
  end
end
