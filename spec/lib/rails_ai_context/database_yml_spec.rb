# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe RailsAiContext::DatabaseYml do
  describe ".elsewhere" do
    it "names an environment the app declares, never a key that only holds an anchor" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "config/environments"))
        %w[development test production].each { |env| File.write(File.join(root, "config/environments/#{env}.rb"), "") }
        File.write(File.join(root, "config/database.yml"), <<~YAML)
          shared: &shared
            primary: &primary
              adapter: sqlite3
              database: storage/app.sqlite3
            queue:
              adapter: sqlite3
              database: storage/queue.sqlite3
              migrations_paths: db/queue_migrate
          development:
            primary: *primary
          test:
            primary: *primary
          production:
            <<: *shared
        YAML

        env, entry = described_class.elsewhere(root, "queue")

        expect(env).to eq("production")
        expect(entry["migrations_paths"]).to eq("db/queue_migrate")
      end
    end
  end
end
