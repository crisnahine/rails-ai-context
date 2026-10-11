# frozen_string_literal: true

module RailsAiContext
  # Notices that the app actually changed: the watch list, the Listen
  # wiring and the fingerprint gate, stated once. Watcher and LiveReload
  # were two implementations of this loop that differed only in their
  # reaction, and the copies had grown apart where nobody chose - different
  # watch lists, and a fingerprint gate maintained twice.
  #
  # The caller supplies the reaction (regenerate files, or notify clients)
  # and its own policy for a missing `listen` gem - start raises LoadError so
  # a CLI can exit and a server can downgrade.
  class ChangeWatch
    def initialize(app)
      @app = app
      @mark = Fingerprinter.mark(app)
    end

    # One scope, the fingerprint's: a directory the fingerprint reads but
    # nobody watches is a change that never reaches the reaction.
    def watched_dirs
      Fingerprinter.watched_dirs(@app.root.to_s)
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
    # moved.
    #
    # It runs on Listen's thread, so neither it nor a reaction loads app
    # code: a server's calls reload it on their own threads, each after
    # checking the files itself, and `watch` hands the change to its main
    # thread.
    def gate(paths, &reaction)
      return unless Fingerprinter.stale?(@app, @mark)

      @mark = Fingerprinter.mark(@app)
      reaction.call(paths)
    rescue => e
      $stderr.puts "[rails-ai-context] Change watch error: #{e.message}"
    end
  end
end
