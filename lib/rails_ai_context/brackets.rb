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
    # A `/.../` regex literal, JavaScript's or Ruby's: a `/` inside a character class does not close it.
    REGEX_LITERAL = %r{\G/(?:\\.|\[(?:\\.|[^\]\\\n])*\]|[^/\\\n])+/[a-z]*}
    RUBY_CHAR = /\G\?(?:\\.|[^\s\w])(?![\w])/
    RUBY_PERCENT = /\G%[qQwWiIrs]?([(\[{<|!\/])/

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
    # ponytail: no heredocs, and a quote or slash inside `#{...}` interpolation ends the literal early; a real parser if that bites.
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

    # The length and kind of a string, comment or other literal starting at i, or nil.
    def literal_at(text, i, comments)
      char = text[i]
      return [ string_length(text, i), :string ] if QUOTES.include?(char)

      if comments && (match = text.match(COMMENTS[comments], i)) && match.begin(0) == i
        return [ match[0].length, :comment ]
      end
      return nil unless "/?%".include?(char) && operand_start?(text, i)

      match =
        if char == "/" then text.match(REGEX_LITERAL, i)
        elsif comments == :ruby && char == "?" then text.match(RUBY_CHAR, i)
        elsif comments == :ruby && char == "%" then text.match(RUBY_PERCENT, i)
        end
      return nil unless match&.begin(0) == i

      [ char == "%" ? percent_length(text, i, match) : match[0].length, :literal ]
    end

    def string_length(text, i)
      match = text[i..][STRING]
      match ? match.length : text.length - i
    end

    def operand_start?(text, i)
      j = i - 1
      j -= 1 while j >= 0 && text[j].match?(/\s/)
      j.negative? || text[j].match?(OPERAND_START)
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
