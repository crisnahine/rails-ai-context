# frozen_string_literal: true

require "set"

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

    # Rails' own bookkeeping tables. ar_internal_metadata.key ends in "key": counted,
    # it would refuse every statement whose text holds the word "key".
    BOOKKEEPING_TABLES = %w[ar_internal_metadata schema_migrations].freeze

    # A wildcard in a select list. `count(*)` reads no column, so it is left out.
    WILDCARD = /(?:\b(?:SELECT|DISTINCT|ALL)\b|[,.])\s*\*/i

    # A name that stands before a dot, in any quotes: a schema, a table or an alias.
    DOTTED = /(?:`((?:``|[^`])+)`|"((?:""|[^"])+)"|\[([^\]]+)\]|((?:[\p{Word}$]|[^\x00-\x7F])+))\s*\./

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
        unless relations
          raise Unreadable, "The columns of the #{connection.pool.db_config.name} database could not be read, so its secret " \
            "columns cannot be told and no query runs on it."
        end

        relations = relations.merge(CATALOG_CREDENTIALS) if family.plan_checks?
        new(relations: relations, encrypted: encrypted_from(context), connection: connection, **definitions_from(connection, schemas))
      end
      statement.to_s.strip.empty? ? secrets : secrets.cover(statement)
    end

    # A name or a statement as the databases compare names: case folded. MySQL reads a dotted capital I
    # as i, where Ruby's downcase keeps the dot as a combining mark.
    def self.fold(text)
      text.to_s.downcase.delete("\u0307")
    end

    # Matches the name as a whole identifier, whatever characters it holds and however it is quoted.
    # The gate reads text with its runs of spaces squeezed, so the name's are squeezed too.
    def self.identifier(name)
      spellings = [ name, name.gsub('"', '""'), name.gsub("`", "``") ].uniq.map { |spelling| Regexp.escape(spelling.squeeze(" ")) }
      /(?<!\p{Word})(?:#{spellings.join("|")})(?!\p{Word})/
    end

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
        raise if DatabaseFamily.timed_out?(e) || DatabaseFamily.lost_connection?(e)

        # Named with no definition, so each one is refused as unreadable.
        connection.views.to_h { |view| [ view, nil ] }
      end
      # SQLite stores a definition as written, comments included.
      views = views.transform_values { |definition| definition && SqlGate.comment_free(definition.to_s, family) }
      { views: views, traced_views: family.traced_views(connection, schemas), generated: family.generated_columns(connection, schemas),
        index_tables: family.index_tables(connection, schemas) }
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

        family.relation_columns(source, schemas).reject { |table, _columns| BOOKKEEPING_TABLES.include?(table.to_s.downcase) }
      else
        tables = source&.dig(:schema, :tables)
        return nil unless tables.is_a?(Hash) && tables.any?

        tables.each_with_object({}) do |(table, data), acc|
          next if BOOKKEEPING_TABLES.include?(table.to_s.downcase)
          acc[table.to_s] = Array(data.is_a?(Hash) && data[:columns]).map { |col| col.is_a?(Hash) ? col[:name] : col }.compact
        end
      end
    rescue StandardError => e
      # A read the timeout ended is the call's timeout, so it is no reason to fall back.
      raise if DatabaseFamily.lost_connection?(e) || (e.is_a?(ActiveRecord::StatementInvalid) && DatabaseFamily.timed_out?(e))

      nil
    end

    def self.encrypted_from(context)
      models = context&.dig(:models)
      return [] unless models.is_a?(Hash)

      models.each_value.flat_map { |data| data.is_a?(Hash) ? Array(data[:encrypts]) : [] }
    end
    private_class_method :encrypted_from

    # relations: relation => its column names. generated: relation => { generated column => its expression }.
    # views: view => its definition, nil for one that cannot be read; nil when the database's views are not known.
    # traced_views: the views that are queried whatever their definition names.
    # index_tables: table => [kind, the virtual table it belongs to], as DatabaseFamily::Family#index_tables answers.
    # connection: where the relations of more schemas are read from; with none the rule knows what it was given.
    def initialize(relations: {}, encrypted: [], views: nil, traced_views: [], generated: {}, index_tables: {}, connection: nil,
                   config: RailsAiContext.configuration)
      fold = self.class.method(:fold)
      @redacted = (Array(config.query_redacted_columns) + BUILT_IN_NAMES).to_set(&fold)
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
      learn(relations: relations, views: views, traced_views: traced_views, generated: generated, index_tables: index_tables)
    end

    # Reads the schemas the statement names, and those the view definitions read so far name, into the rule.
    # @raise [Unreadable] when view definitions still name new schemas after ROUNDS reads
    def cover(statement)
      return self unless @connection

      family = DatabaseFamily.of(@connection)
      statement = SqlGate.comment_free(statement, family)
      (ROUNDS + 1).times do |round|
        names = [ statement, *@views.to_h.values.compact ].flat_map { |text| dotted_names(text) }.to_set - @asked
        @asked.merge(names)
        found = family.schemas_named(@connection, names.to_a) - @read
        return self if found.empty?
        if round == ROUNDS
          raise Unreadable, "The statement and the views of the databases it names lead to more databases than rails_query " \
            "follows (#{ROUNDS} rounds), so the secret columns it could read cannot be told and it is not run."
        end

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
      @columns.key?(self.class.fold(relation))
    end

    def secret?(name)
      down = self.class.fold(name)
      return false if down.empty?
      return true if encrypted?(down)
      return false if @allowed.include?(down)

      @generated.key?(down) || @redacted.include?(down) || heuristic?(down) || RailsAiContext::Redaction.secret_name?(down)
    end

    # True for an `encrypts` column and for a generated column that reads one: neither is released by name.
    def encrypted?(name)
      down = self.class.fold(name)
      @encrypted.include?(down) || (@generated.key?(down) && encrypted?(@generated[down]))
    end

    # @return [String, nil] the secret column a generated column's expression reads
    def generated_from(name)
      @generated[self.class.fold(name)]
    end

    # [view, why] for the first refused view the text names, or nil. A view's definition renames a
    # column outside the statement, where no check on the statement reads it.
    def refused_view_in(text)
      down = self.class.fold(text)
      @refused_views.find { |view, _why| names?(down, view) }
    end

    # [table, why] for the first table the text names that is never read, or nil: the file's pages, a shadow
    # table, and a virtual table or its vocabulary when the virtual table holds a secret column.
    def unread_table_in(text)
      down = self.class.fold(text)
      @unread_tables.find { |table, _why| names?(down, table) }
    end

    # The first relation holding a secret column that the statement's text names, or nil.
    def relation_named_in(text)
      down = self.class.fold(text)
      @by_relation.each_key.find { |relation| names?(down, relation) }
    end

    # The first secret name the statement's text names, or nil. Case-insensitive
    # and word-bounded, so a table or alias that merely holds a secret word passes.
    def named_in(text)
      down = self.class.fold(text)
      @named.each { |name, pattern| return name if down.match?(pattern) }
      nil
    end

    # The schema's real secret columns, read by the PostgreSQL plan checks.
    attr_reader :in_schema

    def of_relation(relation)
      @by_relation.fetch(self.class.fold(relation), [])
    end

    def relation_secret?(relation)
      @by_relation.key?(self.class.fold(relation))
    end

    private

    def dotted_names(text)
      text.scan(DOTTED).map { |found| found.compact.first.gsub(/([`"])\1/, '\1') }
    end

    def learn(relations:, views: nil, traced_views: [], generated: {}, index_tables: {})
      fold = self.class.method(:fold)
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
      @refused_views = @views ? refused_views(@views).except(*@traced) : {}
    end

    def flag_secret_columns(columns)
      @by_relation = columns.each_with_object({}) do |(relation, names), acc|
        flagged = names.uniq.select { |c| secret?(c) }
        acc[relation] = flagged unless flagged.empty?
      end
      @in_schema = @by_relation.values.flatten.uniq.freeze
      @named = ((@redacted.to_a - @allowed.to_a) | @encrypted.to_a | @in_schema).map { |c| [ c, self.class.identifier(c) ] }
    end

    # Whether another generated column was found to read a secret column.
    def trace_generated(generated)
      found = false
      generated.each_value do |expressions|
        expressions.each do |column, expression|
          column = self.class.fold(column)
          next if @generated.key?(column)

          source = named_in(expression)
          next if source.nil? || source == column

          @generated[column] = source
          found = true
        end
      end
      found
    end

    # view name => why it is refused, followed through views built on refused views.
    def refused_views(views)
      views = views.to_h { |view, definition| [ self.class.fold(view), self.class.fold(definition) ] }
      refused = views.transform_values { |definition| refusal_of(definition) }.compact
      loop do
        nested = views.filter_map do |view, definition|
          inner = refused.keys.find { |other| names?(definition, other) } unless refused.key?(view)
          [ view, inner ] if inner
        end
        return refused if nested.empty?

        nested.each { |view, inner| refused[view] = "it reads the view `#{inner}`: #{refused[inner]}" }
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
        unread[self.class.fold(table)] = why if why
      end
    end

    def refusal_of(definition)
      if definition.strip.empty?
        "its definition could not be read, and this database holds secret columns" if @in_schema.any?
      elsif (column = named_in(definition))
        "its definition names the secret column `#{column}`"
      elsif (table = @unread_tables.keys.find { |name| names?(definition, name) })
        "its definition reads `#{table}`, which is not read"
      elsif definition.match?(WILDCARD) && (relation = @by_relation.keys.find { |name| names?(definition, name) })
        "its definition has a wildcard and names `#{relation}`, which holds the secret column `#{@by_relation[relation].first}`"
      end
    end

    def names?(down, name)
      down.match?(self.class.identifier(name))
    end

    def heuristic?(down)
      down.end_with?(*HEURISTIC_SUFFIXES) || down.match?(/password|secret|token|nonce/) || down == "iv" || down.end_with?("_iv")
    end
  end
end
