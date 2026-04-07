# frozen_string_literal: true

require "digest"
require "concurrent"
require "prism"

module RailsAiContext
  # Thread-safe AST parse cache backed by Concurrent::Map.
  # Keyed by path + content hash + mtime — automatically invalidates
  # when file content changes. Used by all Prism-based introspectors.
  #
  # Bounded: evicts oldest entries when MAX_SIZE is exceeded.
  module AstCache
    STORE = Concurrent::Map.new
    MAX_SIZE = 500
    EVICTION_MUTEX = Mutex.new

    # Max file size for parsing (default: matches config.max_file_size).
    # Public API — callers don't need to pre-check size.
    MAX_PARSE_SIZE = 5_000_000

    # Parse a Ruby source file and cache the result.
    # Returns a Prism::ParseResult. Rejects files exceeding MAX_PARSE_SIZE.
    #
    # Reads content first, then checks size — avoids TOCTOU race where the
    # file could change between File.size and File.read.
    def self.parse(path)
      content = File.read(path)
      size = content.bytesize
      raise ArgumentError, "File too large for AST parsing: #{path} (#{size} bytes, max #{MAX_PARSE_SIZE})" if size > MAX_PARSE_SIZE

      mtime = File.mtime(path).to_i
      key   = "#{path}:#{Digest::SHA256.hexdigest(content)}:#{mtime}"

      cached = STORE[key]
      return cached if cached

      # Evict BEFORE inserting to avoid running inside compute_if_absent
      evict_if_full

      STORE.compute_if_absent(key) { Prism.parse(content) }
    end

    # Parse a Ruby source string (no caching).
    # Returns a Prism::ParseResult.
    def self.parse_string(source)
      Prism.parse(source)
    end

    # Invalidate all cached entries for a given path.
    def self.invalidate(path)
      prefix = "#{path}:"
      STORE.each_key do |k|
        STORE.delete(k) if k.start_with?(prefix)
      end
    end

    # Clear the entire cache.
    def self.clear
      STORE.clear
    end

    # Number of cached entries (for diagnostics).
    def self.size
      STORE.size
    end

    # Evict ~25% of entries when cache exceeds MAX_SIZE.
    # Synchronized to prevent multiple threads from over-evicting simultaneously.
    def self.evict_if_full
      EVICTION_MUTEX.synchronize do
        return if STORE.size < MAX_SIZE
        keys = STORE.keys
        keys.first(keys.size / 4).each { |k| STORE.delete(k) }
      end
    end
    private_class_method :evict_if_full
  end
end
