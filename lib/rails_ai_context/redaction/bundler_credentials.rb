# frozen_string_literal: true

autoload :StringScanner, "strscan"

module RailsAiContext
  module Redaction
    # A gem server's credential is found by its name and operator alone, and only those names consume a value.
    # The value is read in one left-to-right pass as pieces: literal text, a reference (`$VAR`, `${VAR}`, `$(...)`,
    # a template, Ruby code that reads a value), the quotes around them and the operators between operands. Every
    # literal piece is filtered; references, quotes and the code after the value stay. No pattern reads a value, so
    # none backtracks through a hostile line.
    #
    # Every index below is a byte index into a binary copy of the line: a character index into a long non-ASCII
    # line costs its length, and an unanchored match from a position scans on after it fails.
    module BundlerCredentials
      SETTING_PREFIXES = %w[BUNDLE_BUILD__ BUNDLE_LOCAL__ BUNDLE_MIRROR__].freeze
      # The gem.* settings `bundle gem` reads (Bundler::Settings' BOOL_KEYS and STRING_KEYS); any other gem.* may be a host.
      GEM_SETTINGS = %w[CHANGELOG COC MIT BUNDLE CI GITHUB_USERNAME LINTER RUBOCOP TEST].freeze

      NAME_BODY = /(?>(?:[A-Za-z0-9_-]|\$\{(?>[^}\s]{1,256})\}|\#\{(?>[^}\s]{1,256})\}){1,1024})/
      NAME = %r{BUNDLE_(?:[A-Za-z]++://[\w.-]++(?::\d++)?/?|#{NAME_BODY}(?::\d++)?)}
      DYNAMIC_KEY = /(?:\$\{?\w+\}?|\#\{[^}]++\}|%\{\w+\})/
      CONFIG_KEY = %r{(?:[A-Za-z][A-Za-z0-9+.-]*://[^\s"'`;&|\\]++|\[[0-9A-Fa-f:]++\](?::\d++)?|[\w-]++(?:\.[\w-]++)++(?::\d++)?|[\w.-]++:\d++|#{DYNAMIC_KEY})}
      CONFIG_FLAG = /(?:set|--?[A-Za-z][\w-]*(?:=\S*)?)/

      GAP = /[\\"'\])*`+]/
      OPERATOR = /(?:#{GAP}*+[ \t]*+(?<op>=>|[?+:|&^*\/%-]{0,2}=(?![=~])|=~(?=[\/~$.\w])|:(?!:))|#{GAP}++[ \t]*+(?<gop>\|(?=[ \t]*+`)|(?:is|equals)(?=[ \t]))|["'][ \t]*+(?<cop>,)|["'][ \t]*+\)[ \t]*+(?<bop>\{))(?:[*`]++(?=[ \t]))?[ \t]*+/
      ASSIGN = /(?<![A-Za-z_$])(?<!\$\{)(?<name>#{NAME})#{OPERATOR}/
      SPACED = /\A[ \t]*(?:export[ \t]++)?(?<sname>#{NAME})[ \t]++(?=[^\s=:#])/
      FISH = /(?<![\w.-])setx?[ \t]++(?:[-\/][A-Za-z-]++[ \t]++)*+(?<fname>#{NAME})[ \t]++/
      CONFIG = /\bbundler?[ \t]++config[ \t]++(?:#{CONFIG_FLAG}[ \t]++)*+["']?(?<key>#{CONFIG_KEY})["']?:?(?:[ \t]++(?:--?[A-Za-z][\w-]*(?:=\S*)?[ \t]++)*+|\z)/
      EXEC_PREFIX = /(?::bundler?[ \t]*+,[ \t]*+:config|["']bundler?["'][ \t]*+,[ \t]*+["']config["']|["']config["'](?=[ \t]*+,[ \t]*+["']set["']))[ \t]*+,[ \t]*+/
      CONFIG_OPEN = /(?<copen>\bbundler?[ \t]++config(?:[ \t]++#{CONFIG_FLAG})*+)[ \t]*+\\[ \t]*+\z|(?<xopen>#{EXEC_PREFIX}(?:(?::set|["']set["'])[ \t]*+,[ \t]*+)?(?:["']--?[\w-]++["'][ \t]*+,[ \t]*+)*+)\z/
      EXEC = /#{EXEC_PREFIX}(?:(?::set|["']set["'])[ \t]*+,[ \t]*+)?(?:["']--?[\w-]++["'][ \t]*+,[ \t]*+)*+(?:["'](?<xkey>#{CONFIG_KEY})["']|(?<xvar>[A-Za-z_@][\w@]*+))[ \t]*+,[ \t]*+/
      API = /Bundler\.settings(?:\.set_(?:local|global|command_option)\(?[ \t]*+:?["']?(?<akey>#{CONFIG_KEY})["']?[ \t]*+,|\[[ \t]*+:?["']?(?<akey2>#{CONFIG_KEY})["']?[ \t]*+\][ \t]*+=)[ \t]*+/
      PSH = /(?<!\w)(?<pname>#{NAME})(?:[ \t]++-(?![Vv]alue\b)\w++(?:[ \t]++[^\s-]\S*+)?)*+[ \t]++-[Vv]alue[ \t]++/
      HOSTKEY = /["'](?<hkey>[\w-]++(?:\.[\w-]++)++)["'][ \t]*+(?::|=>)[ \t]*+(?=["'])/
      QNAME = /\A[ \t]*\?[ \t]++(?<qname>#{NAME})[ \t]*+\z/
      FINDER = /#{ASSIGN}|#{FISH}|#{CONFIG}|#{CONFIG_OPEN}|#{EXEC}|#{API}|#{PSH}|#{QNAME}|#{HOSTKEY}|#{SPACED}/

      DQ_BODY = /(?:[^"\\]|\\.)*+/m
      RUBY_DQ_BODY = /(?:[^"\\\#]|\\.|\#(?!\{)|\#\{(?:[^{}"']|"(?:[^"\\]|\\.)*+"|'[^']*+'|\{[^{}]*+\})*+\})*+/m
      SQ_BODY = /[^']*+/
      ESCAPING_SQ_BODY = /(?:[^'\\]|\\.)*+/m
      BACKTICK_BODY = /(?:[^`\\]|\\.)*+/m
      TRIPLE_DQ_BODY = /(?:[^"\\]|\\.|"(?!""))*+/m
      TRIPLE_SQ_BODY = /(?:[^']|'(?!''))*+/m
      PERCENT = /%[qQwWiI]?([(\[{<|!\/])/
      PERCENT_CLOSE = { "(" => ")", "[" => "]", "{" => "}", "<" => ">", "|" => "|", "!" => "!", "/" => "/" }.freeze
      PERCENT_SCAN = PERCENT_CLOSE.to_h { |open, close| [ open, Regexp.new("[\\\\#{Regexp.escape(open)}#{Regexp.escape(close)}]") ] }.freeze
      HOST_EDGES = { '"' => /["\\]/, "'" => /['\\]/, "`" => /[`\\]/ }.freeze
      JOIN_PLUS = /[ \t]*\+[ \t]*(?=["'`])/
      JOIN_SPACE = /[ \t]+(?=["'])/
      MODIFIER = /(?:if|unless|and|or|while|until|rescue|do|then|end)(?!\w)/
      # A character that ends a word after a closing quote: the code after a value is not part of it.
      ENDS_AFTER_QUOTE = /[\s.,;)\]}&|<>]/
      HEREDOC = /<<[~-]?(["'`]?)([A-Za-z_]\w*)\1/
      HEREDOC_TAG = /<<([~-]?)(["'`]?)([A-Za-z_]\w*)\2/
      BLOCK_SCALAR = /[|>][-+]?\d?[-+]?[ \t]*(?:#.*)?\z/
      VALUE_KEY = /["']?\bvalue["']?[ \t]*:[ \t]*+/
      YAML_PREFIX_TOKEN = /(?:&\S+|![^\s]*|<<:)[ \t]++/
      OPERAND_JOIN = /[ \t]*+(?:\|\||&&|\+|\?|or(?=[ \t])|and(?=[ \t]))[ \t]++/
      TERNARY_COLON = /[ \t]*+:[ \t]++/
      EXPRESSION_CHARS = "|&+-*/<>=!~%^?:".bytes.freeze
      EXPRESSION_END = /(?:#|;|,|\)|\]|\}|(?:if|unless|while|until|rescue|ensure)\b)/
      CODE_RUN = /(?>(?:[\w@$?!.:]|&\.){1,256})/
      BALANCED_RUN = /(?>[^()\[\]{}"'\\]{1,256})/
      KNOWN_CODE = /(?:ENV|ARGV|Rails|File|Dir|Kernel|Settings|Figaro|Base64|YAML|JSON|credentials|secrets)\b[.\[(]/
      ENV_KEY_TAIL = /ENV(?:\[|\.(?:fetch|dig|key\?|delete)\()[ \t]*\z/
      DOUBLE_STRING = /"(?:[^"\\]|\\.)*+"/
      # An unclosed quote ends the match at the end of the line, so no later quote rescans the same text.
      OPEN_DOUBLE_STRING = /"(?:[^"\\]|\\.)*+("|\\?\z)/m
      SINGLE_STRING = /'[^']*+'/
      REF_START = /\$|\#\{|\{\{|\{\w+\}|<%|%\{\w*\}/
      BRACKETS = /[(){}]/

      NULLISH = /\A(?:null|nil|true|false|~)\z/i
      SYMBOL = /\A:[A-Za-z_]\w*\z/
      SECRET_SYMBOL = /:(?=\w*[0-9A-Z])[A-Za-z_]\w*(?![\w(.:?!])/
      PLACEHOLDER_WORD = /(?:user(?:name)?|login|pass(?:word|wd)?|token|secret|key|api_?key|x{3,}|\*{3,})/i
      PLACEHOLDER_CREDS = /\A#{PLACEHOLDER_WORD}(?::#{PLACEHOLDER_WORD})?\z/i
      PROSE_WORD = /\A[A-Za-z.,!?()'-]+\z/
      EXAMPLE_WORD = /\A[A-Za-z]+(?:[_.-][A-Za-z]+)*\z/
      SEPARATOR_RUN = /\A[\s:@\/,;._=+-]*\z/
      FORMAT_RUN = /\A%[sdqb](?:\\n)?\z/
      ASSIGNMENT_LINE = /\A[ \t]*(?:export[ \t]+)?[A-Za-z_][\w.]*=/
      MAPPING_LINE = /\A[ \t]*(?:["'][^"']*["']|[\w.-]+):(?:[ \t]|\z)/
      NAMING_PAIR = /\A[ \t]*(?:-[ \t]+)?["']?(?i:name|key|parameterkey|variable|var|env|envname)["']?[ \t]*:[ \t]*["']?(?<n>#{NAME})["']?[ \t]*[,}]?[ \t]*\z/
      INLINE_NAME = /["']?\b(?i:name|key|parameterkey|variable|var|env|envname)["']?[ \t]*:[ \t]*["']?(?<n>#{NAME})["']?(?=[,}\s]|\z)/
      KEY_VALUE = /["']?(?<k>[A-Za-z_][\w.-]*)["']?[ \t]*:[ \t]*+/
      KEY_VALUE_LINE = /\A[ \t]*(?:-[ \t]+)?["']?(?<k>[A-Za-z_][\w.-]*)["']?[ \t]*:[ \t]*+(?=\S)/
      VALUE_LINE_HEAD = /\A[ \t]*(?:-[ \t]+)?["']?value["']?[ \t]*:[ \t]*/

      RUBY_FILE = /\.(?:rb|rake|ru|gemspec|erb)\z|(?:\A|\/)(?:Gemfile|Rakefile|Capfile|Guardfile|Vagrantfile)\z/
      DOTENV_FILE = %r{(?:\A|/)(?:\.env(?:\.[\w.-]+)?|[\w.-]+\.env)\z}
      CMD_FILE = /\.(?:cmd|bat)\z/i
      JSON_FILE = /\.json(?:\.[\w]+)*\z/i
      TOML_FILE = /\.toml\z/i
      PROSE_FILE = /\.(?:md|markdown|txt|rdoc|adoc)\z/i
      JS_FILE = /\.(?:[cm]?[jt]sx?)\z/i
      BUNDLE_CONFIG_FILE = %r{(?:\A|/)\.bundle/config\z}
      CARRY_LINES = 50
      CHAIN_START = /\A[ \t]*(?:\.(?!\.)|&\.|["'`])/
      # Keys under a credential's name whose values describe it; any other sibling key may hold the secret.
      KEEP_KEYS = %w[name key parameterkey variable var env envname description desc comment note help label title type required options expand regex scope protected masked hidden raw environment_scope id source valuefrom value_from from].freeze

      Part = Struct.new(:open, :body, :close, :closed, :stop, :start)
      Context = Struct.new(:host, :spacey, :lenient, :ruby, :scanner, :kind, :state)
      Kind = Struct.new(:yaml, :dotenv, :cmd, :ruby, :json, :toml, :js, :example, :prose)
      # What one line keeps between its names: the open quote, and tables built once.
      Quotes = Struct.new(:open, :at, :edge, :matches, :headers, :erb_none)
      # Bounded runs, so a word that a later name cuts short costs its own length, not the rest of the line.
      PLAIN = /(?>[^\s"'`$#\\&|<>,;)\[\]}]{1,256})/
      SPACEY_PLAIN = /(?>[^"'`$#\\ \t]{1,256})/
      SPACEY_FREE = /(?>[^$#\\ \t]{1,256})/
      NAME_OPERATOR = /#{NAME}#{OPERATOR}/
      JSON_LITERAL = /\A(?:[-0-9\[]|(?:true|false|null)\b)/
      DOTENV_PREFIX = /[ \t]*(?:export[ \t]+)?/
      YAML_KEY_PREFIX = /[ \t]*(?:-[ \t]+)?["']?/
      YAML_ITEM_PREFIX = /[ \t]*-[ \t]+/
      CMD_PREFIX = /[ \t]*@?set[ \t]+(?:\/\w[ \t]+)?/i
      DOCKER_PREFIX = /[ \t]*(?:ENV|ARG)[ \t]/i
      EDGES = /["'`\\]/

      class << self
        # BUNDLE_<HOST>, the host's dots written `__`, a URL or a host with a port: where Bundler reads a gem server's password.
        def credential?(name)
          upper = name.upcase
          return false unless upper.start_with?("BUNDLE_")
          return false unless name.include?("://") || name.index("__", 7) || name.match?(/:\d+\z/)
          return false if upper.start_with?("BUNDLE_GEM__") && GEM_SETTINGS.include?(upper.delete_prefix("BUNDLE_GEM__"))
          return false if upper == "BUNDLE_GITHUB__HTTPS"

          SETTING_PREFIXES.none? { |prefix| upper.start_with?(prefix) }
        end

        # The line with every gem server credential's value filtered, and what the next line still belongs to.
        # The block says whether a value is no secret; `path` says which formats keep a space in an unquoted value.
        # `opener` says the line before ended in an open call, so a name followed by a comma is an argument.
        def redact(line, path: nil, opener: false, &placeholder)
          unless line.include?("BUNDLE_") || line.include?("bundle") || line.include?("Bundler") || host_key_hint?(line)
            return [ line, path.to_s.match?(RUBY_FILE) && line.sub(/[ \t]+#.*\z/, "").rstrip.end_with?("(") ? [ :opener ] : nil ]
          end

          text = line.b
          scanner = StringScanner.new(text)
          kind = kind_of(path)
          edits = []
          kept = []
          handled = {}
          tail = nil
          pos = 0
          carry = nil
          quotes = Quotes.new(nil, 0, text.index(EDGES) || Float::INFINITY)
          while (found = FINDER.match(text, pos))
            pos = found.end(0)
            name = found_name(found)
            if name == :open
              carry = [ :cfg, found[:copen] || found[:xopen] ]
              next
            elsif name == :explicit
              carry = [ :explicit ]
              next
            end
            next unless name && credential?(name)
            next if found[:sname] && (kind.ruby || kind.prose)
            next if found[:cop] && !(opener || call_argument?(text, found.begin(:name)))
            next if found[:op] == "=~" && kind.ruby

            handled[occurrence_begin(found)] = true
            host = host_quote(text, quotes, pos, kind)
            host = nil if host && text.getbyte(pos) == host.ord
            context = context_for(text, found, host, kind, scanner, quotes)
            start = value_start(text, pos, context, kind)
            tail = [ pos, false, pos ] if active?(found)
            unless start
              carry = empty_value_carry(text, pos, found, kind) || carry
              next
            end

            word = read_value(text, start, context, found.begin(:name), found[:op], placeholder, code: code_value?(found, host), shaped: !!found[:hkey])
            next unless word

            carry = word[:carry]
            next unless word[:stop]

            tail = [ start, true, word[:stop] ] if active?(found)
            if word[:replacement]
              edits << [ start, word[:stop], word[:replacement] ]
            elsif !text.byteslice(start...word[:stop]).match?(/bundle|BUNDLE_|Bundler/)
              kept << [ start, word[:stop] ]
            end
            pos = word[:stop]
          end

          blocked = (edits + kept).sort
          guard = fail_closed(text, kind, handled, blocked, opener)
          edits.concat(guard[:edits])
          tail = guard[:tail] if guard[:tail] && (tail.nil? || guard[:tail][0] >= tail[0])
          carry ||= statement_carry(text, tail, kind)
          carry ||= [ :follow, CARRY_LINES ] if kind.ruby && tail && tail[1]
          carry ||= [ :opener ] if kind.ruby && text.sub(/[ \t]+#.*\z/, "").rstrip.end_with?("(")
          [ apply_edits(line, text, edits), carry ]
        end

        # A line a previous line's open quote, block scalar, heredoc, header or value hands on: its secret is
        # filtered, the quote that closes stays.
        def continue(line, carry, path: nil, &placeholder)
          kind, arg = carry
          case kind
          when :word then continue_word(line, path, placeholder)
          when :cfg then continue_header(line, arg, path, placeholder)
          when :explicit then continue_explicit(line, path, placeholder)
          when :nextval then continue_nextval(line, arg, path, placeholder)
          when :heredoc then continue_heredoc(line, arg, carry)
          when :block then continue_block(line, arg, carry)
          when :stmt then continue_statement(line, carry, path)
          when :follow then continue_follow(line, carry, path)
          when :opener then [ line, nil ]
          else continue_quote(line, carry, path)
          end
        end

        # The word at character `pos` of a `value:` line a credential's name labels, filtered; and the carry.
        def redact_value(line, pos, path: nil, column: 0, &placeholder)
          text = line.b
          at = line[0, pos].bytesize
          kind = kind_of(path)
          context = Context.new(nil, kind.yaml, false, kind.ruby, StringScanner.new(text), kind, Quotes.new)
          at = value_start(text, at, context, kind)
          return [ line, nil ] unless at

          word = read_value(text, at, context, column, ":", placeholder, code: kind.ruby)
          return [ line, nil ] unless word

          carry = word[:carry]
          return [ line, carry ] unless word[:replacement]

          [ (text.byteslice(0, at) + word[:replacement] + text.byteslice(word[:stop]..)).force_encoding(line.encoding), carry ]
        end

        # `{"name": "BUNDLE_X", "value": "..."}` and its flow-map spellings on one line: every key other than the
        # descriptive ones holds a value that may be the secret.
        def inline_pairs(line, path, &placeholder)
          return line unless line.include?("BUNDLE_") && (name = line.match(INLINE_NAME)) && credential?(name[:n])

          text = line.b
          kind = kind_of(path)
          scanner = StringScanner.new(text)
          state = Quotes.new
          edits = []
          at = 0
          while (key = KEY_VALUE.match(text, at))
            at = key.end(0)
            next if KEEP_KEYS.include?(key[:k].downcase) || key[:k].start_with?("BUNDLE_") || text.getbyte(at).nil?

            context = Context.new(nil, kind.yaml, false, kind.ruby, scanner, kind, state)
            start = value_start(text, at, context, kind)
            word = start && read_value(text, start, context, 0, ":", placeholder, code: kind.ruby)
            next unless word&.dig(:replacement)

            edits << [ start, word[:stop], word[:replacement] ]
            at = word[:stop]
          end
          apply_edits(line, text, edits)
        end

        # Name and value written as sibling keys of one object (`name: BUNDLE_X` beside `value: ...`, in either
        # order, on one line or several), in JSON, YAML and flow maps.
        def name_value_pairs(lines, path, &placeholder)
          return lines unless lines.any? { |line| line.include?("BUNDLE_") }

          grouped = group_ids(lines)
          credential = {}
          grouped.each_with_index do |id, i|
            named = id && lines[i].match(NAMING_PAIR)
            credential[id] = true if named && credential?(named[:n])
          end
          return lines if credential.empty?

          carry = nil
          lines.each_with_index.map do |line, i|
            if carry
              line, carry = continue(line, carry, path: path, &placeholder)
              next line if carry
            end
            next line unless credential[grouped[i]] && (head = line.match(KEY_VALUE_LINE))
            next line if KEEP_KEYS.include?(head[:k].downcase) || head[:k].start_with?("BUNDLE_")

            line, carry = redact_value(line, head.end(0), path: path, column: line[/\A[ \t]*(?:-[ \t]+)?/].size, &placeholder)
            line
          end
        end

        private

        # A quoted dotted key followed by `:` or `=>` may be a gem server written as a hash key.
        def host_key_hint?(line)
          line.include?(".") && (line.include?('":') || line.include?("':") || line.include?("=>"))
        end

        def occurrence_begin(found)
          found.begin(:name) || found.begin(:fname) || found.begin(:pname) || found.begin(:sname) || found.begin(:key) ||
            found.begin(:xkey) || found.begin(:xvar) || found.begin(:akey) || found.begin(:akey2) || found.begin(:hkey) || found.begin(0)
        end

        def active?(found)
          !!(found[:op] || found[:cop] || found[:bop] || found[:gop] || found[:key] || found[:xkey] || found[:xvar] ||
             found[:akey] || found[:akey2] || found[:hkey] || found[:fname] || found[:pname] || found[:sname])
        end

        def apply_edits(line, text, edits)
          return line if edits.empty?

          out = +"".b
          copied = 0
          edits.sort_by { |start, stop, _| [ start, stop ] }.each do |start, stop, replacement|
            next if start < copied

            out << text.byteslice(copied...start) << replacement
            copied = stop
          end
          (out << text.byteslice(copied..)).force_encoding(line.encoding)
        end

        # The statement carry: the line names a credential and leaves its value, or the expression around it, open.
        def statement_carry(text, tail, kind)
          return nil unless tail

          from, value, stop = tail
          return nil unless open_after(text, from, value, stop, kind)

          code = text.byteslice(from..).to_s.sub(/[ \t]+#.*\z/, "")
          [ :stmt, [ bracket_delta(code), kind.ruby, kind.ruby ? block_delta(code) : 0 ], CARRY_LINES ]
        end

        def found_name(found)
          direct = found[:name] || found[:fname] || found[:pname] || found[:sname]
          return direct if direct
          return :open if found[:copen] || found[:xopen]
          return :explicit if found[:qname]
          return "BUNDLE_DYNAMIC__KEY" if found[:xvar]

          key = found[:key] || found[:xkey] || found[:akey] || found[:akey2] || found[:hkey]
          key.match?(/\A#{DYNAMIC_KEY}/) ? "BUNDLE_DYNAMIC__KEY" : "BUNDLE_#{key.upcase.gsub('.', '__')}"
        end

        # A name written as an argument (`ENV.store("NAME", ...)`), not a list element or a hash key.
        def call_argument?(text, named)
          text.byteslice([ named - 40, 0 ].max...named).match?(/\([ \t]*["']\z/)
        end

        # Ruby code is read as a value only where the name is assigned in Ruby, not inside a command string.
        def code_value?(found, host)
          host.nil? && (found[:op] || found[:cop] || found[:bop] || found[:akey2] || found[:xkey] || found[:xvar]) ? true : false
        end

        def kind_of(path)
          path = path.to_s
          Kind.new(path.match?(YAML_FILE) || path.match?(BUNDLE_CONFIG_FILE), path.match?(DOTENV_FILE), path.match?(CMD_FILE),
                   path.match?(RUBY_FILE), path.match?(JSON_FILE), path.match?(TOML_FILE), path.match?(JS_FILE), path.match?(EXAMPLE_FILE) || path.match?(PROSE_FILE), path.match?(PROSE_FILE))
        end

        # Which quote of the line is open at `to`, a string the name sits in. The next quote or backslash is
        # kept between calls, so a line with none is searched once, not once per name. A backslash inside
        # single quotes is a character in the shell, an escape in Ruby.
        def host_quote(text, quotes, to, kind)
          while quotes.edge < to
            char = text.getbyte(quotes.edge).chr
            if char == "\\"
              quotes.at = quotes.edge + (quotes.open == "'" && !kind.ruby ? 1 : 2)
            else
              quotes.open = quotes.open.nil? ? char : (quotes.open == char ? nil : quotes.open)
              quotes.at = quotes.edge + 1
            end
            quotes.edge = text.index(EDGES, quotes.at) || Float::INFINITY
          end
          quotes.open
        end

        def context_for(text, found, host, kind, scanner, state)
          named = found.begin(:name) || found.begin(:sname)
          op = found[:op]
          assign = op&.end_with?("=") && op != "=>"
          spacey = found[:fname] || found[:sname] || (named && (host && text.getbyte(named - 1) == host.ord ||
            kind.dotenv && before?(scanner, named, DOTENV_PREFIX) ||
            (kind.yaml || !kind.ruby) && op == ":" && before?(scanner, named, YAML_KEY_PREFIX) ||
            kind.yaml && assign && before?(scanner, named, YAML_ITEM_PREFIX) ||
            kind.cmd && assign && before?(scanner, named, CMD_PREFIX)))
          Context.new(host, !!spacey, before?(scanner, nil, DOCKER_PREFIX), kind.ruby, scanner, kind, state)
        end

        # Whether `pattern` matches the line from its start up to `stop` exactly (any length when nil), so a long
        # line's prefix is never copied for each name.
        def before?(scanner, stop, pattern)
          scanner.pos = 0
          length = scanner.skip(pattern)
          length && (stop.nil? || length == stop)
        end

        def value_start(text, pos, context, kind)
          start = pos
          char = text.getbyte(start)
          return nil if char.nil? || (context.spacey && char == 35)
          return nil if char == 35 && pos.positive? && [ 32, 9 ].include?(text.getbyte(pos - 1)) && text.getbyte(pos + 1) != 123 && !kind.json

          if char == 123 && text.getbyte(start + 1) != 123
            inner = VALUE_KEY.match(text, start)
            return nil unless inner

            start = inner.end(0)
          end
          if kind.yaml
            scanner = context.scanner
            scanner.pos = start
            while (length = scanner.skip(YAML_PREFIX_TOKEN))
              start += length
            end
            return nil if text.getbyte(start) == 42 && text.getbyte(start + 1)&.chr&.match?(/[A-Za-z_]/)
          end
          char = text.getbyte(start)
          return nil if char.nil? || (char == 91 && (kind.yaml || kind.json))
          return nil if kind.json && !context.host && text.byteslice(start, 8).match?(JSON_LITERAL)

          start
        end

        # What the line leaves for the next one when a name has no value on it.
        def empty_value_carry(text, pos, found, kind)
          return nil unless pos >= text.bytesize || brace_only?(text, pos)

          if found[:key] || found[:xkey] then kind.yaml ? [ :word ] : nil
          elsif found[:name] && found[:op] == ":" && (kind.yaml || kind.json) then [ :nextval, found.begin(:name) ]
          end
        end

        # Whether only `{` and what strip drops follow pos, read in place: a copy of the rest per name cost the square of the line.
        def brace_only?(text, pos)
          scanner = StringScanner.new(text)
          scanner.pos = pos
          !scanner.match?(/[\0\s]*+\{[\0\s]*+\z/).nil?
        end

        # `{ replacement:, stop:, carry: }` for the value at `start`; replacement is nil when nothing is a secret.
        def read_value(text, start, context, name_column, op, placeholder, code: false, shaped: false)
          scanner = context.scanner
          return { carry: [ :word ] } if line_continues?(text, start)
          return { carry: [ :heredoc, heredoc_tags(text, start) ] } if matched(scanner, start, HEREDOC)
          return { carry: [ :block, name_column || 0 ] } if op == ":" && matched(scanner, start, BLOCK_SCALAR)

          operands = read_operands(text, start, context, code)
          return nil unless operands

          format_argument(text, operands, context)
          pieces, stop, first = operands.values_at(:pieces, :stop, :first)
          carry = value_carry(text, operands, context, name_column)
          literal = pieces.select { |type, _| type == :lit }.map { |_, string| string }.join
          pure = pieces.none? { |type, _| type == :ref || type == :sep }
          return { stop: stop, carry: carry } if (shaped && !literal.match?(/\A[^\s:\/]+:[^\s\/]+\z/)) || no_secret?(literal, context, placeholder, pure)

          { replacement: render(pieces, first), stop: stop, carry: carry }
        end

        # `printf 'NAME=%s' 'secret'` and `"NAME=%s" % "secret"`: the value is the argument after the format.
        def format_argument(text, operands, context)
          return unless operands[:pieces].all? { |type, string| type != :lit || string.match?(FORMAT_RUN) } && operands[:pieces].any? { |type, _| type == :lit }

          scanner = context.scanner
          scanner.pos = operands[:stop]
          scanner.skip(/(?:\\[nrt])?/)
          scanner.skip(context.host ? /#{Regexp.escape(context.host)}/ : /(?!)/)
          scanner.skip(/[ \t]*(?:%[ \t]*)?/)
          at = scanner.pos
          argument = read_operand(text, at, Context.new(nil, false, false, context.ruby, scanner, context.kind, context.state), false)
          return unless argument

          operands[:pieces] << [ :sep, text.byteslice(operands[:stop]...at) ]
          operands[:pieces].concat(argument[:pieces])
          operands[:stop] = argument[:stop]
          operands[:first] = nil
        end

        def heredoc_tags(text, start)
          text.byteslice(start..).scan(HEREDOC_TAG).map { |mode, _, tag| [ mode, tag ] }
        end

        def value_carry(text, operands, context, column)
          last = operands[:last]
          stop = operands[:stop]
          if last && !last.closed && !last.open.empty? && stop >= text.bytesize && !context.host
            [ :quote, last.open, CARRY_LINES ]
          elsif line_continues?(text, stop)
            [ :word ]
          elsif context.kind.yaml && context.spacey && operands[:first_open].empty? && column
            [ :block, column ]
          end
        end

        # A backslash that ends the line, white space after it included: the shell and Docker read it as a continuation.
        def line_continues?(text, at)
          text.getbyte(at) == 92 && text.byteslice(at..).match?(/\A\\[ \t]*+\z/)
        end

        def no_secret?(literal, context, placeholder, pure)
          stripped = literal.strip
          return true if stripped.empty? || stripped.bytesize < 3 || (pure && (stripped.match?(NULLISH) || (context.ruby && stripped.match?(SYMBOL))))
          return true if pure && placeholder&.call(stripped)
          return true if stripped.gsub(/<[^<>]*>|\[[A-Za-z][A-Za-z0-9_ .-]*\]/, "").match?(SEPARATOR_RUN) && stripped.match?(/[<\[]/)

          tokens = stripped.split(/\s+/)
          return false unless tokens.drop(context.spacey ? 1 : tokens.size).all? { |token| token.match?(PROSE_WORD) }

          first = context.spacey ? tokens.first : stripped
          first.match?(PLACEHOLDER_CREDS) || (context.kind.example && first.bytesize <= 20 && first.match?(EXAMPLE_WORD))
        end

        # The literal runs become one marker each. A word that is only literal and has one operand keeps its
        # first quote and the one that closes it, whatever parts it was written in.
        def render(pieces, first)
          return nil unless pieces.any? { |type, string| type == :lit && !keepable?(string) }
          return collapsed(first) if first && pieces.none? { |type, _| type == :ref || type == :sep }

          out = +"".b
          run = nil
          pieces.each do |type, string|
            if type == :lit
              (run ||= +"".b) << string
            else
              out << flush(run) if run
              run = nil
              out << string
            end
          end
          out << flush(run) if run
          out
        end

        def collapsed(first)
          return FILTERED.b if first[:open].empty?

          "#{first[:open]}#{FILTERED}#{first[:all_closed] ? first[:close] : ''}".b
        end

        def flush(run)
          keepable?(run) ? run : FILTERED.b
        end

        def keepable?(run)
          run.match?(SEPARATOR_RUN) || run.match?(FORMAT_RUN)
        end

        def matched(scanner, at, pattern)
          scanner.pos = at
          scanner.match?(pattern)
        end

        # Operands of one value: a word, or in Ruby an expression of words and code joined by `||`, `&&`, `+`, `? :`.
        def read_operands(text, start, context, code)
          pieces = []
          at = start
          collapse = nil
          first_open = nil
          last = nil
          stop = start
          pending = nil
          ternary = false
          operators = false
          loop do
            operand = read_operand(text, at, context, code)
            break unless operand

            if pieces.empty?
              collapse = operand[:collapse]
              first_open = operand[:first_open]
            end
            pieces << pending if pending
            pieces.concat(operand[:pieces])
            last = operand[:last]
            stop = operand[:stop]
            if code && context.ruby && !operand[:code] && text.getbyte(stop) == 46 && alphanumeric?(text.getbyte(stop + 1)) && (chain = read_code(text, stop, context))
              pieces.concat(chain[:pieces])
              stop = chain[:stop]
              collapse = nil
              operand = chain
            end
            operators ||= context.ruby || operand[:code]
            break unless code && operators

            joined = join_after(text, stop, context.scanner, ternary)
            break unless joined

            pending = [ :sep, text.byteslice(stop...joined[0]) ]
            collapse = nil
            ternary = joined[1]
            at = joined[0]
          end
          return nil if pieces.empty?

          { pieces: pieces, stop: stop, first: collapse, first_open: first_open || "", last: last }
        end

        # [position after the operator, whether a ternary is open], or nil.
        def join_after(text, stop, scanner, ternary)
          scanner.pos = stop
          if (length = scanner.skip(OPERAND_JOIN))
            joined = scanner.string.byteslice(stop, length)
            return [ stop + length, ternary || joined.include?("?") ]
          end
          return nil unless ternary

          scanner.pos = stop
          (length = scanner.skip(TERNARY_COLON)) ? [ stop + length, false ] : nil
        end

        def read_operand(text, at, context, code)
          return nil if text.getbyte(at).nil?

          if code && context.ruby && text.getbyte(at) == 58 && [ 34, 39 ].include?(text.getbyte(at + 1))
            symbol = read_operand(text, at + 1, context, false)
            return symbol && symbol.merge(pieces: [ [ :ref, ":" ] ] + symbol[:pieces], first_open: "", collapse: nil, code: true)
          end
          if code && context.ruby && (symbol = matched(context.scanner, at, SECRET_SYMBOL))
            name = context.scanner.matched.byteslice(1..)
            return { pieces: [ [ :ref, ":" ], [ :lit, name ] ], stop: at + 1 + name.bytesize, last: nil, first_open: "", collapse: nil, code: true } if symbol
          end
          if code && code_start?(text, at, context)
            code_pieces = read_code(text, at, context)
            return code_pieces if code_pieces
          end
          parts, stop = read_word(text, at, context)
          return nil if parts.empty?

          pieces = []
          parts.each_with_index do |part, index|
            gap = index.zero? ? 0 : part.start - parts[index - 1].stop
            pieces << [ :gap, text.byteslice(parts[index - 1].stop, gap) ] if gap.positive?
            pieces.concat(part_pieces(part, context))
          end
          first = parts.first
          { pieces: pieces, stop: stop, last: parts.last, first_open: first.open,
            collapse: { open: first.open, close: first.close, all_closed: parts.all?(&:closed) } }
        end

        def code_start?(text, at, context)
          byte = text.getbyte(at)
          if context.ruby
            [ 58, 64, 36, 91, 40, 95 ].include?(byte) || alphanumeric?(byte) || (byte == 45 && text.getbyte(at + 1) == 62)
          else
            matched(context.scanner, at, KNOWN_CODE)
          end
        end

        # An expression that reads a value: kept as it is, apart from the string literals inside it.
        def read_code(text, at, context)
          scanner = context.scanner
          pieces = []
          mark = at
          depth = 0
          i = at
          limit = next_header(text, at, context)
          fetch = text.byteslice(at, 512).to_s.include?(".fetch(")
          while i < limit
            scanner.pos = i
            advance = scanner.skip(depth.zero? ? CODE_RUN : BALANCED_RUN)
            i += [ advance, limit - i ].min if advance
            break if i >= limit

            byte = text.getbyte(i)
            case byte
            when nil then break
            when 40, 91, 123
              break if depth.zero? && byte == 123 && i == at

              depth += 1
              i += 1
            when 41, 93, 125
              break if depth.zero?

              depth -= 1
              i += 1
              i += block_gap(text, i, scanner) if depth.zero? && fetch
            when 34, 39
              break if depth.zero? && i == at

              mark, i = code_string(text, i, mark, pieces, scanner)
            when 92 then i += 2
            when 32, 9
              if depth.zero?
                gap = expression_gap(text, i, scanner)
                break unless gap

                i += gap
              else
                i += 1
              end
            else
              break if depth.zero? && !EXPRESSION_CHARS.include?(byte)

              i += 1
            end
          end
          i = [ i, text.bytesize ].min
          return nil if i == at || text.byteslice(at...i).match?(/\A[A-Za-z_]\w*:(?!:)/)

          pieces << [ :ref, text.byteslice(mark...i) ] if i > mark
          { pieces: pieces, stop: i, code: true, last: nil, first_open: "" }
        end

        # The white space inside a Ruby expression that goes on, or nil where the value ends: at a comment, a
        # separator, a closer or a modifier.
        def expression_gap(text, at, scanner)
          scanner.pos = at
          gap = scanner.skip(/[ \t]++/)
          return nil if scanner.eos? || scanner.match?(EXPRESSION_END)

          gap
        end

        def block_gap(text, at, scanner)
          scanner.pos = at
          scanner.skip(/[ \t]*(?=\{)/) || 0
        end

        # A string inside code: its quotes stay, its content is literal unless it names an environment variable.
        def code_string(text, at, mark, pieces, scanner)
          quote = text.getbyte(at)
          scanner.pos = at + 1
          edge = at + 1 + scanner.skip(quote == 34 ? DQ_BODY : ESCAPING_SQ_BODY)
          content = text.byteslice((at + 1)...edge)
          pieces << [ :ref, text.byteslice(mark..at) ]
          before = text.byteslice([ at - 60, 0 ].max...at)
          if before.match?(ENV_KEY_TAIL) || before.match?(FailClosed::MESSAGE_TAIL) then pieces << [ :ref, content ]
          else pieces.concat(segment(content, quote == 34 ? :full : :templates).map { |type, string| type == :lit ? [ :lit, string, true ] : [ type, string ] })
          end
          [ edge, text.getbyte(edge) == quote ? edge + 1 : edge ]
        end

        def part_pieces(part, context)
          pieces = []
          pieces << [ :delim, part.open ] unless part.open.empty?
          pieces.concat(body_pieces(part, context))
          pieces << [ :delim, part.close ] if part.closed && !part.close.empty?
          pieces
        end

        def body_pieces(part, context)
          case part.open
          when "'", "\\'" then segment(part.body, :templates)
          when "$'", "%q(", "%q[", "%q{", "%q<", "'''" then segment(part.body, :none)
          when "`"
            command = !context.kind.dotenv && !context.kind.js && part.body.match?(/\s/)
            command ? command_pieces(part.body) : segment(part.body, :none)
          else segment(part.body, :full)
          end
        end

        # Splits text into literal and reference pieces. A reference is a shell expansion, a template or an
        # interpolation; `${NAME:-default}` keeps the name and filters the default.
        def segment(body, mode, depth = 0)
          return [] if body.empty?
          return [ [ :lit, body ] ] if mode == :none || !body.match?(REF_START)

          pieces = []
          at = 0
          mark = 0
          matches = nil
          closer = nil
          while (found = REF_START.match(body, at))
            i = found.begin(0)
            if found[0] == "$" && body.getbyte(i + 1) == 36
              at = i + 2
              next
            end
            matches ||= brace_matches(body)
            closer = body.index("%>", i + 2) || Float::INFINITY if found[0] == "<%" && (closer.nil? || closer < i)
            stop = reference_end(body, i, found[0], mode, matches, closer)
            unless stop
              at = i + 1
              next
            end

            pieces << [ :lit, body.byteslice(mark...i) ] if i > mark
            pieces.concat(reference_pieces(body.byteslice(i...stop), mode, depth))
            at = mark = stop
          end
          pieces << [ :lit, body.byteslice(mark..) ] if mark < body.bytesize
          pieces
        end

        # Where the reference opening at `i` ends, or nil when it is not one.
        def reference_end(body, i, token, mode, matches, closer)
          case token
          when "$"
            return nil if mode == :templates

            following = body[i + 1]
            return matches[:brace][i + 1]&.+(1) if following == "{"
            return matches[:paren][i + 1]&.+(1) if following == "("
            return nil if i.positive? && body[i - 1].match?(/[A-Za-z0-9]/)

            name = body.byteslice(i + 1, 256)[/\A(?:[A-Za-z_]\w*|[0-9@*#?!])/]
            name && i + 1 + name.bytesize
          when "\#{" then mode == :full ? matches[:brace][i + 1]&.+(1) : nil
          when "{{" then matches[:brace][i]&.+(1)
          when "<%" then closer.finite? ? closer + 2 : nil
          else i + token.bytesize
          end
        end

        def reference_pieces(span, mode, depth)
          if span.start_with?("${") && !span.start_with?("${{")
            inner = span.byteslice(2...-1)
            if (head = inner.match(/\A[A-Za-z_]\w*:?[-=+]/))
              default = inner.byteslice(head.end(0)..)
              body = depth < 3 ? segment(default, mode, depth + 1) : [ [ :lit, default ] ]
              return [ [ :ref, "${#{head[0]}" ], *body, [ :ref, "}" ] ]
            end
          end
          return command_pieces(span) if span.start_with?("$(")

          span.start_with?("{{", "${{", "\#{", "<%") ? template_pieces(span) : [ [ :ref, span ] ]
        end

        # A command run inside a value: the words stay, a quoted string and a word shaped like a credential are literal.
        def command_pieces(text)
          scanner = StringScanner.new(text)
          pieces = []
          code = +"".b
          dead = {}
          until scanner.eos?
            code << scanner.scan(/[^"']*+/)
            break if scanner.eos?

            quote = scanner.peek(1)
            literal = dead[quote] ? nil : scanner.scan(quote == '"' ? DOUBLE_STRING : SINGLE_STRING)
            if literal.nil?
              dead[quote] = true
              code << scanner.getch
              next
            end

            command_words(code + quote, pieces)
            content = literal.byteslice(1...-1)
            pieces.concat(content.empty? ? [] : segment(content, quote == '"' ? :full : :templates).map { |type, string| type == :lit ? [ :lit, string, true ] : [ type, string ] })
            code = +quote
          end
          command_words(code, pieces)
          pieces
        end

        def command_words(code, pieces)
          kept = +"".b
          code.split(/([\s()]+)/).each do |word|
            if secret_like?(word)
              pieces << [ :ref, kept ] unless kept.empty?
              kept = +"".b
              pieces << [ :lit, word ]
            else
              kept << word
            end
          end
          pieces << [ :ref, kept ] unless kept.empty?
        end

        def secret_like?(word)
          !word.include?("/") && !word.start_with?("-") && word.bytesize >= 4 &&
            (word.match?(/[A-Za-z0-9]:[A-Za-z0-9]/) || (word.match?(/\d/) && word.match?(/[A-Za-z]/)))
        end

        # A template or interpolation: its code stays, a string literal inside it is filtered. A quote that opens
        # no string leaves every later one of its kind unable to close one, so the text is read once.
        def template_pieces(span)
          scanner = StringScanner.new(span)
          pieces = []
          code = +""
          dead = {}
          until scanner.eos?
            code << scanner.scan(/[^"']*+/)
            break if scanner.eos?

            quote = scanner.peek(1)
            literal = dead[quote] ? nil : scanner.scan(quote == '"' ? DOUBLE_STRING : SINGLE_STRING)
            if literal.nil?
              dead[quote] = true
              code << scanner.getch
              next
            end

            content = literal.byteslice(1...-1)
            pieces << [ :ref, code + quote ]
            pieces << (content.empty? || code.byteslice([ code.bytesize - 40, 0 ].max..).to_s.match?(ENV_KEY_TAIL) ? [ :ref, content ] : [ :lit, content, true ])
            code = +quote
          end
          pieces << [ :ref, code ] unless code.empty?
          pieces
        end

        # { brace: { open => close }, paren: { open => close } } in one pass, so a reference that never closes costs nothing.
        def brace_matches(body)
          matches = { brace: {}, paren: {} }
          stacks = { brace: [], paren: [] }
          at = 0
          while (edge = body.index(BRACKETS, at))
            char = body[edge]
            group = "{}".include?(char) ? :brace : :paren
            if "{(".include?(char) then stacks[group] << edge
            elsif (opened = stacks[group].pop) then matches[group][opened] = edge
            end
            at = edge + 1
          end
          matches
        end

        # A line of a statement a credential's name opened: its literals are filtered until the statement closes.
        def continue_statement(line, carry, path)
          _, (depth, ruby, blocks), left = carry
          return [ line, carry ] if line.strip.empty? || line.lstrip.start_with?("#")

          kind = kind_of(path)
          text = line.b
          shown = apply_edits(line, text, literal_edits(text, 0, kind, []))
          rest = text.sub(/[ \t]+#.*\z/, "").rstrip
          depth += bracket_delta(rest)
          blocks += block_delta(rest) if ruby
          open = depth.positive? || blocks.to_i.positive? || rest.match?(VALUE_OPENERS) || (ruby && rest.match?(CONTINUATION))
          [ shown, open && left > 1 ? [ :stmt, [ depth, ruby, blocks ], left - 1 ] : nil ]
        end

        # A Ruby value that closed on its line may still be followed by a method chain or a bare string on the
        # next line; blank and comment lines between do not end it.
        def continue_follow(line, carry, path)
          _, left = carry
          rest = left > 1 ? [ :follow, left - 1 ] : nil
          return [ line, rest ] if line.strip.empty? || line.lstrip.start_with?("#")
          return [ line, nil ] unless line.match?(CHAIN_START)

          shown, open = continue_statement(line, [ :stmt, [ 0, true, 0 ], CARRY_LINES ], path)
          [ shown, open || rest ]
        end

        def continue_word(line, path, placeholder)
          at = line.index(/\S/)
          return [ line, [ :word ] ] if at.nil? || line.lstrip.start_with?("#")
          return [ line, nil ] if line.match?(ASSIGNMENT_LINE)

          redact_value(line, at, path: path, &placeholder)
        end

        def continue_header(line, header, path, placeholder)
          return [ line, [ :cfg, header ] ] if line.strip.empty? || line.lstrip.start_with?("#")

          lead = line[/\A[ \t]*/]
          joined = "#{header} #{line.lstrip}"
          return [ line, nil ] if header.bytesize > 1024

          shown, carry = redact(joined, path: path, &placeholder)
          [ lead + shown.byteslice((header.bytesize + 1)..).to_s, carry ]
        end

        def continue_explicit(line, path, placeholder)
          head = line.match(/\A[ \t]*:[ \t]+/)
          head ? redact_value(line, head.end(0), path: path, &placeholder) : [ line, nil ]
        end

        # The value of a credential's name written on the lines under it: a scalar, a list, or a mapping whose
        # keys other than the descriptive ones may hold it.
        def continue_nextval(line, column, path, placeholder)
          return [ line, [ :nextval, column ] ] if line.strip.empty?
          return [ line, nil ] if line[/\A[ \t]*/].size <= column

          lead = line[/\A(?:[ \t]*-[ \t]+|[ \t]*)/]
          mapping = line.match(MAPPING_LINE)
          at = lead.size
          if mapping
            key = line[at..][/\A["']?([\w.-]+)["']?:/, 1].to_s
            return [ line, [ :nextval, column ] ] if KEEP_KEYS.include?(key.downcase) || key.start_with?("BUNDLE_")

            colon = line.index(":", at)
            return [ line, [ :nextval, column ] ] if line[(colon + 1)..].to_s.strip.empty?

            at = colon + 1 + line[(colon + 1)..][/\A[ \t]*/].size
          end
          shown, carry = redact_value(line, at, path: path, &placeholder)
          [ shown, carry || [ :nextval, column ] ]
        end

        def continue_heredoc(line, tags, carry)
          mode, tag = tags.first
          return [ line, carry ] if line.strip.empty?
          return [ line, tags.size > 1 ? [ :heredoc, tags.drop(1) ] : nil ] if (mode.empty? ? line : line.strip) == tag

          [ filter_line(line), carry ]
        end

        def continue_block(line, column, carry)
          return [ line, carry ] if line.strip.empty?

          line[/\A[ \t]*/].size <= column ? [ line, nil ] : [ filter_line(line), carry ]
        end

        def continue_quote(line, carry, path)
          _, open, left = carry
          kind = kind_of(path)
          return [ line, nil ] if left <= 0 || (!kind.yaml && !kind.ruby && line.match?(/\A[ \t]*[A-Z_][A-Z0-9_]*=/))

          closing = closing_index(line, open, kind)
          return [ filter_line(line), [ :quote, open, left - 1 ] ] unless closing

          lead = line[/\A[ \t]*/]
          [ closing > lead.size ? lead + filter_segments(line[lead.size...closing]) + line[closing..] : line, nil ]
        end

        # Where the quote opened by `open` closes on this line (character index), or nil.
        def closing_index(line, open, kind)
          closer = open.start_with?("%") ? PERCENT_CLOSE[open[-1]] : open[-1]
          body = case open
          when '"' then kind.ruby ? RUBY_DQ_BODY : DQ_BODY
          when "'" then kind.yaml ? /(?:[^']|'')*+/ : (kind.ruby ? ESCAPING_SQ_BODY : SQ_BODY)
          when "`" then BACKTICK_BODY
          when '"""' then TRIPLE_DQ_BODY
          when "'''" then TRIPLE_SQ_BODY
          else /(?:[^#{Regexp.escape(closer)}\\]|\\.)*+/m
          end
          edge = line.match(/\A#{body}/).end(0)
          edge < line.length ? edge : nil
        end

        def filter_line(line)
          lead = line[/\A[ \t]*/]
          lead + filter_segments(line[lead.size..])
        end

        # A continued line's text as the pieces of an unquoted word: references stay, literals go.
        def filter_segments(text)
          pieces = segment(text.b, :full)
          return FILTERED if pieces.none? { |type, _| type == :ref }

          (render(pieces, nil) || text.b).force_encoding(text.encoding)
        end

        # The id of the object each line belongs to: sibling lines at one indentation, a `- ` item opening a new one.
        def group_ids(lines)
          frames = []
          counter = 0
          lines.map do |line|
            next nil if line.strip.empty?

            indent = line[/\A[ \t]*/].size
            dash = line[/\A[ \t]*-[ \t]+/]
            if dash
              frames.pop while frames.any? && frames.last[0] > indent
              frames << [ dash.size, (counter += 1) ]
            else
              frames.pop while frames.any? && frames.last[0] > indent
              frames << [ indent, (counter += 1) ] unless frames.any? && frames.last[0] == indent
            end
            frames.last[1]
          end
        end

        # Where another name and its operator start inside text[from, to): that is the next setting, not more of this value.
        def next_header(text, from, context)
          context.state.headers ||= header_positions(text)
          context.state.headers.bsearch { |position| position > from } || text.bytesize
        end

        def header_positions(text)
          positions = []
          at = 0
          scanner = StringScanner.new(text)
          while (found = text.index(/(?<![\w$])BUNDLE_/, at))
            scanner.pos = found
            positions << found if scanner.match?(NAME_OPERATOR)
            at = found + 1
          end
          positions
        end

        def angle_placeholder(text, at, scanner)
          scanner.pos = at
          scanner.skip(/(?:<[A-Za-z][A-Za-z0-9_ .-]{0,30}>|\[[A-Za-z][A-Za-z0-9_ .-]{0,30}\])/)
        end

        def escaped_host?(text, at, host)
          return false unless host

          run = 1
          run += 1 while text.getbyte(at + run) == 92
          text.getbyte(at + run) == host
        end

        def alphanumeric?(byte)
          byte && ((48..57).cover?(byte) || (65..90).cover?(byte) || (97..122).cover?(byte))
        end

        def read_word(text, start, context)
          parts = []
          at = start
          stop = start
          host = context.host&.ord
          while (byte = text.getbyte(at)) && byte != host
            part = quoted_part(text, at, context) || bare_part(text, at, context)
            break if part.stop == at

            part.start = at
            parts << part
            stop = part.stop
            at = continuation(text, stop, part, context) or break
          end
          [ parts, stop ]
        end

        # Where the word goes on after `part`, or nil where it ends.
        def continuation(text, stop, part, context)
          byte = text.getbyte(stop)
          return nil if byte.nil? || byte == context.host&.ord
          if part.open.empty?
            return stop if quote_start?(text, stop, context)

            return part.body.start_with?("<%") && !text.byteslice(stop, 1).match?(/[\s,;)\]}]/) ? stop : nil
          end

          scanner = context.scanner
          scanner.pos = stop
          joined = scanner.skip(JOIN_PLUS) || (context.ruby && matched_skip(scanner, stop, JOIN_SPACE))
          return stop + joined if joined
          return nil if text.byteslice(stop, 1).match?(ENDS_AFTER_QUOTE) || matched(context.scanner, stop, MODIFIER)

          stop
        end

        def matched_skip(scanner, at, pattern)
          scanner.pos = at
          scanner.skip(pattern)
        end

        def quote_start?(text, at, context)
          byte = text.getbyte(at)
          return true if [ 34, 39, 96 ].include?(byte)

          following = text.getbyte(at + 1)
          (byte == 36 && [ 34, 39 ].include?(following)) || (byte == 92 && escaped_host?(text, at, context.host&.ord)) ||
            (byte == 38 && matched(context.scanner, at, /&(?:quot;|\#39;|\#34;)/))
        end

        def quoted_part(text, at, context)
          kind = context.kind
          case text.getbyte(at)
          when 34
            return delimited(text, at, '"""', '"""', TRIPLE_DQ_BODY, context) if kind.toml && text.byteslice(at, 3) == '"""'

            delimited(text, at, '"', '"', context.ruby ? RUBY_DQ_BODY : DQ_BODY, context)
          when 39
            return delimited(text, at, "'''", "'''", TRIPLE_SQ_BODY, context) if kind.toml && text.byteslice(at, 3) == "'''"

            delimited(text, at, "'", "'", context.ruby ? ESCAPING_SQ_BODY : SQ_BODY, context)
          when 96 then delimited(text, at, "`", "`", BACKTICK_BODY, context)
          when 36
            quote = text.getbyte(at + 1)
            delimited(text, at, "$#{quote.chr}", quote.chr, quote == 39 ? ESCAPING_SQ_BODY : DQ_BODY, context) if quote == 39 || quote == 34
          when 92
            run = 1
            run += 1 while text.getbyte(at + run) == 92
            escaped(text, at, run, context) if context.host && text.getbyte(at + run) == context.host.ord
          when 37 then context.ruby ? percent(text, at, context) : nil
          when 60 then erb(text, at, context)
          when 38 then entity(text, at, context)
          end
        end

        # `<%= ... %>` is read whole, as one part of the word.
        def erb(text, at, context)
          return nil unless text.getbyte(at + 1) == 37

          state = context.state
          close = state.erb_none && at >= state.erb_none ? nil : text.index("%>", at + 2)
          state.erb_none ||= at unless close
          close ? Part.new("", text.byteslice(at...(close + 2)), "", true, close + 2) : nil
        end

        def entity(text, at, context)
          return nil unless matched(context.scanner, at, /&(?:quot;|\#39;|\#34;)/)

          open = context.scanner.matched
          from = at + open.bytesize
          edge = text.index(open, from)
          return Part.new(open, text.byteslice(from...edge), open, true, edge + open.bytesize) if edge

          unclosed(text, open, from, context)
        end

        def delimited(text, at, open, close, body, context)
          from = at + open.bytesize
          context.scanner.pos = from
          edge = from + context.scanner.skip(body)
          return Part.new(open, text.byteslice(from...edge), close, true, edge + close.bytesize) if text.byteslice(edge, close.bytesize) == close

          unclosed(text, open, from, context)
        end

        # A quote escaped `run` backslashes deep, for a string written inside the host string.
        def escaped(text, at, run, context)
          opener = text.byteslice(at, run + 1)
          from = at + opener.bytesize
          edge = text.index(opener, from)
          return Part.new(opener, text.byteslice(from...edge), opener, true, edge + opener.bytesize) if edge

          unclosed(text, opener, from, context)
        end

        def percent(text, at, context)
          return nil unless matched(context.scanner, at, PERCENT)

          open = context.scanner[1]
          opener = context.scanner.matched
          close = PERCENT_CLOSE[open]
          depth = 1
          from = at + opener.bytesize
          scan = from
          edges = PERCENT_SCAN[open]
          while (edge = text.index(edges, scan))
            char = text.byteslice(edge, 1)
            if char == "\\" then scan = edge + 2
            else
              depth += 1 if char == open && open != close
              depth -= 1 if char == close
              return Part.new(opener, text.byteslice(from...edge), close, true, edge + 1) if depth.zero?

              scan = edge + 1
            end
          end
          unclosed(text, opener, from, context)
        end

        # An opening quote that never closes takes the rest of the line, up to the string the name sits in.
        def unclosed(text, open, from, context)
          stop = (context.host && host_edge(text, from, context.host)) || text.bytesize
          Part.new(open, text.byteslice(from...stop), "", false, stop)
        end

        def host_edge(text, from, host)
          scan = from
          while (edge = text.index(HOST_EDGES.fetch(host), scan))
            return edge if text.getbyte(edge) == host.ord

            scan = edge + 2
          end
        end

        def bare_part(text, at, context)
          scanner = context.scanner
          host = context.host&.ord
          scan = at
          limit = next_header(text, at, context)
          while scan < limit && (byte = text.getbyte(scan))
            scanner.pos = scan
            run = scanner.skip(context.spacey ? (host ? SPACEY_PLAIN : SPACEY_FREE) : PLAIN)
            if run
              scan += run
              next
            end

            following = text.getbyte(scan + 1)
            case byte
            when 92
              break if following.nil? || alphanumeric?(following) || escaped_host?(text, scan, host)

              scan += 2
            when 34, 39, 96
              break
            when 35
              close = following == 123 && (context.state.matches ||= brace_matches(text))[:brace][scan + 1]
              scan = close ? close + 1 : scan + 1
            when 36
              break if [ 34, 39 ].include?(following)

              if following == 123 || following == 40
                close = (context.state.matches ||= brace_matches(text))[following == 123 ? :brace : :paren][scan + 1]
                if close
                  scan = close + 1
                  next
                end
              end
              scan += following == 36 ? 2 : 1
            when 32, 9
              break unless context.spacey

              ahead = text.index(/[^ \t]/, scan) || text.bytesize
              break if ahead >= text.bytesize || text.getbyte(ahead) == 35

              scan = ahead
            when 91
              if (angle = angle_placeholder(text, scan, scanner))
                scan += angle
                next
              end
              scan += 1
            when 38, 124, 60, 62
              if byte == 60 && (angle = angle_placeholder(text, scan, scanner))
                scan += angle
                next
              end
              break unless context.lenient || alphanumeric?(following)

              scan += 1
            when 44, 59, 41, 93, 125
              break if following.nil? || text.byteslice(scan + 1, 1).match?(ENDS_AFTER_QUOTE) || [ 34, 39, 96 ].include?(following)

              scan += 1
            else
              break if byte == 10 || byte == 13 || byte == 12 || byte == 11

              scan += 1
            end
          end
          scan = limit if scan > limit
          scan -= 1 while context.spacey && scan > at && [ 32, 9, 13 ].include?(text.getbyte(scan - 1))
          Part.new("", text.byteslice(at...scan), "", true, scan)
        end
      end
    end
  end
end

require_relative "bundler_credentials/fail_closed"

module RailsAiContext
  module Redaction
    module BundlerCredentials
      class << self
        include FailClosed
      end
    end
  end
end
