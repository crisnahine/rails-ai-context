# frozen_string_literal: true

module RailsAiContext
  # Regenerates context files when the app changes. The loop - watch list,
  # fingerprint gate - is ChangeWatch's; this supplies the blocking
  # foreground behavior, the code reload and the regeneration. Interactive
  # by nature, so it also gets the one-time legacy-files prompt the
  # server-side reload deliberately skips.
  class Watcher
    RESULT_LINES = {
      written: "Updated: %s",
      skipped: "Unchanged: %s",
      not_applicable: "Not applicable: %s (%s)"
    }.freeze

    # How often the main thread looks for a change Listen queued.
    POLL_SECONDS = 0.25

    attr_reader :app

    # `place:` names the app root as the person who started the watch typed
    # it, when they typed it outside the root, so the files it reports are
    # named from there.
    def initialize(app = nil, place: nil)
      @app = app || RailsAiContext.default_app
      @place = place
      @watch = ChangeWatch.new(@app)
      @changes = Thread::Queue.new
    end

    def start
      root = app.root.to_s
      dirs = @watch.watched_dirs

      if dirs.empty?
        $stderr.puts "[rails-ai-context] No watchable directories found"
        return
      end

      # One-time v5.0.0 legacy UI-pattern files warning (warn_only: no prompt in watch mode)
      LegacyCleanup.prompt_legacy_files(
        RailsAiContext.configuration.ai_tools,
        root: root,
        warn_only: true,
        place: @place
      )

      # Listen's thread only queues the change (see ChangeWatch#gate); the
      # reload and the regeneration run here, on the main thread.
      listener = @watch.start { |paths| @changes << paths }
      return unless listener

      # After the listener, not before: the banner is only true once a watch
      # is running, and a missing `listen` or an empty watch list starts none.
      $stderr.puts "[rails-ai-context] Watching for changes..."
      $stderr.puts "[rails-ai-context] Directories: #{dirs.map { |d| d.sub("#{root}/", '') }.join(', ')}"

      loop do
        reload_and_regenerate if change_queued?
        sleep POLL_SECONDS
      rescue Interrupt
        $stderr.puts "\n[rails-ai-context] Stopping watcher..."
        @watch.stop
        break
      end
    rescue LoadError
      $stderr.puts "Error: The `listen` gem is required for watch mode."
      # A standalone install reaches an installed listen; the app's Gemfile
      # is the place only when the gem itself is in it.
      if InstallMode.standalone?
        $stderr.puts "Install it:  gem install listen"
      else
        $stderr.puts "Add to your Gemfile:  gem 'listen', group: :development"
      end
      exit 1
    end

    # Run one change batch through the shared gate and answer it, as the
    # main loop does. Public for testability - specs drive this instead of a
    # real Listen thread.
    def handle_change(paths = [])
      @watch.gate(paths) { |changed| @changes << changed }
      reload_and_regenerate if change_queued?
    end

    private

    # A non-blocking pop, since Queue#pop(timeout:) is Ruby 3.2+. One
    # regeneration answers every batch queued so far.
    def change_queued?
      @changes.pop(true)
      @changes.clear
      true
    rescue ThreadError
      false
    end

    # Regenerating without reloading rewrote the files from the constants the
    # watcher booted with, so a model added while it ran never appeared.
    def reload_and_regenerate
      CodeReloader.reload!
      regenerate
    end

    # A SyntaxError or LoadError from the app's code is the app's, not a
    # missing `listen`: on the main thread it would reach start's rescue.
    def regenerate
      $stderr.puts "[rails-ai-context] Changes detected, regenerating context files..."
      # No format: the configured selection decides, so a watcher no longer
      # rewrites every tool's files for a user who picked one, and writes
      # nothing at all under an MCP-only install.
      result = RailsAiContext.generate_context
      ContextFileReport.each_line(result, RESULT_LINES, root: app.root, place: @place) { |_bucket, text| $stderr.puts "  #{text}" }
    rescue StandardError, ScriptError => e
      $stderr.puts "[rails-ai-context] Error regenerating: #{e.message}"
    end
  end
end
