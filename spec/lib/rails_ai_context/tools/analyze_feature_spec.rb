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

    it "returns clean no-match message when feature has no hits" do
      result = described_class.call(feature: "zzz_nonexistent")
      text = result.content.first[:text]

      expect(text).to include("No matches found for 'zzz_nonexistent'")
      expect(text).to include("Try one of your model names:")
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

          expect(text).to include("first #{described_class::MAX_SCAN_FILES} scanned")
          expect(text).to include("## Services")
          # Listed body is bounded by the cap (each candidate is also a match here).
          listed = text.scan(/`app\/services\/dos_service_\d+\.rb`/).size
          expect(listed).to be <= described_class::MAX_SCAN_FILES
        end
      end

      it "caps discover_jobs at MAX_SCAN_FILES" do
        Dir.mktmpdir("rac_dos_jobs") do |tmp|
          jobs_dir = File.join(tmp, "app", "jobs")
          FileUtils.mkdir_p(jobs_dir)
          (described_class::MAX_SCAN_FILES + 25).times do |i|
            File.write(File.join(jobs_dir, "dos_job_#{i}.rb"),
                       "class DosJob#{i}\n  queue_as :default\nend\n")
          end

          allow(described_class).to receive(:cached_context).and_return({})
          allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(tmp)))

          result = described_class.call(feature: "dos_job")
          text = result.content.first[:text]

          expect(text).to include("first #{described_class::MAX_SCAN_FILES} scanned")
          expect(text).to include("## Jobs")
        end
      end

      it "caps discover_mailers, discover_channels, discover_env_dependencies independently" do
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

          # Each section asserted independently — a regression in any single
          # discover_* method would now fail the spec on its own line.
          expect(text).to include("## Mailers (#{described_class::MAX_SCAN_FILES} — first #{described_class::MAX_SCAN_FILES} scanned)")
          expect(text).to include("## Channels (#{described_class::MAX_SCAN_FILES} — first #{described_class::MAX_SCAN_FILES} scanned)")
          expect(text).to include("## Environment Dependencies (first #{described_class::MAX_SCAN_FILES} per dir scanned)")
        end
      end

      it "does NOT emit a truncation note when file count is below the cap" do
        Dir.mktmpdir("rac_below_cap") do |tmp|
          services_dir = File.join(tmp, "app", "services")
          FileUtils.mkdir_p(services_dir)
          # Strictly below MAX_SCAN_FILES — guard against a `>= cap` off-by-one
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
          expect(text).not_to include("first #{described_class::MAX_SCAN_FILES} scanned")
        end
      end
    end
  end
end
