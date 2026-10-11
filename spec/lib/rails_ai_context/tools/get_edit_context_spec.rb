# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Tools::GetEditContext do
  # Defence in depth: a secrets file nobody listed is still a file this tool
  # will read, so the text it returns carries no credential-shaped value.
  describe "a secret in a file no pattern names" do
    it "filters the value and keeps the line" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "config"))
        File.write(File.join(root, "config", "custom_secrets.yml"),
                   "production:\n  jwt_hmac_secret: #{'a1' * 43}\n  pool: 5\n")
        allow(described_class).to receive(:rails_app).and_return(RailsAiContext::StaticApp.new(root))

        text = described_class.call(file: "config/custom_secrets.yml", near: "jwt_hmac_secret")
                              .content.first[:text]

        expect(text).to include("jwt_hmac_secret")
        expect(text).to include("[FILTERED]")
        expect(text).not_to include("a1a1")
        expect(text).to include("pool: 5")
      end
    end
  end
  before { described_class.reset_cache! }

  # A link that resolves nowhere was offered back as the file to try.
  describe "a file that is a link to nothing" do
    it "is not found, and suggests only files the tool can read" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "app/models/archive"))
        File.symlink("missing.rb", File.join(root, "app/models/ghost.rb"))
        allow(described_class).to receive(:rails_app).and_return(RailsAiContext::StaticApp.new(root))

        text = described_class.call(file: "app/models/ghost.rb", near: "x").content.first[:text]
        expect(text).to eq("File not found: app/models/ghost.rb. No file named ghost.rb is under app/.")

        File.write(File.join(root, "app/models/archive/ghost.rb"), "class Archive::Ghost; end\n")
        text = described_class.call(file: "app/models/ghost.rb", near: "x").content.first[:text]
        expect(text).to include("Did you mean: app/models/archive/ghost.rb?")
        expect(text).not_to include("Did you mean: app/models/ghost.rb")
      end
    end
  end

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

    # The example path was built from the caller's own name, so it handed
    # `app/models/nonexistent.rb` back as the file to try.
    it "does not offer the missing path back as a suggestion" do
      text = described_class.call(file: "app/models/nonexistent.rb", near: "anything").content.first[:text]

      expect(text).to eq("File not found: app/models/nonexistent.rb. No file named nonexistent.rb is under app/.")
    end

    it "returns error when near pattern is not found in file" do
      result = described_class.call(file: "app/models/user.rb", near: "zzz_nonexistent_method")
      text = result.content.first[:text]
      expect(text).to include("not found")
      expect(text).to include("Available methods")
    end

    it "blocks access to sensitive files" do
      result = described_class.call(file: ".env", near: "SECRET")
      expect(result.error?).to be(true)
      expect(result.content.first[:text]).to eq("Path not allowed: .env (sensitive file)")
    end

    it "prevents path traversal" do
      result = described_class.call(file: "../../etc/passwd", near: "root")
      text = result.content.first[:text]
      expect(text).to match(/not (found|allowed)/)
    end

    # A refusal is not "ran and found nothing", so a composer must not drop
    # it the way it drops an empty answer.
    it "marks a refused path as an answer, not an empty result" do
      refused = described_class.call(file: "../../etc/passwd", near: "root")

      expect(described_class.send(:empty?, refused)).to be false
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
