# frozen_string_literal: true

require "digest"
require "concurrent"
require "prism"

module RailsAiContext
  # Thread-safe AST parse cache backed by Concurrent::Map.
  # Keyed by content hash, so a file and the same text read as a string share one
  # parse, and a changed file misses. Used by all Prism-based introspectors.
  # A settled file's stat stands in for the read and hash (see RACY_WINDOW).
  #
  # Bounded: evicts entries when MAX_SIZE is exceeded, and a file's recorded
  # stat goes with its parse.
  module AstCache
    STORE = Concurrent::Map.new
    SEEN = Concurrent::Map.new # path, or [path, ruby grammar] => [stat signature, STORE key, whether the stat can be trusted]
    MAX_SIZE = 500
    EVICTION_MUTEX = Mutex.new

    # Max file size for parsing (default: matches config.max_file_size).
    # Public API - callers don't need to pre-check size.
    MAX_PARSE_SIZE = 5_000_000

    # Parse a Ruby source file and cache the result.
    # Returns a Prism::ParseResult. Rejects files exceeding MAX_PARSE_SIZE.
    #
    # Reads content first, then checks size - avoids TOCTOU race where the
    # file could change between File.size and File.read.
    #
    # `ruby:` is the Ruby version whose grammar decides what is a syntax error;
    # nil parses as the newest Ruby prism knows.
    def self.parse(path, ruby: nil)
      version = prism_version(ruby)
      seen_key = version ? [ path, version ] : path
      # An unchanged file answers from its stat; one concern file reaches every model's walk.
      signature = RunCache.fetch([ :stat_signature, path.to_s ]) { stat_signature(path) }
      seen = SEEN[seen_key]
      if seen && seen[2] && seen.first == signature && (cached = STORE[seen[1]])
        return cached
      end

      read_at = Time.now
      content = File.read(path)
      size = content.bytesize
      raise ArgumentError, "File too large for AST parsing: #{path} (#{size} bytes, max #{MAX_PARSE_SIZE})" if size > MAX_PARSE_SIZE

      key = content_key(content, version)

      cached = STORE[key]
      unless cached
        # Evict BEFORE inserting to avoid running inside compute_if_absent
        evict_if_full
        cached = STORE.compute_if_absent(key) { prism_parse(content, version) }
      end
      SEEN[seen_key] = [ signature, key, settled?(signature, read_at) ]
      cached
    end

    # A filesystem stamps mtime from a clock coarser than the reads around it
    # (1ms to 4ms on Linux, a second on HFS+ and ext3), so a same-size rewrite
    # inside one tick keeps the whole stat. As git does with its index, a stat
    # is trusted only for a file already this much older than the read.
    # ponytail: two seconds covers 1s mtimes (HFS+, ext3); a filesystem whose
    # clock is coarser still, or one another host writes with a skewed clock,
    # needs a wider window.
    RACY_WINDOW = 2

    def self.settled?(signature, read_at)
      Time.at(signature[0], signature[1], :nsec) < read_at - RACY_WINDOW
    end
    private_class_method :settled?

    def self.stat_signature(path)
      stat = File.stat(path)
      [ stat.mtime.to_i, stat.mtime.nsec, stat.size, stat.ino ]
    end
    private_class_method :stat_signature

    # A one-shot parse that stores nothing: for a scan reading thousands of
    # files once, whose entries would only evict what other readers reuse.
    def self.parse_uncached(source)
      Prism.parse(source)
    end

    # Parse a Ruby source string, cached by content digest, so every extractor
    # handed the same text shares one parse.
    def self.parse_string(source, ruby: nil)
      version = prism_version(ruby)
      return prism_parse(source, version) if source.bytesize > MAX_PARSE_SIZE

      key = content_key(source, version)

      cached = STORE[key]
      return cached if cached

      evict_if_full

      STORE.compute_if_absent(key) { prism_parse(source, version) }
    end

    def self.content_key(source, version)
      "src:#{Digest::SHA256.hexdigest(source)}#{":#{version}" if version}"
    end
    private_class_method :content_key

    OLDEST_GRAMMAR = "3.3"
    GRAMMARS = Concurrent::Map.new # major.minor => whether the loaded prism parses it

    # The grammar prism parses `ruby` with: its own major.minor, the oldest prism
    # knows for an older Ruby, and nil (the newest) for one newer than prism knows.
    # ponytail: Ruby 3.1 and 3.2 parse as 3.3; syntax only they accept reads as an error.
    def self.prism_version(ruby)
      wanted = ruby.to_s.b[/\A\d+\.\d+/]
      return nil unless wanted

      wanted = OLDEST_GRAMMAR if Gem::Version.new(wanted) < Gem::Version.new(OLDEST_GRAMMAR)
      wanted if GRAMMARS.compute_if_absent(wanted) { supported?(wanted) }
    end

    def self.supported?(version)
      Prism.parse("", version: version)
      true
    rescue ArgumentError
      false
    end
    private_class_method :supported?

    def self.prism_parse(source, version)
      version ? Prism.parse(source, version: version) : Prism.parse(source)
    end
    private_class_method :prism_parse

    # Clear the entire cache.
    def self.clear
      STORE.clear
      SEEN.clear
    end

    # Number of cached entries (for diagnostics).
    def self.size
      STORE.size
    end

    # Evict ~25% of entries (arbitrary selection - Concurrent::Map has no ordering guarantee)
    # when cache exceeds MAX_SIZE. Synchronized to prevent multiple threads from over-evicting.
    def self.evict_if_full
      EVICTION_MUTEX.synchronize do
        return if STORE.size < MAX_SIZE
        keys = STORE.keys
        evicted = keys.first(keys.size / 4).each { |k| STORE.delete(k) }.to_set
        # A stat goes with the parse it points at; files with the same bytes share
        # one parse, so SEEN can outgrow STORE but not the app's file count.
        SEEN.each_pair { |path, entry| SEEN.delete(path) if evicted.include?(entry[1]) }
      end
    end
    private_class_method :evict_if_full
  end
end
