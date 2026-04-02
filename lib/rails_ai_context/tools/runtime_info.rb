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
          detail: {
            type: "string",
            enum: %w[summary standard full],
            description: "Detail level. summary: one-line per section. standard: tables with sizes (default). full: index usage + cache details."
          },
          section: {
            type: "string",
            enum: %w[database cache jobs connections],
            description: "Filter to one section. Omit for all sections."
          }
        }
      )

      annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: false, open_world_hint: false)

      def self.call(detail: "standard", section: nil, server_context: nil)
        lines = [ "# Runtime Info", "" ]

        sections = section ? [ section ] : %w[connections database cache jobs]

        sections.each do |s|
          result = case s
          when "connections" then gather_connection_pool
          when "database"    then gather_database(detail)
          when "cache"       then gather_cache
          when "jobs"        then gather_jobs(detail)
          end
          lines.concat(result) if result&.any?
        end

        if lines.size <= 2
          lines << "_No runtime data available. Ensure the app has a database connection._"
        end

        text_response(lines.join("\n"))
      rescue => e
        text_response("Runtime info error: #{e.message}")
      end

      class << self
        private

        # ── Connection pool ──────────────────────────────────────────────

        def gather_connection_pool
          stat = ActiveRecord::Base.connection_pool.stat
          lines = [ "## Connection Pool", "" ]
          lines << "| Metric | Value |"
          lines << "|--------|-------|"
          lines << "| Pool size | #{stat[:size]} |"
          lines << "| Connections | #{stat[:connections]} |"
          lines << "| Busy | #{stat[:busy]} |"
          lines << "| Idle | #{stat[:idle]} |"
          lines << "| Dead | #{stat[:dead]} |"
          lines << "| Waiting | #{stat[:waiting]} |"
          lines << "| Checkout timeout | #{stat[:checkout_timeout]}s |"

          utilization = stat[:size] > 0 ? ((stat[:busy].to_f / stat[:size]) * 100).round : 0
          lines << "" << "Pool utilization: #{utilization}%"
          lines << "**Warning:** Pool is full (#{stat[:busy]}/#{stat[:size]} busy, #{stat[:waiting]} waiting)" if stat[:waiting] > 0
          lines << ""
          lines
        rescue => e
          [ "## Connection Pool", "", "_Not available: #{e.message}_", "" ]
        end

        # ── Database section ─────────────────────────────────────────────

        def gather_database(detail) # rubocop:disable Metrics
          conn = ActiveRecord::Base.connection
          adapter = conn.adapter_name.downcase
          lines = [ "## Database", "" ]
          lines << "**Adapter:** #{conn.adapter_name}"

          # Table sizes
          sizes = gather_table_sizes(conn, adapter)
          if sizes&.any?
            lines << "" << "### Table Sizes"
            lines << "| Table | Size |"
            lines << "|-------|------|"
            sizes.first(detail == "summary" ? 5 : 30).each do |row|
              lines << "| #{row[:name]} | #{format_bytes(row[:bytes])} |"
            end
            total = sizes.sum { |r| r[:bytes] }
            lines << "| **Total** | **#{format_bytes(total)}** |"
            lines << "_#{sizes.size - 30} more tables..._" if detail != "summary" && sizes.size > 30
          end

          # Pending migrations
          pending = gather_pending_migrations
          if pending
            if pending.empty?
              lines << "" << "**Migrations:** all up to date"
            else
              lines << "" << "**Pending migrations:** #{pending.size}"
              pending.each { |m| lines << "- #{m}" }
            end
          end

          # Index usage (full detail only)
          if detail == "full"
            index_usage = gather_index_usage(conn, adapter)
            if index_usage&.any?
              lines << "" << "### Index Usage"
              unused = index_usage.select { |i| i[:scans] == 0 }
              if unused.any?
                lines << "**Unused indexes (0 scans):**"
                unused.first(10).each { |i| lines << "- `#{i[:index]}` on `#{i[:table]}`" }
              end
              hot = index_usage.sort_by { |i| -(i[:scans] || 0) }.first(5)
              lines << "" << "**Most used indexes:**"
              hot.each { |i| lines << "- `#{i[:index]}` on `#{i[:table]}` — #{i[:scans]} scans" }
            end
          end

          lines << ""
          lines
        rescue => e
          [ "## Database", "", "_Not available: #{e.message}_", "" ]
        end

        def gather_table_sizes(conn, adapter)
          case adapter
          when /postgresql/
            sql = "SELECT relname AS name, pg_total_relation_size(relid) AS bytes FROM pg_stat_user_tables ORDER BY bytes DESC"
            conn.select_all(sql).map { |r| { name: r["name"], bytes: r["bytes"].to_i } }
          when /mysql/
            sql = "SELECT table_name AS name, (data_length + index_length) AS bytes FROM INFORMATION_SCHEMA.TABLES WHERE table_schema = DATABASE() ORDER BY bytes DESC"
            conn.select_all(sql).map { |r| { name: r["name"], bytes: r["bytes"].to_i } }
          when /sqlite/
            # Try dbstat virtual table first, fall back to whole-DB size
            begin
              result = conn.select_all("SELECT name, SUM(pgsize) AS bytes FROM dbstat GROUP BY name ORDER BY bytes DESC")
              return result.map { |r| { name: r["name"], bytes: r["bytes"].to_i } } if result.any?
            rescue => e
              $stderr.puts "[rails-ai-context] gather_table_sizes failed: #{e.message}" if ENV["DEBUG"]
              nil
            end
            # Fallback: whole database size
            page_count = conn.select_value("PRAGMA page_count").to_i
            page_size = conn.select_value("PRAGMA page_size").to_i
            total = page_count * page_size
            tables = conn.select_values("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name")
            tables.map { |t| { name: t, bytes: total / [ tables.size, 1 ].max } }
          else
            nil
          end
        rescue => e
          $stderr.puts "[rails-ai-context] gather_table_sizes failed: #{e.message}" if ENV["DEBUG"]
          nil
        end

        def gather_pending_migrations
          migrate_dir = File.join(Rails.root, "db/migrate")
          return nil unless Dir.exist?(migrate_dir)

          context = ActiveRecord::MigrationContext.new(migrate_dir)
          pending = if context.respond_to?(:pending_migrations)
            context.pending_migrations
          else
            ActiveRecord::Migrator.new(:up, context.migrations).pending_migrations
          end
          pending.map { |m| "#{m.version} — #{m.name}" }
        rescue => e
          $stderr.puts "[rails-ai-context] gather_pending_migrations failed: #{e.message}" if ENV["DEBUG"]
          nil
        end

        def gather_index_usage(conn, adapter)
          case adapter
          when /postgresql/
            sql = "SELECT relname AS table, indexrelname AS index, idx_scan AS scans FROM pg_stat_user_indexes ORDER BY idx_scan ASC"
            conn.select_all(sql).map { |r| { table: r["table"], index: r["index"], scans: r["scans"].to_i } }
          else
            nil
          end
        rescue => e
          $stderr.puts "[rails-ai-context] gather_index_usage failed: #{e.message}" if ENV["DEBUG"]
          nil
        end

        # ── Cache section ────────────────────────────────────────────────

        def gather_cache
          cache = Rails.cache
          lines = [ "## Cache", "" ]
          lines << "**Store:** #{cache.class.name.demodulize}"

          if cache.respond_to?(:stats)
            stats = cache.stats
            lines << "**Stats:** #{stats.inspect}"
          elsif cache.respond_to?(:redis)
            begin
              info = cache.redis.info("stats")
              hits = info["keyspace_hits"].to_i
              misses = info["keyspace_misses"].to_i
              total = hits + misses
              hit_rate = total > 0 ? ((hits.to_f / total) * 100).round(1) : 0
              lines << "**Hit rate:** #{hit_rate}% (#{hits} hits, #{misses} misses)"
              lines << "**Memory:** #{cache.redis.info("memory")["used_memory_human"]}"
            rescue => e
              lines << "_Redis stats not available: #{e.message}_"
            end
          else
            lines << "_Stats not available for #{cache.class.name}. Supported: Redis, MemoryStore._"
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
            $stderr.puts "[rails-ai-context] gather_jobs failed: #{e.message}" if ENV["DEBUG"]
            "not available"
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

              if detail == "full"
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
            lines << "_Sidekiq not loaded. Queue stats unavailable._"
          end

          lines << ""
          lines
        rescue => e
          [ "## Background Jobs", "", "_Not available: #{e.message}_", "" ]
        end

        # ── Helpers ──────────────────────────────────────────────────────

        def format_bytes(bytes)
          return "0 B" if bytes.nil? || bytes == 0
          if bytes >= 1_073_741_824
            "#{(bytes / 1_073_741_824.0).round(1)} GB"
          elsif bytes >= 1_048_576
            "#{(bytes / 1_048_576.0).round(1)} MB"
          elsif bytes >= 1024
            "#{(bytes / 1024.0).round(1)} KB"
          else
            "#{bytes} B"
          end
        end
      end
    end
  end
end
