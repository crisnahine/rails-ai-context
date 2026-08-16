# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Tools::SearchCode do
  describe ".call" do
    it "rejects invalid file_type with special characters" do
      result = described_class.call(pattern: "test", file_type: "rb;rm -rf /")
      text = result.content.first[:text]
      expect(text).to include("Invalid file_type")
    end

    it "accepts valid alphanumeric file_type" do
      result = described_class.call(pattern: "class", file_type: "rb")
      text = result.content.first[:text]
      expect(text).not_to include("Invalid file_type")
    end

    it "uses smart result limiting and shows total count" do
      result = described_class.call(pattern: "class")
      text = result.content.first[:text]
      expect(text).to include("total results")
      expect(result).to be_a(MCP::Tool::Response)
    end

    it "prevents path traversal" do
      result = described_class.call(pattern: "test", path: "../../etc")
      text = result.content.first[:text]
      expect(text).to match(/Path not (found|allowed)/)
    end

    it "blocks sibling-directory escape via File::SEPARATOR-aware containment" do
      # A realpath like /app/myapp_evil would pass start_with?("/app/myapp") without
      # the separator suffix - the fix adds File::SEPARATOR to close this gap.
      Dir.mktmpdir("rac_sibling_") do |sibling_dir|
        result = described_class.call(pattern: "test", path: sibling_dir)
        text = result.content.first[:text]
        expect(text).to match(/Path not (found|allowed)/)
      end
    end

    it "returns results for a valid search" do
      result = described_class.call(pattern: "ActiveRecord::Schema")
      text = result.content.first[:text]
      expect(text).to include("Search:")
    end

    # Turning search_extensions into a positive glob list on the ripgrep path
    # made the two backends agree and cost the reach that makes the tool
    # useful: a Gemfile, a Rakefile and a .md carry no listed extension. The
    # Ruby fallback still globs by extension, so this is ripgrep's property.
    it "finds a match in a file whose name carries no listed extension" do
      skip "requires ripgrep" unless described_class.send(:ripgrep_available?)

      previous_root = RailsAiContext.configuration.app_root
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app", "models"))
        File.write(File.join(dir, "Gemfile"), %(source "https://rubygems.org"\ngem "devise"\n))
        File.write(File.join(dir, "app", "models", "post.rb"), "class Post; end\n")
        RailsAiContext.configuration.app_root = dir
        allow(RailsAiContext).to receive(:tier).and_return(:static)

        text = described_class.call(pattern: "devise").content.first[:text]

        expect(text).to include("Gemfile")
      end
    ensure
      # app_root lives on the memoized configuration, so setting it without
      # putting it back sends every later example at a deleted directory.
      RailsAiContext.configuration.app_root = previous_root
    end

    it "returns a not-found message for unmatched patterns" do
      result = described_class.call(pattern: "zzz_impossible_pattern_zzz_42")
      text = result.content.first[:text]
      expect(text).to include("No results found")
    end

    it "rejects empty patterns" do
      result = described_class.call(pattern: "   ")
      text = result.content.first[:text]
      expect(text).to include("Pattern is required")
    end

    it "rejects invalid regex patterns" do
      result = described_class.call(pattern: "[invalid")
      text = result.content.first[:text]
      expect(text).to include("Invalid regex")
    end

    it "rejects unknown match_type" do
      result = described_class.call(pattern: "test", match_type: "bogus")
      text = result.content.first[:text]
      expect(text).to include("Unknown match_type")
    end

    it "marks match lines with '>' and context lines with spaces when context is shown" do
      skip "requires ripgrep for context lines" unless described_class.send(:ripgrep_available?)

      result = described_class.call(pattern: "class Post", path: "app/models", context_lines: 2)
      text = result.content.first[:text]
      expect(text).to include("`>` = match line")
      expect(text).to match(%r{^> app/models/post\.rb:\d+: class Post})
      expect(text).to match(/^  \S+:\d+:/)
    end

    it "keeps the plain format when no context lines are requested" do
      result = described_class.call(pattern: "class Post", path: "app/models", context_lines: 0)
      text = result.content.first[:text]
      expect(text).not_to include("`>` = match line")
      expect(text).to match(%r{^app/models/post\.rb:\d+: class Post})
    end
  end

  describe ".ripgrep_available?" do
    after { described_class.instance_variable_set(:@rg_available, nil) }

    it "caches the result including false" do
      # Reset to nil so we can observe caching
      described_class.instance_variable_set(:@rg_available, nil)

      # First call: should run system check
      result = described_class.send(:ripgrep_available?)

      # Store the result and call again - should not re-check
      expect(described_class.instance_variable_get(:@rg_available)).not_to be_nil

      # Force false and verify it stays cached
      described_class.instance_variable_set(:@rg_available, false)
      expect(described_class.send(:ripgrep_available?)).to eq(false)
    end
  end
end
