# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::AppDatabases do
  def fixture(name)
    File.expand_path("../../fixtures/app_databases/#{name}", __dir__)
  end

  # The booted tier reads ActiveRecord's configurations for the app at Rails.root, and ActiveRecord::Base
  # is connected to the environment's first database unless `connected` names another.
  def booted(root, connected: nil)
    configurations = ActiveRecord::DatabaseConfigurations.new(YAML.safe_load_file(File.join(root, "config/database.yml"), aliases: true))
    allow(ActiveRecord::Base).to receive(:configurations).and_return(configurations)
    own = configurations.configs_for(env_name: "test")
    allow(ActiveRecord::Base).to receive(:connection_db_config).and_return(own.find { |config| config.name == connected } || own.first)
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

  def entry(root, name, environments: %w[test], here: true, primary: false, replica: false, tasks: true, adapter: nil,
            family: RailsAiContext::DatabaseFamily.of(adapter), dump: nil, migrate_dirs: [ "db/migrate" ], adapter_default: false)
    { name: name, environments: environments, here: here, primary: primary, replica: replica, tasks: tasks, adapter: adapter,
      adapter_default: adapter_default, family: family, dump: dump && described_class::Dump.new(format: dump.first, path: File.join(root, dump.last)),
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
        entry(root, db, environments: %w[production], here: false, adapter: "sqlite3", dump: [ :ruby, "db/#{db}_schema.rb" ],
                        migrate_dirs: db == "queue" ? [ "db/queue_migrate" ] : [])
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
      entry(root, "warehouse", environments: %w[production], here: false, tasks: false, adapter: "postgresql") ]
  }

  it_behaves_like "the same list on both tiers", "no_dump", lambda { |root|
    [ entry(root, "primary", primary: true, adapter: "postgresql", dump: [ :ruby, "db/schema.rb" ]),
      entry(root, "analytics", adapter: "postgresql", migrate_dirs: [ "db/analytics_migrate" ]) ]
  }

  it_behaves_like "the same list on both tiers", "orphan_dump", lambda { |root|
    [ entry(root, "primary", primary: true, adapter: "sqlite3", dump: [ :ruby, "db/schema.rb" ]),
      entry(root, "archive", environments: [], here: false, dump: [ :ruby, "db/archive_schema.rb" ], migrate_dirs: [ "db/archive_migrate" ]) ]
  }

  it_behaves_like "the same list on both tiers", "animals_first", lambda { |root|
    [ entry(root, "animals", primary: true, adapter: "postgresql", dump: [ :ruby, "db/schema.rb" ]),
      entry(root, "primary", adapter: "mysql2", dump: [ :ruby, "db/schema.rb" ]) ]
  }

  it_behaves_like "the same list on both tiers", "fallback_dump", lambda { |root|
    [ entry(root, "primary", primary: true, adapter: "postgresql", dump: [ :sql, "db/structure.sql" ]),
      entry(root, "queue", adapter: "postgresql", dump: [ :ruby, "db/queue_schema.rb" ]),
      entry(root, "legacy", tasks: false, adapter: "mysql2", dump: [ :ruby, "db/legacy_schema.rb" ]) ]
  }

  describe "an environment whose first database is not the one named primary" do
    let(:root) { fixture("animals_first") }

    it "answers the first database for no name, and the one named primary only by its name, on both tiers" do
      [ booted(root), static(root) ].each do |list|
        expect(list.fetch(nil).name).to eq("animals")
        expect(list.fetch("primary")).to have_attributes(name: "primary", primary: false, adapter: "mysql2")
        expect(list.of_dump_name(nil).name).to eq("animals")
        expect(list.of_dump_name("primary").name).to eq("primary")
      end
    end

    it "reads the first database's settings wherever the primary's are asked for, and the one named primary by its name" do
      previous = [ RailsAiContext.tier, ENV.fetch("RAILS_ENV", nil) ]
      RailsAiContext.tier = :static
      ENV["RAILS_ENV"] = "test"
      conventions = RailsAiContext::Introspectors::SchemaConventions

      RailsAiContext::RunCache.around do
        expect(RailsAiContext::DatabaseYml.primary_name(root)).to eq("animals")
        expect(RailsAiContext::DatabaseYml.primary(root)).to include("adapter" => "postgresql")
        expect(RailsAiContext::DatabaseYml.entry(root, "primary")).to include("database" => "app_test")
        expect(RailsAiContext::Introspectors::SchemaDumpPath.database_name(root, nil)).to eq("animals")
        expect([ conventions.database_adapter_for(root, nil), conventions.database_adapter_for(root, "primary") ]).to eq(%w[postgresql mysql2])
      end
    ensure
      RailsAiContext.tier = previous.first
      ENV["RAILS_ENV"] = previous.last
    end

    it "takes the database ActiveRecord::Base is connected to as the primary on the booted tier, and lists it first" do
      list = booted(root, connected: "primary")

      expect(list.map { |db| [ db.name, db.primary ] }).to eq([ [ "primary", true ], [ "animals", false ] ])
      expect(list.fetch("animals").dump).to have_attributes(format: :ruby, path: File.join(root, "db/schema.rb"))
    end
  end

  it "reads an environment whose whole value is a URL as its one database" do
    Dir.mktmpdir do |root|
      File.write(File.join(FileUtils.mkdir_p(File.join(root, "config")).first, "database.yml"), "test: postgres://app@localhost/app_test\n")

      [ booted(root), static(root) ].each do |list|
        expect(list.map { |db| [ db.name, db.primary, db.here, db.adapter ] }).to eq([ [ "primary", true, true, "postgresql" ] ])
      end
    end
  end

  it "reads database_tasks with no value as Rails does: no tasks" do
    list = described_class.build(
      environments: { "test" => { "primary" => { "adapter" => "sqlite3" }, "legacy" => { "adapter" => "sqlite3", "database_tasks" => nil },
                                  "kept" => { "adapter" => "sqlite3", "database_tasks" => "no" } } },
      current: "test", root: Dir.tmpdir, dumps: []
    )
    rails = ->(value) { ActiveRecord::DatabaseConfigurations::HashConfig.new("test", "x", { adapter: "sqlite3", database_tasks: value }).database_tasks? }

    expect(list.map(&:tasks)).to eq([ true, rails.call(nil), rails.call("no") ])
    expect(list.map(&:tasks)).to eq([ true, false, true ])
  end

  describe "the list's readers" do
    subject(:list) { static(fixture("rails8")) }

    it "answers the primary for no name and names the known ones for an unknown name" do
      expect(list.fetch(nil).name).to eq("primary")
      expect(list.fetch("").name).to eq("primary")
      expect(list.fetch("queue").environments).to eq(%w[production])
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

  it "names the environments the app declares and leaves out a key that only holds an anchor" do
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

  it "leaves out another environment's primary that carries a different name" do
    list = described_class.build(
      environments: {
        "test" => { "primary" => { "adapter" => "sqlite3" } },
        "production" => { "main" => { "adapter" => "postgresql" }, "queue" => { "adapter" => "postgresql" } }
      },
      current: "test", root: Dir.tmpdir, dumps: []
    )

    expect(list.map { |db| [ db.name, db.primary, db.here ] }).to eq([ [ "primary", true, true ], [ "queue", false, false ] ])
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
