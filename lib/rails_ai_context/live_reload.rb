# frozen_string_literal: true

module RailsAiContext
  # Tells connected clients when the app changed, so they re-query. Answers
  # do not wait on it: each call checks the files itself before it reads
  # anything (BaseTool.refresh_if_files_changed!). The loop - watch list,
  # fingerprint gate - is ChangeWatch's; this supplies the non-blocking
  # background behavior, the debounce, and the notification. A missing
  # `listen` gem raises out of start; Server#maybe_start_live_reload owns
  # that policy.
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
      listener = @watch.start(debounce: debounce) { |paths| react(paths) }
      return unless listener

      # After the listener, not before: these lines are only true once a
      # watch is running, and a missing `listen` starts none.
      $stderr.puts "[rails-ai-context] Live reload enabled (debounce: #{debounce}s)"
      $stderr.puts "[rails-ai-context] Watching: #{dirs.map { |d| d.sub("#{app.root}/", "") }.join(", ")}"

      listener
    end

    # Stop the background listener thread.
    def stop
      @watch.stop
    end

    # Run a batch of changed paths through the shared gate. Public for
    # testability - specs drive this instead of a real Listen thread.
    def handle_change(changed_paths = [])
      @watch.gate(changed_paths) { |paths| react(paths) }
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

    # On Listen's thread, so it loads no app code (see ChangeWatch#gate), and
    # it drops no cache either: the first call after the edit already did,
    # when it checked the files, or the next one will. A reload or a drop
    # here would only repeat that call's work, a full introspection a second
    # and a half after every edit.
    def react(paths)
      message = format_change_message(categorize_changes(paths))
      unless CodeReloader.reloadable?
        message += " RAILS_ENV=#{RailsAiContext.environment_name} does not reload code, so what reflection reads stays as of boot."
      end

      mcp_server.notify_resources_list_changed
      mcp_server.notify_log_message(data: message, level: "info", logger: "rails-ai-context")

      $stderr.puts "[rails-ai-context] #{message}"
    rescue => e
      $stderr.puts "[rails-ai-context] Live reload error: #{e.message}"
    end
  end
end
