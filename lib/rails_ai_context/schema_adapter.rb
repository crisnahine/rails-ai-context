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

    # Gemfile display names, only as the last resort.
    GEM_ADAPTERS = {
      "pg" => "PostgreSQL",
      "mysql2" => "MySQL",
      "trilogy" => "MySQL",
      "sqlite3" => "SQLite"
    }.freeze

    # structure.sql dialects, as SchemaIntrospector records them.
    DIALECTS = {
      "postgresql" => "PostgreSQL",
      "mysql" => "MySQL",
      "sqlite" => "SQLite"
    }.freeze

    module_function

    # @param context [Hash] a full introspection context
    # @return [String] the adapter to show, never an internal placeholder
    def label(context)
      context = {} unless context.is_a?(Hash)
      schema = context[:schema]
      observed = schema.is_a?(Hash) ? schema[:adapter] : nil
      return observed unless placeholder?(observed)

      # Best first: the app's own database config, which needs no connection.
      # Then the dialect parsed out of structure.sql. Only then the Gemfile,
      # which is a guess - an app can carry two adapter gems.
      from_configurations(context) || from_dialect(schema) || from_gems(context) || "unknown"
    end

    def placeholder?(adapter)
      adapter.nil? || PLACEHOLDERS.include?(adapter.to_s)
    end

    def from_configurations(context)
      multi = context[:multi_database]
      return nil unless Serializers::SectionGuard.usable?(multi)

      primary = Array(multi[:databases]).find { |db| db[:name].to_s == "primary" } ||
                Array(multi[:databases]).first
      adapter = primary&.dig(:adapter)
      return nil if placeholder?(adapter)

      GEM_ADAPTERS[adapter.to_s] || adapter
    end

    def from_dialect(schema)
      return nil unless schema.is_a?(Hash)

      DIALECTS[schema[:dialect].to_s]
    end

    # Last, and order-independent: an app with both `pg` and `sqlite3` gets the
    # same answer here as anywhere else, rather than depending on which match
    # a loop happened to see last.
    def from_gems(context)
      gems = context[:gems]
      return nil unless Serializers::SectionGuard.usable?(gems)

      names = Array(gems[:notable_gems]).map { |g| g[:name].to_s }
      GEM_ADAPTERS.each_key { |gem_name| return GEM_ADAPTERS[gem_name] if names.include?(gem_name) }
      nil
    end
  end
end
