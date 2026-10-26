# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::ManagedBlock do
  let(:open_mark) { described_class::BEGIN_MARKER }
  let(:close_mark) { described_class::END_MARKER }
  let(:bom) { "\uFEFF" }

  def block(content, newline = "\n")
    "#{open_mark}#{newline}#{content}#{newline}#{close_mark}#{newline}"
  end

  describe ".state" do
    {
      "no marker" => [ "# Mine\n", :none ],
      "one BEGIN before one END" => [ "# Mine\n<!-- BEGIN rails-ai-context -->\nx\n<!-- END rails-ai-context -->\n", :pair ],
      "a lone BEGIN" => [ "<!-- BEGIN rails-ai-context -->\nx\n", :unpaired ],
      "a lone END" => [ "x\n<!-- END rails-ai-context -->\n", :unpaired ],
      "two BEGIN and one END" => [ "<!-- BEGIN rails-ai-context -->\na\n<!-- BEGIN rails-ai-context -->\nb\n<!-- END rails-ai-context -->\n", :unpaired ],
      "END before BEGIN" => [ "<!-- END rails-ai-context -->\nx\n<!-- BEGIN rails-ai-context -->\n", :unpaired ],
      "two whole blocks" => [ "<!-- BEGIN rails-ai-context -->\na\n<!-- END rails-ai-context -->\n<!-- BEGIN rails-ai-context -->\nb\n<!-- END rails-ai-context -->\n", :unpaired ]
    }.each do |layout, (text, state)|
      it "reads #{layout} as #{state}" do
        expect(described_class.state(text)).to eq(state)
      end
    end
  end

  describe ".replace" do
    it "replaces only the block, a backslash in the content kept as written" do
      text = "# Mine\n\n#{block('old')}\nmore of mine\n"

      expect(described_class.replace(text, "new \\1")).to eq("# Mine\n\n#{block('new \\1')}\nmore of mine\n")
    end

    it "puts a first block above the file's text, with one blank line between" do
      expect(described_class.replace("# Mine\n", "new")).to eq("#{block('new')}\n# Mine\n")
    end

    it "is the block alone for an empty file" do
      expect(described_class.replace("", "new")).to eq(block("new"))
    end

    # A heading that starts with U+FEFF is no heading, and the BOM is the file's, not the line's.
    it "keeps a leading BOM first" do
      expect(described_class.replace("#{bom}# Mine\n", "new")).to eq("#{bom}#{block('new')}\n# Mine\n")
      expect(described_class.replace("#{bom}#{block('old')}", "new")).to eq("#{bom}#{block('new')}")
    end

    # An earlier release prepended its block above the BOM, which then sat mid-file and kept the heading from rendering.
    it "moves a BOM a prepended block left under it back to the front" do
      expect(described_class.replace("#{block('old')}\n#{bom}# Mine\n", "new")).to eq("#{bom}#{block('new')}\n# Mine\n")
      expect(described_class.replace("#{block('old', "\r\n")}\r\n#{bom}# Mine\r\n", "new"))
        .to eq("#{bom}#{block('new', "\r\n")}\r\n# Mine\r\n")
      expect(described_class.replace("# Mine\n#{block('old')}\n#{bom}more\n", "new")).to eq("# Mine\n#{block('new')}\n#{bom}more\n")
    end

    it "writes the block in the file's CRLF line endings" do
      text = "# Mine\r\n\r\n#{block('old', "\r\n")}"

      expect(described_class.replace(text, "new\nlines")).to eq("# Mine\r\n\r\n#{block("new\r\nlines", "\r\n")}")
      expect(described_class.replace("# Mine\r\n", "new")).to eq("#{block('new', "\r\n")}\r\n# Mine\r\n")
    end

    it "joins a file that is no UTF-8 as bytes" do
      text = "caf\xE9\n".b

      expect(described_class.replace(text, "new ✓")).to eq("#{block('new ✓')}\ncaf\xE9\n".b)
    end

    it "is nil when the markers do not pair up" do
      expect(described_class.replace("#{open_mark}\na\n#{open_mark}\nb\n#{close_mark}\n", "new")).to be_nil
    end
  end

  describe ".remove" do
    it "takes the block out and leaves the user's lines" do
      expect(described_class.remove("# Mine\n\n#{block('x')}\nmore\n")).to eq("# Mine\n\n\nmore\n")
    end

    it "takes the blank line the writer put under a prepended block with it" do
      expect(described_class.remove("#{block('x')}\n# Mine\n")).to eq("# Mine\n")
      expect(described_class.remove("#{block('x', "\r\n")}\r\n# Mine\r\n")).to eq("# Mine\r\n")
    end

    it "keeps a leading BOM first" do
      expect(described_class.remove("#{bom}#{block('x')}\n# Mine\n")).to eq("#{bom}# Mine\n")
    end

    it "is the text unchanged when it holds no block" do
      expect(described_class.remove("# Mine\n")).to eq("# Mine\n")
    end

    # Nothing says where the block ends, so taking a guess at it took the user's lines.
    it "is nil when the markers do not pair up" do
      text = "# Team\n#{open_mark}\nold\n## My team rules\nNever push to main\n#{open_mark}\nstale\n#{close_mark}\n"

      expect(described_class.remove(text)).to be_nil
    end

    it "works on bytes that are no UTF-8" do
      expect(described_class.remove("#{block('x')}\ncaf\xE9\n".b)).to eq("caf\xE9\n".b)
    end
  end
end
