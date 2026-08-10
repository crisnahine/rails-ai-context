# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Tools::GetHelperMethods do
  before { described_class.reset_cache! }

  describe ".call" do
    it "lists all helpers with default params" do
      result = described_class.call
      text = result.content.first[:text]
      expect(text).to be_a(String)
      expect(text.length).to be > 0
      expect(text).to include("Helpers")
    end

    it "lists helpers with method counts for detail:summary" do
      result = described_class.call(detail: "summary")
      text = result.content.first[:text]
      expect(text).to include("ApplicationHelper")
      expect(text).to include("PostsHelper")
      expect(text).to include("- 1 method")
    end

    it "lists helpers with method signatures for detail:standard" do
      result = described_class.call(detail: "standard")
      text = result.content.first[:text]
      expect(text).to include("ApplicationHelper")
      expect(text).to include("page_title")
      expect(text).to include("post_excerpt")
    end

    it "shows framework helper detection for detail:full" do
      result = described_class.call(detail: "full")
      text = result.content.first[:text]
      expect(text).to include("ApplicationHelper")
      expect(text).to include("page_title")
    end

    it "shows specific helper by module name" do
      result = described_class.call(helper: "ApplicationHelper")
      text = result.content.first[:text]
      expect(text).to include("ApplicationHelper")
      expect(text).to include("page_title")
      expect(text).to include("app/helpers/application_helper.rb")
    end

    it "shows specific helper by short name" do
      result = described_class.call(helper: "PostsHelper")
      text = result.content.first[:text]
      expect(text).to include("PostsHelper")
      expect(text).to include("post_excerpt")
    end

    it "returns not-found for unknown helper" do
      result = described_class.call(helper: "NonexistentHelper")
      text = result.content.first[:text]
      expect(text).to include("not found")
      expect(text).to include("ApplicationHelper")
    end

    it "reads an invalid detail level as the default" do
      result = described_class.call(detail: "bogus")
      expect(result.content.first[:text]).to eq(described_class.call(detail: "standard").content.first[:text])
    end

    it "shows view cross-references at detail:full for a specific helper" do
      result = described_class.call(helper: "ApplicationHelper", detail: "full")
      text = result.content.first[:text]
      expect(text).to include("ApplicationHelper")
      # Should attempt view cross-reference even if none found
      expect(text).to match(/View References|No view references/)
    end

    it "includes method parameter signatures" do
      result = described_class.call(helper: "PostsHelper")
      text = result.content.first[:text]
      # PostsHelper has post_excerpt(post, length: 100)
      expect(text).to include("post_excerpt")
    end
  end
end
