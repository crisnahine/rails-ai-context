# frozen_string_literal: true

require "erb"

module RailsAiContext
  # The Ruby inside ERB tags. Two readers need it for different reasons - a
  # template's ivars, and the ENV names a `.yml` or a view reads - and a
  # second copy of the tag regex is a second answer to "what is a tag".
  module ErbSource
    TAG = /<%={0,2}-?(.*?)-?%>/m

    module_function

    # @return [Boolean] whether the source carries any ERB tag at all
    def tagged?(source)
      source.to_s.include?("<%")
    end

    # The whole template as the Ruby it compiles to, for a parse. Rails'
    # Erubi trims with `-`, so `<%-` and `-%>` are tags and not a minus sign.
    # An output tag becomes a code tag: `<%= form_with do |f| %>` opens a
    # block Erubi allows and stdlib ERB would wrap in parentheses. Each
    # template line stays one line, below the magic comments ERB writes first.
    def compiled(source)
      src = +ERB.new(source.to_s.gsub("<%=", "<%"), trim_mode: "-").src
      src.force_encoding("UTF-8")
    end

    # How many lines `compiled` writes above the template's first: its
    # `#coding:` comment, and `#frozen-string-literal:` when the template
    # opens with that magic comment.
    def compiled_header_lines(src)
      src[/\A(?:#[^\n]*\n)*/].count("\n")
    end

    # The code tag bodies, joined. Order is kept; line numbers are not.
    def tag_bodies(source)
      source.to_s.scan(TAG).flatten.reject { |body| comment?(body) }.join("\n")
    end

    # Only `<%#` (or `<%-#`) is an ERB comment; `<% # note` is code whose first line is a Ruby comment.
    def comment?(body)
      body.to_s.start_with?("#")
    end

    # The same Ruby with everything outside the tags blanked rather than
    # dropped, so a line number in the result is still the line in the file.
    # A `<%#` comment is blanked too.
    def ruby_in_place(source)
      text = source.to_s
      out = +""
      last = 0
      text.to_enum(:scan, TAG).each do
        match = Regexp.last_match
        out << blank(text[last...match.begin(0)])
        body = match[1].to_s
        out << (comment?(body) ? blank(body) : blank_comment_lines(body))
        last = match.end(0)
      end
      out << blank(text[last..].to_s)
      out
    end

    # Tags go and their newlines stay, so the rest parses at its written indentation;
    # a value the file computed is absent rather than wrong.
    def without_tags(source)
      source.to_s.gsub(TAG) { "\n" * Regexp.last_match(0).count("\n") }
    end

    # Like without_tags, but an output tag (`<%= %>`) becomes `marker`, so a value
    # or key it builds reads as computed. A tag alone on its line writes lines we
    # cannot see, and a marker there would break the YAML around it, unless the
    # line above opens a value the tag fills. Each marker is numbered, so two keys tags name stay two keys.
    def with_output_marked(source, marker)
      source = source.to_s
      count = 0
      source.gsub(TAG) do
        match = Regexp.last_match
        tag = match[0]
        next "\n" * tag.count("\n") unless tag.start_with?("<%=") && !lines_written?(source, match.begin(0), match.end(0))

        "#{marker}_#{count += 1}_"
      end
    end

    BLOCK_SCALAR = /(?:\A|\s)[|>][-+0-9]*\z/
    VALUE_OPENER = /:\z/
    private_constant :BLOCK_SCALAR, :VALUE_OPENER

    def lines_written?(source, from, to)
      line_start = from.zero? ? 0 : (source.rindex("\n", from - 1) || -1) + 1
      line_end = source.index("\n", to) || source.size
      return false unless source[line_start...from].strip.empty? && source[to...line_end].strip.empty?

      above = source[0...line_start].rstrip.lines.last.to_s.rstrip
      return false if above.match?(BLOCK_SCALAR)
      return true unless above.match?(VALUE_OPENER)

      # A sibling at the tag's indent below means the tag wrote keys, not the value.
      below = source[line_end..].to_s.lines.find { |line| !line.strip.empty? }
      !below.nil? && indent(below) >= from - line_start
    end
    private_class_method :lines_written?

    def indent(line)
      line[/\A */].size
    end
    private_class_method :indent

    def blank(text)
      text.gsub(/[^\n]/, " ")
    end
    private_class_method :blank

    # Tags sharing a line are joined, so a comment left in would swallow the next tag's code.
    def blank_comment_lines(body)
      return body unless body.include?("#")

      out = body.b
      # Last first: a multibyte comment blanks to fewer bytes and would shift later offsets.
      AstCache.parse_string(body).comments.reverse_each do |comment|
        loc = comment.location
        out[loc.start_offset...loc.end_offset] = blank(loc.slice).b
      end
      out.force_encoding(body.encoding)
    end
    private_class_method :blank_comment_lines
  end
end
