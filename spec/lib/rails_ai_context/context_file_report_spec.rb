# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::ContextFileReport do
  let(:style) do
    { written: "Written: %s", skipped: "Skipped: %s (unchanged)", not_applicable: "Not applicable: %s (%s)" }
  end

  let(:result) do
    {
      written: [ "/app/CLAUDE.md" ],
      skipped: [ "/app/.claude/rules/rails-schema.md" ],
      not_applicable: { "/app/.claude/rules/rails-models.md" => "no models" }
    }
  end

  describe ".entries" do
    it "walks the three buckets in one order, carrying the reason with its path" do
      expect(described_class.entries(result)).to eq(
        [
          [ :written, "/app/CLAUDE.md", nil ],
          [ :skipped, "/app/.claude/rules/rails-schema.md", nil ],
          [ :not_applicable, "/app/.claude/rules/rails-models.md", "no models" ]
        ]
      )
    end

    it "treats a missing bucket as empty" do
      expect(described_class.entries({})).to eq([])
    end
  end

  describe ".each_line" do
    it "yields each bucket with the caller's own wording" do
      lines = []
      described_class.each_line(result, style) { |bucket, text| lines << [ bucket, text ] }

      expect(lines).to eq(
        [
          [ :written, "Written: /app/CLAUDE.md" ],
          [ :skipped, "Skipped: /app/.claude/rules/rails-schema.md (unchanged)" ],
          [ :not_applicable, "Not applicable: /app/.claude/rules/rails-models.md (no models)" ]
        ]
      )
    end

    # A surface that forgets a bucket used to print nothing for it. Adding a
    # fourth bucket should stop the surfaces that have no wording for it.
    it "raises rather than dropping a bucket the style has no wording for" do
      expect { described_class.each_line(result, style.except(:not_applicable)) { |_b, _t| } }
        .to raise_error(KeyError)
    end
  end
end
