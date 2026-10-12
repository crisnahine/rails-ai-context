# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    # The primary database's dump file as DatabaseTasks.schema_dump_path names it
    # (7.0 to 8.1): database.yml's schema_dump in the configured schema_format.
    module SchemaDumpPath
      FILE_NAMES = { ruby: "schema.rb", sql: "structure.sql" }.freeze

      module_function

      # [format, path] pairs: the configured dump first (the one Rails loads), then each format's default file.
      def candidates(root)
        root = root.to_s
        RailsAiContext::RunCache.fetch([ :schema_dump_candidates, root ]) do
          config = RailsAiContext::DatabaseYml.primary(root) || {}
          format = schema_format(root, config)
          defaults = [ format, (%i[ruby sql] - [ format ]).first ].map { |f| [ f, File.join(root, "db", FILE_NAMES[f]) ] }
          ([ configured(root, config, format) ].compact + defaults).uniq
        end
      end

      # A secondary database's dump as schema_dump_path names it: its schema_dump,
      # else <name>_schema.rb or <name>_structure.sql in its format; nil for none.
      def secondary(root, name, config)
        format = schema_format(root, config)
        return configured(root, config, format) if config.key?("schema_dump")

        [ format, File.join(root, "db", "#{name}_#{FILE_NAMES[format]}") ]
      end

      # The database a dump belongs to: the app database whose dump it is, else the one its file name says.
      def database_name(root, dump_path)
        return "primary" if dump_path.nil?

        named = RailsAiContext::AppDatabases.for(root).find_by_dump(dump_path)&.name
        named || File.basename(dump_path.to_s).sub(/\.(rb|sql)\z/, "").sub(/_?(schema|structure)\z/, "").then { |name| name.empty? ? "primary" : name }
      end

      # The first candidate on disk, which the readers answer from.
      def present(root)
        candidates(root).find { |_, path| File.exist?(path) }
      end

      # HashConfig#schema_format (8.0.3+) reads database.yml first; the environment's file sets it after application.rb.
      def schema_format(root, config)
        declared = config["schema_format"].to_s
        return declared.to_sym if FILE_NAMES.key?(declared.to_sym) && reads_database_schema_format?(root)

        ActiveRecordSettings.for(root)[:schema_format] || :ruby
      end

      # An app whose lockfile does not say its Active Record is taken to read it.
      def reads_database_schema_format?(root)
        locked = RailsAiContext::GemLock.for(root).version("activerecord")
        locked.nil? || Gem::Version.new(locked) >= Gem::Version.new("8.0.3")
      rescue ArgumentError
        true
      end

      # schema_dump: false (or empty) means no dump; a name outside db/ or the app is not read.
      # A missing or oversized file is still the one Rails loads, so the readers can name it.
      def configured(root, config, format)
        return nil unless config.key?("schema_dump")

        name = config["schema_dump"]
        return nil unless name.is_a?(String) && !name.empty? && !RailsAiContext::DatabaseYml.computed?(name)

        db_dir = File.join(root, "db")
        relative = File.dirname(name) == db_dir ? File.join("db", File.basename(name)) : File.join("db", name)
        resolved = RailsAiContext::SafePath.locate(relative, under: root, max_size: RailsAiContext.configuration.max_schema_file_size)
        [ format, File.join(root, relative) ] if resolved.ok? || %i[too_large missing].include?(resolved.refusal)
      end
    end
  end
end
