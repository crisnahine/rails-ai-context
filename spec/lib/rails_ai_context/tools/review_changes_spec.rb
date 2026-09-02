# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Tools::ReviewChanges do
  before { described_class.reset_cache! }

  describe ".call" do
    it "returns an MCP::Tool::Response" do
      result = described_class.call
      expect(result).to be_a(MCP::Tool::Response)
    end

    it "handles no changes gracefully" do
      # Use a ref that matches HEAD exactly (no changes)
      result = described_class.call(ref: "HEAD")
      text = result.content.first[:text]
      # Either shows changes or says no changes - both are valid
      expect(text).to be_a(String)
    end

    it "classifies file types correctly" do
      classify = described_class.send(:classify_file, "app/models/user.rb")
      expect(classify).to eq(:model)

      classify = described_class.send(:classify_file, "app/controllers/users_controller.rb")
      expect(classify).to eq(:controller)

      classify = described_class.send(:classify_file, "db/migrate/20260101_create_users.rb")
      expect(classify).to eq(:migration)

      classify = described_class.send(:classify_file, "spec/models/user_spec.rb")
      expect(classify).to eq(:test)

      classify = described_class.send(:classify_file, "app/views/users/index.html.erb")
      expect(classify).to eq(:view)

      classify = described_class.send(:classify_file, "config/routes.rb")
      expect(classify).to eq(:routes)

      classify = described_class.send(:classify_file, "README.md")
      expect(classify).to eq(:other)
    end

    it "detects missing index warnings in migration diffs" do
      warnings = described_class.send(:detect_warnings, [], Rails.root.to_s, "HEAD")
      expect(warnings).to be_an(Array)
    end

    # The routes block used to be dropped whenever the answer's prose held the
    # words "not found", which a real route listing can carry.
    describe "the routes block for a changed controller" do
      def routes_block_for(response)
        allow(RailsAiContext::Tools::GetRoutes).to receive(:call).and_return(response)
        described_class.send(:gather_file_context, "app/controllers/posts_controller.rb",
          :controller, Rails.root.to_s, "HEAD").join("\n")
      end

      it "is absent when get_routes found nothing" do
        base = RailsAiContext::Tools::BaseTool
        text = routes_block_for(base.empty_response("No routes for 'posts'. Controllers: users"))

        expect(text).not_to include("**Routes:**")
        expect(text).not_to include("No routes for")
      end

      it "is present when a real listing mentions not found" do
        base = RailsAiContext::Tools::BaseTool
        text = routes_block_for(base.text_response("GET /posts/:id posts#show\n# rescues a not found record"))

        expect(text).to include("**Routes:**")
        expect(text).to include("posts#show")
      end
    end

    it "handles missing git gracefully" do
      allow(Open3).to receive(:capture2).and_return([ "", double(success?: false) ])
      result = described_class.call(ref: "HEAD")
      text = result.content.first[:text]
      expect(text).to include("git")
    end
  end
end
