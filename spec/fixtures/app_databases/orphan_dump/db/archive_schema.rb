ActiveRecord::Schema[8.0].define(version: 2024_06_01_000000) do
  create_table "archived_orders" do |t|
    t.string "number"
  end
end
