# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    # AST-backed view of a schema.rb dump: which tables it declares, their
    # columns and defaults, and the indexes covering them.
    #
    # The listener emits a flat, ordered event list, so columns and in-table
    # indexes are attached to the most recent create_table. Top-level
    # add_index names its own table.
    class SchemaReader
      def initialize(path)
        @path = path
      end

      # @return [Hash] table name => { columns: [{ name:, type:, default: }], indexes: [[column]] }
      def tables
        @tables ||= build
      end

      # Declared defaults for one table, as source text. Callers report these
      # verbatim when the live database returns no default.
      def defaults_for(table)
        (tables.dig(table, :columns) || []).each_with_object({}) do |column, defaults|
          defaults[column[:name]] = column[:default] unless column[:default].nil?
        end
      end

      def column?(table, name)
        (tables.dig(table, :columns) || []).any? { |c| c[:name] == name }
      end

      def any_column?(name)
        tables.any? { |_, table| table[:columns].any? { |c| c[:name] == name } }
      end

      private

      attr_reader :path

      def build
        return {} unless path && File.exist?(path)

        events = SourceIntrospector.walk(path, { schema: -> { Listeners::SchemaDslListener.new } })[:schema] || []
        tables = {}
        current = nil

        events.sort_by { |e| e[:location] }.each do |event|
          case event[:type]
          when :create_table
            current = event[:table]
            tables[current] ||= { columns: [], indexes: [] }
          when :column
            next unless current
            tables[current][:columns] << column_entry(event)
          when :index
            next unless current
            tables[current][:indexes] << event[:columns]
          when :add_index
            table = tables[event[:table]] or next
            table[:indexes] << event[:columns]
          end
        end

        tables
      rescue => e
        $stderr.puts "[rails-ai-context] SchemaReader failed: #{e.message}" if ENV["DEBUG"]
        {}
      end

      def column_entry(event)
        {
          name:    column_name(event),
          type:    event[:column_type],
          default: default_for(event)
        }
      end

      # A reference declares the foreign key column, not a column of its own name.
      def column_name(event)
        return "#{event[:name]}_id" if %w[references belongs_to].include?(event[:column_type])

        event[:name]
      end

      def default_for(event)
        return nil unless event[:options].key?(:default)

        value = event[:options][:default]
        return event[:default_source] if value == RailsAiContext::Confidence::INFERRED

        value.to_s
      end
    end
  end
end
