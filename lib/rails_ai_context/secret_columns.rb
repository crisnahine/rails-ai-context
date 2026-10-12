# frozen_string_literal: true

require "set"

module RailsAiContext
  # The columns rails_query never returns and whose names a statement may not
  # mention, for one connection's schema. Built once per connection and run.
  class SecretColumns
    # Matched whether or not the name is a real column, so the check holds with no
    # connection. `config.query_allowed_columns` releases a name that only looks secret.
    BUILT_IN_NAMES = %w[
      password_digest password_hash encrypted_password
      password_reset_token confirmation_token unlock_token
      remember_token reset_password_token api_key api_secret
      access_token refresh_token jti otp_secret session_data
      secret_key secret private_key
    ].freeze

    DEFAULT_REDACTED_COLUMNS = %w[
      password_digest encrypted_password password_hash
      reset_password_token confirmation_token unlock_token
      otp_secret session_data secret_key
      api_key api_secret access_token refresh_token jti
    ].freeze

    HEURISTIC_SUFFIXES = %w[password secret token key digest hash].freeze

    # Rails' own bookkeeping tables. ar_internal_metadata.key ends in "key", and
    # counting it refused every statement whose text held the word "key".
    BOOKKEEPING_TABLES = %w[ar_internal_metadata schema_migrations].freeze

    # A wildcard in a select list. `count(*)` reads no column, so it is left out.
    WILDCARD = /(?:\b(?:SELECT|DISTINCT|ALL)\b|[,.])\s*\*/i

    # Cached per run and database: one schema read however many checks ask.
    def self.for(connection, context: nil)
      RunCache.fetch([ :secret_columns, database_key(connection) ]) do
        # The context's schema is the primary's, so no other database falls back to it.
        relations = relations_from(connection) || (relations_from(context) if primary?(connection)) || {}
        new(relations: relations, encrypted: encrypted_from(context), **definitions_from(connection))
      end
    end

    def self.primary?(connection)
      connection.pool.db_config.name == ActiveRecord::Base.connection_db_config.name
    end
    private_class_method :primary?

    # What the database stores outside any statement: view definitions and generated column expressions.
    def self.definitions_from(connection)
      family = DatabaseFamily.of(connection)
      return {} unless family.known?

      views = begin
        family.view_definitions(connection)
      rescue ActiveRecord::StatementInvalid
        # Named with no definition, so each one is refused as unreadable.
        connection.views.to_h { |view| [ view, nil ] }
      end
      { views: views, generated: family.generated_columns(connection) }
    end
    private_class_method :definitions_from

    def self.database_key(connection)
      db_config = connection.pool.db_config
      [ db_config.env_name, db_config.name ]
    rescue StandardError
      connection.object_id
    end
    private_class_method :database_key

    # relation name => column names, from a live connection or a cached
    # context's schema; nil when neither can be read.
    def self.relations_from(source)
      if source.respond_to?(:tables)
        source.tables.each_with_object({}) do |table, acc|
          next if BOOKKEEPING_TABLES.include?(table.to_s.downcase)
          acc[table.to_s] = source.columns(table).map(&:name)
        end
      else
        tables = source&.dig(:schema, :tables)
        return nil unless tables.is_a?(Hash)

        tables.each_with_object({}) do |(table, data), acc|
          next if BOOKKEEPING_TABLES.include?(table.to_s.downcase)
          acc[table.to_s] = Array(data.is_a?(Hash) && data[:columns]).map { |col| col.is_a?(Hash) ? col[:name] : col }.compact
        end
      end
    rescue StandardError
      nil
    end
    private_class_method :relations_from

    def self.encrypted_from(context)
      models = context&.dig(:models)
      return [] unless models.is_a?(Hash)

      models.each_value.flat_map { |data| data.is_a?(Hash) ? Array(data[:encrypts]) : [] }
    end
    private_class_method :encrypted_from

    # relations: relation name => its column names. encrypted: the columns an `encrypts` declaration covers.
    # views: view name => its definition, nil where the family traces a result column to its table column.
    # generated: relation name => { generated column => its expression }.
    def initialize(relations: {}, encrypted: [], views: nil, generated: {}, config: RailsAiContext.configuration)
      @redacted = (Array(config.query_redacted_columns) + BUILT_IN_NAMES).to_set { |c| c.to_s.downcase }
      @allowed = Array(config.query_allowed_columns).to_set { |c| c.to_s.downcase }
      @encrypted = Array(encrypted).to_set { |c| c.to_s.downcase }
      @generated = {}
      columns = Hash.new { |hash, relation| hash[relation] = [] }
      relations.each { |relation, names| columns[relation.to_s.downcase].concat(Array(names).map { |c| c.to_s.downcase }) }
      generated.each { |relation, expressions| columns[relation.to_s.downcase].concat(expressions.keys.map { |c| c.to_s.downcase }) }

      index(columns)
      # A generated column can read another one, so this repeats until it finds no more.
      index(columns) while derive(generated)
      @refused_views = views ? refuse(views) : {}
    end

    def secret?(name)
      down = name.to_s.downcase
      return false if down.empty?
      return true if encrypted?(down)
      return false if @allowed.include?(down)

      @generated.key?(down) || @redacted.include?(down) || heuristic?(down) || RailsAiContext::Redaction.secret_name?(down)
    end

    # True for an `encrypts` column and for a generated column that reads one: neither is released by name.
    def encrypted?(name)
      down = name.to_s.downcase
      @encrypted.include?(down) || (@generated.key?(down) && encrypted?(@generated[down]))
    end

    # @return [String, nil] the secret column a generated column's expression reads
    def generated_from(name)
      @generated[name.to_s.downcase]
    end

    # The first view the text names that this database cannot redact, with the reason, or nil.
    # A view's definition renames a column outside the statement, where no check on the statement reads it.
    # @return [Array(String, String), nil]
    def refused_view_in(text)
      down = text.to_s.downcase
      @refused_views.find { |view, _why| names?(down, view) }
    end

    # The first secret name the statement's text names, or nil. Case-insensitive
    # and word-bounded, so a table or alias that merely holds a secret word passes.
    def named_in(text)
      down = text.to_s.downcase
      @named.each { |name, pattern| return name if down.match?(pattern) }
      nil
    end

    # The schema's real secret columns, read by the PostgreSQL plan checks.
    attr_reader :in_schema

    def of_relation(relation)
      @by_relation.fetch(relation.to_s.downcase, [])
    end

    def relation_secret?(relation)
      @by_relation.key?(relation.to_s.downcase)
    end

    private

    def index(columns)
      @by_relation = columns.each_with_object({}) do |(relation, names), acc|
        flagged = names.uniq.select { |c| secret?(c) }
        acc[relation] = flagged unless flagged.empty?
      end
      @in_schema = @by_relation.values.flatten.uniq.freeze
      @named = ((@redacted.to_a - @allowed.to_a) | @encrypted.to_a | @in_schema).map { |c| [ c, /\b#{Regexp.escape(c)}\b/ ] }
    end

    # Whether another generated column was found to read a secret column.
    def derive(generated)
      found = false
      generated.each_value do |expressions|
        expressions.each do |column, expression|
          column = column.to_s.downcase
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
    def refuse(views)
      views = views.to_h { |view, definition| [ view.to_s.downcase, definition.to_s.downcase ] }
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

    def refusal_of(definition)
      if definition.strip.empty?
        "its definition could not be read, and this database holds sensitive columns" if @in_schema.any?
      elsif (column = named_in(definition))
        "its definition names the sensitive column `#{column}`"
      elsif definition.match?(WILDCARD) && (relation = @by_relation.keys.find { |name| names?(definition, name) })
        "its definition reads every column of `#{relation}`, which holds the sensitive column `#{@by_relation[relation].first}`"
      end
    end

    def names?(down, word)
      down.match?(/\b#{Regexp.escape(word)}\b/)
    end

    def heuristic?(down)
      down.end_with?(*HEURISTIC_SUFFIXES) || down.match?(/password|secret|token/)
    end
  end
end
