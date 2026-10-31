# frozen_string_literal: true

require "spec_helper"

# The one answer to "what is a tag", now that two tools read it instead of
# carrying their own copy.
RSpec.describe RailsAiContext::ErbSource do
  describe ".tag_bodies" do
    it "reads every code tag flavour, raw output included" do
      source = "<% a %>\n<%= b %>\n<%== c %>\n<%- d -%>\n"

      expect(described_class.tag_bodies(source).scan(/[a-d]/)).to eq(%w[a b c d])
    end

    it "leaves out a comment tag's body, which is not code" do
      expect(described_class.tag_bodies("<%# @ghost %>\n<%= @real %>")).not_to include("ghost")
    end

    it "keeps a code tag whose first line is a Ruby comment" do
      expect(described_class.tag_bodies("<%\n  # the list\n  items = @posts.select(&:published?)\n%>")).to include("@posts")
      expect(described_class.tag_bodies("<% # note\n @x.each do |y| %>")).to include("@x")
      expect(described_class.tag_bodies("<%-# @ghost -%>")).not_to include("ghost")
    end

    it "yields an empty body for an empty tag" do
      expect(described_class.tag_bodies("<%%>")).to eq("")
    end

    it "blanks a Ruby comment inside a code tag" do
      expect(described_class.tag_bodies(%(<% # render "x" %>)).strip).to eq("")
      expect(described_class.tag_bodies("<%\n # @legacy = 1\n%>").strip).to eq("")
      expect(described_class.tag_bodies("<% x = 1 # @ghost %>").strip).to eq("x = 1")
    end

    # Erubi prints `<%%= @hidden %>` as the text `<%= @hidden %>`.
    it "blanks one tag's trailing comment without reaching the next tag on its line" do
      bodies = described_class.tag_bodies(%(<% # tail %><%= @z %>\n<%= link_to "#", "#" + @y %>))

      expect(bodies).to include("@z", %(link_to "#", "#" + @y))
      expect(bodies).not_to include("tail")
    end

    it "reads a template's tags in one parse, kept out of the shared parse cache" do
      source = (1..20).map { |i| "<%= @a#{i} # note #{i} %>\n" }.join
      expect(RailsAiContext::AstCache).to receive(:parse_uncached).once.and_call_original
      expect(RailsAiContext::AstCache).not_to receive(:parse_string)

      expect(described_class.tag_bodies(source).scan(/@a\d+/).size).to eq(20)
    end

    it "reads an escaped <%% tag as text, not code" do
      expect(described_class.tag_bodies("<p><%%= @hidden %></p>\n<%= @shown %>\n")).to eq(" @shown ")
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

    it "keeps a code tag whose first line is a Ruby comment, and a one-line comment swallows nothing after it" do
      result = described_class.ruby_in_place("<% # note\n @x.each do |y| %>\n<% # tail %><% @z %>")

      expect(result.lines[1]).to include("@x")
      expect(Prism.parse(result.lines[2]).value.statements.body.size).to eq(1)
    end

    it "keeps a string line that starts with #, and blanks a trailing comment" do
      source = %(<% s = "a\n\#{b}" %>\n<%= s %><% foo # note %><% bar %>)
      result = described_class.ruby_in_place(source)

      expect(result.count("\n")).to eq(source.count("\n"))
      expect(Prism.parse(result).errors).to be_empty
      expect(result).not_to include("note")
      expect(result).to include("bar")
    end

    it "keeps a heredoc line that starts with #" do
      source = %(<% t = <<~MD\n\#{ENV["X"]}\nMD\n%>)

      expect(described_class.ruby_in_place(source)).to include('ENV["X"]')
    end
  end

  describe ".tagged?" do
    it "is false for plain HTML" do
      expect(described_class.tagged?("<p>hi</p>")).to be(false)
    end
  end
end
