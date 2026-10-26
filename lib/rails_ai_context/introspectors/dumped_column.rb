# frozen_string_literal: true

require "bigdecimal"
require "strscan"

module RailsAiContext
  module Introspectors
    # A column as schema.rb writes it for one database family and Rails version, whichever source declared it:
    # a dump's column definition, a replayed migration or the live connection.
    module DumpedColumn
      module_function

      # declared, every key optional but a type:
      #   sql_type:          the type as SQL declares it, or
      #   type:              the type as a migration or the connection names it, with limit:, precision:, scale:, unsigned:, size:, array:
      #   default:           a value, as the database is sent it or as the connection reads it
      #   default_sql:       an expression as a statement writes it, which the database stores its own way
      #   stored_default:    the DEFAULT clause's text as the database keeps it
      #   default_function:  an expression the connection reads as the default
      #   primary_key:       whether the column is the whole key, which names a serial
      #   name:, null:, comment:, collation:, enum_type:, generated:, stored:, auto_increment: as the source has them
      # @return [Hash] the column: type, the sizes schema.rb writes, and default as the dump spells it; own_sequence:,
      #   auto_increment: and year: mark what a caller settles
      def call(declared, family:, rails_version:)
        family = DatabaseFamily.of(family)
        key = family.key
        primary_key = declared[:primary_key] == true
        type, detail = if declared[:sql_type]
          column_type(declared[:sql_type], key, primary_key: primary_key)
        else
          dumped_type(declared[:type], declared, key, primary_key: primary_key)
        end
        type = "enum" if declared[:enum_type] && family.postgres_rules?
        column = declared.slice(*KEPT).merge(type: type, **detail)
        column[:year] = true if declared[:year] == true || declared[:type].to_s.match?(/\Ayear\b/i)
        column.delete(:enum_type) unless type == "enum"
        column.delete(:limit) if type == "float" && family.postgres_rules? && !RailsVersion.at_least?(rails_version, "7.2.2")
        decimal_sizes(column, key) if type == "decimal"
        default = dumped_default(declared, column, key, rails_version)
        default.nil? ? column.delete(:default) : column[:default] = default
        without_nils(column)
      end

      # A column without its nil values, but its type and a datetime's precision: nil, which schema.rb writes for one with no precision.
      def without_nils(column)
        column.reject { |key, value| value.nil? && key != :type && !(key == :precision && column[:type] == "datetime") }
      end

      KEPT = %i[name null comment collation enum_type generated stored auto_increment].freeze

      # The dump reads a decimal of scale 0 as DecimalWithoutScale, which writes no scale; MySQL stores one with neither size as decimal(10,0).
      def decimal_sizes(column, family)
        scale = column.delete(:scale) || (0 if column[:precision] || family == :mysql)
        column[:scale] = scale if scale&.positive?
        column[:precision] ||= 10 if family == :mysql
      end

      def dumped_default(declared, column, family, rails_version)
        value = if declared.key?(:stored_default) then stored_default(declared[:stored_default], column, family, rails_version)
        elsif declared.key?(:default_sql) then written_default(declared[:default_sql], column, family, rails_version)
        elsif declared.key?(:default) then sent_default(declared[:default], column, family)
        end
        value = "-> { #{declared[:default_function].inspect} }" if value.nil? && declared[:default_function]
        return if value.nil?

        value = value.to_s
        value = boolean_default(value) if column[:type] == "boolean" && !column[:array]
        value = dumped_decimal(value, column[:scale] || (0 if column[:precision]), server_rounds: family == :mysql) if column[:type] == "decimal"
        value
      end

      # A value the database holds: MySQL rounds a number on a YEAR to a year, PostgreSQL keeps an array's elements.
      def sent_default(value, column, family)
        return mysql_year(BigDecimal(value)) || value if column[:year] && value.is_a?(Integer) && family == :mysql
        return postgres_array(value, column) || value if column[:array] && (value.is_a?(Array) || value.is_a?(String))

        value
      end

      # An expression as a statement writes it: SQLite keeps its text, PostgreSQL and MySQL store what it means.
      def written_default(sql, column, family, rails_version)
        return stored_default(sql, column, family, rails_version) if family == :sqlite

        literal = family == :mysql ? mysql_value(sql, column) : postgres_value(sql, column)
        return if literal.equal?(NO_DEFAULT)

        literal.nil? ? "-> { #{sql.inspect} }" : literal
      end

      # The default as the schema.rb reader reports it: a literal's value, an expression as `-> { "expr" }` (on
      # PostgreSQL only a function), nil for none, NULL or a serial's nextval(...).
      def stored_default(text, column, family, rails_version)
        text = text.to_s.strip
        return if text.empty? || text.match?(/\ANULL\z/i) || text.match?(/\Anextval\(/i)
        return sqlite_default(text, column[:type], rails_version, column[:scale] || (0 if column[:precision])) if family == :sqlite

        if (literal = text.match(/\A('.*')(?:::[\w\s\[\]."]+)?\z/m)) && (quoted = SqlScan.unquote(literal[1], family: family))
          column[:array] ? array_default(quoted, column[:type], column[:scale] || (0 if column[:precision])) : quoted
        elsif text.match?(DECIMAL_TEXT) || text.match?(/\A(?:true|false)\z/i)
          text.downcase
        elsif family == :mysql || text.match?(PG_FUNCTION)
          "-> { #{text.inspect} }"
        end
      end

      # A SQLite default as the adapter reads it (extract_value_from_default, has_default_function?): an expression without its
      # outer parentheses, and nothing that is no literal, number or function. Rails 7.0 reads a quoted literal with a | in it as one.
      # shortcut: an x'..' blob literal reads as no default, where Rails 7.1 on reads its bytes; decode it if a tool shows one.
      def sqlite_default(text, type, rails_version, scale = nil)
        text = SqlScan.unwrap(text, family: :sqlite)
        current = RailsVersion.at_least?(rails_version, "7.1")
        if RailsVersion.at_least?(rails_version, "8.1.4") ? text.match?(/\A(?:true|false)\z/i) : RailsVersion.at_least?(rails_version, "8.1") && %w[TRUE FALSE].include?(text)
          sqlite_truth(text, type, scale, rails_version)
        elsif (literal = text.match(current ? /\A(['"])([^|]*)\1\z/m : /\A(['"])(.*)\1\z/m))
          literal[2].gsub(literal[1] * 2, literal[1])
        elsif text.match?(/\A-?\d+(?:\.\d*)?\z/)
          text
        elsif text.match?(current ? SQLITE_FUNCTION : SQLITE_FUNCTION_70)
          "-> { #{text.inspect} }"
        end
      end

      # Rails 8.1.0 reads TRUE and FALSE as that text and 8.1.4 either case as a boolean, which the column's type casts
      # and the dumper writes; a value it cannot cast or dump reads as no default.
      def sqlite_truth(word, type, scale, rails_version)
        unless RailsVersion.at_least?(rails_version, "8.1.4")
          return case type
                 when "integer", "bigint", "decimal" then "0"
                 when "float" then "0.0"
                 when "date", "datetime", "time", "json" then nil
                 else word
                 end
        end

        truth = word.casecmp?("true")
        case type
        when "string", "text" then truth ? "t" : "f"
        when "float" then truth ? "1.0" : "0.0"
        when "decimal" then (truth ? "1" : "0") unless scale&.zero?
        when "integer", "bigint", "date", "datetime", "time" then nil
        else truth.to_s
        end
      end

      BOOLEAN_FALSE = %w[0 f F false FALSE off OFF].freeze

      # ActiveModel::Type::Boolean's cast: an empty string is no value, its false words are false, any other text is true.
      def boolean_default(value)
        return value unless value.is_a?(String) && !value.start_with?("-> {")

        (!BOOLEAN_FALSE.include?(value)).to_s unless value.empty?
      end

      # What PostgreSQL's adapter reads as a function default (has_default_function?, 7.0 to 8.1); any other expression is none.
      PG_FUNCTION = %r{\w+\(.*\)|\(.*\)::\w+|CURRENT_DATE|CURRENT_TIMESTAMP}

      SQLITE_FUNCTION = /\w+\(.*\)|CURRENT_TIME|CURRENT_DATE|CURRENT_TIMESTAMP|\|\|/
      SQLITE_FUNCTION_70 = /\w+\(.*\)|CURRENT_TIME|CURRENT_DATE|CURRENT_TIMESTAMP/

      # A PostgreSQL array literal ({1,NULL} or {a,"b c"}) as Rails dumps it: each element cast through the column's type; nil if it does not parse.
      # shortcut: a float element Infinity or NaN reads as Ruby shows it, where the dump writes ::Float::INFINITY; match it if a tool shows one.
      def array_default(value, type, scale = nil)
        scanner = StringScanner.new(value.strip)
        items = array_items(scanner) or return
        scanner.eos? ? array_cast(items, type, scale) : nil
      end

      # PG::TextDecoder::Array: an unquoted NULL is nil, quotes and backslashes escape.
      def array_items(scanner)
        return unless scanner.skip(/\{\s*/)
        return [] if scanner.skip(/\}/)

        items = []
        loop do
          if scanner.check(/\{/)
            items << (array_items(scanner) or return)
          elsif scanner.skip(/"/)
            items << scanner.scan(/(?:[^"\\]|\\.)*/m).gsub(/\\(.)/m, '\\1')
            return unless scanner.skip(/"/)
          else
            item = scanner.scan(/(?:[^,{}"\\]|\\.)+/m) or return
            items << (item.strip.match?(/\ANULL\z/i) ? nil : item.strip.gsub(/\\(.)/m, '\\1'))
          end
          scanner.skip(/\s*/)
          return items if scanner.skip(/\}/)
          return unless scanner.skip(/,\s*/)
        end
      end

      # Each element as its type's type_cast_for_schema writes it: a NULL decimal as "" (nil.to_s), a time on 2000-01-01.
      def array_cast(items, type, scale)
        items.map do |item|
          next array_cast(item, type, scale) if item.is_a?(Array)
          next (type == "decimal" ? "" : nil) if item.nil?

          case type
          when "integer", "bigint" then item.to_i
          when "float" then FLOAT_WORDS.fetch(item) { item.to_f }
          when "decimal" then dumped_decimal(item, scale)
          when "boolean" then item.empty? ? nil : !%w[f false 0 off].include?(item.downcase)
          when "time" then "2000-01-01 #{item[/\A\d\d:\d\d:\d\d/] || item}"
          else item
          end
        end
      end

      FLOAT_WORDS = { "Infinity" => Float::INFINITY, "-Infinity" => -Float::INFINITY, "NaN" => Float::NAN }.freeze
      # A decimal as a dump writes it, and a number as MySQL reads one: digits on either side of the point and an exponent.
      DECIMAL_TEXT = /\A-?\d+(?:\.\d+)?\z/
      MYSQL_NUMBER = /\A(?<sign>-?)(?=\.?\d)(?<whole>\d*)(?:\.(?<fraction>\d*))?(?<exponent>e[-+]?\d+)?\z/i

      # A decimal default as Rails dumps it: a BigDecimal rounded to the scale (whole at scale 0, DecimalWithoutScale), as its to_s.
      # MySQL rounds what it stores to the scale first, a zero unsigned. Text that is no number stays.
      def dumped_decimal(value, scale, server_rounds: false)
        return value unless value.is_a?(String) && value.match?(DECIMAL_TEXT)

        decimal = BigDecimal(value)
        decimal = decimal.round(scale).then { |rounded| rounded.zero? ? rounded.abs : rounded } if server_rounds && scale
        scale&.zero? ? decimal.to_i.to_s : (scale ? decimal.round(scale) : decimal).to_s("F")
      end

      PG_LITERAL = /\AB?'((?:[^']|'')*)'(?:\s*::\s*(?:#{SqlScan::QUOTED_NAME_TEXT}|[\w ]+)(?:\.(?:#{SqlScan::QUOTED_NAME_TEXT}|[\w ]+))*(?:\[\])?)?\z/m
      PG_TRUE = /\A(?:t(?:r(?:ue?)?)?|y(?:es?)?|on|1)\z/
      PG_FALSE = /\A(?:f(?:a(?:l(?:se?)?)?)?|no?|off?|0)\z/
      # The reader's rule on the SQL as declared, which PostgreSQL stores with its keywords upper case.
      # shortcut: an explicit cast PostgreSQL drops or folds (to the column's own type, of a bare number) is judged as written; model the cast if a dump shows one.
      PG_FUNCTION_AS_WRITTEN = Regexp.new(PG_FUNCTION.source, Regexp::IGNORECASE | Regexp::MULTILINE)
      NO_DEFAULT = Object.new.freeze
      TIME_TYPES = %w[date datetime time timestamp timestamptz].freeze

      # PostgreSQL stores a whole literal as the column's type reads it, and Rails decodes it back (extract_value_from_default):
      # a boolean by PostgreSQL's input words, an array as its elements. A date or time word such as 'now' becomes the moment the
      # table was made, which no replay knows. Any other expression is a default only where has_default_function? accepts it.
      def postgres_value(sql, col)
        case sql
        when /\A\((.*)\)\z/m then postgres_value(Regexp.last_match(1).strip, col)
        when /\A\(\s*(B?'(?:[^']|'')*')\s*\)(\s*::.+)\z/m then postgres_value(Regexp.last_match(1) + Regexp.last_match(2), col)
        when PG_LITERAL
          value = Regexp.last_match(1).gsub("''", "'")
          type = col[:type]
          return if TIME_TYPES.include?(type) && !value.match?(/\A\d/)
          return postgres_array(value, col) if col[:array]

          type == "boolean" ? postgres_boolean(value) : value
        when /\A(?:true|false)\z/i then sql.downcase
        when /\A-?\d+(?:\.\d*)?(?:::bigint)?\z/ then sql.delete_suffix("::bigint")
        when PG_FUNCTION_AS_WRITTEN then nil
        when String then NO_DEFAULT
        end
      end

      # An array literal, or a Ruby array as PostgreSQL stores its elements' text, a boolean one by PostgreSQL's input
      # words. A decimal whose precision has no scale is scale 0.
      def postgres_array(value, col)
        scale = col[:scale] || (0 if col[:precision])
        items = value.is_a?(Array) ? array_text(value) : array_default(value, nil) or return
        items = array_text(items) { |item| postgres_boolean(item) } if col[:type] == "boolean"
        array_cast(items, col[:type], scale)
      end

      def array_text(items, &each)
        items.map { |item| item.is_a?(Array) ? array_text(item, &each) : item.nil? ? nil : (each ? each.call(item.to_s) : item.to_s) }
      end

      def postgres_boolean(value)
        word = value.strip.downcase
        if word.match?(PG_TRUE) then "true"
        elsif word.match?(PG_FALSE) then "false"
        end
      end

      # MySQL stores a bare literal or number as the value, which reads back as the column's type casts it; one in
      # parentheses is an expression it keeps.
      def mysql_value(sql, col)
        case sql
        when /\A'.*'\z/m then SqlScan.unquote(sql, family: :mysql)
        when MYSQL_NUMBER then mysql_number(Regexp.last_match, col)
        when /\A(?:true|false)\z/i then sql.casecmp?("true") ? "1" : "0"
        end
      end

      # A number as MySQL stores it for the column's type: rounded for an integer, a float in six digits and a double in its
      # shortest, a decimal as it is, a string's or binary's own text. A date or time column turns it into a date, and an
      # e-notation number no double holds (or one on a float column) stays the proc.
      def mysql_number(number, col)
        value = mysql_decimal(number)
        return if (number[:exponent] || col[:type] == "float") && !value.to_f.finite?

        case col[:type]
        when "integer", "bigint", "boolean" then col[:year] ? mysql_year(value, even: number[:exponent]) : mysql_round(value, number).to_s
        when "float" then mysql_double(col[:limit].to_i > 24 ? value.to_f.to_s : format("%.6g", value.to_f))
        when "decimal" then (number[:exponent] ? BigDecimal(value.to_f.to_s) : value).to_s("F")
        when "string", "text", "binary" then mysql_number_text(number, value)
        when *TIME_TYPES then nil
        else number[0]
        end
      end

      # An e-notation number is a double, which MySQL rounds half to even; an exact one rounds half away from zero.
      def mysql_round(value, number)
        number[:exponent] ? value.round(half: :even).to_i : value.round.to_i
      end

      # A number on a YEAR column becomes a year: 1 to 69 in the 2000s, 70 to 99 in the 1900s, 0 as 0000. A negative one and any
      # outside 1901 to 2155 stay the proc.
      def mysql_year(value, even: false)
        year = even ? value.round(half: :even).to_i : value.round.to_i
        return if value.negative?

        case year
        when 0, 1901..2155 then year.to_s
        when 1..69 then (2000 + year).to_s
        when 70..99 then (1900 + year).to_s
        end
      end

      # MySQL writes a whole or decimal number without its leading zeros, and the sign of a zero not at all; an e-notation
      # one is a double, in its shortest digits.
      def mysql_number_text(number, value)
        return mysql_double(value.to_f.to_s) if number[:exponent]

        whole = number[:whole].sub(/\A0+(?=\d)/, "")
        whole = "0" if whole.empty?
        "#{number[:sign] unless value.zero?}#{whole}#{".#{number[:fraction]}" unless number[:fraction].to_s.empty?}"
      end

      # The number's value; bigdecimal before 3.2 reads no point without a digit after it.
      def mysql_decimal(number)
        whole = number[:whole].to_s.empty? ? 0 : number[:whole]
        fraction = number[:fraction].to_s.empty? ? 0 : number[:fraction]
        BigDecimal("#{number[:sign]}#{whole}.#{fraction}#{number[:exponent]}")
      end

      # A double's digits as MySQL writes them: out from 1e-15 to under 1e15, in e notation outside that.
      def mysql_double(number)
        value = BigDecimal(number)
        return "0" if value.zero?

        sign, digits, _, exponent = value.split
        return value.to_s("F").delete_suffix(".0") if (exponent - 1).between?(-15, 14)

        "#{'-' if sign.negative?}#{digits[0]}#{".#{digits[1..]}" if digits.size > 1}e#{exponent - 1}"
      end

      # A declared type and its sizes as the dump writes them, MySQL's unsigned among them (type_to_sql, schema_precision, 7.0 to 8.1).
      def dumped_type(type, options, family, primary_key: false)
        mysql = family == :mysql
        if mysql && (signed = type.to_s[/\Aunsigned_(\w+)\z/, 1])
          type = signed
          options = options.merge(unsigned: true)
        end
        sizes = options.slice(:limit, :precision, :scale).select { |_, value| value.is_a?(Integer) }
        limit = sizes[:limit]
        name, detail = case type.to_s
        when "decimal" then [ type.to_s, sizes.slice(:precision, :scale) ]
        # numeric is no native type, so type_to_sql writes it bare, and every adapter's type map reads it as decimal.
        when "numeric" then [ "decimal", {} ]
        when "string" then [ "string", mysql && limit == 255 ? {} : sizes.slice(:limit) ]
        when "integer" then dumped_integer(limit, family)
        # Only MySQL reads a timestamp back as one; the others read it as a datetime.
        when "datetime", "timestamp", "time", "timestamptz", "interval"
          name = %w[time timestamptz interval].include?(type.to_s) ? type.to_s : normalize_sql_type(type.to_s, family)
          [ name, dumped_precision(name, sizes[:precision], family, given: options.key?(:precision) && options[:precision].nil?) ]
        when "text", "binary" then [ type.to_s, dumped_blob_size(type.to_s, limit, family) ]
        # type_to_sql writes float(n) for a float's limit on every adapter.
        when "float" then [ "float", column_type(limit ? "float(#{limit})" : "float", family).last ]
        # A type the replay cannot read (add_column with a computed one) stays nil, not the reader's "".
        when "" then [ nil, {} ]
        else
          name, detail = column_type(type.to_s, family, primary_key: primary_key)
          [ name, %w[bit bit_varying].include?(name) ? sizes.slice(:limit).merge(detail) : detail ]
        end
        detail = detail.merge(unsigned: true) if mysql && options[:unsigned] == true
        detail = detail.merge(size: options[:size].to_s) if mysql && %w[text binary].include?(name) && (options[:size].is_a?(Symbol) || options[:size].is_a?(String))
        detail = detail.merge(array: true) if options[:array] == true && DatabaseFamily.of(family).postgres_rules?
        [ name, detail ]
      end

      # PostgreSQL's text and bytea take no limit; MySQL picks tiny to long by it (a binary under 4 KB
      # is a varbinary that keeps it); SQLite keeps it as declared.
      def dumped_blob_size(type, limit, family)
        return {} if limit.nil? || DatabaseFamily.of(family).postgres_rules?
        return { limit: limit } unless family == :mysql && !(type == "binary" && limit <= 0xfff)

        size = case limit
        when 0..0xff then "tiny"
        when 0x100..0xffff then nil
        when 0x10000..0xffffff then "medium"
        else "long"
        end
        size ? { size: size } : {}
      end

      def dumped_integer(limit, family)
        postgres = DatabaseFamily.of(family).postgres_rules?
        return [ "integer", limit ? { limit: limit } : {} ] unless postgres || family == :mysql
        return [ "bigint", {} ] if limit.to_i > 4
        return [ "integer", {} ] if limit.nil? || limit == 4 || (postgres && limit == 3)

        [ "integer", { limit: postgres ? 2 : limit } ]
      end

      # PostgreSQL's serials are not null integers of their size with a sequence.
      SERIALS = { "serial" => "integer", "smallserial" => "smallint", "bigserial" => "bigint" }.freeze

      # A column type as written in SQL, named and sized the way the adapter reads it back.
      def column_type(raw_type, family, primary_key: false)
        postgres = DatabaseFamily.of(family).postgres_rules?
        if postgres && (integer = SERIALS[raw_type.downcase])
          type, detail = column_type(integer, family)
          return [ serial_name(type, primary_key), detail.merge(null: false, own_sequence: true) ]
        end
        # MySQL's serial is BIGINT UNSIGNED NOT NULL AUTO_INCREMENT UNIQUE (serial_index).
        return [ "bigint", { unsigned: true, null: false, auto_increment: true } ] if family == :mysql && raw_type.casecmp?("serial")
        # MySQL makes a bare bit a bit(1).
        raw_type = "bit(1)" if family == :mysql && raw_type.casecmp?("bit")

        type = normalize_sql_type(raw_type.delete_suffix("[]"), family)
        detail = type_detail(raw_type, type, family)
        detail[:array] = true if raw_type.end_with?("[]") && postgres
        # PostgreSQL's money is a decimal of scale 2 to the adapter (OID::Money).
        detail[:scale] = 2 if postgres && type == "money"
        [ type, detail ]
      end

      # The name PostgreSQL's dumper gives a serial integer or bigint: serial or bigserial, and a bigserial that is the whole key
      # the default key (postgresql/schema_dumper.rb schema_type and default_primary_key?, 7.0 to 8.1).
      def serial_name(type, primary_key)
        return "serial" unless type == "bigint"

        primary_key ? "bigint" : "bigserial"
      end

      def without_sequence(column)
        return column unless column[:own_sequence]

        column.except(:own_sequence).merge(type: SERIALS.fetch(column[:type], column[:type]))
      end

      # The default PostgreSQL reads for a sequence: its ::regclass text, each part quoted as regclass output quotes it.
      def nextval_default(sequence)
        regclass = SqlScan.qualified_parts(sequence).map { |part| PgNaming.quote_ident(part) }.join(".")
        "-> { #{"nextval('#{regclass.gsub("'", "''")}'::regclass)".inspect} }"
      end

      # A nextval_default's regclass text, as inspect escapes it.
      NEXTVAL_TEXT = /\A->\s*\{\s*"nextval\('((?:[^'\\]|''|\\.)+)'(?:::regclass)?\)"\s*\}\z/

      # The sequence a nextval_default names as a joined name (SqlScan.join_qualified), without public; nil for any other default.
      def nextval_sequence(default)
        text = default.to_s[NEXTVAL_TEXT, 1] or return
        parts = SqlScan.names(text.gsub(/\\(.)/, '\1').gsub("''", "'"))
        parts.shift if parts.size > 1 && parts.first == "public"
        SqlScan.join_qualified(*parts)
      end

      # The size a type was given, as schema.rb writes it: varchar(255) is
      # MySQL's default string, 6 a datetime's default precision.
      def type_detail(raw_type, type, family)
        detail = {}
        detail[:unsigned] = true if family == :mysql && SqlScan.new(raw_type, family: :mysql).masked.match?(/\bunsigned\b/i)
        size = SchemaConventions.mysql_text_size(raw_type) if family == :mysql
        detail[:size] = size if size
        # SQLite's type map reads no size off an integer's name.
        limit = INTEGER_LIMITS[raw_type[/\A\w+/].to_s.downcase] unless family == :sqlite
        detail[:limit] = limit if type == "integer" && limit
        float = float_limit(raw_type, family) if type == "float"
        detail[:limit] = float if float
        sizes = raw_type[/\((\d+(?:\s*,\s*\d+)?)\)/, 1]&.split(",")&.map(&:to_i)
        return detail.merge(dumped_precision(type, nil, family, given: true)) unless sizes

        detail.merge(sized(type, sizes, family))
      end

      # The limit Rails reads off a float type: 53 for MySQL's double (real, float8, float(25) up), 24 for PostgreSQL's real
      # (float4, float(1) to float(24)), and float(n) as written on SQLite.
      def float_limit(raw_type, family)
        base = raw_type.delete_suffix("[]").downcase
        bits = base[/\Afloat\s*\((\d+)\)/, 1]&.to_i
        case family
        when :mysql then 53 if base.match?(/\A(?:double|real|float8)\b/) || bits.to_i > 24
        when :sqlite then base[/\((\d+)\)/, 1]&.to_i
        else 24 if %w[real float4].include?(base) || bits&.between?(1, 24)
        end
      end

      INTEGER_LIMITS = { "smallint" => 2, "int2" => 2, "tinyint" => 1, "mediumint" => 3 }.freeze

      def sized(type, sizes, family)
        case type
        when "string"
          sizes.first == 255 && family == :mysql ? {} : { limit: sizes.first }
        when "binary", "bit", "bit_varying" then { limit: sizes.first }
        when "integer", "text" then family == :sqlite ? { limit: sizes.first } : {}
        when "decimal" then { precision: sizes.first, scale: sizes[1] }.compact
        when "datetime", "timestamp", "timestamptz", "time", "interval" then dumped_precision(type, sizes.first, family)
        else {}
        end
      end

      # The precision schema.rb writes (schema_precision, 7.0 to 8.1): a datetime's default 6 goes unsaid, a datetime with
      # none (given: it is nil, not left out) or MySQL's 0 is precision: nil, and MySQL leaves out a time or timestamp's 0.
      def dumped_precision(type, precision, family, given: false)
        return { precision: nil } if type == "datetime" && ((precision.nil? && given) || (precision&.zero? && family == :mysql))
        return {} if precision.nil? || (precision == 6 && %w[datetime timestamp].include?(type)) || (precision.zero? && family == :mysql)

        { precision: precision }
      end

      # SQLite's type map (initialize_type_map, 7.0 to 8.1): the last pattern registered that a type matches names it, an
      # alias by its target, and none gives no type. The dumper names a type written bigint in lowercase one (Column#bigint?).
      SQLITE_TYPES = [
        [ /boolean/i, "boolean" ], [ /char/i, "string" ], [ /binary/i, "binary" ], [ /text/i, "text" ], [ /date/i, "date" ],
        [ /time/i, "time" ], [ /datetime/i, "datetime" ], [ /float/i, "float" ], [ /blob/i, "binary" ], [ /clob/i, "text" ],
        [ /timestamp/i, "datetime" ], [ /numeric/i, "decimal" ], [ /number/i, "decimal" ], [ /double/i, "float" ],
        [ /\Ajson/i, "json" ], [ /decimal/i, "decimal" ], [ /int/i, "integer" ]
      ].reverse.freeze

      def sqlite_type(type)
        return "bigint" if type.match?(/\Abigint\b/)

        SQLITE_TYPES.find { |pattern, _| pattern.match?(type) }&.last
      end

      # MySQL's type map is that one with year and bit last (abstract_mysql_adapter.rb, 7.0 to 8.1); its other additions
      # rename no type the case below leaves, and the dumper writes an enum or set as declared (schema_type).
      MYSQL_TYPES = [ [ /bit/i, "binary" ], [ /year/i, "integer" ], *SQLITE_TYPES ].freeze

      def mysql_type(type)
        return type if type.match?(/\A(?:enum|set)\b/i)

        MYSQL_TYPES.find { |pattern, _| pattern.match?(type) }&.last
      end

      # The type schema.rb names: pg_dump qualifies an extension's type with its
      # schema, MySQL appends unsigned, and a size never changes the name.
      def normalize_sql_type(type, family = nil)
        return sqlite_type(type) if family == :sqlite

        # MySQL's boolean columns are a sized tinyint; bare tinyint is a real 1-byte integer, and SQLite's tinyint(1) one of limit 1.
        return "boolean" if family == :mysql && type.start_with?("tinyint(1)")

        type = type.sub(/\A(?:#{SqlScan::NAME_TEXT})\.(?=[\w"`])/o, "")
        base = type.gsub(/(?<!\s)\s*\([^()]*\)/, "").gsub(/(?<!\s)\s+(?:unsigned|signed|zerofill)\b/i, "").strip

        case base
        when /\A(?:integer|int|int4|smallint|int2|tinyint|mediumint)\z/i then "integer"
        # SQLite's type map reads bigint alone as one.
        when /\Abigint\z/i then "bigint"
        when /\Aint8\z/i then family == :sqlite ? "integer" : "bigint"
        when /\A(?:character varying|varchar|character|char|bpchar)\z/i then "string"
        when /\A(?:text|longtext|mediumtext|tinytext)\z/i then "text"
        when /\A(?:boolean|bool)\z/i then "boolean"
        # SQLite's type map reads a timestamptz as a datetime.
        when /\A(?:timestamp with time zone|timestamptz)\z/i then family == :sqlite ? "datetime" : "timestamptz"
        # MySQL's dumper keeps a timestamp column a timestamp.
        when /\Atimestamp(?: without time zone)?\z/i then family == :mysql ? "timestamp" : "datetime"
        when /\Adatetime\z/i then "datetime"
        when /\Adate\z/i then "date"
        when /\Atime(?: without time zone)?\z/i then "time"
        when /\A(?:numeric|decimal)\z/i then "decimal"
        when /\A(?:float|double|double precision|real|float4|float8)\z/i then "float"
        when /\Ajsonb\z/i then "jsonb"
        when /\Ajson\z/i then "json"
        when /\A(?:bytea|longblob|mediumblob|tinyblob|blob|binary|varbinary)\z/i then "binary"
        # MariaDB has a uuid type, which Rails' MySQL type map does not name.
        when /\Auuid\z/i then "uuid" unless family == :mysql
        when /\A(?:inet|citext|hstore|interval)\z/i then base.downcase
        when /\Aarray\z/i then "array"
        when /\Abit\z/i then family == :mysql ? mysql_type(type) : "bit"
        when /\A(?:bit varying|varbit)\z/i then "bit_varying"
        else family == :mysql ? mysql_type(type) : type
        end
      end
    end
  end
end
