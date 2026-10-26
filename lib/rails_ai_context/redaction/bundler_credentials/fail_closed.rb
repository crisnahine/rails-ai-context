# frozen_string_literal: true

autoload :StringScanner, "strscan"

module RailsAiContext
  module Redaction
    module BundlerCredentials
      # What the precise reading falls through to. Where a line names a gem server credential and the scanner
      # does not know the form that follows, every literal after the name is filtered, whatever it is written in;
      # a reference (`$VAR`, a template variable, an environment read, Ruby code that reads a value) stays. A line
      # that leaves the statement open hands the same rule to the lines after it. An unknown form loses text and
      # never leaks the secret.
      module FailClosed
        OCCURRENCE = /(?<![A-Za-z_$])(?<!\$\{)#{NAME}/
        HOST_CONFIG = /\bbundler?[ \t]++config(?:[ \t]++#{CONFIG_FLAG})*+[ \t]++["']?(?<host>#{CONFIG_KEY})["']?/
        GAP_AND_SPACE = /[\\"'\])*`+]*+[ \t]*+/
        ASSIGN_OPERATOR = /(?:=>|[?+:|&^*\/%-]{0,2}=(?!=)|:(?!:))[*`]*[ \t]*+/
        COMPARISON = /(?:==|!=|=~[ \t]|[<>]=)/
        FILLER = /(?:is|equals|to|as|be)\b[ \t]++/i
        MARKUP = /(?:<\/?[A-Za-z](?>[^>]{0,256})>|[>\/\s"'\])*`+])*+/
        RUN = /(?:[^\s"'`(){}\[\],;&|<>\\]|\\.)++/
        TOKEN = /[^\s"'`(){}\[\],;&|<>]++/
        VALUE_SHAPE = /[0-9:@\/+=%#!~^$]/
        RUBY_CODE = /\A(?:[@$]{0,2}[A-Za-z_]\w*[?!]?(?:(?:\.|::|&\.)[A-Za-z_]\w*[?!]?)*|:[A-Za-z_]\w*)\z/
        MESSAGE_TAIL = /\b(?:abort|raise|fail|puts|print|warn|p|pp|log|logger\.\w+|say|echo|error|info|debug|message)\s*\(?\s*\z/
        CONTINUATION = /(?:\\|\+|\|\||&&|\?|:|\b(?:or|and|not))\z/
        BLOCK_START = /\A[ \t]*(?:if|unless|while|until|for|def|class|module)\b/
        BLOCK_OPENER = /\b(?:do|begin|case)\b/
        VALUE_OPENERS = /(?:\\|\+|\|\||&&|\?|,|\(|\[|\{|=|=>|:)\z/

        private

        # { edits:, tail: } for the occurrences the precise reading did not understand: `handled` has the begin
        # of each it read, `blocked` the spans it replaced or kept.
        def fail_closed(text, kind, handled, blocked, opener)
          edits = []
          tail = nil
          done = 0
          occurrences(text).each do |from, to, host|
            next if handled[from] || to <= done || overlaps?(blocked, from, to)

            start, value = trigger(text, to, opener || host, kind)
            next unless start

            tail = [ start, value, start ]
            next unless value

            edits.concat(literal_edits(text, start, kind, blocked))
            done = text.bytesize
          end
          { edits: edits, tail: tail }
        end

        # Every credential name the line holds and every gem server a `bundle config` line names, as [begin, end].
        def occurrences(text)
          found = []
          at = 0
          while (match = OCCURRENCE.match(text, at))
            found << [ match.begin(0), match.end(0), false ] if credential?(match[0])
            at = match.end(0)
          end
          at = 0
          while text.include?("onfig") && (match = HOST_CONFIG.match(text, at))
            name = "BUNDLE_#{match[:host].upcase.gsub('.', '__')}"
            found << [ match.begin(:host), match.end(0), true ] if match[:host].match?(/\A#{DYNAMIC_KEY}/) || credential?(name)
            at = match.end(0)
          end
          found.sort
        end

        # [position the filtering starts at, whether a value follows on this line], or nil for a name that is only
        # mentioned: followed by a closer, a comparison or a plain word.
        def trigger(text, ending, comma, kind)
          scanner = StringScanner.new(text)
          scanner.pos = ending
          scanner.skip(GAP_AND_SPACE)
          return nil if scanner.eos?

          skipped = comma && scanner.skip(/,[ \t]*+/)
          return [ scanner.pos, !scanner.eos? ] if scanner.skip(ASSIGN_OPERATOR) || skipped
          return nil if scanner.match?(COMPARISON)

          nil while scanner.skip(FILLER)
          scanner.skip(MARKUP)
          return nil if scanner.eos? || ")]},;.".include?(text.byteslice(scanner.pos, 1))

          token = scanner.check(TOKEN)
          return nil if token && placeholder_token?(token, kind)

          shaped = token ? token.match?(VALUE_SHAPE) : "$`".include?(text.byteslice(scanner.pos, 1))
          shaped ? [ scanner.pos, true ] : nil
        end

        def placeholder_token?(token, kind)
          token.match?(PLACEHOLDER_CREDS) || (kind.example && token.bytesize <= 20 && token.match?(EXAMPLE_WORD)) ||
            token.gsub(/<[^<>]*>/, "").match?(SEPARATOR_RUN)
        end

        # Edits [start, stop, FILTERED] for the literals in text[from..], skipping what the precise reading kept.
        def literal_edits(text, from, kind, blocked)
          pieces = segment(text.byteslice(from..), :full)
          edits = []
          offset = from
          walker = { quote: nil }
          pieces.each do |type, string, flagged|
            length = string.bytesize
            if type == :lit
              flagged ? string_edit(text, offset, length, edits, kind) : walk(text, string, offset, kind, walker, edits)
            end
            offset += length
          end
          edits.reject { |start, stop, _| overlaps?(blocked, start, stop) }
        end

        def string_edit(text, offset, length, edits, kind)
          return if length.zero?

          content = text.byteslice(offset, length)
          edits << [ offset, offset + length, FILTERED.b ] unless keep_string?(text, offset, content, kind)
        end

        def keep_string?(text, offset, content, kind)
          return true if content.match?(SEPARATOR_RUN) || content.match?(FORMAT_RUN) || content.match?(/\A(?:%[sdqb]|[:@\/,;._=+ -])+\z/)

          before = text.byteslice([ offset - 40, 0 ].max...offset).to_s
          before.delete_suffix('"').delete_suffix("'").match?(ENV_KEY_TAIL) || (kind.ruby && before.match?(MESSAGE_TAIL))
        end

        # Walks literal text, tracking the quote it is in, and edits every run that can hold a secret.
        def walk(text, string, offset, kind, walker, edits)
          scanner = StringScanner.new(string)
          size = string.bytesize
          until scanner.eos?
            at = scanner.pos
            if walker[:quote]
              close = quote_end(string, at, walker[:quote])
              stop = close || size
              string_edit(text, offset + at, stop - at, edits, kind)
              walker[:quote] = nil if close
              scanner.pos = close ? close + 1 : size
            elsif [ 34, 39, 96 ].include?(string.getbyte(at))
              walker[:quote] = string.getbyte(at).chr
              scanner.pos = at + 1
            elsif (run = scanner.scan(RUN))
              edits << [ offset + at, offset + at + run.bytesize, FILTERED.b ] unless keep_run?(run, kind)
            else
              scanner.pos = at + 1
            end
          end
        end

        def quote_end(string, from, quote)
          at = from
          while (edge = string.index(quote == "`" ? /[`\\]/ : (quote == '"' ? /["\\]/ : /'/), at))
            return edge if string.getbyte(edge) == quote.ord

            at = edge + 2
          end
        end

        def keep_run?(run, kind)
          !run.match?(/[A-Za-z0-9]/) || (kind.ruby && run.delete_prefix("&").delete_prefix(".").match?(RUBY_CODE))
        end

        def overlaps?(blocked, start, stop)
          index = blocked.bsearch_index { |_, to| to > start }
          !index.nil? && blocked[index][0] < stop
        end

        # Whether the statement a credential occurrence starts goes on past the end of this line: its value is
        # missing, or an operator, an unclosed bracket or a backslash ends the line.
        def open_after(text, from, value, stop, kind)
          unless value
            rest = text.byteslice(from..).to_s.sub(/(?:\A|[ \t]+)#.*\z/, "").rstrip
            return bracket_delta(rest, false).positive? unless kind.ruby || kind.json
            return rest.empty? || (kind.ruby && rest.match?(VALUE_OPENERS)) || bracket_delta(rest, kind.ruby).positive?
          end

          rest = text.byteslice(from..).to_s.sub(/[ \t]+#.*\z/, "")
          (kind.ruby && (rest.rstrip.match?(CONTINUATION) || block_delta(rest).positive?)) || bracket_delta(rest, kind.ruby).positive?
        end

        # Blocks a Ruby line opens and does not close: `begin`, `case`, `do` and a leading `if`, less each `end`.
        def block_delta(text)
          code = text.gsub(OPEN_DOUBLE_STRING) { $1 == '"' ? '""' : $& }.gsub(SINGLE_STRING, "''")
          (code.match?(BLOCK_START) ? 1 : 0) + code.scan(BLOCK_OPENER).size - code.scan(/\bend\b/).size
        end

        def bracket_delta(text, curly = true)
          depth = 0
          quote = nil
          text.each_byte do |byte|
            if quote
              quote = nil if byte == quote
            elsif [ 34, 39, 96 ].include?(byte)
              quote = byte
            elsif byte == 40 || byte == 91 || (curly && byte == 123)
              depth += 1
            elsif byte == 41 || byte == 93 || (curly && byte == 125)
              depth -= 1
            end
          end
          depth
        end
      end
    end
  end
end
