# frozen_string_literal: true

module RailsAiContext
  # Regenerates context files when the app changes. The loop - watch list,
  # fingerprint gate, code reload - is ChangeWatch's; this supplies the
  # blocking foreground behavior and the regeneration reaction. Interactive
  # by nature, so it also gets the one-time legacy-files prompt the
  # server-side reload deliberately skips.
  class Watcher
    attr_reader :app

    def initialize(app = nil)
      @app = app || Rails.application
      @watch = ChangeWatch.new(@app)
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
        warn_only: true
      )

      $stderr.puts "[rails-ai-context] Watching for changes..."
      $stderr.puts "[rails-ai-context] Directories: #{dirs.map { |d| d.sub("#{root}/", '') }.join(', ')}"

      listener = @watch.start { |_paths, _reloaded| regenerate }
      return unless listener

      # Keep the process alive
      loop do
        sleep 1
      rescue Interrupt
        $stderr.puts "\n[rails-ai-context] Stopping watcher..."
        @watch.stop
        break
      end
    rescue LoadError
      $stderr.puts "Error: The `listen` gem is required for watch mode."
      $stderr.puts "Add to your Gemfile:  gem 'listen', group: :development"
      exit 1
    end

    # Run one change batch through the shared gate. Public for testability -
    # specs drive this instead of a real Listen thread.
    def handle_change(paths = [])
      @watch.gate(paths) { |_paths, _reloaded| regenerate }
    end

    private

    def regenerate
      $stderr.puts "[rails-ai-context] Changes detected, regenerating context files..."
      result = RailsAiContext.generate_context(format: :all)
      result[:written].each { |f| $stderr.puts "  Updated: #{f}" }
      result[:skipped].each { |f| $stderr.puts "  Unchanged: #{f}" }
    rescue => e
      $stderr.puts "[rails-ai-context] Error regenerating: #{e.message}"
    end
  end
end
