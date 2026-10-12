# frozen_string_literal: true

module RailsAiContext
  # Every database the app has, listed once per run: the primary, the rest of the
  # running environment's, those only another environment configures, then dumps
  # no environment claims. Both tiers feed one builder, so they list the same.
  module AppDatabases
    class UnknownDatabase < StandardError; end

    Database = Data.define(:name, :environment, :here, :primary, :replica, :tasks, :adapter, :adapter_default,
                           :family, :dump, :migrate_dirs, :config)

    class List
      include Enumerable

      def initialize(databases)
        @databases = databases.freeze
      end

      def each(&block)
        @databases.each(&block)
      end

      def primary
        find(&:primary)
      end

      # The databases past the primary that Rails dumps and migrates.
      def secondaries
        reject { |db| db.primary || db.replica || !db.tasks }
      end

      def here
        select(&:here)
      end

      def names
        map(&:name)
      end

      def [](name)
        find { |db| db.name == name.to_s }
      end

      # nil or "" is the primary.
      def fetch(name)
        return primary if name.nil? || name.to_s.empty?

        self[name] or raise UnknownDatabase, "No database named #{name}. This app has: #{names.join(', ')}"
      end

      def find_by_dump(path)
        find { |db| db.dump && db.dump.last == path.to_s }
      end
    end

    DUMP_GLOBS = { ruby: "*_schema.rb", sql: "*_structure.sql" }.freeze

    module_function

    def for(root)
      root = root.to_s
      environments = booted_environments(root)
      tier = environments ? :booted : :static
      RunCache.fetch([ :app_databases, root, tier ]) do
        environments ||= static_environments(root)
        build(environments: declared(root, environments), current: RailsAiContext.environment_name, root: root, dumps: dump_files(root))
      end
    end

    # environments: { env => { name => settings Hash or db_config } } in file order;
    # dumps: [format, path] for each secondary-looking dump on disk.
    def build(environments:, current:, root:, dumps:)
      listed = []
      own = environments[current] || {}
      primary_name = DatabaseYml.primary_name_in(own)
      own.each { |name, value| listed << database(root, current, name, value, here: true, primary: name == primary_name) }

      environments.each do |env_name, found|
        next if env_name == current

        other_primary = DatabaseYml.primary_name_in(found)
        found.each do |name, value|
          next if listed.any? { |db| db.name == name }

          is_primary = listed.none?(&:primary) && name == other_primary
          next unless is_primary || (name != other_primary && tasks?(settings_of(value)))

          listed << database(root, env_name, name, value, here: false, primary: is_primary)
        end
      end

      claimed = listed.filter_map { |db| db.dump&.last } + Introspectors::SchemaDumpPath.candidates(root).map(&:last)
      dumps.each do |format, path|
        next if claimed.include?(path)

        name = File.basename(path).sub(/_(schema\.rb|structure\.sql)\z/, "")
        next if listed.any? { |db| db.name == name }

        listed << orphan(root, name, format, path)
      end
      List.new(listed)
    end

    def database(root, env_name, name, value, here:, primary:)
      settings = settings_of(value)
      adapter, from_default = value.respond_to?(:adapter) ? [ value.adapter, false ] : DatabaseYml.adapter(name, settings)
      replica = settings["replica"] == true
      tasks = tasks?(settings)
      Database.new(name: name, environment: env_name, here: here, primary: primary, replica: replica, tasks: tasks,
                   adapter: adapter, adapter_default: from_default, family: DatabaseFamily.of(adapter),
                   dump: (primary ? primary_dump(root) : Introspectors::SchemaDumpPath.secondary(root, name, settings) if tasks),
                   migrate_dirs: Introspectors::MigrationReplay.configured_dirs(root, settings) || [ File.join(root, "db", "migrate") ],
                   config: value)
    end

    def orphan(root, name, format, path)
      Database.new(name: name, environment: nil, here: false, primary: false, replica: false, tasks: true,
                   adapter: nil, adapter_default: false, family: DatabaseFamily.of(nil), dump: [ format, path ],
                   migrate_dirs: [ File.join(root, "db", "#{name}_migrate") ], config: nil)
    end

    # HashConfig#database_tasks?: a replica and database_tasks: false run none.
    def tasks?(settings)
      !settings["replica"] && settings.fetch("database_tasks", true) != false
    end

    def settings_of(value)
      value = value.configuration_hash if value.respond_to?(:configuration_hash)
      value.is_a?(Hash) ? value.transform_keys(&:to_s) : {}
    end

    def primary_dump(root)
      Introspectors::SchemaDumpPath.present(root) || Introspectors::SchemaDumpPath.candidates(root).first
    end

    # ActiveRecord's configurations describe the app booted at Rails.root; any other root is read from its file.
    def booted_environments(root)
      return nil if RailsAiContext.static_tier? || !defined?(ActiveRecord::Base) || !defined?(Rails.root) || Rails.root.to_s != root

      configs = ActiveRecord::Base.configurations.configurations
      return nil if configs.empty?

      configs.each_with_object({}) { |config, found| (found[config.env_name] ||= {})[config.name] = config }
    rescue StandardError => e
      RailsAiContext.debug_fail(e, nil, label: "booted_environments")
    end

    # Rails builds the primary from DATABASE_URL when the file has no entry for the environment.
    def static_environments(root)
      environments = (DatabaseYml.file(root) || {}).transform_values { |config| DatabaseYml.databases_in(config) }.reject { |_, found| found.empty? }
      current = RailsAiContext.environment_name
      environments = environments.merge(current => { "primary" => {} }) if !environments.key?(current) && !ENV["DATABASE_URL"].to_s.empty?
      environments
    end

    # A key with no config/environments file holds an anchor (`default: &default`), not an environment.
    def declared(root, environments)
      files = Dir.glob(File.join(root, "config/environments/*.rb")).map { |path| File.basename(path, ".rb") }
      return environments if files.empty?

      current = RailsAiContext.environment_name
      environments.select { |env_name, _| env_name == current || files.include?(env_name) }
    end

    def dump_files(root)
      DUMP_GLOBS.flat_map { |format, glob| Dir.glob(File.join(root, "db", glob)).sort.map { |path| [ format, path ] } }
    end
  end
end
