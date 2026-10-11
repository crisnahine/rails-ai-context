# frozen_string_literal: true

module RailsAiContext
  # Re-runs Rails' own code reloader so a long-lived process sees files written
  # after it booted.
  #
  # Clearing the gem's caches is not enough on its own. Introspectors reach the
  # app through constants, and the eager loading they trigger
  # (`Zeitwerk::Loader#eager_load_dir`) is idempotent per process - a directory
  # already loaded is never re-scanned, so a model added after boot stays
  # invisible for the life of the server. Routes never had the problem because
  # RouteIntrospector asks `routes_reloader.execute_if_updated` every call.
  module CodeReloader
    # What a process that cannot reload has loaded: each Ruby file under the
    # app's autoload paths, with its stat as loaded - when a server started,
    # or when Zeitwerk loaded it later. `files` is nil until a server tracks.
    LOADED_CODE = { mutex: Mutex.new, files: nil, root: nil, hooked: false }

    module_function

    # Reload the app's autoloaded code. Returns whether a reload actually ran,
    # so callers can say what they did instead of guessing.
    def reload!
      return false unless reloadable?

      Rails.application.reloader.reload!
      true
    rescue StandardError, ScriptError => e
      # A broken file mid-edit is the common case. Zeitwerk reloads by
      # unload-then-setup, so a raise can leave constants already unloaded -
      # they re-autoload lazily on next reference. Either way a running server
      # must survive it.
      $stderr.puts "[rails-ai-context] code reload failed: #{e.class}: #{e.message}" if ENV["DEBUG"]
      false
    end

    # Run a block with the sharing lock held, so a reload cannot unload
    # constants underneath it.
    #
    # `Reloader#class_unload!` takes the unload lock through
    # ActiveSupport::Dependencies.interlock, but that only blocks threads
    # holding the sharing lock - which is acquired inside `executor.wrap`.
    # Nothing here wrapped anything, so a reload on another thread could clear
    # DescendantsTracker while a tool call was midway through reading
    # `ActiveRecord::Base.descendants`, returning a short list with no
    # exception for the per-section rescue to notice.
    #
    # Only taken when a reload could actually happen; everywhere else this is
    # a plain yield.
    def with_app_code
      return yield unless reloadable?

      app = Rails.application
      return yield unless app.respond_to?(:executor)

      app.executor.wrap { yield }
    end

    # Whether this thread is inside a unit of work the app's executor wraps:
    # a request the app itself serves, through the middleware or the engine.
    # Rails' reloader runs at the start of one, so reloading again inside it
    # would repeat that work.
    def inside_app_executor?
      return false unless reloadable?

      app = Rails.application
      app.respond_to?(:executor) && app.executor.active?
    rescue StandardError
      false
    end

    # `enable_reloading` is the flag that decides whether Rails unloads
    # anything: with it off, the finisher registers no class_unload callback,
    # so `reload!` runs the prepare callbacks and returns having reloaded
    # nothing. Gating on `eager_load` instead reported success for every
    # eager_load=false + cache_classes=true environment (stock `test`, a
    # cache-classes staging container) - a reload that never happened,
    # announced as one.
    def reloadable?
      return false if RailsAiContext.static_tier?
      return false unless defined?(Rails) && Rails.respond_to?(:application)

      app = Rails.application
      return false unless app.respond_to?(:reloader) && app.respond_to?(:config)

      config = app.config
      # Rails 7.1+ names it enable_reloading; older releases only have
      # cache_classes, which is its inverse.
      return config.enable_reloading if config.respond_to?(:enable_reloading)
      return !config.cache_classes if config.respond_to?(:cache_classes)

      false
    rescue StandardError
      false
    end

    # A server that cannot reload - RAILS_ENV=test, or production with eager
    # loading - answers from the code it loaded for as long as it runs, so
    # it notes what it loaded, to name an edit since (changed_code). A file
    # Zeitwerk loads later is noted as it loads, so an edit made before then
    # is not stale. A server that can reload has no need.
    def track_loaded_code!
      return if reloadable? || RailsAiContext.static_tier?

      root = Rails.root.to_s
      files = code_files(root).to_h { |file| [ file, code_stat(file) ] }
      hook = LOADED_CODE[:mutex].synchronize do
        LOADED_CODE[:root] ||= root
        LOADED_CODE[:files] ||= files
        !LOADED_CODE[:hooked] && (LOADED_CODE[:hooked] = true)
      end
      loader = Rails.autoloaders.main
      loader.on_load { |_cpath, _value, abspath| code_loaded(abspath) } if hook && loader.respond_to?(:on_load)
    rescue StandardError => e
      RailsAiContext.debug_fail(e, nil, label: "track_loaded_code!")
    end

    # The app's Ruby files that are not what this process loaded: edited or
    # removed since it loaded them, or added since its server started, which
    # no autoload reaches without a reload. Relative to the app's root,
    # sorted; empty unless tracked.
    def changed_code
      known, root = LOADED_CODE[:mutex].synchronize { [ LOADED_CODE[:files]&.dup, LOADED_CODE[:root] ] }
      return [] unless known

      loaded = $LOADED_FEATURES.to_set
      edited = known.select { |file, stat| loaded.include?(file) && code_stat(file) != stat }.keys
      added = code_files(root) - known.keys
      (edited + added).map { |file| file.delete_prefix("#{root}/") }.sort
    rescue StandardError => e
      RailsAiContext.debug_fail(e, [], label: "changed_code")
    end

    # Bootsnap's compile cache knows a file by its size and the second of its
    # mtime, so a file written again within that second at the same size has
    # its code served as it was before the write: on the reload the write
    # set off, and on every boot after, until the file is written in another
    # second. Bootsnap has no way to drop one entry, and nothing here moves
    # the app's own files' stat, so each answer names them instead
    # (BaseTool.stale_code_note). Of the files a look found rewritten so
    # (Fingerprinter::Snapshot#same_stat_rewrites), the ones this process
    # loads code from: its autoload paths and routes files. Relative to the
    # app's root, sorted; empty where Bootsnap's compile cache is off.
    def compile_cached(files)
      return [] if files.empty? || !bootsnap_compile_cache?

      root = Rails.root.to_s
      dirs = code_dirs(root)
      routes = Rails.application.routes_reloader.paths.map(&:to_s)
      files.select { |file| file.end_with?(".rb") && (routes.include?(file) || dirs.any? { |dir| file.start_with?("#{dir}/") }) }
        .map { |file| file.delete_prefix("#{root}/") }.sort
    rescue StandardError => e
      RailsAiContext.debug_fail(e, [], label: "compile_cached")
    end

    # Bootsnap answers Ruby's load_iseq hook, which every require and load
    # asks, once its compile cache is set up; DISABLE_BOOTSNAP_COMPILE_CACHE
    # leaves the hook unset.
    def bootsnap_compile_cache?
      defined?(Bootsnap::CompileCache::ISeq) && defined?(RubyVM::InstructionSequence) &&
        RubyVM::InstructionSequence.respond_to?(:load_iseq) ? true : false
    end

    # Zeitwerk calls this inside the require, so it only records.
    def code_loaded(abspath)
      root = LOADED_CODE[:root]
      return unless root && abspath.end_with?(".rb") && abspath.start_with?("#{root}/")

      stat = code_stat(abspath)
      LOADED_CODE[:mutex].synchronize { LOADED_CODE[:files]&.store(abspath, stat) }
    rescue StandardError
      nil
    end

    def code_files(root)
      code_dirs(root).flat_map { |dir| Dir.glob(File.join(dir, "**", "*.rb")) }.uniq
    end

    # The app's own autoload paths, not an engine's in a gem.
    def code_dirs(root)
      dirs = ActiveSupport::Dependencies.autoload_paths + ActiveSupport::Dependencies.autoload_once_paths
      dirs.map(&:to_s).select { |dir| dir.start_with?("#{root}/") }.uniq
    end

    def code_stat(file)
      stat = File.stat(file)
      [ stat.mtime.to_i, stat.mtime.nsec, stat.size, stat.ino ]
    rescue SystemCallError
      nil
    end
    private_class_method :code_loaded, :code_files, :code_dirs, :code_stat
  end
end
