# frozen_string_literal: true

require "strscan"

module RailsAiContext
  # The columns a CREATE TABLE ... AS query selects, as one database family names and types them: a column taken from
  # the FROM table keeps its type, a literal and a predicate take the family's type, any other computed column has none.
  module SelectList
    # A number as MySQL reads one: digits on either side of the point and an exponent.
    NUMBER = Introspectors::DumpedColumn::MYSQL_NUMBER

    module_function

    def family(adapter)
      DatabaseFamily.of(adapter).key
    end

    def postgres_rules?(adapter)
      DatabaseFamily.of(adapter).postgres_rules?
    end

    QUERY_END = /\s+WITH\s+(?:NO\s+)?DATA\s*\z/i
    COLUMN_REF = /\A(?:(?<qualifier>#{SqlScan::NAME})\s*\.\s*)?(?:(?<column>#{SqlScan::NAME})|(?<star>\*))\z/
    QUOTED_NAME = /\A(?:#{SqlScan::NAME})\z/
    FROM_TABLE = /\A(?:#{SqlScan::NAME_TEXT}\.)?(?<from>#{SqlScan::NAME_TEXT})(?:\s+(?:AS\s+)?(?!(?:JOIN|INNER|LEFT|RIGHT|FULL|CROSS|NATURAL|WHERE|GROUP|ORDER|LIMIT|HAVING|UNION|INTERSECT|EXCEPT|WINDOW|OFFSET|FETCH|FOR)\b)(?<as>#{SqlScan::NAME_TEXT}))?(?<rest>.*)\z/im
    # Words that take an operand on their right after one on their left; the second word of a two-word one goes with it.
    INFIX_WORDS = %w[AND OR IS LIKE ILIKE SIMILAR BETWEEN IN ESCAPE COLLATE DIV MOD XOR REGEXP RLIKE GLOB MATCH OPERATOR SOUNDS MEMBER].freeze
    INFIX_SECOND = { "SIMILAR" => %w[TO], "SOUNDS" => %w[LIKE], "MEMBER" => %w[OF], "BETWEEN" => %w[SYMMETRIC ASYMMETRIC] }.freeze
    # MySQL reads a string after a temporal type or a character set as that type's literal, and any other as the alias;
    # after N, X or B only when the quote touches the letter.
    MYSQL_INTRODUCER = /\A(?:DATE|TIME|TIMESTAMP|_\w+)\z/
    # A string after one of these is its own literal, which MySQL joins to no string after it.
    MYSQL_TYPED = /\A(?:DATE|TIME|TIMESTAMP|[XB])\z/
    INTERVAL_UNIT = /\A(?:MICROSECOND|SECOND|MINUTE|HOUR|DAY|WEEK|MONTH|QUARTER|YEAR)(?:_(?:MICROSECOND|SECOND|MINUTE|HOUR|DAY|MONTH))?\z/i
    # A select item's expression and alias: the name after a complete expression when nothing follows it, a type's,
    # an interval's, a window's and an infix keyword's own words staying with the expression; nil for any other shape.
    def item_alias(item, adapter)
      mysql = family(adapter) == :mysql
      tokens = item_tokens(item, adapter)
      kind = ->(at) { tokens[at]&.first }
      text = ->(at) { tokens[at] && tokens[at][1] }
      word = ->(at) { kind.(at) == :word && text.(at).match?(/\A[a-z_]\w*\z/i) && text.(at).upcase }
      mysql_string = ->(at) { mysql && (kind.(at) == :string || (kind.(at) == :quoted && text.(at).start_with?('"'))) }
      operand = false
      i = 0
      while i < tokens.size
        if !operand && word.(i) == "INTERVAL" && text.(i + 1) && (!word.(i + 1) || text.(i + 2).to_s.match?(INTERVAL_UNIT))
          i = interval_fields(tokens, i + 1)
          operand = true
        elsif !operand
          i += 1 if word.(i).to_s.match?(/\ANFK?[CD]\z/) && word.(i + 1) == "NORMALIZED"
          operand = !(word.(i) == "NOT" || (mysql && word.(i) == "BINARY") || (kind.(i) == :punct && text.(i) != "*"))
          i = type_words(tokens, i) if word.(i)
        elsif text.(i) == ":" && text.(i + 1) == ":" then i = type_words(tokens, i + 2)
        elsif kind.(i) == :punct then operand = false
        elsif kind.(i) == :group || (!mysql && %w[ISNULL NOTNULL].include?(word.(i)))
        elsif word.(i) == "AS"
          name = sql_name(text.(i + 1), adapter) if i + 2 == tokens.size && kind.(i + 1) != :number
          return name && [ item[0, tokens[i][2]].strip, name ]
        elsif kind.(i) == :string && word.(i - 1) && (postgres_rules?(adapter) || (mysql && word.(i - 1).match?(MYSQL_INTRODUCER)) ||
                                                     (tokens[i][2] == tokens[i - 1][2] + 1 && word.(i - 1).match?(mysql ? /\A[NXB]\z/ : /\AX\z/)))
        elsif mysql_string.(i) && mysql_string.(i - 1) && !(i >= 2 && word.(i - 2).to_s.match?(MYSQL_TYPED))
        elsif i + 1 == tokens.size && kind.(i) != :number && (name = sql_name(text.(i), adapter))
          return [ item[0, tokens[i][2]].strip, name ]
        elsif word.(i) == "NOT"
        elsif word.(i) == "AT" && word.(i + 1) == "TIME" && word.(i + 2) == "ZONE"
          i += 2
          operand = false
        elsif word.(i) == "OVER" || (word.(i) == "WITHIN" && word.(i + 1) == "GROUP") then i += 1
        elsif word.(i) == "FILTER" && kind.(i + 1) == :group
        elsif word.(i) == "FROM" && i >= 2 && word.(i - 1) == "DISTINCT" && (word.(i - 2) == "IS" || (i >= 3 && word.(i - 2) == "NOT" && word.(i - 3) == "IS"))
          operand = false
        elsif INFIX_WORDS.include?(word.(i))
          i += 1 if INFIX_SECOND[word.(i)]&.include?(word.(i + 1))
          operand = false
        else return nil
        end
        i += 1
      end
      [ item.strip, nil ]
    end

    # A select item's top-level tokens as [kind, text, offset], read by SqlScan's tokenizer for the family's quotes: a
    # number whole, as 1.5 or 1e-3, and each group in parentheses or brackets and each CASE ... END as one :group.
    def item_tokens(item, adapter)
      db = RailsAiContext::DatabaseFamily.of(adapter.to_s)
      at = 0
      flat = SqlScan.tokens(item, db, brackets: db.sqlite?).map { |kind, span| [ kind, span, at = item.index(span, at) ].tap { at += span.size } }
      opens = ->(kind, span) { (kind == :punct && "([".include?(span)) || (kind == :word && span.casecmp?("CASE")) }
      closes = ->(kind, span) { (kind == :punct && ")]".include?(span)) || (kind == :word && span.casecmp?("END")) }
      close_of = lambda do |at|
        depth = 0
        (at...flat.size).find { |j| (depth += opens.(*flat[j].first(2)) ? 1 : (closes.(*flat[j].first(2)) ? -1 : 0)) <= 0 }
      end
      tokens = []
      i = 0
      while i < flat.size
        kind, span, from = flat[i]
        last = i
        # A CASE with no END after it is a word, as the alias in k case.
        if opens.(kind, span) && (closed = close_of.(i) || (kind == :punct && flat.size - 1))
          last = closed
          kind = :group
        elsif span.match?(/\A\.?\d/) || (span == "." && flat[i + 1]&.[](1)&.match?(/\A\d/))
          joined = span
          (i + 1...[ i + 5, flat.size ].min).each do |j|
            break unless flat[j][2] == flat[j - 1][2] + flat[j - 1][1].size

            joined += flat[j][1]
            last = j if joined.match?(NUMBER)
          end
          kind = :number if last > i
        end
        tokens << [ kind, item[from...(flat[last][2] + flat[last][1].size)], from ]
        i = last + 1
      end
      tokens
    end

    # The last index of a type whose name runs over several words, as double precision or timestamp(3) with time zone,
    # from its first word at i; an interval's fields go with it.
    def type_words(tokens, i)
      name = tokens[i]&.[](1).to_s.downcase
      return interval_fields(tokens, i) if name == "interval"

      last = i
      loop do
        following = tokens[i + 1]&.first == :group ? i + 2 : i + 1
        break unless tokens[following] && PG_TYPE_NAMES.keys.any? { |type| type.start_with?("#{name} #{tokens[following][1].downcase}") }

        i = following
        name = "#{name} #{tokens[i][1].downcase}"
        last = i if PG_TYPE_NAMES.key?(name)
      end
      last
    end

    # The last index of an interval's fields after index i, as DAY or DAY TO SECOND; i when none follow.
    def interval_fields(tokens, i)
      unit = ->(at) { tokens[at]&.first == :word && tokens[at][1].match?(INTERVAL_UNIT) }
      i += 1 if unit.(i + 1)
      i += 2 if unit.(i) && tokens[i + 1]&.[](1)&.casecmp?("TO") && unit.(i + 2)
      i
    end

    # A bare or quoted name as the database spells the column: PostgreSQL folds a bare one to lower case, MySQL and
    # SQLite take a string as a name too, and SQLite a bracketed one.
    def sql_name(text, adapter)
      postgres = postgres_rules?(adapter)
      if !postgres && text.match?(/\A'.*'\z/m) then SqlScan.unquote(text, family: family(adapter))
      elsif text.match?(/\A\[.*\]\z/m) then text[1...-1]
      elsif (name = QUOTED_NAME.match(text))
        postgres && name[3] ? name[3].downcase : SqlScan.unquote_name(*name.captures)
      end
    end

    # @param sql [String] the query after AS
    # @param tables [Hash] the tables the query may read, by name, each with its columns:
    # @param adapter [String, Symbol, nil] the database adapter, which sets how names are quoted and folded
    # @return [Array<Hash>, nil] each selected column (name: nil when the family names it in a way not read here), or nil for a query not read
    def columns(sql, tables, adapter:)
      query = SqlScan.unwrap(sql.sub(QUERY_END, "").strip, family: family(adapter))
      if (whole = query[/\ATABLE\s+(?:#{SqlScan::NAME_TEXT}\.)?(#{SqlScan::NAME_TEXT})\z/io, 1])
        return Array(tables.dig(sql_name(whole, adapter), :columns)).dup.then { |found| found unless found.empty? }
      end

      list, from_clause = top_level_from(adapter, query[/\ASELECT\s+(?:ALL\s+|DISTINCT\s+ON\s*\((?:[^()]|\([^()]*\))*\)\s*|DISTINCT\b\s*)?(.+)\z/im, 1] || return)
      from, as, rest = FROM_TABLE.match(from_clause.to_s)&.captures&.then { |found, alias_name, after| [ found && sql_name(found, adapter), alias_name && sql_name(alias_name, adapter), after ] }
      source = tables.dig(from, :columns)
      single = from && !rest.match?(/\A\s*,|\b(?:JOIN|UNION|INTERSECT|EXCEPT)\b/i)
      SqlScan.new(list, family: family(adapter)).split(",").each_with_object([]) do |item, picked|
        expression, alias_name = item_alias(item, adapter)
        next picked << { type: nil } unless expression

        expression = SqlScan.unwrap(expression, family: family(adapter))
        literal = literal_column(expression, adapter)
        next picked << (alias_name ? literal.merge(name: alias_name) : literal) if literal
        next picked << { name: alias_name || computed_name(item.strip, adapter), type: predicate_type(adapter) } if predicate?(expression, adapter)

        # A number such as 1.5e3 is a constant, never a qualified column.
        qualifier, column, star = COLUMN_REF.match(expression)&.captures unless expression.match?(NUMBER)
        qualifier = sql_name(qualifier, adapter) if qualifier
        column = sql_name(column, adapter) if column
        own = qualifier ? [ from, as ].include?(qualifier) : single
        if star
          return nil unless own && source && (qualifier || single)

          picked.concat(source)
        else
          found = Array(source).find { |c| c[:name] == column } if own
          picked << (found || { type: nil }).merge(name: alias_name || (column unless postgres_rules?(adapter)) || computed_name(item.strip, adapter))
        end
      end
    end

    LITERAL = /\A(?:(-?\d+)|(-?(?:\d*\.\d+|\d+\.))|'((?:[^']|'')*)'|(true|false))\z/i
    # A literal as each database types the column it makes: PostgreSQL names it ?column?, MySQL by its value, and SQLite
    # by its text with no type. MySQL 8.4 makes it not null with its type's zero.
    # MySQL joins adjacent strings into one, named by the first.
    # shortcut: MariaDB gives a literal column no default, types an integer by other lengths and names joined strings by all of them, which the replay cannot tell from MySQL; split by server if a MariaDB app shows one.
    def literal_column(text, adapter)
      parts = item_tokens(text, adapter) if family(adapter) == :mysql
      if parts && parts.size > 1 && parts.all? { |kind, span| kind == :string || span.start_with?('"') }
        first, *rest = parts.map { |_, span| span[1...-1].gsub(span[0] * 2, span[0]) }
        return literal_column("'#{(first + rest.join).gsub("'", "''")}'", adapter).merge(name: first)
      end

      integer, decimal, string, truth = LITERAL.match(text)&.captures
      return unless integer || decimal || string || truth

      if postgres_rules?(adapter)
        bits = Integer(integer, 10).bit_length if integer
        type = if bits then bits < 32 ? "integer" : (bits < 64 ? "bigint" : "decimal")
        else decimal ? "decimal" : (string ? "text" : "boolean")
        end
        { name: "?column?", type: type }
      elsif family(adapter) == :mysql
        value = string&.gsub("''", "'")
        column = if value then { type: "string", limit: value.size, default: "" }
        elsif decimal
          whole, _, scale = decimal.delete("-").partition(".")
          { type: "decimal", precision: (whole.empty? ? 0 : [ whole.sub(/\A0+/, "").size, 1 ].max) + scale.size, scale: scale.size, default: "0" }
        else { **(truth ? { type: "integer" } : mysql_integer(integer)), default: "0" }
        end
        { name: value || text, null: false, **column }
      else { name: text, type: nil }
      end
    end

    # MySQL 8.4 types an integer literal by its text's length, sign and leading zeros counted, then by its value.
    def mysql_integer(text)
      value = Integer(text, 10)
      if text.size <= (value.negative? ? 11 : 8) then { type: "integer" }
      elsif value.bit_length < 64 then { type: "bigint" }
      elsif value.positive? && value.bit_length == 64 then { type: "bigint", unsigned: true }
      else { type: "decimal", precision: text.delete("-").sub(/\A0+/, "").size, scale: 0 }
      end
    end

    # A comparison or a boolean operator at an expression's top level; an operator character beside one makes another operator.
    PREDICATE = %r{(?<![-+*/<>=~!@#%^&|`?])(?:<=>|<>|!=|<=|>=|=|<|>)(?![-+*/<>=~!@#%^&|`?])|\b(?:IS|IN|LIKE|ILIKE|SIMILAR|BETWEEN|NOT|AND|OR|EXISTS|ISNULL|NOTNULL)\b}i

    def predicate?(expression, adapter)
      top_level(expression, family(adapter) == :mysql ? :mysql : :postgresql)[0].match?(PREDICATE)
    end

    # PostgreSQL types a predicate boolean and MySQL int; SQLite gives an expression column no type.
    def predicate_type(adapter)
      return "boolean" if postgres_rules?(adapter)

      "integer" if family(adapter) == :mysql
    end

    # A computed column's name: MySQL and SQLite name it by its text, PostgreSQL as its FigureColname does.
    def computed_name(text, adapter)
      postgres_rules?(adapter) ? postgres_name(text)&.first : text
    end

    PG_OPERATOR = %r{[-+*/%<>=~!@\#^&|`?]|\b(?:IS|ISNULL|NOTNULL|NOT|AND|OR|BETWEEN|IN|LIKE|ILIKE|SIMILAR|OPERATOR)\b}i
    PG_NAME = /"_*"|\w+/
    PG_CALL = /\A(?:(?:#{PG_NAME})\s*\.\s*)*(#{PG_NAME})\s*\(_*\)(?:\s*FILTER\s*\(_*\))?(?:\s*OVER\s*(?:\(_*\)|\w+))?\z/i
    PG_TYPED_LITERAL = /\A(?<type>[A-Za-z_][\w ]*?)\s*'_*'\z|\A(?<type>INTERVAL)\s*'_*'\s+\w+(?:\s+TO\s+\w+)?\z/i
    PG_REF = /\A(?:(?:#{PG_NAME})\s*\.\s*)*(#{PG_NAME})\z/
    PG_TYPE_NAMES = {
      "int" => "int4", "integer" => "int4", "smallint" => "int2", "bigint" => "int8", "real" => "float4", "float" => "float8",
      "double precision" => "float8", "decimal" => "numeric", "dec" => "numeric", "boolean" => "bool", "char" => "bpchar",
      "character" => "bpchar", "character varying" => "varchar", "char varying" => "varchar", "bit varying" => "varbit",
      "timestamp without time zone" => "timestamp", "timestamp with time zone" => "timestamptz",
      "time without time zone" => "time", "time with time zone" => "timetz"
    }.freeze

    # PostgreSQL's name for a select item and its strength (FigureColnameInternal, as PostgreSQL 16 names it): 2 for a name
    # it takes over a cast's type or a CASE's, 1 for a cast's type or case, 0 for ?column?. nil for a shape the replay
    # cannot read, which stays unnamed.
    def postgres_name(text)
      text = text.strip
      text = SqlScan.unwrap(text, family: :postgresql) while text.start_with?("(") && SqlScan.unwrap(text, family: :postgresql) != text
      return [ "?column?", 0 ] if text.match?(LITERAL) || text.match?(NUMBER) || text.match?(/\A(?:NULL|(?:[BEXN]|U&)'(?:[^']|'')*')\z/i)
      return postgres_sublink(text) if text.match?(/\A(?:SELECT|VALUES|WITH|TABLE)\b/i)

      top, cases = top_level(text)
      if cases == [ [ 0, text.size ] ]
        else_at = case_else(text)
        name = else_at ? postgres_name(text[else_at...-3]) : [ "case", 1 ]
        return name && (name[1] == 2 ? name : [ "case", 1 ])
      end
      if (normalized = top.match(/\s+IS\s+(?:NFK?[CD]\s+)?NORMALIZED\z/i)) && !top[0, normalized.begin(0)].match?(/\b(?:AND|OR|NOT)\b/i)
        return [ "is_normalized", 2 ]
      end
      return [ "?column?", 0 ] if top.match?(PG_OPERATOR)
      return [ "timezone", 2 ] if top.match?(/\bAT\s+TIME\s+ZONE\b/i)
      return postgres_name(text[0, Regexp.last_match.begin(0)]) if top =~ /\s+COLLATE\s+\S+\z/i

      if (cast = top.rindex("::")) && (!top[0, cast].strip.match?(/\s/) || top[0, cast].match?(PG_TYPED_LITERAL))
        postgres_cast(text[0, cast], text[(cast + 2)..])
      elsif top.match?(/\ACAST\s*\(_*\)\z/i) && (as = top_level(inner = text[(text.index("(") + 1)...-1])[0].rindex(/\sAS\s/i))
        postgres_cast(inner[0, as], inner[(as + 4)..])
      elsif top =~ /\A(\S+?)\s*(?:\[_*\])+\z/ && !Regexp.last_match(1).casecmp?("ARRAY")
        postgres_name(text[0, Regexp.last_match.end(1)])
      elsif top.match?(/\AARRAY\s*[\[(]_*[\])]\z/i) then [ "array", 2 ]
      elsif (literal = PG_TYPED_LITERAL.match(top)) then [ postgres_type_name(literal[:type]), 1 ]
      elsif top.match?(/\ATRIM\s*\(_*\)\z/i)
        [ { "leading" => "ltrim", "trailing" => "rtrim" }.fetch(text[/\(\s*(LEADING|TRAILING)\b/i, 1].to_s.downcase, "btrim"), 2 ]
      elsif (call = PG_CALL.match(top) || PG_REF.match(top)) then [ folded_name(text[call.begin(1)...call.end(1)]), 2 ]
      end
    end

    # A scalar subquery takes its first column's name, ?column? included; nil for one that does not start with SELECT
    # or whose first item is a star.
    def postgres_sublink(query)
      return unless query.match?(/\ASELECT\b/i)

      list, = top_level_from("postgresql", query[/\ASELECT\b\s*(?:ALL\b\s*|DISTINCT\b\s*)?(.+)\z/im, 1] || return)
      expression, alias_name = item_alias(SqlScan.new(list, family: :postgresql).split(",").first.to_s, "postgresql")
      return if COLUMN_REF.match(expression.to_s)&.[](:star)
      name = alias_name || (expression && postgres_name(expression)&.first)
      [ name, 2 ] if name
    end

    # A cast takes its argument's name when PostgreSQL names that by itself, else its type's last name.
    def postgres_cast(arg, type)
      name = postgres_name(arg) or return
      name[1] == 2 ? name : [ postgres_type_name(type), 1 ]
    end

    # A type's last name as PostgreSQL's grammar spells it: int is int4, double precision float8, float(n) float4 up to 24 bits.
    def postgres_type_name(type)
      type = SqlScan.strip_array_suffix(type.strip).first
      last = last_name(type)
      return SqlScan.names(last).first if last.start_with?('"')

      bits = last[/\Afloat\s*\(\s*(\d+)/i, 1]
      return bits.to_i <= 24 ? "float4" : "float8" if bits

      words = last.gsub(/(?<!\s)\s*\([^()]*\)/, " ").squeeze(" ").strip.downcase
      PG_TYPE_NAMES.fetch(words, words)
    end

    # The text after the last dot outside quotes and parentheses. A scan from the end keeps a long run of quotes linear.
    def last_name(type)
      scan = SqlScan.new(type, family: :postgresql)
      bytes = type.b
      dot = bytes.rindex(".")
      dot = (dot.zero? ? nil : bytes.rindex(".", dot - 1)) while dot && !scan.top_level?(dot)
      (dot ? type.byteslice(dot + 1..) : type).strip
    end

    def folded_name(name)
      name.start_with?('"') ? SqlScan.names(name).first : name.downcase
    end

    # The text with quoted text, the inside of parentheses and brackets, and each CASE's body blanked, so a pattern sees
    # only the top level; and the start and end of each top-level CASE.
    def top_level(text, family = :postgresql)
      scan = SqlScan.new(text, family: family)
      shown = Array.new(text.bytesize) { |i| scan.top_level?(i) }
      groups = shown.each_index.select { |i| shown[i] && [ 40, 91 ].include?(text.getbyte(i)) }.map { |i| i..(scan.paren_group(i) || text.bytesize) }
      # A top-level quoted span is shown by its quotes alone.
      scan.quoted_spans.each do |_, from, to|
        shown[from] = shown[to - 1] = true unless to - from < 2 || groups.any? { |group| group.cover?(from) }
      end
      at = 0
      masked = text.each_char.map { |char| (shown[at] ? char : "_").tap { at += char.bytesize } }.join
      cases = case_spans(masked)
      cases.each { |from, to| masked[(from + 4)...(to - 3)] = "_" * (to - from - 7) }
      [ masked, cases ]
    end

    # Each top-level CASE ... END in a masked text, as its start and end.
    def case_spans(masked)
      depth = 0
      from = nil
      masked.to_enum(:scan, /\b(?:CASE|END)\b/i).filter_map do
        match = Regexp.last_match
        if match[0].casecmp?("CASE")
          from = match.begin(0) if depth.zero?
          depth += 1
          nil
        elsif depth.positive?
          depth -= 1
          [ from, match.end(0) ] if depth.zero?
        end
      end
    end

    # Where the ELSE result of the CASE that is the whole text starts, nil when it has none.
    def case_else(text)
      masked = top_level(text[4...-3])[0]
      depth = 0
      masked.to_enum(:scan, /\b(?:CASE|ELSE|END)\b/i).each do
        match = Regexp.last_match
        word = match[0].upcase
        return match.end(0) + 4 if word == "ELSE" && depth.zero?

        depth += word == "CASE" ? 1 : (word == "END" ? -1 : 0)
      end
      nil
    end

    DISTINCT_BEFORE = /\bIS\s+(?:NOT\s+)?DISTINCT\z/i
    # The select list and what follows its FROM, split at the FROM outside parentheses and quotes. The FROM of
    # IS [NOT] DISTINCT FROM is part of a select item.
    def top_level_from(adapter, query)
      scan = SqlScan.new(query, family: family(adapter))
      scanner = StringScanner.new(query)
      while scanner.skip_until(/\s+FROM\s+/i)
        at = scanner.pos - scanner.matched.bytesize
        next if !scan.top_level?(at) || query.byteslice(0, at).match?(DISTINCT_BEFORE)

        return [ query.byteslice(0, at), query.byteslice(scanner.pos, query.bytesize) ]
      end
      [ query, nil ]
    end
  end
end
