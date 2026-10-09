# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "open3"
require "rbconfig"

RSpec.describe RailsAiContext::Serializers::SectionMarkerWriter do
  let(:begin_marker) { described_class::BEGIN_MARKER }
  let(:end_marker) { described_class::END_MARKER }

  it "replaces only the block between the markers" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "CLAUDE.md")
      File.write(path, "# Mine\n\n#{begin_marker}\nold\n#{end_marker}\n\nmore of mine\n")

      expect(described_class.write_with_markers(path, "new")).to eq(:written)
      expect(File.read(path)).to eq("# Mine\n\n#{begin_marker}\nnew\n#{end_marker}\n\nmore of mine\n")
    end
  end

  # A C locale tags what File.read returns US-ASCII, and the first character
  # outside it stopped every later run.
  it "rewrites a file holding text outside ASCII in a C locale" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "CLAUDE.md")
      File.write(path, "# Café — notes\n\n#{begin_marker}\nold ✓\n#{end_marker}\n")
      lib = File.expand_path("../../../../lib", __dir__)
      script = <<~RUBY
        require "rails_ai_context/safe_file"
        require "rails_ai_context/serializers/section_marker_writer"
        print RailsAiContext::Serializers::SectionMarkerWriter.write_with_markers(ARGV[0], "new \\u2713")
      RUBY

      out, err, status = Open3.capture3({ "LANG" => "C", "LC_ALL" => "C" }, RbConfig.ruby, "-I", lib, "-e", script, path)

      expect(status.success?).to be(true), err
      expect(out).to eq("written")
      expect(File.binread(path).force_encoding("UTF-8")).to eq("# Café — notes\n\n#{begin_marker}\nnew ✓\n#{end_marker}\n")
    end
  end

  # What lies outside the block is written back as it came.
  it "keeps the bytes of a file that is not UTF-8" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "CLAUDE.md")
      File.binwrite(path, "caf\xE9\n\n#{begin_marker}\nold\n#{end_marker}\n".b)

      described_class.write_with_markers(path, "new ✓")

      expect(File.binread(path)).to eq("caf\xE9\n\n#{begin_marker}\nnew ✓\n#{end_marker}\n".b)
    end
  end
end
