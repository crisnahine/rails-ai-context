# frozen_string_literal: true

require "fileutils"
require "securerandom"

module RailsAiContext
  # Safe file reading with size limits and error handling.
  # Returns String on success, nil on any failure (missing, too large, unreadable).
  # Designed as a drop-in replacement for unguarded File.read calls across
  # introspectors and tools where nil is already handled.
  module SafeFile
    # Write through a temp file in the same directory, then rename. A reader
    # racing the write sees either the old file or the new one, never a
    # half-written one.
    def self.atomic_write(path, content)
      dir = File.dirname(path)
      FileUtils.mkdir_p(dir)
      tmp = File.join(dir, ".#{File.basename(path)}.#{SecureRandom.hex(4)}.tmp")
      File.write(tmp, content)
      File.rename(tmp, path)
    end

    def self.read(path, max_size: nil)
      return nil unless path && File.file?(path)

      limit = max_size || RailsAiContext.configuration.max_file_size
      return nil if File.size(path) > limit

      # The encoding options only apply while TRANSCODING; a file read as
      # UTF-8 that contains invalid bytes comes back tagged UTF-8 but
      # invalid, and the first regex over it raises ArgumentError. scrub
      # guarantees every consumer gets valid UTF-8.
      File.read(path, encoding: "UTF-8", invalid: :replace, undef: :replace).scrub("?")
    rescue Errno::ENOENT, Errno::EACCES, Errno::EISDIR, Errno::ENAMETOOLONG, SystemCallError
      nil
    end
  end
end
