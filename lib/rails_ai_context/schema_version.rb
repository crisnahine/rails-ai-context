# frozen_string_literal: true

module RailsAiContext
  # Reads the applied schema version without a database connection.
  #
  # db/schema.rb (config.active_record.schema_format = :ruby, the default)
  # carries the version as a `version: X` keyword on the ActiveRecord::Schema
  # define call.
  #
  # db/structure.sql (schema_format = :sql) has no such line - Rails instead
  # writes every applied migration version into an `INSERT INTO
  # schema_migrations (version) VALUES (...)` block at the bottom of the dump
  # (mysqldump quotes the table name with backticks, pg_dump with double
  # quotes; the version literals themselves are always single-quoted).
  module SchemaVersion
    # From the dump the app configures, then the default files.
    def self.current(root)
      Introspectors::SchemaDumpPath.candidates(root).each do |format, path|
        next unless File.exist?(path)

        version = format == :ruby ? from_schema_rb(path) : from_structure_sql(path)
        return version if version
      end
      nil
    end

    def self.from_schema_rb(path)
      content = RailsAiContext::SafeFile.read(path, max_size: RailsAiContext.configuration.max_schema_file_size)
      return nil unless content

      AstCache.parse_string(content).value.statements.body.each do |node|
        version = define_version(node)
        return version if version
      end
      nil
    end

    # The version keyword of `ActiveRecord::Schema.define` or `ActiveRecord::Schema[7.1].define`.
    def self.define_version(node)
      return unless node.is_a?(Prism::CallNode) && node.name == :define

      receiver = node.receiver
      receiver = receiver.receiver if receiver.is_a?(Prism::CallNode) && receiver.name == :[]
      return unless receiver.is_a?(Prism::ConstantPathNode) && receiver.slice.delete_prefix("::") == "ActiveRecord::Schema"

      (node.arguments&.arguments || []).grep(Prism::KeywordHashNode).flat_map(&:elements).each do |assoc|
        next unless assoc.is_a?(Prism::AssocNode) && assoc.key.is_a?(Prism::SymbolNode) && assoc.key.unescaped == "version"

        return assoc.value.value.to_s if assoc.value.is_a?(Prism::IntegerNode)
      end
      nil
    end
    private_class_method :define_version

    def self.from_structure_sql(path)
      content = RailsAiContext::SafeFile.read(path, max_size: RailsAiContext.configuration.max_schema_file_size)
      return nil unless content

      versions = applied_versions(content)
      return nil if versions.empty?

      # Versions are timestamps (14 digits) padded consistently, but compare
      # numerically rather than lexically in case an old app still has
      # pre-timestamp (short integer) migration versions mixed in.
      versions.map(&:to_i).max.to_s
    end

    # The whole applied set, which only structure.sql records; schema.rb
    # carries the max version alone, so `current` is the answer there.
    def self.applied(root)
      format, path = Introspectors::SchemaDumpPath.present(root)
      return nil unless format == :sql

      recorded(format, path)
    end

    # What one dump records as applied: structure.sql's whole set, schema.rb's
    # newest version. A secondary database's dump answers for that database.
    def self.recorded(format, path)
      return nil unless path && File.exist?(path)
      return from_schema_rb(path) unless format == :sql

      content = RailsAiContext::SafeFile.read(path, max_size: RailsAiContext.configuration.max_schema_file_size)
      return nil unless content

      versions = applied_versions(content)
      versions.empty? ? nil : versions
    end

    # Every applied version recorded in a structure.sql dump's
    # schema_migrations INSERT block(s). Single home for the INSERT regex -
    # the schema introspector's pending-migration derivation uses this too.
    def self.applied_versions(content)
      content.scan(/INSERT INTO\s+[`"]?schema_migrations[`"]?\s*\(version\)\s*VALUES\s*(.+?);/mi)
        .flat_map { |m| m[0].scan(/'(\d+)'/).flatten }
    end
  end
end
