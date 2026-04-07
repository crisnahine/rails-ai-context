# frozen_string_literal: true

module RailsAiContext
  # Watches for file changes and automatically invalidates MCP tool caches,
  # sending notifications to connected AI clients so they re-query fresh data.
  # Runs a background thread alongside the MCP server (stdio or HTTP).
  class LiveReload
    WATCH_DIRS = (Watcher::WATCH_PATTERNS | Fingerprinter::WATCHED_DIRS).freeze

    attr_reader :app, :mcp_server

    def initialize(app, mcp_server)
      @app = app
      @mcp_server = mcp_server
      @last_fingerprint = Fingerprinter.compute(app)
    end

    # Start the file watcher in a background thread. Non-blocking.
    def start
      require "listen"

      root = app.root.to_s
      debounce = RailsAiContext.configuration.live_reload_debounce
      dirs = WATCH_DIRS.map { |p| File.join(root, p) }.select { |d| Dir.exist?(d) }

      if dirs.empty?
        $stderr.puts "[rails-ai-context] Live reload: no watchable directories found"
        return
      end

      $stderr.puts "[rails-ai-context] Live reload enabled (debounce: #{debounce}s)"
      $stderr.puts "[rails-ai-context] Watching: #{dirs.map { |d| d.sub("#{root}/", "") }.join(", ")}"

      listener = Listen.to(*dirs, wait_for_delay: debounce) do |modified, added, removed|
        all_changes = modified + added + removed
        next if all_changes.empty?

        handle_change(all_changes)
      end

      listener.start
      @listener = listener
    end

    # Stop the background listener thread.
    def stop
      @listener&.stop
    end

    # Process a batch of file changes. Public for testability.
    def handle_change(changed_paths = [])
      return unless Fingerprinter.changed?(app, @last_fingerprint)

      @last_fingerprint = Fingerprinter.compute(app)

      # Invalidate all tool caches (includes AstCache.clear)
      Tools::BaseTool.reset_all_caches!

      # Build a human-readable change summary
      message = format_change_message(categorize_changes(changed_paths))

      # Notify connected MCP clients
      mcp_server.notify_resources_list_changed
      mcp_server.notify_log_message(
        data: "#{message} Tool caches invalidated.",
        level: "info",
        logger: "rails-ai-context"
      )

      $stderr.puts "[rails-ai-context] #{message} Tool caches invalidated."
    rescue => e
      $stderr.puts "[rails-ai-context] Live reload error: #{e.message}"
    end

    # Group changed file paths by category (model, controller, etc.)
    def categorize_changes(paths)
      categories = Hash.new(0)

      paths.each do |path|
        category = case path
        when %r{app/models}          then "model"
        when %r{app/controllers}     then "controller"
        when %r{app/views}           then "view"
        when %r{app/jobs}            then "job"
        when %r{app/mailers}         then "mailer"
        when %r{app/javascript}      then "javascript"
        when %r{config/routes}       then "route"
        when %r{config/}             then "config"
        when %r{db/migrate}          then "migration"
        when %r{db/}                 then "database"
        when %r{lib/tasks}           then "rake_task"
        else                              "file"
        end

        categories[category] += 1
      end

      categories
    end

    # Build a readable summary like "Files changed: 2 model(s), 1 controller(s)."
    def format_change_message(categories)
      parts = categories.map { |cat, count| "#{count} #{cat}(s)" }
      "Files changed: #{parts.join(", ")}."
    end
  end
end
