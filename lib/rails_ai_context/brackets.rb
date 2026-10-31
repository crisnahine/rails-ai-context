# frozen_string_literal: true

module RailsAiContext
  # Matching brackets in Ruby or JavaScript source read as text: a render
  # call's arguments, a Stimulus `static values` object, a bundler alias block.
  module Brackets
    PAIRS = { "(" => ")", "[" => "]", "{" => "}", "<" => ">" }.freeze
    OPENERS = [ "(", "[", "{" ].freeze
    QUOTES = %w[" ' `].freeze
    COMMENTS = {
      js: /\G(?:\/\/[^\n]*|\/\*.*?\*\/)/m,
      ruby: /\G#[^\n]*/
    }.freeze
    STRING = /\A(["'`])(?:\\.|(?!\1).)*\1/m
    # A `/` opens a JS regex literal, a `?` a Ruby character and a `%` a Ruby
    # percent literal only where an operand can start, not after a value.
    OPERAND_START = /[(\[{,=:;!&|?+\-*%~^<>]/
    OPERAND_KEYWORDS = {
      js: %w[return typeof case in of delete void throw new else do yield await instanceof].freeze,
      ruby: %w[return if unless while until and or not when in then else elsif do yield puts p].freeze
    }.freeze
    # `$x`, `@x` and `#x` are names, not keywords.
    NAME_CHAR = /[[:word:]$@#]/
    # The interpolation sigil and the quotes whose strings read it as code.
    INTERPOLATION = { ruby: [ "#", %w[" `] ], js: [ "$", %w[`] ] }.freeze
    # A `/.../` regex literal, JavaScript's or Ruby's: a `/` inside a character class does not close it.
    REGEX_LITERAL = %r{\G/(?:\\.|\[(?:\\.|[^\]\\\n])*\]|[^/\\\n])+/[a-z]*}
    RUBY_CHAR = /\G\?(?:\\.|[^\s\w])(?![\w])/
    RUBY_PERCENT = /\G%[qQwWiIrs]?([(\[{<|!\/])/
    MODIFIER = /\A(?:if|unless|while|until|rescue)\b/
    LITERAL_START = %r{["'`/#?%]}

    module_function

    # Walks text one top-level piece at a time: a whole bracket group (:group), a
    # string (:string), a comment (:comment), another literal (:literal), or a character.
    def each_top_level(text, comments: nil)
      i = 0
      while i < text.length
        piece, kind =
          if (span = span(text, i, comments: comments)) then [ span, :group ]
          elsif (length, literal = literal_at(text, i, comments)) then [ text[i, length], literal ]
          else [ text[i], :char ]
          end
        yield piece, kind
        i += piece.length
      end
    end

    # The text from the bracket at `open` through the one that closes it,
    # skipping strings, comments and the language's literals; nil when it never closes.
    # ponytail: no heredocs, and interpolation is read as code only in double-quoted and backtick Ruby strings and JS template literals, not in percent or regex literals; a real parser if that bites.
    def span(text, open, comments: nil)
      return nil unless OPENERS.include?(text[open])

      closer = PAIRS[text[open]]
      depth = 0
      i = open
      while i < text.length
        skipped, = literal_at(text, i, comments)
        if skipped
          i += skipped
          next
        end

        char = text[i]
        depth += 1 if char == text[open]
        if char == closer
          depth -= 1
          return text[open..i] if depth.zero?
        end
        i += 1
      end
      nil
    end

    # `text` with each comment blanked to spaces, newlines kept, so every offset still points at the source.
    def without_comments(text, comments:)
      out = text.dup
      i = 0
      while (i = text.index(LITERAL_START, i))
        length, kind = literal_at(text, i, comments)
        out[i, length] = text[i, length].tr("^\n", " ") if kind == :comment
        i += length || 1
      end
      out
    end

    # The inside of the group `text` opens with, when nothing but a trailing
    # modifier (`... if x`) follows it; otherwise `text` as it is.
    def unwrap(text, comments: :ruby)
      group = span(text, 0, comments: comments)
      return text unless group

      rest = text[group.length..].strip
      rest.empty? || rest.match?(MODIFIER) ? group[1...-1] : text
    end

    # The length and kind of a string, comment or other literal starting at i, or nil.
    def literal_at(text, i, comments)
      char = text[i]
      return [ string_length(text, i, comments), :string ] if QUOTES.include?(char)

      if comments && (match = text.match(COMMENTS[comments], i)) && match.begin(0) == i
        return [ match[0].length, :comment ]
      end
      return nil unless "/?%".include?(char) && operand_start?(text, i, comments)

      match =
        if char == "/" then text.match(REGEX_LITERAL, i)
        elsif comments == :ruby && char == "?" then text.match(RUBY_CHAR, i)
        elsif comments == :ruby && char == "%" then text.match(RUBY_PERCENT, i)
        end
      return nil unless match&.begin(0) == i

      [ char == "%" ? percent_length(text, i, match) : match[0].length, :literal ]
    end

    def string_length(text, i, comments = nil)
      sigil, quotes = INTERPOLATION[comments]
      return interpolated_length(text, i, sigil, comments) if quotes&.include?(text[i])

      match = text[i..][STRING]
      match ? match.length : text.length - i
    end

    # A string whose `#{...}` or `${...}` is read as code, nested strings included.
    def interpolated_length(text, i, sigil, comments)
      quote = text[i]
      j = i + 1
      while j < text.length
        char = text[j]
        if char == "\\"
          j += 2
        elsif char == quote
          return j - i + 1
        elsif char == sigil && text[j + 1] == "{"
          group = span(text, j + 1, comments: comments) or return text.length - i
          j += 1 + group.length
        else
          j += 1
        end
      end
      text.length - i
    end

    def operand_start?(text, i, comments = nil)
      j = i - 1
      j -= 1 while j >= 0 && text[j].match?(/\s/)
      j.negative? || text[j].match?(OPERAND_START) || after_keyword?(text, j, comments)
    end

    # `x.return / 2` calls a method named like the keyword, so its `/` divides.
    def after_keyword?(text, last, comments)
      keywords = OPERAND_KEYWORDS[comments] or return false
      first = last + 1
      first -= 1 while first.positive? && text[first - 1].match?(NAME_CHAR)
      keywords.include?(text[first..last]) && (first.zero? || text[first - 1] != ".")
    end

    # `%w[a )]`: the literal runs to the delimiter that closes it, nesting for
    # bracket delimiters and honouring escapes.
    def percent_length(text, i, match)
      opener = match[1]
      closer = PAIRS[opener] || opener
      depth = 0
      j = match.end(0) - 1
      while j < text.length
        char = text[j]
        if char == "\\"
          j += 2
          next
        end
        if opener != closer && char == opener && j > match.end(0) - 1
          depth += 1
        elsif char == closer && j > match.end(0) - 1
          return j - i + 1 if depth.zero?

          depth -= 1
        end
        j += 1
      end
      text.length - i
    end
  end
end
