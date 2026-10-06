# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "digest"
require "fileutils"

RSpec.describe RailsAiContext::Introspectors::MigrationReplay do
  def replay(migrations, pk_type: "bigint")
    Dir.mktmpdir do |dir|
      migrations.each_with_index do |content, i|
        File.write(File.join(dir, "202401010000#{i}_step#{i}.rb"), content)
      end
      return described_class.tables(dir, pk_type: pk_type)
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
    tables = replay([ <<~RUBY ], pk_type: "integer")
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
    expect(cols["plan"]).to have_key(:default)
    expect(cols["plan"][:default]).to be_nil
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
      expect(column("notes", "read_at")[:default]).to eq('lambda { "now()" }')
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

    it "reads a table an execute creates" do
      expect(tables["raw_things"][:columns].map { |c| c[:name] }).to eq(%w[id name])
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

      expect(odd["copies"][:columns]).to eq([])
      expect(odd["empty_copies"][:columns]).to eq([])
    end

    it "gives a Migration[5.0] table integer keys" do
      expect(tables["legacies"][:columns].map { |c| [ c[:name], c[:type] ] }).to eq([ %w[id integer], %w[user_id integer] ])
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

  # Canvas has a migration that calls `create_table table_name do |t|`, where
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
  # OpenProject creates 99 of its tables in db/migrate/tables/*.rb, required by
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

    # OpenProject declares inflect.acronym "OAuth", so Tables::OAuthApplications
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
  # pattern would not do: Discourse's create_join_table :web_hooks, :categories
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

    # OpenProject creates sessions through Tables::Base.create_unlogged_table.
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
    # Canvas's epub_exports reads three references off one call.
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

    # Canvas's `t.replica_identity_index` is an app method that adds an index
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
  # OpenProject renames favorites.favored_* to favorited_*; the replay kept the
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
  # index: - OpenProject's work_package_journals declares type_id and
  # project_id that way, and the replay dropped both indexes.
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
  # Discourse adds top_topics columns in a loop, `add_column :top_topics,
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
  # Anything else (Mastodon's change_column_type_concurrently adds a temp
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
  # source order: Mastodon's add_index_to_table / remove_index_from_table pair
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
  # GitLab, Discourse and Mastodon keep post-deployment migrations in
  # db/post_migrate; the app adds the path, and Rails runs every path's files
  # in one version order. Mastodon drops users.current_sign_in_ip there.
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
  # The rest of change_table's DSL. OpenProject adds workspace_type with a
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
  end
  # change_column_default takes the new default positionally or as
  # from:/to: (extract_new_default_value, 7.0 and 8.1); only from:/to: was read.
  describe "a positional change_column_default" do
    let(:posts) do
      replay([
        "create_table :posts do |t|\n  t.string :state\n  t.integer :views\n  t.boolean :draft, default: true\n  t.string :kind\nend\n",
        <<~RUBY
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

    it "reads it inside change_table" do
      expect(posts["kind"]).to eq("article")
    end
  end
  # Discourse drops columns with Migration::ColumnDropper.execute_drop, whose
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
  # one. SafeMigrate.enable!, existing_site? and Discourse.redis are not.
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
        File.write(File.join(dir, "lib/discourse.rb"), "module Discourse\n  def self.redis\n    nil\n  end\nend\n")
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
              Discourse.redis
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

  # What db:migrate dumps for these statements, which the replay dropped or mistyped.
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
end
