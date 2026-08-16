# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

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

    it "reads an invalid detail level as the default, and says so" do
      text = described_class.call(detail: "bogus").content.first[:text]

      expect(text).to start_with(described_class.call(detail: "standard").content.first[:text])
      expect(text).to include("bogus")
      expect(text).to include("not a valid `detail`")
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

    context "when an API-only app has no app/helpers directory" do
      it "answers not applicable instead of not found" do
        Dir.mktmpdir do |root|
          allow(described_class).to receive(:rails_app).and_return(RailsAiContext::StaticApp.new(root))
          allow(described_class).to receive(:cached_context).and_return(api: { api_only: true })

          text = described_class.call.content.first[:text]
          expect(text).to include("Not applicable")
          expect(text).to include("API-only")
        end
      end
    end
  end
end
