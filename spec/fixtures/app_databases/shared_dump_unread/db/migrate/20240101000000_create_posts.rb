class CreatePosts < ActiveRecord::Migration[8.0]
  def change
    create_table :posts
  end
end
