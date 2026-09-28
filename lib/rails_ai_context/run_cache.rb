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

    def active?
      !Thread.current[KEY].nil?
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
