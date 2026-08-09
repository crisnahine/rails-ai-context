# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    # AST-backed view of a schema.rb dump: which tables it declares, their
    # columns, defaults and indexes, plus the foreign keys, enum types and
    # check constraints declared alongside them.
    #
    # The listener emits a flat, ordered event list, so columns, in-table
    # indexes and in-table constraints are attached to the most recent
    # create_table. Top-level add_index and add_check_constraint name their
    # own table.
    #
    # Callers keep their own output shapes: this reads the dump, it does not
    # decide how a table is reported.
    class SchemaReader
      def initialize(path)
        @path = path
      end

      # @return [Hash] table name => { options:, columns: [...], indexes: [...] }
      def tables
        parse[:tables]
      end

      # @return [Array<Hash>] { from:, to: } per declared foreign key
      def foreign_keys
        parse[:foreign_keys]
      end

      # @return [Array<Hash>] { name:, values: } per declared enum type
      def enums
        parse[:enums]
      end

      # @return [Array<Hash>] { table:, expression: } per declared constraint
      def check_constraints
        parse[:check_constraints]
      end

      # Declared defaults for one table, as source text. Callers report these
      # verbatim when the live database returns no default.
      def defaults_for(table)
        columns_for(table).each_with_object({}) do |column, defaults|
          defaults[column[:name]] = column[:default] unless column[:default].nil?
        end
      end

      def column?(table, name)
        columns_for(table).any? { |c| c[:name] == name }
      end

      def any_column?(name)
        tables.any? { |table, _| column?(table, name) }
      end

      private

      attr_reader :path

      def columns_for(table)
        tables.dig(table, :columns) || []
      end

      def parse
        @parse ||= build
      end

      def build
        empty = { tables: {}, foreign_keys: [], enums: [], check_constraints: [] }
        return empty unless path && File.exist?(path)

        # Read against the configured schema limit rather than walking the
        # path directly: AstCache caps parses well below it, and a schema
        # between the two would silently read as having no tables at all.
        source = RailsAiContext::SafeFile.read(path, max_size: RailsAiContext.configuration.max_schema_file_size)
        return empty unless source

        events = SourceIntrospector.walk_source(source, { schema: -> { Listeners::SchemaDslListener.new } })[:schema] || []
        events.sort_by { |e| e[:location] }.each_with_object(empty) do |event, schema|
          absorb(event, schema)
        end
      rescue => e
        $stderr.puts "[rails-ai-context] SchemaReader failed: #{e.message}" if ENV["DEBUG"]
        { tables: {}, foreign_keys: [], enums: [], check_constraints: [] }
      end

      def absorb(event, schema)
        case event[:type]
        when :create_table
          @current = event[:table]
          schema[:tables][@current] ||= { options: event[:options] || {}, columns: [], indexes: [] }
        when :column
          current_table(schema)&.dig(:columns)&.push(column_entry(event))
        when :index
          current_table(schema)&.dig(:indexes)&.push(index_entry(event))
        when :add_index
          schema[:tables][event[:table]]&.dig(:indexes)&.push(index_entry(event))
        when :foreign_key
          schema[:foreign_keys] << { from: event[:from], to: event[:to] }
        when :enum
          schema[:enums] << { name: event[:name], values: event[:values] }
        when :check_constraint
          schema[:check_constraints] << { table: @current, expression: event[:expression] } if @current
        when :add_check_constraint
          schema[:check_constraints] << { table: event[:table], expression: event[:expression] }
        end
      end

      def current_table(schema)
        @current && schema[:tables][@current]
      end

      def column_entry(event)
        options = event[:options] || {}
        {
          name:    column_name(event),
          type:    event[:column_type],
          default: default_for(event, options),
          options: options
        }
      end

      def index_entry(event)
        { columns: event[:columns].map(&:to_s), options: event[:options] || {} }
      end

      # A reference declares the foreign key column, not a column of its own name.
      def column_name(event)
        return "#{event[:name]}_id" if %w[references belongs_to].include?(event[:column_type])

        event[:name]
      end

      def default_for(event, options)
        return nil unless options.key?(:default)

        value = options[:default]
        # A non-literal default (a proc, a constant) parses to the confidence
        # marker, so fall back to what the column actually declared.
        return event[:default_source] if value == RailsAiContext::Confidence::INFERRED
        return nil if value.nil?

        value.to_s
      end
    end
  end
end
