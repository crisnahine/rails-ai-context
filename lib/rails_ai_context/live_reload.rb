# frozen_string_literal: true

module RailsAiContext
  # Keeps a long-lived MCP server truthful: when the app changes, drop the
  # tool caches and tell connected clients to re-query. The loop - watch
  # list, fingerprint gate, code reload - is ChangeWatch's; this supplies
  # the non-blocking background behavior, the debounce, and the
  # cache-and-notify reaction. A missing `listen` gem raises out of start;
  # Server#maybe_start_live_reload owns that policy.
  class LiveReload
    include CountPhrase

    attr_reader :app, :mcp_server

    def initialize(app, mcp_server)
      @app = app
      @mcp_server = mcp_server
      @watch = ChangeWatch.new(app)
    end

    # Start the file watcher in a background thread. Non-blocking.
    def start
      dirs = @watch.watched_dirs
      if dirs.empty?
        $stderr.puts "[rails-ai-context] Live reload: no watchable directories found"
        return
      end

      debounce = RailsAiContext.configuration.live_reload_debounce
      $stderr.puts "[rails-ai-context] Live reload enabled (debounce: #{debounce}s)"
      $stderr.puts "[rails-ai-context] Watching: #{dirs.map { |d| d.sub("#{app.root}/", "") }.join(", ")}"

      @watch.start(debounce: debounce) { |paths, reloaded| react(paths, reloaded) }
    end

    # Stop the background listener thread.
    def stop
      @watch.stop
    end

    # Run a batch of changed paths through the shared gate. Public for
    # testability - specs drive this instead of a real Listen thread.
    def handle_change(changed_paths = [])
      @watch.gate(changed_paths) { |paths, reloaded| react(paths, reloaded) }
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
        when %r{app/javascript}      then "JavaScript file"
        when %r{config/routes}       then "route"
        when %r{config/}             then "config"
        when %r{db/migrate}          then "migration"
        when %r{db/}                 then "database"
        when %r{lib/tasks}           then "rake task"
        else                              "file"
        end

        categories[category] += 1
      end

      categories
    end

    # Build a readable summary like "Files changed: 2 models, 1 controller."
    def format_change_message(categories)
      parts = categories.map { |cat, count| count_phrase(count, cat) }
      "Files changed: #{parts.join(", ")}."
    end

    private

    # The gate already reloaded the app's code; dropping the caches after
    # that order is what keeps the server from answering with constants
    # Rails autoloaded at boot.
    def react(paths, reloaded)
      Tools::BaseTool.reset_all_caches!

      message = format_change_message(categorize_changes(paths))

      mcp_server.notify_resources_list_changed
      mcp_server.notify_log_message(
        data: "#{message} Tool caches invalidated#{reloaded ? " and app code reloaded" : ""}.",
        level: "info",
        logger: "rails-ai-context"
      )

      $stderr.puts "[rails-ai-context] #{message} Tool caches invalidated#{reloaded ? " and app code reloaded" : ""}."
    rescue => e
      $stderr.puts "[rails-ai-context] Live reload error: #{e.message}"
    end
  end
end
