# frozen_string_literal: true

module RailsAiContext
  # The kind of engine a database is: PostgreSQL, MySQL or SQLite, else no family.
  # Claimed by name only, never by class ancestry (ADR-0008).
  module DatabaseFamily
    Family = Struct.new(:key, :name) do
      def known?
        key != :unknown
      end

      def implicit_pk_type
        key == :sqlite ? "integer" : "bigint"
      end
    end

    POSTGRESQL = Family.new(:postgresql, "PostgreSQL").freeze
    MYSQL = Family.new(:mysql, "MySQL").freeze
    SQLITE = Family.new(:sqlite, "SQLite").freeze

    # Live adapter_name values, database.yml adapters, URL schemes, display labels and dump dialects, downcased.
    NAMES = {
      "postgresql" => POSTGRESQL, "postgis" => POSTGRESQL, "postgres" => POSTGRESQL,
      "mysql2" => MYSQL, "trilogy" => MYSQL, "mysql" => MYSQL, "mariadb" => MYSQL,
      "sqlite3" => SQLITE, "sqlite" => SQLITE
    }.freeze

    DEFAULT_SUFFIX = " by database.yml default"

    module_function

    # @param source [#adapter_name, #adapter, String, Symbol, nil]
    # @return [Family] never raises; no family carries the raw name
    def of(source)
      raw = raw_name(source)
      NAMES.fetch(raw.downcase.delete_suffix(DEFAULT_SUFFIX)) { Family.new(:unknown, raw.empty? ? "unknown" : raw).freeze }
    end

    def raw_name(source)
      source = source.adapter_name if source.respond_to?(:adapter_name)
      source = source.adapter if source.respond_to?(:adapter)
      source.is_a?(String) || source.is_a?(Symbol) ? source.to_s : ""
    rescue StandardError
      ""
    end
  end
end
