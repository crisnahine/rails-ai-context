# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Tools::Onboard do
  before { described_class.reset_cache! }

  # Errbit: no ActiveRecord schema, so the stack line said "on unknown".
  describe "a Mongoid app" do
    it "names Mongoid and the database mongoid.yml names" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "config"))
        File.write(File.join(dir, "config", "mongoid.yml"),
                   "development:\n  clients:\n    default:\n      uri: mongodb://localhost/errbit_development\n")
        allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(dir)))
        allow(described_class).to receive(:cached_context).and_return({ app_name: "Errbit", models: {} })

        text = described_class.call(detail: "standard").content.first[:text]

        expect(text).to include("on MongoDB through Mongoid (database errbit_development)")
      end
    end
  end

  describe "an app with no tables yet" do
    it "names the adapter database.yml declares" do
      Dir.mktmpdir do |dir|
        allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(dir)))
        allow(described_class).to receive(:cached_context).and_return({
          app_name: "Fresh", models: {},
          schema: { unavailable: "No db/schema.rb, db/structure.sql, or migrations found" },
          multi_database: { databases: [ { name: "primary", adapter: "postgresql" } ] }
        })

        text = described_class.call(detail: "standard").content.first[:text]

        expect(text).to include("application on PostgreSQL.")
      end
    end
  end

  describe ".call" do
    it "returns an MCP::Tool::Response" do
      result = described_class.call
      expect(result).to be_a(MCP::Tool::Response)
    end

    it "includes app name in output" do
      result = described_class.call
      text = result.content.first[:text]
      expect(text).to include("Welcome")
    end

    it "quick mode returns a paragraph without section headers" do
      result = described_class.call(detail: "quick")
      text = result.content.first[:text]
      expect(text).not_to include("## ")
      expect(text).to include("Rails")
    end

    it "standard mode includes structured sections" do
      result = described_class.call(detail: "standard")
      text = result.content.first[:text]
      expect(text).to include("## Stack")
      expect(text).to include("## Testing")
      expect(text).to include("## Getting Started")
    end

    # `cd` needs a directory, and an app name underscored is not one.
    it "names the app's own directory in Getting Started" do
      text = described_class.call(detail: "standard").content.first[:text]

      expect(text).to include("cd #{File.basename(RailsAiContext.default_app.root.to_s)}")
    end

    # The Commands section and Getting Started decide the server command in
    # one place, so they cannot name two different ones.
    it "starts the app with the command the generated Commands section names" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "bin"))
        File.write(File.join(dir, "bin", "rails"), "")
        allow(RailsAiContext).to receive(:default_app).and_return(RailsAiContext::StaticApp.new(dir))
        allow(described_class).to receive(:cached_context).and_return({})

        text = described_class.call(detail: "standard").content.first[:text]

        expect(text).to include("bin/rails server")
        expect(text).not_to include("bin/dev")
        expect(text).not_to match(/^rails server$/)
        expect(text).not_to include("db:setup")
      end
    end

    it "full mode includes additional sections beyond standard" do
      result = described_class.call(detail: "full")
      text = result.content.first[:text]
      expect(text).to include("## Stack")
      expect(text).to include("Full Walkthrough")
    end

    # Every model tying on association count is the normal case for an app
    # whose models all include the same concern; with each list sorting on
    # its own the two named disjoint sets of "key" models.
    it "names the same key models as the generated context file when every model ties" do
      models = %w[Zebra Alpha Mango Beta Kiwi Delta Echo Foxtrot].each_with_object({}) do |name, h|
        h[name] = { table_name: name.downcase, associations: [ { type: "belongs_to", name: "user" } ], validations: [] }
      end
      ctx = {
        app_name: "TiedApp", rails_version: "8.0", ruby_version: "3.4",
        generated_at: Time.now.iso8601, schema: {}, models: models,
        routes: {}, gems: {}, conventions: {}
      }
      allow(described_class).to receive(:cached_context).and_return(ctx)

      onboard = described_class.call(detail: "standard").content.first[:text]
      generated = RailsAiContext::Serializers::ClaudeSerializer.new(ctx).call

      order = ->(text) { models.keys.select { |name| text.include?("**#{name}**") }.sort_by { |name| text.index("**#{name}**") } }
      expect(order.call(onboard)).to eq(order.call(generated).first(7))
      expect(order.call(onboard).first).to eq("Alpha")
    end

    # A payload entry is not always a Hash: a section the introspector could
    # not build leaves a marker string. Counted as central it took one of the
    # seven slots and printed nothing, so a real model fell off the list.
    it "spends no central slot on an entry that is not a model record" do
      models = { "AAABroken" => "[UNAVAILABLE]" }
      ("A".."H").each_with_index { |l, i| models["Model#{l}"] = { table_name: "t#{i}", associations: [], validations: [] } }
      ctx = {
        app_name: "OddApp", rails_version: "8.0", ruby_version: "3.4",
        generated_at: Time.now.iso8601, schema: {}, models: models,
        routes: {}, gems: {}, conventions: {}
      }
      allow(described_class).to receive(:cached_context).and_return(ctx)

      text = described_class.call(detail: "standard").content.first[:text]

      expect(text.scan(/\*\*Model[A-H]\*\*/).size).to eq(7)
      expect(text).not_to include("AAABroken")
    end

    # The ranking reads every entry, and a model whose file could not be read
    # carries an error hash rather than an association list.
    it "ranks past a model whose introspection failed without naming it central" do
      models = {
        "Broken" => { error: "file is unreadable" },
        "Widget" => { table_name: "widgets", associations: [ { type: "has_many", name: "parts" } ], validations: [] }
      }
      ctx = {
        app_name: "PartialApp", rails_version: "8.0", ruby_version: "3.4",
        generated_at: Time.now.iso8601, schema: {}, models: models,
        routes: {}, gems: {}, conventions: {}
      }
      allow(described_class).to receive(:cached_context).and_return(ctx)

      onboard = described_class.call(detail: "standard").content.first[:text]
      generated = RailsAiContext::Serializers::ClaudeSerializer.new(ctx).call

      expect(onboard).to include("**Widget**")
      expect(onboard).not_to include("**Broken**")
      expect(generated).to include("- **Broken** [UNAVAILABLE: file is unreadable]")
    end

    it "handles missing context data gracefully" do
      allow(described_class).to receive(:cached_context).and_return({
        app_name: "TestApp",
        rails_version: "8.0",
        ruby_version: "3.4"
      })
      result = described_class.call(detail: "standard")
      text = result.content.first[:text]
      expect(text).to include("TestApp")
      expect(text).not_to include("error")
    end

    # Statically the ruby version is the one the lockfile declares, and
    # nothing is running it.
    it "says the static tier's ruby version is declared, not running" do
      allow(described_class).to receive(:cached_context).and_return({
        app_name: "TestApp",
        rails_version: "8.0",
        ruby_version: "3.4",
        gems: { declared_ruby_version: "3.4" },
        tier: "static"
      })

      text = described_class.call(detail: "standard").content.first[:text]

      expect(text).to include("declaring Ruby 3.4")
      expect(text).not_to include("running Ruby")
    end

    # With no RUBY VERSION in the lockfile and no ruby line in the Gemfile the
    # introspector refuses rather than naming the interpreter running the CLI,
    # which the app declared nowhere.
    it "claims no declared ruby version when nothing declares one" do
      allow(described_class).to receive(:cached_context).and_return({
        app_name: "TestApp",
        rails_version: "8.0",
        ruby_version: RailsAiContext::Confidence.unavailable("app declares none"),
        gems: { declared_ruby_version: nil },
        tier: "static"
      })

      text = described_class.call(detail: "standard").content.first[:text]

      expect(text).to include("TestApp is a Rails 8.0 application on")
      expect(text).not_to include("Ruby #{RUBY_VERSION}")
    end

    # Both depths describe the same app, so the depth that says less must not
    # be the one that claims more.
    it "keeps quick silent about a ruby version the app declares nowhere" do
      allow(described_class).to receive(:cached_context).and_return({
        app_name: "TestApp",
        rails_version: "8.0",
        ruby_version: RailsAiContext::Confidence.unavailable("app declares none"),
        gems: { declared_ruby_version: nil },
        tier: "static"
      })

      text = described_class.call(detail: "quick").content.first[:text]

      expect(text).to include("TestApp** is a Rails 8.0 app")
      expect(text).not_to include("UNAVAILABLE")
    end

    # The Ruby half degrades by dropping its clause; the Rails half was
    # interpolated raw, so a lockfile naming no rails wrote
    # "is a Rails [UNAVAILABLE: app not booted] application on sqlite"
    # into a file the user commits.
    it "names no Rails version rather than writing the marker mid-sentence" do
      allow(described_class).to receive(:cached_context).and_return({
        app_name: "TestApp",
        rails_version: RailsAiContext::Confidence.unavailable("app not booted"),
        ruby_version: "3.4",
        gems: { declared_ruby_version: "3.4" },
        tier: "static"
      })

      standard = described_class.call(detail: "standard").content.first[:text]
      quick = described_class.call(detail: "quick").content.first[:text]

      expect(standard).to include("TestApp is a Rails application declaring Ruby 3.4 on")
      expect(quick).to include("**TestApp** is a Rails app")
      [ standard, quick ].each { |text| expect(text.lines.first(4).join).not_to include("UNAVAILABLE") }
    end

    it "says a booted run is running that ruby" do
      allow(described_class).to receive(:cached_context).and_return({
        app_name: "TestApp",
        rails_version: "8.0",
        ruby_version: "3.4",
        tier: "booted"
      })

      expect(described_class.call(detail: "standard").content.first[:text]).to include("running Ruby 3.4")
    end

    it "renders mounted engines from the introspector's own keys" do
      allow(described_class).to receive(:cached_context).and_return({
        app_name: "TestApp",
        rails_version: "8.0",
        ruby_version: "3.4",
        engines: { mounted_engines: [ { engine: "Sidekiq::Web", path: "/sidekiq" } ] }
      })
      text = described_class.call(detail: "full").content.first[:text]
      expect(text).to include("## Mounted Apps")
      expect(text).to include("Sidekiq::Web")
    end

    it "names a mounted app with no known path without inventing one" do
      allow(described_class).to receive(:cached_context).and_return({
        app_name: "TestApp",
        rails_version: "8.0",
        ruby_version: "3.4",
        engines: { mounted_engines: [ { engine: "Sidekiq::Web", path: nil } ] }
      })
      text = described_class.call(detail: "full").content.first[:text]
      expect(text).to include("- **Sidekiq::Web**\n")
      expect(text).not_to include("Sidekiq::Web** at")
    end

    it "renders real-time features from the introspector's own keys" do
      allow(described_class).to receive(:cached_context).and_return({
        app_name: "TestApp",
        rails_version: "8.0",
        ruby_version: "3.4",
        turbo: {
          model_broadcasts: [ { model: "Post" } ],
          turbo_streams: [ "posts/create.turbo_stream.erb" ]
        }
      })
      text = described_class.call(detail: "full").content.first[:text]
      expect(text).to include("Turbo Stream broadcasts: 1 broadcast point.")
      expect(text).to include("Turbo Stream templates: 1.")
    end

    context "quick mode" do
      it "includes frontend summary from architecture conventions" do
        allow(described_class).to receive(:cached_context).and_return({
          app_name: "MyApp",
          rails_version: "8.0",
          ruby_version: "3.4",
          schema: { adapter: "SQLite", total_tables: 5 },
          models: { "User" => { associations: [] } },
          jobs: { jobs: [] },
          conventions: { architecture: %w[hotwire phlex stimulus] },
          gems: { notable_gems: [] },
          tests: { framework: "minitest" }
        })
        result = described_class.call(detail: "quick")
        text = result.content.first[:text]

        expect(text).to include("Hotwire + Phlex frontend")
      end

      it "names the rspec command when the app runs both suites" do
        allow(described_class).to receive(:cached_context).and_return({
          app_name: "MyApp",
          rails_version: "8.0",
          ruby_version: "3.4",
          schema: { adapter: "SQLite", total_tables: 5 },
          models: {},
          jobs: { jobs: [] },
          conventions: { architecture: [] },
          gems: { notable_gems: [] },
          tests: { framework: "rspec, minitest", factories: nil }
        })

        text = described_class.call(detail: "standard").content.first[:text]

        expect(text).to include("bundle exec rspec")
        expect(text).not_to include("rails test")
      end

      it "says the app has no tests rather than naming a framework it does not run" do
        allow(described_class).to receive(:cached_context).and_return({
          app_name: "Lab", rails_version: "8.0", ruby_version: "3.4",
          schema: { adapter: "SQLite", total_tables: 2 }, models: {}, jobs: { jobs: [] },
          conventions: { architecture: [] }, gems: { notable_gems: [] },
          tests: { framework: "no tests yet (minitest in the bundle)" }
        })

        text = described_class.call(detail: "quick").content.first[:text]

        expect(text).to include("no tests yet")
        expect(text).not_to include("tested with")
      end

      # One factory file commonly defines several factories, and the count
      # said the number of files.
      it "counts factory definitions, and names the files they sit in" do
        allow(described_class).to receive(:cached_context).and_return({
          app_name: "Api", rails_version: "8.0", ruby_version: "3.4",
          schema: { adapter: "PostgreSQL", total_tables: 2 }, models: {}, jobs: { jobs: [] },
          conventions: { architecture: [] }, gems: { notable_gems: [] },
          tests: { framework: "rspec", factories: { location: "spec/factories", count: 2 },
                   factory_names: { "spec/factories/users.rb" => %w[user admin], "spec/factories/posts.rb" => %w[post] } }
        })

        text = described_class.call(detail: "standard").content.first[:text]

        expect(text).to include("Data setup: FactoryBot (3 factories in 2 files).")
      end

      it "marks the factory count a floor when some names are computed" do
        allow(described_class).to receive(:cached_context).and_return({
          app_name: "Api", rails_version: "8.0", ruby_version: "3.4",
          schema: { adapter: "PostgreSQL", total_tables: 2 }, models: {}, jobs: { jobs: [] },
          conventions: { architecture: [] }, gems: { notable_gems: [] },
          tests: { framework: "rspec", factories: { location: "spec/factories", count: 1 },
                   factory_names: { "spec/factories/comments.rb" => %w[comment] }, computed_factories: 1 }
        })

        text = described_class.call(detail: "standard").content.first[:text]

        expect(text).to include("Data setup: FactoryBot (2+ factories in 1 file).")
      end

      it "names Fabrication when the suite builds its data with fabricators" do
        allow(described_class).to receive(:cached_context).and_return({
          app_name: "Api", rails_version: "8.0", ruby_version: "3.4",
          schema: { adapter: "PostgreSQL", total_tables: 2 }, models: {}, jobs: { jobs: [] },
          conventions: { architecture: [] }, gems: { notable_gems: [] },
          tests: { framework: "rspec", fabricators: { location: "spec/fabricators", count: 2 },
                   fabricator_names: { "spec/fabricators/user_fabricator.rb" => %w[user admin], "spec/fabricators/post_fabricator.rb" => %w[post] } }
        })

        text = described_class.call(detail: "standard").content.first[:text]

        expect(text).to include("Data setup: Fabrication (3 fabricators in 2 files).")
      end

      it "names no guessed domain, only the app" do
        allow(described_class).to receive(:cached_context).and_return({
          app_name: "Acme",
          rails_version: "8.0",
          ruby_version: "3.4",
          schema: { adapter: "SQLite", total_tables: 4 },
          models: { "Message" => { associations: [] }, "User" => { associations: [] } },
          jobs: { jobs: [] },
          conventions: { architecture: [] },
          gems: { notable_gems: [] },
          tests: { framework: "minitest" }
        })

        text = described_class.call(detail: "quick").content.first[:text]

        expect(text).to include("**Acme** is a Rails 8.0 / Ruby 3.4 app -")
        expect(text).not_to include("messaging")
      end

      it "shows actual table count instead of adapter name" do
        allow(described_class).to receive(:cached_context).and_return({
          app_name: "TestApp",
          rails_version: "8.0",
          ruby_version: "3.4",
          schema: { adapter: "static_parse", total_tables: 25 },
          models: {},
          jobs: { jobs: [] },
          conventions: { architecture: [] },
          gems: { notable_gems: [] },
          tests: { framework: "minitest" }
        })
        result = described_class.call(detail: "quick")
        text = result.content.first[:text]

        expect(text).to include("25 tables")
        expect(text).not_to include("static_parse")
      end
    end

    # An app whose async work runs through Sidekiq workers has nothing in
    # app/jobs, and the section read as if it had no background work.
    context "the async section on an app with no ActiveJob jobs" do
      before do
        allow(described_class).to receive(:cached_context).and_return({
          app_name: "TestApp",
          jobs: { jobs: [], mailers: [ { name: "UserMailer" } ], channels: [] }
        })
      end

      it "states the limit the job listing states" do
        text = described_class.call(detail: "standard").content.first[:text]

        expect(text).to include("## Background Jobs & Async")
        expect(text).to include(RailsAiContext::Tools::GetJobPattern::NOT_COVERED)
      end

      # The workers sit in the same hash the section reads, and job_pattern
      # lists them, so a section that names only the mailer points the reader
      # away from where the app's background work actually is.
      it "names the Sidekiq workers the same hash carries" do
        allow(described_class).to receive(:cached_context).and_return({
          app_name: "TestApp",
          jobs: {
            jobs: [], mailers: [], channels: [],
            workers: [ { name: "Billing::Invoices::CreateWorker", file: "app/workers/billing/invoices/create_worker.rb" } ]
          }
        })

        text = described_class.call(detail: "standard").content.first[:text]

        expect(text).to include("## Background Jobs & Async")
        expect(text).to include("1 Sidekiq worker")
        expect(text).to include("Billing::Invoices::CreateWorker")
      end

      it "counts the workers in the one-line overview" do
        allow(described_class).to receive(:cached_context).and_return({
          app_name: "TestApp",
          jobs: { jobs: [], mailers: [], channels: [], workers: [ { name: "Billing::Invoices::CreateWorker" } ] }
        })

        expect(described_class.call(detail: "quick").content.first[:text]).to include("1 Sidekiq worker")
      end

      it "leaves the caveat off when the workers are the background work" do
        allow(described_class).to receive(:cached_context).and_return({
          app_name: "TestApp",
          jobs: {
            jobs: [], mailers: [], channels: [],
            workers: [ { name: "Billing::Invoices::CreateWorker" } ]
          }
        })

        text = described_class.call(detail: "standard").content.first[:text]

        expect(text).not_to include(RailsAiContext::Tools::GetJobPattern::NOT_COVERED)
      end

      it "leaves the caveat off when jobs were found" do
        allow(described_class).to receive(:cached_context).and_return({
          app_name: "TestApp",
          jobs: { jobs: [ { name: "ImportJob" } ], mailers: [], channels: [] }
        })

        text = described_class.call(detail: "standard").content.first[:text]

        expect(text).not_to include(RailsAiContext::Tools::GetJobPattern::NOT_COVERED)
      end
    end

    context "route count parity with rails_get_routes" do
      it "reports the same app route total as the routes tool (PUT/PATCH deduped)" do
        RailsAiContext::Tools::GetRoutes.reset_cache!

        routes_text = RailsAiContext::Tools::GetRoutes.call(detail: "standard").content.first[:text]
        routes_total = routes_text[/# Routes \((\d+) route/, 1].to_i
        expect(routes_total).to be > 0

        onboard_text = described_class.call(detail: "standard").content.first[:text]
        onboard_total = onboard_text[/Total: (\d+) app routes/, 1].to_i

        expect(onboard_total).to eq(routes_total)
      end
    end
  end

  describe "section lists" do
    it "names a section builder for every listed section" do
      listed = (described_class::STANDARD_SECTIONS + described_class::FULL_SECTIONS).uniq
      missing = listed.reject { |name| described_class.private_methods.include?(:"section_#{name}") }

      expect(missing).to be_empty
    end
  end
  # The lists are the render order, which the builder guard above cannot see.
  describe "section order" do
    def headings(detail)
      described_class.call(detail: detail).content.first[:text].scan(/^## (.+)$/).flatten
    end

    it "renders the standard walkthrough in STANDARD_SECTIONS order" do
      expect(headings("standard")).to eq(
        [ "Stack", "Data Model", "Key Flows", "Background Jobs & Async", "Frontend", "Testing", "Getting Started" ]
      )
    end

    it "renders the full walkthrough in FULL_SECTIONS order" do
      expect(headings("full")).to eq(
        [ "Stack", "Data Model", "Key Flows", "Background Jobs & Async", "Frontend", "Real-Time Features",
          "File Storage & Rich Text", "API", "Deployment & DevOps", "Testing", "Getting Started" ]
      )
    end
  end
end
