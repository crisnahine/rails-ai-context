# frozen_string_literal: true

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
    # cannot see, and a marker there would break the YAML around it.
    def with_output_marked(source, marker)
      source = source.to_s
      source.gsub(TAG) do
        match = Regexp.last_match
        tag = match[0]
        next "\n" * tag.count("\n") unless tag.start_with?("<%=") && !own_line?(source, match.begin(0), match.end(0))

        marker
      end
    end

    def own_line?(source, from, to)
      line_start = from.zero? ? 0 : (source.rindex("\n", from - 1) || -1) + 1
      line_end = source.index("\n", to) || source.size
      source[line_start...from].strip.empty? && source[to...line_end].strip.empty?
    end
    private_class_method :own_line?

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
