# frozen_string_literal: true

require "set"
require "strscan"

module RailsAiContext
  # The columns rails_query never returns and whose names a statement may not
  # mention, for one connection's schema. Built once per connection and run.
  class SecretColumns
    # The schema of a database could not be read, so its secret columns cannot be told.
    class Unreadable < RailsAiContext::Error; end

    DEFAULT_REDACTED_COLUMNS = %w[
      password_digest encrypted_password password_hash
      reset_password_token confirmation_token unlock_token
      otp_secret session_data secret_key
      api_key api_secret access_token refresh_token jti
    ].freeze

    # PostgreSQL catalog columns that hold a stored credential: a role's password hash, and the settings
    # stored for a role or a database. pg_roles, pg_user and pg_shadow are views over them.
    CATALOG_CREDENTIALS = { "pg_authid" => %w[rolpassword], "pg_db_role_setting" => %w[setconfig] }.freeze

    # Matched whether or not the name is a real column, so the check holds with no
    # connection. `config.query_allowed_columns` releases a name that only looks secret.
    BUILT_IN_NAMES = (DEFAULT_REDACTED_COLUMNS + %w[
      password_reset_token remember_token secret private_key authentication_string
    ] + CATALOG_CREDENTIALS.values.flatten).freeze

    HEURISTIC_SUFFIXES = %w[password secret token key digest hash].freeze

    # A wildcard in a select list. `count(*)` reads no column, so it is left out.
    WILDCARD = /(?:\b(?:SELECT|DISTINCT|ALL)\b|[,.])\s*\*/i

    # A name before a dot, matched in reversed text from the dot backward: bare, or in backticks or double quotes
    # with the quote doubled inside. A schema name on MySQL, MariaDB or PostgreSQL is 64 characters at most.
    NAME_END = /\.(?=\s*(?:[\p{Word}$`"]|[^\x00-\x7F]))/
    BARE_NAME = /(?:[\p{Word}$]|[^\x00-\x7F])+/
    QUOTED_NAME = /`((?>(?:``|[^`]){1,64}))`(?!`)|"((?>(?:""|[^"]){1,64}))"(?!")/

    # How many times the schemas a statement and the view definitions name are followed into more view definitions.
    ROUNDS = 3

    # Cached per run and database: one schema read however many checks ask. With a statement, the schemas it
    # names are read too, so the rule knows every relation the statement can reach.
    def self.for(connection, context: nil, statement: nil)
      secrets = RunCache.fetch([ :secret_columns, database_key(connection) ]) do
        family = DatabaseFamily.of(connection)
        schemas = family.known? ? family.unqualified_schemas(connection) : []
        # The context's schema is the primary's, so no other database falls back to it.
        relations = relations_from(connection, schemas) || (relations_from(context) if primary?(connection))
        raise unreadable(connection) unless relations

        relations = relations.merge(CATALOG_CREDENTIALS) if family.plan_checks?
        new(relations: relations, encrypted: encrypted_from(context), connection: connection, family: family,
            **definitions_from(connection, schemas))
      end
      statement.to_s.strip.empty? ? secrets : secrets.cover(statement)
    end

    # A name or a statement as the databases compare names: case folded (ASCII alone with `ascii:`, as SQLite folds),
    # a dotted capital I read as i as MySQL reads it, and runs of spaces squeezed, so text squeezed or not matches.
    def self.fold(text, ascii: false)
      ascii ? text.to_s.downcase(:ascii).squeeze(" ") : text.to_s.downcase.delete("\u0307").squeeze(" ")
    end

    # Matches the name as a whole identifier in folded text, whatever characters it holds and however it is quoted.
    def self.identifier(name, ascii: false)
      name = fold(name, ascii: ascii)
      spellings = [ name, name.gsub('"', '""'), name.gsub("`", "``"), name.gsub("'", "''") ].uniq.map { |spelling| Regexp.escape(spelling) }
      /(?<!\p{Word})(?:#{spellings.join("|")})(?!\p{Word})/
    end

    def self.unreadable(connection)
      Unreadable.new("The columns of the #{connection.pool.db_config.name} database could not be read, so its secret " \
        "columns cannot be told and no query runs on it.")
    end
    private_class_method :unreadable

    # An error that is the call's own answer, so no other read stands in for the one that raised it.
    def self.answered?(error)
      DatabaseFamily.lost_connection?(error) ||
        (error.is_a?(ActiveRecord::StatementInvalid) && (DatabaseFamily.timed_out?(error) || DatabaseFamily.busy?(error)))
    end
    private_class_method :answered?

    def self.primary?(connection)
      connection.pool.db_config.name == ActiveRecord::Base.connection_db_config.name
    end
    private_class_method :primary?

    # What the database stores outside any statement: view definitions and generated column expressions.
    def self.definitions_from(connection, schemas)
      family = DatabaseFamily.of(connection)
      return {} unless family.known?

      views = begin
        family.view_definitions(connection, schemas)
      rescue ActiveRecord::StatementInvalid => e
        raise if answered?(e)

        # Named with no definition, so each one is refused as unreadable.
        connection.views.to_h { |view| [ view, nil ] }
      end
      # SQLite stores a definition as written, comments included.
      views = views.transform_values { |definition| definition && SqlGate.comment_free(definition.to_s, family) }
      { views: views, traced_views: family.traced_views(connection, schemas), generated: family.generated_columns(connection, schemas),
        index_tables: family.index_tables(connection, schemas) }
    rescue ActiveRecord::StatementInvalid => e
      raise if answered?(e)

      raise unreadable(connection)
    end

    def self.database_key(connection)
      db_config = connection.pool.db_config
      [ db_config.env_name, db_config.name ]
    rescue StandardError
      connection.object_id
    end
    private_class_method :database_key

    # relation name => column names, from a live connection or a cached
    # context's schema; nil when neither can be read.
    def self.relations_from(source, schemas = [])
      if source.respond_to?(:adapter_name)
        family = DatabaseFamily.of(source)
        return nil unless family.known?

        family.relation_columns(source, schemas).reject { |table, _columns| Introspectors::SchemaConventions.bookkeeping_table?(table.to_s.downcase) }
      else
        tables = source&.dig(:schema, :tables)
        return nil unless tables.is_a?(Hash) && tables.any?

        tables.each_with_object({}) do |(table, data), acc|
          next if Introspectors::SchemaConventions.bookkeeping_table?(table.to_s.downcase)
          acc[table.to_s] = Array(data.is_a?(Hash) && data[:columns]).map { |col| col.is_a?(Hash) ? col[:name] : col }.compact
        end
      end
    rescue StandardError => e
      # A read the timeout ended is the call's timeout, so it is no reason to fall back.
      raise if answered?(e)

      nil
    end

    def self.encrypted_from(context)
      models = context&.dig(:models)
      return [] unless models.is_a?(Hash)

      models.each_value.flat_map { |data| data.is_a?(Hash) ? Array(data[:encrypts]) : [] }
    end
    private_class_method :encrypted_from

    # Each argument is what the DatabaseFamily::Family read of the same name answers. views is nil when the
    # database's views are not known. connection: where more schemas are read from; with none the rule keeps what it was given.
    def initialize(relations: {}, encrypted: [], views: nil, traced_views: [], generated: {}, index_tables: {}, connection: nil,
                   family: nil, config: RailsAiContext.configuration)
      @ascii = family&.sqlite? || false
      fold = method(:fold)
      @configured = Array(config.query_redacted_columns)
      @redacted = (@configured + BUILT_IN_NAMES).to_set(&fold)
      @allowed = Array(config.query_allowed_columns).to_set(&fold)
      @encrypted = Array(encrypted).to_set(&fold)
      @connection = connection
      @columns = Hash.new { |hash, relation| hash[relation] = [] }
      @views = views && {}
      @traced = []
      @expressions = {}
      @index_tables = {}
      @asked = Set.new
      @read = []
      @spelled = {}
      learn(relations: relations, views: views, traced_views: traced_views, generated: generated, index_tables: index_tables)
    end

    # Reads what the statement reaches into the rule.
    # @raise [Unreadable] as #reach does
    def cover(statement)
      return self unless @connection

      reach(SqlGate.comment_free(statement, DatabaseFamily.of(@connection)))
    end

    # Reads the schemas given and those the text names, then follows the views the text names ROUNDS definitions deep.
    # @raise [Unreadable] when a view the text names leads deeper, or a schema's columns cannot be read
    def reach(text, schemas = [])
      return self unless @connection

      family = DatabaseFamily.of(@connection)
      read_schemas(schemas)
      (ROUNDS + 1).times do |round|
        followed = views_reached(text)
        names = [ text, *@views.to_h.values_at(*followed.keys).compact ].flat_map { |read| dotted_names(read) }.to_set - @asked
        found = family.schemas_named(@connection, names.to_a) - @read
        raise too_deep(found, followed, family) if found.any? && round == ROUNDS

        @asked.merge(names)
        return self if found.empty?

        read_schemas(found)
      end
      self
    end

    # Reads the relations, views and generated columns of more schemas into the rule.
    # @raise [Unreadable] when a schema's columns cannot be read
    def read_schemas(schemas)
      schemas = schemas.compact.uniq - @read
      return self if schemas.empty? || @connection.nil?

      relations = self.class.relations_from(@connection, schemas)
      unless relations
        raise Unreadable, "The columns of #{schemas.map { |name| "`#{name}`" }.join(", ")} could not be read, so the secret columns " \
          "there cannot be told and no query that reads it runs."
      end
      @read.concat(schemas)
      learn(relations: relations, **self.class.definitions_from(@connection, schemas))
      self
    end

    # Whether the relation's columns were read. A PostgreSQL relation is asked for as `schema.relation`.
    def knows?(relation)
      @columns.key?(fold(relation))
    end

    def secret?(name)
      down = fold(name)
      return false if down.empty?
      return true if encrypted?(down)
      return false if @allowed.include?(down)

      # What a name means is read with every letter folded, whatever the database folds.
      meaning = self.class.fold(name)
      @generated.key?(down) || @redacted.include?(down) || @secret_meanings.include?(meaning) || heuristic?(meaning) ||
        RailsAiContext::Redaction.secret_name?(meaning)
    end

    # True for an `encrypts` column and for a generated column that reads one: neither is released by name.
    # Generated columns of one name on two tables are one name here, encrypted when either reads such a column.
    def encrypted?(name, through = [])
      down = fold(name)
      return true if @encrypted.include?(down)

      !through.include?(down) && @generated.fetch(down, []).any? { |source| encrypted?(source, through + [ down ]) }
    end

    # @return [String, nil] a secret column a generated column's expression reads, an `encrypts` one first
    def generated_from(name)
      sources = @generated.fetch(fold(name), [])
      sources.find { |source| encrypted?(source) } || sources.first
    end

    # [view, why] for the first refused view the text names, or nil. A view's definition renames a
    # column outside the statement, where no check on the statement reads it.
    def refused_view_in(text)
      down = fold(text)
      view, why = @refused_views.find { |name, _why| names?(down, name) }
      [ spelled(view), why ] if view
    end

    # Why the view at exactly this place is refused, or nil. The plan names a relation as `schema.relation`, so a table
    # is not taken for a view of its name in another schema; a view with no definition read is told by its bare name.
    def placed_view_refusal(relation, name)
      placed, bare = fold(relation), fold(name)
      return @refused_views[placed] if @views&.key?(placed)

      @refused_views[bare] if @views&.key?(bare) && @views[bare].nil?
    end

    # Whether the relation is a view whose rows the plan does not trace to their table columns.
    def stored_view?(relation)
      placed = fold(relation)
      !@views.nil? && @views.key?(placed) && !@traced.include?(placed)
    end

    # [table, why] for the first table the text names that is never read, or nil: the file's pages, a shadow
    # table, and a virtual table or its vocabulary when the virtual table holds a secret column.
    def unread_table_in(text)
      down = fold(text)
      table, why = @unread_tables.find { |name, _why| names?(down, name) }
      [ spelled(table), why ] if table
    end

    # The first relation holding a secret column that the statement's text names, or nil.
    def relation_named_in(text)
      down = fold(text)
      relation = @by_relation.each_key.find { |name| names?(down, name) }
      relation && spelled(relation)
    end

    # The first secret name the statement's text names, or nil. Case-insensitive
    # and word-bounded, so a table or alias that merely holds a secret word passes.
    def named_in(text)
      down = fold(text)
      @named.each { |name, pattern| return name if down.match?(pattern) }
      nil
    end

    # view => its definition, for each view the text names and each one their definitions name.
    def view_definitions_in(text)
      views_reached(text).keys.filter_map { |view| [ spelled(view), @views[view] ] if @views[view] }.to_h
    end

    # The schema's real secret columns, read by the PostgreSQL plan checks.
    attr_reader :in_schema

    def of_relation(relation)
      @by_relation.fetch(fold(relation), [])
    end

    def relation_secret?(relation)
      @by_relation.key?(fold(relation))
    end

    private

    # Every name that stands before a dot, read backward from the dot, so a quote character inside a string before it
    # changes nothing. A name in brackets is not read: SQLite reads every schema, and the gate refuses a bracket on MySQL.
    def dotted_names(text)
      scanner = StringScanner.new(text.reverse)
      names = []
      while scanner.skip_until(NAME_END)
        scanner.skip(/\s+/)
        if (bare = scanner.check(BARE_NAME)) then names << bare.reverse
        elsif scanner.check(QUOTED_NAME) then names << (scanner[1]&.gsub("``", "`") || scanner[2].gsub('""', '"')).reverse
        end
      end
      names
    end

    # view => the view the text names that leads to it, for each view the text names and each one their
    # definitions name. A view the plan reads through is no start: its relations are in the plan.
    def views_reached(text)
      down = fold(text)
      reached = @views.to_h.keys.select { |view| !@traced.include?(view) && names?(down, view) }.to_h { |view| [ view, view ] }
      waiting = reached.keys
      while (view = waiting.shift)
        definition = fold(@views[view])
        (@views.keys - reached.keys).each do |other|
          next unless names?(definition, other)

          reached[other] = reached[view]
          waiting << other
        end
      end
      reached
    end

    def too_deep(found, followed, family)
      found = found.map { |schema| fold(schema) }
      view = followed.find { |name, _start| (dotted_names(fold(@views[name])) & found).any? }&.last
      Unreadable.new("The view `#{spelled(view)}` leads through more #{family.postgresql? ? "schemas" : "databases"} than rails_query follows, " \
        "so the secret columns it could read cannot be told and no statement that names it runs.")
    end

    # The name as the database spells it, for a sentence: the rule itself holds every name folded.
    def spelled(name)
      @spelled.fetch(name, name)
    end

    def learn(relations:, views: nil, traced_views: [], generated: {}, index_tables: {})
      fold = method(:fold)
      [ relations, views, index_tables ].each { |named| named&.each_key { |name| @spelled[fold.call(name)] ||= name.to_s } }
      relations.each { |relation, names| @columns[fold.call(relation)].concat(Array(names).map(&fold)) }
      generated.each do |relation, expressions|
        @columns[fold.call(relation)].concat(expressions.keys.map(&fold))
        (@expressions[relation] ||= {}).merge!(expressions) { |_column, known, read| "#{known} #{read}" }
      end
      views&.each do |view, definition|
        view = fold.call(view)
        @views[view] = @views.key?(view) ? [ @views[view], definition ].then { |both| both.all? ? both.join("\n") : nil } : definition
      end
      @traced.concat(traced_views.map(&fold))
      @index_tables.merge!(index_tables)

      @generated = {}
      flag_secret_columns(@columns)
      # A generated column can read another one, so this repeats until it finds no more.
      flag_secret_columns(@columns) while trace_generated(@expressions)
      @unread_tables = unread_tables(@index_tables)
      # A virtual table can be built on a refused view, and a view on that virtual table.
      loop do
        @refused_views = @views ? refused_views(@views).except(*@traced) : {}
        built = built_on_unread(@index_tables)
        break if built.empty?

        @unread_tables.merge!(built)
      end
    end

    def flag_secret_columns(columns)
      # A configured name that no column spells as the database folds it still holds the columns it folds to.
      known = columns.values.flatten.to_set
      @secret_meanings = (BUILT_IN_NAMES + @configured.reject { |name| known.include?(fold(name)) }).to_set { |name| self.class.fold(name) }
      @by_relation = columns.each_with_object({}) do |(relation, names), acc|
        flagged = names.uniq.select { |c| secret?(c) }
        acc[relation] = flagged unless flagged.empty?
      end
      @in_schema = @by_relation.values.flatten.uniq.freeze
      @named = ((@redacted.to_a - @allowed.to_a) | @encrypted.to_a | @in_schema).map { |c| [ c, identifier(c) ] }
    end

    # Whether another secret column was found that a generated column reads. Every source of a name is kept.
    def trace_generated(generated)
      found = false
      generated.each_value do |expressions|
        expressions.each do |column, expression|
          column = fold(column)
          down = fold(expression)
          sources = @named.filter_map { |name, pattern| name if name != column && down.match?(pattern) } - @generated.fetch(column, [])
          next if sources.empty?

          (@generated[column] ||= []).concat(sources)
          found = true
        end
      end
      found
    end

    # view name => why it is refused, followed through views built on refused views.
    def refused_views(views)
      views = views.to_h { |view, definition| [ fold(view), fold(definition) ] }
      refused = views.transform_values { |definition| refusal_of(definition) }.compact
      loop do
        nested = views.filter_map do |view, definition|
          inner = refused.keys.find { |other| names?(definition, other) } unless refused.key?(view)
          [ view, inner ] if inner
        end
        return refused if nested.empty?

        nested.each { |view, inner| refused[view] = "it reads the view `#{spelled(inner)}`: #{refused[inner]}" }
      end
    end

    def unread_tables(index_tables)
      index_tables.each_with_object({}) do |(table, (kind, owner)), unread|
        secret = of_relation(owner).first
        why = case kind
        when :pages then "it returns the database file's raw pages, and every stored value is in them"
        when :shadow
          "it is a shadow table, where SQLite keeps what the virtual table `#{owner}` stores under other column names" \
            "#{". Query `#{owner}`" unless secret}"
        when :vocabulary
          "it lists the words of the full-text table `#{owner}`, which holds the secret column `#{secret}`" if secret
        when :virtual
          if secret
            "it is a virtual table that holds the secret column `#{secret}`, and a search or a function over a virtual " \
              "table reads a column by its position, with no name written"
          end
        end
        unread[fold(table)] = why if why
      end
    end

    # A name or a string in any of the four quotings SQLite reads.
    SQLITE_QUOTED = /"(?:""|[^"])*"|'(?:''|[^'])*'|`(?:``|[^`])*`|\[[^\]]*\]/

    # One argument of a virtual table's module: up to the next comma outside quotes, brackets and parentheses.
    MODULE_ARGUMENT = /(?:#{SQLITE_QUOTED}|\([^()]*\)|[^,])+/

    # virtual table => why it is not read, for each one built on a refused view or on a table that is not read:
    # its rows, or its words, are theirs.
    def built_on_unread(index_tables)
      index_tables.each_with_object({}) do |(table, (kind, owner, definition)), built|
        table = fold(table)
        next if definition.nil? || @unread_tables.key?(table)

        down = fold("#{owner if kind == :vocabulary} #{relation_words(table, definition)}")
        view, why = @refused_views.find { |name, _why| name != table && names?(down, name) }
        other = @unread_tables.keys.find { |name| name != table && names?(down, name) } unless view
        built[table] = "its definition names the view `#{spelled(view)}`, which is not queried: #{why}" if view
        built[table] = "its definition names `#{spelled(other)}`, which is not read" if other
      end
    end

    # The name an argument of a virtual table's module opens with: one quoted name whole, or its first word.
    LEADING_NAME = /\A\s*(?:#{SQLITE_QUOTED}|[^\s"'`\[]+)/

    # What a virtual table's definition can name a relation with: its module, and every argument but the columns a
    # full-text table declares (a column named like a view is no view). An argument with `=` is an option, kept whole.
    def relation_words(table, definition)
      mod, arguments = definition.match(/\A\s*USING\s+([^\s(]+)\s*(?:\((.*)\))?\s*\z/mi)&.captures
      return definition unless mod

      mod_name = mod.delete(%q("'`[]))
      columns = mod_name.match?(/\Afts[345]\z/i) ? @columns[table] : []
      named = arguments.to_s.scan(MODULE_ARGUMENT).reject do |argument|
        !argument.include?("=") && columns.include?(fold(argument[LEADING_NAME].to_s.delete(%q("'`[])).strip))
      end
      # A vocabulary's last argument is its type (row, col or instance), which SQLite reads as no relation.
      named.pop if mod_name.casecmp?("fts5vocab") && named.size > 1
      [ mod, *named ].join(" ")
    end

    def refusal_of(definition)
      if definition.strip.empty?
        "its definition could not be read, and this database holds secret columns" if @in_schema.any?
      elsif (column = named_in(definition))
        "its definition names the secret column `#{column}`"
      elsif (table = @unread_tables.keys.find { |name| names?(definition, name) })
        "its definition names `#{spelled(table)}`, which is not read"
      elsif definition.match?(WILDCARD) && (relation = @by_relation.keys.find { |name| names?(definition, name) })
        "its definition has a wildcard and names `#{spelled(relation)}`, which holds the secret column `#{@by_relation[relation].first}`"
      end
    end

    def names?(down, name)
      down.match?(identifier(name))
    end

    def fold(text)
      self.class.fold(text, ascii: @ascii)
    end

    def identifier(name)
      self.class.identifier(name, ascii: @ascii)
    end

    def heuristic?(down)
      down.end_with?(*HEURISTIC_SUFFIXES) || down.match?(/password|secret|token|nonce|recoverycode|backupcode/) || down == "iv" || down.end_with?("_iv")
    end
  end
end
