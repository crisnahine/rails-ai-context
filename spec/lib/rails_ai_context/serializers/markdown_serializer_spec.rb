# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Serializers::MarkdownSerializer do
  let(:context) { RailsAiContext.introspect }

  describe "the header against a static-tier context" do
    around do |example|
      RailsAiContext.tier = :static
      example.run
    ensure
      RailsAiContext.tier = :runtime
    end

    it "names the Rails version the lockfile carries" do
      app = RailsAiContext::StaticApp.new(File.expand_path("../../../fixtures/static_app", __dir__))
      output = described_class.new(RailsAiContext::Introspector.new(app).call).call

      expect(output).to include("> Rails 7.2.2 | Ruby ")
    end
  end

  describe "the Routes section" do
    it "lists routes drawn into an engine under that engine, apart from the total" do
      context = { routes: { total_routes: 1, by_controller: { "posts" => [ { verb: "GET", path: "/posts", action: "index" } ] },
                            engine_routes: [ { engine: "Spree::Core::Engine", mount: "/shop", routes: [
                              { verb: "GET", path: "/shop/admin/orders", controller: "spree/admin/orders", action: "index" }
                            ] } ] } }

      output = described_class.new(context).call

      expect(output).to include("### spree/admin/orders (in Spree::Core::Engine's table, not in the total)")
      expect(output).to include("- `GET /shop/admin/orders` → index")
    end
  end

  describe "the Testing section" do
    it "names the fabricators a Fabrication suite builds its data with" do
      context = { tests: { framework: "rspec", fabricators: { location: "spec/fabricators", count: 2 } } }

      expect(described_class.new(context).call).to include("- Fabricators: spec/fabricators (2 files)")
    end
  end

  describe "the Multi-Database section" do
    it "labels each adapter the way every other surface does" do
      context = {
        multi_database: {
          multi_db: true,
          databases: [
            { name: "primary", adapter: "mysql2", adapter_default: true },
            { name: "cache", adapter: "postgresql" },
            { name: "archive", adapter: nil }
          ]
        }
      }

      output = described_class.new(context).call

      expect(output).to include("- `primary` - MySQL by database.yml default")
      expect(output).to include("- `cache` - PostgreSQL")
      expect(output).to include("- `archive` - unknown")
    end
  end

  describe "the Custom Middleware section" do
    it "lists what an initializer inserts, and says where a listed class was inserted" do
      context = {
        middleware: {
          custom_middleware: [ { class_name: "Middleware::RequestTracker", file: "lib/middleware/request_tracker.rb" } ],
          middleware_from_initializers: [
            { middleware: "Middleware::RequestTracker", action: "unshift", file: "config/initializers/200-first_middlewares.rb" },
            { middleware: "Middleware::RequestTracker", action: "move_after", file: "config/environments/test.rb" },
            { middleware: "Discourse::Cors", action: "insert_before", file: "config/initializers/008-rack-cors.rb" }
          ]
        }
      }

      output = described_class.new(context).call

      expect(output).to include("- `Middleware::RequestTracker` (lib/middleware/request_tracker.rb) - inserted (unshift) in config/initializers/200-first_middlewares.rb, moved (move_after) in config/environments/test.rb")
      expect(output).to include("### Stack changes from the app's config")
      expect(output).to include("- `Discourse::Cors` inserted (insert_before) in config/initializers/008-rack-cors.rb")
    end
  end

  describe "a middleware section with an exceptions app" do
    it "names it apart from the stack" do
      context = {
        middleware: {
          custom_middleware: [],
          middleware_from_initializers: [],
          exceptions_app: { class_name: "Middleware::PublicExceptions", file: "lib/middleware/public_exceptions.rb" }
        }
      }

      output = described_class.new(context).call

      expect(output).to include("- Exceptions app: `Middleware::PublicExceptions` (lib/middleware/public_exceptions.rb)")
    end
  end

  describe "a middleware section with nothing of the app's own" do
    it "says what the initializers change without calling any of it custom" do
      context = {
        middleware: {
          custom_middleware: [],
          middleware_from_initializers: [
            { middleware: "ActionDispatch::Executor", action: "delete", file: "config/initializers/200-first_middlewares.rb" },
            { middleware: "ActionDispatch::RemoteIp", action: "move_before", file: "config/application.rb" }
          ]
        }
      }

      output = described_class.new(context).call

      expect(output).to include("- `ActionDispatch::Executor` removed in config/initializers/200-first_middlewares.rb")
      expect(output).to include("- `ActionDispatch::RemoteIp` moved (move_before) in config/application.rb")
      expect(output).to include("- No custom middleware in app/middleware/ or lib/middleware/")
    end
  end

  describe "the Authentication & Authorization section" do
    it "lists policy classes without naming a gem the app does not bundle" do
      context = {
        auth: { authentication: {}, authorization: { policies: %w[PostPolicy], ability_class: "app/models/ability.rb" } }
      }

      output = described_class.new(context).call

      expect(output).to include("### Policy Classes (app/policies)")
      expect(output).to include("- `PostPolicy`")
      expect(output).to include("- Ability class: `app/models/ability.rb`")
      expect(output).not_to include("Pundit")
      expect(output).not_to include("CanCanCan")
    end
  end

  describe "the Controllers section" do
    it "names the strong params methods rather than dumping their permit detail" do
      context = {
        controllers: {
          controllers: {
            "PostsController" => {
              actions: %w[index],
              filters: [],
              strong_params: [ { name: "post_params", permits: %w[title body] } ],
              parent_class: "ApplicationController"
            }
          }
        }
      }

      output = described_class.new(context).call

      expect(output).to include("- Strong params: post_params")
    end

    # The Filters line is resolved through the chain now, so the generated
    # file carries an inherited filter and marks the child's skip.
    it "writes the resolved chain, inherited filters included" do
      context = {
        controllers: {
          controllers: {
            "AdminController" => {
              actions: %w[index],
              filters: [ { kind: "before", name: "authenticate" } ],
              strong_params: [],
              parent_class: "ApplicationController"
            },
            "ReportsController" => {
              actions: %w[index],
              filters: [],
              strong_params: [],
              parent_class: "AdminController"
            },
            "AuditsController" => {
              actions: %w[index],
              filters: [ { kind: "before", name: "authenticate", skipped: true } ],
              strong_params: [],
              parent_class: "AdminController"
            }
          }
        }
      }

      output = described_class.new(context).call

      expect(output).to include("### ReportsController\n- Parent: `AdminController`\n- Actions: index\n- Filters: before authenticate")
      expect(output).to include("### AuditsController\n- Parent: `AdminController`\n- Actions: index\n- Filters: ~~authenticate~~ _(skipped)_")
    end
  end

  describe "the Views section" do
    # The introspector answers layouts as records; joining them printed a
    # Ruby hash into a file the app commits.
    it "names each layout file" do
      context = {
        views: {
          layouts: [ { name: "application.html.erb", yields: %w[content] }, { name: "mailer.html.erb" } ]
        }
      }

      output = described_class.new(context).call

      expect(output).to include("- Layouts: application.html.erb, mailer.html.erb")
      expect(output).not_to include("{name:")
    end
  end

  describe "the Mounted Apps section" do
    it "names a mount with no known path without inventing one" do
      output = described_class.new({ engines: { mounted_engines: [ { engine: "Sidekiq::Web", path: nil } ] } }).call

      expect(output).to include("- `Sidekiq::Web`\n")
      expect(output).not_to include("Sidekiq::Web` at")
    end

    it "names the app's own in-repo engines under the mounts" do
      output = described_class.new({
        engines: { mounted_engines: [ { engine: "Sidekiq::Web", path: "/sidekiq" } ],
                   in_repo_engines: [ { name: "budgets", path: "modules/budgets" } ] },
        models: { "Budget" => { file: "modules/budgets/app/models/budget.rb" } }
      }).call

      expect(output).to include("### In-Repo Engines (1)")
      expect(output).to include("- `budgets` at `modules/budgets` - 1 model")
    end

    it "leaves the in-repo heading out for an app with none" do
      output = described_class.new({ engines: { mounted_engines: [ { engine: "Sidekiq::Web", path: "/s" } ] } }).call

      expect(output).not_to include("In-Repo Engines")
    end
  end

  describe "the Internationalization section" do
    def i18n_output(source)
      described_class.new({ i18n: { default_locale: "en", available_locales: %w[en fr], available_locales_source: source } }).call
    end

    it "says a list read off the locale files is not the app's enabled list" do
      expect(i18n_output("locale_files")).to include("- Available locales (from locale files): en, fr")
    end

    it "states a configured list plainly" do
      expect(i18n_output("config")).to include("- Available locales: en, fr")
    end

    it "says the locale file count leaves out in-repo engine locale dirs" do
      output = described_class.new({ i18n: { default_locale: "en", available_locales: %w[en],
                                             total_locale_files: 108, in_repo_locale_files: 2601,
                                             in_repo_locale_dirs: 28 } }).call

      expect(output).to include("- Locale files: 108 (2601 more under 28 in-repo engine locale dirs, not read)")
    end
  end

  describe "the Hotwire section against the static fixture" do
    it "names each model's broadcast macros" do
      output = described_class.new(IntrospectedFixture.context).call

      expect(output).to include("- `Comment`: broadcasts_to")
    end
  end

  describe "#call" do
    subject(:output) { described_class.new(context).call }

    it "returns a markdown string" do
      expect(output).to be_a(String)
      expect(output).to include("# ")
    end

    it "includes the app overview" do
      expect(output).to include("## Overview")
    end

    it "includes database schema section" do
      expect(output).to include("## Database Schema")
    end

    it "includes routes section" do
      expect(output).to include("## Routes")
    end

    context "with introspector warnings" do
      let(:context) do
        ctx = RailsAiContext.introspect
        ctx[:_warnings] = [
          { introspector: "database_stats", error: "Database connection failed" }
        ]
        ctx
      end

      it "renders a Warnings section" do
        expect(output).to include("## Warnings")
        expect(output).to include("**database_stats**")
        expect(output).to include("Database connection failed")
      end
    end

    context "without warnings" do
      let(:context) do
        ctx = RailsAiContext.introspect
        ctx.delete(:_warnings)
        ctx
      end

      it "does not render a Warnings section" do
        expect(output).not_to include("## Warnings")
      end
    end
  end

  # A section the static tier refused is not a section with a zero count.
  describe "a refused section" do
    it "renders no routes section when the static tier refused routes" do
      ctx = RailsAiContext.introspect
      ctx[:routes] = { unavailable: "requires a booted Rails app" }

      expect(described_class.new(ctx).call).not_to include("## Routes")
    end

    it "renders no conventions section when conventions failed" do
      ctx = RailsAiContext.introspect
      ctx[:conventions] = { error: "boom", directory_structure: { "app/models" => 3 } }

      expect(described_class.new(ctx).call).not_to include("## Project Structure")
    end

    it "renders no configuration section when the static tier refused config" do
      ctx = RailsAiContext.introspect
      ctx[:config] = { unavailable: "runtime only" }

      expect(described_class.new(ctx).call).not_to include("## Configuration")
    end

    it "renders no schema section when schema failed" do
      ctx = RailsAiContext.introspect
      ctx[:schema] = { error: "boom", total_tables: 3 }

      expect(described_class.new(ctx).call).not_to include("## Database Schema")
    end
  end

  describe "SECTIONS" do
    it "names a renderer that exists for every key" do
      missing = described_class::SECTIONS.reject do |key|
        described_class.private_method_defined?("#{key}_section")
      end

      expect(missing).to be_empty
    end
  end

  # The regenerate line at the foot of the file is read by whoever opens it;
  # a standalone install has no rake task to run.
  describe "the regenerate command in the footer" do
    let(:minimal) do
      { app_name: "App", rails_version: "8.0", ruby_version: "3.4", schema: {}, models: {},
        routes: {}, gems: {}, conventions: {} }
    end

    it "names the binary in a standalone install" do
      allow(RailsAiContext::InstallMode).to receive(:standalone?).and_return(true)
      output = described_class.new(minimal).call

      expect(output).to include("Run `rails-ai-context context` to regenerate.")
      expect(output).not_to include("rails ai:context")
    end

    it "names the rake task where the app bundles the gem" do
      allow(RailsAiContext::InstallMode).to receive(:standalone?).and_return(false)

      expect(described_class.new(minimal).call).to include("Run `rails ai:context` to regenerate.")
    end
  end
end

RSpec.describe RailsAiContext::Serializers::ClaudeSerializer do
  let(:context) { RailsAiContext.introspect }

  describe "#call" do
    subject(:output) { described_class.new(context).call }

    context "in compact mode (default)" do
      it "includes AI Context header" do
        expect(output).to include("AI Context")
      end

      it "includes MCP tools section" do
        expect(output).to include("MCP tools")
      end

      it "includes rules section" do
        expect(output).to include("## Rules")
      end

      context "with introspector warnings" do
        let(:context) do
          ctx = RailsAiContext.introspect
          ctx[:_warnings] = [
            { introspector: "schema", error: "No database" }
          ]
          ctx
        end

        it "renders warnings in compact mode" do
          expect(output).to include("## Warnings")
          expect(output).to include("**schema** skipped")
        end
      end
    end

    context "in full mode" do
      before { RailsAiContext.configuration.context_mode = :full }
      after { RailsAiContext.configuration.context_mode = :compact }

      it "includes Claude-specific header" do
        expect(output).to include("Claude Code")
      end

      it "includes behavioral rules section" do
        expect(output).to include("## Behavioral Rules")
      end
    end
  end
end

RSpec.describe RailsAiContext::Serializers::CopilotSerializer do
  let(:context) { RailsAiContext.introspect }

  describe "#call" do
    subject(:output) { described_class.new(context).call }

    context "in compact mode (default)" do
      it "uses Copilot-specific header" do
        expect(output).to include("Copilot Context")
      end
    end

    context "in full mode" do
      before { RailsAiContext.configuration.context_mode = :full }
      after { RailsAiContext.configuration.context_mode = :compact }

      it "uses Copilot Instructions header" do
        expect(output).to include("Copilot Instructions")
      end
    end
  end
end
