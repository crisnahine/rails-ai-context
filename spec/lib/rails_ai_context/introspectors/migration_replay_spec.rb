# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "digest"
require "fileutils"

RSpec.describe RailsAiContext::Introspectors::MigrationReplay do
  def replay(migrations, pk_type: "bigint", adapter: nil)
    Dir.mktmpdir do |dir|
      migrations.each_with_index do |content, i|
        File.write(File.join(dir, "202401010000#{i}_step#{i}.rb"), content)
      end
      return described_class.tables(dir, pk_type: pk_type, adapter: adapter)
    end
  end

  it "seeds a replayed create_table with the implicit primary key" do
    tables = replay([ <<~RUBY ])
      class CreatePosts < ActiveRecord::Migration[7.1]
        def change
          create_table :posts do |t|
            t.string :title
          end
        end
      end
    RUBY

    id = tables["posts"][:columns].first
    expect(id).to include(name: "id", type: "bigint", null: false, primary_key: true)
    expect(tables["posts"][:columns].map { |c| c[:name] }).to eq(%w[id title])
  end

  it "replays migrations when the app root is the filesystem root" do
    tables = Dir.mktmpdir do |dir|
      File.write(File.join(dir, "20240101000000_create_posts.rb"), <<~RUBY)
        class CreatePosts < ActiveRecord::Migration[7.1]
          def change
            create_table :posts
          end
        end
      RUBY
      described_class.tables(dir, pk_type: "bigint", root: File::SEPARATOR)
    end

    expect(tables.keys).to eq(%w[posts])
  end

  it "types the implicit key and references per adapter" do
    tables = replay([ <<~RUBY ], pk_type: "integer", adapter: "sqlite3")
      class CreateComments < ActiveRecord::Migration[7.1]
        def change
          create_table :comments do |t|
            t.references :post
          end
        end
      end
    RUBY

    expect(tables["comments"][:columns]).to include(
      hash_including(name: "id", type: "integer"),
      hash_including(name: "post_id", type: "integer")
    )
  end

  it "honours id: false" do
    tables = replay([ <<~RUBY ])
      class CreateJoins < ActiveRecord::Migration[7.1]
        def change
          create_table :posts_tags, id: false do |t|
            t.bigint :post_id
          end
        end
      end
    RUBY

    expect(tables["posts_tags"][:columns].map { |c| c[:name] }).to eq(%w[post_id])
  end

  it "renames a column, and leaves a table it does not know alone" do
    tables = replay([ <<~FIRST, <<~SECOND ])
      class CreateUsers < ActiveRecord::Migration[7.1]
        def change
          create_table :users do |t|
            t.string :email
          end
        end
      end
    FIRST
      class RenameUserEmail < ActiveRecord::Migration[7.1]
        def change
          rename_column :users, :email, :email_address
          rename_column :users, :nope, :still_nope
          rename_column :ghosts, :email, :email_address
        end
      end
    SECOND

    expect(tables["users"][:columns].map { |c| c[:name] }).to eq(%w[id email_address])
    expect(tables).not_to have_key("ghosts")
  end

  it "changes a column type, and leaves the type alone when none is given" do
    tables = replay([ <<~FIRST, <<~SECOND ])
      class CreateUsers < ActiveRecord::Migration[7.1]
        def change
          create_table :users do |t|
            t.string :age
            t.string :name
          end
        end
      end
    FIRST
      class RetypeUsers < ActiveRecord::Migration[7.1]
        def change
          change_column :users, :age, :integer
          change_column :users, :name, null: false
          change_column :users, :nope, :integer
        end
      end
    SECOND

    age = tables["users"][:columns].find { |c| c[:name] == "age" }
    name = tables["users"][:columns].find { |c| c[:name] == "name" }
    expect(age[:type]).to eq("integer")
    expect(name[:type]).to eq("string")
  end

  it "sets and clears a column default" do
    tables = replay([ <<~FIRST, <<~SECOND ])
      class CreateUsers < ActiveRecord::Migration[7.1]
        def change
          create_table :users do |t|
            t.string :role, default: "member"
            t.string :plan, default: "free"
            t.string :tier, default: "basic"
            t.integer :age, default: nil
            t.timestamps default: nil
          end
        end
      end
    FIRST
      class RedefaultUsers < ActiveRecord::Migration[7.1]
        def change
          change_column_default :users, :role, to: "admin"
          change_column_default :users, :plan, to: nil
          change_column_default :users, :tier, from: "basic"
          change_column_default :users, :nope, to: "x"
        end
      end
    SECOND

    cols = tables["users"][:columns].to_h { |c| [ c[:name], c ] }
    expect(cols["role"][:default]).to eq("admin")
    # A nil default is none: the dump writes no default: for it.
    expect(cols.values_at("plan", "age", "created_at").map { |c| c.key?(:default) }).to eq([ false ] * 3)
    expect(cols["tier"][:default]).to eq("basic")
  end

  it "records a standalone add_index the way a create_table block one is recorded" do
    tables = replay([ <<~FIRST, <<~SECOND ])
      class CreateUsers < ActiveRecord::Migration[7.1]
        def change
          create_table :users do |t|
            t.string :email
            t.string :handle
            t.index :handle, unique: true
          end
        end
      end
    FIRST
      class IndexUserEmail < ActiveRecord::Migration[7.1]
        def change
          add_index :users, :email, unique: true, name: "index_users_on_email"
          add_index :ghosts, :email
        end
      end
    SECOND

    expect(tables["users"][:indexes]).to contain_exactly(
      { name: "index_users_on_handle", columns: [ "handle" ], unique: true },
      { name: "index_users_on_email", columns: [ "email" ], unique: true }
    )
  end

  it "applies change_column_null in both directions" do
    tables = replay([ <<~FIRST, <<~SECOND ])
      class CreateUsers < ActiveRecord::Migration[7.1]
        def change
          create_table :users do |t|
            t.string :email
            t.string :name, null: false
          end
        end
      end
    FIRST
      class TightenUsers < ActiveRecord::Migration[7.1]
        def change
          change_column_null :users, :email, false
          change_column_null :users, :name, true
        end
      end
    SECOND

    email = tables["users"][:columns].find { |c| c[:name] == "email" }
    name = tables["users"][:columns].find { |c| c[:name] == "name" }
    expect(email[:null]).to be(false)
    expect(name).not_to have_key(:null)
  end

  it "drops a table a literal DROP TABLE statement names" do
    tables = replay([ <<~FIRST, <<~SECOND ])
      create_table :meeting_contents
      create_table :journals
      create_table :legacy
      create_table :kept
      create_table :mysql_a
      create_table :mysql_b
      create_table :pg_c
    FIRST
      class DeleteOld < ActiveRecord::Migration[8.0]
        def up
          execute("DROP TABLE meeting_contents")
          execute <<~SQL.squish
            DROP TABLE IF EXISTS journals, legacy CASCADE;
          SQL
          execute("DROP TABLE IF EXISTS `mysql_a`, `mysql_b`")
          execute('DROP TABLE "public"."pg_c" CASCADE')
          execute("DROP TABLE \#{name}")
        end

        def down
          execute("DROP TABLE kept")
        end
      end
    SECOND

    expect(tables.keys).to eq(%w[kept])
  end

  it "expands t.timestamps" do
    tables = replay([ <<~RUBY ])
      class CreateEvents < ActiveRecord::Migration[7.1]
        def change
          create_table :events do |t|
            t.string :kind
            t.timestamps
          end
        end
      end
    RUBY

    expect(tables["events"][:columns].map { |c| c[:name] }).to include("created_at", "updated_at")
  end

  # TableDefinition#timestamps and add_timestamps pass their options to both
  # columns (7.0 and 8.1); only a create_table block honours index:.
  describe "timestamps options" do
    let(:tables) do
      replay([ <<~FIRST, <<~SECOND, <<~THIRD ])
        class CreateEvents < ActiveRecord::Migration[7.1]
          def change
            create_table :events do |t|
              t.timestamps precision: nil, null: true, index: true, default: -> { "CURRENT_TIMESTAMP" }
            end
            create_table :notes do |t|
              t.datetime :seen_at, default: -> { "now()" }
              t.datetime :checked_at, default: Time.zone.at(0)
              t.datetime :read_at, default: lambda { "now()" }
            end
            create_table :tags
            change_table :tags do |t|
              t.timestamps index: true
            end
            create_table :pins
            add_timestamps :pins, null: true, default: -> { "now()" }
          end
        end
      FIRST
        class CreateLegacy < ActiveRecord::Migration[4.2]
          def change
            create_table :legacy do |t|
              t.timestamps
            end
          end
        end
      SECOND
        class AddStampsSomewhere < ActiveRecord::Migration[7.1]
          def change
            add_timestamps table_for_stamps
          end
        end
      THIRD
    end

    def column(table, name)
      tables[table][:columns].find { |c| c[:name] == name }
    end

    it "keeps null:, a proc default and index: from a create_table block" do
      expect(column("events", "created_at")).to eq({ name: "created_at", type: "datetime", default: '-> { "CURRENT_TIMESTAMP" }' })
      expect(tables["events"][:indexes].map { |i| i[:name] }).to eq(%w[index_events_on_created_at index_events_on_updated_at])
    end

    it "keeps a proc default on a plain column" do
      expect(column("notes", "seen_at")[:default]).to eq('-> { "now()" }')
      expect(column("notes", "checked_at")).not_to have_key(:default)
      expect(column("notes", "read_at")[:default]).to eq('-> { "now()" }')
    end

    it "adds no index from change_table's timestamps, which run add_timestamps" do
      expect(column("tags", "updated_at")).to eq({ name: "updated_at", type: "datetime", null: false })
      expect(tables["tags"][:indexes]).to be_empty
    end

    it "replays add_timestamps with its options" do
      expect(column("pins", "created_at")).to eq({ name: "created_at", type: "datetime", default: '-> { "now()" }' })
    end

    it "allows NULL by default before 5.0" do
      expect(column("legacy", "created_at")).not_to have_key(:null)
    end

    it "counts an add_timestamps whose table it cannot read" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "1_a.rb"), "add_timestamps table_for_stamps\n")
        expect(described_class.replayed(dir, pk_type: "bigint").counts.helper_calls).to eq(1)
      end
    end
  end

  # `def up` creates, `def down` undoes it - the ordinary shape of an
  # irreversible migration. Replaying both bodies cancels the table out, and
  # the table the app really has disappears from the schema answer.
  it "ignores a drop_table that only runs on the way down" do
    tables = replay([ <<~RUBY ])
      class CreateProjectTypes < ActiveRecord::Migration[7.1]
        def up
          create_table :project_types do |t|
            t.string :name
          end
        end

        def down
          drop_table :project_types
        end
      end
    RUBY

    expect(tables.keys).to include("project_types")
  end

  it "ignores a create_table that only runs on the way down" do
    tables = replay([ <<~RUBY ])
      class DropLegacyThings < ActiveRecord::Migration[7.1]
        def up
          drop_table :legacy_things
        end

        def down
          create_table :legacy_things do |t|
            t.string :name
          end
        end
      end
    RUBY

    expect(tables.keys).not_to include("legacy_things")
  end

  # t.timestamps is found by its own walk over the whole file, so a `down`
  # body's timestamps were attributed to the last table created on the way up.
  it "does not give an up table the timestamps of a down table" do
    tables = replay([ <<~RUBY ])
      class SwapWidgets < ActiveRecord::Migration[7.1]
        def up
          create_table :widgets do |t|
            t.string :name
          end
        end

        def down
          create_table :old_widgets do |t|
            t.string :name
            t.timestamps
          end
        end
      end
    RUBY

    expect(tables["widgets"][:columns].map { |c| c[:name] }).to eq(%w[id name])
  end

  # `reversible` and `revert` are the modern spelling of the same intent, and
  # they are blocks inside `change` rather than a method named down.
  it "ignores a drop inside reversible's down block" do
    tables = replay([ <<~RUBY ])
      class CreateProjectTypes < ActiveRecord::Migration[7.1]
        def change
          create_table :project_types do |t|
            t.string :name
          end

          reversible do |dir|
            dir.down { drop_table :project_types }
          end
        end
      end
    RUBY

    expect(tables.keys).to include("project_types")
  end

  describe "statements Rails runs differently from how they read" do
    let(:tables) do
      replay([ <<~RUBY, <<~RUBY2 ])
        class CreateUsers < ActiveRecord::Migration[8.1]
          def change
            create_table :users do |t|
              t.string :email
              if connection.supports_datetime_with_precision?
                t.datetime :created_at, precision: 6, null: false
              else
                t.datetime :created_at, null: false
              end
            end
            add_index :users, :email
            rename_index :users, "index_users_on_email", "uniq_email"
            create_table :users, if_not_exists: true do |t|
              t.string :never_added
            end
            create_table :scratch, temporary: true do |t|
              t.string :x
            end
            create_table :user_copies, as: "SELECT id, email FROM users"
            execute "CREATE TABLE raw_things (id integer primary key, name varchar)"
            execute "CREATE UNLOGGED TABLE cache_entries (id bigserial primary key, key varchar NOT NULL)"
          end
        end
      RUBY
        class Legacy < ActiveRecord::Migration[5.0]
          def change
            create_table :legacies do |t|
              t.references :user
            end
          end
        end
      RUBY2
    end

    it "keeps one column when both branches of an if declare it" do
      expect(tables["users"][:columns].map { |c| c[:name] }).to eq(%w[id email created_at])
    end

    it "renames an index rename_index names" do
      expect(tables["users"][:indexes].map { |i| i[:name] }).to eq([ "uniq_email" ])
    end

    it "leaves out temporary tables and keeps the select's columns for an as: table" do
      expect(tables.keys).not_to include("scratch")
      expect(tables["user_copies"][:columns].map { |c| c[:name] }).to eq(%w[id email])
    end

    # schema.rb's own reader also sees a string-named create_table; it must skip what the migration skips.
    it "leaves out a string-named temporary table and an existing table's if_not_exists block" do
      skipped = replay([ <<~RUBY ])
        class Scratch < ActiveRecord::Migration[8.1]
          def change
            create_table "posts"
            create_table "posts", if_not_exists: true do |t|
              t.string :never_added
            end
            create_table "scratch", temporary: true do |t|
              t.string :x
            end
            create_table "tags", if_not_exists: true do |t|
              t.string :name
            end
          end
        end
      RUBY

      expect(skipped.keys).to eq(%w[posts tags])
      expect(skipped.transform_values { |t| t[:columns].map { |c| c[:name] } }).to eq("posts" => %w[id], "tags" => %w[id name])
    end

    it "reads a table an execute creates" do
      expect(tables["raw_things"][:columns].map { |c| c[:name] }).to eq(%w[id name])
    end

    it "reads an unlogged table an execute creates" do
      expect(tables["cache_entries"][:columns].map { |c| c[:name] }).to eq(%w[id key])
    end

    it "survives SQL it cannot read" do
      odd = replay([ <<~RUBY ])
        class Odd < ActiveRecord::Migration[8.1]
          def change
            create_table :copies, as: "SELECT lower(email) FROM missing"
            create_table :empty_copies, as: ""
            execute "CREATE TABLE ("
          end
        end
      RUBY

      expect(odd["copies"][:columns]).to eq([ { name: "lower", type: nil } ])
      expect(odd).not_to have_key("empty_copies")
    end

    # V5_0 keys the table with integer, which PostgreSQL's rules back with a sequence: the dump's id: :serial.
    it "gives a Migration[5.0] table integer keys" do
      expect(tables["legacies"][:columns].map { |c| [ c[:name], c[:type] ] }).to eq([ %w[id serial], %w[user_id integer] ])
    end
  end

  describe "a revert block" do
    let(:create_posts) do
      <<~RUBY
        class CreatePosts < ActiveRecord::Migration[8.1]
          def change
            create_table :posts do |t|
              t.string :title
            end
            add_column :posts, :slug, :string
            add_index :posts, :slug
          end
        end
      RUBY
    end

    it "undoes the create_table it wraps" do
      tables = replay([ create_posts, <<~RUBY ])
        class DropPostsAgain < ActiveRecord::Migration[8.1]
          def change
            revert do
              create_table :posts do |t|
                t.string :title
              end
            end
          end
        end
      RUBY

      expect(tables.keys).not_to include("posts")
    end

    it "runs its statements inverted, last first" do
      tables = replay([ create_posts, <<~RUBY ])
        class UndoSlug < ActiveRecord::Migration[8.1]
          def change
            revert do
              add_column :posts, :body, :text
              rename_column :posts, :title, :headline
              add_index :posts, :slug
              remove_column :posts, :draft, :boolean
            end
          end
        end
      RUBY

      expect(tables["posts"][:columns].map { |c| c[:name] }).to eq(%w[id title slug draft])
      expect(tables["posts"][:indexes]).to be_empty
    end

    it "runs a revert nested in a revert forward, as Rails flips it back" do
      tables = replay([ create_posts, <<~RUBY ])
        class Twice < ActiveRecord::Migration[8.1]
          def change
            revert do
              add_column :posts, :body, :text
              revert do
                add_column :posts, :summary, :text
                add_column :posts, :lede, :text
              end
            end
          end
        end
      RUBY

      expect(tables["posts"][:columns].map { |c| c[:name] }).to eq(%w[id title slug summary lede])
    end

    it "counts the class form it cannot see into as not replayed" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "20240101000000_create_posts.rb"), create_posts)
        File.write(File.join(dir, "20240101000001_undo_posts.rb"), <<~RUBY)
          class UndoPosts < ActiveRecord::Migration[8.1]
            def change
              revert CreatePosts
            end
          end
        RUBY
        expect(described_class.replayed(dir, pk_type: "bigint").counts.helper_calls).to eq(1)
      end
    end
  end

  # One app has a migration that calls `create_table table_name do |t|`, where
  # the name is a local computed at run time. A table the replay cannot name is
  # a table it cannot report, and keeping it produced a nil key that took the
  # whole context run down when a serializer sorted the table names.
  it "skips a create_table whose name it cannot resolve" do
    tables = replay([ <<~RUBY ])
      class CreateComputed < ActiveRecord::Migration[7.1]
        def change
          table_name = "widgets_\#{Shard.current.id}"
          create_table table_name do |t|
            t.string :name
          end
        end
      end
    RUBY

    expect(tables.keys).to all(be_a(String))
    expect(tables.keys).not_to include(nil)
  end

  # The fix must not reach so far that it stops honouring a real drop.
  it "still drops a table a later migration removes on the way up" do
    tables = replay([ <<~RUBY, <<~RUBY2 ])
      class CreateWidgets < ActiveRecord::Migration[7.1]
        def change
          create_table :widgets do |t|
            t.string :name
          end
        end
      end
    RUBY
      class DropWidgets < ActiveRecord::Migration[7.1]
        def up
          drop_table :widgets
        end
      end
    RUBY2

    expect(tables.keys).not_to include("widgets")
  end

  it "parses a migration's source once" do
    source = <<~RUBY
      class CreateWidgets < ActiveRecord::Migration[7.1]
        def up
          create_table :widgets do |t|
            t.string :name
            t.timestamps
          end
        end

        def down
          drop_table :widgets
        end
      end
    RUBY

    parses = 0
    allow(RailsAiContext::AstCache).to receive(:parse_string).and_wrap_original do |original, *args|
      parses += 1
      original.call(*args)
    end

    described_class.replay(source, {}, described_class.new_run([], pk_type: "bigint", root: Dir.tmpdir))

    expect(parses).to eq(1)
  end
  # An app can create 99 of its tables in db/migrate/tables/*.rb, required by
  # db/migrate/1000016_aggregated_migrations.rb. Reading db/migrate/*.rb alone
  # found 37 tables and answered "Table 'work_packages' not found".
  describe "a migration that requires other files under db/" do
    def app_with(files)
      Dir.mktmpdir do |dir|
        files.each do |rel, body|
          path = File.join(dir, rel)
          FileUtils.mkdir_p(File.dirname(path))
          File.write(path, body)
        end
        return yield(dir)
      end
    end

    it "follows a Dir glob the migration requires" do
      tables = app_with(
        "db/migrate/100_aggregated.rb" => <<~RUBY,
          Dir[Rails.root.join("db/migrate/tables/*.rb").to_s].each { |file| require file }
          class Aggregated < ActiveRecord::Migration[7.1]
          end
        RUBY
        "db/migrate/tables/widgets.rb" => <<~RUBY
          create_table "widgets" do |t|
            t.string :name
          end
        RUBY
      ) { |dir| described_class.tables(File.join(dir, "db/migrate"), pk_type: "bigint", root: dir) }

      expect(tables.keys).to include("widgets")
      expect(tables["widgets"][:columns].map { |c| c[:name] }).to eq(%w[id name])
    end

    it "follows require_relative from the requiring file's own directory" do
      tables = app_with(
        "db/migrate/100_aggregated.rb" => "require_relative \"tables/gadgets\"\n",
        "db/migrate/tables/gadgets.rb" => <<~RUBY
          create_table "gadgets" do |t|
            t.string :label
          end
        RUBY
      ) { |dir| described_class.tables(File.join(dir, "db/migrate"), pk_type: "bigint", root: dir) }

      expect(tables.keys).to include("gadgets")
    end

    it "reads a required file once however many migrations require it" do
      tables = app_with(
        "db/migrate/100_a.rb" => "require_relative \"tables/thing\"\n",
        "db/migrate/200_b.rb" => "require_relative \"tables/thing\"\n",
        "db/migrate/tables/thing.rb" => "create_table \"things\" do |t|\n  t.string :a\nend\n"
      ) { |dir| described_class.tables(File.join(dir, "db/migrate"), pk_type: "bigint", root: dir) }

      expect(tables["things"][:columns].map { |c| c[:name] }).to eq(%w[id a])
    end

    it "refuses a require that reaches outside db/" do
      tables = app_with(
        "db/migrate/100_a.rb" => "require_relative \"../../lib/sneaky\"\n",
        "lib/sneaky.rb" => "create_table \"sneaky\" do |t|\n  t.string :a\nend\n"
      ) { |dir| described_class.tables(File.join(dir, "db/migrate"), pk_type: "bigint", root: dir) }

      expect(tables.keys).not_to include("sneaky")
    end

    it "ignores a require whose path is computed" do
      tables = app_with(
        "db/migrate/100_a.rb" => "require File.join(some_dir, \"thing\")\n",
        "db/migrate/tables/thing.rb" => "create_table \"things\" do |t|\nend\n"
      ) { |dir| described_class.tables(File.join(dir, "db/migrate"), pk_type: "bigint", root: dir) }

      expect(tables.keys).not_to include("things")
    end

    it "follows an engine migration's requires within the engine's db/" do
      tables = app_with(
        "modules/costs/db/migrate/100_costs.rb" => "require_relative \"tables/time_entries\"\n",
        "modules/costs/db/migrate/tables/time_entries.rb" => "create_table \"time_entries\" do |t|\n  t.float :hours\nend\n",
        "modules/meeting/db/migrate/200_meeting.rb" => "Dir[File.join(__dir__, \"tables/*.rb\")].each { |file| require file }\n",
        "modules/meeting/db/migrate/tables/meetings.rb" => "create_table \"meetings\" do |t|\n  t.string :title\nend\n",
        "modules/wiki/db/migrate/300_wiki.rb" => "require File.expand_path(\"tables/pages\", __dir__)\n",
        "modules/wiki/db/migrate/tables/pages.rb" => "create_table \"pages\" do |t|\nend\n",
        "modules/wiki/db/migrate/400_sneaky.rb" => "require_relative \"../../lib/sneaky\"\n",
        "modules/wiki/lib/sneaky.rb" => "create_table \"sneaky\" do |t|\nend\n"
      ) do |dir|
        dirs = %w[db/migrate modules/costs/db/migrate modules/meeting/db/migrate modules/wiki/db/migrate].map { |d| File.join(dir, d) }
        described_class.tables(dirs, pk_type: "bigint", root: dir)
      end

      expect(tables.keys).to include("time_entries", "meetings", "pages")
      expect(tables.keys).not_to include("sneaky")
      expect(tables["meetings"][:columns].map { |c| c[:name] }).to eq(%w[id title])
    end
  end

  # Tables::Base derives the name from the class (name.demodulize.underscore),
  # so the create_table call carries no literal to read.
  describe "a create_table whose name is not a literal" do
    def replay_file(rel, body)
      Dir.mktmpdir do |dir|
        path = File.join(dir, rel)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, body)
        tables = {}
        described_class.send(:replay_file, path, tables, described_class.new_run([], pk_type: "bigint", root: dir))
        return tables
      end
    end

    it "takes the name from the class when it matches the file" do
      tables = replay_file("db/migrate/tables/work_packages.rb", <<~RUBY)
        class Tables::WorkPackages < Tables::Base
          def self.table(migration)
            create_table migration do |t|
              t.string :subject
            end
          end
        end
      RUBY

      expect(tables.keys).to eq([ "work_packages" ])
      expect(tables["work_packages"][:columns].map { |c| c[:name] }).to eq(%w[id subject])
      expect(tables["work_packages"][:inferred_name]).to be(true)
    end

    # Tables::Base calls create_table from a helper of its own, which read as a
    # table called `base` with nothing in it.
    it "drops an inferred table that gained no column" do
      tables = replay_file("db/migrate/tables/base.rb", <<~RUBY)
        class Tables::Base
          def self.create_unlogged_table(migration, id: :bigint)
            create_table(migration, id:)
          end
        end
      RUBY

      expect(tables).to be_empty
    end

    # With inflect.acronym "OAuth" declared, Tables::OAuthApplications
    # is oauth_applications to Rails; a plain underscore makes it
    # o_auth_applications, missed the file name, and dropped five tables.
    it "matches a class to its file across an acronym the app inflects" do
      tables = replay_file("db/migrate/tables/oauth_applications.rb", <<~RUBY)
        class Tables::OAuthApplications < Tables::Base
          def self.table(migration)
            create_table migration do |t|
              t.string :name
            end
          end
        end
      RUBY

      expect(tables.keys).to eq([ "oauth_applications" ])
    end

    # "Shop_Items".underscore is shop_items, the file's name.
    it "matches a class whose name keeps an underscore to its file" do
      tables = replay_file("db/migrate/tables/shop_items.rb", <<~RUBY)
        class Tables::Shop_Items < Tables::Base
          def self.table(migration)
            create_table migration do |t|
              t.string :name
            end
          end
        end
      RUBY

      expect(tables.keys).to eq([ "shop_items" ])
    end

    it "invents nothing when the class name does not match the file" do
      tables = replay_file("db/migrate/20240101_create_foos.rb", <<~RUBY)
        class CreateFoos < ActiveRecord::Migration[7.1]
          def change
            create_table some_name do |t|
              t.string :a
            end
          end
        end
      RUBY

      expect(tables).to be_empty
    end
  end
  # A helper the replayed files define is read for what it does. A name
  # pattern would not do: a create_join_table :web_hooks, :categories
  # makes categories_web_hooks, and reading it as create_table would redefine
  # web_hooks with nothing but an id.
  describe "a table helper the replayed files define" do
    def app_with(files)
      Dir.mktmpdir do |dir|
        files.each do |rel, body|
          path = File.join(dir, rel)
          FileUtils.mkdir_p(File.dirname(path))
          File.write(path, body)
        end
        return yield(dir)
      end
    end

    let(:base) do
      <<~RUBY
        class Tables::Base
          def self.create_unlogged_table(migration, id: :bigint, **, &)
            create_table(migration, id:, **, &)
          end
        end
      RUBY
    end

    # An app can create sessions through Tables::Base.create_unlogged_table.
    it "reads a call to a helper that forwards its first argument to create_table" do
      result = app_with(
        "db/migrate/100_aggregated.rb" => "require_relative \"tables/sessions\"\n",
        "db/migrate/tables/base.rb" => base,
        "db/migrate/tables/sessions.rb" => <<~RUBY
          require_relative "base"
          class Tables::Sessions < Tables::Base
            def self.table(migration)
              create_unlogged_table migration do |t|
                t.string :session_id, null: false
              end
            end
          end
        RUBY
      ) { |dir| described_class.replayed(File.join(dir, "db/migrate"), pk_type: "bigint", root: dir) }

      expect(result.tables.keys).to eq([ "sessions" ])
      expect(result.tables["sessions"][:columns].map { |c| c[:name] }).to eq(%w[id session_id])
      expect(result.counts.unnamed).to eq(0)
    end

    it "takes a literal name passed through the helper" do
      tables = app_with(
        "db/migrate/100_a.rb" => <<~RUBY
          def make_table(name, &block)
            create_table(name, &block)
          end

          make_table "widgets" do |t|
            t.string :label
          end
        RUBY
      ) { |dir| described_class.tables(File.join(dir, "db/migrate"), pk_type: "bigint", root: dir) }

      expect(tables.keys).to eq([ "widgets" ])
      expect(tables["widgets"][:columns].map { |c| c[:name] }).to eq(%w[id label])
    end

    it "leaves create_join_table alone" do
      tables = app_with(
        "db/migrate/100_a.rb" => "create_table :web_hooks do |t|\n  t.string :url\nend\n",
        "db/migrate/200_b.rb" => "create_join_table :web_hooks, :categories\n"
      ) { |dir| described_class.tables(File.join(dir, "db/migrate"), pk_type: "bigint", root: dir) }

      expect(tables["web_hooks"][:columns].map { |c| c[:name] }).to eq(%w[id url])
    end
  end

  describe "create_table calls the replay cannot name" do
    it "counts them" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "db/migrate"))
        File.write(File.join(dir, "db/migrate/20240101_create_things.rb"), <<~RUBY)
          class CreateThings < ActiveRecord::Migration[7.1]
            def change
              create_table table_name_from_somewhere do |t|
                t.string :a
              end
              create_table :named do |t|
                t.string :b
              end
            end
          end
        RUBY

        result = described_class.replayed(File.join(dir, "db/migrate"), pk_type: "bigint", root: dir)

        expect(result.tables.keys).to eq([ "named" ])
        expect(result.counts.unnamed).to eq(1)
      end
    end
  end
  # A migration that names no index gets the name Rails generates, which the
  # schema printed as an empty `` before.
  describe "an index the migration gives no name" do
    it "takes Rails' default name" do
      tables = replay([ <<~RUBY ])
        create_table :announcements do |t|
          t.date :show_until
          t.boolean :active
          t.index %i[show_until active]
        end
      RUBY

      expect(tables["announcements"][:indexes].first[:name]).to eq("index_announcements_on_show_until_and_active")
    end

    it "carries a partial index's where: condition" do
      tables = replay([ "create_table :posts do |t|\n  t.string :slug\nend\n",
                        "add_index :posts, :slug, unique: true, where: \"deleted_at IS NULL\"\n" ])

      expect(tables["posts"][:indexes].first).to include(unique: true, where: "deleted_at IS NULL")
    end

    it "names a standalone add_index the same way" do
      tables = replay([ "create_table :posts do |t|\n  t.string :slug\nend\n", "add_index :posts, :slug\n" ])

      expect(tables["posts"][:indexes].first[:name]).to eq("index_posts_on_slug")
    end

    # Rails 7.1+ shortens a name past 62 bytes to idx_on_<cols>_<sha256 prefix>.
    it "shortens a name too long for the database the way Rails does" do
      tables = replay([ <<~RUBY ])
        create_table :project_custom_field_project_mappings do |t|
          t.bigint :custom_field_id
          t.bigint :project_id
          t.index %i[custom_field_id project_id]
        end
      RUBY

      long = "index_project_custom_field_project_mappings_on_custom_field_id_and_project_id"
      hash = "_" + Digest::SHA256.hexdigest(long)[0, 10]
      expect(tables["project_custom_field_project_mappings"][:indexes].first[:name])
        .to eq("idx_on_custom_field_id_project_id#{hash}")
    end

    it "keeps a name the migration gives" do
      tables = replay([ "create_table :posts do |t|\n  t.string :slug\n  t.index :slug, name: :by_slug\nend\n" ])

      expect(tables["posts"][:indexes].first[:name]).to eq("by_slug")
    end
  end
  # Rails' ReferenceDefinition (7.0 to 8.1) indexes a reference by default;
  # the replay added the column and no index, so a replayed app read every
  # reference as unindexed.
  describe "a reference" do
    def replayed(source)
      replay([ source ])["comments"]
    end

    def index_on(table, *cols)
      table[:indexes].find { |i| i[:columns] == cols }
    end

    it "gets Rails' default index inside create_table" do
      table = replayed("create_table :comments do |t|\n  t.references :user\nend\n")

      expect(index_on(table, "user_id")).to eq({ name: "index_comments_on_user_id", columns: %w[user_id], unique: false })
    end

    it "indexes t.belongs_to the same way" do
      table = replayed("create_table :comments do |t|\n  t.belongs_to :post\nend\n")

      expect(index_on(table, "post_id")[:name]).to eq("index_comments_on_post_id")
    end

    it "adds the type column and indexes the pair for a polymorphic reference" do
      table = replayed("create_table :comments do |t|\n  t.references :commentable, polymorphic: true, null: false\nend\n")

      expect(table[:columns].map { |c| c[:name] }).to eq(%w[id commentable_type commentable_id])
      expect(table[:columns].find { |c| c[:name] == "commentable_type" }).to include(type: "string", null: false)
      expect(index_on(table, "commentable_type", "commentable_id"))
        .to eq({ name: "index_comments_on_commentable", columns: %w[commentable_type commentable_id], unique: false })
    end

    it "adds no index for index: false" do
      table = replayed("create_table :comments do |t|\n  t.references :user, index: false\nend\n")

      expect(table[:indexes]).to be_empty
    end

    it "honours index: { unique: true } and a given name" do
      table = replayed(<<~RUBY)
        create_table :comments do |t|
          t.references :author, index: { unique: true }
          t.references :editor, index: { name: "by_editor" }
        end
      RUBY

      expect(index_on(table, "author_id")).to include(name: "index_comments_on_author_id", unique: true)
      expect(index_on(table, "editor_id")).to include(name: "by_editor", unique: false)
    end

    # TableDefinition#references (7.0 to 8.1) defines each name it is given;
    # An epub_exports table can read three references off one call.
    it "reads every name of one t.references call" do
      table = replayed(<<~RUBY)
        create_table :comments do |t|
          t.references :export, :course, :user, foreign_key: true
        end
      RUBY

      expect(table[:columns].map { |c| c[:name] }).to eq(%w[id export_id course_id user_id])
      expect(table[:indexes].map { |i| i[:columns] }).to eq([ %w[export_id], %w[course_id], %w[user_id] ])
      expect(table[:foreign_keys].map { |fk| fk[:column] }).to eq(%w[export_id course_id user_id])
    end

    it "reads every name in a change_table block, adding and removing" do
      table = replay([
        "create_table :comments do |t|\n  t.string :body\nend\n",
        "change_table :comments do |t|\n  t.belongs_to :a, :b\nend\n",
        "change_table :comments do |t|\n  t.remove_references :a, :b\nend\n"
      ])["comments"]

      expect(table[:columns].map { |c| c[:name] }).to eq(%w[id body])
    end

    # A `t.replica_identity_index` can be an app method that adds an index
    # the replay cannot see, so the table's index list may be short.
    it "marks a table whose block calls a method the replay does not read" do
      tables = replay([ <<~RUBY ])
        create_table :comments do |t|
          t.references :root_account, index: false
          t.replica_identity_index
          t.timestamps
        end
        create_table :posts do |t|
          t.references :user
          t.foreign_key :users
          t.timestamps
        end
      RUBY

      expect(tables["comments"][:unread_calls]).to eq(%w[replica_identity_index])
      expect(tables["posts"]).not_to have_key(:unread_calls)
    end

    it "replays a table block whose parameter is not t" do
      tables = replay([ <<~RUBY ])
        class CreatePosts < ActiveRecord::Migration[7.1]
          def change
            create_table :posts do |table|
              table.string :title
              table.references :user
              table.index :title
              table.timestamps
            end
            change_table :posts do |tbl|
              tbl.integer :views
              tbl.rename :title, :headline
            end
            reversible do |dir|
              dir.up { add_column :posts, :x, :string }
            end
          end
        end
      RUBY

      expect(tables["posts"][:columns].map { |c| c[:name] }).to eq(%w[id headline user_id created_at updated_at views x])
      expect(tables["posts"][:indexes].map { |i| i[:columns] }).to contain_exactly(%w[headline], %w[user_id])
    end

    it "replays a table block that names its table _1 or it" do
      tables = replay([ <<~RUBY ])
        class CreatePosts < ActiveRecord::Migration[7.1]
          def change
            create_table :posts do
              _1.string :title
              _1.index :title
            end
            create_table :tags do
              it.string :name
              it.timestamps
            end
            change_table :posts do
              it.integer :views
              it.rename :title, :headline
            end
            change_table :tags do
              _1.remove :name
            end
          end
        end
      RUBY

      expect(tables.transform_values { |table| table[:columns].map { |c| c[:name] } }).to eq(
        "posts" => %w[id headline views], "tags" => %w[id created_at updated_at]
      )
      expect(tables["posts"][:indexes].map { |i| i[:columns] }).to eq([ %w[headline] ])
    end

    it "reads a call on another block's `t` as no table call" do
      tables = replay([ <<~RUBY ])
        class CreateTags < ActiveRecord::Migration[7.1]
          def up
            create_table :tags do |t|
              t.string :name
            end
            Tag.find_each { |t| t.update!(slug: t.name.parameterize) }
            Tag.all.each { |t| t.remove :name }
          end
        end
      RUBY

      expect(tables["tags"]).not_to have_key(:unread_calls)
      expect(tables["tags"][:columns].map { |c| c[:name] }).to eq(%w[id name])
    end

    it "indexes an add_reference too" do
      table = replay([
        "create_table :comments do |t|\n  t.string :body\nend\n",
        "add_reference :comments, :blog\n",
        "add_reference :comments, :owner, polymorphic: true, index: false\n"
      ])["comments"]

      expect(index_on(table, "blog_id")[:name]).to eq("index_comments_on_blog_id")
      expect(table[:columns].map { |c| c[:name] }).to include("owner_type", "owner_id")
      expect(index_on(table, "owner_type", "owner_id")).to be_nil
    end
  end
  # The database moves an index to a renamed column, and Rails renames a
  # default-named index to match (rename_column_indexes, 7.0 to 8.1).
  # An app can rename favorites.favored_* to favorited_*; the replay kept the
  # old keys, and the missing-index check reported the pair unindexed.
  describe "rename_column and the indexes on the column" do
    let(:table) do
      replay([
        <<~RUBY,
          create_table :favorites do |t|
            t.references :favored, polymorphic: true
            t.string :note
            t.index :note, name: "by_note"
          end
        RUBY
        <<~RUBY
          rename_column :favorites, :favored_id, :favorited_id
          rename_column :favorites, :favored_type, :favorited_type
          rename_column :favorites, :note, :remark
        RUBY
      ])["favorites"]
    end

    it "moves each index onto the renamed column" do
      expect(table[:indexes].map { |i| i[:columns] }).to contain_exactly(%w[favorited_type favorited_id], %w[remark])
    end

    it "keeps a name Rails would not have generated from the old columns" do
      expect(table[:indexes].map { |i| i[:name] }).to contain_exactly("index_favorites_on_favored", "by_note")
    end

    it "renames an index whose name was the default for the old columns" do
      renamed = replay([
        "create_table :posts do |t|\n  t.string :title\n  t.index :title\nend\n",
        "rename_column :posts, :title, :heading\n"
      ])["posts"]

      expect(renamed[:indexes]).to eq([ { name: "index_posts_on_heading", columns: %w[heading], unique: false } ])
    end
  end
  # TableDefinition#column (7.0 to 8.1) indexes a column declared with
  # index: (a work_package_journals table can declare type_id and
  # project_id that way), and the replay dropped both indexes.
  describe "a column declared with index:" do
    let(:table) do
      replay([ <<~RUBY ])["journals"]
        create_table :journals do |t|
          t.bigint :type_id, null: false, index: true
          t.string :token, index: { unique: true }
          t.string :slug, index: { name: "by_slug" }
          t.string :body, index: false
        end
      RUBY
    end

    it "gets Rails' default index" do
      expect(table[:indexes]).to include({ name: "index_journals_on_type_id", columns: %w[type_id], unique: false })
    end

    it "honours unique and a given name" do
      expect(table[:indexes]).to include({ name: "index_journals_on_token", columns: %w[token], unique: true })
      expect(table[:indexes]).to include({ name: "by_slug", columns: %w[slug], unique: false })
    end

    it "adds none for index: false" do
      expect(table[:indexes].map { |i| i[:columns] }).not_to include(%w[body])
    end
  end
  # rename_table renames each index whose name was the default for the old
  # table (rename_table_indexes, 7.0 and 8.1); a name the migration chose stays.
  describe "rename_table and the table's indexes" do
    let(:table) do
      replay([
        <<~RUBY,
          create_table :posts do |t|
            t.references :user
            t.string :slug
            t.index :slug, name: "by_slug"
          end
        RUBY
        "rename_table :posts, :articles\n"
      ])["articles"]
    end

    it "renames a default-named index to the new table's default name" do
      expect(table[:indexes].map { |i| i[:name] }).to include("index_articles_on_user_id")
      expect(table[:indexes].map { |i| i[:name] }).not_to include("index_posts_on_user_id")
    end

    it "keeps a name the migration chose" do
      expect(table[:indexes].map { |i| i[:name] }).to include("by_slug")
    end
  end
  # Each expectation is what Rails' dumper writes after running the same migrations on SQLite.
  describe "renames, drops and if_not_exists as Rails runs them" do
    it "moves foreign keys with rename_table and rename_column" do
      tables = replay([ <<~RUBY, <<~RUBY2 ])
        class CreateThings < ActiveRecord::Migration[7.1]
          def change
            create_table :authors do |t|
              t.string :name
            end
            create_table :posts do |t|
              t.references :user, foreign_key: { to_table: :authors }
              t.bigint :editor_id
            end
            add_foreign_key :posts, :authors, column: :editor_id
          end
        end
      RUBY
        class RenameThings < ActiveRecord::Migration[7.1]
          def change
            rename_table :authors, :writers
            rename_column :posts, :user_id, :writer_id
            rename_table :posts, :articles
          end
        end
      RUBY2

      keys = tables["articles"][:foreign_keys].map { |fk| fk.slice(:from_table, :to_table, :column, :primary_key) }
      expect(keys).to contain_exactly(
        { from_table: "articles", to_table: "writers", column: "writer_id", primary_key: "id" },
        { from_table: "articles", to_table: "writers", column: "editor_id", primary_key: "id" }
      )
    end

    # PostgreSQL's dump after the same migration; SQLite's rebuild keeps the old name.
    it "renames the primary_key a foreign key points at" do
      migration = <<~RUBY
        create_table :authors, id: false do |t|
          t.string :code, primary_key: true
        end
        create_table :posts do |t|
          t.string :author_code
        end
        add_foreign_key :posts, :authors, column: :author_code, primary_key: :code
        rename_column :authors, :code, :slug
      RUBY

      expect(replay([ migration ], adapter: "postgresql")["posts"][:foreign_keys].first).to include(to_table: "authors", column: "author_code", primary_key: "slug")
      expect(replay([ migration ], adapter: "sqlite3")["posts"][:foreign_keys].first).to include(primary_key: "code")
    end

    # PostgreSQL keeps a key on the column, so each renamed column of a composite key follows.
    it "renames a column of a composite foreign key on both of its tables" do
      migration = <<~RUBY
        create_table :orders, primary_key: [:shop_id, :id] do |t|
          t.integer :shop_id
          t.integer :id
        end
        create_table :items do |t|
          t.integer :order_shop_id
          t.integer :order_id
        end
        add_foreign_key :items, :orders, column: [:order_shop_id, :order_id], primary_key: [:shop_id, :id]
        rename_column :items, :order_id, :order_ref
        rename_column :orders, :shop_id, :store_id
      RUBY

      tables = replay([ migration ], adapter: "postgresql")
      expect(tables["items"][:foreign_keys].first).to include(column: %w[order_shop_id order_ref], primary_key: %w[store_id id])
      expect(tables["orders"][:primary_key]).to eq(%w[store_id id])
    end

    it "drops every table drop_table names, and drop_join_table's table" do
      tables = replay([ <<~RUBY, <<~RUBY2 ])
        class CreateThings < ActiveRecord::Migration[7.1]
          def change
            create_table :users
            create_table :old_logs
            create_table :old_events
            create_join_table :users, :roles
            create_join_table :users, :teams, table_name: :memberships
          end
        end
      RUBY
        class DropThings < ActiveRecord::Migration[7.1]
          def change
            drop_table :old_logs, :old_events
            drop_join_table :users, :roles
            drop_join_table :users, :teams, table_name: :memberships
          end
        end
      RUBY2

      expect(tables.keys).to eq(%w[users])
    end

    it "leaves an existing column and index as they are under if_not_exists" do
      tables = replay([ <<~RUBY, <<~RUBY2 ])
        class CreateUsers < ActiveRecord::Migration[8.0]
          def change
            create_table :users do |t|
              t.string :email, null: false
              t.string :name
              t.index :email, unique: true
            end
          end
        end
      RUBY
        class AddEmailAgain < ActiveRecord::Migration[8.0]
          def change
            add_index :users, :email, unique: true, if_not_exists: true
            add_column :users, :email, :text, if_not_exists: true
            add_column :users, :phone, :string, if_not_exists: true
          end
        end
      RUBY2

      users = tables["users"]
      expect(users[:columns].map { |c| [ c[:name], c[:type], c[:null] ] })
        .to eq([ [ "id", "bigint", false ], [ "email", "string", false ], [ "name", "string", nil ], [ "phone", "string", nil ] ])
      expect(users[:indexes].map { |i| [ i[:name], i[:unique] ] }).to eq([ [ "index_users_on_email", true ] ])
    end

    # PostgreSQL and MySQL skip an existing key, check and reference column (schema_statements.rb, 7.1 to 8.1);
    # SQLite's add_foreign_key and add_check_constraint rebuild the table and ignore the option.
    it "skips a foreign key, check constraint and reference that exist under if_not_exists" do
      migration = <<~RUBY
        create_table :users
        create_table :posts do |t|
          t.integer :user_id
          t.integer :score
        end
        add_foreign_key :posts, :users
        add_check_constraint :posts, "score > 0"
        add_foreign_key :posts, :users, if_not_exists: true
        add_check_constraint :posts, "score > 0", if_not_exists: true
        add_reference :posts, :user, foreign_key: true, if_not_exists: true
      RUBY

      posts = replay([ migration ], adapter: "postgresql")["posts"]
      expect(posts[:columns].map { |c| [ c[:name], c[:type] ] }).to eq([ %w[id bigint], %w[user_id integer], %w[score integer] ])
      expect(posts[:indexes].map { |i| i[:name] }).to eq(%w[index_posts_on_user_id])
      expect(posts[:foreign_keys].size).to eq(1)
      expect(posts[:check_constraints].size).to eq(1)

      sqlite = replay([ migration ], adapter: "sqlite3")["posts"]
      expect([ sqlite[:foreign_keys].size, sqlite[:check_constraints].size ]).to eq([ 3, 2 ])
    end

    # Rails 7.0's add_foreign_key checks foreign_key_exists?(from, to); 7.1 and 8.0 also compare a given column.
    it "skips a foreign key to a table that already has one under if_not_exists on Rails 7.0, and compares the column from 7.1" do
      allow(RailsAiContext).to receive(:static_tier?).and_return(true)
      key_columns = lambda do |rails|
        Dir.mktmpdir do |dir|
          File.write(File.join(dir, "Gemfile.lock"), "GEM\n  remote: https://rubygems.org/\n  specs:\n    rails (#{rails})\n\nDEPENDENCIES\n  rails\n")
          File.write(File.join(dir, "20240101000000_create.rb"), <<~RUBY)
            create_table :users
            create_table :posts do |t|
              t.integer :user_id
              t.integer :editor_id
            end
            add_foreign_key :posts, :users
            add_foreign_key :posts, :users, column: :editor_id, if_not_exists: true
          RUBY
          described_class.tables(dir, pk_type: "bigint", adapter: "postgresql", root: dir)["posts"][:foreign_keys].map { |fk| fk[:column] }
        end
      end

      expect(key_columns.("7.0.10")).to eq(%w[user_id])
      expect(key_columns.("7.1.6")).to eq(%w[user_id editor_id])
    end

    # 8.1's add_foreign_key fills the default column before the check and compares it with
    # primary_key; 7.1 to 8.0 compare only a column the call gives.
    it "compares the default column and primary key of a foreign key under if_not_exists from Rails 8.1" do
      allow(RailsAiContext).to receive(:static_tier?).and_return(true)
      keys = lambda do |rails|
        Dir.mktmpdir do |dir|
          File.write(File.join(dir, "Gemfile.lock"), "GEM\n  remote: https://rubygems.org/\n  specs:\n    rails (#{rails})\n\nDEPENDENCIES\n  rails\n") if rails
          File.write(File.join(dir, "20240101000000_create.rb"), <<~RUBY)
            create_table :users
            create_table :posts do |t|
              t.integer :user_id
              t.integer :editor_id
            end
            add_foreign_key :posts, :users, column: :editor_id
            add_foreign_key :posts, :users, if_not_exists: true
            create_table :comments do |t|
              t.integer :user_id
            end
            add_foreign_key :comments, :users
            add_reference :comments, :user, foreign_key: { primary_key: :uuid }, if_not_exists: true
          RUBY
          tables = described_class.tables(dir, pk_type: "bigint", adapter: "postgresql", root: dir)
          %w[posts comments].map { |t| tables[t][:foreign_keys].map { |fk| [ fk[:column], fk[:primary_key] ] } }
        end
      end

      expect(keys.("8.0.5")).to eq([ [ %w[editor_id id] ], [ %w[user_id id] ] ])
      newest = [ [ %w[editor_id id], %w[user_id id] ], [ %w[user_id id], %w[user_id uuid] ] ]
      expect(keys.("8.1.4")).to eq(newest)
      expect(keys.(nil)).to eq(newest)
    end

    # Rails 7.1+ fills name ||= chk_rails_<hash of table and expression> and compares names only;
    # chk_rails_bb777d5bd8 is the name Rails derives for posts "score > 1".
    it "finds an existing check constraint by its given or derived name under if_not_exists" do
      migration = <<~RUBY
        create_table :posts do |t|
          t.integer :score
        end
        add_check_constraint :posts, "score > 0", name: "positive"
        add_check_constraint :posts, "score > 1"
        add_check_constraint :posts, "score > 0", if_not_exists: true
        add_check_constraint :posts, "score > 1", name: "chk_rails_e2f4e0d1aa", if_not_exists: true
        add_check_constraint :posts, "score > 2", name: "chk_rails_bb777d5bd8", if_not_exists: true
      RUBY

      posts = replay([ migration ], adapter: "postgresql")["posts"]
      expect(posts[:check_constraints]).to eq([
        { name: "positive", expression: "score > 0" },
        { expression: "score > 1" },
        { expression: "score > 0" },
        { name: "chk_rails_e2f4e0d1aa", expression: "score > 1" }
      ])
    end
  end

  # The migration's own Rails version decides a reference's index
  # (migration/compatibility.rb, 8.1): V6_0 and earlier give a polymorphic
  # pair the default name, V4_2 and earlier add no index by default.
  describe "a reference in a versioned migration" do
    def comments_after(version)
      superclass = version ? "ActiveRecord::Migration[#{version}]" : "ActiveRecord::Migration"
      replay([ <<~RUBY ])["comments"]
        class CreateComments < #{superclass}
          def change
            create_table :comments do |t|
              t.references :commentable, polymorphic: true
              t.references :user
            end
          end
        end
      RUBY
    end

    def names(table) = table[:indexes].map { |i| i[:name] }

    it "names a polymorphic index for its pair in a 6.0 migration" do
      expect(names(comments_after("6.0"))).to include("index_comments_on_commentable_type_and_commentable_id")
    end

    it "names it for the reference from 6.1 on" do
      expect(names(comments_after("6.1"))).to include("index_comments_on_commentable")
      expect(names(comments_after("8.1"))).to include("index_comments_on_commentable")
    end

    it "reads a migration with no version as current" do
      expect(names(comments_after(nil))).to include("index_comments_on_commentable")
    end

    it "adds no index by default in a 4.2 migration" do
      expect(comments_after("4.2")[:indexes]).to be_empty
    end

    it "still indexes a 4.2 reference that asks for one" do
      table = replay([ <<~RUBY ])["posts"]
        class CreatePosts < ActiveRecord::Migration[4.2]
          def change
            create_table :posts do |t|
              t.references :user, index: true
            end
          end
        end
      RUBY

      expect(names(table)).to eq([ "index_posts_on_user_id" ])
    end

    it "names an add_reference in a 6.0 migration the old way too" do
      table = replay([
        "create_table :comments do |t|\n  t.string :body\nend\n",
        <<~RUBY
          class AddOwner < ActiveRecord::Migration[6.0]
            def change
              add_reference :comments, :owner, polymorphic: true
            end
          end
        RUBY
      ])["comments"]

      expect(names(table)).to eq([ "index_comments_on_owner_type_and_owner_id" ])
    end
  end
  # ReferenceDefinition takes the id column's type from type: (7.0 and 8.1).
  describe "a reference with an explicit type" do
    it "gives the id column that type, not the primary key's" do
      table = replay([ <<~RUBY ], pk_type: "bigint")["comments"]
        create_table :comments do |t|
          t.references :user, type: :uuid
          t.references :external, type: :string, polymorphic: true
          t.references :post
        end
      RUBY

      types = table[:columns].to_h { |c| [ c[:name], c[:type] ] }
      expect(types).to include("user_id" => "uuid", "external_id" => "string", "external_type" => "string", "post_id" => "bigint")
    end

    it "applies to add_reference too" do
      table = replay([
        "create_table :comments do |t|\n  t.string :body\nend\n",
        "add_reference :comments, :account, type: :uuid\n"
      ])["comments"]

      expect(table[:columns].find { |c| c[:name] == "account_id" }[:type]).to eq("uuid")
    end
  end
  # An app can add top_topics columns in a loop, `add_column :top_topics,
  # column, :integer`: the replay recorded a column named nil, which any
  # reader calling a String method on the name trips over.
  describe "a column whose name the replay cannot read" do
    let(:result) do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "db/migrate"))
        File.write(File.join(dir, "db/migrate/1_create.rb"), "create_table :top_topics do |t|\n  t.integer :topic_id\nend\n")
        File.write(File.join(dir, "db/migrate/2_add.rb"), <<~RUBY)
          %i[daily weekly].each do |period|
            column = "\#{period}_posts_count"
            add_column :top_topics, column, :integer, default: 0
          end
          add_column :top_topics, :all_score, :float
        RUBY
        return described_class.replayed(File.join(dir, "db/migrate"), pk_type: "bigint", root: dir)
      end
    end

    it "is left out rather than recorded with no name" do
      names = result.tables["top_topics"][:columns].map { |c| c[:name] }

      expect(names).to eq(%w[id topic_id all_score])
    end

    it "is counted" do
      expect(result.counts.unnamed_columns).to eq(1)
    end
  end
  # A private API app drops two references with remove_reference, which the
  # replay skipped, so both columns and their indexes outlived the migration
  # that dropped them.
  describe "remove_reference" do
    let(:table) do
      replay([
        <<~RUBY,
          create_table :store_accounts do |t|
            t.references :product, type: :uuid
            t.references :site, type: :uuid
            t.references :owner, polymorphic: true
            t.index %w[product_id site_id], name: "index_store_accounts_product_site_uniqueness", unique: true
          end
        RUBY
        <<~RUBY
          remove_reference :store_accounts, :product, index: true, type: :uuid
          remove_belongs_to :store_accounts, :owner, polymorphic: true
        RUBY
      ])["store_accounts"]
    end

    it "drops the reference's column, and the type column when polymorphic" do
      expect(table[:columns].map { |c| c[:name] }).to eq(%w[id site_id])
    end

    # The database drops an index when a column in it is dropped (PostgreSQL
    # drops the whole index; SQLite's table rebuild keeps only indexes whose
    # columns all survive).
    it "drops every index that held a removed column" do
      expect(table[:indexes].map { |i| i[:name] }).to eq(%w[index_store_accounts_on_site_id])
    end
  end

  describe "remove_column" do
    it "drops the indexes that held the column" do
      table = replay([
        "create_table :posts do |t|\n  t.string :slug\n  t.string :title\n  t.index :slug\n  t.index %i[title slug]\n  t.index :title\nend\n",
        "remove_column :posts, :slug\n"
      ])["posts"]

      expect(table[:indexes].map { |i| i[:name] }).to eq(%w[index_posts_on_title])
    end
  end
  # remove_index finds its index the way index_name_for_remove does (7.0 and
  # 8.1): by name, by the exact column list, or both. The replay kept every
  # removed index, 84 of them on one private app alone.
  describe "remove_index" do
    def after(*removals)
      replay([
        <<~RUBY,
          create_table :posts do |t|
            t.string :slug
            t.string :title
            t.index :slug
            t.index %i[title slug], name: "by_title_slug"
            t.index :title, name: "by_title"
          end
        RUBY
        *removals
      ])["posts"][:indexes].map { |i| i[:name] }
    end

    it "removes by column" do
      expect(after("remove_index :posts, :slug\n")).to eq(%w[by_title_slug by_title])
    end

    it "removes by column: option" do
      expect(after("remove_index :posts, column: %i[title slug]\n")).to eq(%w[index_posts_on_slug by_title])
    end

    it "removes by name" do
      expect(after("remove_index :posts, name: \"by_title\"\n")).to eq(%w[index_posts_on_slug by_title_slug])
    end

    # Rails raises rather than guess when no single index matches.
    it "removes nothing when no index matches" do
      expect(after("remove_index :posts, :body, if_exists: true\n")).to eq(%w[index_posts_on_slug by_title_slug by_title])
    end

    it "honours the column order" do
      expect(after("remove_index :posts, column: %i[slug title]\n")).to eq(%w[index_posts_on_slug by_title_slug by_title])
    end
  end
  # remove_foreign_key finds its key the way foreign_key_for does (8.1): by
  # to_table, by column:, preferring the default column when none is given.
  describe "remove_foreign_key" do
    def after(removal)
      replay([
        <<~RUBY,
          create_table :posts do |t|
            t.bigint :user_id
            t.bigint :editor_id
          end
          add_foreign_key :posts, :users
          add_foreign_key :posts, :users, column: :editor_id
        RUBY
        removal
      ])["posts"][:foreign_keys].map { |fk| fk[:column] }
    end

    it "removes the key to a table, the default column first" do
      expect(after("remove_foreign_key :posts, :users\n")).to eq(%w[editor_id])
    end

    it "removes by column" do
      expect(after("remove_foreign_key :posts, column: :editor_id\n")).to eq(%w[user_id])
    end

    it "removes nothing when no key matches" do
      expect(after("remove_foreign_key :posts, :accounts, if_exists: true\n")).to eq(%w[user_id editor_id])
    end

    # Dropping the column drops the constraint on it.
    it "goes with a removed column" do
      expect(after("remove_column :posts, :editor_id\n")).to eq(%w[user_id])
    end
  end
  # change_table's block was read as if it belonged to the last create_table
  # in the file: t.string :body landed on the wrong table, and t.remove was
  # not read at all.
  describe "change_table" do
    let(:tables) do
      replay([
        <<~RUBY,
          create_table :posts do |t|
            t.string :title
            t.string :slug
            t.string :legacy
            t.references :author, polymorphic: true
            t.references :user
            t.index :slug
            t.timestamps
          end
        RUBY
        <<~RUBY
          create_table :tags do |t|
            t.string :name
          end
          change_table :posts do |t|
            t.string :body
            t.remove :legacy
            t.remove_references :author, polymorphic: true
            t.remove_belongs_to :user
            t.remove_index :slug
            t.rename :title, :heading
            t.remove_timestamps
          end
        RUBY
      ])
    end

    def columns(table) = tables[table][:columns].map { |c| c[:name] }

    it "applies the block to the table it names" do
      expect(columns("posts")).to include("body")
      expect(columns("tags")).to eq(%w[id name])
    end

    it "reads the removals, the rename and remove_timestamps" do
      expect(columns("posts")).to eq(%w[id heading slug body])
    end

    it "drops the removed index and the removed references' indexes" do
      expect(tables["posts"][:indexes]).to be_empty
    end

    it "gives t.timestamps inside change_table to that table" do
      changed = replay([
        "create_table :posts do |t|\n  t.string :title\nend\n",
        "create_table :tags do |t|\n  t.string :name\nend\nchange_table :posts do |t|\n  t.timestamps\nend\n"
      ])

      expect(changed["posts"][:columns].map { |c| c[:name] }).to include("created_at", "updated_at")
      expect(changed["tags"][:columns].map { |c| c[:name] }).to eq(%w[id name])
    end
  end

  describe "remove_columns" do
    it "drops each column it names" do
      table = replay([
        "create_table :posts do |t|\n  t.string :a\n  t.string :b\n  t.string :c\nend\n",
        "remove_columns :posts, :a, :b\n"
      ])["posts"]

      expect(table[:columns].map { |c| c[:name] }).to eq(%w[id c])
    end
  end
  # A helper in a module the migration includes is replayed as the schema
  # statement it forwards to, when its whole body is that one statement.
  # Anything else (a change_column_type_concurrently that adds a temp
  # column, copies rows, swaps names) is counted, not guessed.
  describe "a helper from a module the migration includes" do
    let(:result) do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "lib/acme"))
        File.write(File.join(dir, "lib/acme/migration_helpers.rb"), <<~RUBY)
          module Acme
            module MigrationHelpers
              def add_flag(table, name, default: false)
                add_column table, name, :boolean, default: default, null: false
              end

              def change_type_slowly(table, column, new_type)
                temp = "\#{column}_tmp"
                add_column table, temp, new_type
                remove_column table, column
                rename_column table, temp, column
              end
            end
          end
        RUBY
        FileUtils.mkdir_p(File.join(dir, "db/migrate"))
        File.write(File.join(dir, "db/migrate/1_create.rb"), "create_table :posts do |t|\n  t.integer :views\nend\n")
        File.write(File.join(dir, "db/migrate/2_helpers.rb"), <<~RUBY)
          class UseHelpers < ActiveRecord::Migration[7.1]
            include Acme::MigrationHelpers

            def up
              add_flag :posts, :pinned, default: true
              change_type_slowly :posts, :views, :bigint
            end
          end
        RUBY
        return described_class.replayed(File.join(dir, "db/migrate"), pk_type: "bigint", root: dir)
      end
    end

    let(:posts) { result.tables["posts"][:columns] }

    it "replays a helper that forwards to one statement as that statement" do
      expect(posts.find { |c| c[:name] == "pinned" }).to include(type: "boolean", null: false, default: "true")
    end

    it "leaves a helper that does more, and counts the call" do
      expect(posts.find { |c| c[:name] == "views" }[:type]).to eq("integer")
      expect(result.counts.helper_calls).to eq(1)
    end
  end
  # A migration's private methods run where up or change calls them, not in
  # source order: an add_index_to_table / remove_index_from_table pair
  # read as add-then-remove once remove_index was modelled, and five unique
  # indexes the migration does create went missing.
  describe "a migration's own private methods" do
    def posts_indexes(body)
      replay([
        "create_table :posts do |t|\n  t.bigint :account_id\n  t.string :uri\nend\n",
        "class AddIdx < ActiveRecord::Migration[7.0]\n#{body}\nend\n"
      ])["posts"][:indexes].map { |i| i[:name] }
    end

    it "replays a method where up calls it and skips one only down reaches" do
      names = posts_indexes(<<~RUBY)
        def up
          add_index_to_table
        rescue ActiveRecord::RecordNotUnique
          remove_duplicates_and_reindex
        end

        def down
          remove_index_from_table
        end

        private

        def remove_duplicates_and_reindex
          remove_index_from_table
          add_index_to_table
        end

        def add_index_to_table
          add_index :posts, %i[account_id uri], unique: true
        end

        def remove_index_from_table
          remove_index :posts, %i[account_id uri]
        end
      RUBY

      expect(names).to eq(%w[index_posts_on_account_id_and_uri])
    end

    # up drops then re-adds; the methods sit in the file the other way
    # round, so source order would end with the index gone.
    it "replays calls in the order up makes them, nested ones included" do
      names = posts_indexes(<<~RUBY)
        def up
          drop_it
          rebuild
        end

        private

        def add_it
          add_index :posts, :uri
        end

        def rebuild
          add_it
        end

        def drop_it
          remove_index :posts, :uri
        end
      RUBY

      expect(names).to eq(%w[index_posts_on_uri])
    end

    it "leaves a file with no up or change replayed in source order" do
      expect(posts_indexes("def helper\n  add_index :posts, :uri\nend\n")).to eq(%w[index_posts_on_uri])
    end
  end
  # Many large apps keep post-deployment migrations in
  # db/post_migrate; the app adds the path, and Rails runs every path's files
  # in one version order.
  describe ".migration_dirs" do
    it "reads db/post_migrate beside db/migrate, in one version order" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "db/migrate"))
        FileUtils.mkdir_p(File.join(dir, "db/post_migrate"))
        File.write(File.join(dir, "db/migrate/1_create.rb"), "create_table :users do |t|\n  t.inet :current_sign_in_ip\nend\n")
        File.write(File.join(dir, "db/post_migrate/2_drop.rb"), "remove_column :users, :current_sign_in_ip\n")
        File.write(File.join(dir, "db/migrate/3_add.rb"), "add_column :users, :name, :string\n")

        tables = described_class.tables(described_class.migration_dirs(dir), pk_type: "bigint", root: dir)

        expect(tables["users"][:columns].map { |c| c[:name] }).to eq(%w[id name])
      end
    end
  end
  # schema.rb writes an index's using:, order:, opclass: and the rest; the replay keeps them as the dump reader does.
  it "keeps an index's using: and order:, however the migration declares it" do
    tables = Dir.mktmpdir do |dir|
      File.write(File.join(dir, "20240101000000_c.rb"), <<~RUBY)
        create_table :assignments do |t|
          t.bigint :score
          t.index :score, using: :hash
          t.references :cloned_item, index: { where: "cloned_item_id IS NOT NULL", order: :desc }
        end
        add_index :assignments, :score, using: :gin, opclass: :jsonb_path_ops, name: "idx_gin"
      RUBY
      described_class.tables(dir, pk_type: "bigint")
    end

    expect(tables["assignments"][:indexes]).to eq([
      { name: "index_assignments_on_score", columns: [ "score" ], unique: false, using: "hash" },
      { name: "index_assignments_on_cloned_item_id", columns: [ "cloned_item_id" ], unique: false,
        where: "cloned_item_id IS NOT NULL", order: { "cloned_item_id" => "desc" } },
      { name: "idx_gin", columns: [ "score" ], unique: false, using: "gin", opclass: { "score" => "jsonb_path_ops" } }
    ])
  end

  # A declared size reads as the dump writes it: an integer limit picks smallint or bigint on PostgreSQL
  # and MySQL, a string's 255 is MySQL's default, a datetime's 6 is the default, and MySQL sizes text by limit.
  describe "declared sizes" do
    def sizes(adapter, rails: nil)
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "Gemfile.lock"), "GEM\n  remote: https://rubygems.org/\n  specs:\n    rails (#{rails})\n\nDEPENDENCIES\n  rails\n") if rails
        File.write(File.join(dir, "20240101000000_create.rb"), <<~RUBY)
          create_table :widgets do |t|
            t.integer :tiny, limit: 1
            t.integer :small, limit: 2
            t.integer :normal, limit: 4
            t.integer :big, limit: 8
            t.string :code, limit: 2
            t.string :name, limit: 255
            t.datetime :seen_at, precision: 6
            t.datetime :at3, precision: 3
            t.time :t2, precision: 2
            t.decimal :price, precision: 10, scale: 2
            t.text :body, limit: 16777215
            t.binary :blob, limit: 1024
            t.float :ratio
            t.float :single, limit: 24
            t.float :double, limit: 53
          end
          add_column :widgets, :later, :integer, limit: 8
          change_column :widgets, :normal, :integer, limit: 8
        RUBY
        described_class.tables(dir, pk_type: "bigint", adapter: adapter, root: dir)["widgets"][:columns]
          .drop(1).to_h { |c| [ c[:name], [ c[:type], c.slice(:limit, :precision, :scale, :size) ] ] }
      end
    end

    # A real keeps limit 24 only from Rails 7.2.2, so the dump is read as an 8.1 app's.
    it "matches what the PostgreSQL dump writes" do
      allow(RailsAiContext).to receive(:static_tier?).and_return(true)
      expect(sizes("postgresql", rails: "8.1.0")).to eq(
        "tiny" => [ "integer", { limit: 2 } ], "small" => [ "integer", { limit: 2 } ], "normal" => [ "bigint", {} ],
        "big" => [ "bigint", {} ], "code" => [ "string", { limit: 2 } ], "name" => [ "string", { limit: 255 } ],
        "seen_at" => [ "datetime", {} ], "at3" => [ "datetime", { precision: 3 } ], "t2" => [ "time", { precision: 2 } ],
        "price" => [ "decimal", { precision: 10, scale: 2 } ], "body" => [ "text", {} ], "blob" => [ "binary", {} ],
        "ratio" => [ "float", {} ], "single" => [ "float", { limit: 24 } ], "double" => [ "float", {} ],
        "later" => [ "bigint", {} ]
      )
    end

    it "matches what the MySQL dump writes" do
      expect(sizes("mysql2")).to eq(
        "tiny" => [ "integer", { limit: 1 } ], "small" => [ "integer", { limit: 2 } ], "normal" => [ "bigint", {} ],
        "big" => [ "bigint", {} ], "code" => [ "string", { limit: 2 } ], "name" => [ "string", {} ],
        "seen_at" => [ "datetime", {} ], "at3" => [ "datetime", { precision: 3 } ], "t2" => [ "time", { precision: 2 } ],
        "price" => [ "decimal", { precision: 10, scale: 2 } ], "body" => [ "text", { size: "medium" } ],
        "blob" => [ "binary", { limit: 1024 } ], "ratio" => [ "float", {} ], "single" => [ "float", {} ],
        "double" => [ "float", { limit: 53 } ], "later" => [ "bigint", {} ]
      )
    end

    it "keeps an integer's declared limit on SQLite" do
      expect(sizes("sqlite3").values_at("tiny", "big", "later")).to eq([ [ "integer", { limit: 1 } ], [ "integer", { limit: 8 } ], [ "integer", { limit: 8 } ] ])
    end

    # Rails reads a real as limit 24 from 7.2.2; before it a real dumps as the bare float, on an adapter with no family too.
    it "gives a PostgreSQL real no limit before Rails 7.2.2" do
      allow(RailsAiContext).to receive(:static_tier?).and_return(true)
      expect(sizes("postgresql", rails: "7.2.1").values_at("single", "double")).to eq([ [ "float", {} ], [ "float", {} ] ])
      expect(sizes("postgresql", rails: "7.2.2").fetch("single")).to eq([ "float", { limit: 24 } ])
      expect(sizes("sqlserver", rails: "7.2.1").fetch("single")).to eq([ "float", {} ])
    end

    it "keeps a float's declared limit on SQLite" do
      expect(sizes("sqlite3").values_at("ratio", "single", "double")).to eq([ [ "float", {} ], [ "float", { limit: 24 } ], [ "float", { limit: 53 } ] ])
    end
  end

  # Rails passes a type name its adapter does not list to the server as written, and the dump names
  # the column the way the adapter reads it back. Expected values are each server's live dump.
  describe "native type names" do
    def native(adapter, types, sql: nil)
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "Gemfile.lock"), "GEM\n  remote: https://rubygems.org/\n  specs:\n    rails (8.1.0)\n\nDEPENDENCIES\n  rails\n")
        columns = types.each_with_index.map { |type, i| "    t.column :c#{i}, #{type.inspect}" }.join("\n")
        File.write(File.join(dir, "20240101000000_create.rb"), <<~RUBY)
          create_table :widgets do |t|
          #{columns}
          end
          add_column :widgets, :added, #{types.first.inspect}
          #{"execute #{sql.inspect}" if sql}
        RUBY
        described_class.tables(dir, pk_type: "bigint", adapter: adapter, root: dir).transform_values do |table|
          table[:columns].reject { |c| c[:primary_key] }.map { |c| [ c[:type], c.slice(:limit, :precision, :scale, :size) ] }
        end
      end
    end

    it "reads PostgreSQL's spellings the way its type map does" do
      allow(RailsAiContext).to receive(:static_tier?).and_return(true)
      types = [ "real", "float4", "float(10)", "float8", "double precision", "float(30)", "int4", "int8", "int2", "smallint",
                "varchar", "character varying", "varchar(40)", "bool", "bytea", "timestamptz", "timestamp" ]
      expect(native("postgresql", types)["widgets"]).to eq(
        [ [ "float", { limit: 24 } ] ] * 3 + [ [ "float", {} ] ] * 3 +
        [ [ "integer", {} ], [ "bigint", {} ], [ "integer", { limit: 2 } ], [ "integer", { limit: 2 } ],
          [ "string", {} ], [ "string", {} ], [ "string", { limit: 40 } ], [ "boolean", {} ], [ "binary", {} ], [ "timestamptz", {} ],
          [ "datetime", {} ], [ "float", { limit: 24 } ] ]
      )
    end

    it "reads MySQL's spellings the way its type map does, in a table an execute creates too" do
      types = [ "double", "double precision", "real", "float8", "float(30)", "float", "float4", "float(10)", "int4", "int8", "int2",
                "mediumint", "tinyint", "tinyint(1)", "bool", "character varying(40)" ]
      tables = native("trilogy", types, sql: "CREATE TABLE gauges (d double, r real, f float(30), s float)")
      expect(tables["widgets"]).to eq(
        [ [ "float", { limit: 53 } ] ] * 5 + [ [ "float", {} ] ] * 3 +
        [ [ "integer", {} ], [ "bigint", {} ], [ "integer", { limit: 2 } ], [ "integer", { limit: 3 } ], [ "integer", { limit: 1 } ],
          [ "boolean", {} ], [ "boolean", {} ], [ "string", { limit: 40 } ], [ "float", { limit: 53 } ] ]
      )
      expect(tables["gauges"]).to eq([ [ "float", { limit: 53 } ] ] * 3 + [ [ "float", {} ] ])
    end

    it "reads a bare MySQL bit as the bit(1) MySQL makes it" do
      expect(native("trilogy", [ "bit", "bit(8)" ])["widgets"]).to eq([ [ "binary", { limit: 1 } ], [ "binary", { limit: 8 } ], [ "binary", { limit: 1 } ] ])
    end

    # A serial is an integer of its size with a sequence: the dump names it serial, or bigserial for a
    # bigint, gives it null: false, and writes a bigserial key as the default key (postgresql/schema_dumper.rb).
    it "reads PostgreSQL's serials the way its dump writes them, as a key and as a column" do
      tables = replay([ <<~RUBY ], adapter: "postgresql")
        execute "CREATE TABLE big_keys (id bigserial primary key, body text)"
        execute "CREATE TABLE int_keys (id serial primary key, n serial, s smallserial, b bigserial)"
        execute "CREATE TABLE small_keys (id smallserial primary key)"
        execute "CREATE TABLE late_keys (id bigserial, PRIMARY KEY (id))"
        execute "CREATE TABLE shared (id bigint PRIMARY KEY DEFAULT nextval('shared_seq'), n integer DEFAULT nextval('shared_seq'))"
        execute "CREATE TABLE odd (id bigint PRIMARY KEY, n integer DEFAULT nextval('odd_n_seq'))"
        create_table :declared_big, id: :bigserial
        create_table :declared_small, id: :smallserial
        create_table :counters do |t|
          t.column :n, :smallserial
          t.serial :m
          t.bigserial :q
        end
      RUBY
      shape = ->(name) { tables[name][:columns].to_h { |c| [ c[:name], [ c[:type], c.slice(:limit, :null) ] ] } }
      expect([ shape.("big_keys")["id"], shape.("late_keys")["id"] ]).to eq([ [ "bigint", { null: false } ] ] * 2)
      expect(shape.("int_keys")).to eq(
        "id" => [ "serial", { null: false } ], "n" => [ "serial", { null: false } ], "s" => [ "serial", { limit: 2, null: false } ],
        "b" => [ "bigserial", { null: false } ]
      )
      expect(shape.("small_keys")).to eq("id" => [ "serial", { limit: 2, null: false } ])
      expect(shape.("declared_big")).to eq("id" => [ "bigint", { null: false } ])
      expect(shape.("declared_small")).to eq("id" => [ "serial", { limit: 2, null: false } ])
      nextval = %q(-> { "nextval('shared_seq'::regclass)" })
      expect(tables["shared"][:columns].map { |c| c.values_at(:type, :default) }).to eq([ [ "bigint", nextval ], [ "integer", nextval ] ])
      expect(shape.("odd")["n"]).to eq([ "serial", { null: true } ])
      expect(shape.("counters").except("id")).to eq(
        "n" => [ "serial", { limit: 2, null: false } ], "m" => [ "serial", { null: false } ], "q" => [ "bigserial", { null: false } ]
      )
    end

    # An adapter with no family reads with PostgreSQL's rules, as the structure.sql reader reads an unmarked dump;
    # each expected value is PostgreSQL's live dump of the same column.
    it "reads every type of an adapter with no family the way PostgreSQL does" do
      allow(RailsAiContext).to receive(:static_tier?).and_return(true)
      types = [ "real", "float(10)", "smallint", "varchar(40)" ]
      tables = native("sqlserver", types)
      sized = replay([ <<~RUBY ], adapter: "sqlserver")
        create_table :widgets do |t|
          t.float :ratio, limit: 10
          t.integer :tiny, limit: 1
          t.text :body, limit: 100
          t.binary :blob, limit: 100
        end
      RUBY

      expect(tables["widgets"]).to eq([ [ "float", { limit: 24 } ] ] * 2 + [ [ "integer", { limit: 2 } ], [ "string", { limit: 40 } ], [ "float", { limit: 24 } ] ])
      expect(sized["widgets"][:columns].drop(1).map { |c| c.slice(:type, :limit) }).to eq(
        [ { type: "float", limit: 24 }, { type: "integer", limit: 2 }, { type: "text" }, { type: "binary" } ]
      )
    end

    it "leaves a type it cannot read unnamed" do
      tables = replay([ "create_table :widgets\nadd_column :widgets, :kind, computed_type\n" ], adapter: "postgresql")

      expect(tables["widgets"][:columns].last).to eq(name: "kind", type: nil)
    end

    it "keeps a time type's precision the way each dump writes it" do
      expect(native("postgresql", [ "timestamptz(3)", "timestamptz(6)", "timestamp(0)", "time(0)" ])["widgets"]).to eq(
        [ [ "timestamptz", { precision: 3 } ], [ "timestamptz", { precision: 6 } ], [ "datetime", { precision: 0 } ], [ "time", { precision: 0 } ],
          [ "timestamptz", { precision: 3 } ] ]
      )
      expect(native("sqlite3", [ "timestamptz(3)", "time(0)" ])["widgets"]).to eq(
        [ [ "datetime", { precision: 3 } ], [ "time", { precision: 0 } ], [ "datetime", { precision: 3 } ] ]
      )
      mysql = replay([ "create_table :widgets do |t|\n  t.time :e, precision: 0\n  t.timestamp :i, precision: 0\nend\n" ], adapter: "trilogy")
      expect(mysql["widgets"][:columns].drop(1).map { |c| c.slice(:type, :precision) }).to eq([ { type: "time" }, { type: "timestamp" } ])
    end

    it "keeps a MySQL timestamp's precision the way its dump writes it" do
      tables = native("trilogy", [ "timestamp(3)", "timestamp(6)", "timestamp" ], sql: "CREATE TABLE stamps (at timestamp(3) NULL)")

      expect(tables["widgets"]).to eq([ [ "timestamp", { precision: 3 } ], [ "timestamp", {} ], [ "timestamp", {} ], [ "timestamp", { precision: 3 } ] ])
      expect(tables["stamps"]).to eq([ [ "timestamp", { precision: 3 } ] ])
    end

    # change_column keeps the sequence default, so the integer it makes is still a serial (serial? reads the default).
    it "keeps a PostgreSQL serial a serial of its new size through change_column" do
      tables = replay([ <<~RUBY ], adapter: "postgresql")
        create_table :counters do |t|
          t.serial :n
          t.bigserial :m
        end
        change_column :counters, :n, :bigint
        change_column :counters, :m, :integer
      RUBY

      expect(tables["counters"][:columns].drop(1).map { |c| c.slice(:type, :null) }).to eq([ { type: "bigserial", null: false }, { type: "serial", null: false } ])
    end

    # PostgreSQL copies each parent's columns, with their defaults, into an INHERITS child and keeps no key on it.
    it "gives a child an execute creates with INHERITS its parent's columns, as PostgreSQL's dump writes them" do
      tables = replay([ <<~RUBY ], adapter: "postgresql")
        execute "CREATE TABLE parents (id serial PRIMARY KEY, name varchar NOT NULL)"
        execute "CREATE TABLE children (extra integer, name varchar) INHERITS (parents)"
      RUBY

      expect(tables["children"][:columns]).to eq(
        [ { name: "id", type: "integer", null: false, default: %q(-> { "nextval('parents_id_seq'::regclass)" }) },
          { name: "name", type: "string", null: false }, { name: "extra", type: "integer", null: true } ]
      )
    end

    # PostgreSQL backs an integer or bigint key create_table makes with its own sequence unless a default is given
    # (ColumnMethods#primary_key), and change_column keeps that default, so the dump names the key by serial?.
    it "names a PostgreSQL key create_table makes, and after change_column, as the dump does" do
      tables = replay([ <<~RUBY ], adapter: "postgresql")
        create_table :ints, id: :integer
        create_table :plain_ints, id: :integer, default: nil
        create_table :defaults
        change_column :defaults, :id, :integer
        create_table :bigs, id: :bigint
        change_column :bigs, :id, :integer
        create_table :codes, primary_key: :code
        change_column :codes, :code, :integer
        create_table :strings
        change_column :strings, :id, :string
      RUBY

      expect(tables.transform_values { |t| t[:columns].first[:type] }).to eq(
        "ints" => "serial", "plain_ints" => "integer", "defaults" => "serial", "bigs" => "serial", "codes" => "serial", "strings" => "serial"
      )

      legacy = replay([ "class Legacy < ActiveRecord::Migration[5.0]\n  def change\n    create_table :olds\n    create_table :old_ints, id: :integer\n  end\nend\n" ],
                      pk_type: "integer", adapter: "postgresql")
      expect(legacy.transform_values { |t| t[:columns].first[:type] }).to eq("olds" => "serial", "old_ints" => "integer")
    end

    # change_column keeps a key's own sequence, or its lack of one, and an INHERITS child copies the parent's
    # sequence as its key's default. Expected values are PostgreSQL 16's dump of the same migrations.
    it "follows whether a PostgreSQL key has its own sequence, through change_column and into an INHERITS child" do
      tables = replay([ <<~RUBY ], adapter: "postgresql")
        create_table :no_seqs, id: :bigint, default: nil
        change_column :no_seqs, :id, :integer
        execute "CREATE TABLE raw_keys (id bigint PRIMARY KEY, n integer)"
        change_column :raw_keys, :id, :integer
        execute "CREATE TABLE big_keys (id bigserial PRIMARY KEY)"
        change_column :big_keys, :id, :integer
        create_table :parents
        execute "CREATE TABLE children (x integer) INHERITS (parents)"
        execute "CREATE TABLE big_parents (id bigserial PRIMARY KEY)"
        execute "CREATE TABLE big_children (x integer) INHERITS (big_parents)"
        create_table :serial_parents, id: :serial
        execute "CREATE TABLE serial_children (x integer) INHERITS (serial_parents)"
        create_table :old_parents, id: :serial
        rename_table :old_parents, :new_parents
        execute "CREATE TABLE new_children (x integer) INHERITS (new_parents)"
        create_table :serial_keys, id: :serial
        change_column :serial_keys, :id, :integer
        create_table :small_keys, id: :smallserial
        change_column :small_keys, :id, :integer
      RUBY
      legacy = replay([ "class Legacy < ActiveRecord::Migration[5.0]\n  def change\n    create_table :olds, id: :bigint\n    change_column :olds, :id, :integer\n  end\nend\n" ],
                      adapter: "postgresql")

      expect(%w[no_seqs raw_keys big_keys].map { |name| tables[name][:columns].first[:type] } + [ legacy["olds"][:columns].first[:type] ]).to eq(
        %w[integer integer serial integer]
      )
      expect(%w[serial_keys small_keys].map { |name| tables[name][:columns].first.slice(:type, :limit, :null) }).to eq([ { type: "serial", null: false } ] * 2)
      expect(%w[serial_children new_children].map { |name| tables[name][:columns].first }).to eq(
        %w[serial_parents new_parents].map { |parent| { name: "id", type: "integer", null: false, default: %(-> { "nextval('#{parent}_id_seq'::regclass)" }) } }
      )
      expect(tables["parents"][:columns]).to eq([ { name: "id", type: "bigint", null: false, primary_key: true } ])
      expect(%w[children big_children].map { |name| tables[name][:columns].first }).to eq(
        %w[parents big_parents].map { |parent| { name: "id", type: "bigint", null: false, default: %(-> { "nextval('#{parent}_id_seq'::regclass)" }) } }
      )
    end

    # PostgreSQL names a serial by its sequence: rename_column and a renamed table keep the old sequence, and a new default
    # or a copy drops it, so the dump writes the integer it was made from. Expected values are PostgreSQL 16 dumps.
    it "reads a PostgreSQL serial whose sequence no longer follows its name as the integer the dump writes" do
      tables = replay([ <<~RUBY ], adapter: "postgresql")
        create_table :renamed do |t|
          t.serial :n
          t.column :s, :smallserial
          t.bigserial :b
        end
        rename_column :renamed, :n, :m
        rename_column :renamed, :s, :s2
        rename_column :renamed, :b, :b2
        execute "CREATE TABLE renamed_children (x integer) INHERITS (renamed)"
        change_column :renamed, :m, :bigint
        create_table :keys
        rename_column :keys, :id, :uid
        create_table :defaulted do |t|
          t.serial :n
          t.column :s, :smallserial
          t.bigserial :b
        end
        change_column_default :defaulted, :n, 5
        change_column_default :defaulted, :s, from: nil, to: 3
        change_column_default :defaulted, :b, nil
        create_table :moved do |t|
          t.serial :n
        end
        rename_table :moved, :moves
        create_table :sources do |t|
          t.serial :n
          t.bigserial :b
        end
        create_table :copies, id: false, as: "SELECT id, n, b FROM sources"
      RUBY
      nextval = ->(sequence) { %(-> { "nextval('#{sequence}'::regclass)" }) }
      shape = ->(name) { tables[name][:columns].to_h { |c| [ c[:name], c.slice(:type, :limit, :null, :default) ] } }

      expect(shape.("renamed").except("id")).to eq(
        "m" => { type: "bigint", null: false, default: nextval.("renamed_n_seq") },
        "s2" => { type: "integer", limit: 2, null: false, default: nextval.("renamed_s_seq") },
        "b2" => { type: "bigint", null: false, default: nextval.("renamed_b_seq") }
      )
      expect(shape.("renamed_children")["m"]).to eq(type: "bigint", null: false, default: nextval.("renamed_n_seq"))
      expect(shape.("keys")).to eq("uid" => { type: "bigint", null: false, default: nextval.("keys_id_seq") })
      expect(shape.("defaulted").except("id")).to eq(
        "n" => { type: "integer", null: false, default: "5" }, "s" => { type: "integer", limit: 2, null: false, default: "3" },
        "b" => { type: "bigint", null: false }
      )
      expect(shape.("moves")).to eq("id" => { type: "bigint", null: false }, "n" => { type: "integer", null: false, default: nextval.("moved_n_seq") })
      expect(shape.("copies")).to eq("id" => { type: "bigint" }, "n" => { type: "integer" }, "b" => { type: "bigint" })
    end

    # The dump decides serial? by name (PostgreSQL::Column#serial?), so a column or table renamed back to the names its
    # sequence was made from is a serial again. Expected values are PostgreSQL 16 dumps.
    it "reads a PostgreSQL serial renamed away and back as the serial the dump writes" do
      tables = replay([ <<~RUBY ], adapter: "postgresql")
        create_table :columns_back do |t|
          t.serial :n
        end
        rename_column :columns_back, :n, :m
        rename_column :columns_back, :m, :n
        create_table :tables_back do |t|
          t.serial :n
        end
        rename_table :tables_back, :tables_away
        rename_table :tables_away, :tables_back
        create_table :keys_back
        rename_column :keys_back, :id, :uid
        rename_table :keys_back, :keys_away
        rename_table :keys_away, :keys_back
        rename_column :keys_back, :uid, :id
        create_table :resized_back do |t|
          t.serial :n
        end
        rename_column :resized_back, :n, :m
        change_column :resized_back, :m, :bigint
        rename_column :resized_back, :m, :n
      RUBY
      shape = ->(name, column) { tables[name][:columns].find { |c| c[:name] == column }.slice(:type, :null, :default) }

      expect([ shape.("columns_back", "n"), shape.("tables_back", "n"), shape.("keys_back", "id"), shape.("resized_back", "n") ]).to eq(
        [ { type: "serial", null: false }, { type: "serial", null: false }, { type: "bigint", null: false }, { type: "bigserial", null: false } ]
      )
    end

    # change_column keeps a column's sequence default, so the dump names it serial whatever its type while the names
    # follow the sequence (schema_type), and writes the changed type with the nextval default once they do not.
    # Expected values are PostgreSQL 16 dumps.
    it "reads a PostgreSQL serial change_column retypes as its new type once its sequence no longer follows its names" do
      tables = replay([ <<~RUBY ], adapter: "postgresql")
        create_table :b1 do |t|
          t.serial :n
        end
        change_column :b1, :n, :string
        create_table :b2 do |t|
          t.serial :n
        end
        rename_column :b2, :n, :m
        change_column :b2, :m, :string
        rename_column :b2, :m, :n
        create_table :b3 do |t|
          t.serial :n
        end
        rename_column :b3, :n, :m
        change_column :b3, :m, :decimal, precision: 10
        create_table :b4 do |t|
          t.serial :n
        end
        rename_table :b4, :c4
        change_column :c4, :n, :string
      RUBY
      nextval = ->(sequence) { %(-> { "nextval('#{sequence}'::regclass)" }) }
      shape = ->(name) { tables[name][:columns].last.slice(:type, :precision, :null, :default) }

      expect(%w[b1 b2 b3 c4].map { |name| shape.(name) }).to eq(
        [ { type: "serial", null: false }, { type: "serial", null: false },
          { type: "decimal", precision: 10, null: false, default: nextval.("b3_n_seq") },
          { type: "string", null: false, default: nextval.("b4_n_seq") } ]
      )
    end

    # PostgreSQL's ALTER TABLE on a parent reaches the tables that INHERITS it: a column added, renamed, retyped or given a
    # default or NOT NULL changes in each child, a dropped one goes unless the child declares it too, and a renamed
    # sequence shows in the child's copied default. Expected values are PostgreSQL 16 dumps.
    it "changes a PostgreSQL child table when a statement changes the parent it inherits" do
      tables = replay([ <<~RUBY ], adapter: "postgresql")
        execute "CREATE TABLE a3 (id serial PRIMARY KEY, n integer)"
        execute "CREATE TABLE a3c (x integer) INHERITS (a3)"
        rename_column :a3, :n, :m
        execute "CREATE TABLE a4 (id serial PRIMARY KEY, n integer)"
        execute "CREATE TABLE a4c (x integer) INHERITS (a4)"
        add_column :a4, :k, :string
        remove_column :a4, :n
        execute "CREATE TABLE a5 (id serial PRIMARY KEY, n integer)"
        execute "CREATE TABLE a5c (x integer) INHERITS (a5)"
        change_column :a5, :n, :bigint
        change_column_null :a5, :n, false
        change_column_default :a5, :n, 7
        execute "CREATE TABLE a6 (id serial PRIMARY KEY, n integer)"
        execute "CREATE TABLE a6c (n integer, x integer) INHERITS (a6)"
        remove_column :a6, :n
        rename_table :a6, :a7
      RUBY
      shape = ->(name) { tables[name][:columns].to_h { |c| [ c[:name], c.slice(:type, :null, :default) ] } }
      id = ->(sequence) { { "id" => { type: "integer", null: false, default: %(-> { "nextval('#{sequence}'::regclass)" }) } } }
      nullable = { type: "integer", null: true }

      expect(%w[a3c a4c a5c a6c].map { |name| shape.(name) }).to eq(
        [ id.("a3_id_seq").merge("m" => nullable, "x" => nullable),
          id.("a4_id_seq").merge("x" => nullable, "k" => { type: "string" }),
          id.("a5_id_seq").merge("n" => { type: "bigint", null: false, default: "7" }, "x" => nullable),
          id.("a7_id_seq").merge("n" => nullable, "x" => nullable) ]
      )
    end

    # Rails' PostgreSQL unique constraints, in create_table, change_table or alone; the dump leaves out a uniq_rails_ name
    # Rails made up, and a constraint made from an index takes that index over. Expected values are PostgreSQL 16 dumps.
    it "replays PostgreSQL unique constraints as the dump writes them" do
      tables = replay([ <<~RUBY ], adapter: "postgresql")
        create_table :ks do |t|
          t.integer :v_id
          t.integer :w
        end
        change_table :ks do |t|
          t.unique_constraint :v_id
          t.unique_constraint [:v_id, :w], name: "ks_vw", deferrable: :deferred
        end
        create_table :kt do |t|
          t.integer :v
          t.integer :x
          t.unique_constraint :v
          t.unique_constraint :x, name: "kt_x"
        end
        add_unique_constraint :kt, :id
        add_unique_constraint :kt, [:v, :x], deferrable: :immediate
        remove_unique_constraint :kt, :v
        remove_unique_constraint :kt, name: "kt_x"
        create_table :ku do |t|
          t.integer :a
          t.index :a, unique: true, name: "ku_a_idx"
        end
        add_unique_constraint :ku, using_index: "ku_a_idx"
        add_unique_constraint :ku, :id
        revert { add_unique_constraint :ku, :id }
        change_table :ks do |t|
          t.remove_unique_constraint name: "ks_vw"
        end
        rename_column :ks, :v_id, :vv
      RUBY

      expect(%w[ks kt ku].map { |name| tables[name].slice(:unique_constraints, :indexes) }).to eq(
        [ { unique_constraints: [ { columns: %w[vv] } ], indexes: [] },
          { unique_constraints: [ { columns: %w[id] }, { columns: %w[v x], deferrable: "immediate" } ], indexes: [] },
          { unique_constraints: [ { columns: %w[a] } ], indexes: [] } ]
      )
    end

    # Rails 8.0 writes NULLS NOT DISTINCT for nulls_not_distinct: and dumps it; 7.1 and 7.2 ignore the option.
    it "keeps a PostgreSQL unique constraint's nulls_not_distinct from Rails 8.0" do
      allow(RailsAiContext).to receive(:static_tier?).and_return(true)
      constraints = lambda do |rails|
        Dir.mktmpdir do |dir|
          File.write(File.join(dir, "Gemfile.lock"), "GEM\n  remote: https://rubygems.org/\n  specs:\n    rails (#{rails})\n\nDEPENDENCIES\n  rails\n")
          File.write(File.join(dir, "20240101000000_create.rb"), <<~RUBY)
            create_table :kn do |t|
              t.integer :a
              t.integer :b
              t.unique_constraint :a, nulls_not_distinct: true
            end
            add_unique_constraint :kn, :b, nulls_not_distinct: true, deferrable: :deferred
          RUBY
          described_class.replayed(dir, pk_type: "bigint", root: dir, adapter: "postgresql").tables["kn"][:unique_constraints]
        end
      end

      expect(constraints.("8.0.5")).to eq([ { columns: %w[a], nulls_not_distinct: true }, { columns: %w[b], deferrable: "deferred", nulls_not_distinct: true } ])
      expect(constraints.("7.2.3")).to eq([ { columns: %w[a] }, { columns: %w[b], deferrable: "deferred" } ])
    end

    # create_table's options: string ends the CREATE TABLE, so INHERITS there gives the table its parents' columns first,
    # a declared column of the same name merged in place. Expected values are PostgreSQL 16 dumps.
    it "gives a PostgreSQL create_table with INHERITS in its options its parents' columns" do
      tables = replay([ <<~RUBY ], adapter: "postgresql")
        create_table :ie do |t|
          t.string :a
          t.integer :m
        end
        create_table :iec, id: false, options: "INHERITS (ie)" do |t|
          t.integer :y
          t.integer :m, null: false, default: 4
        end
        create_table :ied, options: "INHERITS (ie)" do |t|
          t.integer :y
        end
        add_column :ie, :b, :integer
        remove_column :ie, :m
        create_table :iee, id: false, options: "INHERITS (ied)" do |t|
          t.text :w
        end
      RUBY
      shape = ->(name) { tables[name][:columns].map { |c| [ c[:name], c[:type], c[:null] != false, c[:default] ].compact } }
      nextval = ->(sequence) { %(-> { "nextval('#{sequence}'::regclass)" }) }

      expect(%w[iec ied iee].map { |name| shape.(name) }).to eq(
        [ [ [ "id", "bigint", false, nextval.("ie_id_seq") ], [ "a", "string", true ], [ "m", "integer", false, "4" ], [ "y", "integer", true ], [ "b", "integer", true ] ],
          [ [ "id", "bigint", false ], [ "a", "string", true ], [ "y", "integer", true ], [ "b", "integer", true ] ],
          [ [ "id", "bigint", false, nextval.("ied_id_seq") ], [ "a", "string", true ], [ "y", "integer", true ], [ "b", "integer", true ], [ "w", "text", true ] ] ]
      )
    end

    # A parent no statement the replay read made is noted, whichever way the INHERITS is written.
    it "keeps an INHERITS parent it cannot find as unresolved, in an execute and in create_table's options" do
      tables = replay([ <<~RUBY ], adapter: "postgresql")
        create_table :ip
        execute "CREATE TABLE ic (y integer) INHERITS (ip, gone)"
        create_table :io, id: false, options: 'INHERITS (ip, "gone")' do |t|
          t.integer :y
        end
      RUBY

      expect(%w[ic io].map { |name| [ tables[name][:inherits_unresolved], tables[name][:columns].map { |c| c[:name] } ] }).to eq(
        [ [ %w[gone], %w[id y] ], [ %w[gone], %w[id y] ] ]
      )
    end

    # ALTER COLUMN on a parent runs on every child as well, so it sets what the child declared itself even where the
    # parent already had that value. Expected values are PostgreSQL 16 dumps.
    it "runs a PostgreSQL parent's column change on each INHERITS child, whatever the child declared" do
      tables = replay([ <<~RUBY ], adapter: "postgresql")
        create_table :ja do |t|
          t.integer :b
          t.string :s, default: "p"
        end
        execute "CREATE TABLE jac (b integer NOT NULL, s varchar DEFAULT 'c') INHERITS (ja)"
        execute "CREATE TABLE jag (z int) INHERITS (jac)"
        change_column_null :ja, :b, true
        change_column_default :ja, :s, "p"
        create_table :ih do |t|
          t.string :a
        end
        execute "CREATE TABLE ihc (a varchar NOT NULL DEFAULT 'c') INHERITS (ih)"
        change_column :ih, :a, :text
        change_column_default :ih, :a, nil
      RUBY
      shape = lambda do |name, column|
        found = tables[name][:columns].find { |c| c[:name] == column }
        found.slice(:type, :default).merge(null: found[:null] != false)
      end

      expect([ shape.("jac", "b"), shape.("jac", "s"), shape.("jag", "b"), shape.("jag", "s"), shape.("ihc", "a") ]).to eq(
        [ { type: "integer", null: true }, { type: "string", default: "p", null: true }, { type: "integer", null: true },
          { type: "string", default: "p", null: true }, { type: "text", null: false } ]
      )
    end

    # DROP TABLE ... CASCADE drops the tables that INHERITS the one it names, and create_table's force: drops the old
    # table before it makes the new one. Expected values are PostgreSQL 16 dumps.
    it "drops a PostgreSQL parent's INHERITS children with it under CASCADE, and a forced create_table replaces its table" do
      result = Dir.mktmpdir do |dir|
        File.write(File.join(dir, "20240101000000_one.rb"), <<~RUBY)
          create_table :zp do |t|
            t.string :a
          end
          execute "CREATE TABLE zc (y int) INHERITS (zp)"
          execute "CREATE TABLE zg (z int) INHERITS (zc)"
          create_table :zp2
          execute "CREATE TABLE zc2 (y int) INHERITS (zp2)"
          create_table :zp3 do |t|
            t.string :old
          end
          execute "CREATE TABLE zc3 (y int) INHERITS (zp3)"
          create_table :zp4 do |t|
            t.string :old
          end
        RUBY
        File.write(File.join(dir, "20240101000001_two.rb"), <<~RUBY)
          drop_table :zp, force: :cascade
          drop_table :zp, if_exists: true
          execute "DROP TABLE zp2 CASCADE"
          create_table :zp3, force: :cascade do |t|
            t.string :n
          end
          create_table :zp4, force: true do |t|
            t.string :n
          end
          create_table :keep
        RUBY
        described_class.replayed(dir, pk_type: "bigint", adapter: "postgresql")
      end
      names = result.tables.transform_values { |table| table[:columns].map { |c| c[:name] } }

      expect([ names, result.counts.failed_files ]).to eq([ { "zp3" => %w[id n], "zp4" => %w[id n], "keep" => %w[id] }, 0 ])
    end

    # CASCADE drops the foreign keys other tables hold to the dropped table. Expected values are PostgreSQL 16 dumps.
    it "drops the foreign keys to a table PostgreSQL drops under CASCADE" do
      tables = replay([ <<~RUBY ], adapter: "postgresql")
        create_table :fas
        create_table :fb do |t|
          t.references :fa, foreign_key: true
        end
        create_table :fcs
        create_table :fd do |t|
          t.references :fc, foreign_key: true
        end
        drop_table :fas, force: :cascade
        create_table :fcs, force: :cascade do |t|
          t.string :n
        end
      RUBY

      expect([ tables["fb"][:foreign_keys], tables["fd"][:foreign_keys] ]).to eq([ [], [] ])
    end

    # PostgreSQL merges a column the child declares with the parent's, NOT NULL if either is (MergeAttributes).
    it "keeps a child's own NOT NULL on a column it shares with a parent create_table made" do
      tables = replay([ <<~RUBY ], adapter: "postgresql")
        create_table :k1 do |t|
          t.string :a
        end
        execute "CREATE TABLE k2 (a varchar NOT NULL DEFAULT 'q') INHERITS (k1)"
        change_column_default :k1, :a, "p"
      RUBY

      expect(tables["k2"][:columns].find { |c| c[:name] == "a" }).to include(null: false, default: "p")
    end

    # PostgreSQL numbers a serial's sequence <table>_<column>_seq1 when another relation holds the plain name, and the
    # dump reads seq\d* as the serial's own (new_column_from_field). Expected values are PostgreSQL 16 dumps.
    it "names a PostgreSQL serial's sequence with a number when its plain name is taken" do
      tables = replay([ <<~RUBY ], adapter: "postgresql")
        create_table :sd, id: false do |t|
          t.serial :n
        end
        rename_table :sd, :se
        create_table :sd, id: false do |t|
          t.serial :n
        end
        rename_column :sd, :n, :m
        create_table :sf, id: false do |t|
          t.serial :n
        end
        rename_table :sf, :sg
        create_table :sf, id: false do |t|
          t.serial :n
        end
        rename_column :sf, :n, :m
        rename_column :sf, :m, :n
        execute "CREATE TABLE pe_id_seq (x integer)"
        create_table :pe
        rename_table :pe, :pf
        create_table :ia do |t|
          t.integer :x
          t.index :x, name: "ib_n_seq"
        end
        create_table :ib, id: false do |t|
          t.serial :n
        end
        rename_column :ib, :n, :m
        execute "CREATE TABLE xs (id serial PRIMARY KEY, n serial)"
        rename_table :xs, :xt
        execute "CREATE TABLE xs (id serial PRIMARY KEY, n serial)"
        rename_column :xs, :n, :m
      RUBY
      nextval = ->(sequence) { %(-> { "nextval('#{sequence}'::regclass)" }) }
      shape = ->(name, column) { tables[name][:columns].find { |c| c[:name] == column }.slice(:type, :null, :default) }

      expect([ shape.("sd", "m"), shape.("se", "n"), shape.("sf", "n"), shape.("pf", "id"), shape.("ib", "m"), shape.("xs", "id"), shape.("xs", "m") ]).to eq(
        [ { type: "integer", null: false, default: nextval.("sd_n_seq1") }, { type: "integer", null: false, default: nextval.("sd_n_seq") },
          { type: "serial", null: false }, { type: "bigint", null: false, default: nextval.("pe_id_seq1") },
          { type: "integer", null: false, default: nextval.("ib_n_seq1") }, { type: "serial", null: false },
          { type: "integer", null: false, default: nextval.("xs_n_seq1") } ]
      )
    end

    # rename_table renames the key's sequence only when it has the name Rails builds from the old table: 7.1 to 8.1 cut
    # the table to fit 63 bytes, 7.0 does not and PostgreSQL cuts the new name. Expected values are PostgreSQL 16 dumps.
    it "renames a PostgreSQL key's sequence with a long table the way each Rails line's rename_table does" do
      allow(RailsAiContext).to receive(:static_tier?).and_return(true)
      long = "c" * 58
      keys = lambda do |rails|
        Dir.mktmpdir do |dir|
          File.write(File.join(dir, "Gemfile.lock"), "GEM\n  remote: https://rubygems.org/\n  specs:\n    rails (#{rails})\n\nDEPENDENCIES\n  rails\n")
          File.write(File.join(dir, "20240101000000_create.rb"), <<~RUBY)
            create_table :short_t
            rename_table :short_t, :#{long}
            create_table :#{"d" * 40}, primary_key: :#{"k" * 40}
            rename_table :#{"d" * 40}, :#{"e" * 40}
          RUBY
          tables = described_class.tables(dir, pk_type: "bigint", adapter: "postgresql", root: dir)
          [ long, "e" * 40 ].map { |name| tables[name][:columns].first.slice(:type, :default) }
        end
      end
      nextval = ->(sequence) { %(-> { "nextval('#{sequence}'::regclass)" }) }
      long_key = nextval.("#{"d" * 29}_#{"k" * 29}_seq")

      expect(keys.("7.0.10")).to eq([ { type: "bigint", default: nextval.("#{long}_id_s") }, { type: "bigint", default: long_key } ])
      expect(keys.("8.1.0")).to eq([ { type: "bigint" }, { type: "bigint", default: long_key } ])
    end

    # TableDefinition#primary_key makes a column of its type, :primary_key unless given, that is the key; an integer or
    # bigint one gets its own sequence on PostgreSQL. Expected values are PostgreSQL 16 and MySQL 8.4 dumps.
    it "reads a key a column declares the way it reads the key create_table implies" do
      body = <<~RUBY
        create_table :plain_keys, id: false do |t|
          t.primary_key :id
        end
        create_table :typed_keys, id: false do |t|
          t.primary_key :id, :integer
        end
        create_table :serial_keys, id: false do |t|
          t.primary_key :id, :serial
        end
        execute "CREATE TABLE serial_children (x integer) INHERITS (serial_keys)"
        create_table :changed_keys, id: false do |t|
          t.primary_key :id, :serial
        end
        change_column :changed_keys, :id, :bigint
        create_table :string_keys, id: false do |t|
          t.primary_key :uid, :string
        end
        create_table :flagged_keys, id: false do |t|
          t.integer :id, primary_key: true
        end
        create_table :added_keys, id: false do |t|
          t.string :x
        end
        add_column :added_keys, :id, :primary_key
      RUBY
      keys = ->(adapter) { replay([ body ], adapter: adapter).transform_values { |t| t[:columns].find { |c| c[:name] != "x" }.slice(:type, :null, :primary_key, :default) } }
      key = ->(type) { { type: type, null: false, primary_key: true } }

      expect(keys.("postgresql")).to eq(
        "plain_keys" => key.("bigint"), "typed_keys" => key.("serial"), "serial_keys" => key.("serial"),
        "serial_children" => { type: "integer", null: false, default: %(-> { "nextval('serial_keys_id_seq'::regclass)" }) },
        "changed_keys" => key.("bigint"), "string_keys" => key.("string"), "flagged_keys" => key.("serial"), "added_keys" => key.("bigint")
      )
      expect(keys.("trilogy").except("serial_children", "serial_keys", "changed_keys")).to eq(
        "plain_keys" => key.("bigint"), "typed_keys" => key.("integer"), "string_keys" => key.("string"), "flagged_keys" => key.("integer"),
        "added_keys" => key.("bigint")
      )
    end

    # PostgreSQL and MySQL make every column of a primary key not null; SQLite leaves a composite key's columns nullable.
    it "makes a composite key's columns not null as the database does" do
      nulls = %w[postgresql trilogy sqlite3].map do |adapter|
        replay([ "create_table :lines, primary_key: [:a, :b] do |t|\n  t.integer :a\n  t.string :b\n  t.integer :c\nend\n" ], adapter: adapter)["lines"][:columns].map { |c| c[:null] }
      end

      expect(nulls).to eq([ [ false, false, nil ], [ false, false, nil ], [ nil, nil, nil ] ])
    end

    # MySQL's serial is BIGINT UNSIGNED NOT NULL AUTO_INCREMENT UNIQUE, which its dump writes as an unsigned bigint.
    it "reads MySQL's serial as the unsigned bigint its dump writes, as a key and as a column" do
      tables = replay([ <<~RUBY ], adapter: "trilogy")
        create_table :keyed, id: :serial
        create_table :counters, id: false do |t|
          t.column :n, :serial
        end
        execute "CREATE TABLE raw_keys (id serial primary key)"
      RUBY
      unsigned = { type: "bigint", null: false, unsigned: true }

      expect(%w[keyed counters raw_keys].map { |name| tables[name][:columns].first.slice(:type, :null, :unsigned) }).to eq([ unsigned ] * 3)
    end

    # MySQL's change_column_null runs change_column, which keeps a column's AUTO_INCREMENT unless told otherwise, and the
    # server keeps an AUTO_INCREMENT column NOT NULL. Expected values are MySQL 8.4 and MariaDB 11.4 dumps.
    it "keeps a MySQL auto-increment column not null through change_column_null and change_column" do
      tables = replay([ <<~RUBY ], adapter: "trilogy")
        create_table :ns, id: false do |t|
          t.column :n, :serial
        end
        change_column_null :ns, :n, true
        execute "CREATE TABLE nx (id bigint PRIMARY KEY, n SERIAL)"
        change_column_null :nx, :n, true
        execute "CREATE TABLE na (id bigint PRIMARY KEY, n bigint NOT NULL AUTO_INCREMENT UNIQUE)"
        change_column_null :na, :n, true
        create_table :nd, id: false do |t|
          t.bigint :n, auto_increment: true, index: { unique: true }
        end
        change_column_null :nd, :n, true
        create_table :nc, id: false do |t|
          t.column :n, :serial
        end
        change_column :nc, :n, :bigint, null: true
        create_table :ne, id: false do |t|
          t.column :n, :serial
        end
        change_column :ne, :n, :bigint, null: true, auto_increment: false
      RUBY

      expect(%w[ns nx na nd nc ne].map { |name| tables[name][:columns].find { |c| c[:name] == "n" }.slice(:type, :null, :unsigned) }).to eq(
        [ { type: "bigint", null: false, unsigned: true } ] * 2 + [ { type: "bigint", null: false } ] * 3 + [ { type: "bigint" } ]
      )
    end

    # MySQL writes unsigned after the type a column declares it on (type_to_sql), and change_column builds the column from
    # its own options alone (change_column_for_alter). Expected values are MySQL 8.4 and MariaDB 11.4 dumps.
    it "keeps a MySQL column unsigned where the statement that makes it says so" do
      body = <<~RUBY
        create_table :gauges, id: :bigint, unsigned: true do |t|
          t.integer :n, unsigned: true
          t.decimal :d, precision: 5, scale: 2, unsigned: true
          t.float :f, unsigned: true
          t.references :owner, unsigned: true
          t.unsigned_integer :u
          t.integer :changed, unsigned: true
          t.integer :kept, unsigned: true
        end
        add_column :gauges, :a, :integer, unsigned: true
        change_column :gauges, :changed, :bigint
        change_column :gauges, :kept, :bigint, unsigned: true
        create_table :keys, id: { type: :bigint, unsigned: true }
        create_table :counters, id: false do |t|
          t.column :n, :serial
        end
        change_column :counters, :n, :integer
      RUBY
      unsigned = ->(adapter) { replay([ body ], adapter: adapter).transform_values { |t| t[:columns].select { |c| c[:unsigned] }.map { |c| c.values_at(:name, :type) } } }

      expect(unsigned.("trilogy")).to eq(
        "gauges" => [ %w[id bigint], %w[n integer], %w[d decimal], %w[f float], %w[owner_id bigint], %w[u integer], %w[kept bigint], %w[a integer] ],
        "keys" => [ %w[id bigint] ], "counters" => []
      )
      expect(unsigned.("postgresql").values.flatten).to eq([])
    end

    # ReferenceDefinition gives the id column the reference's own options (columns, 7.0 to 8.1), so its type and sizes read
    # as any column's do. Expected values are PostgreSQL 16, MySQL 8.4, MariaDB 11.4 and SQLite dumps.
    it "reads a reference's id column type and sizes the way the dump writes a column's" do
      body = "create_table :links do |t|\n  t.references :r, type: :unsigned_integer\n  t.references :s, type: :integer, limit: 2\nend\n"
      ids = ->(adapter) { replay([ body ], adapter: adapter)["links"][:columns].drop(1).map { |c| c.slice(:name, :type, :limit, :unsigned) } }

      expect(ids.("trilogy")).to eq([ { name: "r_id", type: "integer", unsigned: true }, { name: "s_id", type: "integer", limit: 2 } ])
      expect(ids.("sqlite3").last).to eq(name: "s_id", type: "integer", limit: 2)
      expect(ids.("postgresql").last).to eq(name: "s_id", type: "integer", limit: 2)
    end

    # create_join_table adds each side with references and its column_options (7.0 to 8.1), so the ids read as a
    # reference's do on each adapter. Expected values are MySQL 8.4, MariaDB 11.4, SQLite and PostgreSQL 16 dumps.
    it "reads a join table's id columns the way each adapter's dump writes a reference's" do
      body = <<~RUBY
        create_join_table :as, :bs, column_options: { type: :unsigned_integer }
        create_join_table :cs, :ds, column_options: { type: :integer, unsigned: true }
        create_join_table :es, :fs, column_options: { type: :integer, limit: 8 }
      RUBY
      ids = ->(adapter) { replay([ body ], adapter: adapter).values.map { |t| t[:columns].first.slice(:type, :limit, :unsigned) } }
      unsigned = { type: "integer", unsigned: true }

      expect(ids.("trilogy")).to eq([ unsigned, unsigned, { type: "bigint" } ])
      expect(ids.("sqlite3").last).to eq(type: "integer", limit: 8)
      expect(ids.("postgresql").last).to eq(type: "bigint")
    end

    # MySQL 8.4 and MariaDB 11.4 add a unique index named after each column a statement declares serial, or
    # <column>_2 on where the name is taken, and the dump lists each one; only MySQL adds one to a whole-key serial.
    it "lists the unique index MySQL adds for a serial column, as its dump does" do
      tables = replay([ <<~RUBY ], adapter: "trilogy")
        create_table :keyed, id: :serial
        create_table :counters, id: false do |t|
          t.column :n, :serial
          t.integer :k
        end
        add_column :counters, :m, :serial
        change_column :counters, :k, :serial
        create_table :taken, id: false do |t|
          t.integer :k
          t.index :k, name: "n"
        end
        add_column :taken, :n, :serial
        execute "CREATE TABLE raw_keys (id serial primary key)"
        execute "CREATE TABLE raw_cols (id bigint primary key, n serial)"
      RUBY
      unique = ->(name, column) { { name: name, columns: [ column ], unique: true } }

      expect(%w[keyed counters taken raw_keys raw_cols].to_h { |name| [ name, tables[name][:indexes].select { |i| i[:unique] } ] }).to eq(
        "keyed" => [], "counters" => [ unique.("n", "n"), unique.("m", "m"), unique.("k", "k") ],
        "taken" => [ unique.("n_2", "n") ], "raw_keys" => [], "raw_cols" => [ unique.("n", "n") ]
      )
      expect(replay([ "create_table :counters do |t|\n  t.serial :n\nend\n" ], adapter: "postgresql")["counters"][:indexes]).to eq([])
    end

    it "keeps a PostgreSQL array spelling an array of its element type" do
      allow(RailsAiContext).to receive(:static_tier?).and_return(true)
      tables = replay([ <<~RUBY ], adapter: "postgresql")
        create_table :widgets do |t|
          t.column :tags, "text[]"
          t.column :codes, "varchar(40)[]"
          t.column :scores, "real[]"
        end
      RUBY

      expect(tables["widgets"][:columns].drop(1).map { |c| c.except(:name) }).to eq(
        [ { type: "text", array: true }, { type: "string", limit: 40, array: true }, { type: "float", limit: 24, array: true } ]
      )
    end

    it "reads SQLite's spellings the way its type map does" do
      types = [ "double", "double precision", "float4", "float8", "float(10)", "int4", "int8", "int2", "smallint", "tinyint", "varchar(40)",
                "integer(1)", "bigint(8)", "timestamp", "tinyint(1)" ]
      expect(native("sqlite3", types)["widgets"]).to eq(
        [ [ "float", {} ] ] * 4 + [ [ "float", { limit: 10 } ] ] + [ [ "integer", {} ] ] * 5 +
        [ [ "string", { limit: 40 } ], [ "integer", { limit: 1 } ], [ "bigint", {} ], [ "datetime", {} ], [ "integer", { limit: 1 } ], [ "float", {} ] ]
      )
    end
  end

  # The rest of change_table's DSL. An app can add workspace_type with a
  # default and drops the default in the same block; reading only the add
  # left a default the table does not have.
  describe "change_table's change and column calls" do
    let(:posts) do
      replay([
        "create_table :posts do |t|\n  t.integer :views\n  t.string :state, null: false\nend\n",
        <<~RUBY
          change_table :posts do |t|
            t.string :workspace_type, null: false, default: "project"
            t.change_default :workspace_type, from: "project", to: nil
            t.change :views, :bigint
            t.change_null :state, true
            t.column :score, :decimal
          end
        RUBY
      ])["posts"][:columns].to_h { |c| [ c[:name], c ] }
    end

    it "applies change_default" do
      expect(posts["workspace_type"][:default]).to be_nil
    end

    it "applies change and change_null" do
      expect(posts["views"][:type]).to eq("bigint")
      expect(posts["state"]).not_to have_key(:null)
    end

    it "adds a t.column" do
      expect(posts["score"]).to include(type: "decimal")
    end

    # Ruby's sort is not stable, so a block's statement on its opener's line must keep source order.
    it "applies a one-line block's statement after the block opens, among many statements" do
      columns = (1..12).map { |i| "c#{i}" }
      ups = columns.first(3).map { |c| "    change_column :posts, :#{c}, :string, default: \"x\"\n" } +
            [ "    change_table(:posts) { |t| t.change :seen_at, :datetime, default: -> { \"CURRENT_TIMESTAMP\" } }\n" ] +
            columns.drop(3).map { |c| "    change_column :posts, :#{c}, :string, default: \"y\"\n" }
      tables = replay([
        "create_table :posts do |t|\n#{columns.map { |c| "  t.string :#{c}\n" }.join}  t.datetime :seen_at\nend\n",
        "class Relax < ActiveRecord::Migration[8.1]\n  def up\n#{ups.join}  end\nend\n"
      ])

      seen_at = tables["posts"][:columns].find { |c| c[:name] == "seen_at" }
      expect(seen_at[:default]).to eq(%q(-> { "CURRENT_TIMESTAMP" }))
    end
  end
  # change_column_default takes the new default positionally or as
  # from:/to: (extract_new_default_value, 7.0 and 8.1); only from:/to: was read.
  describe "a positional change_column_default" do
    let(:posts) do
      replay([
        "create_table :posts do |t|\n  t.string :state\n  t.integer :views\n  t.boolean :draft, default: true\n  t.string :kind\n  t.uuid :key\n  t.datetime :seen\n  t.string :tag\n  t.datetime :stamp\nend\n",
        <<~RUBY
          change_column_default :posts, :key, -> { "gen_random_uuid()" }
          change_column_default :posts, :seen, from: nil, to: -> { "CURRENT_TIMESTAMP" }
          change_column_default :posts, :tag, "a"
          change_column_default :posts, :stamp, -> { "now()" }
          revert do
            change_column_default :posts, :tag, from: "a", to: -> { "now()" }
            change_column_default :posts, :stamp, from: -> { "clock_timestamp()" }, to: -> { "now()" }
          end
          change_column_default :posts, :state, "open"
          change_column_default :posts, :views, 0
          change_column_default :posts, :draft, nil
          change_table :posts do |t|
            t.change_default :kind, "article"
          end
        RUBY
      ])["posts"][:columns].to_h { |c| [ c[:name], c[:default] ] }
    end

    it "reads the new default at the top level" do
      expect(posts).to include("state" => "open", "views" => "0")
    end

    it "clears a default set to nil" do
      expect(posts["draft"]).to be_nil
    end

    it "reads a proc as the dump writes it" do
      expect(posts.values_at("key", "seen", "tag", "stamp")).to eq(
        [ %(-> { "gen_random_uuid()" }), %(-> { "CURRENT_TIMESTAMP" }), "a", %(-> { "clock_timestamp()" }) ]
      )
    end

    it "reads it inside change_table" do
      expect(posts["kind"]).to eq("article")
    end
  end
  # An app can drop columns with Migration::ColumnDropper.execute_drop, whose
  # body is raw SQL, not a Rails schema statement: nothing ties it to Rails'
  # semantics, so the call is counted, and the column is left alone.
  describe "a class method called on an app constant" do
    let(:result) do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "lib/migration"))
        File.write(File.join(dir, "lib/migration/column_dropper.rb"), <<~RUBY)
          module Migration
            class ColumnDropper
              def self.execute_drop(table, columns)
                columns.each { |c| DB.exec("ALTER TABLE \#{table} DROP COLUMN IF EXISTS \#{c}") }
              end
            end
          end
        RUBY
        FileUtils.mkdir_p(File.join(dir, "app/models"))
        File.write(File.join(dir, "app/models/post.rb"), "class Post < ApplicationRecord\nend\n")
        FileUtils.mkdir_p(File.join(dir, "db/migrate"))
        File.write(File.join(dir, "db/migrate/1_create.rb"), "create_table :posts do |t|\n  t.string :legacy\nend\n")
        File.write(File.join(dir, "db/migrate/2_drop.rb"), <<~RUBY)
          class DropLegacy < ActiveRecord::Migration[7.1]
            def up
              Migration::ColumnDropper.execute_drop(:posts, %i[legacy])
              Post.update_all(legacy: nil)
            end

            def down
              Migration::ColumnDropper.execute_drop(:posts, %i[other])
            end
          end
        RUBY
        return described_class.replayed(File.join(dir, "db/migrate"), pk_type: "bigint", root: dir)
      end
    end

    it "counts the call that up makes, and not the one in down or a model's" do
      expect(result.counts.helper_calls).to eq(1)
    end

    it "does not guess the drop" do
      expect(result.tables["posts"][:columns].map { |c| c[:name] }).to include("legacy")
    end
  end
  # index_name_options names an expression key by its words
  # (`expression.scan(/\w+/).join("_")`, 7.0 and 8.1).
  describe "an unnamed expression index" do
    let(:table) do
      replay([
        "create_table :email_login_codes do |t|\n  t.string :email\n  t.index \"lower(email)\"\nend\n",
        "add_index :email_login_codes, \"lower((email)::text), id\"\n"
      ])["email_login_codes"]
    end

    it "is named for the words of the expression" do
      expect(table[:indexes].map { |i| i[:name] }).to eq(%w[index_email_login_codes_on_lower_email
                                                              index_email_login_codes_on_lower_email_text_id])
    end

    # expression_column_name? takes a String only: a one-element Array is a
    # column list, joined as written.
    it "is not scanned for words when written as an array" do
      table = replay([
        "create_table :codes do |t|\n  t.index [\"lower(email)\"]\nend\n",
        "add_index :codes, [\"upper(email)\"]\n"
      ])["codes"]

      expect(table[:indexes].map { |i| i[:name] }).to eq([ "index_codes_on_lower(email)", "index_codes_on_upper(email)" ])
    end

    it "is found by remove_index under that name" do
      removed = replay([
        "create_table :codes do |t|\n  t.string :email\n  t.index \"lower(email)\"\nend\n",
        "remove_index :codes, name: \"index_codes_on_lower_email\"\n"
      ])["codes"]

      expect(removed[:indexes]).to be_empty
    end
  end
  # A destructured parameter is a Prism::MultiTargetNode with no name, and
  # reading it raised out of the whole replay, taking schema and performance
  # down with it.
  describe "a helper with a destructured parameter" do
    let(:result) do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "lib/acme"))
        File.write(File.join(dir, "lib/acme/helpers.rb"),
                   "module Acme\n  module Helpers\n    def add_pair((table, column))\n      add_column table, column, :string\n    end\n  end\nend\n")
        FileUtils.mkdir_p(File.join(dir, "db/migrate"))
        File.write(File.join(dir, "db/migrate/1_create.rb"), "create_table :posts do |t|\n  t.string :a\nend\n")
        File.write(File.join(dir, "db/migrate/2_use.rb"), <<~RUBY)
          class UsePair < ActiveRecord::Migration[7.1]
            include Acme::Helpers
            def up
              add_pair [:posts, :b]
            end
          end
        RUBY
        return described_class.replayed(File.join(dir, "db/migrate"), pk_type: "bigint", root: dir)
      end
    end

    it "is not followed and does not stop the replay" do
      expect(result.tables["posts"][:columns].map { |c| c[:name] }).to eq(%w[id a])
    end
  end

  # One migration the replay cannot read must cost that file, not the schema.
  describe "a migration file that raises" do
    it "is skipped and counted, and the rest replays" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "db/migrate"))
        File.write(File.join(dir, "db/migrate/1_create.rb"), "create_table :posts do |t|\n  t.string :a\nend\n")
        File.write(File.join(dir, "db/migrate/2_bad.rb"), "add_column :posts, :b, :string\n")
        File.write(File.join(dir, "db/migrate/3_more.rb"), "add_column :posts, :c, :string\n")
        original = described_class.method(:replay)
        allow(described_class).to receive(:replay) do |content, *args, **kwargs|
          raise NoMethodError, "boom" if content.include?(":b")

          original.call(content, *args, **kwargs)
        end

        result = described_class.replayed(File.join(dir, "db/migrate"), pk_type: "bigint", root: dir)

        expect(result.tables["posts"][:columns].map { |c| c[:name] }).to eq(%w[id a c])
        expect(result.counts.failed_files).to eq(1)
      end
    end
  end
  # remove_columns names its own table; a computed one is unknown, and falling
  # back to the block's table dropped a column from the wrong one.
  describe "remove_columns with a computed table" do
    let(:result) do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "db/migrate"))
        File.write(File.join(dir, "db/migrate/1_create.rb"), "create_table :first do |t|\n  t.string :a\nend\n")
        File.write(File.join(dir, "db/migrate/2_drop.rb"), <<~RUBY)
          create_table :third do |t|
            t.string :a
          end
          TABLES.each { |t| remove_columns t, :a }
        RUBY
        return described_class.replayed(File.join(dir, "db/migrate"), pk_type: "bigint", root: dir)
      end
    end

    it "drops nothing from a table it cannot name" do
      expect(result.tables["third"][:columns].map { |c| c[:name] }).to eq(%w[id a])
      expect(result.tables["first"][:columns].map { |c| c[:name] }).to eq(%w[id a])
    end

    it "is counted as not replayed" do
      expect(result.counts.helper_calls).to eq(1)
    end
  end
  it "records a composite primary key the migration declares" do
    table = replay([ "create_table :accounts_tags, primary_key: [:tag_id, :account_id] do |t|\n  t.bigint :tag_id\n  t.bigint :account_id\nend\n" ])["accounts_tags"]

    expect(table[:primary_key]).to eq(%w[tag_id account_id])
  end
  # The count is of calls that could change the schema: a helper whose body
  # reaches a schema statement (through the module's own methods too), or a
  # constant's class method whose name is a schema verb or whose body reaches
  # one. SafeMigrate.enable!, existing_site? and Forum.redis are not.
  describe "which skipped calls count" do
    let(:result) do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "lib/migration"))
        File.write(File.join(dir, "lib/migration/column_dropper.rb"),
                   "module Migration\n  class ColumnDropper\n    def self.execute_drop(t, c)\n      DB.exec(\"x\")\n    end\n  end\nend\n")
        File.write(File.join(dir, "lib/migration/safe_migrate.rb"),
                   "module Migration\n  class SafeMigrate\n    def self.enable!\n      @on = true\n    end\n  end\nend\n")
        File.write(File.join(dir, "lib/migration/rebuilder.rb"),
                   "module Migration\n  class Rebuilder\n    def self.run(t)\n      rename_column t, :a, :b\n    end\n  end\nend\n")
        File.write(File.join(dir, "lib/forum.rb"), "module Forum\n  def self.redis\n    nil\n  end\nend\n")
        FileUtils.mkdir_p(File.join(dir, "lib/acme"))
        File.write(File.join(dir, "lib/acme/helpers.rb"), <<~RUBY)
          module Acme
            module Helpers
              def existing_site?
                true
              end

              def swap_type(table, column, type)
                temp = "tmp"
                add_temp(table, temp, type)
                remove_column table, column
              end

              def add_temp(table, name, type)
                add_column table, name, type
                true
              end
            end
          end
        RUBY
        FileUtils.mkdir_p(File.join(dir, "db/migrate"))
        File.write(File.join(dir, "db/migrate/1_create.rb"), "create_table :posts do |t|\n  t.string :a\nend\n")
        File.write(File.join(dir, "db/migrate/2_calls.rb"), <<~RUBY)
          class Calls < ActiveRecord::Migration[7.1]
            include Acme::Helpers
            def up
              Migration::SafeMigrate.enable!
              Forum.redis
              existing_site?
              Migration::ColumnDropper.execute_drop(:posts, %i[a])
              Migration::Rebuilder.run(:posts)
              swap_type :posts, :a, :text
            end
          end
        RUBY
        return described_class.replayed(File.join(dir, "db/migrate"), pk_type: "bigint", root: dir)
      end
    end

    it "counts only the calls that reach the schema" do
      expect(result.counts.helper_calls).to eq(3)
    end
  end
  # t.column went through the add_column table-op path, which kept only
  # null: and default:, so array: and index: were lost inside create_table.
  describe "t.column" do
    let(:table) do
      replay([ <<~RUBY ])["posts"]
        create_table :posts do |t|
          t.column :tags, :string, array: true, index: true, null: false, default: []
          t.column :score, :decimal, index: { unique: true }
        end
      RUBY
    end

    it "keeps every option inside create_table" do
      tags = table[:columns].find { |c| c[:name] == "tags" }
      expect(tags).to include(type: "string", array: true, null: false)
    end

    it "indexes a column declared with index:" do
      expect(table[:indexes]).to include({ name: "index_posts_on_tags", columns: %w[tags], unique: false },
                                         { name: "index_posts_on_score", columns: %w[score], unique: true })
    end

    it "types a t.virtual by its type: option" do
      boxes = replay([ <<~RUBY ])["boxes"]
        create_table :boxes do |t|
          t.virtual :area, type: :integer, as: "w * 2", stored: true
        end
      RUBY
      expect(boxes[:columns].find { |c| c[:name] == "area" }).to include(type: "integer", generated: "w * 2", stored: true)
    end
  end
  # create_join_table (schema_statements.rb, 7.0 and 8.1) creates the join
  # table with two non-null references and no id, and yields its definition;
  # the replay ignored it and gave the block to the previous table.
  describe "create_join_table" do
    let(:tables) do
      replay([ <<~RUBY ])
        create_table :web_hooks do |t|
          t.string :url
        end
        create_join_table :web_hooks, :categories do |t|
          t.index [:web_hook_id, :category_id]
        end
        create_join_table :tags, :posts, table_name: :post_tags, column_options: { null: true }
      RUBY
    end

    it "creates the table Rails names, with its two references and no id" do
      expect(tables["categories_web_hooks"][:columns]).to eq([
        { name: "web_hook_id", type: "bigint", null: false },
        { name: "category_id", type: "bigint", null: false }
      ])
    end

    it "gives the block to the join table" do
      expect(tables["categories_web_hooks"][:indexes].map { |i| i[:columns] }).to eq([ %w[web_hook_id category_id] ])
      expect(tables["web_hooks"][:indexes]).to be_empty
    end

    it "honours table_name: and column_options:" do
      expect(tables["post_tags"][:columns].map { |c| c[:name] }).to eq(%w[tag_id post_id])
      expect(tables["post_tags"][:columns].first).not_to have_key(:null)
    end

    it "reads one called on the migration a table file is handed" do
      tables = replay([ <<~RUBY ])
        class Tables::PullRequestsWorkPackages < Tables::Base
          def self.table(migration)
            migration.create_join_table :pull_requests, :work_packages do |t|
              t.index :pull_request_id, name: "pr_wp_pr_id"
            end
          end
        end
      RUBY

      expect(tables["pull_requests_work_packages"][:indexes].map { |i| i[:name] }).to eq(%w[pr_wp_pr_id])
    end
  end

  it "replays a migration in a subdirectory, in version order, as Rails reads them" do
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "archive"))
      File.write(File.join(dir, "20240102000000_create_comments.rb"),
                 "class CreateComments < ActiveRecord::Migration[8.1]\n  def change\n    create_table :comments\n  end\nend\n")
      File.write(File.join(dir, "archive", "20240101000000_create_posts.rb"),
                 "class CreatePosts < ActiveRecord::Migration[8.1]\n  def change\n    create_table :posts\n  end\nend\n")
      File.write(File.join(dir, "helper.rb"), "")

      expect(described_class.migration_files([ dir ]).map { |path| File.basename(path) })
        .to eq(%w[20240101000000_create_posts.rb 20240102000000_create_comments.rb])
      expect(described_class.tables(dir, pk_type: "bigint").keys).to contain_exactly("posts", "comments")
    end
  end

  it "does not read a migration file symlinked from outside the app" do
    Dir.mktmpdir do |dir|
      app = File.join(dir, "app")
      FileUtils.mkdir_p([ File.join(app, "db/migrate"), File.join(dir, "outside") ])
      File.write(File.join(dir, "outside/secrets.rb"), "create_table :secrets do |t|\n  t.string :token\nend\n")
      File.symlink(File.join(dir, "outside/secrets.rb"), File.join(app, "db/migrate/20240101000001_link.rb"))

      expect(described_class.tables(File.join(app, "db/migrate"), pk_type: "bigint", root: app)).not_to have_key("secrets")
    end
  end

  # What db:migrate dumps for these statements.
  describe "statements a dump records in full" do
    let(:tables) do
      replay([ <<~RUBY ])
        class Shapes < ActiveRecord::Migration[8.1]
          def change
            create_table :boxes do |t|
              t.integer :w
              t.integer :h
              t.check_constraint "w > 0", name: "w_positive"
              t.check_constraint "h > 0"
            end
            add_column :boxes, :area, :virtual, type: :integer, as: "w * h", stored: true
            add_column :boxes, :tags, :string, array: true
            add_check_constraint :boxes, "w < 100", name: "w_small"
            add_check_constraint :boxes, "h < 100"
            remove_check_constraint :boxes, name: "w_small"
            remove_check_constraint :boxes, "h > 0"
            create_table :tokens, id: { type: :string, limit: 36 }
            add_foreign_key :boxes, :tokens, column: :token_id, on_delete: :cascade, deferrable: :immediate, validate: false
            reversible do |dir|
              dir.up do
                execute <<~SQL
                  CREATE TABLE heredoc_things (
                    id integer primary key,
                    label varchar(20) NOT NULL
                  )
                SQL
              end
            end
          end
        end
      RUBY
    end

    it "types an added virtual column by its type: and lists it as generated" do
      area = tables["boxes"][:columns].find { |c| c[:name] == "area" }
      expect(area).to eq(name: "area", type: "integer", generated: "w * h", stored: true)
      expect(tables["boxes"][:columns].find { |c| c[:name] == "tags" }).to include(array: true)
    end

    it "keeps the check constraints a block or add_check_constraint declares, less the removed ones" do
      expect(tables["boxes"][:check_constraints]).to eq([
        { name: "w_positive", expression: "w > 0" },
        { expression: "h < 100" }
      ])
    end

    it "keeps a foreign key's actions, deferrable mode and validate: false" do
      expect(tables["boxes"][:foreign_keys]).to eq([
        { from_table: "boxes", to_table: "tokens", column: "token_id", primary_key: "id", on_delete: "cascade", deferrable: "immediate", validate: false }
      ])
    end

    it "gives an id: hash's limit to the key" do
      expect(tables["tokens"][:columns].first).to include(name: "id", type: "string", limit: 36)
    end

    it "reads a table a multi-line squiggly heredoc creates" do
      expect(tables["heredoc_things"][:columns].map { |c| c[:name] }).to eq(%w[id label])
    end

    it "counts a CREATE TABLE built at run time as not replayed, squished or not" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "20240101000000_raw.rb"), <<~'RUBY')
          class Raw < ActiveRecord::Migration[8.1]
            def up
              execute <<~SQL
                CREATE TABLE #{name} (
                  id integer primary key
                )
              SQL
            end
          end
        RUBY
        File.write(File.join(dir, "20240101000001_squished.rb"), <<~'RUBY')
          class Squished < ActiveRecord::Migration[8.1]
            def up
              execute <<~SQL.squish
                CREATE TABLE #{name} (
                  id integer primary key
                )
              SQL
            end
          end
        RUBY
        expect(described_class.replayed(dir, pk_type: "bigint").counts.helper_calls).to eq(2)
      end
    end

    it "drops a check constraint a revert block adds" do
      reverted = replay([ <<~RUBY ])
        class Undo < ActiveRecord::Migration[8.1]
          def change
            create_table :posts do |t|
              t.string :title
            end
            add_check_constraint :posts, "length(title) > 0", name: "title_len"
            revert do
              add_check_constraint :posts, "length(title) > 0", name: "title_len"
            end
          end
        end
      RUBY

      expect(reverted["posts"][:check_constraints].to_a).to eq([])
    end
  end

  # The names each server gives, read from PostgreSQL 16's and MySQL 8.4's dumps of these statements.
  describe "a UNIQUE an execute's CREATE TABLE declares" do
    let(:source) do
      <<~RUBY
        execute "CREATE TABLE u5 (id bigint PRIMARY KEY, n int UNIQUE, m int UNIQUE)"
        rename_column :u5, :n, :nn
        remove_column :u5, :m
      RUBY
    end
    let(:keys) { ->(entries) { Array(entries).map { |e| [ e[:name], e[:columns] ] }.sort } }

    it "is a constraint on PostgreSQL, named for its table and columns, that follows its column" do
      allow(RailsAiContext).to receive(:static_tier?).and_return(true)
      tables = replay([ source + <<~RUBY ], adapter: "postgresql")
        execute "CREATE TABLE u1 (id bigint PRIMARY KEY, n bigint NOT NULL UNIQUE, m integer UNIQUE, k text CONSTRAINT k_uq UNIQUE)"
        execute "CREATE TABLE u6 (id bigint PRIMARY KEY UNIQUE, a int, b int UNIQUE, CONSTRAINT ab_uq UNIQUE (a, b), UNIQUE (b), UNIQUE (a), c int UNIQUE, CONSTRAINT c_named UNIQUE (c))"
        create_table :ip9 do |t|
          t.string :a
          t.string :b
        end
        execute "CREATE TABLE ic9 (x int, UNIQUE (a), UNIQUE (b)) INHERITS (ip9)"
        rename_column :ip9, :a, :aa
        remove_column :ip9, :b
      RUBY

      expect(keys.(tables["u1"][:unique_constraints])).to eq([ [ "k_uq", %w[k] ], [ "u1_m_key", %w[m] ], [ "u1_n_key", %w[n] ] ])
      expect(keys.(tables["u5"][:unique_constraints])).to eq([ [ "u5_n_key", %w[nn] ] ])
      expect(keys.(tables["u6"][:unique_constraints])).to eq([ [ "ab_uq", %w[a b] ], [ "c_named", %w[c] ], [ "u6_a_key", %w[a] ], [ "u6_b_key", %w[b] ] ])
      expect(keys.(tables["ic9"][:unique_constraints])).to eq([ [ "ic9_a_key", %w[aa] ] ])
      expect(tables["u1"][:indexes]).to eq([])
    end

    # Rails 7.0 dumps a PostgreSQL UNIQUE as the unique index behind it, under the same name.
    it "is the unique index behind it on PostgreSQL for a Rails 7.0 app" do
      allow(RailsAiContext::Introspectors::RailsVersion).to receive(:of).and_return("7.0.10")
      tables = replay([ <<~RUBY ], adapter: "postgresql")
        execute "CREATE TABLE u1 (id bigint PRIMARY KEY, n bigint NOT NULL UNIQUE, m integer UNIQUE, k text CONSTRAINT k_uq UNIQUE)"
      RUBY

      expect(tables["u1"][:unique_constraints]).to be_nil
      expect(tables["u1"][:indexes].map { |i| [ i[:name], i[:columns], i[:unique] ] }).to contain_exactly(
        [ "u1_n_key", %w[n], true ], [ "u1_m_key", %w[m], true ], [ "k_uq", %w[k], true ]
      )
    end

    it "is an index on MySQL, named for its first column" do
      tables = replay([ source + <<~RUBY ], adapter: "trilogy")
        execute "CREATE TABLE u1 (id bigint PRIMARY KEY, n int UNIQUE, m int UNIQUE KEY, k varchar(9) NOT NULL UNIQUE)"
        execute "CREATE TABLE u6 (id bigint PRIMARY KEY, a int, b int UNIQUE, CONSTRAINT ab_uq UNIQUE (a, b), UNIQUE (b), UNIQUE KEY bk2 (b, a), UNIQUE (a))"
        execute "CREATE TABLE na (id bigint PRIMARY KEY, n bigint NOT NULL AUTO_INCREMENT UNIQUE)"
      RUBY

      expect(keys.(tables["u1"][:indexes])).to eq([ [ "k", %w[k] ], [ "m", %w[m] ], [ "n", %w[n] ] ])
      expect(keys.(tables["u5"][:indexes])).to eq([ [ "n", %w[nn] ] ])
      expect(keys.(tables["u6"][:indexes])).to eq([ [ "a", %w[a] ], [ "ab_uq", %w[a b] ], [ "b", %w[b] ], [ "b_2", %w[b] ], [ "bk2", %w[b a] ] ])
      expect(tables["na"][:indexes]).to eq([ { name: "n", columns: %w[n], unique: true } ])
      expect(tables["u1"]).not_to have_key(:unique_constraints)
    end
  end

  # Each table as PostgreSQL 16's, MySQL 8.4's and SQLite's dumps (SQLite's booted columns where the dump cannot write one) give it.
  describe "a table made from a query" do
    let(:source) do
      <<~RUBY
        create_table :c1src do |t|
          t.string :s, null: false
          t.integer :k, default: 3
        end
        execute "CREATE TABLE c1 AS SELECT s, k AS kk FROM c1src"
        create_table :c2, id: false, as: "SELECT * FROM c1src"
        execute "CREATE TABLE IF NOT EXISTS c3 AS SELECT * FROM c1src"
        execute "CREATE TABLE IF NOT EXISTS c3 AS SELECT s FROM c1src"
      RUBY
    end
    let(:shape) { ->(tables, name) { tables[name][:columns].map { |c| [ c[:name], c[:type], c.slice(:limit, :null, :default) ] } } }

    it "takes PostgreSQL's columns with no key, not null or default" do
      tables = replay([ source + %(execute "CREATE TABLE c5 AS (SELECT s FROM c1src)"\n) ], adapter: "postgresql")
      plain = [ [ "id", "bigint", {} ], [ "s", "string", {} ], [ "k", "integer", {} ] ]
      expect(shape.(tables, "c1")).to eq([ [ "s", "string", {} ], [ "kk", "integer", {} ] ])
      expect(shape.(tables, "c5")).to eq([ [ "s", "string", {} ] ])
      expect([ shape.(tables, "c2"), shape.(tables, "c3") ]).to eq([ plain, plain ])
    end

    it "keeps MySQL's not null and defaults, and gives an auto-increment column a 0 default" do
      tables = replay([ source + <<~RUBY ], adapter: "trilogy")
        execute "CREATE TABLE ng (id bigint PRIMARY KEY, n bigint AUTO_INCREMENT UNIQUE)"
        execute "CREATE TABLE nh AS SELECT n FROM ng"
      RUBY
      full = [ [ "id", "bigint", { null: false, default: "0" } ], [ "s", "string", { null: false } ], [ "k", "integer", { default: "3" } ] ]
      expect(shape.(tables, "c1")).to eq([ [ "s", "string", { null: false } ], [ "kk", "integer", { default: "3" } ] ])
      expect([ shape.(tables, "c2"), shape.(tables, "c3") ]).to eq([ full, full ])
      expect(shape.(tables, "nh")).to eq([ [ "n", "bigint", { null: false, default: "0" } ] ])
    end

    # A column the query computes, or takes from a table other than the FROM one, has a type only the database knows: it
    # stays untyped, one with no name is counted, and a query the replay cannot read is counted, never an empty table.
    it "leaves a PostgreSQL column it cannot trace untyped, and counts what it cannot name or read" do
      result = Dir.mktmpdir do |dir|
        File.write(File.join(dir, "20240101000000_step.rb"), source + <<~RUBY)
          create_table :c9o do |t|
            t.date :k
          end
          execute "CREATE TABLE ca1 AS SELECT s, count(*) AS n FROM c1src GROUP BY s"
          execute "CREATE TABLE ca2 AS SELECT s s2, k FROM c1src"
          execute "CREATE TABLE ca3 AS SELECT o.k FROM c1src c JOIN c9o o ON o.id = c.id"
          execute "CREATE TABLE ca4 (x, y) AS SELECT s, k FROM c1src"
          execute "CREATE TABLE ca5 AS SELECT c.k, c.s AS t FROM c1src c"
          execute "CREATE TABLE ca7 (x) AS SELECT s, k FROM c1src WITH NO DATA"
          execute "CREATE TABLE ct1 AS SELECT 1 AS n"
          execute "CREATE TABLE ct2 AS TABLE c1src"
          create_table :ct9, as: "SELECT 1 AS n"
          execute "CREATE TABLE cu AS SELECT s, lower(s) FROM c1src"
          execute "CREATE TABLE cv AS SELECT s, (SELECT max(k) FROM c1src), (VALUES (1)) FROM c1src"
          execute "CREATE TABLE cj AS SELECT * FROM c1src c JOIN c9o o ON o.id = c.id"
        RUBY
        described_class.replayed(dir, pk_type: "bigint", adapter: "postgresql")
      end
      columns = %w[ca1 ca2 ca3 ca4 ca5 ca7 ct1 ct2 ct9 cu cv].to_h { |name| [ name, result.tables[name][:columns].map { |c| [ c[:name], c[:type] ] } ] }

      expect(columns).to eq(
        "ca1" => [ [ "s", "string" ], [ "n", nil ] ], "ca2" => [ [ "s2", "string" ], [ "k", "integer" ] ], "ca3" => [ [ "k", nil ] ],
        "ca4" => [ [ "x", "string" ], [ "y", "integer" ] ], "ca5" => [ [ "k", "integer" ], [ "t", "string" ] ],
        "ca7" => [ [ "x", "string" ], [ "k", "integer" ] ], "ct1" => [ [ "n", "integer" ] ],
        "ct2" => [ [ "id", "bigint" ], [ "s", "string" ], [ "k", "integer" ] ], "ct9" => [ [ "n", "integer" ] ], "cu" => [ [ "s", "string" ], [ "lower", nil ] ],
        "cv" => [ [ "s", "string" ], [ "max", nil ] ]
      )
      expect([ result.tables.key?("cj"), result.counts.unnamed_columns, result.counts.helper_calls ]).to eq([ false, 1, 1 ])
    end

    # The FROM is the one outside parentheses, DISTINCT is no column, PostgreSQL names a bare number ?column? where MySQL
    # and SQLite name it by its text, and MySQL needs no AS before the SELECT.
    it "reads the query's own FROM, DISTINCT and a bare number as each database does" do
      queries = <<~RUBY
        create_table :src do |t|
          t.date :k
          t.string :name
          t.integer :qty
        end
        create_table :oth do |t|
          t.integer :k
        end
        execute "CREATE TABLE q1 AS SELECT k, (SELECT count(*) FROM oth) AS n FROM src"
        execute "CREATE TABLE q2 AS SELECT EXTRACT(YEAR FROM k) AS y, name FROM src"
        execute "CREATE TABLE q4 AS SELECT DISTINCT k, qty FROM src"
        execute "CREATE TABLE q5 AS SELECT name FROM src WHERE qty IN (1, 2)"
        execute "CREATE TABLE q7 AS SELECT name, 2 FROM src"
        execute "CREATE TABLE q8 SELECT name, qty FROM src"
      RUBY
      columns = lambda do |adapter|
        tables = replay([ queries ], adapter: adapter)
        %w[q1 q2 q4 q5 q7 q8].to_h { |name| [ name, tables[name]&.dig(:columns)&.map { |c| [ c[:name], c[:type] ] } ] }
      end
      read = { "q1" => [ [ "k", "date" ], [ "n", nil ] ], "q2" => [ [ "y", nil ], [ "name", "string" ] ], "q4" => [ [ "k", "date" ], [ "qty", "integer" ] ],
               "q5" => [ [ "name", "string" ] ] }

      expect(columns.("postgresql")).to eq(read.merge("q7" => [ [ "name", "string" ], [ "?column?", "integer" ] ], "q8" => nil))
      expect(columns.("trilogy")).to eq(read.merge("q7" => [ [ "name", "string" ], [ "2", "integer" ] ], "q8" => [ [ "name", "string" ], [ "qty", "integer" ] ]))
    end

    # PostgreSQL 16, MySQL 8.4 and SQLite: PostgreSQL names a literal or an operator's result ?column?, MySQL a literal by
    # its value and anything else by its text, SQLite by its text; a column in parentheses is that column.
    it "names and types a literal or computed column as each database does" do
      queries = <<~RUBY
        create_table :src do |t|
          t.date :k
          t.string :name
          t.integer :qty
        end
        execute "CREATE TABLE l1 AS SELECT k + 1, name FROM src"
        execute "CREATE TABLE l2 AS SELECT 1, -1 AS n, 'x' AS s, (name) FROM src"
        execute "CREATE TABLE l4 AS SELECT DISTINCT(k), qty FROM src"
        execute "CREATE TABLE l5 AS SELECT 2.5 AS d, TRUE AS b, 12345678901 AS big"
      RUBY
      columns = lambda do |adapter, extra = ""|
        tables = replay([ queries + extra ], adapter: adapter)
        tables.except("src").transform_values { |t| t[:columns].map { |c| [ c[:name], c[:type] ] } }
      end
      dated = [ %w[k date], %w[qty integer] ]

      expect(columns.("postgresql", %(execute "CREATE TABLE l3 AS SELECT DISTINCT ON (k) k, qty FROM src"\n))).to eq(
        "l1" => [ [ "?column?", nil ], %w[name string] ], "l2" => [ %w[?column? integer], %w[n integer], %w[s text], %w[name string] ],
        "l3" => dated, "l4" => dated, "l5" => [ %w[d decimal], %w[b boolean], %w[big bigint] ]
      )
      expect(columns.("trilogy")).to eq(
        "l1" => [ [ "k + 1", nil ], %w[name string] ], "l2" => [ %w[1 integer], %w[n integer], %w[s string], %w[name string] ],
        "l4" => dated, "l5" => [ %w[d decimal], %w[b integer], %w[big bigint] ]
      )
      expect(columns.("sqlite3")).to eq(
        "l1" => [ [ "k + 1", nil ], %w[name text] ], "l2" => [ [ "1", nil ], [ "n", nil ], [ "s", nil ], %w[name text] ],
        "l4" => [ [ "k", nil ], %w[qty integer] ], "l5" => [ [ "d", nil ], [ "b", nil ], [ "big", nil ] ]
      )
      mysql = replay([ queries ], adapter: "trilogy")
      expect(%w[l2 l5].flat_map { |name| mysql[name][:columns].map { |c| c.except(:type) } }).to eq(
        [ { name: "1", null: false, default: "0" }, { name: "n", null: false, default: "0" }, { name: "s", null: false, default: "", limit: 1 }, { name: "name" },
          { name: "d", null: false, default: "0.0", precision: 2, scale: 1 }, { name: "b", null: false, default: "0" }, { name: "big", null: false, default: "0" } ]
      )
    end

    # MySQL 8.4's dump: an integer by its text's length (sign and leading zeros counted), then by its value; a decimal's
    # precision counts no leading zero but the one before the point; a string's length in characters.
    it "types a MySQL literal column as MySQL 8.4 does" do
      literals = {
        "12345678" => [ "integer" ], "123456789" => [ "bigint" ], "000000001" => [ "bigint" ], "-1234567890" => [ "integer" ],
        "-2147483649" => [ "integer" ], "-00000000001" => [ "bigint" ], "2147483647" => [ "bigint" ], "9223372036854775808" => [ "bigint", true ],
        "18446744073709551616" => [ "decimal", nil, 20 ], "-9223372036854775809" => [ "decimal", nil, 19 ], "00000000000000000001" => [ "bigint" ],
        ".5" => [ "decimal", nil, 1, 1 ], "-.5" => [ "decimal", nil, 1, 1 ], "0.5" => [ "decimal", nil, 2, 1 ], "00.5" => [ "decimal", nil, 2, 1 ],
        "1.50" => [ "decimal", nil, 3, 2 ], "5." => [ "decimal", nil, 1 ], "''" => [ "string" ], "'it''s'" => [ "string" ], "'héllo'" => [ "string" ],
        "TRUE" => [ "integer" ], "FALSE" => [ "integer" ]
      }
      sql = literals.keys.each_with_index.map { |literal, i| %(execute "CREATE TABLE l#{i} AS SELECT #{literal} AS v FROM src"\n) }.join
      tables = replay([ "create_table :src\n#{sql}" ], adapter: "trilogy")
      read = literals.keys.each_with_index.to_h do |literal, i|
        c = tables["l#{i}"][:columns].first
        [ literal, [ c[:type], c[:unsigned], c[:precision], c[:scale] ].reverse.drop_while(&:nil?).reverse ]
      end
      expect(read).to eq(literals)
      expect(%w[l17 l18 l19].map { |name| tables[name][:columns].first[:limit] }).to eq([ 0, 4, 5 ])
    end

    # PostgreSQL 16's FigureColname: a column's last field, a function's name, a cast's argument when that is named and
    # else its type, a CASE's ELSE when that is named and else case, ARRAY; ?column? for an operator or a constant.
    it "names a computed PostgreSQL column as PostgreSQL does" do
      names = {
        "lower(name)" => "lower", %q("Mixed"(k)) => "Mixed", "pg_catalog.LOWER(name)" => "lower", "count(*) OVER ()" => "count", "COALESCE(k, 0)" => "coalesce",
        "EXISTS (SELECT 1)" => "exists", "ARRAY[k]" => "array", "(ARRAY[k])[1]" => "array", "CURRENT_TIMESTAMP" => "current_timestamp", "current_timestamp(3)" => "current_timestamp",
        "k::text" => "k", "((k))::text" => "k", "(k + 1)::text" => "text", "CAST(k + 1 AS bigint)" => "int8", "1::double precision" => "float8", "1::float(10)" => "float4",
        "'a'::varchar(5)" => "varchar", "'a'::char(2)" => "bpchar", "now()::timestamp with time zone" => "now", "'1:00'::time with time zone" => "timetz", "'{}'::int[]" => "int4",
        "'a'::pg_catalog.text" => "text", %q('a'::"char") => "char", "(k + 1)::int::text" => "text", "date '2020-01-01'" => "date",
        "CASE WHEN k > 1 THEN 1 END" => "case", "CASE WHEN k > 1 THEN 1 ELSE k END" => "k", "CASE WHEN k > 1 THEN 'a' ELSE (k + 1)::text END" => "case",
        "CASE k WHEN 1 THEN 'a' ELSE CASE WHEN k > 2 THEN name ELSE name END END" => "name", "CASE WHEN k > 1 THEN 1 END::text" => "text",
        "trim(name)" => "btrim", "trim(leading 'a' from name)" => "ltrim", "trim(trailing from name)" => "rtrim", "k :: text" => "k",
        "INTERVAL '1' day" => "interval", "interval '1 day'::text" => "text", "now() AT TIME ZONE 'utc'" => "timezone", %q(name COLLATE "C") => "name",
        "k IS NULL" => "?column?", "k BETWEEN 1 AND 2" => "?column?", "k IN (1, 2)" => "?column?", "NOT (k > 1)" => "?column?", "k ISNULL" => "?column?",
        "NULL" => "?column?", "E'a'" => "?column?", "upper(name) || 'x'" => "?column?", "CASE WHEN k > 1 THEN 1 END + 1" => "?column?"
      }
      sql = names.keys.each_with_index.map { |item, i| %(execute %q~CREATE TABLE e#{i} AS SELECT #{item} FROM src s~\n) }.join
      result = Dir.mktmpdir do |dir|
        File.write(File.join(dir, "20240101000000_step.rb"), "create_table :src do |t|\n  t.integer :k\n  t.string :name\nend\n#{sql}")
        described_class.replayed(dir, pk_type: "bigint", adapter: "postgresql")
      end
      expect(names.keys.each_with_index.to_h { |item, i| [ item, result.tables["e#{i}"][:columns].first&.dig(:name) ] }).to eq(names)
      expect(result.counts.unnamed_columns).to eq(0)
    end

    # PostgreSQL 16 reads SELECT before a parenthesis or a star; a subquery whose first item is a star takes a name from
    # a table the replay does not follow, so that column stays unnamed and counted.
    it "names a PostgreSQL scalar subquery written with no space after SELECT, and leaves one that selects a star unnamed" do
      items = [ "(SELECT(1))", "(SELECT * FROM (SELECT 1 z) q)", "(SELECT*FROM (SELECT 1 z) q)" ]
      sql = items.each_with_index.map { |item, i| %(execute %q~CREATE TABLE e#{i} AS SELECT #{item} FROM src~\n) }.join
      result = Dir.mktmpdir do |dir|
        File.write(File.join(dir, "20240101000000_step.rb"), "create_table :src do |t|\n  t.integer :k\nend\n#{sql}")
        described_class.replayed(dir, pk_type: "bigint", adapter: "postgresql")
      end
      expect(items.each_index.map { |i| result.tables["e#{i}"][:columns].map { |c| c[:name] } }).to eq([ [ "?column?" ], [], [] ])
      expect(result.counts.unnamed_columns).to eq(2)
    end

    # PostgreSQL 16 names a scalar subquery by its own first column's name, ?column? included, and rewrites IS NORMALIZED
    # to is_normalized(), which NOT or AND outside it turns back into ?column?.
    it "names a PostgreSQL scalar subquery and IS NORMALIZED as PostgreSQL does" do
      names = {
        "(SELECT name FROM src WHERE k = 1 LIMIT 1)" => "name", "(SELECT 1)" => "?column?", "(SELECT max(k) FROM src)" => "max",
        "(SELECT k AS kk FROM src LIMIT 1)" => "kk", "(SELECT k kk2 FROM src LIMIT 1)" => "kk2", "(SELECT k + 1 FROM src LIMIT 1)" => "?column?",
        "((SELECT k FROM src LIMIT 1))" => "k", "(SELECT DISTINCT k FROM src LIMIT 1)" => "k", "(SELECT s.k FROM src s LIMIT 1)" => "k",
        "(SELECT k FROM src LIMIT 1)::int8" => "k", "(SELECT 1)::text" => "?column?", "(SELECT (SELECT max(k) FROM src))" => "max",
        "(SELECT k FROM src LIMIT 1) + 1" => "?column?", "(SELECT CASE WHEN k > 1 THEN 1 END FROM src LIMIT 1)" => "case",
        "name IS NORMALIZED" => "is_normalized", "name IS NFKD NORMALIZED" => "is_normalized", "name || 'x' IS NORMALIZED" => "is_normalized",
        "name IS NOT NORMALIZED" => "?column?", "k = 1 AND name IS NORMALIZED" => "?column?"
      }
      sql = names.keys.each_with_index.map { |item, i| %(execute %q~CREATE TABLE e#{i} AS SELECT #{item} FROM src~\n) }.join
      result = Dir.mktmpdir do |dir|
        File.write(File.join(dir, "20240101000000_step.rb"), "create_table :src do |t|\n  t.integer :k\n  t.string :name\nend\n#{sql}")
        described_class.replayed(dir, pk_type: "bigint", adapter: "postgresql")
      end
      expect(names.keys.each_with_index.to_h { |item, i| [ item, result.tables["e#{i}"][:columns].first&.dig(:name) ] }).to eq(names)
    end

    # PostgreSQL 16, MySQL 8.4 and SQLite read 08 and -09 as base-ten numbers.
    it "reads a number with a leading zero and keeps replaying the file" do
      queries = <<~RUBY
        create_table :src do |t|
          t.integer :qty
        end
        execute "CREATE TABLE z AS SELECT 08 AS n, qty FROM src"
        execute "CREATE TABLE z2 AS SELECT -09 AS m, 007 AS o FROM src"
        create_table :after_it
      RUBY
      types = { "postgresql" => "integer", "trilogy" => "integer", "sqlite3" => nil }
      types.each do |adapter, type|
        tables = replay([ queries ], adapter: adapter)
        expect(tables.keys).to eq(%w[src z z2 after_it])
        expect(tables["z2"][:columns].map { |c| [ c[:name], c[:type] ] }).to eq([ [ "m", type ], [ "o", type ] ])
      end
    end

    # PostgreSQL 16, MySQL 8.4 and SQLite: a bare word after an expression is its alias, unless an operator or a keyword
    # before it takes it as an operand, or it is END, NULL, TRUE or FALSE.
    it "reads a bare alias after a literal, a negative number, a cast or an operator expression" do
      queries = <<~RUBY
        create_table :src do |t|
          t.integer :qty
          t.integer :total
          t.boolean :flag
          t.string :name
        end
        execute "CREATE TABLE b1 AS SELECT 1 n, 'x' s, -2 m, qty + 1 total, name nm FROM src"
        execute "CREATE TABLE b2 AS SELECT CASE WHEN qty > 1 THEN 1 END c, qty IS NOT NULL nn, qty - total d FROM src"
        execute "CREATE TABLE b3 AS SELECT NOT flag FROM src"
        execute "CREATE TABLE b4 AS SELECT qty + total FROM src"
        execute "CREATE TABLE b6 AS SELECT qty ISNULL FROM src"
      RUBY
      names = ->(adapter, extra = "") { replay([ queries + extra ], adapter: adapter).except("src").transform_values { |t| t[:columns].map { |c| c[:name] } } }
      read = { "b1" => %w[n s m total nm], "b2" => %w[c nn d] }

      expect(names.("trilogy")).to eq(read.merge("b3" => [ "NOT flag" ], "b4" => [ "qty + total" ], "b6" => [ "ISNULL" ]))
      expect(names.("sqlite3")).to eq(read.merge("b3" => [ "NOT flag" ], "b4" => [ "qty + total" ], "b6" => [ "qty ISNULL" ]))
      pg = names.("postgresql", %(execute "CREATE TABLE b5 AS SELECT qty::text t, qty::double precision dp, qty :: text FROM src"\n))
      expect(pg.slice("b1", "b2", "b4", "b6")).to eq(read.merge("b4" => [ "?column?" ], "b6" => [ "?column?" ]))
      expect(pg["b5"].first(2)).to eq(%w[t dp])
      expect(pg.values.flatten).not_to include("flag", "text", "precision")
    end

    # PostgreSQL 16, MySQL 8.4, MariaDB 11.4 and SQLite: a word that is a column, after nothing, a dot or an operator,
    # ends an expression the next word aliases; a type's, an interval's or a window's last word is the expression's own.
    it "reads a bare alias only after a complete expression" do
      source = <<~RUBY
        create_table :src do |t|
          t.integer :qty
          t.integer :k
          t.string :zone
          t.string :escape
          t.integer :mod
          t.integer :any
          t.integer :"my col"
          t.datetime :created_at
        end
      RUBY
      names = lambda do |adapter, items|
        sql = items.each_with_index.map { |(item, suffix), i| %(execute %q~CREATE TABLE e#{i} AS SELECT #{item} FROM src s #{suffix}~\n) }.join
        tables = replay([ source + sql ], adapter: adapter)
        items.each_with_index.to_h { |(item, _), i| [ item, tables["e#{i}"][:columns].map { |c| c[:name] } ] }
      end
      window = "WINDOW w AS (ORDER BY k)"
      every = { "zone z" => [ "z" ], "s.zone z" => [ "z" ], "sum(k) OVER w sw" => [ "sw" ] }

      expect(names.("postgresql", [ *every.keys, "escape e", "mod m", "s.escape e2", "qty + mod m", "created_at::timestamp with time zone tz",
                                    "created_at::timestamp without time zone ts", "created_at::timestamp with time zone", "sum(k) OVER w",
                                    "INTERVAL '1-2' YEAR TO MONTH", "INTERVAL '1-2' YEAR TO MONTH ym", "INTERVAL '1 day' iv", "INTERVAL '1' DAY",
                                    %q(k AS "my alias"), %q(k "my ""alias"""), "k Kk", %q("my col") ].map { |item| [ item, (window if item.include?("OVER")) ] })).to eq(
        every.merge("escape e" => [ "e" ], "mod m" => [ "m" ], "s.escape e2" => [ "e2" ], "qty + mod m" => [ "m" ], "created_at::timestamp with time zone tz" => [ "tz" ],
                    "created_at::timestamp without time zone ts" => [ "ts" ], "created_at::timestamp with time zone" => [ "created_at" ], "sum(k) OVER w" => [ "sum" ],
                    "INTERVAL '1-2' YEAR TO MONTH" => [ "interval" ], "INTERVAL '1-2' YEAR TO MONTH ym" => [ "ym" ], "INTERVAL '1 day' iv" => [ "iv" ],
                    "INTERVAL '1' DAY" => [ "interval" ], %q(k AS "my alias") => [ "my alias" ], %q(k "my ""alias""") => [ %q(my "alias") ],
                    "k Kk" => [ "kk" ], %q("my col") => [ "my col" ])
      )
      expect(names.("trilogy", [ *every.keys, "escape e", "any a", "qty + zone z", "sum(k) OVER w", "now() + INTERVAL 1 DAY", "k AS `my alias`", "k Kk", "`my col`", "k 'str'", "k AS 'it''s'",
                                   "DATE '2020-01-01' 'd'", "DATE '2020-01-01'" ]
                                 .map { |item| [ item, (window if item.include?("OVER")) ] })).to eq(
        every.merge("escape e" => [ "e" ], "any a" => [ "a" ], "qty + zone z" => [ "z" ], "sum(k) OVER w" => [ "sum(k) OVER w" ],
                    "now() + INTERVAL 1 DAY" => [ "now() + INTERVAL 1 DAY" ], "k AS `my alias`" => [ "my alias" ], "k Kk" => [ "Kk" ],
                    "`my col`" => [ "my col" ], "k 'str'" => [ "str" ], "k AS 'it''s'" => [ "it's" ], "DATE '2020-01-01' 'd'" => [ "d" ],
                    "DATE '2020-01-01'" => [ "DATE '2020-01-01'" ])
      )
      expect(names.("sqlite3", [ *every.keys, "mod m", "any a", "qty AND mod m", "sum(k) OVER w", %q(k AS "my alias"), "k AS `my alias`", "k 'str'" ]
                                 .map { |item| [ item, (window if item.include?("OVER")) ] })).to eq(
        every.merge("mod m" => [ "m" ], "any a" => [ "a" ], "qty AND mod m" => [ "m" ], "sum(k) OVER w" => [ "sum(k) OVER w" ],
                    %q(k AS "my alias") => [ "my alias" ], "k AS `my alias`" => [ "my alias" ], "k 'str'" => [ "str" ])
      )
    end

    # PostgreSQL 16, MySQL 8.4 and SQLite: a dollar-quoted string, a hex or binary number and a blob are one constant, a
    # precision or an interval's fields stay with their type, and MySQL reads adjacent strings as one.
    it "reads a select item's constants and types as the database tokenizes them" do
      source = "create_table :src do |t|\n  t.integer :k\n  t.datetime :created_at\nend\n"
      names = lambda do |adapter, items|
        sql = items.each_with_index.map { |item, i| %(execute %q~CREATE TABLE e#{i} AS SELECT #{item} FROM src~\n) }.join
        tables = replay([ source + sql ], adapter: adapter)
        items.each_with_index.to_h { |item, i| [ item, tables["e#{i}"][:columns].map { |c| c[:name] } ] }
      end
      postgres = {
        "created_at::timestamp(3) with time zone tz" => [ "tz" ], "created_at::timestamp(3) with time zone" => [ "created_at" ],
        "created_at::timestamp(3) without time zone ts" => [ "ts" ], "'1 day'::interval day iv" => [ "iv" ],
        "'1 day'::interval day to second iv" => [ "iv" ], "'1'::interval second(3) iv" => [ "iv" ],
        "timestamp(3) with time zone '2020-01-01' t" => [ "t" ], "k BETWEEN SYMMETRIC 2 AND 1 bs" => [ "bs" ],
        "k NOT BETWEEN SYMMETRIC 1 AND 2 nb" => [ "nb" ], "k BETWEEN ASYMMETRIC 1 AND 2 ab" => [ "ab" ], "k BETWEEN SYMMETRIC 1 AND 2" => [ "?column?" ],
        "$$a$$ d" => [ "d" ], "$t$a$t$ d" => [ "d" ]
      }
      mysql = { "0b101 b" => [ "b" ], "0x1F h" => [ "h" ], "0x1F" => [ "0x1F" ], %q('a' "b" c) => [ "c" ] }
      sqlite = { "0x1F h" => [ "h" ], "0x1F" => [ "0x1F" ], "x'1F' h" => [ "h" ], "k [x y]" => [ "x y" ] }

      expect(names.("postgresql", postgres.keys)).to eq(postgres)
      expect(names.("trilogy", mysql.keys)).to eq(mysql)
      expect(names.("sqlite3", sqlite.keys)).to eq(sqlite)
    end

    # MySQL 8.4, MariaDB 11.4 and SQLite name an e-notation number by its text; PostgreSQL 16 names a constant ?column?.
    it "names an e-notation number as the database does, never by the part after its point" do
      source = "create_table :src do |t|\n  t.integer :k\nend\n"
      names = lambda do |adapter, items|
        sql = items.each_with_index.map { |item, i| %(execute %q~CREATE TABLE e#{i} AS SELECT #{item} FROM src~\n) }.join
        tables = replay([ source + sql ], adapter: adapter)
        items.each_with_index.to_h { |item, i| [ item, tables["e#{i}"][:columns].map { |c| c[:name] } ] }
      end

      expect(names.("trilogy", [ "1.5e3", "10.25E2" ])).to eq("1.5e3" => [ "1.5e3" ], "10.25E2" => [ "10.25E2" ])
      expect(names.("sqlite3", [ "k, 1.5e3" ])).to eq("k, 1.5e3" => [ "k", "1.5e3" ])
      expect(names.("postgresql", [ "1.5e3" ])).to eq("1.5e3" => [ "?column?" ])
    end

    # PostgreSQL 16, MySQL 8.4, MariaDB 11.4 and SQLite: a word that only starts a multi-word type's next word is an alias.
    it "reads an alias after a type's first word as the alias" do
      source = "create_table :src do |t|\n  t.datetime :time\n  t.integer :bit\n  t.integer :double\n  t.string :character\nend\n"
      names = lambda do |adapter, items|
        sql = items.each_with_index.map { |item, i| %(execute %q~CREATE TABLE e#{i} AS SELECT #{item} FROM src s~\n) }.join
        tables = replay([ source + sql ], adapter: adapter)
        items.each_with_index.to_h { |item, i| [ item, tables["e#{i}"][:columns].map { |c| c[:name] } ] }
      end
      every = { "time w" => [ "w" ], "s.time w" => [ "w" ], "time wi" => [ "wi" ], "bit v" => [ "v" ], "double p" => [ "p" ], "character v" => [ "v" ] }

      expect(names.("postgresql", every.keys)).to eq(every)
      expect(names.("trilogy", [ *every.keys, "time without" ])).to eq(every.merge("time without" => [ "without" ]))
      expect(names.("sqlite3", [ *every.keys, "time without", "time with" ])).to eq(every.merge("time without" => [ "without" ], "time with" => [ "with" ]))
    end

    # PostgreSQL 16, MySQL 8.4, MariaDB 11.4 and SQLite take a keyword with nothing after it as the alias, CASE with no END too.
    it "reads a keyword that ends a select item as its alias" do
      names = lambda do |adapter, words|
        sql = words.each_with_index.map { |word, i| %(execute %q~CREATE TABLE e#{i} AS SELECT k #{word} FROM src~\n) }.join
        tables = replay([ "create_table :src do |t|\n  t.integer :k\nend\n" + sql ], adapter: adapter)
        words.each_with_index.to_h { |word, i| [ word, tables["e#{i}"][:columns].map { |c| c[:name] } ] }
      end
      postgres = %w[member operator match escape glob div mod xor regexp collate between like in is and or not ilike similar case]
      mysql = %w[operator escape glob ilike similar]
      sqlite = %w[member operator div mod xor over rlike sounds ilike similar]

      expect(names.("postgresql", postgres)).to eq(postgres.to_h { |word| [ word, [ word ] ] })
      expect(names.("trilogy", mysql)).to eq(mysql.to_h { |word| [ word, [ word ] ] })
      expect(names.("sqlite3", sqlite)).to eq(sqlite.to_h { |word| [ word, [ word ] ] })
    end

    # MySQL 8.4 and MariaDB 11.4 read N, X or B as a literal's prefix only when the quote touches it; apart, it is a column.
    it "reads a MySQL string after a column named n, x or b as the alias" do
      items = [ "n 'a1'", "b 'a2'", "x 'a3'", "N'a' n1", "b'1' b1", "x'1F' x1" ]
      sql = items.each_with_index.map { |item, i| %(execute %q~CREATE TABLE e#{i} AS SELECT #{item} FROM src~\n) }.join
      tables = replay([ "create_table :src do |t|\n  t.string :n\n  t.integer :b\n  t.integer :x\nend\n" + sql ], adapter: "trilogy")
      expect(items.each_index.map { |i| tables["e#{i}"][:columns].map { |c| c[:name] } }).to eq([ [ "a1" ], [ "a2" ], [ "a3" ], [ "n1" ], [ "b1" ], [ "x1" ] ])
    end

    # PostgreSQL 16, MySQL 8.4 and SQLite read a string and a quoted name that touch as two tokens; MySQL's "q" is a string.
    it "reads a string and a quoted name that touch as the database splits them" do
      names = lambda do |adapter, items|
        sql = items.each_with_index.map { |item, i| %(execute %q~CREATE TABLE e#{i} AS SELECT #{item} FROM src~\n) }.join
        tables = replay([ "create_table :src\n" + sql ], adapter: adapter)
        items.each_index.map { |i| tables["e#{i}"][:columns].map { |c| c[:name] } }
      end

      expect(names.("postgresql", [ %q('x'"q") ])).to eq([ [ "q" ] ])
      expect(names.("trilogy", [ %q('x'"q"), "'x'`q`" ])).to eq([ [ "x" ], [ "q" ] ])
      expect(names.("sqlite3", [ %q('x'"q"), "'x'`q`" ])).to eq([ [ "q" ], [ "q" ] ])
    end

    # MySQL 8.4 joins adjacent strings into one literal and names its column by the first: 'a' 'b' is a varchar(2) named a.
    it "names adjacent MySQL strings by the first, as one string literal" do
      tables = replay([ "create_table :src\nexecute %q~CREATE TABLE e AS SELECT 'a' 'b', 'x' \"yz\" c FROM src~\n" ], adapter: "trilogy")
      expect(tables["e"][:columns].map { |c| c.slice(:name, :type, :limit, :null, :default) }).to eq(
        [ { name: "a", type: "string", limit: 2, null: false, default: "" }, { name: "c", type: "string", limit: 3, null: false, default: "" } ]
      )
    end

    it "reads a plain CREATE TABLE whose name ends in as or select as that table" do
      sql = <<~RUBY
        execute "CREATE TABLE quotas (id integer, n text)"
        execute "CREATE TABLE areas (id integer)"
        execute "CREATE TABLE x_preselect (id integer, n text)"
      RUBY
      %w[postgresql trilogy sqlite3].each do |adapter|
        tables = replay([ sql ], adapter: adapter)
        expect(tables.transform_values { |t| t[:columns].map { |c| c[:name] } }).to eq("quotas" => %w[id n], "areas" => %w[id], "x_preselect" => %w[id n])
      end
    end

    it "leaves a table an earlier statement made when a CREATE TABLE IF NOT EXISTS names it" do
      sql = <<~RUBY
        create_table :src do |t|
          t.string :name
        end
        execute "CREATE TABLE IF NOT EXISTS src (id integer)"
        execute "CREATE TABLE IF NOT EXISTS fresh (id integer)"
      RUBY
      %w[postgresql trilogy sqlite3].each do |adapter|
        tables = replay([ sql ], adapter: adapter)
        expect(tables.transform_values { |t| t[:columns].map { |c| c[:name] } }).to eq("src" => %w[id name], "fresh" => %w[id])
      end
    end

    # MySQL 8.4: the declared columns come first and keep their definition, then each selected column they do not name.
    it "merges MySQL's declared columns with the selected ones, and reads a query in parentheses" do
      tables = replay([ <<~RUBY ], adapter: "trilogy")
        create_table :src do |t|
          t.date :k
          t.integer :qty
        end
        execute "CREATE TABLE m1 (z int) SELECT k FROM src"
        execute "CREATE TABLE m2 (z int) AS SELECT k FROM src"
        execute "CREATE TABLE m3 (k int) SELECT k, qty FROM src"
        execute "CREATE TABLE m4 (SELECT k FROM src)"
        execute "CREATE TABLE m5 (n varchar(5)) SELECT k FROM src"
      RUBY
      expect(%w[m1 m2 m3 m4 m5].to_h { |name| [ name, tables[name]&.dig(:columns)&.map { |c| [ c[:name], c[:type] ] } ] }).to eq(
        "m1" => [ %w[z integer], %w[k date] ], "m2" => [ %w[z integer], %w[k date] ],
        "m3" => [ %w[k integer], %w[qty integer] ], "m4" => [ %w[k date] ], "m5" => [ %w[n string], %w[k date] ]
      )
    end

    # MySQL 8.4's dump keeps the PRIMARY KEY, UNIQUE KEY and KEY a column list declares, on its own or a selected column.
    # MySQL 8.4: the declared columns the query does not select, then the selected ones in SELECT order.
    it "orders a MySQL column list's columns as MySQL does" do
      tables = replay([ <<~RUBY ], adapter: "trilogy")
        create_table :src do |t|
          t.string :name
          t.integer :qty
        end
        execute "CREATE TABLE ctq (qty bigint NOT NULL DEFAULT 0, z int) AS SELECT qty, name FROM src"
        execute "CREATE TABLE ctw (name varchar(9), qty bigint, z int) SELECT qty, name FROM src"
      RUBY
      expect(%w[ctq ctw].to_h { |name| [ name, tables[name][:columns].map { |c| [ c[:name], c[:type], c.slice(:limit, :null, :default).compact.reject { |_, v| v == true } ] } ] }).to eq(
        "ctq" => [ [ "z", "integer", {} ], [ "qty", "bigint", { null: false, default: "0" } ], [ "name", "string", {} ] ],
        "ctw" => [ [ "z", "integer", {} ], [ "qty", "bigint", {} ], [ "name", "string", { limit: 9 } ] ]
      )
    end

    it "keeps the keys a MySQL column list declares" do
      tables = replay([ <<~RUBY ], adapter: "trilogy")
        create_table :src do |t|
          t.string :name
          t.integer :qty
        end
        execute "CREATE TABLE ctk (id int AUTO_INCREMENT, PRIMARY KEY (id)) SELECT qty FROM src"
        execute "CREATE TABLE ctu (z int, UNIQUE KEY uz (z)) SELECT qty FROM src"
        execute "CREATE TABLE ctr (z decimal(5,2), KEY ix_z (z)) SELECT name FROM src"
        execute "CREATE TABLE ctx (z int, KEY ix_q (qty)) SELECT qty FROM src"
      RUBY
      expect(tables["ctk"][:primary_key]).to eq("id")
      expect(%w[ctu ctr ctx].to_h { |name| [ name, tables[name][:indexes] ] }).to eq(
        "ctu" => [ { name: "uz", columns: %w[z], unique: true } ], "ctr" => [ { name: "ix_z", columns: %w[z], unique: false } ],
        "ctx" => [ { name: "ix_q", columns: %w[qty], unique: false } ]
      )
    end

    it "types SQLite's columns by their affinity" do
      tables = replay([ source + <<~RUBY ], pk_type: "integer", adapter: "sqlite3")
        create_table :c4src do |t|
          t.datetime :d
          t.float :f
          t.bigint :g
          t.binary :y
          t.string :s, limit: 20
          t.text :x
        end
        execute "CREATE TABLE c4 AS SELECT * FROM c4src"
      RUBY
      expect(shape.(tables, "c1")).to eq([ [ "s", "text", {} ], [ "kk", "integer", {} ] ])
      expect(shape.(tables, "c3")).to eq([ [ "id", "integer", {} ], [ "s", "text", {} ], [ "k", "integer", {} ] ])
      expect(tables["c4"][:columns].map { |c| [ c[:name], c[:type] ] }).to eq(
        [ [ "id", "integer" ], [ "d", nil ], [ "f", nil ], [ "g", "integer" ], [ "y", nil ], [ "s", "text" ], [ "x", "text" ] ]
      )
    end
  end

  # PostgreSQL 16 stores a nextval default by the sequence, so it reads back under the name a rename gives the sequence.
  # numeric is decimal's alias, and the dump writes a decimal's default as its type reads it back: rounded to the scale,
  # a whole number where the scale is 0 (DecimalWithoutScale), which is MySQL's decimal(10,0) when none is given.
  # Expected values are PostgreSQL 16, MySQL 8.4 and SQLite dumps.
  it "reads numeric as decimal and a decimal's default as each adapter's dump writes it" do
    source = <<~RUBY
      create_table :n1 do |t|
        t.column :n, :numeric, precision: 5, scale: 2
        t.column :m, :numeric
        t.decimal :d, precision: 10, scale: 2, default: 0
        t.decimal :e, precision: 8, scale: 2, default: 1.555
        t.decimal :f, default: "10"
        t.decimal :g, precision: 6, scale: 0, default: 5
        t.decimal :h
      end
      add_column :n1, :k, :decimal, precision: 4, scale: 1, default: 2
      change_column_default :n1, :h, 3
      change_column :n1, :n, :decimal, precision: 5, scale: 2, default: 7
    RUBY
    shape = lambda do |adapter|
      replay([ source ], adapter: adapter)["n1"][:columns].drop(1).to_h { |c| [ c[:name], c.slice(:type, :precision, :scale, :default) ] }
    end
    decimal = ->(**rest) { { type: "decimal", **rest } }

    expect(shape.("postgresql")).to eq(
      "n" => decimal.(precision: 5, scale: 2, default: "7.0"), "m" => decimal.(), "d" => decimal.(precision: 10, scale: 2, default: "0.0"),
      "e" => decimal.(precision: 8, scale: 2, default: "1.56"), "f" => decimal.(default: "10.0"), "g" => decimal.(precision: 6, default: "5"),
      "h" => decimal.(default: "3.0"), "k" => decimal.(precision: 4, scale: 1, default: "2.0")
    )
    expect(shape.("trilogy").slice("m", "f", "h")).to eq(
      "m" => decimal.(precision: 10), "f" => decimal.(precision: 10, default: "10"), "h" => decimal.(precision: 10, default: "3")
    )
    expect(shape.("sqlite3").slice("m", "f", "g")).to eq("m" => decimal.(), "f" => decimal.(default: "10.0"), "g" => decimal.(precision: 6, default: "5"))
  end

  # A precision with no scale is scale 0 on every adapter (extract_scale), and DecimalWithoutScale casts a default with
  # to_i, which truncates; MySQL's own decimal(10,0) rounds a default the migration sent unscaled. numeric is no native
  # type, so type_to_sql drops its sizes. Expected values are PostgreSQL 16, MySQL 8.4, MariaDB 11.4 and SQLite dumps.
  it "reads a decimal default with no scale as each adapter's dump writes it" do
    source = <<~RUBY
      create_table :dq do |t|
        t.decimal :a, precision: 5, default: 3
        t.decimal :b, precision: 5, default: 1.5
        t.decimal :c, precision: 5, scale: 0, default: -2.5
        t.decimal :d, default: 2.5
        t.column :g, :numeric, precision: 6, scale: 3, default: "2"
      end
      add_column :dq, :k, :decimal, precision: 7, default: 100
      add_column :dq, :m, :decimal, precision: 5
      change_column_default :dq, :m, 7.9
    RUBY
    shape = lambda do |adapter|
      replay([ source ], adapter: adapter)["dq"][:columns].drop(1).to_h { |c| [ c[:name], c.slice(:precision, :scale, :default) ] }
    end

    expect(shape.("postgresql")).to eq(
      "a" => { precision: 5, default: "3" }, "b" => { precision: 5, default: "1" }, "c" => { precision: 5, default: "-2" },
      "d" => { default: "2.5" }, "g" => { default: "2.0" }, "k" => { precision: 7, default: "100" }, "m" => { precision: 5, default: "7" }
    )
    expect(shape.("sqlite3")).to eq(shape.("postgresql"))
    expect(shape.("trilogy")).to eq(
      "a" => { precision: 5, default: "3" }, "b" => { precision: 5, default: "1" }, "c" => { precision: 5, default: "-2" },
      "d" => { precision: 10, default: "3" }, "g" => { precision: 10, default: "2" }, "k" => { precision: 7, default: "100" }, "m" => { precision: 5, default: "7" }
    )
    raw = ->(adapter) { replay([ %(execute "CREATE TABLE dr (id int PRIMARY KEY, a decimal(5) DEFAULT 2.5)") ], adapter: adapter)["dr"][:columns].last[:default] }
    expect([ raw.("trilogy"), raw.("postgresql") ]).to eq([ "3", "2" ])
  end

  # PostgreSQL's adapter casts only change_column_default's value, through the column it reads back; create_table,
  # add_column and change_column send theirs as written, which a later change to a plain decimal shows. PostgreSQL 16 dump.
  it "keeps a PostgreSQL decimal default as sent when the column later loses its precision" do
    tables = replay([ <<~RUBY ], adapter: "postgresql")
      create_table :dw do |t|
        t.decimal :a, precision: 5, default: 1.5
        t.decimal :b, precision: 5
        t.decimal :c
      end
      add_column :dw, :e, :decimal, precision: 5, default: 1.5
      change_column_default :dw, :b, 1.5
      change_column :dw, :c, :decimal, precision: 5, default: 1.5
      change_column :dw, :a, :decimal
      change_column :dw, :b, :decimal
      change_column :dw, :c, :decimal
      change_column :dw, :e, :decimal
    RUBY

    expect(tables["dw"][:columns].drop(1).to_h { |c| [ c[:name], c[:default] ] }).to eq("a" => "1.5", "b" => "1.0", "c" => "1.5", "e" => "1.5")
  end

  # The dump writes a proc default as its SQL text in double quotes, and PostgreSQL's adapter reads a literal there back
  # as its value (extract_value_from_default). Expected values are PostgreSQL 16 dumps.
  it "reads a proc default the way the PostgreSQL dump writes it" do
    tables = replay([ <<~RUBY ], adapter: "postgresql")
      create_table :d1 do |t|
        t.datetime :a, default: -> { 'now()' }
        t.string :c, default: -> { "'y'::character varying" }
        t.integer :n, default: -> { "5" }
        t.boolean :b, default: -> { "true" }
        t.datetime :e
        t.date :dd, default: -> { "'2024-01-02'::date" }
      end
      add_column :d1, :q, :string, default: -> { "'it''s'" }
      change_column_default :d1, :e, -> { 'CURRENT_TIMESTAMP' }
      create_table :d2 do |t|
        t.string :s, default: -> { "'z'" }
      end
      revert { change_column_default :d2, :s, from: -> { "'k'::character varying" }, to: -> { "'z'" } }
    RUBY
    defaults = %w[d1 d2].flat_map { |name| tables[name][:columns].filter_map { |c| [ c[:name], c[:default] ] if c.key?(:default) } }.to_h

    expect(defaults).to eq(
      "a" => '-> { "now()" }', "c" => "y", "n" => "5", "b" => "true", "dd" => "2024-01-02", "q" => "it's",
      "e" => '-> { "CURRENT_TIMESTAMP" }', "s" => "k"
    )
  end

  # PostgreSQL stores one whole literal as the column's type reads it, which Rails decodes back (extract_value_from_default);
  # an expression is a proc only where has_default_function? accepts it, else no default. MySQL stores a bare literal or
  # number as the value. Expected values are PostgreSQL 16, MySQL 8.4 and MariaDB 11.4 dumps; the kept procs are the
  # declared SQL, where the dump writes PostgreSQL's own spelling of it.
  it "reads a proc default that is one literal as the server stores it" do
    pg = replay([ <<~RUBY ], adapter: "postgresql")
      create_table :la do |t|
        t.text :cc, default: -> { "'a' || 'b'" }
        t.string :s1, default: -> { "('q')" }
        t.string :s4, default: -> { "'a'::text || 'b'" }
        t.string :s5, default: -> { "'x' :: text" }
        t.string :s6, default: -> { "('a')::text" }
        t.boolean :b1, default: -> { "'t'" }
        t.boolean :b2, default: -> { "'no'" }
        t.boolean :b3, default: -> { "'off'::boolean" }
        t.boolean :b5, default: -> { "TRUE" }
        t.boolean :b6, default: -> { "False" }
        t.integer :i2, default: -> { "(-7)" }
        t.string :a1, array: true, default: -> { "'{}'::character varying[]" }
        t.text :a2, array: true, default: -> { "'{a,b}'::text[]" }
        t.integer :a4, array: true, default: -> { "'{1,2}'" }
        t.boolean :a5, array: true, default: -> { "'{no,yes,of,n,1}'::boolean[]" }
        t.boolean :a6, array: true, default: [ "no", "on", true, false ]
        t.string :e1, array: true, default: -> { "ARRAY['a', 'b']" }
        t.string :e2, array: true, default: -> { "ARRAY[]::varchar[]" }
        t.integer :e3, default: -> { "1 + 1" }
        t.time :e4, default: -> { "CURRENT_TIME" }
        t.text :e5, default: -> { "current_user" }
        t.datetime :f1, default: -> { "current_timestamp" }
        t.date :f2, default: -> { "current_date + 1" }
        t.text :f3, default: -> { "(current_user)::text" }
        t.integer :f4, default: 4
      end
      change_column_default :la, :f4, -> { "1 + 1" }
    RUBY
    my = replay([ <<~RUBY ], adapter: "trilogy")
      create_table :la do |t|
        t.string :s2, default: -> { "'y'" }
        t.string :s1, default: -> { "('q')" }
        t.string :s3, default: -> { "'it''s'" }
        t.integer :i1, default: -> { "5" }
        t.integer :i3, default: -> { "2.5" }
        t.bigint :i4, default: -> { "-2.5" }
        t.float :f1, default: -> { "2.50" }
        t.float :f2, default: -> { "3" }
        t.string :s4, default: -> { "2.50" }
        t.boolean :b4, default: -> { "true" }
        t.decimal :dp, precision: 5, default: -> { "1.5" }
      end
    RUBY
    defaults = ->(tables) { tables["la"][:columns].drop(1).to_h { |c| [ c[:name], c[:default] ] } }

    expect(defaults.(pg)).to eq(
      "cc" => nil, "s1" => "q", "s4" => nil, "s5" => "x", "s6" => "a", "b1" => "true", "b2" => "false",
      "b3" => "false", "b5" => "true", "b6" => "false", "i2" => "-7", "a1" => "[]", "a2" => '["a", "b"]', "a4" => "[1, 2]", "a5" => "[false, true, false, false, true]", "a6" => "[false, true, true, false]",
      "e1" => nil, "e2" => nil, "e3" => nil, "e4" => nil, "e5" => nil, "f1" => '-> { "current_timestamp" }',
      "f2" => '-> { "current_date + 1" }', "f3" => '-> { "(current_user)::text" }', "f4" => nil
    )
    expect(defaults.(my)).to eq("s2" => "y", "s1" => %q(-> { "('q')" }), "s3" => "it's", "i1" => "5", "i3" => "3", "i4" => "-3", "f1" => "2.5", "f2" => "3", "s4" => "2.50", "b4" => "true", "dp" => "2")
  end

  # MySQL 8.4 stores a bare number a string column takes as the number's own text, and an e-notation one as the value on
  # every number type; a date or time column turns it into a date, which the replay leaves as the proc.
  it "reads a bare MySQL number on a string, number or date column as MySQL stores it" do
    numbers = { "a" => "007", "b" => "-07", "c" => "00.10", "d" => "-0.50", "e" => "2.50", "f" => "1e3", "g" => "-1.5e2", "h" => ".5", "i" => "5.",
                "j" => "1e15", "k" => "1.5e-3", "l" => "-0.0", "m" => "1e-16", "n" => "12345678901234567e0" }
    columns = numbers.map { |name, number| %(  t.string :#{name}, default: -> { "#{number}" }) }
    tables = replay([ <<~RUBY ], adapter: "trilogy")
      create_table :la do |t|
      #{columns.join("\n")}
        t.binary :x, limit: 20, default: -> { "007" }
        t.integer :y, default: -> { "1e3" }
        t.float :z, default: -> { "-1.5e2" }
        t.float :z2, default: -> { "1.23456789" }
        t.float :z3, limit: 53, default: -> { "1.23456789" }
        t.decimal :w, precision: 6, scale: 2, default: -> { "1e3" }
        t.date :v, default: -> { "20200101" }
      end
    RUBY
    expect(tables["la"][:columns].drop(1).to_h { |c| [ c[:name], c[:default] ] }).to eq(
      "a" => "7", "b" => "-7", "c" => "0.10", "d" => "-0.50", "e" => "2.50", "f" => "1000", "g" => "-150", "h" => "0.5", "i" => "5",
      "j" => "1e15", "k" => "0.0015", "l" => "0.0", "m" => "1e-16", "n" => "1.2345678901234568e16",
      "x" => "7", "y" => "1000", "z" => "-150", "z2" => "1.23457", "z3" => "1.23456789", "w" => "1000.0", "v" => '-> { "20200101" }'
    )
  end

  # MySQL 8.4 rounds a decimal default half away from zero to the column's scale before it stores it, a zero with no
  # sign, and an e-notation number from the double's shortest digits.
  it "reads a bare MySQL number on a decimal column rounded to its scale, a zero unsigned" do
    numbers = { "a" => "-2.5e-3", "b" => "-0.004", "c" => "-0.005", "d" => "0.005", "e" => "-0.0049", "f" => "-1.005", "g" => "2.345",
                "h" => "-0.0", "i" => "-1e-3", "j" => "-5e-3", "k" => "1.0049999999999999e0", "l" => "-0.125e0" }
    columns = numbers.map { |name, number| %(  t.decimal :#{name}, precision: 8, scale: 2, default: -> { "#{number}" }) }
    tables = replay([ <<~RUBY ], adapter: "trilogy")
      create_table :la do |t|
      #{columns.join("\n")}
        t.decimal :z, precision: 8, scale: 0, default: -> { "-0.4" }
      end
    RUBY
    expect(tables["la"][:columns].drop(1).to_h { |c| [ c[:name], c[:default] ] }).to eq(
      "a" => "0.0", "b" => "0.0", "c" => "-0.01", "d" => "0.01", "e" => "0.0", "f" => "-1.01", "g" => "2.35", "h" => "0.0", "i" => "0.0",
      "j" => "-0.01", "k" => "1.01", "l" => "-0.13", "z" => "0"
    )
  end

  # MySQL 8.4 and MariaDB 11.4 store a number on a YEAR column rounded to a year: 1 to 69 in the 2000s, 70 to 99 in the
  # 1900s and 0 as 0000, which the dump reads as 0; a value outside 1901 to 2155 or below zero they refuse.
  it "reads a bare MySQL number on a year column as MySQL stores it, and keeps the proc for one MySQL refuses" do
    years = { "a" => [ "07", "2007" ], "b" => [ "70", "1970" ], "c" => [ "0", "0" ], "d" => [ "00", "0" ], "e" => [ "2155", "2155" ], "f" => [ "1901", "1901" ],
              "g" => [ "69", "2069" ], "h" => [ "99", "1999" ], "i" => [ "7.5", "2008" ], "j" => [ "2.0e3", "2000" ], "k" => [ "0.4", "0" ],
              "l" => [ "69.5", "1970" ], "m" => [ "1.", "2001" ], "n" => [ "1900.5", "1901" ], "o" => [ "1900", nil ], "p" => [ "2156", nil ],
              "q" => [ "-1", nil ], "r" => [ "1e3", nil ], "s" => [ "-0.4", nil ], "t" => [ "99.5", nil ], "u" => [ "2155.5", nil ] }
    columns = years.map { |name, (number, _)| %(  t.column :#{name}, :year, default: -> { "#{number}" }) }
    tables = replay([ <<~RUBY ], adapter: "trilogy")
      create_table :la, id: false do |t|
      #{columns.join("\n")}
      end
      add_column :la, :v, :year, default: -> { "70" }
      add_column :la, :w, :integer
      change_column :la, :w, :year, default: -> { "72" }
      add_column :la, :x, :year, default: 7
    RUBY
    expect(tables["la"][:columns].to_h { |c| [ c[:name], c[:default] ] }).to eq(
      years.transform_values { |number, stored| stored || %(-> { "#{number}" }) }.merge("v" => "1970", "w" => "1972", "x" => "2007")
    )
  end

  # change_column_default names no type: MySQL 8.4 stores 08 as 2008 and 74 as 1974 on a year column and 07 as 7 on an
  # int one, though the dump reads both as integer.
  it "reads a bare MySQL number change_column_default sets as the column's declared type stores it" do
    tables = replay([ <<~RUBY ], adapter: "trilogy")
      create_table :y, id: false do |t|
        t.column :a, :year
        t.column :b, :year
        t.column :c, :year
        t.integer :n
        t.column :d, :year
        t.column :e, :year
      end
      change_column_default :y, :a, -> { "08" }
      change_column_default :y, :b, from: nil, to: -> { "75" }
      change_column_default :y, :c, from: 7, to: 74
      change_column_default :y, :n, -> { "07" }
      change_column :y, :d, :year, default: -> { "09" }
      change_column :y, :e, :integer
      change_column_default :y, :e, 7
    RUBY
    expect(tables["y"][:columns].to_h { |c| [ c[:name], c[:default] ] }).to eq(
      "a" => "2008", "b" => "1975", "c" => "1974", "n" => "7", "d" => "2009", "e" => "7"
    )
    expect(tables["y"][:columns].map(&:keys).flatten.uniq).not_to include(:year)
  end

  # MySQL 8.4 reads a number with a trailing point as its value, which bigdecimal before 3.2 refuses to parse, and
  # refuses a number no double holds, so that default stays the proc and the rest of the file still replays. A whole
  # number past a double's range is refused on a float column and stored as 1e65 on a double one; both stay the proc.
  it "reads a bare MySQL number with a trailing point or out of a double's range and keeps replaying the file" do
    huge = "1#{"0" * 400}"
    tables = replay([ <<~RUBY ], adapter: "trilogy")
      create_table :la do |t|
        t.integer :n, default: -> { "1." }
        t.decimal :m, precision: 5, scale: 1, default: -> { "1.e3" }
        t.float :f, default: -> { "5." }
        t.float :g, default: -> { "1e400" }
        t.string :s, default: -> { "-1.e3" }
        t.float :h, default: -> { "#{huge}" }
        t.float :w, limit: 53, default: -> { "#{huge}" }
      end
      create_table :after_it
    RUBY
    expect(tables.keys).to eq(%w[la after_it])
    expect(tables["la"][:columns].drop(1).to_h { |c| [ c[:name], c[:default] ] }).to eq(
      "n" => "1", "m" => "1000.0", "f" => "5", "g" => '-> { "1e400" }', "s" => "-1000", "h" => %(-> { "#{huge}" }), "w" => %(-> { "#{huge}" })
    )
  end

  # SQLite stores a proc's SQL as written, and the adapter reads it back by its own rule (the reader's sqlite_default).
  # Expected values are SQLite dumps under Rails 7.0.10, 7.1.6 and 8.1.4.
  it "reads a SQLite proc default as the adapter of the app's Rails reads it back" do
    source = <<~'RUBY'
      create_table :la do |t|
        t.string :s1, default: -> { "'y'" }
        t.string :s2, default: -> { "('q')" }
        t.integer :i1, default: -> { "5" }
        t.integer :i2, default: -> { "(1 + 1)" }
        t.string :s3, default: -> { "'a|b'" }
        t.datetime :d1, default: -> { "CURRENT_TIMESTAMP" }
        t.string :s4, default: -> { "lower('X')" }
        t.boolean :b1, default: -> { "TRUE" }
        t.boolean :b2, default: -> { "1" }
        t.boolean :b3, default: -> { "'f'" }
        t.boolean :b4, default: -> { "'t'" }
      end
      add_column :la, :s6, :string, default: -> { "'z'" }
      add_column :la, :b5, :boolean, default: -> { "0" }
    RUBY
    defaults = lambda do |rails|
      allow(RailsAiContext::Introspectors::RailsVersion).to receive(:of).and_return(rails)
      replay([ source ], adapter: "sqlite3")["la"][:columns].filter_map { |c| [ c[:name], c[:default] ] if c.key?(:default) }.to_h
    end
    newest = { "s1" => "y", "s2" => "q", "i1" => "5", "d1" => '-> { "CURRENT_TIMESTAMP" }', "s4" => %q(-> { "lower('X')" }), "s6" => "z",
               "b2" => "true", "b3" => "false", "b4" => "true", "b5" => "false" }

    expect(defaults.("8.1.4")).to eq(newest.merge("b1" => "true"))
    expect(defaults.("8.1.3")).to eq(newest.merge("b1" => "true"))
    expect(defaults.("7.1.6")).to eq(newest)
    expect(defaults.("7.0.10")).to eq(newest.merge("s3" => "a|b"))
  end

  # Rails 8.1.4's SQLite dump: a decimal with a scale casts TRUE to 1.0, a whole one cannot dump it, and an empty
  # string on a boolean is no default, as ActiveModel's Boolean cast reads it.
  it "reads a SQLite proc default through the column's scale and Rails' boolean cast" do
    source = <<~'RUBY'
      create_table :lb do |t|
        t.decimal :d1, precision: 5, scale: 2, default: -> { "TRUE" }
        t.decimal :d2, precision: 5, scale: 0, default: -> { "TRUE" }
        t.boolean :b1, default: -> { "''" }
      end
    RUBY
    allow(RailsAiContext::Introspectors::RailsVersion).to receive(:of).and_return("8.1.4")
    columns = replay([ source ], adapter: "sqlite3")["lb"][:columns].to_h { |c| [ c[:name], c ] }

    expect(columns["d1"][:default]).to eq("1.0")
    expect(columns["d2"]).not_to have_key(:default)
    expect(columns["b1"]).not_to have_key(:default)
  end

  # PostgreSQL 16 and Rails 8.1.4's dump: each element goes through the column's type, NULL included.
  it "reads a PostgreSQL array proc default's elements as the dump casts them" do
    tables = replay([ <<~'RUBY' ], adapter: "postgresql")
      create_table :la do |t|
        t.integer :a1, array: true, default: -> { "'{1,NULL}'" }
        t.float :a2, array: true, default: -> { "'{1,2.5}'" }
        t.decimal :a3, precision: 5, array: true, default: -> { "'{2.5}'" }
        t.text :a4, array: true, default: -> { %q('{"b\\\\c",NULL}') }
        t.boolean :a5, array: true, default: -> { "'{t,NULL}'" }
      end
    RUBY

    expect(tables["la"][:columns].drop(1).to_h { |c| [ c[:name], c[:default] ] })
      .to eq("a1" => "[1, nil]", "a2" => "[1.0, 2.5]", "a3" => '["2"]', "a4" => '["b\\\\c", nil]', "a5" => "[true, nil]")
  end

  # Rails 7.0.10 and 8.1.4's dump on PostgreSQL 16: a Ruby array or array-literal string default is stored as the
  # column's array and read back through its element type.
  it "reads a PostgreSQL array default given as a value as the dump casts it" do
    tables = replay([ <<~'RUBY' ], adapter: "postgresql")
      create_table :la do |t|
        t.string :g1, array: true, default: ["a", "b"]
        t.string :g3, array: true, default: []
        t.integer :g4, array: true, default: [1, nil]
        t.decimal :g6, precision: 5, array: true, default: [2.5]
        t.float :g8, array: true, default: [1, 2.5]
        t.integer :g9, array: true, default: [[1, 2], [3, 4]]
        t.string :g10, array: true, default: "{a,b}"
        t.float :g11, array: true
        t.float :g12, array: true
      end
      change_column :la, :g11, :float, array: true, default: [3]
      change_column_default :la, :g12, [4, nil]
    RUBY

    expect(tables["la"][:columns].drop(1).to_h { |c| [ c[:name], c[:default] ] }).to eq(
      "g1" => '["a", "b"]', "g3" => "[]", "g4" => "[1, nil]", "g6" => '["2"]', "g8" => "[1.0, 2.5]", "g9" => "[[1, 2], [3, 4]]",
      "g10" => '["a", "b"]', "g11" => "[3.0]", "g12" => "[4.0, nil]"
    )
  end

  describe "a nextval default naming another table's key sequence" do
    it "reads as PostgreSQL writes it, and follows the sequence when rename_table renames it" do
      tables = replay([ <<~RUBY ], adapter: "postgresql")
        create_table :a5
        create_table :o5 do |t|
          t.bigint :n, default: -> { "nextval('a5_id_seq'::regclass)" }
        end
        rename_table :a5, :c5
        create_table :a6
        create_table :o6 do |t|
          t.bigint :n, default: -> { "nextval('a6_id_seq')" }
          t.bigint :p, default: -> { "nextval('public.a6_id_seq'::regclass)" }
        end
        rename_table :a6, :c6
        create_table :a7
        create_table :o7 do |t|
          t.bigint :n, default: -> { "nextval('a7_id_seq')" }
        end
        create_table :a9
        rename_column :a9, :id, :uid
        create_table :o9 do |t|
          t.bigint :n, default: -> { "nextval('a9_id_seq'::regclass)" }
        end
        rename_table :a9, :c9
        create_table :d2 do |t|
          t.serial :n
        end
        change_column_default :d2, :n, -> { "nextval('d2_n_seq'::regclass)" }
        create_table :a10
        execute "CREATE SEQUENCE a10_m_seq"
        add_column :a10, :m, :bigint, default: -> { "nextval('a10_m_seq')" }
        add_column :a10, :at, :datetime, default: -> { "CURRENT_TIMESTAMP" }
      RUBY
      nextval = ->(sequence) { %(-> { "nextval('#{sequence}'::regclass)" }) }
      defaults = ->(name) { tables[name][:columns].drop(1).map { |c| c[:default] } }

      expect(defaults.("o5")).to eq([ nextval.("c5_id_seq") ])
      expect(defaults.("o6")).to eq([ nextval.("c6_id_seq") ] * 2)
      expect(defaults.("o7")).to eq([ nextval.("a7_id_seq") ])
      expect(defaults.("o9")).to eq([ nextval.("a9_id_seq") ])
      expect(tables["d2"][:columns].last).to eq(name: "n", type: "serial", null: false)
      expect(tables["a10"][:columns].drop(1)).to eq([ { name: "m", type: "bigserial" }, { name: "at", type: "datetime", default: %(-> { "CURRENT_TIMESTAMP" }) } ])
    end
  end

  describe "an app root that cannot be resolved" do
    it "reads no migrations instead of raising" do
      missing = File.join(Dir.tmpdir, "rac-no-such-app-#{Process.pid}")
      expect(described_class.configured_dirs(missing, { "migrations_paths" => "db/other_migrate" })).to eq([])
      expect(described_class.migration_files([ File.join(missing, "db/migrate") ], root: missing)).to eq([])
    end
  end
end
