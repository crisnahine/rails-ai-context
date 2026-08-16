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
