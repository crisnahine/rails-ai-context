# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe RailsAiContext::Introspectors::EngineIntrospector do
  let(:app) { Rails.application }
  let(:introspector) { described_class.new(app) }

  describe "#call" do
    subject(:result) { introspector.call }

    context "with mounted engines in routes" do
      before do
        @routes_path = File.join(app.root.to_s, "config/routes.rb")
        @original = File.read(@routes_path) if File.exist?(@routes_path)
        File.write(@routes_path, <<~RUBY)
          Rails.application.routes.draw do
            mount Sidekiq::Web => "/sidekiq"
            mount Flipper::UI, at: "/flipper"
            mount PgHero::Engine, at: "/pghero"

            resources :posts
          end
        RUBY
      end

      after do
        if @original
          File.write(@routes_path, @original)
        else
          FileUtils.rm_f(@routes_path)
        end
      end

      it "discovers mounted engines" do
        engines = result[:mounted_engines]
        names = engines.map { |e| e[:engine] }
        expect(names).to include("Sidekiq::Web", "Flipper::UI", "PgHero::Engine")
      end

      it "includes path for each engine" do
        sidekiq = result[:mounted_engines].find { |e| e[:engine] == "Sidekiq::Web" }
        expect(sidekiq[:path]).to eq("/sidekiq")
      end

      it "includes description for known engines" do
        sidekiq = result[:mounted_engines].find { |e| e[:engine] == "Sidekiq::Web" }
        expect(sidekiq[:description]).to include("Sidekiq")
        expect(sidekiq[:category]).to eq("admin")
      end

      it "includes description for Flipper" do
        flipper = result[:mounted_engines].find { |e| e[:engine] == "Flipper::UI" }
        expect(flipper[:description]).to include("feature flag")
      end
    end

    context "with no mounted engines" do
      before do
        @routes_path = File.join(app.root.to_s, "config/routes.rb")
        @original = File.read(@routes_path) if File.exist?(@routes_path)
        File.write(@routes_path, <<~RUBY)
          Rails.application.routes.draw do
            resources :posts
          end
        RUBY
      end

      after do
        if @original
          File.write(@routes_path, @original)
        else
          FileUtils.rm_f(@routes_path)
        end
      end

      it "returns empty array" do
        expect(result[:mounted_engines]).to eq([])
      end
    end

    it "discovers loaded Rails engines" do
      engines = result[:rails_engines]
      expect(engines).to be_an(Array)
    end

    it "does not return an error" do
      expect(result[:error]).to be_nil
    end
  end

  # Testing `defined?(Rails::Engine)` answered from the half-finished boot that
  # entered the static tier, so the marker never fired where it mattered. The
  # tier decides, per ADR 0002.
  # routes lists what every drawn file mounts; this list read
  # config/routes.rb alone, so the two tools named different sets for one app.
  describe "a routes file split with draw" do
    it "names what a drawn file mounts" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "config", "routes"))
        File.write(File.join(dir, "config", "routes.rb"), <<~RUBY)
          Rails.application.routes.draw do
            mount Sidekiq::Web => "/sidekiq"
            draw :extra
          end
        RUBY
        File.write(File.join(dir, "config", "routes", "extra.rb"), <<~RUBY)
          mount DrawnApp => "/drawn-app"
        RUBY

        mounted = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call[:mounted_engines]

        expect(mounted.map { |m| m[:engine] }).to contain_exactly("DrawnApp", "Sidekiq::Web")
        expect(mounted.find { |m| m[:engine] == "DrawnApp" }[:path]).to eq("/drawn-app")
      end
    end
  end

  # A scope whose prefix is an expression leaves the mount's path unknown,
  # and a placeholder in its place reads as a path named "unknown".
  describe "a mount whose path the source does not spell out" do
    it "carries no path" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "config"))
        File.write(File.join(dir, "config", "routes.rb"), <<~RUBY)
          Rails.application.routes.draw do
            scope ENV.fetch("ADMIN_PREFIX") do
              mount Sidekiq::Web => "/sidekiq"
            end
          end
        RUBY

        mounted = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call[:mounted_engines]

        expect(mounted.map { |m| m[:engine] }).to eq([ "Sidekiq::Web" ])
        expect(mounted.first[:path]).to be_nil
      end
    end
  end

  describe "#static_call" do
    subject(:result) { described_class.new(RailsAiContext::StaticApp.new(Dir.pwd)).static_call }

    it "marks the list unavailable instead of returning none" do
      expect(result[:rails_engines]).to eq({ unavailable: RailsAiContext::Introspectors::StaticTier.unavailable_reason })
    end

    it "still reads the mounted engines from config/routes.rb" do
      expect(result[:mounted_engines]).to be_an(Array)
    end
  end

  describe "in-repo engines" do
    it "names each in-repo code root with its path" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "config"))
        File.write(File.join(dir, "config/routes.rb"), "Rails.application.routes.draw do\nend\n")
        FileUtils.mkdir_p(File.join(dir, "modules/budgets/app/models"))
        FileUtils.touch(File.join(dir, "modules/budgets/budgets.gemspec"))
        FileUtils.touch(File.join(dir, "modules/budgets/app/models/budget.rb"))

        result = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call

        expect(result[:in_repo_engines]).to eq([ { name: "budgets", path: "modules/budgets" } ])
      end
    end

    # Only the models section knows which of an engine's files are models, so
    # the count is Payload's to fill in - see Payload.in_repo_engines_with_models.
    it "carries no model count of its own" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "config"))
        File.write(File.join(dir, "config/routes.rb"), "Rails.application.routes.draw do\nend\n")
        FileUtils.mkdir_p(File.join(dir, "modules/documents/app/models"))
        FileUtils.touch(File.join(dir, "modules/documents/documents.gemspec"))

        result = described_class.new(RailsAiContext::StaticApp.new(dir)).static_call

        expect(result[:in_repo_engines].first.keys).to eq(%i[name path])
      end
    end

    it "answers empty for an app with no in-repo code roots" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "config"))
        File.write(File.join(dir, "config/routes.rb"), "Rails.application.routes.draw do\nend\n")

        expect(described_class.new(RailsAiContext::StaticApp.new(dir)).static_call[:in_repo_engines]).to eq([])
      end
    end
  end

  # The loaded-engine count was every .rb under app/models, concerns and plain
  # modules included.
  describe "a loaded engine's model count" do
    it "counts models by the rule the models section uses" do
      Dir.mktmpdir do |dir|
        models = File.join(dir, "app", "models")
        FileUtils.mkdir_p(File.join(models, "concerns"))
        File.write(File.join(models, "application_record.rb"),
                   "class ApplicationRecord < ActiveRecord::Base\n  self.abstract_class = true\nend\n")
        File.write(File.join(models, "widget.rb"), "class Widget < ApplicationRecord\nend\n")
        File.write(File.join(models, "gadget.rb"), "class Gadget < ApplicationRecord\nend\n")
        File.write(File.join(models, "price_calculator.rb"), "class PriceCalculator\nend\n")
        File.write(File.join(models, "concerns", "sluggable.rb"), "module Sluggable\nend\n")
        engine = double("engine", name: "Shop::Engine", root: Pathname.new(dir))
        allow(Rails::Engine).to receive(:subclasses).and_return([ engine ])
        # The app's excluded_models hide framework models from its own list;
        # an engine's models are still the engine's (ActiveStorage::Blob).
        allow(RailsAiContext.configuration).to receive(:excluded_models).and_return(%w[Widget])

        loaded = described_class.new(Rails.application).send(:discover_rails_engines)

        expect(loaded.find { |e| e[:name] == "Shop::Engine" }[:model_count]).to eq(2)
      end
    end
  end

  describe "a loaded engine's route count" do
    it "counts the table as the routes section lists it, PATCH and PUT as one, and the redirects apart" do
      set = ActionDispatch::Routing::RouteSet.new.tap do |routes|
        routes.draw do
          resources :widgets
          mount ->(_env) { [ 200, {}, [] ] }, at: "/raw"
          get "old_widgets" => redirect("widgets")
        end
      end
      engine = double("engine", name: "Shop::Engine", root: Pathname.new(Dir.tmpdir), routes: set)
      allow(Rails::Engine).to receive(:subclasses).and_return([ engine ])

      loaded = described_class.new(Rails.application).send(:discover_rails_engines)

      expect(loaded.first).to include(route_count: 7, dynamic_route_count: 2)
    end
  end

  # .ai-context.json is committed: an engine's root is carried relative to
  # the app or to its gem, and never as this machine's absolute path.
  describe "an engine's root" do
    def root_for(path)
      engine = double("engine", name: "Pau::Engine", root: Pathname.new(path))
      allow(Rails::Engine).to receive(:subclasses).and_return([ engine ])
      described_class.new(Rails.application).send(:discover_rails_engines).first[:root]
    end

    it "is app-relative inside the app, and . for the app itself" do
      expect(root_for(File.join(Rails.root.to_s, "engines", "pau"))).to eq("engines/pau")
      expect(root_for(Rails.root.to_s)).to eq(".")
    end

    it "names the gem for an engine unpacked in a gem directory" do
      gem_root = RailsAiContext::PortablePath.gem_roots.first
      expect(root_for(File.join(gem_root, "pau-1.0"))).to eq("pau-1.0")
    end

    it "is left out for an engine rooted anywhere else" do
      Dir.mktmpdir do |dir|
        expect(root_for(dir)).to be_nil
      end
    end
  end
end
