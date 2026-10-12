# frozen_string_literal: true

module RailsAiContext
  module Tools
    class RuntimeInfo < BaseTool
      tool_name "rails_runtime_info"
      description "Live runtime state: database connection pool, table sizes, pending migrations, cache stats, job queues. " \
        "Use when: debugging performance, checking database health, verifying deployment state, or understanding infrastructure. " \
        "Key params: detail (summary/standard/full), section (database/cache/jobs/connections)."

      input_schema(
        properties: {
          detail: RailsAiContext::DetailLevel.schema("Detail level. summary: one-line per section. standard: tables with sizes (default). full: index usage + cache details."),
          section: {
            type: "string",
            enum: %w[database cache jobs connections],
            description: "Filter to one section. Omit for all sections."
          },
          database: {
            type: "string",
            description: "The app database whose table sizes and index usage to show, by its config/database.yml name. Default: the primary."
          }
        }
      )

      guide_row(
        order: 33,
        mcp: "rails_runtime_info(detail:\"standard\")",
        cli_args: "detail=standard",
        summary: "Live runtime: DB pool, table sizes, cache stats, job queues, pending migrations"
      )

      annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: false, open_world_hint: false)

      def self.call(detail: "standard", section: nil, database: nil, server_context: nil)
        if (refusal = static_tier_refusal("Live runtime state"))
          return refusal
        end
        AppDatabases.for(rails_app.root).fetch(database).reachable! unless database.to_s.empty?

        lines = [ "# Runtime Info", "" ]

        sections = section ? [ section ] : %w[connections database cache jobs]

        sections.each do |s|
          result = case s
          when "connections" then gather_connection_pool
          when "database"    then gather_database(detail, database)
          when "cache"       then gather_cache
          when "jobs"        then gather_jobs(detail)
          end
          lines.concat(result) if result&.any?
        end

        if lines.size <= 2
          lines << "_No runtime data available. Ensure the app has a database connection._"
        end
        if section && section != "database" && !database.to_s.empty?
          lines << "_The #{section} section does not read `database`, so #{database} was not used._"
        end

        text_response(lines.join("\n"))
      rescue AppDatabases::Error => e
        error_response(e.message)
      end

      class << self
        private

        # ── Connection pool ──────────────────────────────────────────────

        def gather_connection_pool
          return [ "## Connection Pool", "", "_ActiveRecord not available._", "" ] unless defined?(ActiveRecord::Base)

          stat = ActiveRecord::Base.connection_pool.stat
          lines = [ "## Connection Pool", "" ]
          # Read in-process, so the counts are the MCP server's own. 0 connections
          # said nothing about an app server running beside it.
          lines << "_This MCP server process's pool: the counts are its own connections. Each app server process keeps a pool of its own, of the size configured here._"
          lines << ""
          lines << "| Metric | Value |"
          lines << "|--------|-------|"
          lines << "| Pool size | #{stat[:size]} |"
          lines << "| Connections | #{stat[:connections]} |"
          lines << "| Busy | #{stat[:busy]} |"
          lines << "| Idle | #{stat[:idle]} |"
          lines << "| Dead | #{stat[:dead]} |"
          lines << "| Waiting | #{stat[:waiting]} |"
          lines << "| Checkout timeout | #{stat[:checkout_timeout]}s |"

          utilization = RailsAiContext::Percent.floor(stat[:busy], stat[:size], decimals: 0)
          lines << "" << "Pool utilization: #{utilization}%"
          lines << "**Warning:** Pool is full (#{stat[:busy]}/#{stat[:size]} busy, #{stat[:waiting]} waiting)" if stat[:waiting] > 0
          lines << ""
          lines
        rescue => e
          [ "## Connection Pool", "", "_Not available: #{e.message}_", "" ]
        end

        # ── Database section ─────────────────────────────────────────────

        def gather_database(detail, database)
          return [ "## Database", "", "_ActiveRecord not available._", "" ] unless defined?(ActiveRecord::Base)

          AppDatabases.lease(rails_app.root, database) { |conn| database_lines(conn, detail, database) }
        rescue AppDatabases::Missing => e
          [ "## Database", "", "_Not available: #{e.message}_", "" ]
        rescue AppDatabases::Error
          raise
        rescue => e
          [ "## Database", "", "_Not available: #{e.message}_", "" ]
        end

        def database_lines(conn, detail, database)
          family = DatabaseFamily.of(conn)
          lines = [ database.to_s.empty? ? "## Database" : "## Database: #{database}", "" ]
          lines << "**Adapter:** #{SchemaAdapter.display(conn.adapter_name)}"
          unless family.known?
            lines << "" << "_Table sizes and index usage are not available for the #{family.name} adapter._"
          end

          sizes = gather_table_sizes(conn, family)
          if sizes&.any?
            lines << "" << "### Table Sizes"
            lines << "| Table | Size |"
            lines << "|-------|------|"
            shown = RailsAiContext::DetailLevel.summary?(detail) ? 5 : 30
            sizes.first(shown).each do |row|
              lines << "| #{row[:name]} | #{human_size(row[:bytes])} |"
            end
            total = sizes.sum { |r| r[:bytes] }
            lines << "| **Total** | **#{human_size(total)}** |"
            lines << "_#{count_phrase(sizes.size - shown, "more table")}..._" if sizes.size > shown
          end

          lines.concat(pending_migration_lines)

          # Index usage (full detail only)
          if RailsAiContext::DetailLevel.full?(detail)
            index_usage = gather_index_usage(conn, family)
            if index_usage&.any?
              lines << "" << "### Index Usage"
              unused = index_usage.select { |i| i[:scans] == 0 }
              if unused.any?
                lines << "**Unused indexes (0 scans):**"
                unused.first(10).each { |i| lines << "- `#{i[:index]}` on `#{i[:table]}`" }
                lines << "_#{count_phrase(unused.size - 10, "more unused index", plural: "more unused indexes")}..._" if unused.size > 10
              end
              hot = index_usage.sort_by { |i| [ -i[:scans].to_i, i[:table].to_s, i[:index].to_s ] }.first(5)
              lines << "" << "**Most used indexes:**"
              hot.each { |i| lines << "- `#{i[:index]}` on `#{i[:table]}` - #{count_phrase(i[:scans], "scan")}" }
            end
          end

          lines << ""
          lines
        end

        # Rails-managed bookkeeping tables - real tables, but noise in a
        # "table sizes" view aimed at application data (matches the schema
        # introspector, which also skips them).
        INTERNAL_TABLES = %w[schema_migrations ar_internal_metadata].freeze

        def gather_table_sizes(conn, family)
          return nil unless family.known?

          family.table_sizes(conn)&.reject { |r| INTERNAL_TABLES.include?(r[:name]) }
        rescue => e
          RailsAiContext.debug_fail(e, nil, label: "gather_table_sizes")
        end

        # Every database the app migrates here, each through its own connection.
        def pending_migration_lines
          databases = AppDatabases.for(rails_app.root).here.select(&:tasks)
          if databases.size <= 1
            pending = RailsAiContext::PendingMigrations.live(RailsAiContext::PendingMigrations.migrate_dirs_for(rails_app.root))
            return [] unless pending
            return [ "", "**Migrations:** all up to date" ] if pending.empty?

            return [ "", "**Pending migrations:** #{pending.size}", *pending.map { |m| "- #{m[:version]} #{m[:name]}" } ]
          end

          states = databases.to_h { |db| [ db.name, db.pending_migrations[:pending] ] }
          unread = states.select { |_, pending| pending.nil? }.keys
          pending = states.flat_map { |name, found| Array(found).map { |m| m.merge(database: name) } }
          lines = []
          if pending.any?
            by_database = pending.map { |m| m[:database] }.tally.map { |name, count| "#{count} in #{name}" }
            lines << "" << "**Pending migrations:** #{by_database.one? ? by_database.first : "#{pending.size} (#{by_database.join(', ')})"}"
            pending.each { |m| lines << "- #{m[:version]} #{m[:name]} (#{m[:database]})" }
          end
          lines << "" << "_Pending migrations could not be read for #{unread.join(', ')}._" if unread.any?
          lines << "" << "**Migrations:** all up to date in #{databases.map(&:name).join(', ')}" if pending.empty? && unread.empty?
          lines
        end

        def gather_index_usage(conn, family)
          family.index_usage(conn) if family.known?
        rescue => e
          RailsAiContext.debug_fail(e, nil, label: "gather_index_usage")
        end

        # ── Cache section ────────────────────────────────────────────────

        # A store's #stats is a Hash - memcached returns curr_items, bytes and
        # friends. Rendering it with #inspect puts a Ruby literal in an answer
        # a reader has to parse; the pairs are the facts.
        def cache_stat_lines(stats)
          return [ "**Stats:** #{stats}" ] unless stats.is_a?(Hash)
          return [ "_No cache stats reported._" ] if stats.empty?

          [ "**Stats:**" ] + stats.map { |key, value| "- #{key}: #{format_stat_value(value)}" }
        end

        def format_stat_value(value)
          value.is_a?(Hash) ? value.map { |k, v| "#{k}: #{v}" }.join(", ") : value.to_s
        end

        # Whose numbers these are depends on where the store keeps its entries.
        def cache_scope(cache)
          case cache.class.name.demodulize
          when "MemoryStore"
            "_A MemoryStore lives inside one process, so these numbers are this MCP server's own. " \
              "Each app server process holds entries of its own that no other process sees._"
          when "NullStore" then "_A NullStore keeps nothing, in this process or any other._"
          when "FileStore"
            "_The app's processes on this machine share these files#{" under `#{relative_path(cache.cache_path)}`" if cache.respond_to?(:cache_path)}._"
          else
            "_The app's processes in this environment share this store, so these numbers are theirs too._"
          end
        end

        def relative_path(path)
          path.to_s.delete_prefix("#{rails_app.root}/")
        end

        # A store no other process can read is nobody's real cache.
        PROCESS_STORES = /\A:(memory|null)_store\b/

        # This process runs one environment's store; another environment that
        # configures a shared one (Redis, Memcached, Solid Cache) keeps the
        # app's real cache there.
        def configured_elsewhere
          config = cached_context[:env_config]
          return [] unless config.is_a?(Hash)

          Array(config[:environments]).filter_map do |env|
            next if env[:name].to_s == rails_env_name.to_s

            store = (env[:notable] || {})["cache_store"]
            next unless store && !store.match?(PROCESS_STORES)

            # The store's name; its options are the env_config section's to show, unshortened.
            "- #{env[:name]}: `#{store[/\A:\w+/] || store}` (`#{env[:file]}`)"
          end
        end

        # Solid Cache answers #stats from its databases, one per shard, and
        # connecting to a SQLite file that is not there creates it.
        def cache_database_missing(cache)
          return unless defined?(::SolidCache::Store) && cache.is_a?(::SolidCache::Store)

          cache.with_each_connection do
            config = ::SolidCache::Record.connection_db_config
            AppDatabases.present!(config.name, config)
          end
          nil
        rescue AppDatabases::Missing => e
          e.message
        end

        def gather_cache
          cache = Rails.cache
          lines = [ "## Cache", "" ]
          lines << "**Store:** #{cache.class.name.delete_prefix("ActiveSupport::Cache::")}, this MCP server process's `Rails.cache` (#{rails_env_name})"

          if (missing = cache_database_missing(cache))
            lines << "_#{missing}_"
          elsif cache.respond_to?(:stats)
            cache_stat_lines(cache.stats).each { |line| lines << line }
          elsif cache.respond_to?(:redis)
            begin
              info = cache.redis.info("stats")
              hits = info["keyspace_hits"].to_i
              misses = info["keyspace_misses"].to_i
              total = hits + misses
              hit_rate = RailsAiContext::Percent.floor(hits, total)
              lines << "**Hit rate:** #{hit_rate}% (#{count_phrase(hits, "hit")}, #{count_phrase(misses, "miss")})"
              lines << "**Memory:** #{cache.redis.info("memory")["used_memory_human"]}"
            rescue => e
              lines << "_Redis stats not available: #{e.message}_"
            end
          elsif defined?(ActiveSupport::Cache::MemoryStore) && cache.is_a?(ActiveSupport::Cache::MemoryStore)
            # MemoryStore has no #stats method - its own #inspect is where the
            # entry count and byte size live. Read the numbers out of it; the
            # string itself is an object dumped into prose.
            shape = cache.inspect
            lines << "**Entries:** #{shape[/entries=(\d+)/, 1] || "unknown"}"
            lines << "**Size:** #{shape[/size=(\d+)/, 1] || "unknown"} bytes"
          else
            lines << "_Stats not available for #{cache.class.name}. Supported: Redis, MemoryStore._"
          end

          lines << "" << cache_scope(cache)
          elsewhere = configured_elsewhere
          if elsewhere.any?
            options = pointer("rails_get_env_config", %(environment:"..."), "shows each one's options.")
            lines.push("", "**The app's cache in other environments:**", *elsewhere, *("_#{options}_" if options))
          end

          lines << ""
          lines
        rescue => e
          [ "## Cache", "", "_Not available: #{e.message}_", "" ]
        end

        # ── Jobs section ─────────────────────────────────────────────────

        def gather_jobs(detail)
          lines = [ "## Background Jobs", "" ]

          # Active Job adapter
          adapter_name = begin
            name = ActiveJob::Base.queue_adapter_name
            name.empty? ? "not configured" : name
          rescue => e
            RailsAiContext.debug_fail(e, "not available", label: "gather_jobs")
          end
          lines << "**Adapter:** #{adapter_name}"

          # Sidekiq stats (if available)
          if defined?(Sidekiq)
            begin
              require "sidekiq/api"
              stats = Sidekiq::Stats.new
              lines << "**Enqueued:** #{stats.enqueued}"
              lines << "**Processed:** #{stats.processed}"
              lines << "**Failed:** #{stats.failed}"
              lines << "**Scheduled:** #{stats.scheduled_size}"
              lines << "**Retries:** #{stats.retry_size}"
              lines << "**Dead:** #{stats.dead_size}"

              if RailsAiContext::DetailLevel.full?(detail)
                queues = Sidekiq::Queue.all
                if queues.any?
                  lines << "" << "### Queues"
                  lines << "| Queue | Size | Latency |"
                  lines << "|-------|------|---------|"
                  queues.each do |q|
                    lines << "| #{q.name} | #{q.size} | #{q.latency.round(1)}s |"
                  end
                end
              end
            rescue => e
              lines << "_Sidekiq stats error: #{e.message}_"
            end
          else
            # Name the adapter the app actually uses so "no stats" reads as a
            # tool limitation, not as the app having no queue backend.
            if adapter_name.start_with?("not ")
              lines << "_Queue stats unavailable: no queue adapter detected._"
            else
              lines << "_Live queue stats are only implemented for Sidekiq; this app uses the #{adapter_name} adapter._"
            end
          end

          lines << ""
          lines
        rescue => e
          [ "## Background Jobs", "", "_Not available: #{e.message}_", "" ]
        end
      end
    end
  end
end
