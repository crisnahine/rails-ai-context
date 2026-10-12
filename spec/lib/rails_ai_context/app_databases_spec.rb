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
            family: RailsAiContext::DatabaseFamily.of(adapter), dump: nil, migrate_dirs: [ "db/migrate" ], adapter_default: false)
    { name: name, environment: environment, here: here, primary: primary, replica: replica, tasks: tasks, adapter: adapter,
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
    [ entry(root, "primary", primary: true, adapter: "sqlite3", dump: [ :ruby, "db/schema.rb" ]),
      *%w[cache queue cable].map do |db|
        entry(root, db, environment: "production", here: false, adapter: "sqlite3", dump: [ :ruby, "db/#{db}_schema.rb" ], migrate_dirs: [])
      end ]
  }

  it_behaves_like "the same list on both tiers", "url_primary", lambda { |root|
    [ entry(root, "primary", primary: true, adapter: "postgresql", dump: [ :ruby, "db/schema.rb" ]) ]
  }

  it_behaves_like "the same list on both tiers", "replica", lambda { |root|
    [ entry(root, "primary", primary: true, adapter: "mysql2", dump: [ :ruby, "db/schema.rb" ]),
      entry(root, "primary_replica", replica: true, tasks: false, adapter: "mysql2") ]
  }

  it_behaves_like "the same list on both tiers", "no_tasks", lambda { |root|
    [ entry(root, "primary", primary: true, adapter: "postgresql", dump: [ :ruby, "db/schema.rb" ]),
      entry(root, "legacy", tasks: false, adapter: "mysql2") ]
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

  it "builds once per run" do
    RailsAiContext::RunCache.around do
      expect(described_class.for(fixture("rails8"))).to equal(described_class.for(fixture("rails8")))
    end
  end
end
