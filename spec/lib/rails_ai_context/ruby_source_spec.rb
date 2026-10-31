# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::RubySource do
  describe ".without_comments" do
    it "blanks a line comment and keeps the code and every line" do
      source = "render :edit # render :new\nredirect_to root_path\n"
      text = described_class.without_comments(source)

      expect(text).not_to include("render :new")
      expect(text).to include("render :edit", "redirect_to root_path")
      expect(text.lines.size).to eq(source.lines.size)
    end

    it "blanks a =begin block and the __END__ section" do
      source = "x = 1\n=begin\nI18n.default_locale = :fr\n=end\ny = 2\n__END__\nPost.all\n"
      text = described_class.without_comments(source)

      expect(text).not_to include("default_locale", "Post.all")
      expect(text).to include("x = 1", "y = 2")
    end

    it "keeps every character offset after a multibyte comment" do
      source = "a = 1 # café ☕\nbroadcast_to :room\n"
      text = described_class.without_comments(source)

      expect(text.index("broadcast_to")).to eq(source.index("broadcast_to"))
      expect(text.length).to eq(source.length)
    end

    it "keeps a hash inside a string, which is not a comment" do
      expect(described_class.without_comments(%(x = "a # b"\n))).to eq(%(x = "a # b"\n))
    end
  end

  describe ".code_only" do
    it "blanks string bodies and keeps the quotes and interpolated code" do
      text = described_class.code_only(%(log "render x"\nmail "a\#{user.email}b"\n))

      expect(text).not_to include("render x")
      expect(text).to include("user.email", %(log "))
    end

    it "blanks a heredoc body but keeps the code it interpolates" do
      source = "SQL = <<~TXT\n  def fake\n  \#{helper_call}\nTXT\nreal_call\n"
      text = described_class.code_only(source)

      expect(text).not_to include("def fake")
      expect(text).to include("helper_call", "real_call")
      expect(text.lines.size).to eq(source.lines.size)
    end

    it "blanks regex bodies and comments" do
      text = described_class.code_only("x =~ /Post\\.all/ # Post.all\nPost.first\n")

      expect(text).not_to include("Post.all")
      expect(text).to include("Post.first")
    end

    it "keeps symbols, which name things code reads" do
      expect(described_class.code_only("render :edit, status: :ok\n")).to eq("render :edit, status: :ok\n")
    end

    it "returns text of the same length for source that does not parse" do
      source = "def broken(\n  # note\n  \"str\"\n"
      expect(described_class.code_only(source).length).to eq(source.length)
    end
  end

  describe "a snippet read with cache: false" do
    it "gives the same text and keeps nothing in the shared parse cache" do
      snippet = %( link_to "a # b", path # note #{rand(1_000_000)}\n)
      expect { described_class.code_only(snippet, cache: false) }.not_to(change { RailsAiContext::AstCache::STORE.size })
      expect(described_class.code_only(snippet, cache: false)).to eq(described_class.code_only(snippet))
    end

    it "is parsed once per run however often it is asked for" do
      snippet = %( x = 1 # note #{rand(1_000_000)}\n)
      expect(RailsAiContext::AstCache).to receive(:parse_uncached).once.and_call_original
      RailsAiContext::RunCache.around do
        3.times { described_class.without_comments(snippet, cache: false) }
      end
    end
  end
end
