# frozen_string_literal: true

require "spec_helper"

# The one answer to "what is a tag", now that two tools read it instead of
# carrying their own copy.
RSpec.describe RailsAiContext::ErbSource do
  describe ".tag_bodies" do
    it "reads every tag flavour, raw output included" do
      source = "<% a %>\n<%= b %>\n<%== c %>\n<%- d -%>\n<%# e %>\n"

      expect(described_class.tag_bodies(source).scan(/[a-e]/)).to eq(%w[a b c d e])
    end

    it "yields an empty body for an empty tag" do
      expect(described_class.tag_bodies("<%%>")).to eq("")
    end
  end

  describe ".ruby_in_place" do
    it "blanks a comment body and keeps every other line where it was" do
      source = "<p>x</p>\n<%# @ghost %>\n<%= @real %>\n"
      result = described_class.ruby_in_place(source)

      expect(result.lines.size).to eq(3)
      expect(result).not_to include("@ghost")
      expect(result.lines[2]).to include("@real")
      expect(result.lines[0].strip).to eq("")
    end
  end

  describe ".tagged?" do
    it "is false for plain HTML" do
      expect(described_class.tagged?("<p>hi</p>")).to be(false)
    end
  end
end
