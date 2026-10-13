ActiveRecord::Schema[8.0].define(version: 2025_01_01_000002) do
  create_table "legacy_orders" do |t|
    t.bigint "user_id"
  end
end
