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
          strong_params: %w[post_params]
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
end
