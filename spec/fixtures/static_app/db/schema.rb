ActiveRecord::Schema.define(version: 2024_01_15_000000) do
  create_table "users" do |t|
    t.string "email"
    t.string "name"
    t.integer "role"
    t.boolean "active", default: true
    t.timestamps
  end

  create_table "posts" do |t|
    t.string "title"
    t.text "body"
    t.boolean "published", default: false
    t.integer "comments_count", default: 0
    t.references "user"
    t.timestamps
  end

  create_table "comments" do |t|
    t.text "body"
    t.references "post"
    t.references "user"
    t.timestamps
  end

  add_index "users", "email", unique: true
end
