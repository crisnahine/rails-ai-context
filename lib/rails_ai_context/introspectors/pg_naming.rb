# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    # How Rails' PostgreSQL connection and schema.rb dumper name extensions, enum types and
    # relations, and size a real, by Rails version, so the static tier answers as the booted app does.
    # Each rule cites the activerecord source it mirrors.
    module PgNaming
      DEFAULT_SEARCH_PATH = %w[public].freeze
      # 6.1 schema_dumper.rb:89 writes Schema.define, 7.0 :90 Schema[x.y]; every rule here starts at 7.0 or later.
      UNSTAMPED_DUMP = "6.1"

      module_function

      # The words PostgreSQL 13 to 17 quote as an identifier (pg_get_keywords, a category other than unreserved): the
      # union, as a release adds words and none leaves.
      QUOTED_KEYWORDS = %w[
        all analyse analyze and any array as asc asymmetric authorization between bigint binary bit boolean
        both case cast char character check coalesce collate collation column concurrently constraint create
        cross current_catalog current_date current_role current_schema current_time current_timestamp
        current_user dec decimal default deferrable desc distinct do else end except exists extract false
        fetch float for foreign freeze from full grant greatest group grouping having ilike in initially
        inner inout int integer intersect interval into is isnull join json json_array json_arrayagg
        json_exists json_object json_objectagg json_query json_scalar json_serialize json_table json_value
        lateral leading least left like limit localtime localtimestamp merge_action national natural nchar
        none normalize not notnull null nullif numeric offset on only or order out outer overlaps overlay
        placing position precision primary real references returning right row select session_user setof
        similar smallint some substring symmetric system_user table tablesample then time timestamp to
        trailing treat trim true union unique user using values varchar variadic verbose when where window
        with xmlattributes xmlconcat xmlelement xmlexists xmlforest xmlnamespaces xmlparse xmlpi xmlroot
        xmlserialize xmltable
      ].freeze

      # An identifier as quote_ident writes it: bare only when it is lowercase letters, digits and underscores,
      # starts with a letter or underscore, and is no keyword.
      def quote_ident(name)
        return name if name.match?(/\A[a-z_][a-z0-9_]*\z/) && !QUOTED_KEYWORDS.include?(name)

        %("#{name.gsub('"', '""')}")
      end

      # 8.0 postgresql_adapter.rb:506-520 drops the schema only when it is current_schema;
      # 7.0 :453, 7.1 :497 and 7.2 :496 select extname alone.
      def extension_name(name, schema, path, version)
        return name if schema.nil? || !RailsVersion.at_least?(version, "8.0") || schema == path.first

        "#{schema}.#{name}"
      end

      # 7.1 postgresql_adapter.rb:502-522 (to 8.1 :533-553): the types in current_schemas(false),
      # bare in current_schema. 7.0 :458-469 merges same-name types' labels; the static tier keeps the first set.
      def enum_list(enums, path, version)
        legacy = !RailsVersion.at_least?(version, "7.1")
        listed = enums.filter_map do |name, values|
          schema, bare = SqlScan.split_qualified(name)
          shown = if schema.nil? || legacy then bare
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
        RailsVersion.at_least?(version, "8.1")
      end

      # Whether a bare name in the dump says its schema. Before 8.1 the dumper names each of
      # connection.tables bare, whichever search path schema holds it, so only a one-schema path places it.
      def dump_places_names?(version, path)
        dump_qualifies_names?(version) || path.size < 2
      end

      # 7.1 postgresql/schema_dumper.rb:31-40 writes create_schema for every schema; 7.0 has no schemas().
      def dump_lists_schemas?(version)
        RailsVersion.at_least?(version, "7.1")
      end

      # The sequence a serial uses: the one a rename left it (the mark holds its name), else the one table and column name make.
      def owned_sequence(column, table, suffix = "seq")
        return column[:own_sequence] if column[:own_sequence].is_a?(String)

        schema, name = SqlScan.split_qualified(table)
        SqlScan.join_qualified(*[ schema, serial_sequence_name(name, column[:name], suffix) ].compact)
      end

      # A sequence named for the table and column with any seq\d* suffix makes the column a serial (new_column_from_field).
      def serial_sequence?(sequence, table, column)
        suffix = sequence.to_s[/_(seq\d*)\z/, 1]
        !suffix.nil? && sequence == owned_sequence({ name: column }, table, suffix)
      end

      # PostgreSQL's name for a serial's sequence, cut to its 63-byte identifiers (sequence_name_from_parts).
      def serial_sequence_name(table, column, suffix)
        available = 63 - suffix.bytesize - 2
        table_bytes = table.bytesize
        column_bytes = column.bytesize
        # The longer name loses a byte at a time, the column when they tie (makeObjectName).
        while table_bytes + column_bytes > available
          if table_bytes > column_bytes then table_bytes -= 1 else column_bytes -= 1 end
        end
        "#{clip_bytes(table, table_bytes)}_#{clip_bytes(column, column_bytes)}_#{suffix}"
      end

      # The text cut to at most limit bytes without splitting a character (pg_mbcliplen).
      def clip_bytes(text, limit)
        text.each_char.each_with_object(+"") { |char, kept| break kept if kept.bytesize + char.bytesize > limit; kept << char }
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
          schema, bare = SqlScan.split_qualified(name)
          rank = path.index(schema) if schema
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
          visible(name, shadowed_types, joined: false)
        end

        private

        # joined: false for a type, whose bare name is shown as written; a relation's is a key, so it keeps its quotes.
        def visible(name, shadowed, joined: true)
          schema, bare = SqlScan.split_qualified(name)
          schema.nil? || !path.include?(schema) || shadowed.include?(name) ? name : (joined ? SqlScan.join_qualified(bare) : bare)
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
        schema, = SqlScan.split_qualified(name)
        return if schema.nil? || !RailsVersion.at_least?(version, "8.1") || path.include?(schema) || created.include?(schema)
        return unless (created - path).empty?

        "If schema '#{schema}' exists, #{dump} leaves it out: Rails 8.1 dumps only the search path schemas there by default. " \
          "`config.active_record.dump_schemas = :all` includes it."
      end
    end
  end
end
