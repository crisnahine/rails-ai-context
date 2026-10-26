# frozen_string_literal: true

require_relative "safe_file"

module RailsAiContext
  # The block this gem owns inside a file the user writes in too (CLAUDE.md,
  # AGENTS.md): its markers, the rule that they pair up, and reading,
  # replacing and removing it. The writer and the uninstall both go through
  # here, so a file one of them leaves as unpaired the other leaves too.
  #
  # Text in, text out, in the file's own encoding: the markers are ASCII, and
  # a file that is no UTF-8 is handled as bytes. Stdlib only, since the
  # standalone install loads it before the app boots.
  module ManagedBlock
    BEGIN_MARKER = "<!-- BEGIN rails-ai-context -->"
    END_MARKER   = "<!-- END rails-ai-context -->"

    BLOCK = /#{Regexp.escape(BEGIN_MARKER)}.*?#{Regexp.escape(END_MARKER)}(?:\r?\n)?/m

    # Why a run left a file alone: with a marker lost, or a second block
    # pasted in, nothing says where the gem's block ends.
    UNPAIRED = "unpaired rails-ai-context marker, left as it is"

    module_function

    # :pair for one BEGIN marker before one END marker, :none for neither,
    # :unpaired for anything else: a lone marker, two blocks, END first.
    def state(text)
      begins = text.scan(BEGIN_MARKER).size
      ends = text.scan(END_MARKER).size
      return :none if begins.zero? && ends.zero?
      return :pair if begins == 1 && ends == 1 && text.index(BEGIN_MARKER) < text.index(END_MARKER)

      :unpaired
    end

    # The text with `content` as its block: in place of the one it has, or
    # above the text with a blank line under it. nil when the markers do not
    # pair up, since replacing a guess at the block could take the user's text.
    def replace(text, content)
      marked = "#{BEGIN_MARKER}\n#{content}\n#{END_MARKER}\n"
      marked = marked.gsub(/\r?\n/, "\r\n") if crlf?(text)
      marked = marked.b if text.encoding == Encoding::BINARY

      case state(text)
      when :pair
        # An earlier release prepended its block above a BOM, leaving the BOM mid-file: written again from the front.
        unblocked = text.start_with?(BEGIN_MARKER) && remove(text)
        return replace(unblocked, content) if unblocked && !SafeFile.split_bom(unblocked).first.empty?

        # A block, so a backslash in the content is not read as a backreference.
        text.sub(BLOCK) { marked }
      when :none
        bom, rest = SafeFile.split_bom(text)
        rest.empty? ? "#{bom}#{marked}" : "#{bom}#{marked}#{crlf?(text) ? "\r\n" : "\n"}#{rest}"
      end
    end

    # The text without its block, unchanged when it holds none, nil when the
    # markers do not pair up.
    def remove(text)
      case state(text)
      when :none then text
      when :pair
        bom, rest = SafeFile.split_bom(text)
        trimmed = rest.sub(BLOCK, "")
        # The writer puts one blank line under a block it prepends.
        trimmed = trimmed.sub(/\A\r?\n/, "") if rest.start_with?(BEGIN_MARKER)
        "#{bom}#{trimmed}"
      end
    end

    def crlf?(text)
      text.include?("\r\n")
    end

    private_class_method :crlf?
  end
end
