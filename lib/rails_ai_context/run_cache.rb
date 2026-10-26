# frozen_string_literal: true

module RailsAiContext
  # Answers kept for one introspection run and dropped when it ends. A file
  # list or a stat asked by every section is answered once, and nothing
  # outlives the run, so an MCP tool called later still sees files added since.
  module RunCache
    KEY = :rails_ai_context_run_cache

    module_function

    # A nested run shares the outer one's answers; the outer one drops them.
    def around
      return yield if Thread.current[KEY]

      begin
        Thread.current[KEY] = {}
        yield
      ensure
        Thread.current[KEY] = nil
      end
    end

    # A run against one app: the shared answers, and a static app's own inflections.
    def around_app(*app, &block)
      around { PathResolver.scoped_to(app.first) { AppInflections.around(*app, &block) } }
    end

    # What an open run holds was read before this moment; the run goes on empty.
    def clear
      Thread.current[KEY]&.clear
    end

    def active?
      !Thread.current[KEY].nil?
    end

    class << self
      # Set by a server: keeps a value past the run for as long as the context it holds is fresh.
      attr_accessor :keeper
    end

    # A value read from the app's files that a server may keep across calls; elsewhere it lasts the run.
    def kept(key, &read)
      fetch(key) { RunCache.keeper ? RunCache.keeper.call(key, &read) : yield }
    end

    # An answer kept per object and key, found by the object's identity so a tree stays the one read.
    def fetch_for(name, object, key)
      held = (fetch([ name ]) { {}.compare_by_identity }[object] ||= {})
      held.key?(key) ? held[key] : (held[key] = yield)
    end

    # Outside a run the block answers every time.
    def fetch(key)
      store = Thread.current[KEY]
      return yield unless store
      return store[key] if store.key?(key)

      store[key] = yield
    end
  end
end
