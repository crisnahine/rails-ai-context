ActiveRecord::Schema[7.2].define(version: 2026_03_14_120000) do
  enable_extension "plpgsql"

  create_table "articles", force: :cascade do |t|
    t.string "title", null: false
    t.string "slug", null: false
    t.text "body"
    t.integer "status", default: 0, null: false
    t.datetime "published_at"
    t.integer "comments_count", default: 0, null: false
    t.bigint "author_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["author_id"], name: "index_articles_on_author_id"
    t.index ["slug"], name: "index_articles_on_slug", unique: true
    t.index ["status", "published_at"], name: "index_articles_on_status_and_published_at"
  end

  create_table "comments", force: :cascade do |t|
    t.text "body", null: false
    t.bigint "article_id", null: false
    t.bigint "user_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["article_id"], name: "index_comments_on_article_id"
    t.index ["user_id"], name: "index_comments_on_user_id"
  end

  create_table "users", force: :cascade do |t|
    t.string "email", default: "", null: false
    t.string "encrypted_password", default: "", null: false
    t.string "name"
    t.integer "role", default: 0, null: false
    t.boolean "active", default: true, null: false
    t.string "api_token"
    t.string "reset_password_token"
    t.datetime "reset_password_sent_at"
    t.datetime "remember_created_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["api_token"], name: "index_users_on_api_token", unique: true
    t.index ["email"], name: "index_users_on_email", unique: true
    t.index ["reset_password_token"], name: "index_users_on_reset_password_token", unique: true
  end

  add_foreign_key "articles", "users", column: "author_id"
  add_foreign_key "comments", "articles"
  add_foreign_key "comments", "users"
end
