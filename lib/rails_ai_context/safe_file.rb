# frozen_string_literal: true

require "fileutils"

# securerandom is a gem an app's bundle pins, and this file loads before the
# app boots: required here, our copy loaded first and the app's then loaded
# over it ("already initialized constant"). It loads when first named.
autoload :SecureRandom, "securerandom"

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
      File.binwrite(tmp, content)
      File.rename(tmp, path)
    rescue StandardError
      FileUtils.rm_f(tmp) if tmp
      raise
    end

    # A file the gem rewrites in part, as UTF-8 whatever the locale says. One
    # that is not valid UTF-8 stays as bytes: what is looked for in it is
    # ASCII, and what is not replaced is written back as it came.
    def self.read_text(path)
      content = File.binread(path)
      utf8 = content.dup.force_encoding(Encoding::UTF_8)
      utf8.valid_encoding? ? utf8 : content
    end

    def self.read(path, max_size: nil)
      return nil unless path

      # One stat for both questions: a run over a large app calls this tens of thousands of times.
      stat = File.stat(path)
      return nil unless stat.file?

      limit = max_size || RailsAiContext.configuration.max_file_size
      return nil if stat.size > limit

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
