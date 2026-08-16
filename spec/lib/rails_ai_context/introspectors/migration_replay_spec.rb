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
end
