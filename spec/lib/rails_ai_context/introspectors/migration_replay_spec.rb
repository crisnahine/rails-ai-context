# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

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
      { columns: [ "handle" ], unique: true },
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
end
