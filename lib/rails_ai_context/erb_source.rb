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

    # The tag bodies, joined. Order is kept; line numbers are not.
    def tag_bodies(source)
      source.to_s.scan(TAG).flatten.join("\n")
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
        out << (body.lstrip.start_with?("#") ? blank(body) : body)
        last = match.end(0)
      end
      out << blank(text[last..].to_s)
      out
    end

    def blank(text)
      text.gsub(/[^\n]/, " ")
    end
    private_class_method :blank
  end
end
