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
      SafePath.outermost(Fingerprinter.watched_dirs(@app.root.to_s) + Fingerprinter.manifest_dirs(@app.root.to_s))
    end

    # Wires Listen to the watched directories and runs every change batch
    # through the gate. Returns the listener, or nil when nothing is
    # watchable.
    def start(debounce: nil, &reaction)
      require "listen"

      dirs = watched_dirs
      return nil if dirs.empty?

      options = debounce ? { wait_for_delay: debounce } : {}
      options[:ignore] = ignored(dirs)
      # shortcut: Listen takes directories only and inotify would recurse the whole root (node_modules too), so an edit to a file at the root the fingerprint reads (Gemfile, Dockerfile) or in a frontend root waits for the next change in a watched directory; watch the root once Listen can watch single files.
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

    # Listen matches an ignore pattern against a path relative to each watched folder, so a pruned folder is ignored by
    # its spelling below the one holding it.
    # The same spelling below another watched folder is ignored there too, which is harmless: it ends in node_modules or
    # vendor/bundle, so it is pruned there as well, or sits outside every autoload root, where no look reads Ruby.
    # shortcut: a folder pruned after start is watched until a restart; read pruned_dirs again on a new folder if that bites.
    def ignored(dirs)
      Fingerprinter.pruned_dirs(@app.root.to_s).flat_map do |pruned|
        dirs.select { |dir| SafePath.contained?(pruned, dir) && pruned != dir }
            .map { |dir| %r{\A#{Regexp.escape(pruned.delete_prefix("#{dir}/"))}(?:/|\z)} }
      end.uniq
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
