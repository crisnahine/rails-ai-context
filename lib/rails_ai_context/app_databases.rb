# frozen_string_literal: true

require "did_you_mean"

module RailsAiContext
  # Every database the app has, listed once per run: the primary, the rest of the
  # running environment's, those only another environment configures, then dumps
  # no environment claims. Both tiers feed one builder, so they list the same.
  module AppDatabases
    class Error < RailsAiContext::Error; end
    class UnknownDatabase < Error; end
    class NotHere < Error; end
    class NotBooted < Error; end

    # What a pool leased for another database belongs to: Rails names a pool by
    # its owner, and an owner that is no primary class is not the app's.
    class LeaseOwner
      def self.primary_class?
        false
      end

      def self.current_preventing_writes
        false
      end
    end

    # environment: the first that configures it; environments: every one, in file order.
    Database = Data.define(:name, :environment, :environments, :here, :primary, :replica, :tasks, :adapter, :adapter_default,
                           :family, :dump, :migrate_dirs, :config) do
      def with_connection(&block)
        with_pool { |pool| pool.with_connection(&block) }
      end

      # The primary is the app's own pool. Any other database gets a handler of
      # its own per lease, so the app's pools are never touched and two
      # concurrent leases never share a pool.
      def with_pool
        raise NotHere, not_here_message unless here
        raise NotBooted, "The #{name} database needs the booted app to connect, and this is the static tier." if RailsAiContext.static_tier? || !config.respond_to?(:configuration_hash)

        missing = DatabaseFile.missing(primary ? ActiveRecord::Base.connection_db_config : config)
        raise missing if missing
        return yield(ActiveRecord::Base.connection_pool) if primary

        handler = ActiveRecord::ConnectionAdapters::ConnectionHandler.new
        begin
          yield handler.establish_connection(config, owner_name: LeaseOwner)
        ensure
          handler.remove_connection_pool(LeaseOwner.name)
        end
      end

      # { pending: [{ version:, name: }, ...] } read through the lease, or { error: exception }.
      def pending_migrations(dirs = migrate_dirs)
        with_pool do |pool|
          pool.with_connection(&:verify!)
          { pending: MigrationStatus.pending_on(pool, dirs) }
        end
      rescue StandardError => e
        { error: e }
      end

      private

      def not_here_message
        if environments.empty?
          "The #{name} database is only a committed dump: no environment in config/database.yml configures it, so there is nothing to connect to."
        else
          "The #{name} database is configured in #{AppDatabases.environment_phrase(environments)}, " \
            "not in #{RailsAiContext.environment_name}, so it cannot be reached from here."
        end
      end
    end

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

        found = self[name]
        return found if found

        guess = ::DidYouMean::SpellChecker.new(dictionary: names).correct(name.to_s).first
        raise UnknownDatabase, "No database named #{name}.#{" Did you mean #{guess}?" if guess} This app has: #{names.join(', ')}"
      end

      def find_by_dump(path)
        find { |db| db.dump && db.dump.last == path.to_s }
      end
    end

    DUMP_GLOBS = { ruby: "*_schema.rb", sql: "*_structure.sql" }.freeze

    module_function

    # "production", or "staging and production".
    def environment_phrase(environments)
      environments.to_sentence(words_connector: ", ", two_words_connector: " and ", last_word_connector: " and ")
    end

    # A connection to the named database for the block. No name is the app's own pool, as it always was.
    def lease(root, name, &block)
      return yield(ActiveRecord::Base.connection) if name.to_s.empty?

      self.for(root).fetch(name).with_connection(&block)
    end

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
      configured = ->(name) { environments.select { |_, found| found.key?(name) }.keys }
      own.each do |name, value|
        listed << database(root, current, name, value, here: true, primary: name == primary_name, environments: configured.call(name))
      end

      environments.each do |env_name, found|
        next if env_name == current

        other_primary = DatabaseYml.primary_name_in(found)
        found.each do |name, value|
          next if listed.any? { |db| db.name == name }

          is_primary = listed.none?(&:primary) && name == other_primary
          next unless is_primary || (name != other_primary && tasks?(settings_of(value)))

          listed << database(root, env_name, name, value, here: false, primary: is_primary, environments: configured.call(name))
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

    def database(root, env_name, name, value, here:, primary:, environments:)
      settings = settings_of(value)
      adapter, from_default = value.respond_to?(:adapter) ? [ value.adapter, false ] : DatabaseYml.adapter(name, settings)
      replica = settings["replica"] == true
      tasks = tasks?(settings)
      Database.new(name: name, environment: env_name, environments: environments, here: here, primary: primary, replica: replica, tasks: tasks,
                   adapter: adapter, adapter_default: from_default, family: DatabaseFamily.of(adapter),
                   dump: (primary ? primary_dump(root) : Introspectors::SchemaDumpPath.secondary(root, name, settings) if tasks),
                   migrate_dirs: Introspectors::MigrationReplay.configured_dirs(root, settings) || [ File.join(root, "db", "migrate") ],
                   config: value)
    end

    def orphan(root, name, format, path)
      Database.new(name: name, environment: nil, environments: [], here: false, primary: false, replica: false, tasks: true,
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
