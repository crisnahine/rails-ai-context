# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    # The primary database's dump file as DatabaseTasks.schema_dump_path names it
    # (7.0 to 8.1): database.yml's schema_dump in the configured schema_format.
    module SchemaDumpPath
      FILE_NAMES = { ruby: "schema.rb", sql: "structure.sql" }.freeze
      APP_FORMAT = /^\s*config\.active_record\.schema_format\s*=\s*:(ruby|sql)\b/

      module_function

      # [format, absolute path] pairs to try in order: the configured dump first, then
      # the default file of each format, for an app whose configured file is missing.
      # Only the first is the file Rails would load.
      # Every schema reader asks, so a run reads the config files once.
      def candidates(root)
        root = root.to_s
        RailsAiContext::RunCache.fetch([ :schema_dump_candidates, root ]) do
          config = RailsAiContext::DatabaseYml.primary(root) || {}
          format = schema_format(root, config)
          defaults = [ format, (%i[ruby sql] - [ format ]).first ].map { |f| [ f, File.join(root, "db", FILE_NAMES[f]) ] }
          ([ configured(root, config, format) ].compact + defaults).uniq
        end
      end

      # The first candidate on disk, which the readers answer from.
      def present(root)
        candidates(root).find { |_, path| File.exist?(path) }
      end

      # HashConfig#schema_format (8.1) reads database.yml first; the environment's file sets it after application.rb.
      def schema_format(root, config)
        declared = config["schema_format"].to_s
        return declared.to_sym if FILE_NAMES.key?(declared.to_sym)

        files = [ "config/application.rb", "config/environments/#{RailsAiContext.environment_name}.rb" ]
        found = files.filter_map { |path| RailsAiContext::SafeFile.read(File.join(root, path)).to_s.scan(APP_FORMAT).last&.first }
        (found.last || "ruby").to_sym
      end

      # schema_dump: false (or empty) means no dump; a name outside db/ or the app is not read.
      def configured(root, config, format)
        return nil unless config.key?("schema_dump")

        name = config["schema_dump"]
        return nil unless name.is_a?(String) && !name.empty? && !RailsAiContext::DatabaseYml.computed?(name)

        db_dir = File.join(root, "db")
        relative = File.dirname(name) == db_dir ? File.join("db", File.basename(name)) : File.join("db", name)
        resolved = RailsAiContext::SafePath.locate(relative, under: root, max_size: RailsAiContext.configuration.max_schema_file_size)
        [ format, File.join(root, relative) ] if resolved.ok?
      end
    end
  end
end
