# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Tools::AnalyzeFeature do
  before { described_class.reset_cache! }

  let(:mock_context) do
    {
      models: {
        "User" => {
          table_name: "users",
          associations: [
            { type: "has_many", name: "posts" },
            { type: "has_one", name: "profile" }
          ],
          validations: [
            { kind: "presence", attributes: %w[email] },
            { kind: "uniqueness", attributes: %w[email] }
          ],
          scopes: %w[active admins]
        },
        "UserSession" => {
          table_name: "user_sessions",
          associations: [ { type: "belongs_to", name: "user" } ],
          validations: [],
          scopes: []
        },
        "Post" => {
          table_name: "posts",
          associations: [ { type: "belongs_to", name: "user" } ],
          validations: [ { kind: "presence", attributes: %w[title] } ],
          scopes: %w[published]
        }
      },
      schema: {
        adapter: "postgresql",
        tables: {
          "users" => {
            columns: [
              { name: "id", type: "bigint" },
              { name: "email", type: "string" },
              { name: "name", type: "string" },
              { name: "created_at", type: "datetime" },
              { name: "updated_at", type: "datetime" }
            ],
            indexes: [ { name: "idx_users_email", columns: [ "email" ], unique: true } ],
            foreign_keys: []
          },
          "user_sessions" => {
            columns: [
              { name: "id", type: "bigint" },
              { name: "user_id", type: "bigint" },
              { name: "token", type: "string" },
              { name: "created_at", type: "datetime" },
              { name: "updated_at", type: "datetime" }
            ],
            indexes: [],
            foreign_keys: [ { column: "user_id", to_table: "users", primary_key: "id" } ]
          },
          "posts" => {
            columns: [
              { name: "id", type: "bigint" },
              { name: "title", type: "string" },
              { name: "user_id", type: "bigint" },
              { name: "created_at", type: "datetime" },
              { name: "updated_at", type: "datetime" }
            ],
            indexes: [],
            foreign_keys: [ { column: "user_id", to_table: "users", primary_key: "id" } ]
          }
        }
      },
      controllers: {
        controllers: {
          "UsersController" => {
            actions: %w[index show create],
            filters: [ { kind: "before_action", name: "authenticate!" } ],
            parent_class: "ApplicationController"
          },
          "UserSessionsController" => {
            actions: %w[new create destroy],
            filters: [],
            parent_class: "ApplicationController"
          },
          "PostsController" => {
            actions: %w[index show new create edit update destroy],
            filters: [ { kind: "before_action", name: "set_post", only: %w[show edit update destroy] } ],
            parent_class: "ApplicationController"
          }
        }
      },
      routes: {
        by_controller: {
          "users" => [
            { verb: "GET", path: "/users", action: "index", name: "users" },
            { verb: "GET", path: "/users/:id", action: "show", name: "user" },
            { verb: "POST", path: "/users", action: "create", name: nil }
          ],
          "user_sessions" => [
            { verb: "GET", path: "/login", action: "new", name: "new_user_session" },
            { verb: "POST", path: "/login", action: "create", name: "user_session" },
            { verb: "DELETE", path: "/logout", action: "destroy", name: "destroy_user_session" }
          ],
          "posts" => [
            { verb: "GET", path: "/posts", action: "index", name: "posts" },
            { verb: "GET", path: "/posts/:id", action: "show", name: "post" }
          ]
        }
      }
    }
  end

  before do
    allow(described_class).to receive(:cached_context).and_return(mock_context)
    allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(Dir.pwd)))
  end

  describe ".call" do
    it "returns matching models with schema, associations, validations, and scopes" do
      result = described_class.call(feature: "user")
      text = result.content.first[:text]

      expect(text).to include("Feature Analysis: user")
      expect(text).to include("Models (2)")
      expect(text).to include("### User")
      expect(text).to include("### UserSession")
      expect(text).to include("email:string")
      expect(text).to include("has_many :posts")
      expect(text).to include("presence on email")
      expect(text).to include("active, admins")
      expect(text).to include("active, admins")
    end

    it "returns matching controllers with actions and filters" do
      result = described_class.call(feature: "user")
      text = result.content.first[:text]

      expect(text).to include("Controllers (2)")
      expect(text).to include("### UsersController")
      expect(text).to include("### UserSessionsController")
      expect(text).to include("index, show, create")
      expect(text).to include("before_action authenticate!")
    end

    it "returns matching routes" do
      result = described_class.call(feature: "user")
      text = result.content.first[:text]

      expect(text).to include("Routes (6)")
      expect(text).to include("`GET` `/users`")
      expect(text).to include("`POST` `/login`")
      expect(text).to include("`DELETE` `/logout`")
    end

    it "passes a glob segment to a route's helper, since Rails requires it" do
      mock_context[:routes][:by_controller]["docs"] = [ { verb: "GET", path: "/docs/*section", action: "show", name: "doc" } ]

      text = described_class.call(feature: "docs").content.first[:text]

      expect(text).to include("`GET` `/docs/*section` → docs#show `doc_path(:section)`")
    end

    it "returns clean no-match message when feature has no hits" do
      result = described_class.call(feature: "zzz_nonexistent")
      text = result.content.first[:text]

      expect(text).to include("No matches found for 'zzz_nonexistent'")
      expect(text).to include("Try one of your model names:")
    end

    # Ten seconds of word-matching a 100 KB keyword against every layer,
    # then the keyword echoed back whole.
    it "answers a keyword no feature name could be at once, shortened" do
      expect(described_class).not_to receive(:discover_models)

      text = described_class.call(feature: "a" * 100_000).content.first[:text]

      expect(text).to eq("No matches found for '#{"a" * 80}... (100000 characters)'. A feature keyword is a word or two, such as 'payment'.")
    end

    it "handles missing introspection data gracefully" do
      allow(described_class).to receive(:cached_context).and_return({})
      allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(Dir.pwd)))
      result = described_class.call(feature: "anything")
      text = result.content.first[:text]

      expect(text).to include("No matches found for 'anything'")
    end

    it "performs case-insensitive matching" do
      result = described_class.call(feature: "POST")
      text = result.content.first[:text]

      expect(text).to include("### Post")
      expect(text).to include("### PostsController")
      expect(text).to include("`GET` `/posts`")
    end

    it "does not treat an unrelated word that merely starts the same as a match" do
      context_with_mailbox_route = mock_context.deep_dup
      context_with_mailbox_route[:routes][:by_controller]["action_mailbox/ingresses/postmark/inbound_emails"] = [
        { verb: "POST", path: "/rails/action_mailbox/postmark/inbound_emails", action: "create", name: "rails_postmark_inbound_emails" }
      ]
      allow(described_class).to receive(:cached_context).and_return(context_with_mailbox_route)

      result = described_class.call(feature: "post")
      text = result.content.first[:text]

      expect(text).to include("### Post")
      expect(text).not_to include("postmark")
    end

    # A gap is a claim that something has no test, so it needs every test's
    # name: on an app with more specs than the cap, the ones covering the
    # feature sort past the first 500.
    [ true, false ].each do |tested|
      it "#{tested ? "finds" : "misses"} the test of a controller past the first 500 specs, and claims a gap only when it is missing" do
        Dir.mktmpdir("rac_gap") do |tmp|
          spec_dir = File.join(tmp, "spec", "requests")
          FileUtils.mkdir_p(spec_dir)
          (described_class::MAX_SCAN_FILES + 5).times do |i|
            File.write(File.join(spec_dir, "aaa_filler#{i}_spec.rb"), "# widget\n")
          end
          File.write(File.join(spec_dir, "widgets_controller_spec.rb"), "it 'lists' do\nend\n") if tested
          FileUtils.mkdir_p(File.join(tmp, "app", "controllers"))
          File.write(File.join(tmp, "app", "controllers", "widgets_controller.rb"),
                     "class WidgetsController < ApplicationController\n  def index; end\nend\n")

          allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(tmp)))
          allow(described_class).to receive(:cached_context).and_return(
            controllers: { controllers: { "WidgetsController" => { file: "app/controllers/widgets_controller.rb", actions: [ "index" ] } } }
          )

          text = described_class.call(feature: "widget").content.first[:text]

          expect(text.include?("Controller `WidgetsController` - no test file found")).to be(!tested)
        end
      end
    end

    it "says which setting a model's computed table comes from" do
      allow(described_class).to receive(:cached_context).and_return(
        models: { "Archive" => { table_set_by: "Archive.table_name", associations: [], validations: [] } }
      )

      text = described_class.call(feature: "archive").content.first[:text]

      expect(text).to include("**Table:** set by `Archive.table_name`, which the static tier did not read")
    end

    it "lists the admin resources that expose the feature's model, with ActiveAdmin's permitted params" do
      Dir.mktmpdir("rac_admin") do |tmp|
        FileUtils.mkdir_p([ File.join(tmp, "app", "admin"), File.join(tmp, "app", "dashboards") ])
        File.write(File.join(tmp, "app", "admin", "users.rb"), "ActiveAdmin.register User do\n  permit_params :email, :name\nend\n")
        File.write(File.join(tmp, "app", "admin", "posts.rb"), "ActiveAdmin.register Post do\nend\n")
        File.write(File.join(tmp, "app", "dashboards", "user_dashboard.rb"), "class UserDashboard < Administrate::BaseDashboard\nend\n")

        allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(tmp)))
        allow(described_class).to receive(:cached_context).and_return({})

        text = described_class.call(feature: "user").content.first[:text]

        expect(text).to include("## Admin Resources (2)")
        expect(text).to include("- ActiveAdmin `User` (`app/admin/users.rb`) - permits email, name")
        expect(text).to include("- Administrate `User` (`app/dashboards/user_dashboard.rb`)")
        expect(text).not_to include("`Post`")
      end
    end

    it "names an untested job and service in the gap list" do
      Dir.mktmpdir("rac_gap_js") do |tmp|
        FileUtils.mkdir_p(File.join(tmp, "app", "controllers"))
        FileUtils.mkdir_p(File.join(tmp, "app", "jobs"))
        FileUtils.mkdir_p(File.join(tmp, "app", "services"))
        File.write(File.join(tmp, "app", "jobs", "widget_sync_job.rb"), "class WidgetSyncJob; end\n")
        File.write(File.join(tmp, "app", "services", "widget_pricer.rb"), "class WidgetPricer; end\n")

        allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(tmp)))
        allow(described_class).to receive(:cached_context).and_return({})

        text = described_class.call(feature: "widget").content.first[:text]

        expect(text).to include("## Test Coverage Gaps")
        expect(text).to include("- Job `widget_sync_job` - no test file found")
        expect(text).to include("- Service `widget_pricer` - no test file found")
      end
    end

    # The gap checker matches on the path and the test lister matched on the
    # basename, so one of them saw a spec the other did not and the feature
    # read as untested.
    it "finds a spec whose feature word is in its directory" do
      Dir.mktmpdir("rac_tests") do |tmp|
        spec_dir = File.join(tmp, "spec", "services", "billing", "invoices")
        FileUtils.mkdir_p(spec_dir)
        File.write(File.join(spec_dir, "create_spec.rb"), <<~RUBY)
          require "rails_helper"

          RSpec.describe Billing::Invoices::Create do
            it "runs" do
              expect(described_class).to be_a(Class)
            end
          end
        RUBY

        allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(tmp)))
        allow(described_class).to receive(:cached_context).and_return({})

        text = described_class.call(feature: "invoice").content.first[:text]

        expect(text).to include("## Tests (1)")
        expect(text).to include("spec/services/billing/invoices/create_spec.rb")
      end
    end

    it "finds the tests of the engine an app's test/dummy runs inside" do
      Dir.mktmpdir("rac_engine") do |engine|
        engine = File.realpath(engine)
        dummy = File.join(engine, "test", "dummy")
        FileUtils.mkdir_p([ File.join(engine, "test", "models", "shop"), File.join(dummy, "app") ])
        File.write(File.join(engine, "test", "models", "shop", "widget_test.rb"), "class Shop::WidgetTest\n  test \"x\" do\n  end\nend\n")

        allow(RailsAiContext::PathResolver).to receive(:enclosing_engine_roots).and_return([ engine ])
        allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(dummy)))
        allow(described_class).to receive(:cached_context).and_return({})

        text = described_class.call(feature: "widget").content.first[:text]

        expect(text).to include("## Tests (1)")
        expect(text).to include("- `../models/shop/widget_test.rb` (1 test)")
      end
    end

    # The path match put the suite's own directory names in scope, so
    # "spec" or "test" matched every file in it.
    it "does not treat the suite's own directory as a feature word" do
      Dir.mktmpdir("rac_tests") do |tmp|
        spec_dir = File.join(tmp, "spec", "services", "billing")
        FileUtils.mkdir_p(spec_dir)
        File.write(File.join(spec_dir, "create_spec.rb"), "require \"rails_helper\"\n")

        allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(tmp)))
        allow(described_class).to receive(:cached_context).and_return({})

        text = described_class.call(feature: "spec").content.first[:text]

        expect(text).not_to include("## Tests")
      end
    end

    # A minitest suite names its files test_orders.rb, and stripping that
    # prefix must not take the path separator with it.
    it "finds a prefix-named test by the directory it sits in" do
      Dir.mktmpdir("rac_tests") do |tmp|
        test_dir = File.join(tmp, "test", "billing", "invoices")
        FileUtils.mkdir_p(test_dir)
        File.write(File.join(test_dir, "test_create.rb"), "require \"test_helper\"\n")

        allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(tmp)))
        allow(described_class).to receive(:cached_context).and_return({})

        text = described_class.call(feature: "invoice").content.first[:text]

        expect(text).to include("test/billing/invoices/test_create.rb")
      end
    end

    # spec/models/account_spec.rb is a test of Account, not of a "models"
    # feature: the suite's type directory is how it files every spec.
    it "does not treat a suite type directory as a feature word" do
      Dir.mktmpdir("rac_tests") do |tmp|
        FileUtils.mkdir_p(File.join(tmp, "spec", "models"))
        File.write(File.join(tmp, "spec", "models", "account_spec.rb"), "require \"rails_helper\"\n")

        allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(tmp)))
        allow(described_class).to receive(:cached_context).and_return({})

        text = described_class.call(feature: "models").content.first[:text]

        expect(text).not_to include("## Tests")
      end
    end

    # A file named by both conventions keeps its own words: stripping the
    # `spec_` prefix from spec_runner_spec.rb left "runner".
    it "keeps a feature word that only looks like the suite's prefix" do
      Dir.mktmpdir("rac_tests") do |tmp|
        spec_dir = File.join(tmp, "spec", "system")
        FileUtils.mkdir_p(spec_dir)
        File.write(File.join(spec_dir, "spec_runner_spec.rb"), "require \"rails_helper\"\n")

        allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(tmp)))
        allow(described_class).to receive(:cached_context).and_return({})

        text = described_class.call(feature: "spec_runner").content.first[:text]

        expect(text).to include("spec/system/spec_runner_spec.rb")
      end
    end

    context "DoS cap (v5.8.1 round 2)" do
      it "caps discover_services at MAX_SCAN_FILES and emits truncation note" do
        Dir.mktmpdir("rac_dos_services") do |tmp|
          services_dir = File.join(tmp, "app", "services")
          FileUtils.mkdir_p(services_dir)
          (described_class::MAX_SCAN_FILES + 50).times do |i|
            File.write(File.join(services_dir, "dos_service_#{i}.rb"),
                       "class DosService#{i}\n  def call; end\nend\n")
          end

          allow(described_class).to receive(:cached_context).and_return({})
          allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(tmp)))

          result = described_class.call(feature: "dos_service")
          text = result.content.first[:text]

          expect(text).to include("## Services (#{described_class::MAX_SCAN_FILES + 50} - first #{described_class::MAX_SCAN_FILES} listed)")
          listed = text.scan(/`app\/services\/dos_service_\d+\.rb`/).size
          expect(listed).to eq(described_class::MAX_SCAN_FILES)
        end
      end

      it "caps the env dependency scan of app/jobs at MAX_SCAN_FILES" do
        Dir.mktmpdir("rac_dos_jobs") do |tmp|
          jobs_dir = File.join(tmp, "app", "jobs")
          FileUtils.mkdir_p(jobs_dir)
          (described_class::MAX_SCAN_FILES + 25).times do |i|
            File.write(File.join(jobs_dir, "dos_job_#{i}.rb"),
                       "class DosJob#{i}\n  def perform; ENV['DOS_JOB_KEY']; end\nend\n")
          end

          allow(described_class).to receive(:cached_context).and_return({})
          allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(tmp)))

          result = described_class.call(feature: "dos_job")
          text = result.content.first[:text]

          expect(text).to include("## Environment Dependencies (first #{described_class::MAX_SCAN_FILES} per dir scanned)")
        end
      end

      it "caps discover_services and discover_env_dependencies independently" do
        Dir.mktmpdir("rac_dos_mixed") do |tmp|
          %w[app/mailers app/channels app/services].each do |sub|
            dir = File.join(tmp, sub)
            FileUtils.mkdir_p(dir)
            (described_class::MAX_SCAN_FILES + 10).times do |i|
              File.write(File.join(dir, "dos_thing_#{i}.rb"),
                         "class DosThing#{i}\n  def deliver; ENV['DOS_THING_KEY']; end\nend\n")
            end
          end

          allow(described_class).to receive(:cached_context).and_return({})
          allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(tmp)))

          result = described_class.call(feature: "dos_thing")
          text = result.content.first[:text]

          # Each section asserted independently - a regression in any single
          # discover_* method would now fail the spec on its own line.
          expect(text).to include("## Services (#{described_class::MAX_SCAN_FILES + 10} - first #{described_class::MAX_SCAN_FILES} listed)")
          expect(text).to include("## Environment Dependencies (first #{described_class::MAX_SCAN_FILES} per dir scanned)")
          expect(text).not_to include("## Mailers")
          expect(text).not_to include("## Channels")
        end
      end

      def analyze(tmp, feature, context: {})
        allow(described_class).to receive(:cached_context).and_return(context)
        allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(tmp)))
        described_class.call(feature: feature).content.first[:text]
      end

      def write_numbered(dir, count, body: "class Filler; end\n", ext: "rb")
        FileUtils.mkdir_p(dir)
        count.times { |i| File.write(File.join(dir, format("a%04d.%s", i, ext)), body) }
      end

      it "lists a service, a view and a spec whose names match when they sort past the first 500 files" do
        Dir.mktmpdir("rac_past_cap") do |tmp|
          write_numbered(File.join(tmp, "app", "services"), described_class::MAX_SCAN_FILES)
          write_numbered(File.join(tmp, "app", "views"), described_class::MAX_SCAN_FILES, ext: "html.erb")
          write_numbered(File.join(tmp, "spec"), described_class::MAX_SCAN_FILES, ext: "_spec.rb")
          FileUtils.mkdir_p([ File.join(tmp, "app", "services", "goals"), File.join(tmp, "app", "views", "goals") ])
          File.write(File.join(tmp, "app", "services", "goals", "sync_goal.rb"), "class Goals::SyncGoal; end\n")
          File.write(File.join(tmp, "app", "views", "goals", "show.html.erb"), "<p></p>\n")
          File.write(File.join(tmp, "spec", "zz_goal_spec.rb"), "it 'syncs' do\nend\n")

          text = analyze(tmp, "goal")

          expect(text).to include("## Services (1)").and include("`app/services/goals/sync_goal.rb`")
          expect(text).to include("## Views (1)").and include("`goals/show.html.erb`")
          expect(text).to include("## Tests (1)").and include("`spec/zz_goal_spec.rb`")
          expect(text).not_to include("matched by name alone")
        end
      end

      it "says which directory it matched by name alone when a file past the cap holds the word" do
        Dir.mktmpdir("rac_past_cap_empty") do |tmp|
          write_numbered(File.join(tmp, "app", "services"), described_class::MAX_SCAN_FILES)
          File.write(File.join(tmp, "app", "services", "z_sync.rb"), "class ZSync\n  # goal\nend\n")

          text = analyze(tmp, "goal")

          expect(text).to start_with("No matches found for 'goal'")
          expect(text).to include("past them in app/services were matched by name alone")
        end
      end

      it "says nothing at exactly the cap, where every file was read" do
        Dir.mktmpdir("rac_at_cap") do |tmp|
          write_numbered(File.join(tmp, "app", "services"), described_class::MAX_SCAN_FILES - 1)
          File.write(File.join(tmp, "app", "services", "goal_service.rb"), "class GoalService; end\n")

          text = analyze(tmp, "goal")

          expect(text).to include("## Services (1)")
          expect(text).not_to include("matched by name alone")
          expect(text).not_to include("listed)")
        end
      end

      it "does NOT emit a truncation note when file count is below the cap" do
        Dir.mktmpdir("rac_below_cap") do |tmp|
          services_dir = File.join(tmp, "app", "services")
          FileUtils.mkdir_p(services_dir)
          # Strictly below MAX_SCAN_FILES - guard against a `>= cap` off-by-one
          # that would falsely emit the truncation note.
          (described_class::MAX_SCAN_FILES - 50).times do |i|
            File.write(File.join(services_dir, "small_service_#{i}.rb"),
                       "class SmallService#{i}\n  def call; end\nend\n")
          end

          allow(described_class).to receive(:cached_context).and_return({})
          allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(tmp)))

          result = described_class.call(feature: "small_service")
          text = result.content.first[:text]

          expect(text).to include("## Services")
          expect(text).not_to include("first #{described_class::MAX_SCAN_FILES} listed")
        end
      end
    end
  end

  # get_controllers already strikes a skipped filter through; a reader must
  # not have to open the other tool to learn one was skipped.
  describe "a skipped filter" do
    let(:controller_path) { File.join(Rails.root, "app", "controllers", "widgets_controller.rb") }

    before do
      FileUtils.mkdir_p(File.dirname(controller_path))
      File.write(controller_path, <<~RUBY)
        class WidgetsController < ApplicationController
          skip_before_action :authenticate_widget

          def index; end
        end
      RUBY

      allow(described_class).to receive(:rails_app).and_return(double(root: Rails.root))
      allow(described_class).to receive(:cached_context).and_return(
        controllers: {
          controllers: {
            "ApplicationController" => {
              actions: [],
              filters: [ { kind: "before", name: "authenticate_widget", declared: true } ]
            },
            "WidgetsController" => {
              actions: [ "index" ],
              filters: [],
              parent_class: "ApplicationController",
              file: "app/controllers/widgets_controller.rb"
            }
          }
        }
      )
    end

    after { FileUtils.rm_f(controller_path) }

    it "is struck through in the controller's entry" do
      text = described_class.call(feature: "widget").content.first[:text]

      expect(text).to include("- **Skipped filters:** ~~authenticate_widget~~")
    end
  end

  describe "an inherited filter" do
    before do
      allow(described_class).to receive(:cached_context).and_return(
        controllers: {
          controllers: {
            "ApplicationController" => {
              actions: [],
              filters: [ { kind: "before", name: "authenticate_widget", only: [ "index" ], declared: true } ]
            },
            "WidgetsController" => {
              actions: [ "index" ],
              filters: [
                { kind: "before", name: "set_widget" },
                { kind: "before", name: "authenticate_widget", only: [ "index" ] }
              ],
              parent_class: "ApplicationController"
            }
          }
        }
      )
    end

    it "is listed once, annotated with the parent it comes from" do
      text = described_class.call(feature: "widget").content.first[:text]

      expect(text).to include("- **Inherited filters:** authenticate_widget _(from ApplicationController)_")
      expect(text.scan("authenticate_widget").size).to eq(1)
      expect(text).to include("- **Filters:** before set_widget")
    end

    # The deliberate trade: a parent the payload does not carry answers no
    # inherited filters. Rebuilding its path from the class name breaks on
    # every app inflection, so nothing is guessed.
    it "is absent when the payload does not carry the parent at all" do
      allow(described_class).to receive(:cached_context).and_return(
        controllers: {
          controllers: {
            "WidgetsController" => {
              actions: [ "index" ],
              filters: [ { kind: "before", name: "set_widget" } ],
              parent_class: "ApplicationController"
            }
          }
        }
      )

      text = described_class.call(feature: "widget").content.first[:text]

      expect(text).not_to include("Inherited filters")
      expect(text).to include("- **Filters:** before set_widget")
    end

    # Exclusion hides a controller from the listings, not from the filter
    # chain: ActionFilters reads every controller the payload carries.
    it "still names a parent the configuration excludes from listings" do
      original = RailsAiContext.configuration.excluded_controllers
      RailsAiContext.configuration.excluded_controllers = %w[ApplicationController]

      text = described_class.call(feature: "widget").content.first[:text]

      expect(text).to include("- **Inherited filters:** authenticate_widget _(from ApplicationController)_")
    ensure
      RailsAiContext.configuration.excluded_controllers = original
    end

    # A skip carrying `unless:` leaves the filter in the chain, so the label
    # says what it is skipped on rather than dropping it.
    it "names the condition a conditional skip takes the filter out on" do
      allow(described_class).to receive(:cached_context).and_return(
        controllers: {
          controllers: {
            "ApplicationController" => {
              actions: [],
              filters: [ { kind: "before", name: "authenticate_widget", declared: true } ]
            },
            "WidgetsController" => {
              actions: [ "index" ],
              filters: [
                { kind: "before", name: "authenticate_widget", skipped: true, unless: "trusted_widget?" }
              ],
              parent_class: "ApplicationController"
            }
          }
        }
      )

      text = described_class.call(feature: "widget").content.first[:text]

      expect(text).to include(
        "- **Inherited filters:** authenticate_widget _(from ApplicationController)_ (skipped unless: trusted_widget?)"
      )
      expect(text).not_to include("Skipped filters")
    end
  end

  # A callback object and an inline block are not symbols, so the callback
  # line stopped prefixing every target with a colon.
  describe "callback targets that are not method names" do
    before do
      described_class.reset_cache!
      allow(described_class).to receive(:cached_context).and_return(
        models: {
          "Status" => {
            table_name: "statuses",
            callbacks: {
              "around_create" => %w[Social::Snowflake::Callbacks],
              "before_validation" => %w[[inline_block] set_slug]
            }
          }
        }
      )
    end

    it "names the callback object and the block without a colon" do
      text = described_class.call(feature: "status").content.first[:text]

      expect(text).to include("Status: around_create Social::Snowflake::Callbacks")
      expect(text).to include("Status: before_validation [inline_block]")
      expect(text).to include("Status: before_validation :set_slug")
      expect(text).not_to include(":Social")
    end

    # after_commit_on_create is the key this gem files `after_create_commit`
    # under; Rails has no macro by that name.
    it "writes a commit callback's event the way Rails declares it" do
      allow(described_class).to receive(:cached_context).and_return(
        models: { "Status" => { table_name: "statuses", callbacks: { "after_commit_on_create" => %w[notify] } } }
      )

      text = described_class.call(feature: "status").content.first[:text]

      expect(text).to include("Status: after_commit (on: :create) :notify")
      expect(text).not_to include("after_commit_on_create")
    end
  end

  # ledger runs its reminders as Sidekiq workers in app/sidekiq, and the
  # analysis read only the ActiveJob list: `feature=reminder` found no job and
  # printed four blank lines under its heading, one per empty layer.
  describe "a feature run by a Sidekiq worker" do
    before do
      described_class.reset_cache!
      allow(described_class).to receive(:cached_context).and_return(
        jobs: { jobs: [], workers: [ { name: "InvoiceReminderJob", file: "app/sidekiq/invoice_reminder_job.rb",
                                       options: { "queue" => "mailers" }, perform_signature: "invoice_id" } ] }
      )
      allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(Dir.mktmpdir("rac_workers"))))
    end

    it "lists the worker" do
      text = described_class.call(feature: "reminder").content.first[:text]

      expect(text).to include("## Sidekiq Workers (1)")
      expect(text).to include("- `app/sidekiq/invoice_reminder_job.rb` (queue: mailers, perform(invoice_id))")
    end

    it "leaves no run of blank lines for the layers it found nothing in" do
      text = described_class.call(feature: "reminder").content.first[:text]

      expect(text).to start_with("# Feature Analysis: reminder\n\n## Sidekiq Workers (1)")
      expect(text).not_to include("\n\n\n")
    end
  end

  # shopapp's CheckoutService nests a Result struct whose `success?` the line
  # scan listed as the service's `success`, and the two controllers that run
  # the checkout were nowhere in the answer.
  describe "a feature's service" do
    it "lists the service's own public methods and the files that call it" do
      Dir.mktmpdir("rac_service") do |tmp|
        FileUtils.mkdir_p([ File.join(tmp, "app", "services"), File.join(tmp, "app", "controllers", "api") ])
        File.write(File.join(tmp, "app", "services", "checkout_service.rb"), <<~RUBY)
          class CheckoutService
            Result = Struct.new(:order, :error) do
              def success?
                error.nil?
              end
            end

            def self.call(**args) = new(**args).call

            def initialize(cart:)
              @cart = cart
            end

            def call
              Result.new(order: build)
            end

            private

            def build; end
          end
        RUBY
        File.write(File.join(tmp, "app", "controllers", "orders_controller.rb"),
                   "class OrdersController < ApplicationController\n  def create\n    CheckoutService.new(cart: {}).call\n  end\nend\n")
        File.write(File.join(tmp, "app", "controllers", "api", "orders_controller.rb"),
                   "module Api\n  class OrdersController\n    def create = ::CheckoutService.call(cart: {})\n  end\nend\n")
        allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(tmp)))
        allow(described_class).to receive(:cached_context).and_return({})

        text = described_class.call(feature: "checkout").content.first[:text]

        expect(text).to include("  Methods: self.call, call\n")
        expect(text).to include("  Called by: `app/controllers/api/orders_controller.rb`, `app/controllers/orders_controller.rb`")
      end
    end
  end

  # The auth rule matches User for `authentication`, and the gap check looked
  # only at the tests that word names, so test/models/user_test.rb went
  # unseen and User read as untested.
  describe "a model the feature word does not name" do
    it "finds the model's test anywhere in the suite" do
      Dir.mktmpdir("rac_auth_gap") do |tmp|
        FileUtils.mkdir_p(File.join(tmp, "test", "models"))
        File.write(File.join(tmp, "test", "models", "user_test.rb"), "class UserTest < ActiveSupport::TestCase\nend\n")
        allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(tmp)))
        allow(described_class).to receive(:cached_context).and_return(
          models: { "User" => { table_name: "users", associations: [], validations: [], scopes: [] } }
        )

        text = described_class.call(feature: "authentication").content.first[:text]

        expect(text).to include("### User")
        expect(text).not_to include("Model `User` - no test file found")
      end
    end
  end

  # Token::ICal lives in token/ical.rb where the app declares the ICal acronym,
  # and this process underscores the name to token/i_cal.
  describe "a feature named by a class whose name spells an acronym" do
    it "lists the model, its test, and no gap" do
      Dir.mktmpdir("rac_acronym") do |tmp|
        FileUtils.mkdir_p(File.join(tmp, "spec", "models", "token"))
        File.write(File.join(tmp, "spec", "models", "token", "ical_token_spec.rb"), "RSpec.describe Token::ICal do\nend\n")
        allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(tmp)))
        allow(described_class).to receive(:cached_context).and_return(
          models: { "Token::ICal" => { table_name: "tokens", file: "app/models/token/ical.rb", associations: [], validations: [], scopes: [] } }
        )

        text = described_class.call(feature: "Token::ICal").content.first[:text]

        expect(text).to include("### Token::ICal")
        expect(text).to include("spec/models/token/ical_token_spec.rb")
        expect(text).not_to include("no test file found")
      end
    end

    # The file's name is the model's only when it names that model.
    it "still reports a second model its file shares with a tested one" do
      Dir.mktmpdir("rac_shared_file") do |tmp|
        FileUtils.mkdir_p(File.join(tmp, "spec", "models"))
        File.write(File.join(tmp, "spec", "models", "payment_spec.rb"), "RSpec.describe Payment do\nend\n")
        allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(tmp)))
        allow(described_class).to receive(:cached_context).and_return(
          models: {
            "Payment" => { table_name: "payments", file: "app/models/payment.rb", associations: [], validations: [], scopes: [] },
            "PaymentRefund" => { table_name: "payment_refunds", file: "app/models/payment.rb", associations: [], validations: [], scopes: [] }
          }
        )

        text = described_class.call(feature: "payment").content.first[:text]

        expect(text).to include("Model `PaymentRefund` - no test file found")
        expect(text).not_to include("Model `Payment` - no test file found")
      end
    end
  end

  # The glob tier read queue_as out of the job's own file, so a queue
  # inherited from ApplicationJob printed as "default".
  describe "jobs, mailers and channels read from the payload" do
    let(:jobs_section) do
      {
        jobs: [
          { name: "OrderExportJob", file: "app/jobs/order_export_job.rb", queue: "low",
            retries: [ "retry_on Timeout::Error, attempts: 3" ], perform_signature: "order_id" }
        ],
        mailers: [
          { name: "OrderMailer", file: "app/mailers/order_mailer.rb", actions: %w[confirmation] }
        ],
        channels: [
          { name: "OrderChannel", file: "app/channels/order_channel.rb", stream_methods: %w[subscribed] }
        ]
      }
    end

    before do
      described_class.reset_cache!
      allow(described_class).to receive(:cached_context).and_return(jobs: jobs_section)
      allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(Dir.mktmpdir("rac_payload"))))
    end

    it "reports the resolved queue, not the one the job's own file declares" do
      text = described_class.call(feature: "order").content.first[:text]

      expect(text).to include("## Jobs (1)")
      expect(text).to include("`app/jobs/order_export_job.rb` (queue: low, retry_on Timeout::Error, attempts: 3, perform(order_id))")
      expect(text).not_to include("queue: default")
    end

    it "lists mailer actions and channel stream methods from the payload" do
      text = described_class.call(feature: "order").content.first[:text]

      expect(text).to include("## Mailers (1)")
      expect(text).to include("`app/mailers/order_mailer.rb` - confirmation")
      expect(text).to include("## Channels (1)")
      expect(text).to include("`app/channels/order_channel.rb` - subscribed")
    end

    it "goes quiet when the jobs section is unavailable" do
      allow(described_class).to receive(:cached_context).and_return(jobs: { unavailable: true })
      described_class.reset_cache!

      text = described_class.call(feature: "order").content.first[:text]

      expect(text).not_to include("## Jobs")
      expect(text).not_to include("## Mailers")
      expect(text).not_to include("## Channels")
    end
  end

  # `belongs_to owner_name` passes a local; classified, it named an
  # `OwnerName` model the app does not have.
  describe "a related model reached through a computed association name" do
    before do
      described_class.reset_cache!
      allow(described_class).to receive(:cached_context).and_return(
        models: {
          "Group" => {
            table_name: "users",
            associations: [ { type: "belongs_to", name: "owner_name", computed_name: true },
                            { type: "has_many", name: "users" } ],
            validations: [], scopes: []
          }
        }
      )
    end

    it "names no model for the computed association" do
      text = described_class.call(feature: "Group").content.first[:text]

      expect(text).not_to include("OwnerName")
      expect(text).to include("User")
    end
  end

  # An app that declares `inflect.acronym "API"` has APIClientToken, which
  # classify spells ApiClientToken.
  describe "a related model whose name carries an app acronym" do
    before do
      described_class.reset_cache!
      allow(described_class).to receive(:cached_context).and_return(
        models: {
          "Account" => { table_name: "accounts", validations: [], scopes: [],
                         associations: [ { type: "has_many", name: "api_client_tokens" } ] },
          "APIClientToken" => { table_name: "api_client_tokens", associations: [], validations: [], scopes: [] }
        }
      )
    end

    it "names the model as the app spells it" do
      text = described_class.call(feature: "Account").content.first[:text]

      expect(text).to include("APIClientToken")
      expect(text).not_to include("ApiClientToken")
    end

    it "finds the model when the feature is its class name" do
      text = described_class.call(feature: "APIClientToken").content.first[:text]

      expect(text).to include("### APIClientToken")
    end
  end

  # Rails names a through association's class from its source, and
  # singularizes the association name only for a collection.
  describe "related models named the way Rails derives an association's class" do
    before do
      described_class.reset_cache!
      allow(described_class).to receive(:cached_context).and_return(
        models: {
          "Post" => { table_name: "posts", validations: [], scopes: [],
                      associations: [
                        { type: "belongs_to", name: "preferences" },
                        { type: "belongs_to", name: "author", class_name: "User" },
                        { type: "belongs_to", name: "commentable", polymorphic: true },
                        { type: "has_many", name: "subscriptions" },
                        { type: "has_many", name: "followers", through: "subscriptions", options: { source: :user } },
                        { type: "has_many", name: "author_emails", through: "author", options: { source: :emails } },
                        { type: "has_many", name: "reader_emails", through: "reader" }
                      ] },
          "Subscription" => { table_name: "subscriptions", validations: [], scopes: [],
                              associations: [ { type: "belongs_to", name: "user" } ] },
          "User" => { table_name: "users", validations: [], scopes: [],
                      associations: [ { type: "has_many", name: "emails" } ] },
          "Email" => { table_name: "emails", associations: [], validations: [], scopes: [] },
          "Preferences" => { table_name: "preferences", associations: [], validations: [], scopes: [] }
        }
      )
    end

    it "lists the classes the associations point at, and none they do not" do
      text = described_class.call(feature: "Post").content.first[:text]
      related = text[/## Related Models.*?\n\n/m].to_s.scan(/^- \*\*(\S+)\*\*/).flatten

      expect(related).to contain_exactly("Preferences", "User", "Subscription", "Email")
    end
  end

  describe "a model whose table lives in a secondary database" do
    it "lists the table's columns" do
      allow(described_class).to receive(:cached_context).and_return(
        models: { "PageView" => { table_name: "page_views", associations: [], validations: [], scopes: [] } },
        schema: { tables: {}, secondary_databases: { "analytics" => { tables: { "page_views" => { columns: [ { name: "path", type: "string" } ] } } } } }
      )
      expect(described_class.call(feature: "page_view").content.first[:text]).to include("**Columns:** path:string")
    end
  end

  # The folders above the app hold any word: a home directory, the app's own name.
  describe "environment dependencies under a folder that holds the feature word" do
    it "matches each service and job by its path under its own directory" do
      Dir.mktmpdir("rac_env") do |tmp|
        root = File.join(tmp, "shop")
        { "app/services/billing_service.rb" => "class BillingService\n  def key = ENV[\"STRIPE_SECRET_KEY\"]\nend\n",
          "app/jobs/cleanup_job.rb" => "class CleanupJob\n  def bucket = ENV.fetch(\"S3_BUCKET\")\nend\n" }.each do |rel, body|
          FileUtils.mkdir_p(File.dirname(File.join(root, rel)))
          File.write(File.join(root, rel), body)
        end
        allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(root)))
        allow(described_class).to receive(:cached_context).and_return({})

        expect(described_class.call(feature: "shop").content.first[:text]).not_to include("## Environment Dependencies")
        billing = described_class.call(feature: "billing").content.first[:text]
        expect(billing).to include("## Environment Dependencies\n- `STRIPE_SECRET_KEY`\n\n")
      end
    end
  end

  # spec/models/postmark_event_spec.rb tests PostmarkEvent, and user_mailer_spec.rb a mailer.
  describe "a test gap beside a test whose name only starts with the subject's" do
    def gaps(tmp, feature, models)
      allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(tmp)))
      allow(described_class).to receive(:cached_context).and_return(
        models: models.to_h { |name| [ name, { table_name: name.underscore.pluralize, associations: [], validations: [], scopes: [] } ] },
        controllers: { controllers: { "PostsController" => { file: "app/controllers/posts_controller.rb", actions: [ "index" ] },
                                      "Admin::BadgesController" => { file: "app/controllers/admin/badges_controller.rb", actions: [ "index" ] } } }
      )
      described_class.call(feature: feature).content.first[:text]
    end

    it "still reports the subject as untested, and counts the test files that are its own" do
      Dir.mktmpdir("rac_gap_word") do |tmp|
        { "app/jobs/post_job.rb" => "class PostJob\nend\n",
          "spec/models/postmark_event_spec.rb" => "RSpec.describe PostmarkEvent do\nend\n",
          "spec/models/user_mailer_spec.rb" => "RSpec.describe UserMailer do\nend\n",
          "spec/requests/posts_controller_spec.rb" => "RSpec.describe PostsController do\nend\n",
          "spec/requests/admin/badges_controller_spec.rb" => "RSpec.describe Admin::BadgesController do\nend\n",
          "app/jobs/badge_job.rb" => "class BadgeJob\nend\n",
          "spec/jobs/admin/badge_job_spec.rb" => "RSpec.describe Admin::BadgeJob do\nend\n",
          "app/jobs/admin/badge_sync_job.rb" => "class Admin::BadgeSyncJob\nend\n",
          "spec/jobs/admin/badge_sync_job_spec.rb" => "RSpec.describe Admin::BadgeSyncJob do\nend\n" }.each do |rel, body|
          FileUtils.mkdir_p(File.dirname(File.join(tmp, rel)))
          File.write(File.join(tmp, rel), body)
        end

        post = gaps(tmp, "post", %w[Post PostmarkEvent])
        expect(post).to include("- Model `Post` - no test file found\n")
        expect(post).to include("- Job `post_job` - no test file found")
        expect(post).not_to include("PostmarkEvent` - no test file found")
        expect(post).not_to include("Controller `PostsController` - no test file found")

        expect(gaps(tmp, "badge", [])).to include("- Job `badge_job` - no test file found")
        expect(gaps(tmp, "badge", [])).not_to include("badge_sync_job` - no test file found")
        expect(gaps(tmp, "user", %w[User])).to include("- Model `User` - no test file found")
        expect(gaps(tmp, "badge", [])).not_to include("Controller `Admin::BadgesController` - no test file found")
      end
    end

    it "counts a model spec or test named with the _model suffix test_info also looks up" do
      Dir.mktmpdir("rac_gap_suffix") do |tmp|
        { "spec/models/widget_model_spec.rb" => "RSpec.describe Widget do\nend\n",
          "test/models/gadget_model_test.rb" => "class GadgetTest < ActiveSupport::TestCase\nend\n" }.each do |rel, body|
          FileUtils.mkdir_p(File.dirname(File.join(tmp, rel)))
          File.write(File.join(tmp, rel), body)
        end

        expect(gaps(tmp, "widget", %w[Widget])).not_to include("Model `Widget` - no test file found")
        expect(gaps(tmp, "gadget", %w[Gadget])).not_to include("Model `Gadget` - no test file found")
      end
    end

    it "counts the test an in-repo engine keeps in its own spec folder" do
      Dir.mktmpdir("rac_gap_engine") do |tmp|
        { "engines/billing/app/controllers/invoices_controller.rb" => "class InvoicesController < ApplicationController\nend\n",
          "engines/billing/spec/controllers/invoices_controller_spec.rb" => "RSpec.describe InvoicesController do\nend\n",
          "spec/rails_helper.rb" => "" }.each do |rel, body|
          FileUtils.mkdir_p(File.dirname(File.join(tmp, rel)))
          File.write(File.join(tmp, rel), body)
        end
        allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(tmp)))
        allow(described_class).to receive(:cached_context).and_return(
          controllers: { controllers: { "InvoicesController" => { file: "engines/billing/app/controllers/invoices_controller.rb", actions: [ "index" ] } } }
        )

        text = described_class.call(feature: "invoice").content.first[:text]
        expect(text).to include("engines/billing/spec/controllers/invoices_controller_spec.rb")
        expect(text).not_to include("Controller `InvoicesController` - no test file found")
      end
    end

    describe "a test filed under the subject's name that describes another of the app's classes" do
      around do |example|
        Dir.mktmpdir("rac_gap_other") do |tmp|
          @tmp = tmp
          { "app/models/invoice.rb" => "class Invoice < ApplicationRecord\nend\n",
            "engines/billing/app/models/billing/invoice.rb" => "module Billing\n  class Invoice < ApplicationRecord\n  end\nend\n",
            "engines/billing/spec/models/invoice_spec.rb" => "RSpec.describe Billing::Invoice do\nend\n",
            "app/models/receipt.rb" => "class Receipt < ApplicationRecord\nend\n",
            "app/models/archive/receipt.rb" => "module Archive\n  class Receipt < ApplicationRecord\n  end\nend\n",
            "spec/models/receipt_spec.rb" => "RSpec.describe Archive::Receipt do\nend\n",
            "app/models/order.rb" => "class Order < ApplicationRecord\nend\n",
            "app/presenters/order_presenter.rb" => "class OrderPresenter\nend\n",
            "spec/models/order_spec.rb" => "RSpec.describe \"Order\" do\n  describe OrderPresenter do\n  end\nend\n",
            "test/integration/widgets_test.rb" => "class WidgetsTest < ActionDispatch::IntegrationTest\nend\n",
            "app/controllers/gadgets_controller.rb" => "class GadgetsController < ApplicationController\nend\n",
            "app/controllers/orders_controller.rb" => "class OrdersController < ApplicationController\nend\n",
            "app/controllers/admin/orders_controller.rb" => "module Admin\n  class OrdersController < ApplicationController\n  end\nend\n",
            "test/controllers/admin/orders_controller_test.rb" => "class OrdersControllerTest < ActionDispatch::IntegrationTest\nend\n",
            "app/controllers/admin/gizmos_controller.rb" => "module Admin\n  class GizmosController < ApplicationController\n  end\nend\n",
            "test/controllers/admin/gizmos_controller_test.rb" => "class OrdersControllerTest < ActionController::TestCase\nend\n",
            "spec/requests/reports_controller_spec.rb" => "RSpec.describe Archive::Receipt do\nend\n",
            "spec/controllers/gadgets_controller_spec.rb" => "RSpec.describe OrdersController do\nend\n" }.each do |rel, body|
            FileUtils.mkdir_p(File.dirname(File.join(tmp, rel)))
            File.write(File.join(tmp, rel), body)
          end
          example.run
        end
      end

      def gaps(feature)
        models = { "Invoice" => "app/models/invoice.rb", "Billing::Invoice" => "engines/billing/app/models/billing/invoice.rb",
                   "Receipt" => "app/models/receipt.rb", "Archive::Receipt" => "app/models/archive/receipt.rb",
                   "Order" => "app/models/order.rb" }
        controllers = %w[WidgetsController ReportsController GadgetsController Admin::OrdersController Admin::GizmosController]
        allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(@tmp)))
        allow(described_class).to receive(:cached_context).and_return(
          models: models.transform_values { |file| { file: file, table_name: "x", associations: [], validations: [], scopes: [] } },
          controllers: { controllers: controllers.to_h { |name| [ name, { file: "app/controllers/#{name.underscore}.rb", actions: [ "index" ] } ] } }
        )
        described_class.call(feature: feature).content.first[:text]
      end

      it "leaves a top-level model untested by an engine's spec for the engine's own class" do
        expect(gaps("invoice")).to include("- Model `Invoice` - no test file found")
        expect(gaps("invoice")).not_to include("Model `Billing::Invoice` - no test file found")
      end

      it "leaves a model untested by its namesake spec describing a namespaced class" do
        expect(gaps("receipt")).to include("- Model `Receipt` - no test file found")
        expect(gaps("receipt")).not_to include("Model `Archive::Receipt` - no test file found")
      end

      it "counts a model spec whose top-level group names the model, whatever its nested groups describe" do
        expect(gaps("order")).not_to include("Model `Order` - no test file found")
      end

      it "counts an integration test for the controller it is filed as" do
        expect(gaps("widget")).not_to include("Controller `WidgetsController` - no test file found")
      end

      it "counts a request spec for the controller it is filed as, whatever it describes" do
        expect(gaps("report")).not_to include("Controller `ReportsController` - no test file found")
      end

      it "counts an ActionDispatch::IntegrationTest under test/controllers for the controller it is filed as" do
        expect(gaps("order")).not_to include("Controller `Admin::OrdersController` - no test file found")
      end

      it "leaves a controller untested by its controller spec describing another controller" do
        expect(gaps("gadget")).to include("- Controller `GadgetsController` - no test file found")
      end

      it "leaves a controller untested by its ActionController::TestCase named for another controller" do
        expect(gaps("gizmo")).to include("- Controller `Admin::GizmosController` - no test file found")
      end
    end

    it "counts a test filed elsewhere whose described class is the subject's declared constant" do
      Dir.mktmpdir("rac_gap_described") do |tmp|
        { "app/jobs/scheduled/sweep_widgets.rb" => "module Jobs\n  class SweepWidgets < ::Jobs::Base\n  end\nend\n",
          "spec/jobs/sweep_widgets_spec.rb" => "require \"rails_helper\"\n\nRSpec.describe Jobs::SweepWidgets do\nend\n",
          "app/jobs/regular/rotate_widgets.rb" => "module Jobs\n  class RotateWidgets < ::Jobs::Base\n  end\nend\n",
          "test/jobs/rotate_widgets_test.rb" => "module Jobs\n  class RotateWidgetsTest < ActiveSupport::TestCase\n  end\nend\n",
          "app/jobs/regular/prune_widgets.rb" => "module Jobs\n  class PruneWidgets < ::Jobs::Base\n  end\nend\n",
          "spec/jobs/prune_widgets_spec.rb" => "RSpec.describe \"Jobs::PruneWidgets\" do\nend\n",
          "app/services/widget_tools/create_widget.rb" => "module WidgetTools\n  class CreateWidget < Base\n  end\nend\n",
          "spec/requests/api/widget_tools/create_widget_spec.rb" => "RSpec.describe ::WidgetTools::CreateWidget, type: :request do\nend\n" }.each do |rel, body|
          FileUtils.mkdir_p(File.dirname(File.join(tmp, rel)))
          File.write(File.join(tmp, rel), body)
        end

        text = gaps(tmp, "widget", [])
        expect(text).not_to include("Job `scheduled/sweep_widgets` - no test file found")
        expect(text).not_to include("Job `regular/rotate_widgets` - no test file found")
        expect(text).not_to include("Service `widget_tools/create_widget` - no test file found")
        expect(text).to include("- Job `regular/prune_widgets` - no test file found")
      end
    end

    it "counts a nested example group whose first argument is the subject, as RSpec's described_class does" do
      Dir.mktmpdir("rac_gap_nested") do |tmp|
        { "app/jobs/badge_job.rb" => "class BadgeJob\nend\n",
          "spec/jobs/badge_flows_spec.rb" => "RSpec.describe \"badge flows\" do\n  xcontext BadgeJob do\n  end\nend\n",
          "spec/permissions/badges_access_spec.rb" =>
            "RSpec.describe \"badge access\", type: :controller do\n  describe Admin::BadgeSerializer do\n" \
            "    feature Admin::BadgesController do\n    end\n  end\nend\n" }.each do |rel, body|
          FileUtils.mkdir_p(File.dirname(File.join(tmp, rel)))
          File.write(File.join(tmp, rel), body)
        end

        text = gaps(tmp, "badge", [])
        expect(text).not_to include("Job `badge_job` - no test file found")
        expect(text).not_to include("Controller `Admin::BadgesController` - no test file found")
      end
    end

    it "counts a group describing the subject in a test whose name shares none of its words" do
      Dir.mktmpdir("rac_gap_any_name") do |tmp|
        { "app/jobs/regular/sweep_badges.rb" => "module Jobs\n  class SweepBadges < ::Jobs::Base\n  end\nend\n",
          "spec/permissions/access_spec.rb" =>
            "RSpec.describe \"access\" do\n  describe Admin::BadgesController do\n  end\n  context Jobs::SweepBadges do\n  end\nend\n",
          "spec/permissions/other_spec.rb" => "RSpec.describe \"other\" do\n  # BadgesController\nend\n" }.each do |rel, body|
          FileUtils.mkdir_p(File.dirname(File.join(tmp, rel)))
          File.write(File.join(tmp, rel), body)
        end

        text = gaps(tmp, "badge", [])
        expect(text).not_to include("Controller `Admin::BadgesController` - no test file found")
        expect(text).not_to include("Job `regular/sweep_badges` - no test file found")
      end
    end

    it "resolves a described constant written inside a module the way Ruby looks it up there" do
      Dir.mktmpdir("rac_gap_lexical") do |tmp|
        { "app/controllers/admin/badges_controller.rb" => "module Admin\n  class BadgesController < ApplicationController\n  end\nend\n",
          "app/controllers/admin/posts_controller.rb" => "module Admin\n  class PostsController < ApplicationController\n  end\nend\n",
          "app/controllers/posts_controller.rb" => "class PostsController < ApplicationController\nend\n",
          "spec/permissions/admin_access_spec.rb" => "module Admin\n  RSpec.describe BadgesController do\n  end\nend\n",
          "spec/permissions/admin_posts_access_spec.rb" => "module Admin\n  RSpec.describe PostsController do\n  end\nend\n" }.each do |rel, body|
          FileUtils.mkdir_p(File.dirname(File.join(tmp, rel)))
          File.write(File.join(tmp, rel), body)
        end

        expect(gaps(tmp, "badge", [])).not_to include("Controller `Admin::BadgesController` - no test file found")
        expect(gaps(tmp, "post", [])).to include("- Controller `PostsController` - no test file found")

        File.write(File.join(tmp, "spec/permissions/admin_access_spec.rb"), "module Admin\n  RSpec.describe ::BadgesController do\n  end\nend\n")
        expect(gaps(tmp, "badge", [])).to include("- Controller `Admin::BadgesController` - no test file found")
      end
    end

    it "does not count the model's spec as the controller's test" do
      Dir.mktmpdir("rac_gap_model") do |tmp|
        FileUtils.mkdir_p(File.join(tmp, "spec", "models"))
        File.write(File.join(tmp, "spec", "models", "post_spec.rb"), "RSpec.describe Post do\nend\n")

        expect(gaps(tmp, "post", %w[Post])).to include("- Controller `PostsController` - no test file found")
      end
    end
  end

  # The same names rails_get_view lists for the template.
  describe "the partials a view renders" do
    it "reads render(partial: ...), records, and no JavaScript render" do
      Dir.mktmpdir("rac_views") do |tmp|
        FileUtils.mkdir_p(File.join(tmp, "app", "views", "posts"))
        File.write(File.join(tmp, "app", "views", "posts", "edit.html.erb"), <<~ERB)
          <%= render(partial: "posts/card") %>
          <%= render "nav" %>
          <%= render @post %>
          <script>turnstile.render "box"</script>
        ERB
        allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(tmp)))
        allow(described_class).to receive(:cached_context).and_return({})

        text = described_class.call(feature: "post").content.first[:text]

        expect(text).to include("- `posts/edit.html.erb` (4 lines) renders: posts/card, nav, post\n")
      end
    end

    it "lists every partial one render call names" do
      Dir.mktmpdir("rac_views") do |tmp|
        FileUtils.mkdir_p(File.join(tmp, "app", "views", "posts"))
        File.write(File.join(tmp, "app", "views", "posts", "edit.html.erb"), %(<%= render partial: "posts/row", layout: "posts/frame" %>\n<%= render layout: "posts/box" do %>x<% end %>\n))
        allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(tmp)))
        allow(described_class).to receive(:cached_context).and_return({})

        expect(described_class.call(feature: "post").content.first[:text]).to include("renders: posts/row, posts/frame, posts/box\n")
      end
    end
  end

  # A request spec is filed by the resource it drives, often in the singular,
  # and reaches the controller through the routes it requests.
  describe "a controller its request spec reaches through a route" do
    def token_gaps(spec_body, file: File.join("spec", "requests", "oauth", "token_spec.rb"))
      Dir.mktmpdir("rac_route_test") do |tmp|
        FileUtils.mkdir_p(File.dirname(File.join(tmp, file)))
        File.write(File.join(tmp, file), spec_body)
        allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(tmp)))
        allow(described_class).to receive(:cached_context).and_return(
          controllers: { controllers: { "Oauth::TokensController" => { file: "app/controllers/oauth/tokens_controller.rb", actions: [ "revoke" ] } } },
          routes: { by_controller: { "oauth/tokens" => [
            { verb: "POST", path: "/oauth/revoke(.:format)", controller: "oauth/tokens", action: "revoke", name: "oauth_revoke" },
            { verb: "GET", path: "/oauth/tokens/:id(.:format)", controller: "oauth/tokens", action: "show", name: "oauth_token" }
          ] } }
        )
        return described_class.call(feature: "token").content.first[:text]
      end
    end

    it "counts a request sent to the controller's path" do
      text = token_gaps(%(RSpec.describe "POST /oauth/revoke", type: :request do\n  it "revokes" do\n    post "/oauth/revoke"\n  end\nend\n))

      expect(text).not_to include("Controller `Oauth::TokensController` - no test file found")
    end

    it "counts a request to a path with a segment, or through a route helper" do
      by_segment = token_gaps(%(RSpec.describe "tokens" do\n  it "shows" do\n    get "/oauth/tokens/\#{token.id}"\n  end\nend\n))
      by_helper = token_gaps(%(RSpec.describe "tokens" do\n  it "revokes" do\n    post oauth_revoke_path\n  end\nend\n))

      expect([ by_segment, by_helper ]).to all(satisfy { |text| !text.include?("Controller `Oauth::TokensController` - no test file found") })
    end

    it "still reports a controller whose paths the spec never requests" do
      text = token_gaps(%(RSpec.describe "tokens" do\n  it "lists" do\n    get "/oauth/applications"\n    get "/oauth/revoke/history"\n  end\nend\n))

      expect(text).to include("Controller `Oauth::TokensController` - no test file found")
    end

    it "counts a route helper only as the path a request is sent to" do
      redirect = token_gaps(%(RSpec.describe "comments" do\n  it "redirects" do\n    post "/comments"\n    expect(response).to redirect_to(oauth_revoke_path)\n  end\nend\n))
      sent = token_gaps(%(RSpec.describe "tokens" do\n  it "shows" do\n    get(oauth_token_path(token))\n  end\nend\n))
      visited = token_gaps(%(RSpec.describe "tokens", type: :system do\n  it "shows" do\n    visit oauth_token_path(token)\n  end\nend\n),
                           file: File.join("spec", "system", "token_spec.rb"))

      interpolated = token_gaps(%(RSpec.describe "tokens" do\n  it "pages" do\n    get "\#{oauth_token_path(token)}?page=2"\n  end\nend\n))
      redirect_in_string = token_gaps(%(RSpec.describe "comments" do\n  it "links" do\n    get "/comments"\n    expect(body).to include("\#{oauth_revoke_path}")\n  end\nend\n))

      expect(redirect).to include("Controller `Oauth::TokensController` - no test file found")
      expect(redirect_in_string).to include("Controller `Oauth::TokensController` - no test file found")
      expect([ sent, visited, interpolated ]).to all(satisfy { |text| !text.include?("Controller `Oauth::TokensController` - no test file found") })
    end

    # Rails sends a path to the first route in the table that matches it, so a catch-all or
    # slug route answers only what no route drawn before it does.
    def table_gaps(spec_body, by_controller)
      Dir.mktmpdir("rac_route_test") do |tmp|
        file = File.join(tmp, "spec", "requests", "site_spec.rb")
        FileUtils.mkdir_p(File.dirname(file))
        File.write(file, spec_body)
        allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(tmp)))
        allow(described_class).to receive(:cached_context).and_return(
          controllers: { controllers: {
            "PagesController" => { file: "app/controllers/pages_controller.rb", actions: [ "show" ] },
            "UsersController" => { file: "app/controllers/users_controller.rb", actions: [ "show" ] }
          } },
          routes: { by_controller: by_controller }
        )
        return described_class.call(feature: "page").content.first[:text] + described_class.call(feature: "user").content.first[:text]
      end
    end

    let(:site_routes) do
      { "dashboard" => [ { verb: "GET", path: "/dashboard", action: "index", name: "dashboard", position: 0 } ],
        "devise/sessions" => [ { verb: "GET", path: "/users/sign_in", action: "new", name: "new_user_session", position: 1 } ],
        "users" => [ { verb: "GET", path: "/users/:id(.:format)", action: "show", name: "user", position: 2 } ],
        "pages" => [ { verb: "GET", path: "/:slug(.:format)", action: "show", name: "page", position: 3 } ] }
    end

    it "does not count a slug or parameter route for a request an earlier route answers" do
      text = table_gaps(%(RSpec.describe "site", type: :request do\n  it "works" do\n    get "/dashboard"\n    get "/users/sign_in"\n  end\nend\n), site_routes)

      expect(text).to include("Controller `PagesController` - no test file found")
      expect(text).to include("Controller `UsersController` - no test file found")
    end

    it "counts a slug route for a request no earlier route answers" do
      text = table_gaps(%(RSpec.describe "site", type: :request do\n  it "works" do\n    get "/about"\n    get "/users/\#{user.id}"\n  end\nend\n), site_routes)

      expect(text).not_to include("Controller `PagesController` - no test file found")
      expect(text).not_to include("Controller `UsersController` - no test file found")
    end

    it "answers a path by the table's draw order, not the order controllers are listed in" do
      reordered = site_routes.slice("pages", "users", "devise/sessions", "dashboard")
      text = table_gaps(%(RSpec.describe "site", type: :request do\n  it "works" do\n    get "/users/sign_in"\n  end\nend\n), reordered)

      expect(text).to include("Controller `UsersController` - no test file found")
    end

    it "credits the controllers behind a constrained route as well as the one the constraint lets through" do
      routes = { "pages" => [ { verb: "GET", path: "/:slug(.:format)", action: "show", name: "page", position: 0, constraints: "{slug: /about|help/}" } ],
                 "users" => [ { verb: "GET", path: "/users", action: "show", name: "user", position: 1 } ] }
      text = table_gaps(%(RSpec.describe "site", type: :request do\n  it "works" do\n    get "/users"\n  end\nend\n), routes)

      expect(text).not_to include("Controller `UsersController` - no test file found")
      expect(text).not_to include("Controller `PagesController` - no test file found")
    end

    it "compares the verb a request is sent with" do
      text = table_gaps(%(RSpec.describe "site", type: :request do\n  it "works" do\n    post "/about"\n  end\nend\n), site_routes)

      expect(text).to include("Controller `PagesController` - no test file found")
    end

    # A client library's spec posts to the path on another server.
    it "counts no request from a test outside the request and controller folders" do
      text = token_gaps(%(RSpec.describe "token client" do\n  it "revokes" do\n    client.post "/oauth/revoke"\n  end\nend\n),
                        file: File.join("spec", "lib", "token_client_spec.rb"))

      expect(text).to include("Controller `Oauth::TokensController` - no test file found")
    end
  end
end
