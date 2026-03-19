# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Tools::GetView do
  before { described_class.reset_cache! }

  describe ".call" do
    it "lists views with detail:summary" do
      result = described_class.call(detail: "summary")
      text = result.content.first[:text]
      expect(text).to include("Views")
      expect(text).to include("posts")
    end

    it "lists views for a specific controller" do
      result = described_class.call(controller: "posts", detail: "summary")
      text = result.content.first[:text]
      expect(text).to include("index.html.erb")
      expect(text).to include("show.html.erb")
    end

    it "returns specific view content by path" do
      result = described_class.call(path: "posts/index.html.erb")
      text = result.content.first[:text]
      expect(text).to include("posts/index.html.erb")
      expect(text).to include("Posts")
    end

    it "returns error for non-existent path" do
      result = described_class.call(path: "nonexistent/show.html.erb")
      text = result.content.first[:text]
      expect(text).to include("not found")
    end

    it "prevents path traversal" do
      result = described_class.call(path: "../../etc/passwd")
      text = result.content.first[:text]
      expect(text).to match(/not (found|allowed)/)
    end

    it "returns error for unknown controller" do
      result = described_class.call(controller: "zzz_nonexistent")
      text = result.content.first[:text]
      expect(text).to include("No views for")
    end

    it "returns standard detail with partial and stimulus refs" do
      result = described_class.call(controller: "posts", detail: "standard")
      text = result.content.first[:text]
      expect(text).to include("index.html.erb")
    end

    it "returns full detail with template content for a controller" do
      result = described_class.call(controller: "posts", detail: "full")
      text = result.content.first[:text]
      expect(text).to include("```erb")
      expect(text).to include("Posts")
    end

    it "returns hint when full detail used without controller" do
      result = described_class.call(detail: "full")
      text = result.content.first[:text]
      expect(text).to include("controller:")
    end
  end
end
