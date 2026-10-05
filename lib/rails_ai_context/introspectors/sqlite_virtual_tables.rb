# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    # Rails 8 leaves a virtual table and its shadow tables out of connection.tables;
    # Rails 7.x lists them as plain tables and has no virtual_tables, so both are read here.
    module SqliteVirtualTables
      module_function

      # Each virtual table's [module, arguments], read from sqlite_master as Rails 8 does.
      def of(connection)
        connection.select_rows("SELECT name, sql FROM sqlite_master WHERE sql LIKE 'CREATE VIRTUAL %'").to_h do |name, sql|
          [ name, sql.match(/USING\s+(\w+)\s*(?:\((.*)\))?/im).to_a.drop(1) ]
        end
      end

      # ponytail: pragma_table_list needs SQLite 3.37+; an older SQLite under Rails 7.x still lists shadow tables.
      def hidden(connection)
        virtual = of(connection).keys
        return virtual if virtual.empty?

        virtual + connection.select_values("SELECT name FROM pragma_table_list WHERE type = 'shadow'")
      rescue ActiveRecord::StatementInvalid
        virtual
      end
    end
  end
end
