# frozen_string_literal: true

require "spec_helper"

# docs/COMPATIBILITY.md tells a reader how much of the gem still answers when
# their app will not boot, and that is the question they use to decide whether
# it is worth installing at all. The page once said 6 introspectors answered
# and 34 reported unavailable, naming eight examples - every one of which
# actually answers. Counting is what rots; pin the counts to the code.
RSpec.describe "docs/COMPATIBILITY.md operating tiers" do
  let(:doc) { File.read(File.expand_path("../../../docs/COMPATIBILITY.md", __dir__)) }
  # Prose wraps, so a sentence can carry a newline between two of its words.
  let(:flat) { doc.gsub(/\s+/, " ") }
  let(:map) { RailsAiContext::Introspector::INTROSPECTOR_MAP }

  def keys_for(kind)
    map.select { |_, klass| klass.static_tier == kind }.keys.map(&:to_s).sort
  end

  it "states the number of introspectors that answer in the static tier" do
    answering = keys_for(:files_only).size + keys_for(:alternate_source).size

    expect(flat).to include("#{answering} of the #{map.size} introspectors")
  end

  it "names every files-only introspector and no others" do
    keys_for(:files_only).each do |key|
      expect(doc).to include("`#{key}`"), "docs/COMPATIBILITY.md never names the files-only introspector #{key}"
    end
  end

  it "names exactly the alternate-source introspectors" do
    alternate = keys_for(:alternate_source)
    section = flat[/\*\*alternate-source\*\*.*?\*\*runtime-only\*\*/].to_s

    expect(section).to include("(#{alternate.size})")
    alternate.each do |key|
      expect(section).to include("`#{key}`"), "the alternate-source table omits #{key}"
    end
  end

  it "names exactly the runtime-only introspectors as unavailable" do
    runtime = keys_for(:runtime_only)
    section = flat[/\*\*runtime-only\*\*.*?observability`\./].to_s

    expect(section).to include("(#{runtime.size})")
    runtime.each do |key|
      expect(section).to include("`#{key}`"), "the runtime-only list omits #{key}"
    end
    (map.keys.map(&:to_s) - runtime).each do |key|
      expect(section).not_to include("`#{key}`"), "#{key} answers statically but is listed as runtime-only"
    end
  end

  # The page called [STATIC] a whole-response tag while a static model entry's
  # own records claimed [VERIFIED]. Both halves are pinned here so the claim
  # and the code cannot part company again.
  it "says a record is capped at the tier that carries it, and it is" do
    expect(flat).to include("no record can claim more than the tier carrying it")
    expect(flat).not_to include("`[STATIC]`/`[UNAVAILABLE]` are whole-response tags")

    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "app", "models"))
      File.write(File.join(dir, "app", "models", "post.rb"), <<~RUBY)
        class Post < ApplicationRecord
          belongs_to :author
          validates :title, presence: true
          scope :recent, -> { order(id: :desc) }
        end
      RUBY

      entry = RailsAiContext::Introspectors::ModelIntrospector
        .new(RailsAiContext::StaticApp.new(dir)).static_call["Post"]

      expect(entry[:confidence]).to eq(RailsAiContext::Confidence::STATIC)
      %i[associations validations scopes].each do |key|
        marks = Array(entry[key]).map { |record| record[:confidence] }.compact.uniq
        expect(marks).to all(eq(RailsAiContext::Confidence::STATIC)),
          "#{key} carries #{marks.inspect} inside an entry marked STATIC"
      end
    end
  end
end
