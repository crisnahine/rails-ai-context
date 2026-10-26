# frozen_string_literal: true

require "fileutils"
require_relative "safe_path"

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
    # A write refused because its path is a link that leads out of the root.
    # An IOError, so a caller that reports failed writes reports this one too.
    class LinkedOut < IOError; end

    # Why a path a link stopped was left, in the words every report uses.
    LINKED = "it is a symlink or behind one, which this run does not follow"

    # Why a write the file's permissions refused was left, in the same words.
    UNWRITABLE = "it could not be written - check its permissions"
    DENIED = [ Errno::EACCES, Errno::EPERM, Errno::EROFS ].freeze

    # Temp file then rename, so no reader sees half a file; a link is written through only to a file inside `root`.
    def self.atomic_write(path, content, root:)
      path = link_target(path, root) if File.symlink?(path)
      refuse_outside(path, root)
      # A rename needs only a writable folder, and read-only is how a user keeps tools off a file.
      raise Errno::EACCES, path.to_s if File.exist?(path) && !File.writable?(path)

      dir = File.dirname(path)
      FileUtils.mkdir_p(dir)
      mode = File.stat(path).mode & 0o7777 if File.exist?(path)
      tmp = File.join(dir, ".#{File.basename(path)}.#{SecureRandom.hex(4)}.tmp")
      File.binwrite(tmp, content)
      File.chmod(mode, tmp) if mode
      File.rename(tmp, path)
    rescue StandardError
      FileUtils.rm_f(tmp) if tmp
      raise
    end

    # Why atomic_write would refuse `path`, in plain words; nil when it would write.
    def self.write_refusal(path, root:)
      path = link_target(path, root) if File.symlink?(path)
      refuse_outside(path, root)
      dir = File.dirname(path)
      "its permissions do not allow it" if (File.exist?(path) && !File.writable?(path)) || (File.directory?(dir) && !File.writable?(dir))
    rescue LinkedOut => e
      "#{LINKED}: #{e.message[/#{Regexp.escape(LINKED)} \((.*)\)\z/o, 1]}"
    end

    # Delete a file, refused like a write when a linked directory carries it
    # out of `root`. A link itself goes, not the file it names.
    def self.delete(path, root:)
      refuse_outside(path, root)
      File.delete(path)
    end

    private_class_method def self.refuse_outside(path, root)
      dir = File.dirname(path)
      # A link that leads nowhere reads as a folder not made yet, and mkdir_p cannot make it.
      dir = File.dirname(dir) until File.exist?(dir) || File.symlink?(dir) || File.dirname(dir) == dir
      raise LinkedOut, "Left #{path} as it is - #{LINKED} (it leads nowhere)" unless File.exist?(dir)
      return if SafePath.inside?(File.dirname(path), root)

      raise LinkedOut, "Left #{path} as it is - #{LINKED} (it leads out of the app)"
    end

    private_class_method def self.link_target(path, root)
      real = File.realpath(path)
      return real if SafePath.contained?(real, SafePath.canonical(root))

      raise LinkedOut, "Left #{path} as it is - #{LINKED} (it leads out of the app)"
    rescue Errno::ENOENT
      raise LinkedOut, "Left #{path} as it is - #{LINKED} (it leads nowhere)"
    rescue SystemCallError => e
      # Ruby's own text repeats the absolute path.
      raise LinkedOut, "Left #{path} as it is - #{LINKED} (#{SystemCallError.new(nil, e.errno).message.downcase})"
    end

    BOM = "\xEF\xBB\xBF".b.freeze

    # A text's byte order mark ("" when it has none) and the text after it,
    # each in the text's encoding: the mark is the file's, and goes back at
    # its head when the file is written.
    def self.split_bom(text)
      return [ "", text ] unless text.byteslice(0, BOM.bytesize).b == BOM

      [ text.byteslice(0, BOM.bytesize), text.byteslice(BOM.bytesize..) ]
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
