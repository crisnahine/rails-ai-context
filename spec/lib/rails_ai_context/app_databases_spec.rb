# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::AppDatabases do
  def fixture(name)
    File.expand_path("../../fixtures/app_databases/#{name}", __dir__)
  end

  # The booted tier reads ActiveRecord's configurations for the app at Rails.root.
  def booted(root)
    configurations = ActiveRecord::DatabaseConfigurations.new(YAML.safe_load_file(File.join(root, "config/database.yml"), aliases: true))
    allow(ActiveRecord::Base).to receive(:configurations).and_return(configurations)
    allow(Rails).to receive(:root).and_return(Pathname.new(root))
    RailsAiContext::RunCache.around { described_class.for(root) }.tap { expect(ActiveRecord::Base).to have_received(:configurations) }
  end

  def static(root)
    previous = [ RailsAiContext.tier, ENV.fetch("RAILS_ENV", nil) ]
    RailsAiContext.tier = :static
    ENV["RAILS_ENV"] = "test"
    RailsAiContext::RunCache.around { described_class.for(root) }
  ensure
    RailsAiContext.tier = previous.first
    ENV["RAILS_ENV"] = previous.last
  end

  def entry(root, name, environment: "test", here: true, primary: false, replica: false, tasks: true, adapter: nil,
            family: RailsAiContext::DatabaseFamily.of(adapter), dump: nil, migrate_dirs: [ "db/migrate" ], adapter_default: false,
            environments: [ environment ].compact)
    { name: name, environment: environment, environments: environments, here: here, primary: primary, replica: replica, tasks: tasks, adapter: adapter,
      adapter_default: adapter_default, family: family, dump: dump && [ dump.first, File.join(root, dump.last) ],
      migrate_dirs: migrate_dirs.map { |dir| File.join(root, dir) } }
  end

  shared_examples "the same list on both tiers" do |name, expected|
    %i[booted static].each do |tier|
      it "lists the #{name} fixture's databases on the #{tier} tier" do
        root = fixture(name)
        list = send(tier, root)

        expect(list.map { |db| db.to_h.except(:config) }).to eq(instance_exec(root, &expected))
      end
    end
  end

  it_behaves_like "the same list on both tiers", "rails8", lambda { |root|
    [ entry(root, "primary", primary: true, adapter: "sqlite3", dump: [ :ruby, "db/schema.rb" ], environments: %w[development test production]),
      *%w[cache queue cable].map do |db|
        entry(root, db, environment: "production", here: false, adapter: "sqlite3", dump: [ :ruby, "db/#{db}_schema.rb" ], migrate_dirs: [])
      end ]
  }

  it_behaves_like "the same list on both tiers", "url_primary", lambda { |root|
    [ entry(root, "primary", primary: true, adapter: "postgresql", dump: [ :ruby, "db/schema.rb" ], environments: %w[test production]) ]
  }

  it_behaves_like "the same list on both tiers", "replica", lambda { |root|
    [ entry(root, "primary", primary: true, adapter: "mysql2", dump: [ :ruby, "db/schema.rb" ]),
      entry(root, "primary_replica", replica: true, tasks: false, adapter: "mysql2") ]
  }

  it_behaves_like "the same list on both tiers", "no_tasks", lambda { |root|
    [ entry(root, "primary", primary: true, adapter: "postgresql", dump: [ :ruby, "db/schema.rb" ], environments: %w[test production]),
      entry(root, "legacy", tasks: false, adapter: "mysql2"),
      entry(root, "warehouse", environment: "production", here: false, tasks: false, adapter: "postgresql") ]
  }

  it_behaves_like "the same list on both tiers", "no_dump", lambda { |root|
    [ entry(root, "primary", primary: true, adapter: "postgresql", dump: [ :ruby, "db/schema.rb" ]),
      entry(root, "analytics", adapter: "postgresql", migrate_dirs: [ "db/analytics_migrate" ]) ]
  }

  it_behaves_like "the same list on both tiers", "orphan_dump", lambda { |root|
    [ entry(root, "primary", primary: true, adapter: "sqlite3", dump: [ :ruby, "db/schema.rb" ]),
      entry(root, "archive", environment: nil, here: false, dump: [ :ruby, "db/archive_schema.rb" ], migrate_dirs: [ "db/archive_migrate" ]) ]
  }

  describe "the list's readers" do
    subject(:list) { static(fixture("rails8")) }

    it "answers the primary for no name and names the known ones for an unknown name" do
      expect(list.fetch(nil).name).to eq("primary")
      expect(list.fetch("").name).to eq("primary")
      expect(list.fetch("queue").environment).to eq("production")
      expect { list.fetch("qeue") }.to raise_error(described_class::UnknownDatabase, /qeue.*primary, cache, queue, cable/)
    end

    it "splits the databases configured here from the secondaries Rails runs tasks on" do
      expect(list.names).to eq(%w[primary cache queue cable])
      expect(list.here.map(&:name)).to eq(%w[primary])
      expect(list.secondaries.map(&:name)).to eq(%w[cache queue cable])
      expect(list.find_by_dump(File.join(fixture("rails8"), "db/queue_schema.rb")).name).to eq("queue")
      expect(list.find_by_dump(File.join(fixture("rails8"), "db/nothing_schema.rb"))).to be_nil
    end
  end

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

      queue = static(root).fetch("queue")

      expect(queue.environment).to eq("production")
      expect(queue.environments).to eq(%w[production])
      expect(queue.config["migrations_paths"]).to eq("db/queue_migrate")
    end
  end

  it "lists a replica and a database with no tasks that only another environment configures, flagged, and keeps both out of the secondaries" do
    list = described_class.build(
      environments: {
        "test" => { "primary" => { "adapter" => "postgresql" } },
        "production" => {
          "primary" => { "adapter" => "postgresql" },
          "primary_replica" => { "adapter" => "postgresql", "replica" => true },
          "warehouse" => { "adapter" => "mysql2", "database_tasks" => false },
          "queue" => { "adapter" => "postgresql" }
        }
      },
      current: "test", root: Dir.tmpdir, dumps: []
    )

    expect(list.map { |db| [ db.name, db.here, db.replica, db.tasks ] }).to eq(
      [ [ "primary", true, false, true ], [ "primary_replica", false, true, false ],
        [ "warehouse", false, false, false ], [ "queue", false, false, true ] ]
    )
    expect(list.secondaries.map(&:name)).to eq(%w[queue])
    expect { list.fetch("warehouse").with_connection { nil } }
      .to raise_error(described_class::NotHere, /warehouse database is configured in production/)
  end

  describe "the one list" do
    rules = {
      "reads ActiveRecord's configurations" => /configs_for|\.configurations\b/,
      "reads database.yml's databases" => /DatabaseYml\.(?:databases|file)\b|\bdatabases_in\b/,
      "globs the dumps" => /\*_(?:schema|structure|#\{)/
    }
    offences = lambda do |source|
      source.lines.each_with_index.filter_map do |line, index|
        next if line.lstrip.start_with?("#")

        rule = rules.find { |_, pattern| line.match?(pattern) }&.first
        "#{index + 1} #{rule}: #{line.strip}" if rule
      end
    end

    it "is built nowhere but in the app databases and database.yml's reader" do
      root = File.expand_path("../../../lib", __dir__)
      found = Dir.glob(File.join(root, "**", "*.rb")).sort.flat_map do |file|
        next [] if file.end_with?("rails_ai_context/app_databases.rb", "rails_ai_context/database_yml.rb")

        offences.call(File.read(file)).map { |offence| "#{file.delete_prefix("#{root}/")}:#{offence}" }
      end
      expect(found).to be_empty
    end

    it "catches each way a list is built" do
      [
        "ActiveRecord::Base.configurations.configs_for(env_name: Rails.env)",
        "ActiveRecord::Base.configurations.configurations.map(&:name)",
        "RailsAiContext::DatabaseYml.databases(root).keys",
        "DatabaseYml.databases_in(config)",
        'Dir.glob(File.join(root, "db", "*_schema.rb"))',
        'Dir.glob(File.join(root, "db", "*_#{kind}.#{ext}"))'
      ].each { |source| expect(offences.call(source)).not_to be_empty, source }
      expect(offences.call('RailsAiContext::AppDatabases.for(root).secondaries')).to be_empty
    end
  end

  it "builds once per run" do
    RailsAiContext::RunCache.around do
      expect(described_class.for(fixture("rails8"))).to equal(described_class.for(fixture("rails8")))
    end
  end
end
