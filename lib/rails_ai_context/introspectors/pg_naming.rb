# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    # How Rails' PostgreSQL connection and schema.rb dumper name extensions, enum types and
    # relations, by Rails version, so the static tier names them as the booted app does.
    # Each rule cites the activerecord source it mirrors.
    module PgNaming
      DEFAULT_SEARCH_PATH = %w[public].freeze
      # 6.1 schema_dumper.rb:89 writes Schema.define, 7.0 :90 Schema[x.y]; every rule here starts at 7.0 or later.
      UNSTAMPED_DUMP = "6.1"

      module_function

      # The running Rails when booted, else the lockfile's; nil when neither says.
      def rails_version(root)
        return Rails.version if defined?(Rails) && Rails.respond_to?(:version) && !RailsAiContext.static_tier?

        lock = GemLock.for(root)
        lock.version("rails") || lock.version("railties")
      end

      # An unknown version takes the newest rules.
      def at_least?(version, release)
        version.nil? || Gem::Version.new(version) >= Gem::Version.new(release)
      end

      # 8.0 postgresql_adapter.rb:506-520 drops the schema only when it is current_schema;
      # 7.0 :453, 7.1 :497 and 7.2 :496 select extname alone.
      def extension_name(name, schema, path, version)
        return name if schema.nil? || !at_least?(version, "8.0") || schema == path.first

        "#{schema}.#{name}"
      end

      # 7.1 postgresql_adapter.rb:502-522 (to 8.1 :533-553): the types in current_schemas(false),
      # bare in current_schema. 7.0 :458-469 merges same-name types' labels; the static tier keeps the first set.
      def enum_list(enums, path, version)
        legacy = !at_least?(version, "7.1")
        listed = enums.filter_map do |name, values|
          schema, dot, bare = name.rpartition(".")
          shown = if dot.empty? || legacy then bare
          elsif path.include?(schema) then schema == path.first ? bare : name
          end
          { name: shown, values: values } if shown
        end
        listed.uniq { |enum| enum[:name] }.sort_by { |enum| enum[:name] }
      end

      # 8.1 schema_dumper.rb:154-162 (relation_name) qualifies every name in a dump of more than one
      # schema. Before, the dumper writes connection.tables, enum_types and column.sql_type
      # (7.2 postgresql/schema_dumper.rb:19-29, :94), the names the booted app reads.
      def dump_qualifies_names?(version)
        at_least?(version, "8.1")
      end

      # Whether a bare name in the dump says its schema. Before 8.1 the dumper names each of
      # connection.tables bare, whichever search path schema holds it, so only a one-schema path places it.
      def dump_places_names?(version, path)
        dump_qualifies_names?(version) || path.size < 2
      end

      # 7.1 postgresql/schema_dumper.rb:31-40 writes create_schema for every schema; 7.0 has no schemas().
      def dump_lists_schemas?(version)
        at_least?(version, "7.1")
      end

      # current_schemas(false) skips a schema that does not exist; pg_dump never creates public.
      def existing_path(path, created)
        path.select { |schema| schema == "public" || created.include?(schema) }
      end

      # The names a dump's relations and enum types go by, given its qualified names.
      def names(path, relations: [], types: [])
        Names.new(path, shadowed(relations, path), shadowed(types, path))
      end

      # The qualified names an earlier search path schema hides by holding the same bare name.
      def shadowed(names, path)
        return Set.new if path.size < 2

        ranked = names.uniq.filter_map do |name|
          schema, dot, bare = name.rpartition(".")
          rank = path.index(schema) unless dot.empty?
          [ rank, bare, name ] if rank
        end
        first = ranked.sort_by(&:first).reverse.to_h { |_, bare, name| [ bare, name ] }
        ranked.filter_map { |_, bare, name| name unless first[bare] == name }.to_set
      end

      # PostgreSQL resolves a bare name through the search path (data_sources and format_type alike).
      Names = Struct.new(:path, :shadowed_relations, :shadowed_types) do
        def relation(name)
          visible(name, shadowed_relations)
        end

        def type(name)
          visible(name, shadowed_types)
        end

        private

        def visible(name, shadowed)
          schema, dot, bare = name.rpartition(".")
          dot.empty? || !path.include?(schema) || shadowed.include?(name) ? name : bare
        end
      end

      # The enum types a table's columns use: a bare column type is the first search path schema's
      # holding it, and a bare list name is the current schema's.
      def enums_used(enum_types, column_types, path)
        path = Array(path).presence || DEFAULT_SEARCH_PATH
        listed = Array(enum_types).to_h { |enum| [ enum[:name].to_s.include?(".") ? enum[:name].to_s : "#{path.first}.#{enum[:name]}", enum ] }
        used = column_types.map do |type|
          type.include?(".") ? type : path.map { |schema| "#{schema}.#{type}" }.find { |key| listed.key?(key) }
        end
        listed.select { |key, _| used.include?(key) }.values
      end

      # 8.1 postgresql/schema_dumper.rb:13-23, :50-68 dumps only ActiveRecord.dump_schemas, the search
      # path by default (active_record.rb:436); 7.1 to 8.0 dump every schema's create_schema and ignore it.
      # A dump naming no schema off the path is the default; one that does has dump_schemas set.
      def missing_from_schema_rb(name, path, created, version, dump)
        schema, dot, = name.to_s.rpartition(".")
        return if dot.empty? || !at_least?(version, "8.1") || path.include?(schema) || created.include?(schema)
        return unless (created - path).empty?

        "If schema '#{schema}' exists, #{dump} leaves it out: Rails 8.1 dumps only the search path schemas there by default. " \
          "`config.active_record.dump_schemas = :all` includes it."
      end
    end
  end
end
