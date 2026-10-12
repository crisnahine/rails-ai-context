# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Tools::GetGems do
  before { described_class.reset_cache! }

  let(:gems_data) do
    {
      notable_gems: [
        { name: "devise", version: "4.9.3", category: "auth", note: "Authentication framework" },
        { name: "pundit", version: "2.3.1", category: "auth", note: "Authorization framework" },
        { name: "sidekiq", version: "7.2.0", category: "jobs", note: "Background job processing" },
        { name: "pg", version: "1.5.4", category: "database", note: "PostgreSQL adapter" },
        { name: "redis", version: "5.1.0", category: "database", note: "Redis client" },
        { name: "tailwindcss-rails", version: "3.0.0", category: "frontend", note: "Tailwind CSS integration" },
        { name: "rspec-rails", version: "6.1.0", category: "testing", note: "RSpec testing framework" },
        { name: "kamal", version: "2.0.0", category: "deploy", note: "Container deployment" },
        { name: "aws-sdk-s3", version: "1.140.0", category: "files", note: "AWS S3 storage" },
        { name: "graphql", version: "2.2.0", category: "api", note: "GraphQL API framework" }
      ]
    }
  end

  before do
    allow(described_class).to receive(:cached_context).and_return({ gems: gems_data })
  end

  describe ".call" do
    context "with default params (all categories)" do
      it "returns notable gems heading" do
        result = described_class.call
        text = result.content.first[:text]
        expect(text).to include("Notable Gems")
      end

      it "groups gems by category" do
        result = described_class.call
        text = result.content.first[:text]
        expect(text).to include("## Auth")
        expect(text).to include("## Jobs")
        expect(text).to include("## Database")
        expect(text).to include("## Frontend")
        expect(text).to include("## Testing")
        expect(text).to include("## Deploy")
      end

      it "shows gem names with versions and notes" do
        result = described_class.call
        text = result.content.first[:text]
        expect(text).to include("**devise** `4.9.3`")
        expect(text).to include("Authentication framework")
      end

      it "includes config hints for known gems" do
        result = described_class.call
        text = result.content.first[:text]
        expect(text).to include("config/storage.yml")
        expect(text).not_to include("config/initializers/devise.rb")
      end

      # The app names its file sidekiq_production.yml, and the hint pointed
      # at a config/sidekiq.yml that does not exist.
      it "names the Sidekiq config files the app has, and none when it has none" do
        Dir.mktmpdir do |dir|
          FileUtils.mkdir_p(File.join(dir, "config"))
          allow(described_class).to receive(:rails_app).and_return(double(root: Pathname.new(dir)))

          expect(described_class.call.content.first[:text]).not_to include("config/sidekiq")

          File.write(File.join(dir, "config", "sidekiq_production.yml"), ":concurrency: 5\n")
          described_class.reset_cache!

          expect(described_class.call.content.first[:text]).to include("config/sidekiq_production.yml")
        end
      end
    end

    context "filtering by category" do
      it "shows only auth gems when category is auth" do
        result = described_class.call(category: "auth")
        text = result.content.first[:text]
        expect(text).to include("devise")
        expect(text).to include("pundit")
        expect(text).not_to include("sidekiq")
        expect(text).not_to include("## Database")
      end

      it "shows only database gems when category is database" do
        result = described_class.call(category: "database")
        text = result.content.first[:text]
        expect(text).to include("pg")
        expect(text).to include("redis")
        expect(text).not_to include("devise")
      end

      it "shows only testing gems when category is testing" do
        result = described_class.call(category: "testing")
        text = result.content.first[:text]
        expect(text).to include("rspec-rails")
        expect(text).not_to include("devise")
      end

      it "shows only deploy gems when category is deploy" do
        result = described_class.call(category: "deploy")
        text = result.content.first[:text]
        expect(text).to include("kamal")
        expect(text).not_to include("pg")
      end

      it "returns helpful message for empty category" do
        result = described_class.call(category: "jobs")
        text = result.content.first[:text]
        expect(text).to include("sidekiq")
      end
    end

    context "with no matching gems in filtered category" do
      it "returns not-found message with available categories" do
        gems_data[:notable_gems] = gems_data[:notable_gems].reject { |g| g[:category] == "jobs" }
        result = described_class.call(category: "jobs")
        text = result.content.first[:text]
        expect(text).to include("No notable gems found")
        expect(text).to include("Available categories:")
      end
    end
  end

  describe "edge cases" do
    it "handles missing gems data" do
      allow(described_class).to receive(:cached_context).and_return({})
      result = described_class.call
      text = result.content.first[:text]
      expect(text).to include("not available")
    end

    it "handles gems introspection error" do
      allow(described_class).to receive(:cached_context).and_return({
        gems: { error: "Gemfile.lock not found" }
      })
      result = described_class.call
      text = result.content.first[:text]
      expect(text).to include("failed")
      expect(text).to include("Gemfile.lock not found")
    end

    it "reports [UNAVAILABLE] instead of a fabricated empty answer in static tier" do
      allow(described_class).to receive(:cached_context).and_return({
        gems: { unavailable: "requires a booted Rails app (RuntimeError: boom)" }
      })
      result = described_class.call
      text = result.content.first[:text]
      expect(text).to include("UNAVAILABLE")
      expect(text).to include("requires a booted Rails app (RuntimeError: boom)")
      expect(text).not_to include("No notable gems")
    end

    it "handles empty notable_gems list" do
      gems_data[:notable_gems] = []
      result = described_class.call
      text = result.content.first[:text]
      expect(text).to include("No notable gems found")
    end

    it "handles gems without version" do
      gems_data[:notable_gems] = [
        { name: "custom_gem", version: nil, category: "api", note: "Custom API gem" }
      ]
      result = described_class.call
      text = result.content.first[:text]
      expect(text).to include("**custom_gem**")
      expect(text).to include("Custom API gem")
    end

    it "sorts gems by category then name" do
      result = described_class.call
      text = result.content.first[:text]
      # "api" comes before "auth" alphabetically
      api_pos = text.index("## Api")
      auth_pos = text.index("## Auth")
      expect(api_pos).to be < auth_pos
    end
  end

  describe "a config hint names a file the app has" do
    around do |example|
      Dir.mktmpdir("gem-config-hints") do |dir|
        @root = dir
        FileUtils.mkdir_p(File.join(dir, "config/initializers"))
        FileUtils.mkdir_p(File.join(dir, "app/policies"))
        File.write(File.join(dir, "config/initializers/3_omniauth.rb"), "")
        File.write(File.join(dir, "config/initializers/devise.rb"), "")
        File.write(File.join(dir, "config/initializers/001-redis.rb"), "")
        example.run
      end
    end

    before do
      allow(RailsAiContext).to receive(:default_app).and_return(RailsAiContext::StaticApp.new(@root))
      gems_data[:notable_gems] = [
        { name: "devise", version: "4.9.3", category: "auth", note: "Authentication framework" },
        { name: "omniauth", version: "2.1.0", category: "auth", note: "Multi-provider auth" },
        { name: "pundit", version: "2.3.1", category: "auth", note: "Authorization framework" },
        { name: "pg_search", version: "2.3.6", category: "database", note: "Postgres search" },
        { name: "redis", version: "5.1.0", category: "database", note: "Redis client" },
        { name: "aws-sdk-s3", version: "1.140.0", category: "files", note: "AWS S3 storage" }
      ]
    end

    it "does not print the path twice when the note already names it" do
      gems_data[:notable_gems] = [
        { name: "rack-cors", version: "2.0.2", category: "utilities",
          note: "CORS middleware. Origins and resources in config/initializers/rack-cors.rb." }
      ]
      FileUtils.touch(File.join(@root, "config/initializers/rack-cors.rb"))

      text = described_class.call.content.first[:text]

      expect(text).to include("Origins and resources in config/initializers/rack-cors.rb.")
      expect(text).not_to include("_(config:")
    end

    it "finds an initializer the app numbered" do
      text = described_class.call.content.first[:text]

      expect(text).to include("_(config: config/initializers/3_omniauth.rb)_")
    end

    it "prints no hint for a config file the app does not have" do
      text = described_class.call.content.first[:text]

      expect(text).to include("**redis**")
      expect(text).not_to include("config/storage.yml")
    end

    it "finds an initializer with a hyphenated load-order prefix" do
      text = described_class.call.content.first[:text]

      expect(text).to include("_(config: config/initializers/001-redis.rb)_")
    end

    it "still names an initializer the app spells plainly" do
      text = described_class.call.content.first[:text]

      expect(text).to include("_(config: config/initializers/devise.rb)_")
    end

    it "keeps a directory convention the app has" do
      text = described_class.call.content.first[:text]

      expect(text).to include("_(config: app/policies/)_")
    end

    it "drops a directory convention the app lacks" do
      text = described_class.call.content.first[:text]

      expect(text).to include("**pg_search**")
      expect(text).not_to include("include PgSearch::Model")
    end
  end

  describe "solid_queue config hint" do
    let(:root) { Rails.application.root }

    before do
      gems_data[:notable_gems] = [
        { name: "solid_queue", version: "1.0.0", category: "jobs", note: "Background jobs via SolidQueue" }
      ]
      allow(File).to receive(:exist?).and_call_original
    end

    it "shows no config hint when neither queue.yml nor recurring.yml exist" do
      allow(File).to receive(:exist?).with(File.join(root, "config/queue.yml")).and_return(false)
      allow(File).to receive(:exist?).with(File.join(root, "config/recurring.yml")).and_return(false)

      result = described_class.call
      text = result.content.first[:text]
      expect(text).to include("**solid_queue**")
      expect(text).not_to include("config/solid_queue.yml")
      expect(text).not_to include("(config:")
    end

    it "shows only the config files that actually exist" do
      allow(File).to receive(:exist?).with(File.join(root, "config/queue.yml")).and_return(true)
      allow(File).to receive(:exist?).with(File.join(root, "config/recurring.yml")).and_return(false)

      result = described_class.call
      text = result.content.first[:text]
      expect(text).to include("(config: config/queue.yml)")
      expect(text).not_to include("config/recurring.yml")
      expect(text).not_to include("config/solid_queue.yml")
    end

    it "shows both config files when both exist" do
      allow(File).to receive(:exist?).with(File.join(root, "config/queue.yml")).and_return(true)
      allow(File).to receive(:exist?).with(File.join(root, "config/recurring.yml")).and_return(true)

      result = described_class.call
      text = result.content.first[:text]
      expect(text).to include("(config: config/queue.yml, config/recurring.yml)")
    end
  end

  # An offset past the end used to render "_No notable gems found._" directly
  # above "_No items at offset 9999. Total: 13._" - the first line reads as the
  # answer and it was false.
  describe "pagination past the end" do
    it "does not claim the app has no gems" do
      text = described_class.call(offset: 9_999).content.first[:text]
      expect(text).not_to include("No notable gems found")
    end

    it "says which page was empty and how many there are" do
      text = described_class.call(offset: 9_999).content.first[:text]
      expect(text).to match(/No items at offset 9999/)
    end
  end

  # A lockfile holds every gem's dependencies too: rails pulls in activestorage
  # on an app that leaves the engine out, and oauth gems pull in jwt.
  describe "a gem the app does not name" do
    def gems_text(dir, application_rb)
      FileUtils.mkdir_p(File.join(dir, "config"))
      File.write(File.join(dir, "config", "application.rb"), application_rb)
      File.write(File.join(dir, "Gemfile.lock"), <<~LOCK)
        GEM
          remote: https://rubygems.org/
          specs:
            activestorage (8.1.3)
            jwt (3.2.0)
            omniauth-google-oauth2 (1.2.1)
              jwt (>= 2.9)
            rails (8.1.3)
              activestorage (= 8.1.3)
            sprockets (4.2.2)
            sprockets-rails (3.5.2)
              sprockets (>= 3.0.0)

        DEPENDENCIES
          omniauth-google-oauth2
          rails (~> 8.1)
          sprockets-rails
      LOCK
      context = { gems: RailsAiContext::Introspectors::GemIntrospector.new(RailsAiContext::StaticApp.new(dir)).call }
      allow(described_class).to receive(:cached_context).and_return(context)
      described_class.call.content.first[:text]
    end

    it "keeps a gem the Gemfile names from another source, whose lock line ends in a bang" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "config"))
        File.write(File.join(dir, "config", "application.rb"), "require \"rails\"\n")
        File.write(File.join(dir, "Gemfile.lock"), <<~LOCK)
          GEM
            remote: https://gems.contribsys.com/
            specs:
              sidekiq-pro (8.0.3)
                sidekiq (>= 8.0.0)

          GEM
            remote: https://rubygems.org/
            specs:
              sidekiq (8.0.9)

          DEPENDENCIES
            sidekiq-pro (= 8.0.3)!
        LOCK
        context = { gems: RailsAiContext::Introspectors::GemIntrospector.new(RailsAiContext::StaticApp.new(dir)).call }
        allow(described_class).to receive(:cached_context).and_return(context)

        expect(described_class.call.content.first[:text]).to include("**sidekiq-pro** `8.0.3`")
      end
    end

    it "leaves out a transitive gem and a framework the app does not load" do
      Dir.mktmpdir do |dir|
        text = gems_text(dir, <<~RUBY)
          require "rails"
          require "action_controller/railtie"
          # require "active_storage/engine"
        RUBY

        expect(text).to include("**sprockets-rails**")
        expect(text).not_to include("**jwt**")
        expect(text).not_to include("**sprockets**")
        expect(text).not_to include("**activestorage**")
      end
    end

    # Rails 6's rails gem depends on sprockets-rails, but only rails/all or sprockets/railtie loads it.
    it "lists sprockets-rails the rails gem pulls in only when config/application.rb loads it" do
      lock = <<~LOCK
        GEM
          remote: https://rubygems.org/
          specs:
            rails (6.1.7)
              sprockets-rails (>= 2.0.0)
            sprockets-rails (3.4.2)

        DEPENDENCIES
          rails (~> 6.1)
      LOCK
      texts = [ "require \"action_controller/railtie\"\n", "require \"rails/all\"\n" ].map do |application_rb|
        Dir.mktmpdir do |dir|
          FileUtils.mkdir_p(File.join(dir, "config"))
          File.write(File.join(dir, "config", "application.rb"), "require \"rails\"\n#{application_rb}")
          File.write(File.join(dir, "Gemfile.lock"), lock)
          context = { gems: RailsAiContext::Introspectors::GemIntrospector.new(RailsAiContext::StaticApp.new(dir)).call }
          allow(described_class).to receive(:cached_context).and_return(context)
          described_class.call.content.first[:text]
        end
      end

      expect(texts.first).not_to include("**sprockets-rails**")
      expect(texts.last).to include("**sprockets-rails**")
    end

    # OmniAuth is Rack middleware: only a gem that mounts it in the app pulls it in (gds-sso, a strategy gem).
    it "keeps OmniAuth a wrapper gem brings in" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "Gemfile.lock"), <<~LOCK)
          GEM
            remote: https://rubygems.org/
            specs:
              gds-sso (22.3.0)
                omniauth (~> 2.1)
              omniauth (2.1.4)

          DEPENDENCIES
            gds-sso
        LOCK
        context = { gems: RailsAiContext::Introspectors::GemIntrospector.new(RailsAiContext::StaticApp.new(dir)).call }
        allow(described_class).to receive(:cached_context).and_return(context)

        expect(described_class.call.content.first[:text]).to include("**omniauth** `2.1.4`")
      end
    end

    # The parent gem requires its engine, so devise runs inside the app; jwt stays oauth2's own detail.
    it "keeps a Rails engine the app gets through another gem" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "Gemfile.lock"), <<~LOCK)
          GEM
            remote: https://rubygems.org/
            specs:
              devise (4.9.4)
              devise_token_auth (1.2.5)
                devise (> 3.5.2, < 5)
              jwt (3.2.0)
              oauth2 (2.0.10)
                jwt (>= 1.0, < 4.0)

          DEPENDENCIES
            devise_token_auth
            oauth2
        LOCK
        context = { gems: RailsAiContext::Introspectors::GemIntrospector.new(RailsAiContext::StaticApp.new(dir)).call }
        allow(described_class).to receive(:cached_context).and_return(context)
        text = described_class.call.content.first[:text]

        expect(text).to include("## Auth\n- **devise** `4.9.4`")
        expect(text).not_to include("**jwt**")
      end
    end

    # Bundler resolves a gemspec's runtime dependencies as the Gemfile's own.
    it "keeps what a gemspec the Gemfile pulls in depends on" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "Gemfile.lock"), <<~LOCK)
          PATH
            remote: .
            specs:
              my_engine (0.1.0)
                devise (>= 4)

          GEM
            remote: https://rubygems.org/
            specs:
              devise (4.9.4)
                warden (~> 1.2.3)
              jwt (3.2.0)
              warden (1.2.9)

          DEPENDENCIES
            my_engine!
        LOCK
        context = { gems: RailsAiContext::Introspectors::GemIntrospector.new(RailsAiContext::StaticApp.new(dir)).call }
        allow(described_class).to receive(:cached_context).and_return(context)
        text = described_class.call.content.first[:text]

        expect(text).to include("## Auth\n- **devise** `4.9.4`")
        expect(text).not_to include("**jwt**")
      end
    end

    it "keeps a framework the app loads through rails/all" do
      Dir.mktmpdir do |dir|
        expect(gems_text(dir, "require \"rails/all\"\n")).to include("**activestorage** `8.1.3`")
      end
    end
  end

  it "lets every category the gem list uses be asked for" do
    categories = RailsAiContext::Introspectors::GemIntrospector::NOTABLE_GEMS.values.map { |gem| gem[:category].to_s }.uniq
    enum = described_class.input_schema.to_h[:properties][:category][:enum]

    expect(enum).to match_array(categories + [ "all" ])
  end
end
