# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe RailsAiContext::Introspectors::RouteIntrospector do
  let(:introspector) { described_class.new(Rails.application) }

  describe "#call" do
    subject(:result) { introspector.call }

    it "counts total routes" do
      expect(result[:total_routes]).to be > 0
    end

    it "groups routes by controller" do
      expect(result[:by_controller]).to have_key("users")
      expect(result[:by_controller]).to have_key("posts")
    end

    it "extracts HTTP verbs and paths" do
      user_routes = result[:by_controller]["users"]
      expect(user_routes).to include(a_hash_including(verb: "GET", path: "/users"))
    end

    it "returns api_namespaces as an array" do
      expect(result[:api_namespaces]).to be_an(Array)
    end

    it "returns mounted_engines as an array" do
      expect(result[:mounted_engines]).to be_an(Array)
    end
  end

  describe "#static_call" do
    it "builds the runtime output shape from config/routes.rb without booting" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "config"))
        File.write(File.join(dir, "config", "routes.rb"), <<~RUBY)
          Rails.application.routes.draw do
            root "welcome#index"
            resources :posts, only: [:index, :show]
            namespace :api do
              namespace :v1 do
                resources :widgets, only: [:index]
              end
            end
            mount Sidekiq::Web, at: "/sidekiq"
            devise_for :users
          end
        RUBY

        result = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call

        expect(result[:total_routes]).to eq(4)
        expect(result[:by_controller].keys).to contain_exactly("welcome", "posts", "api/v1/widgets")
        post_routes = result[:by_controller]["posts"]
        expect(post_routes).to include(
          a_hash_including(verb: "GET", path: "/posts", action: "index", restful: true)
        )
        expect(result[:api_namespaces]).to eq([ "/api/v1" ])
        expect(result[:mounted_engines]).to eq([ { engine: "Sidekiq::Web", path: "/sidekiq" } ])
        expect(result[:root_route]).to eq("welcome#index")
        expect(result[:confidence]).to eq("[STATIC]")
        expect(result[:dynamic_routes]).to eq(1)
      end
    end

    # Rails registers PATCH and PUT separately for one update action, and every
    # surface that lists routes merges them. The static total did not, so the
    # generated files said "8 total" where rails_get_routes said 7 on the same
    # `resources :posts`.
    it "counts an update route once, the way the booted tier does" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "config"))
        File.write(File.join(dir, "config", "routes.rb"), <<~RUBY)
          Rails.application.routes.draw do
            resources :posts
          end
        RUBY

        result = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call
        merged = result[:by_controller].values.sum do |actions|
          RailsAiContext::Tools::BaseTool.dedupe_put_patch_routes(actions).size
        end
        expect(result[:total_routes]).to eq(merged)
        expect(result[:total_routes]).to eq(7)
      end
    end

    it "reports a missing routes.rb honestly" do
      Dir.mktmpdir do |dir|
        result = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call
        expect(result[:error]).to include("config/routes.rb")
      end
    end

    # An app that splits its routing table with `draw` keeps most of it in
    # config/routes/*.rb. Reading config/routes.rb alone answered 94 on a
    # 723-route app, with nothing saying the count was partial.
    describe "an app that draws its routes from other files" do
      def build_app(dir, main:, drawn: {})
        FileUtils.mkdir_p(File.join(dir, "config", "routes"))
        File.write(File.join(dir, "config", "routes.rb"), main)
        drawn.each do |name, source|
          path = File.join(dir, "config", "routes", "#{name}.rb")
          FileUtils.mkdir_p(File.dirname(path))
          File.write(path, source)
        end
        described_class.new(RailsAiContext::StaticApp.new(dir))
      end

      let(:main) do
        <<~RUBY
          Rails.application.routes.draw do
            root "welcome#index"
            draw(:admin)
            devise_for :users
          end
        RUBY
      end

      let(:drawn) do
        { "admin" => <<~RUBY }
          namespace :admin do
            resources :reports, only: [:index, :show]
          end
        RUBY
      end

      it "counts the routes the drawn file defines" do
        Dir.mktmpdir do |dir|
          expect(build_app(dir, main: main, drawn: drawn).static_call[:total_routes]).to eq(3)
        end
      end

      it "attributes them to their own controller" do
        Dir.mktmpdir do |dir|
          result = build_app(dir, main: main, drawn: drawn).static_call
          expect(result[:by_controller].keys).to contain_exactly("welcome", "admin/reports")
        end
      end

      # The draw was expanded, so it is no longer one of the things missing.
      it "stops counting a draw it followed as unexpanded" do
        Dir.mktmpdir do |dir|
          expect(build_app(dir, main: main, drawn: drawn).static_call[:dynamic_routes]).to eq(1)
        end
      end

      it "names the files it read" do
        Dir.mktmpdir do |dir|
          expect(build_app(dir, main: main, drawn: drawn).static_call[:note])
            .to eq("Parsed statically from config/routes.rb and 1 file it draws (app not booted)")
        end
      end

      it "follows a draw nested inside another drawn file" do
        Dir.mktmpdir do |dir|
          nested = {
            "admin" => "draw(:reports)\n",
            "reports" => "get \"/reports\", to: \"reports#index\"\n"
          }
          expect(build_app(dir, main: main, drawn: nested).static_call[:total_routes]).to eq(2)
        end
      end

      it "keeps counting a draw whose target file is absent" do
        Dir.mktmpdir do |dir|
          result = build_app(dir, main: main).static_call
          expect(result[:total_routes]).to eq(1)
          expect(result[:dynamic_routes]).to eq(2)
        end
      end

      it "keeps counting a draw whose target is not a literal" do
        Dir.mktmpdir do |dir|
          computed = "Rails.application.routes.draw do\n  draw(SECTION)\nend\n"
          expect(build_app(dir, main: computed, drawn: drawn).static_call[:dynamic_routes]).to eq(1)
        end
      end

      # The name reaches the resolver as source text, so it must not be able
      # to name a file outside config/routes/.
      it "refuses a target that climbs out of config/routes" do
        Dir.mktmpdir do |dir|
          escaping = "Rails.application.routes.draw do\n  draw(:\"../secrets\")\nend\n"
          introspector = build_app(dir, main: escaping)
          File.write(File.join(dir, "config", "secrets.rb"), "get \"/leak\", to: \"leak#index\"\n")
          result = introspector.static_call
          expect(result[:total_routes]).to eq(0)
          expect(result[:dynamic_routes]).to eq(1)
        end
      end

      # Coming back to a file already read is not a loss: its routes are in the
      # list. Only devise_for is genuinely unexpanded here.
      it "does not invent a caveat for a draw that closes a cycle" do
        Dir.mktmpdir do |dir|
          cycle = { "admin" => "get \"/a\", to: \"a#index\"\ndraw(:other)\n", "other" => "draw(:admin)\n" }
          result = build_app(dir, main: main, drawn: cycle).static_call
          expect(result[:dynamic_routes]).to eq(1)
        end
      end

      # Two files drawing the same third one is the ordinary shape, not a
      # cycle. The second draw is expanded because the first already read it.
      it "does not invent a caveat when two files draw the same one" do
        Dir.mktmpdir do |dir|
          diamond = "Rails.application.routes.draw do\n  draw(:admin)\n  draw(:api)\nend\n"
          drawn = {
            "admin" => "get \"/admin\", to: \"admin#index\"\ndraw(:shared)\n",
            "api" => "get \"/api\", to: \"api#index\"\ndraw(:shared)\n",
            "shared" => "get \"/shared\", to: \"shared#index\"\n"
          }
          result = build_app(dir, main: diamond, drawn: drawn).static_call
          expect(result[:total_routes]).to eq(3)
          expect(result[:dynamic_routes]).to be_nil
        end
      end

      # The depth cap does lose routes, so the caveat has to stay.
      it "still counts a draw the depth cap stopped" do
        Dir.mktmpdir do |dir|
          chain = (0..8).to_h { |i| [ "l#{i}", "get \"/l#{i}\", to: \"l#{i}#index\"\ndraw(:l#{i + 1})\n" ] }
          deep = "Rails.application.routes.draw do\n  draw(:l0)\nend\n"
          result = build_app(dir, main: deep, drawn: chain).static_call
          expect(result[:total_routes]).to be < chain.size
          expect(result[:dynamic_routes]).to be >= 1
        end
      end

      # config/routes.rb alone could always fail the whole section. Following
      # draws must not hand that power to every file it reads.
      it "keeps the routes it did parse when a drawn file cannot be" do
        Dir.mktmpdir do |dir|
          oversized = "# pad\n" * ((RailsAiContext::AstCache::MAX_PARSE_SIZE / 6) + 1)
          result = build_app(dir, main: main, drawn: { "admin" => oversized }).static_call

          expect(result[:error]).to be_nil
          expect(result[:total_routes]).to eq(1)
          expect(result[:dynamic_routes]).to eq(2)
        end
      end

      it "survives two files that draw each other" do
        Dir.mktmpdir do |dir|
          cycle = { "admin" => "draw(:other)\n", "other" => "draw(:admin)\n" }
          expect { build_app(dir, main: main, drawn: cycle).static_call }.not_to raise_error
        end
      end

      # expand_path folds `..` without following links, so a symlink under
      # config/routes/ was enough to read a file anywhere on disk.
      it "refuses a target that reaches outside through a symlink" do
        Dir.mktmpdir do |dir|
          sneaky = "Rails.application.routes.draw do\n  draw(:sneaky)\nend\n"
          introspector = build_app(dir, main: sneaky)
          File.write(File.join(dir, "outside.rb"), "get \"/leak\", to: \"leak#index\"\n")
          File.symlink(File.join(dir, "outside.rb"), File.join(dir, "config", "routes", "sneaky.rb"))

          result = introspector.static_call
          expect(result[:total_routes]).to eq(0)
          expect(result[:dynamic_routes]).to eq(1)
        end
      end
    end
  end
end
