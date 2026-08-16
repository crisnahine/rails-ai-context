# frozen_string_literal: true

module RailsAiContext
  # Notices that the app actually changed: the watch list, the Listen
  # wiring, the fingerprint gate and the code reload, stated once. Watcher
  # and LiveReload were two implementations of this loop that differed only
  # in their reaction, and the copies had grown apart where nobody chose -
  # different watch lists, and a fingerprint gate maintained twice.
  #
  # The caller supplies the reaction (regenerate files, or refresh caches
  # and notify clients) and its own policy for a missing `listen` gem -
  # start raises LoadError so a CLI can exit and a server can downgrade.
  class ChangeWatch
    # The union the two watchers had converged on, one home. config and db
    # cover their subdirectories; the app/ entries mirror what the
    # fingerprint reads.
    WATCH_DIRS = %w[
      app/models app/controllers app/views app/jobs app/mailers
      app/channels app/components app/helpers app/services
      app/javascript/controllers app/middleware
      config db lib/tasks
    ].freeze

    def initialize(app)
      @app = app
      @last_fingerprint = Fingerprinter.compute(app)
    end

    def watched_dirs
      root = @app.root.to_s
      WATCH_DIRS.map { |p| File.join(root, p) }.select { |d| Dir.exist?(d) }
    end

    # Wires Listen to the watched directories and runs every change batch
    # through the gate. Returns the listener, or nil when nothing is
    # watchable.
    def start(debounce: nil, &reaction)
      require "listen"

      dirs = watched_dirs
      return nil if dirs.empty?

      options = debounce ? { wait_for_delay: debounce } : {}
      @listener = Listen.to(*dirs, **options) do |modified, added, removed|
        changed = modified + added + removed
        next if changed.empty?

        gate(changed, &reaction)
      end
      @listener.start
      @listener
    end

    def stop
      @listener&.stop
    end

    # The part both reactions share: nothing happened unless the fingerprint
    # moved, and the reaction sees fresh code - without the reload, a
    # reaction describes the app as it was when the watch started.
    def gate(paths, &reaction)
      return unless Fingerprinter.changed?(@app, @last_fingerprint)

      @last_fingerprint = Fingerprinter.compute(@app)
      reloaded = CodeReloader.reload!
      reaction.call(paths, reloaded)
    rescue => e
      $stderr.puts "[rails-ai-context] Change watch error: #{e.message}"
    end
  end
end
