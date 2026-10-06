# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Tools::Onboard do
  before { described_class.reset_cache! }

  it "keeps its gem lists on the tool class, where a caller can name them" do
    expect(described_class::AUTHZ_GEMS).to include("pundit", "action_policy")
    expect(described_class::AUTH_GEMS).to include("devise")
    expect(described_class::RAKE_TASKS_SHOWN).to eq(15)
  end

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

  describe "an engine's test/dummy whose bundle is outside the repository" do
    it "says the engine's tests are not read, not that there are none" do
      Dir.mktmpdir do |engine|
        dummy = File.join(engine, "test", "dummy")
        FileUtils.mkdir_p(File.join(dummy, "config"))
        File.write(File.join(dummy, "config", "boot.rb"), %(ENV["BUNDLE_GEMFILE"] ||= File.expand_path("../../../Gemfile", __dir__)\n))
        File.write(File.join(engine, "shop.gemspec"), "")
        File.write(File.join(engine, "Gemfile"), "gemspec\n")
        File.write(File.join(engine, "test", "test_helper.rb"), "")
        allow(RailsAiContext::PathResolver).to receive(:enclosing_engine_roots).and_return([])
        app = RailsAiContext::StaticApp.new(dummy)
        allow(described_class).to receive(:rails_app).and_return(app)
        tests = RailsAiContext::Introspectors::TestIntrospector.new(app).call
        allow(described_class).to receive(:cached_context).and_return({ app_name: "Dummy", models: {}, tests: tests })

        standard = described_class.call(detail: "standard").content.first[:text]
        quick = described_class.call(detail: "quick").content.first[:text]

        expect(standard).to include("Framework: not read.")
        expect(standard).not_to include("no tests yet", "Data setup: inline")
        expect(quick).to include("with its tests not read")
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

  describe "an app that does not load Active Record" do
    it "says so instead of naming an unknown database" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "config"))
        File.write(File.join(dir, "config/application.rb"), "require \"rails\"\nrequire \"active_model/railtie\"\n# require \"active_record/railtie\"\nrequire \"action_controller/railtie\"\n")
        allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(dir)))
        allow(described_class).to receive(:cached_context).and_return({
          app_name: "NoAr", models: {},
          schema: { unavailable: "this app does not load Active Record; ActiveRecord schema introspection does not apply" }
        })

        text = described_class.call(detail: "standard").content.first[:text]

        expect(text).to include("application without Active Record.")
        expect(text).not_to include("unknown")
      end
    end
  end

  describe "the Deployment & DevOps section of a default Rails 8 app" do
    it "reads the devops introspector's keys: Dockerfile present, no Procfile, Kamal" do
      Dir.mktmpdir do |dir|
        allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(dir)))
        allow(described_class).to receive(:cached_context).and_return(
          { app_name: "App", models: {},
            devops: { puma: nil, procfile: [], health_check: true, docker: { base_images: [ "ruby" ], multi_stage: true, compose: false }, deployment: "kamal" },
            active_storage: { attachments: [] }, action_text: { models: [] } }
        )

        text = described_class.call(detail: "full").content.first[:text]

        expect(text).to include("Dockerfile: present.")
        expect(text).not_to include("Procfile: present.")
        expect(text).to include("Deployment: kamal.")
        expect(text).not_to include("## File Storage & Rich Text")
      end
    end

    it "names a Procfile.dev on its own, never as a Procfile" do
      Dir.mktmpdir do |dir|
        allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(dir)))
        allow(described_class).to receive(:cached_context).and_return(
          { app_name: "App", models: {},
            devops: { puma: nil, procfile: [ { file: "Procfile.dev", entries: [ { name: "web", command: "bin/rails server" } ] } ],
                      health_check: true, docker: nil, deployment: nil },
            active_storage: { attachments: [] }, action_text: { models: [] } }
        )

        text = described_class.call(detail: "full").content.first[:text]

        expect(text).to include("Procfile: not found.", "Procfile.dev: present.")
      end
    end
  end

  describe "the app's custom rake tasks" do
    def onboard(detail, tasks)
      Dir.mktmpdir do |dir|
        allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(dir)))
        allow(described_class).to receive(:cached_context).and_return({ app_name: "App", models: {}, rake_tasks: { tasks: tasks } })
        described_class.call(detail: detail).content.first[:text]
      end
    end

    it "lists each task with its arguments, description and file" do
      tasks = [ { name: "ops:backfill", description: "Backfill totals", file: "lib/tasks/ops.rake", args: [ "batch" ] } ]

      %w[standard full].each do |detail|
        text = onboard(detail, tasks)
        expect(text).to include("## Rake Tasks")
        expect(text).to include("- `ops:backfill[batch]` - Backfill totals (`lib/tasks/ops.rake`)")
      end
    end

    it "caps the standard walkthrough and lists every task in full" do
      tasks = Array.new(30) { |i| { name: "ops:t#{i}", file: "lib/tasks/ops.rake" } }

      expect(onboard("standard", tasks)).to include("`ops:t14`").and include("...15 more: `detail:\"full\"` lists every task.")
      expect(onboard("standard", tasks)).not_to include("`ops:t15`")
      expect(onboard("full", tasks)).to include("`ops:t29`")
    end

    it "names a task file it could not read" do
      text = onboard("full", [ { file: "lib/tasks/bad.rake", error: "unreadable" } ])

      expect(text).to include("- `lib/tasks/bad.rake`: not read (unreadable)")
    end

    it "leaves the section out when the app defines no task" do
      expect(onboard("standard", [])).not_to include("## Rake Tasks")
    end
  end

  describe "the app's generators and Railties" do
    def onboard(detail, rake_tasks)
      Dir.mktmpdir do |dir|
        allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(dir)))
        allow(described_class).to receive(:cached_context).and_return({ app_name: "App", models: {}, rake_tasks: rake_tasks })
        described_class.call(detail: detail).content.first[:text]
      end
    end

    it "names each generator command, each template override and each Railtie" do
      data = {
        tasks: [],
        generators: [ { command: "bin/rails generate service", file: "lib/generators/service/service_generator.rb", usage: "Creates a service object." } ],
        generator_templates: [ { file: "lib/templates/active_record/model/model.rb.tt", generator: "active_record:model" } ],
        railties: [ { name: "MyThing::Railtie", file: "lib/my_thing/railtie.rb", initializers: [ "my_thing.setup" ], rake_tasks: true } ]
      }

      %w[standard full].each do |detail|
        text = onboard(detail, data)
        expect(text).to include("## Generators and Railties")
        expect(text).to include("- `bin/rails generate service` - Creates a service object. (`lib/generators/service/service_generator.rb`)")
        expect(text).to include("- `lib/templates/active_record/model/model.rb.tt` replaces the template the `active_record:model` generator writes")
        expect(text).to include("- Railtie `MyThing::Railtie` (`lib/my_thing/railtie.rb`): initializers `my_thing.setup`; adds rake tasks")
      end
    end

    it "leaves the section out when the app has none" do
      expect(onboard("standard", { tasks: [] })).not_to include("## Generators and Railties")
    end
  end

  describe "the auth section" do
    def onboard_with(ctx)
      allow(described_class).to receive(:cached_context).and_return({ app_name: "App", models: {} }.merge(ctx))
      described_class.call(detail: "full").content.first[:text]
    end

    it "names what the auth introspector found: Rodauth and Action Policy" do
      text = onboard_with(auth: { authentication: { rodauth: { classes: [ "RodauthMain" ] } },
                                  authorization: { action_policy: [ "ApplicationPolicy" ] } })

      expect(text).to include("## Authentication & Authorization")
      expect(text).to include("Authentication via Rodauth (RodauthMain).")
      expect(text).to include("Authorization via Action Policy (1 policy).")
    end

    it "names Rails' generated authentication" do
      text = onboard_with(auth: { authentication: { rails_auth: { detected: true }, has_secure_password: [ "User" ] },
                                  authorization: {} })

      expect(text).to include("Authentication via the Rails authentication generator (Session and Current models).")
      expect(text).to include("has_secure_password on User.")
    end

    it "still names the authentication gem when the introspector found only policy classes" do
      text = onboard_with(auth: { authentication: {}, authorization: { policies: %w[APolicy BPolicy] } },
                          gems: { notable_gems: [ { name: "omniauth", version: "1.9.2", category: "auth" } ] })

      expect(text).to include("Authentication via omniauth (1.9.2).")
      expect(text).to include("2 policy classes in app/policies.")
    end

    it "names the Devise model and its modules" do
      text = onboard_with(auth: { authentication: { devise: [ { model: "User", matches: [ ":database_authenticatable, :lockable" ] } ] },
                                  authorization: {},
                                  devise_modules_per_model: { "User" => %w[database_authenticatable lockable] } })

      expect(text).to include("Authentication via Devise on User (database_authenticatable, lockable).")
    end

    it "counts serializer classes, not the keys of the serializers hash" do
      text = onboard_with(api: { serializers: { serializer_classes: %w[ASerializer BSerializer CSerializer] } })

      expect(text).to include("Serialization: 3 serializer classes (ASerializer, BSerializer, CSerializer).")
    end

    it "names jbuilder templates and an own serializer layer the way the api tool does" do
      expect(onboard_with(api: { serializers: { jbuilder: 6 } })).to include("## API\n\nSerialization: Jbuilder (6 templates).")
      own = onboard_with(api: { serializers: { serializer_dirs: [ { path: "app/services/serializers", files: 93 } ] } })
      expect(own).to include("app/services/serializers (93 files)")
    end

    it "leaves the API section out when there is no API layer to name" do
      expect(onboard_with(api: { serializers: {}, graphql: nil, api_only: false })).not_to include("## API")
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

    it "names the Ruby engine the app declares, with the Ruby version it implements" do
      allow(described_class).to receive(:cached_context).and_return({
        app_name: "Fx", rails_version: "8.1.4", ruby_version: "3.1.4",
        ruby_engine: "JRuby 9.4.8.0", tier: "static"
      })

      standard = described_class.call(detail: "standard").content.first[:text]
      quick = described_class.call(detail: "quick").content.first[:text]

      expect(standard).to include("Fx is a Rails 8.1.4 application declaring JRuby 9.4.8.0 (Ruby 3.1.4) on")
      expect(quick).to include("**Fx** is a Rails 8.1.4 / JRuby 9.4.8.0 (Ruby 3.1.4) app")
    end

    it "names the engine alone when the app declares no Ruby version" do
      allow(described_class).to receive(:cached_context).and_return({
        app_name: "Fx", rails_version: "8.1.4",
        ruby_version: RailsAiContext::Confidence.unavailable("app declares none"),
        ruby_engine: "JRuby 9.4.8.0", tier: "static"
      })

      text = described_class.call(detail: "standard").content.first[:text]

      expect(text).to include("Fx is a Rails 8.1.4 application declaring JRuby 9.4.8.0 on")
    end

    it "says the gems are not read when boot.rb names a Gemfile outside the app" do
      allow(described_class).to receive(:cached_context).and_return({
        app_name: "Dummy", rails_version: RailsAiContext::Confidence.unavailable("x"),
        ruby_version: RailsAiContext::Confidence.unavailable("app declares none"), tier: "static"
      })
      allow(RailsAiContext::GemLock).to receive(:for).and_return(
        RailsAiContext::GemLock::Spec.new({}, reason: "x", absent: true, outside_gemfile: "../../Gemfile")
      )

      %w[quick standard].each do |detail|
        text = described_class.call(detail: detail).content.first[:text]

        expect(text).to include("Its gems and Rails version are not read: config/boot.rb points Bundler at `../../Gemfile`, outside the app's git repository.")
      end
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

    it "names the condition a mount is drawn under" do
      allow(described_class).to receive(:cached_context).and_return({
        app_name: "TestApp", rails_version: "8.0", ruby_version: "3.4",
        engines: { mounted_engines: [ { engine: "Lookbook::Engine", path: "/lookbook", condition: "if Rails.env.development?" } ] }
      })
      text = described_class.call(detail: "full").content.first[:text]
      expect(text).to include("- **Lookbook::Engine** at `/lookbook` (`if Rails.env.development?`)\n")
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
        [ "Stack", "Data Model", "Key Flows", "Background Jobs & Async", "Frontend", "Testing", "Getting Started", "Rake Tasks" ]
      )
    end

    it "renders the full walkthrough in FULL_SECTIONS order" do
      expect(headings("full")).to eq(
        [ "Stack", "Data Model", "Key Flows", "Background Jobs & Async", "Frontend", "Real-Time Features",
          "Deployment & DevOps", "Testing", "Getting Started", "Rake Tasks" ]
      )
    end
  end
end
