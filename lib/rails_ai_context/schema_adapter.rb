# frozen_string_literal: true

module RailsAiContext
  # One answer to "which database is this app on", for every surface that asks.
  #
  # `SchemaIntrospector` writes `static_parse` when it read `db/schema.rb`
  # instead of the connection. That is an internal detail: printed raw it names
  # a database that does not exist. Four call sites each grew their own
  # substitute and gave three different answers for one app - the generated
  # CLAUDE.md said PostgreSQL, `rails_get_schema` said unknown, `rails ai:inspect`
  # said static_parse. This is the seam they share.
  module SchemaAdapter
    # Values that mean "no adapter was observed", not "the adapter is X".
    PLACEHOLDERS = %w[static_parse unknown].freeze

    # Also the marker that a label names several: the label is written back into the
    # payload, so a surface reading it back checks for this rather than a flag.
    CANDIDATE_JOIN = " or "

    # Gemfile display names, only as the last resort.
    GEM_ADAPTERS = {
      "pg" => "PostgreSQL",
      "mysql2" => "MySQL",
      "trilogy" => "MySQL",
      "sqlite3" => "SQLite"
    }.freeze

    # Column types only one database has, as schema.rb and migrations write
    # them. A table with jsonb columns is not on MySQL or SQLite.
    POSTGRES_ONLY_TYPES = %w[jsonb hstore inet cidr citext tsvector ltree macaddr interval].freeze
    MYSQL_ONLY_TYPES = %w[tinytext mediumtext longtext tinyblob mediumblob longblob].freeze

    # structure.sql dialects as SchemaIntrospector records them, plus adapter names that
    # mean one of them (activerecord-postgis-adapter registers `postgis`).
    DIALECTS = {
      "postgresql" => "PostgreSQL",
      "postgis" => "PostgreSQL",
      "mysql" => "MySQL",
      "sqlite" => "SQLite"
    }.freeze

    DISPLAY_ORDER = %w[PostgreSQL MySQL SQLite].freeze

    module_function

    # @param context [Hash] a full introspection context
    # @return [String] the adapter to show, never an internal placeholder
    def label(context)
      context = {} unless context.is_a?(Hash)
      schema = context[:schema]
      observed = schema.is_a?(Hash) ? schema[:adapter] : nil
      return display(observed) unless placeholder?(observed)

      # Best first: the app's own database config, which needs no connection.
      # Then what the schema proves, then the example database files (often SQLite for
      # convenience), and last the Gemfile, which is a guess.
      from_configurations(context) || from_dialect(schema) || from_column_types(schema) ||
        from_examples(context) || from_gems(context) || "unknown"
    end

    # A connection's adapter_name as the other surfaces name it (PostGIS is PostgreSQL).
    def display(adapter_name)
      DIALECTS.fetch(adapter_name.to_s.downcase, adapter_name)
    end

    def label_with_reason(context)
      shown = label(context)
      undecided?(shown) ? "#{shown}, #{undecided_reason(context, shown)}" : shown
    end

    # Names only files the app has: an app may commit no database.yml, just one example
    # per database it supports.
    def undecided_reason(context, shown)
      context = {} unless context.is_a?(Hash)
      return "its database.yml examples name each" if shown == from_examples(context)

      multi = context[:multi_database]
      configured = Tools::SectionFetch.usable?(multi) && Array(multi[:databases]).any?
      configured ? "database.yml does not say which" : "the app does not say which"
    end

    def undecided?(adapter)
      adapter.to_s.include?(CANDIDATE_JOIN)
    end

    def placeholder?(adapter)
      adapter.nil? || PLACEHOLDERS.include?(adapter.to_s)
    end

    def from_configurations(context)
      multi = context[:multi_database]
      return nil unless Tools::SectionFetch.usable?(multi)

      primary = Array(multi[:databases]).find { |db| db[:name].to_s == "primary" } ||
                Array(multi[:databases]).first
      database_label(primary)
    end

    # A secondary database's adapter: its database.yml entry, else the dialect
    # its structure.sql is in. nil when neither says; schema.rb does not.
    def secondary_label(context, name, schema)
      multi = context.is_a?(Hash) ? context[:multi_database] : nil
      databases = Tools::SectionFetch.usable?(multi) ? Array(multi[:databases]) : []
      database_label(databases.find { |db| db.is_a?(Hash) && db[:name].to_s == name.to_s }) || from_dialect(schema)
    end

    # These are ActiveRecord adapter names (`postgresql`), not gem names; the two
    # overlap only at sqlite3/mysql2/trilogy.
    #
    # @return [String, nil] nil when the record says nothing about the adapter
    def database_label(database)
      return nil unless database.is_a?(Hash)

      adapter = database[:adapter]
      return nil if placeholder?(adapter)

      name = DIALECTS[adapter.to_s] || GEM_ADAPTERS[adapter.to_s] || adapter
      database[:adapter_default] ? "#{name} by database.yml default" : name
    end

    def from_examples(context)
      multi = context[:multi_database]
      return nil unless Tools::SectionFetch.usable?(multi)

      candidates(Array(multi[:example_adapters]).map { |name| DIALECTS[name.to_s] || GEM_ADAPTERS[name.to_s] || name.to_s })
    end

    def from_column_types(schema)
      return nil unless schema.is_a?(Hash) && schema[:tables].is_a?(Hash)

      columns = schema[:tables].values.flat_map { |table| table.is_a?(Hash) ? Array(table[:columns]) : [] }
      postgres = columns.any? { |c| c[:array] || POSTGRES_ONLY_TYPES.include?(c[:type].to_s) }
      mysql = columns.any? { |c| MYSQL_ONLY_TYPES.include?(c[:type].to_s) }
      return nil if postgres == mysql

      postgres ? "PostgreSQL" : "MySQL"
    end

    def candidates(shown)
      shown = shown.uniq.sort_by { |name| [ DISPLAY_ORDER.index(name) || DISPLAY_ORDER.size, name ] }
      shown.empty? ? nil : shown.join(CANDIDATE_JOIN)
    end

    def from_dialect(schema)
      return nil unless schema.is_a?(Hash)

      DIALECTS[schema[:dialect].to_s]
    end

    # Never a guess: naming one of `pg` and `mysql2` can put a database the app does not
    # use into every generated file. Two gems for the same database still answer.
    def from_gems(context)
      gems = context[:gems]
      return nil unless Tools::SectionFetch.usable?(gems)

      names = Array(gems[:notable_gems]).map { |g| g[:name].to_s }
      bundled = GEM_ADAPTERS.keys.select { |gem_name| names.include?(gem_name) }
      return nil if bundled.empty?

      candidates(bundled.map { |gem_name| GEM_ADAPTERS[gem_name] })
    end
  end
end
