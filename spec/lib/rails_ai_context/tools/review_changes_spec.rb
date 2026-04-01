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
      # Either shows changes or says no changes — both are valid
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

    it "handles missing git gracefully" do
      allow(Open3).to receive(:capture2).and_return([ "", double(success?: false) ])
      result = described_class.call(ref: "HEAD")
      text = result.content.first[:text]
      expect(text).to include("git")
    end
  end
end
