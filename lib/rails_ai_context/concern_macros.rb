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

    module_function

    # @param root [String] application root
    # @param mixins [Array<Hash>] MixinsListener records
    # @param keys [Array<Symbol>] payload keys to collect
    # @param prefer [String, nil] owner kind, so a basename two owners share
    #   resolves to this one's concerns directory
    # @param within [String, nil] the enclosing constant of the class, for a
    #   namespace-relative `include`
    # @return [Array(Hash, Array<String>)] the collected entries per key, and
    #   the names whose file could not be read
    def collect(root, mixins, keys:, prefer: nil, within: nil, depth: MAX_DEPTH)
      names = ConcernMembership.from_mixins(mixins)
      return [ {}, [] ] if names.empty?

      # Resolved once per call and threaded through the recursion: the
      # configured paths change in-process, so a cache keyed on root goes
      # stale with no reset hook.
      dirs = ConcernPaths.ordered_dirs(root.to_s, prefer)
      collected = Hash.new { |hash, key| hash[key] = [] }
      unresolved = []

      walk(names, root.to_s, dirs, keys, within, depth, Set.new, collected, unresolved)

      [ collected, unresolved ]
    end

    def walk(names, root, dirs, keys, within, depth, seen, collected, unresolved)
      return if depth.negative?

      names.each do |name|
        next unless seen.add?(name)

        path = ConcernPaths.find_file(root, name, within: within, dirs: dirs)
        if path.nil? || File.size(path) > RailsAiContext.configuration.max_file_size
          unresolved << name
          next
        end

        data = Introspectors::SourceIntrospector.call(path)
        keys.each do |key|
          Array(data[key]).each { |entry| collected[key] << tagged(entry, name) }
        end

        walk(ConcernMembership.from_mixins(data[:mixins]), root, dirs, keys, name, depth - 1, seen, collected, unresolved)
      end
    end

    def tagged(entry, concern_name)
      entry.is_a?(Hash) ? entry.merge(from_concern: concern_name) : entry
    end
  end
end
