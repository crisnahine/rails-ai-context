# frozen_string_literal: true

module RailsAiContext
  # Source-scanning helpers for the tools that read Ruby without a full
  # parse (Turbo broadcast scans, retry_on option scans).
  module SourceLine
    # %-literal type letters that open a string-like literal (%w[], %i(),
    # %q{}, %r//, %x``, ...). A bare % followed by a non-alphanumeric
    # delimiter (%(...)) opens one too.
    PERCENT_TYPES = "wWiIqQrsx"

    # Paired delimiters nest; anything else closes on the same character.
    PERCENT_PAIRS = { "(" => ")", "[" => "]", "{" => "}", "<" => ">" }.freeze

    # Literals whose bodies interpolate (so "#{...}" must be tracked).
    INTERPOLATING = [ '"', "`" ].freeze

    module_function

    # Remove Ruby comments from a source fragment (a single line or several
    # joined lines), respecting string, backtick, and %-literals: a '#'
    # inside "..."/'...'/`...`/%w[...] is content, and interpolation braces
    # are tracked so a '#' after a closed interpolation still counts as
    # inside its literal. Literal state carries across newlines, so a
    # multi-line string does not lose its tail, and =begin/=end block
    # comments are removed up front. Heuristic, not a lexer - /regex/
    # literals, ?# char literals, and heredoc bodies are not modeled.
    # Newlines and any trailing-newline shape are preserved.
    def strip_comments(text)
      # =begin/=end block comments first: their prose ("doesn't") would
      # otherwise open phantom string literals that poison the state for
      # the rest of the fragment. Newlines are kept so line numbers hold.
      if text.include?("=begin")
        text = text.gsub(/^=begin\b.*?(?:^=end\b[^\n]*(?:\n|\z)|\z)/m) { |block| "\n" * block.count("\n") }
      end

      # Fast path: no '#' at all (the overwhelmingly common case).
      return text unless text.include?("#")

      chars = text.chars
      out = []
      i = 0
      quote = nil       # the character that closes the current literal
      quote_open = nil  # the opener, when it differs (paired % delimiters)
      interp = 0
      while i < chars.length
        ch = chars[i]
        if ch == "\\"
          out << ch << chars[i + 1].to_s
          i += 2
          next
        end
        if quote
          if interp.positive?
            # A string nested inside the interpolation may contain braces
            # ("#{ "}" }") - copy it whole so they don't skew the count.
            if ch == '"' || ch == "'" || ch == "`"
              inner = ch
              out << ch
              i += 1
              while i < chars.length && chars[i] != inner
                if chars[i] == "\\"
                  out << chars[i] << chars[i + 1].to_s
                  i += 2
                else
                  out << chars[i]
                  i += 1
                end
              end
              out << chars[i].to_s
              i += 1
              next
            end
            interp += 1 if ch == "{"
            interp -= 1 if ch == "}"
          elsif ch == "#" && INTERPOLATING.include?(quote) && chars[i + 1] == "{"
            interp = 1
            out << ch << "{"
            i += 2
            next
          elsif ch == quote_open && quote_open != quote
            # nested paired delimiter inside a %-literal: copy to its close
            depth = 1
            out << ch
            i += 1
            while i < chars.length && depth.positive?
              depth += 1 if chars[i] == quote_open
              depth -= 1 if chars[i] == quote
              out << chars[i]
              i += 1
            end
            next
          elsif ch == quote
            quote = nil
            quote_open = nil
          end
        elsif ch == '"' || ch == "'" || ch == "`"
          quote = ch
        elsif ch == "%" && (delim = percent_delimiter(chars, i))
          quote_open = delim
          quote = PERCENT_PAIRS[delim] || delim
          if PERCENT_TYPES.include?(chars[i + 1].to_s)
            out << ch << chars[i + 1] << chars[i + 2]
            i += 3
          else
            out << ch << chars[i + 1]
            i += 2
          end
          next
        elsif ch == "#"
          # comment: skip to (not past) the next newline
          i += 1 until i >= chars.length || chars[i] == "\n"
          next
        end
        out << ch
        i += 1
      end
      out.join
    end

    # Single-line form, kept for call sites that scan line by line.
    def strip_comment(line)
      strip_comments(line)
    end

    # The executable portion of one source line for call-site scanning.
    # A `def` line - including visibility-prefixed forms like `private def`
    # or `private_class_method def self.x` - contributes only its body:
    # nothing for a plain signature (names and parameter defaults are
    # declarations, not calls: `def notify(via: :broadcast_x_to)`), the
    # part after a top-level `=` for an endless method, and the part after
    # a top-level `;` for a classic one-liner (`def x; call; end`).
    def executable_part(line)
      m = line.match(/\A\s*(?:[a-z_]\w*\s+)*def\b/)
      return line unless m

      depth = 0
      quote = nil
      chars = line.chars
      i = m.end(0)
      while i < chars.length
        ch = chars[i]
        if ch == "\\"
          i += 2
          next
        end
        if quote
          if ch == "#" && quote == '"' && chars[i + 1] == "{"
            # Interpolation inside a string default: skip to its matching
            # close brace, copying nested strings whole, so quotes and
            # delimiters inside `#{...}` can't flip the walk's state.
            depth_braces = 1
            i += 2
            while i < chars.length && depth_braces.positive?
              case chars[i]
              when "\\" then i += 1
              when "{" then depth_braces += 1
              when "}" then depth_braces -= 1
              when '"', "'"
                inner = chars[i]
                i += 1
                while i < chars.length && chars[i] != inner
                  i += chars[i] == "\\" ? 2 : 1
                end
              end
              i += 1
            end
            next
          end
          quote = nil if ch == quote
          i += 1
          next
        end
        case ch
        when '"', "'" then quote = ch
        when "(" then depth += 1
        when ")" then depth -= 1
        when ";"
          # A `;` inside a string default (`sep: "; "`) is content, handled
          # by the quote branch above; a bare top-level `;` ends the
          # signature of a classic one-liner.
          return chars[(i + 1)..].join if depth.zero?
        when "="
          if depth.zero? && chars[i + 1] != "=" && chars[i - 1] != "=" && chars[i - 1] != "!" &&
             chars[i - 1] != "<" && chars[i - 1] != ">"
            return chars[(i + 1)..].join
          end
        end
        i += 1
      end
      ""
    end

    # The delimiter of a %-literal starting at chars[i] ("%"), or nil when
    # this % is arithmetic/format (e.g. `n % 2`, `"%s" % x`).
    def percent_delimiter(chars, i)
      nxt = chars[i + 1]
      return nil if nxt.nil?

      if PERCENT_TYPES.include?(nxt)
        delim = chars[i + 2]
        delim if delim && delim !~ /[[:alnum:][:space:]]/
      elsif nxt !~ /[[:alnum:][:space:]=]/
        nxt
      end
    end
  end
end
