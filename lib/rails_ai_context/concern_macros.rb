# frozen_string_literal: true

module RailsAiContext
  # One answer to "what did this class's concerns declare".
  #
  # A model or controller file names the modules it mixes in, and those files
  # are on disk and parse the same way; only the walk stopped at the one file.
  # So a model whose associations all live in concerns answered `0 assoc` in
  # the static tier while the booted tier read 68 off reflection.
  module ConcernMacros
    MAX_DEPTH = 3

    # One walk's state. The root, the directories, the keys and the cache are
    # fixed for the run and `seen`, `collected` and `unresolved` accumulate
    # across it, so they belong to the run rather than to every call.
    class Run
      attr_reader :unresolved

      # The default block belongs to the walk. Once the entries leave it, a
      # caller reading a key the walk never produced would grow one.
      def collected
        {}.merge(@collected)
      end

      def initialize(root, dirs, keys, cache)
        @root = root
        @dirs = dirs
        @keys = keys
        @cache = cache
        @seen = Set.new
        @collected = Hash.new { |hash, key| hash[key] = [] }
        @unresolved = []
      end

      def walk(names, within, depth)
        return if depth.negative?

        names.each do |name|
          next unless @seen.add?(name)

          path = ConcernPaths.find_file(@root, name, within: within, dirs: @dirs)
          data = path && introspect(path)
          if data.nil?
            @unresolved << name
            next
          end

          @keys.each do |key|
            Array(data[key]).each { |entry| @collected[key] << tagged(entry, name) }
          end

          walk(ConcernMembership.from_mixins(data[:mixins]), name, depth - 1)
        end
      end

      private

      # The cache carries a file the walk could not read as well, so an app
      # where 100 models include one unreadable concern reads it once.
      def introspect(path)
        return read(path) if @cache.nil?
        return @cache[path] if @cache.key?(path)

        @cache[path] = read(path)
      end

      # A concern too big or unreadable costs its own declarations, not the
      # including class's whole entry. The size check stays in front of the
      # rescue: max_file_size can be configured above AstCache::MAX_PARSE_SIZE,
      # and the parse raises on its own limit.
      def read(path)
        return nil if File.size(path) > RailsAiContext.configuration.max_file_size

        Introspectors::SourceIntrospector.call(path)
      rescue StandardError
        nil
      end

      def tagged(entry, concern_name)
        entry.is_a?(Hash) ? entry.merge(from_concern: concern_name) : entry
      end
    end

    module_function

    # @param root [String] application root
    # @param mixins [Array<Hash>] MixinsListener records
    # @param keys [Array<Symbol>] payload keys to collect
    # @param prefer [String, nil] owner kind, so a basename two owners share
    #   resolves to this one's concerns directory
    # @param within [String, nil] the enclosing constant of the class, for a
    #   namespace-relative `include`
    # @param cache [Hash, nil] a caller-owned store keyed by concern file, so
    #   one run walks a file once however many classes include it. The caller
    #   owns its lifetime: a process-wide store would go stale, because the
    #   configured paths and the files themselves change in-process.
    # @return [Array(Hash, Array<String>)] the collected entries per key, and
    #   the names whose file could not be read
    def collect(root, mixins, keys:, prefer: nil, within: nil, cache: nil)
      names = ConcernMembership.from_mixins(mixins)
      return [ {}, [] ] if names.empty?

      # Resolved once per call and held by the run: the configured paths
      # change in-process, so a cache keyed on root goes stale with no reset
      # hook.
      run = Run.new(root.to_s, ConcernPaths.ordered_dirs(root.to_s, prefer), keys, cache)
      run.walk(names, within, MAX_DEPTH)

      [ run.collected, run.unresolved ]
    end
  end
end
