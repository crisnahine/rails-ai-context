ActiveRecord::Schema[8.0].define(version: 2025_01_01_000001) do
  create_table "jobs" do |t|
    t.bigint "user_id"
  end
end
