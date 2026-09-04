# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Tools::GetControllers do
  before { described_class.reset_cache! }

  describe "action parameter" do
    before do
      controllers = {
        "PostsController" => {
          actions: %w[index show create],
          filters: [
            { kind: "before_action", name: "set_post", only: %w[show edit update destroy] },
            { kind: "before_action", name: "authenticate_user!" }
          ],
          strong_params: [ { name: "post_params", permits: %w[title body] } ],
          file: "app/controllers/posts_controller.rb"
        }
      }
      allow(described_class).to receive(:cached_context).and_return({
        controllers: { controllers: controllers }
      })
    end

    it "returns action source code for a specific action" do
      result = described_class.call(controller: "PostsController", action: "index")
      text = result.content.first[:text]
      expect(text).to include("PostsController#index")
      expect(text).to include("def index")
      expect(text).to include("```ruby")
    end

    it "shows only applicable filters for the action" do
      result = described_class.call(controller: "PostsController", action: "index")
      text = result.content.first[:text]
      # authenticate_user! applies to all (no :only), so it should appear
      expect(text).to include("authenticate_user!")
      # set_post only applies to show/edit/update/destroy, NOT index
      expect(text).not_to include("set_post")
    end

    it "shows filters that apply to the specific action" do
      result = described_class.call(controller: "PostsController", action: "show")
      text = result.content.first[:text]
      expect(text).to include("set_post")
      expect(text).to include("authenticate_user!")
    end

    it "returns error for non-existent action" do
      result = described_class.call(controller: "PostsController", action: "nonexistent")
      text = result.content.first[:text]
      expect(text).to include("not found")
      expect(text).to include("index, show, create")
    end

    it "includes strong params" do
      result = described_class.call(controller: "PostsController", action: "create")
      text = result.content.first[:text]
      expect(text).to include("Strong Params")
      expect(text).to include("post_params")
    end
  end

  describe "the applicable filters block" do
    around do |example|
      Dir.mktmpdir("get-controllers-filters") do |dir|
        @root = dir
        FileUtils.mkdir_p(File.join(dir, "app/controllers"))
        File.write(File.join(dir, "app/controllers/posts_controller.rb"), <<~RUBY)
          class PostsController < ApplicationController
            skip_before_action :authenticate, only: %i[index]

            def index
            end

            def show
            end
          end
        RUBY
        example.run
      end
    end

    before do
      allow(RailsAiContext).to receive(:default_app).and_return(RailsAiContext::StaticApp.new(@root))
      allow(described_class).to receive(:cached_context).and_return({
        controllers: { controllers: {
          "ApplicationController" => {
            filters: [
              { kind: "before", name: "authenticate" },
              { kind: "before", name: "set_locale", except: %w[health] },
              { kind: "after", name: "track" }
            ],
            file: "app/controllers/application_controller.rb"
          },
          "PostsController" => {
            parent_class: "ApplicationController",
            actions: %w[index show],
            filters: [
              { kind: "before", name: "authenticate" },
              { kind: "before", name: "set_locale", except: %w[health] },
              { kind: "after", name: "track" },
              { kind: "before", name: "set_post", only: %w[show] }
            ],
            file: "app/controllers/posts_controller.rb"
          }
        } }
      })
    end

    def filters_block(action)
      text = described_class.call(controller: "PostsController", action: action).content.first[:text]
      text[/## Applicable Filters\n(?:- .*\n?)*/].to_s.strip
    end

    it "annotates every inherited filter, whatever its kind or constraint" do
      expect(filters_block("show")).to eq(<<~MD.strip)
        ## Applicable Filters
        - `before` **authenticate** _(from ApplicationController)_
        - `before` **set_locale** _(from ApplicationController)_ (except: health)
        - `after` **track** _(from ApplicationController)_
        - `before` **set_post** (only: show)
      MD
    end

    it "drops the skipped filter and strikes it through" do
      expect(filters_block("index")).to eq(<<~MD.strip)
        ## Applicable Filters
        - `before` **set_locale** _(from ApplicationController)_ (except: health)
        - `after` **track** _(from ApplicationController)_
        - ~~authenticate~~ _(skipped)_
      MD
    end

    it "strikes the skipped filter through in the whole-controller view too" do
      text = described_class.call(controller: "PostsController").content.first[:text]

      expect(text[/## Filters\n(?:- .*\n?)*/].to_s.strip).to eq(<<~MD.strip)
        ## Filters
        - `before` **set_locale** _(from ApplicationController)_ (except: health)
        - `after` **track** _(from ApplicationController)_
        - `before` **set_post** (only: show)
        - ~~authenticate~~ _(skipped)_
      MD
    end
  end

  describe "a controller entry that carries no file" do
    before do
      allow(described_class).to receive(:cached_context).and_return({
        controllers: { controllers: {
          "PostsController" => { actions: %w[index], filters: [] }
        } }
      })
    end

    it "says the source is not recorded and skips hydration" do
      text = described_class.call(controller: "PostsController", action: "index").content.first[:text]

      expect(text).to include("not recorded for")
      expect(text).not_to include("**File:**")
    end
  end
end
