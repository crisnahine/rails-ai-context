class CreateSolidQueueJobs < ActiveRecord::Migration[8.0]
  def change
    create_table :solid_queue_jobs do |t|
      t.string :key
    end
  end
end
