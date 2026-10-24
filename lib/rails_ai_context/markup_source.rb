# frozen_string_literal: true

require "prism"
require "strscan"

module RailsAiContext
  # The Ruby a HAML or Slim template runs, split from its markup the way haml's and slim's parsers split each line.
  # shortcut: a line neither parser would accept is kept whole, a false hit at worst; parse it once such hits are reported.
  module MarkupSource
    module_function

    # [code, ruby?] pairs in template order (ruby? is false for a line kept whole), nil for other templates.
    def pieces(source, path)
      path = path.to_s
      if path.end_with?(".haml") then Haml.new(source).pieces
      elsif path.end_with?(".slim") then Slim.new(source).pieces
      end
    end

    INTERPOLATION = /#([{@$])/
    BRACKETS = { "{" => /[{}]/, "[" => /[\[\]]/ }.freeze

    # The Ruby in `#{...}`, plus `#@ivar` and `#$global` when `sigils`, as Ruby and HAML read them.
    def interpolations(text, sigils: false)
      found = []
      scanner = StringScanner.new(text)
      loop do
        from = scanner.pos
        scanner.skip_until(INTERPOLATION) or break
        sigil = scanner[1]
        next if escaped?(text, scanner.pos - 2, from)

        if sigil == "{"
          found << (enclosed(scanner) or break)
        elsif sigils && (name = scanner.scan(/\w+/))
          found << "#{sigil}#{name}"
        end
      end
      found
    end

    # An odd run of backslashes since `from` before the byte at `at` escapes it.
    def escaped?(text, at, from)
      count = 0
      count += 1 while at - count > from && text.getbyte(at - count - 1) == "\\".ord
      count.odd?
    end

    # What the scanner reads up to the bracket closing one already open, the scanner moved
    # past it; nil when it never closes. Counted the way both parsers count: strings unseen.
    def enclosed(scanner, open = "{")
      start = scanner.pos
      depth = 1
      while scanner.skip_until(BRACKETS.fetch(open))
        depth += scanner.matched == open ? 1 : -1
        return scanner.string.byteslice(start, scanner.pos - 1 - start) if depth.zero?
      end
      nil
    end

    def indent(line)
      line[/\A[ \t]*/].gsub("\t", "    ").length
    end

    # A malformed line is kept whole from where it started.
    class Unparsed < StandardError; end

    class Reader
      def initialize(source)
        @lines = source.to_s.split(/\r\n|\r|\n/)
      end

      def pieces
        @out = []
        @i = 0
        while @i < @lines.length
          start = @i
          line = @lines[@i]
          @i += 1
          next if line.strip.empty?

          begin
            found = []
            @found = found
            read(line.strip, MarkupSource.indent(line))
            @out.concat(found.reject { |code, _| code.strip.empty? })
          rescue Unparsed
            @out << [ @lines[start...@i].join("\n"), false ]
          end
        end
        @out
      end

      private

      def ruby(code) = @found << [ code, true ]

      def text(content)
        MarkupSource.interpolations(content, sigils: sigils?).each { |code| ruby(code) }
      end

      # HAML text interpolates `#@ivar` and `#$global` as Ruby does; Slim only `#{}`.
      def sigils? = false

      # The lines indented under the current one, blank lines included.
      def block(under)
        body = []
        while @i < @lines.length && (@lines[@i].strip.empty? || MarkupSource.indent(@lines[@i]) > under)
          body << @lines[@i]
          @i += 1
        end
        body.join("\n")
      end

      def next_line!
        raise Unparsed if @i >= @lines.length

        @i += 1
        @lines[@i - 1].strip
      end

      def filter(name, body)
        case name
        when "ruby" then ruby(body)
        when "erb" then ruby(RailsAiContext::ErbSource.tag_bodies(body))
        else text(body)
        end
      end
    end

    # haml's lib/haml/parser.rb, line by line: process_line, parse_tag,
    # parse_old_attributes, parse_new_attribute, handle_multiline and
    # handle_ruby_multiline.
    class Haml < Reader
      BLOCK_WITH_SPACES = /do\s*\|\s*[^|]*\s+\|\z/
      QUOTED_PART = %w[" '].to_h { |quote| [ quote, /(?:\\.|\#(?!\{)|[^#{quote}\\#])*(#{quote}|#\{)/ ] }.freeze

      private

      def sigils? = true

      def read(line, indent)
        line = multiline(line)
        case line[0]
        when "%" then tag(line)
        when "." then tag("%div#{line}")
        when "#" then %w[{ @ $].include?(line[1]) ? text(line) : tag("%div#{line}")
        when "/" then text(line[1..])
        when "&", "!" then escaped(line)
        when "=" then line[1] == "=" ? text(line[2..]) : script(line[1..])
        when "~" then script(line[1..])
        when "-" then line[1] == "#" ? block(indent) : script(line[1..])
        when ":"
          name = line[1..].downcase
          raise Unparsed unless name.match?(/\A\w+\z/)

          filter(name, block(indent))
        when "\\" then text(line[1..])
        else text(line)
        end
      end

      def escaped(line)
        return if line.start_with?("!!!")

        if line[1, 2] == "==" then text(line[3..])
        elsif %w[= ~].include?(line[1]) then script(line[2..])
        else text(line)
        end
      end

      def multiline?(line)
        line.length > 1 && line.end_with?(" |") && !line.match?(BLOCK_WITH_SPACES)
      end

      def multiline(line)
        return line unless multiline?(line)

        parts = [ line.chop ]
        while @i < @lines.length
          following = @lines[@i].strip
          if following.empty?
            @i += 1
            next
          end
          break unless multiline?(following)

          parts << following.chop
          @i += 1
        end
        parts.join
      end

      # A trailing comma continues a script on the next line.
      def script(code)
        lines = [ code.rstrip ]
        tail = lines.last[-3..] || lines.last
        while continued?(tail)
          following = next_line!
          break if following.empty?

          lines << following
          tail = "#{tail} #{following}"[-3..]
        end
        ruby(lines.join(" "))
      end

      # Whether a script ending in these three characters goes on: a comma, unless it ends `?,` or `?\,`.
      def continued?(tail)
        tail.length > 1 && tail.end_with?(",") && !tail[-3, 2].to_s.match?(/\W\?/) && tail[-3, 2] != "?\\"
      end

      def tag(line)
        match = line.match(/\A%([-:\w]+)([-:\w.#@]*)(.+)?/m) or raise Unparsed
        rest = match[3].to_s
        seen = []
        until rest.empty? || seen.include?(rest[0]) || !"{([".include?(rest[0])
          seen << rest[0]
          rest =
            case rest[0]
            when "{" then old_attributes(rest)
            when "(" then new_attributes(rest)
            else object_ref(rest)
            end
        end

        action, value = rest.match(/\A(?:<>|><|[><])?([=\/~&!])?(.*)/m).captures
        value = value.to_s.strip
        case action
        when "=" then value.start_with?("=") ? text(value[1..]) : script(value)
        when "~" then script(value)
        when "&", "!"
          if value.start_with?("==") then text(value[2..])
          elsif value.start_with?("=", "~") then script(value[1..])
          else text(value)
          end
        when "/" then nil
        else text(value)
        end
      end

      # `{...}`, balanced on Prism's tokens, grown by as many lines again each time it stays open
      # so a hash never closed costs a few lexes; only the lines up to the close are taken.
      def old_attributes(rest)
        buffer = rest.sub("{", "a(")
        first = @i
        loop do
          count = 1
          Prism.lex(buffer).value.each do |token, _|
            # prism 2 splits BRACE_LEFT into _HASH and _ARGUMENT kinds.
            count += 1 if token.type.start_with?("BRACE_LEFT") || %i[LAMBDA_BEGIN EMBEXPR_BEGIN].include?(token.type)
            count -= 1 if %i[BRACE_RIGHT EMBEXPR_END].include?(token.type)
            next unless count.zero?

            hash = buffer.byteslice(0, token.location.end_offset)
            @i = first + hash.count("\n")
            ruby(hash.sub("a(", "{"))
            return buffer.byteslice(hash.bytesize..)[/\A[^\n]*/]
          end
          raise Unparsed if @i >= @lines.length

          added = @lines[@i, [ @i - first, 1 ].max]
          @i += added.length
          buffer = [ buffer, *added.map(&:strip) ].join("\n")
        end
      end

      # `(name=value ...)`: a bare value is Ruby, a quoted one is text that interpolates.
      def new_attributes(rest)
        scanner = StringScanner.new(+rest)
        scanner.scan(/\(\s*/)
        loop do
          unless scanner.scan(/[-:@#\w.]+/)
            break if scanner.scan(/\)/)

            raise Unparsed
          end
          scanner.scan(/\s*/)
          if scanner.scan(/=/)
            scanner.scan(/\s*/)
            if (quote = scanner.scan(/["']/))
              quoted_attribute(scanner, quote)
            else
              ruby(scanner.scan(/(@@?|\$)?\w+/) || raise(Unparsed))
            end
          end
          scanner.scan(/\s*/)
          scanner << " #{next_line!}" if scanner.eos?
        end
        scanner.rest
      end

      def quoted_attribute(scanner, quote)
        loop do
          scanner.scan(QUOTED_PART.fetch(quote)) or raise Unparsed
          break if scanner[1] == quote

          ruby(MarkupSource.enclosed(scanner) || raise(Unparsed))
        end
      end

      def object_ref(rest)
        scanner = StringScanner.new(rest)
        scanner.pos = 1
        ruby(MarkupSource.enclosed(scanner, "[") || raise(Unparsed))
        scanner.rest
      end
    end

    # slim's lib/slim/parser.rb, line by line: parse_line_indicators,
    # parse_tag, parse_attributes, parse_ruby_code, parse_quoted_attribute,
    # parse_text_block and parse_broken_line.
    class Slim < Reader
      ENGINES = %w[ruby javascript css erb markdown textile rdoc asciidoc coffee less sass scss].freeze
      EMBEDDED = /\A(#{Regexp.union(ENGINES)})(?:\s*(?:(.*)))?:(\s*)/
      TAG = /\A(?:[#.]|\*(?=[^\s]+)|(\p{Word}(?:\p{Word}|:|-)*\p{Word}|\p{Word}+))/
      SHORTCUT = /\A([#.]+)((?:\p{Word}|-|\/\d+|:(\w|-)+)*)/
      DELIMITERS = { "(" => ")", "[" => "]", "{" => "}" }.freeze
      ATTR_NAME = "\\A\\s*([^\\0\\s\"'><=/(){}\\[\\]]+)"
      QUOTED_ATTR = /#{ATTR_NAME}\s*=(=?)\s*("|')/
      CODE_ATTR = /#{ATTR_NAME}\s*=(=?)\s*/
      SPLAT = /\A\s*\*(?=[^\s]+)/
      CODE_END = [ nil, *DELIMITERS.values ].to_h { |outer| [ outer, /[\s#{Regexp.escape(outer.to_s)}]/ ] }.freeze

      private

      def read(line, indent)
        @indent = indent
        case line
        when %r{\A/!( ?)} then text_block(Regexp.last_match.post_match)
        when %r{\A/\[.*\]\z} then nil
        when %r{\A/} then block(indent)
        when /\A([|'])([<>]{1,2}(?: |\z)| ?)/ then text_block(Regexp.last_match.post_match)
        when /\A</ then text(line)
        when /\A-/ then ruby(broken_line(line[1..]))
        when /\A=(=?)([<>]*)/ then ruby(broken_line(Regexp.last_match.post_match))
        when EMBEDDED then embedded(*Regexp.last_match.captures.first(2), Regexp.last_match.post_match)
        when /\Adoctype\b/ then nil
        when TAG
          @line = StringScanner.new(Regexp.last_match(1) ? Regexp.last_match.post_match : line)
          tag
        else raise Unparsed
        end
      end

      def text_block(first)
        text([ first, block(@indent) ].join("\n"))
      end

      def broken_line(code)
        lines = [ code.strip ]
        lines << next_line! while lines.last.match?(/[,\\]\z/)
        lines.join("\n")
      end

      def embedded(engine, attributes_text, body)
        @line = StringScanner.new(attributes_text.to_s)
        attributes
        filter(engine, [ body, block(@indent) ].join("\n"))
      end

      def next_line_scanner! = StringScanner.new(next_line!)

      # The rest of the line is read through @line, a scanner, so each step costs what it reads.
      def tag
        nil while @line.skip(SHORTCUT)
        @line.skip(/[<>']*/)
        attributes

        if @line.skip(/\s*:\s*/)
          if @line.scan(EMBEDDED) then embedded(@line[1], @line[2], @line.rest)
          elsif @line.check(TAG)
            @line.skip(TAG) if @line[1]
            tag
          else raise Unparsed
          end
        elsif @line.skip(/\s*=(=?)(['<>]*)/) then ruby(broken_line(@line.rest))
        elsif !@line.match?(%r{\s*/}) && !@line.match?(/\s*\z/)
          @line.skip(/ /)
          text_block(@line.rest)
        end
      end

      def attributes
        delimiter = nil
        if @line.scan(/\s*([(\[{])/)
          delimiter = DELIMITERS[@line[1]]
          boolean = /#{ATTR_NAME}(?=(\s|#{Regexp.escape(delimiter)}|\Z))/
          finish = /\s*#{Regexp.escape(delimiter)}/
        end

        loop do
          if @line.skip(SPLAT) then ruby(ruby_code(delimiter))
          elsif @line.scan(QUOTED_ATTR) then text(quoted(@line[3]))
          elsif @line.skip(CODE_ATTR) then ruby(ruby_code(delimiter))
          else
            break unless delimiter
            next if @line.skip(boolean)
            break if @line.skip(finish)
            raise Unparsed unless @line.match?(/\s*\z/)

            @line = next_line_scanner!
          end
        end
      end

      # An attribute's Ruby runs to a space or the list's delimiter outside brackets. It and `quoted` count
      # by hand: Slim carries the count over a broken line, and a stray `}` takes it below zero.
      def ruby_code(outer)
        code = +""
        count = 0
        open = close = nil
        finish = CODE_END.fetch(outer)
        until @line.eos? || (count.zero? && @line.match?(finish))
          if @line.match?(/[,\\]\z/)
            code << @line.rest << "\n"
            @line = next_line_scanner!
            next
          end
          char = @line.getch
          if count.positive?
            count += 1 if char == open
            count -= 1 if char == close
          elsif DELIMITERS.key?(char)
            count = 1
            open = char
            close = DELIMITERS[open]
          end
          code << char
        end
        raise Unparsed unless count.zero?

        code
      end

      def quoted(quote)
        value = +""
        count = 0
        until count.zero? && @line.peek(1) == quote
          if @line.match?(/(\\)?\z/)
            value << (@line.eos? ? "\n" : " ")
            @line = next_line_scanner!
            next
          end
          char = @line.getch
          count += 1 if char == "{"
          count -= 1 if char == "}"
          value << char
        end
        @line.getch
        value
      end
    end
  end
end
