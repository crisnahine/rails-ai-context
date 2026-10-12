# frozen_string_literal: true

require "set"

module RailsAiContext
  # The columns rails_query never returns and whose names a statement may not
  # mention, for one connection's schema. Built once per connection and run.
  class SecretColumns
    # Matched on every adapter whether or not the name is a real column, so the
    # check holds with no connection. An app whose own column merely looks
    # secret exempts it by name through `config.query_allowed_columns`.
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

    # Cached per run and database: one schema read however many checks ask.
    def self.for(connection, context: nil)
      RunCache.fetch([ :secret_columns, database_key(connection) ]) do
        # The context's schema is the primary's, so no other database falls back to it.
        relations = relations_from(connection) || (relations_from(context) if primary?(connection)) || {}
        new(relations: relations, encrypted: encrypted_from(context))
      end
    end

    def self.primary?(connection)
      connection.pool.db_config.name == ActiveRecord::Base.connection_db_config.name
    rescue StandardError
      false
    end
    private_class_method :primary?

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

    # relations: relation name => its column names. encrypted: the columns an
    # `encrypts` declaration covers.
    def initialize(relations: {}, encrypted: [], config: RailsAiContext.configuration)
      @redacted = (Array(config.query_redacted_columns) + BUILT_IN_NAMES).to_set { |c| c.to_s.downcase }
      @allowed = Array(config.query_allowed_columns).to_set { |c| c.to_s.downcase }
      @encrypted = Array(encrypted).to_set { |c| c.to_s.downcase }
      @by_relation = relations.each_with_object({}) do |(relation, columns), acc|
        flagged = Array(columns).map { |c| c.to_s.downcase }.select { |c| secret?(c) }
        acc[relation.to_s.downcase] = flagged.uniq unless flagged.empty?
      end
      @in_schema = @by_relation.values.flatten.uniq.freeze
      @named = ((@redacted.to_a - @allowed.to_a) | @encrypted.to_a | @in_schema).map { |c| [ c, /\b#{Regexp.escape(c)}\b/ ] }
    end

    def secret?(name)
      down = name.to_s.downcase
      return false if down.empty?
      return true if @encrypted.include?(down)
      return false if @allowed.include?(down)

      @redacted.include?(down) || heuristic?(down) || RailsAiContext::Redaction.secret_name?(down)
    end

    def encrypted?(name)
      @encrypted.include?(name.to_s.downcase)
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

    def heuristic?(down)
      down.end_with?(*HEURISTIC_SUFFIXES) || down.match?(/password|secret|token/)
    end
  end
end
