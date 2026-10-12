ActiveRecord::Schema[8.0].define(version: 2025_01_01_000001) do
  create_table "solid_queue_jobs" do |t|
    t.string "key"
  end
end
