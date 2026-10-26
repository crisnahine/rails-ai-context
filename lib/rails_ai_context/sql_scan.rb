# frozen_string_literal: true

require "strscan"

module RailsAiContext
  # Reads SQL text the way one database family quotes it: where each string, quoted name and comment starts and
  # ends, and which bytes stand outside all of them and outside every parenthesis. Every offset is a byte offset.
  class SqlScan
    # Any character past ASCII is an identifier character to SQLite and MySQL, a no-break space included.
    BARE_WORD = /(?:[\p{Word}$]|[^\x00-\x7F])+/
    NUMBER = /\A(?:\d+(?:e\d+)?|0x\h+|0b[01]+)\z/i
    # A quoted span by the quote that opens it. A doubled quote stays inside the span.
    PLAIN_SPAN = { "'" => /'(?:''|[^'])*'?/m, '"' => /"(?:""|[^"])*"?/m, "`" => /`(?:``|[^`])*`?/m }.freeze
    # A backslash escapes the next character: every MySQL string, and a PostgreSQL E'...' one.
    ESCAPED_SPAN = { "'" => /'(?:\\.|''|[^'\\])*'?/m, '"' => /"(?:\\.|""|[^"\\])*"?/m }.freeze
    # The quote of an E'...' string: the E stands right before it, as a word of its own.
    E_QUOTE = /(?<=(?<![\p{Word}$]|[^\x00-\x7F])[eE])'/
    # SQLite reads [name] as an identifier.
    BRACKETED = /\[[^\]\n]*\]/
    # PostgreSQL spells a dollar quote's tag as a name, and reads any non-ASCII character as a letter in both:
    # a dollar after one (`→$a$`) is part of that name, and `$→$` is a tag.
    TAG_NAME = /(?:[A-Za-z_]|[^\x00-\x7F])(?:\w|[^\x00-\x7F])*/
    DOLLAR_QUOTED = /(?<![\w$]|[^\x00-\x7F])\$((?:#{TAG_NAME})?)\$.*?\$\1\$/m
    DOLLAR_TAG = /(?<![\w$]|[^\x00-\x7F])\$(?:#{TAG_NAME})?\$/
    UNQUOTED = /[^'"`$\/\-#*\[]+/
    # Text that opens no span and no group, skipped in one step so a long dump is not read a character at a time.
    PLAIN_RUN = /[^'"`$\/\-#\[\]()]+/

    # A whole string literal: MySQL reads a backslash as an escape in every one.
    STRING = /\A'(?:''|[^'])*'\z/m
    ESCAPED_STRING = /\A'(?:\\.|''|[^'\\])*'\z/m
    # MySQL's escape sequences; a backslash before any other character is dropped, and stays before % and _.
    MYSQL_ESCAPES = { "0" => "\0", "b" => "\b", "n" => "\n", "r" => "\r", "t" => "\t", "Z" => "\x1A", "%" => "\\%", "_" => "\\_" }.freeze

    # A statement's text under a pointer. A lookbehind sees the text before the pointer, and where each dollar
    # tag last stands is read in one pass: a search for its closer from every opener is quadratic.
    class Scanner < StringScanner
      def initialize(text)
        super(text, fixed_anchor: true)
      end

      # The [name] at the pointer. A line with no closing bracket is read once, however many brackets open on it.
      def bracketed
        return nil if @unclosed_to && pos < @unclosed_to

        span = scan(BRACKETED)
        @unclosed_to = pos + check(/[^\]\n]*/).bytesize unless span
        span
      end

      # Whether the dollar tag at the pointer stands again after itself, to close the quote it opens.
      def closed?(tag)
        @last ||= {}.tap do |last|
          tags = StringScanner.new(string)
          last["$#{tags[1]}"] = tags.pos - 1 while tags.skip_until(/\$(?=((?:#{TAG_NAME})?\$))/o)
        end
        @last.fetch(tag, -1) >= pos + tag.bytesize
      end
    end

    # Every quoted span the block picks blanked to spaces of the same length, so positions still line up.
    def self.mask_quoted(text, family, backslash: family.backslash_escapes?)
      scanner = Scanner.new(text)
      out = +""

      until scanner.eos?
        kind, span = quoted(scanner, family, backslash: backslash)
        out << (span.nil? ? scanner.scan(UNQUOTED) || scanner.getch : yield(kind, span) ? " " * span.length : span)
      end

      out
    end

    # The quoted span that opens where the scanner stands, as the family reads it: [:string or :quoted, the span], or nil.
    # brackets: whether [name] quotes a name in this text. backslash: whether one escapes the next character of a string.
    def self.quoted(scanner, family, brackets: family.sqlite?, backslash: family.backslash_escapes?)
      case scanner.peek(1)
      when "'" then [ :string, scanner.scan(backslash || scanner.check(E_QUOTE) ? ESCAPED_SPAN["'"] : PLAIN_SPAN["'"]) ]
      when '"' then [ :quoted, scanner.scan(backslash ? ESCAPED_SPAN['"'] : PLAIN_SPAN['"']) ]
      when "`" then [ :quoted, scanner.scan(PLAIN_SPAN["`"]) ]
      when "[" then brackets && (span = scanner.bracketed) ? [ :quoted, span ] : nil
      when "$"
        tag = scanner.check(DOLLAR_TAG) if family.dollar_quoting?
        [ :string, scanner.scan(DOLLAR_QUOTED) ] if tag && scanner.closed?(tag)
      end
    end

    # Skips the comment that opens where the scanner stands, as the family reads it. One that never closes runs to the end.
    # @return [Boolean] whether one opened there
    def self.comment(scanner, family)
      return !scanner.skip(family.line_comment).nil? unless scanner.skip(/\/\*/)

      depth = 1
      marks = family.nested_comments? ? /\/\*|\*\// : /\*\//
      depth += scanner.matched == "/*" ? 1 : -1 while depth.positive? && scanner.skip_until(marks)
      scanner.terminate if depth.positive?
      true
    end

    # [kind, text] for each token of comment-free text: :word (bare, a keyword or a name), :quoted (a name in
    # double quotes, backticks or brackets), :string, :number, or :punct, one character. brackets: whether [name] quotes a name.
    def self.tokens(text, family, brackets: true, backslash: family.backslash_escapes?)
      scanner = Scanner.new(text)
      found = []
      until scanner.eos?
        next if scanner.skip(/\s+/) || scanner.skip(/[uU]&(?=["'])/)

        found << (quoted(scanner, family, brackets: brackets, backslash: backslash) ||
          scanner.scan(BARE_WORD)&.then { |span| [ span.match?(NUMBER) ? :number : :word, span ] } || [ :punct, scanner.getch ])
      end
      found
    end

    # The value of a text that is one whole single-quoted string, as the family reads its escapes; nil for any other text.
    def self.unquote(literal, family:)
      backslash = DatabaseFamily.of(family).backslash_escapes?
      return unless literal.match?(backslash ? ESCAPED_STRING : STRING)

      body = literal[1...-1]
      return body.gsub("''", "'") unless backslash

      body.gsub(/\\(.)|''/m) { Regexp.last_match(1) ? MYSQL_ESCAPES.fetch(Regexp.last_match(1), Regexp.last_match(1)) : "'" }
    end

    # The text inside the first top-level parentheses, quotes respected; nil when none opens or it never closes.
    def self.first_group(text, family:)
      text = text.to_s
      scan = new(text, family: family)
      scanner = StringScanner.new(text)
      while scanner.skip_until(/\(/)
        open = scanner.pos - 1
        next unless scan.top_level?(open)

        close = scan.paren_group(open) or return nil
        return text.byteslice(open + 1, close - open - 1)
      end
      nil
    end

    # The expression inside one pair of parentheses that encloses all of it, else the expression as it is.
    def self.unwrap(expression, family:)
      inner = first_group(expression, family: family) if expression.start_with?("(")
      inner && inner.bytesize == expression.bytesize - 2 ? inner.strip : expression
    end

    # A name bare or quoted: double quotes or backticks, a doubled quote inside.
    NAME = /"((?:[^"]|"")+)"|`((?:[^`]|``)+)`|(\w+)/
    # NAME's quoted forms alone, with no capture.
    QUOTED_NAME_TEXT = /"(?:[^"]|"")+"|`(?:[^`]|``)+`/
    # NAME with no capture, to sit inside a larger pattern's own group.
    NAME_TEXT = /#{QUOTED_NAME_TEXT}|\w+/
    # A name optionally qualified by its schema, with no capture.
    QUALIFIED_NAME_TEXT = /(?:#{NAME_TEXT})\.(?:#{NAME_TEXT})|#{NAME_TEXT}/

    # The name the NAME captures spell.
    def self.unquote_name(double, back, plain)
      double&.gsub('""', '"') || back&.gsub("``", "`") || plain
    end

    # One part of a qualified name: a double-quoted name (a doubled quote inside) or a run with no dot or quote.
    QUALIFIED_PART = /"(?:[^"]|"")*"|[^."]+/

    # A qualified name's parts joined with a dot, any part that holds a dot or a quote in quotes so its dot and the dots between
    # parts stay apart: schema a's b is a.b, a table named a.b is "a.b".
    def self.join_qualified(*parts)
      parts.map { |part| part.match?(/[."]/) ? %("#{part.gsub('"', '""')}") : part }.join(".")
    end

    # The parts of a joined name, unquoted.
    def self.qualified_parts(text)
      text.to_s.scan(QUALIFIED_PART).map { |part| part.start_with?('"') ? part[1...-1].gsub('""', '"') : part }
    end

    # [schema, name] of a joined name, both unquoted; schema is nil for a bare one.
    def self.split_qualified(text)
      parts = qualified_parts(text)
      [ (parts[0...-1].join(".") if parts.size > 1), parts.last.to_s ]
    end

    # A type with its trailing [] and [n] dropped, and whether it had any. Walks back from the end, so a long run of brackets
    # costs one pass, where a pattern ending in \z tries every start of it on Ruby 3.1.
    def self.strip_array_suffix(type)
      stop = type.rstrip.length
      array = false
      while stop.positive? && type[stop - 1] == "]" && (open = type.rindex("[", stop - 1)) && type[open + 1...stop - 1].match?(/\A\d*\z/)
        stop = open
        stop -= 1 while stop.positive? && type[stop - 1].match?(/\s/)
        array = true
      end
      [ type[0, stop], array ]
    end

    # Each name in text, unquoted: the parts of a qualified name, or the names in a column list.
    def self.names(text)
      text.to_s.scan(NAME).map { |groups| unquote_name(*groups) }
    end

    # [kind, from, to] of each string (:string), quoted name (:quoted) and comment (:comment), to exclusive.
    attr_reader :quoted_spans

    # family: a DatabaseFamily, or any name DatabaseFamily.of reads.
    def initialize(sql, family:)
      @sql = sql
      @family = DatabaseFamily.of(family)
      read
    end

    # Whether the byte at index stands outside every span and inside no parentheses or brackets; a group's own
    # parenthesis stands outside it.
    def top_level?(index)
      hidden = @hidden.bsearch { |_, to| to > index }
      !(hidden && hidden[0] <= index)
    end

    # The text split at each top-level separator, each part stripped; an empty last part is dropped.
    def split(separator)
      cuts = []
      scanner = StringScanner.new(@sql)
      pattern = Regexp.new(Regexp.escape(separator))
      while scanner.skip_until(pattern)
        at = scanner.pos - separator.bytesize
        cuts << at if top_level?(at)
      end
      starts = [ 0 ] + cuts.map { |at| at + separator.bytesize }
      parts = starts.zip(cuts + [ @sql.bytesize ]).map { |from, to| @sql.byteslice(from, to - from).strip }
      parts.pop if parts.last.empty?
      parts
    end

    # The byte index of the parenthesis or bracket that closes the one at open_index; nil when it never closes.
    def paren_group(open_index)
      @closes[open_index]
    end

    # The text with every string and comment blanked byte for byte, so a pattern reads code alone at the same offsets.
    def masked
      @masked ||= @quoted_spans.each_with_object(@sql.b) do |(kind, from, to), out|
        out[from, to - from] = " " * (to - from) unless kind == :quoted
      end.force_encoding(@sql.encoding)
    end

    private

    def read
      @quoted_spans = []
      @hidden = []
      @closes = {}
      opens = []
      scanner = Scanner.new(@sql)
      until scanner.eos?
        next if scanner.skip(PLAIN_RUN)

        at = scanner.pos
        kind = self.class.quoted(scanner, @family)&.first || (:comment if self.class.comment(scanner, @family))
        if kind
          @quoted_spans << [ kind, at, scanner.pos ]
          @hidden << [ at, scanner.pos ] if opens.empty?
          next
        end

        case scanner.getch
        when "(", "[" then opens << at
        when ")", "]"
          open = opens.pop or next
          @closes[open] = at
          @hidden << [ open + 1, at ] if opens.empty? && at > open + 1
        end
      end
      @hidden << [ opens.first + 1, @sql.bytesize ] unless opens.empty?
    end
  end
end
