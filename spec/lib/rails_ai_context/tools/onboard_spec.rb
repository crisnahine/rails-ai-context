# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Tools::Onboard do
  before { described_class.reset_cache! }

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

    it "full mode includes additional sections beyond standard" do
      result = described_class.call(detail: "full")
      text = result.content.first[:text]
      expect(text).to include("## Stack")
      expect(text).to include("Full Walkthrough")
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
    # context falls back to the interpreter running the CLI, which the app
    # declared nowhere.
    it "claims no declared ruby version when nothing declares one" do
      allow(described_class).to receive(:cached_context).and_return({
        app_name: "TestApp",
        rails_version: "8.0",
        ruby_version: RUBY_VERSION,
        gems: { declared_ruby_version: nil },
        tier: "static"
      })

      text = described_class.call(detail: "standard").content.first[:text]

      expect(text).to include("TestApp is a Rails 8.0 application on")
      expect(text).not_to include("Ruby #{RUBY_VERSION}")
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
      expect(text).to include("## Mounted Engines")
      expect(text).to include("Sidekiq::Web")
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

    context "quick mode purpose inference" do
      it "infers news aggregation from article/site models and RSS jobs" do
        allow(described_class).to receive(:cached_context).and_return({
          app_name: "AlNews",
          rails_version: "8.0.5",
          ruby_version: "3.4.9",
          schema: { adapter: "PostgreSQL", total_tables: 17 },
          models: {
            "Article" => { associations: [ { type: "belongs_to", name: "site" } ] },
            "Site" => { associations: [ { type: "has_many", name: "articles" } ] },
            "Post" => { associations: [] }
          },
          jobs: { jobs: [
            { name: "RssSiteJob" },
            { name: "YoutubeSiteJob" },
            { name: "HackerNewsSiteJob" },
            { name: "RedditSiteJob" },
            { name: "ArticleJob" }
          ] },
          conventions: { architecture: %w[hotwire phlex] },
          gems: { notable_gems: [ { name: "federails" } ] },
          tests: { framework: "minitest" }
        })
        # Stub extract_service_names since it reads the filesystem
        allow(described_class).to receive(:extract_service_names).and_return(
          %w[ArticleAgentsService MastodonService ContentService]
        )

        result = described_class.call(detail: "quick")
        text = result.content.first[:text]

        expect(text).to include("news aggregation")
        expect(text).to include("RSS")
        expect(text).to include("YouTube")
        expect(text).to include("HackerNews")
        expect(text).to include("Reddit")
        expect(text).to include("ActivityPub federation")
        expect(text).to include("17 tables")
        expect(text).to include("3 models")
        expect(text).to include("5 jobs")
        expect(text).not_to include("static_parse")
        expect(text).not_to include("(key:")
      end

      it "infers e-commerce domain from product/order models" do
        allow(described_class).to receive(:cached_context).and_return({
          app_name: "ShopApp",
          rails_version: "7.2",
          ruby_version: "3.3",
          schema: { adapter: "PostgreSQL", total_tables: 12 },
          models: {
            "Product" => { associations: [] },
            "Order" => { associations: [] },
            "Cart" => { associations: [] },
            "User" => { associations: [] }
          },
          jobs: { jobs: [] },
          conventions: { architecture: %w[hotwire stimulus] },
          gems: { notable_gems: [ { name: "stripe" } ] },
          tests: { framework: "rspec" }
        })
        allow(described_class).to receive(:extract_service_names).and_return(%w[PaymentService])

        result = described_class.call(detail: "quick")
        text = result.content.first[:text]

        expect(text).to include("e-commerce")
        expect(text).to include("payment processing")
      end

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
        allow(described_class).to receive(:extract_service_names).and_return([])

        result = described_class.call(detail: "quick")
        text = result.content.first[:text]

        expect(text).to include("Hotwire + Phlex frontend")
      end

      it "omits purpose when no domain signals are detected" do
        allow(described_class).to receive(:cached_context).and_return({
          app_name: "GenericApp",
          rails_version: "8.0",
          ruby_version: "3.4",
          schema: { adapter: "SQLite", total_tables: 3 },
          models: { "User" => { associations: [] } },
          jobs: { jobs: [] },
          conventions: { architecture: [] },
          gems: { notable_gems: [] },
          tests: { framework: "minitest" }
        })
        allow(described_class).to receive(:extract_service_names).and_return([])

        result = described_class.call(detail: "quick")
        text = result.content.first[:text]

        expect(text).to include("GenericApp")
        expect(text).to include("Rails 8.0 / Ruby 3.4")
        expect(text).not_to include("app with")
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
        allow(described_class).to receive(:extract_service_names).and_return([])

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
end
