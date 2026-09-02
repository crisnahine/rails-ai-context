# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Tools::GetEditContext do
  before { described_class.reset_cache! }

  describe ".call" do
    it "returns context around a matching method" do
      result = described_class.call(file: "app/models/user.rb", near: "has_many")
      text = result.content.first[:text]
      expect(text).to be_a(String)
      expect(text).to include("app/models/user.rb")
      expect(text).to include("has_many")
    end

    it "shows line numbers in the output" do
      result = described_class.call(file: "app/models/user.rb", near: "validates")
      text = result.content.first[:text]
      # Line numbers are right-justified, e.g. "   7  validates :email..."
      expect(text).to match(/\d+\s+validates/)
    end

    it "expands to full method when near matches a def" do
      result = described_class.call(file: "app/controllers/posts_controller.rb", near: "def create")
      text = result.content.first[:text]
      expect(text).to include("def create")
      expect(text).to include("post_params")
    end

    it "returns error when file is not found" do
      result = described_class.call(file: "app/models/nonexistent.rb", near: "anything")
      text = result.content.first[:text]
      expect(text).to include("File not found")
    end

    it "returns error when near pattern is not found in file" do
      result = described_class.call(file: "app/models/user.rb", near: "zzz_nonexistent_method")
      text = result.content.first[:text]
      expect(text).to include("not found")
      expect(text).to include("Available methods")
    end

    it "blocks access to sensitive files" do
      result = described_class.call(file: ".env", near: "SECRET")
      text = result.content.first[:text]
      expect(text).to include("Access denied")
    end

    it "prevents path traversal" do
      result = described_class.call(file: "../../etc/passwd", near: "root")
      text = result.content.first[:text]
      expect(text).to match(/not (found|allowed)/)
    end

    it "requires the file parameter" do
      result = described_class.call(file: "", near: "test")
      text = result.content.first[:text]
      expect(text).to include("file")
      expect(text).to include("required")
    end

    it "requires the near parameter" do
      result = described_class.call(file: "app/models/user.rb", near: "")
      text = result.content.first[:text]
      expect(text).to include("near")
      expect(text).to include("required")
    end

    it "respects custom context_lines parameter" do
      result = described_class.call(file: "app/models/user.rb", near: "scope :active", context_lines: 1)
      text = result.content.first[:text]
      expect(text).to include("scope")
      # With context_lines: 1, output should be relatively short
      code_lines = text.scan(/^\s*\d+\s+/).size
      expect(code_lines).to be <= 10
    end
  end
end
