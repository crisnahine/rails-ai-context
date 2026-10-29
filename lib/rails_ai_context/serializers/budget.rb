# frozen_string_literal: true

module RailsAiContext
  module Serializers
    # Every size rule a context file follows. These files share the agent's
    # context with the user's own instructions, and Codex stops reading project
    # docs at 32 KiB in all, so the aim is the fewest bytes that still steer the
    # agent: a list names what fits a line and counts the rest, since the tools
    # answer in full.
    module Budget
      # Bytes of a whole file, by what it is.
      BYTES = { root: 12_000, full: 24_000, rule: 8_000 }.freeze

      # A wider line is cut at an item boundary.
      LINE_WIDTH = 240

      # How many of a list a file names before it counts the rest.
      CAPS = {
        key_models: 10, listed_rows: 30, listed_controllers: 25, names: 12, methods: 20,
        mounted: 5, in_repo_engines: 5, databases: 3, patterns: 8, architecture: 5, locales: 5
      }.freeze

      module_function

      def cap(name)
        CAPS.fetch(name)
      end

      # The items that fit one line after `lead`, at most `cap` of them, then
      # how many more there are.
      def list(items, cap: nil, lead: "", width: LINE_WIDTH)
        items = Array(items).map(&:to_s)
        shown = []
        items.each_with_index do |item, i|
          break if cap && i >= cap

          rest = items.size - i - 1
          candidate = lead + [ *shown, item ].join(", ") + (rest.positive? ? ", ...#{rest} more" : "")
          break if candidate.size > width

          shown << item
        end
        return "#{lead}...#{items.size} more" if shown.empty? && items.any?

        left = items.size - shown.size
        lead + [ *shown, ("...#{left} more" if left.positive?) ].compact.join(", ")
      end

      # A list that has to stay whole, over as many lines of the width as it
      # takes, the later ones indented under the lead.
      def wrap(items, lead: "", width: LINE_WIDTH)
        lines = [ lead.dup ]
        Array(items).map(&:to_s).each_with_index do |item, i|
          piece = i.zero? ? item : ", #{item}"
          if lines.last.size + piece.size > width && lines.last.strip != lead.strip
            lines[-1] = "#{lines.last},"
            lines << "  #{item}"
          else
            lines[-1] = lines.last + piece
          end
        end
        lines
      end

      # The head, as much of the body as fits the kind's bytes and the line
      # budget, then the kept sections whole. The body is cut from the bottom,
      # a cut marked with the note; the head and the kept sections are what a
      # file is for, so they are never cut. `reserve` is what the writer adds
      # around the text, a managed block's markers.
      def fit(head:, body:, keep:, kind:, note:, max_lines: nil, reserve: 0)
        bytes = BYTES.fetch(kind) - reserve
        whole = [ *head, *body, *keep ]
        return whole.join("\n") if fits?(whole, bytes, max_lines)

        tail = keep.empty? ? [] : [ "", *keep ]
        kept = body.dup
        kept.pop until kept.empty? || fits?([ *head, *kept, "", note, *tail ], bytes, max_lines)
        kept = close_cut(kept)
        [ *head, *kept, *("" if kept.any?), note, *tail ].join("\n")
      end

      def fits?(lines, bytes, max_lines)
        lines.join("\n").bytesize <= bytes && (max_lines.nil? || content_lines(lines) <= max_lines)
      end

      def content_lines(lines)
        lines.join("\n").split("\n").count { |line| !line.strip.empty? }
      end

      # A block cut open renders everything after it as code, and a heading
      # whose body was cut claims content that is not there.
      def close_cut(lines)
        open_at = nil
        lines.each_with_index { |line, i| open_at = open_at.nil? ? i : nil if line.lstrip.start_with?("```", "~~~") }
        lines = lines[0...open_at] if open_at
        lines = lines.dup
        lines.pop while lines.any? && (lines.last.strip.empty? || lines.last.lstrip.start_with?("#"))
        lines
      end
    end
  end
end
