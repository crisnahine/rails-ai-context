# frozen_string_literal: true

require "digest"

module RailsAiContext
  class Fingerprinter
    # A server's question before every call - did a file a reader reads
    # change since the last look? - answered by stat alone. compute globs the
    # tree and hashes every mtime each time, about 75 ms at 9,500 files; this
    # keeps each directory's listing while the directory's stat holds (adding,
    # removing or renaming an entry restamps it), so a look stats the
    # directories and the watched files, about 3 microseconds a file, and
    # lists only a directory that changed. The files are the ones compute
    # reads: the root manifests, and each watched directory as `**/*` walks
    # it, a cassette counting by its presence alone.
    #
    # A stat cannot show a second write in the same clock tick as the first,
    # so a file younger than AstCache::RACY_WINDOW at one look has its
    # content compared at the next, and a directory that young is listed
    # again.
    class Snapshot
      # What a look keeps of one directory: its stat, whether that stat was
      # old enough to trust, its listing, and per watched file what look_at
      # saw of it.
      Listing = Struct.new(:mtime, :ino, :settled, :subdirs, :files, :seen, :cassettes)

      def initialize(root)
        @root = root.to_s
        @prefix = SafePath.dir_prefix(@root)
        @dirs = nil
        @manifests = {}
      end

      # Whether anything changed since the previous look; the first one only
      # records.
      def changed?
        @first = @dirs.nil?
        @changed = false
        horizon = Time.now - AstCache::RACY_WINDOW

        manifests = {}
        WATCHED_FILES.each do |name|
          path = File.join(@root, name)
          manifests[path] = look_at(path, @manifests[path], horizon) if File.exist?(path)
        rescue SystemCallError
          next
        end
        @changed = true if manifests.keys != @manifests.keys
        @manifests = manifests

        dirs = {}
        Fingerprinter.watched_dirs(@root).each { |top| walk(top, horizon, dirs) }
        # A directory the walk no longer reaches took its files with it.
        @changed = true if @dirs&.any? { |path, dir| !dirs.key?(path) && (dir.files.any? || dir.cassettes.any?) }
        @dirs = dirs
        !@first && @changed
      end

      private

      def walk(top, horizon, dirs)
        pending = [ top ]
        while (path = pending.pop)
          next if dirs.key?(path)

          stat = dir_stat(path)
          next unless stat

          dir = listing(path, stat, horizon)
          dirs[path] = dir
          look_at_all(dir.files, dir.seen, horizon)
          pending.concat(dir.subdirs)
        end
      end

      # The hot loop, once per watched file per call: a stat, and a method
      # call only for a file that moved or is young.
      def look_at_all(files, seen, horizon)
        index = 0
        while index < files.size
          file = files[index]
          was = seen[index]
          begin
            mtime = File.mtime(file)
            seen[index] = look_at(file, was, horizon, mtime) unless was && was[0] == mtime && !was[1]
          rescue SystemCallError
            # Gone since the listing: its directory is restamped, so the next
            # look lists it again.
            @changed = true if was
            seen[index] = nil
          end
          index += 1
        end
      end

      def dir_stat(path)
        File.stat(path)
      rescue SystemCallError
        nil
      end

      # The kept listing while the directory's stat holds; otherwise the
      # directory read again, each file keeping what was seen of it. A file
      # added or removed since the kept listing is a change, and so is a
      # directory that appeared with files in it.
      def listing(path, stat, horizon)
        kept = @dirs && @dirs[path]
        return kept if kept&.settled && kept.mtime == stat.mtime && kept.ino == stat.ino

        subdirs, files, cassettes = list(path)
        before = kept ? kept.files.zip(kept.seen).to_h : {}
        seen = files.map { |file| before[file] }
        if kept
          @changed = true if files.size != kept.files.size || files.any? { |file| !before.key?(file) } || cassettes.sort != kept.cassettes.sort
        elsif !@first && (files.any? || cassettes.any?)
          @changed = true
        end
        Listing.new(stat.mtime, stat.ino, stat.mtime < horizon, subdirs, files, seen, cassettes)
      end

      # What glob's `**/*` walks: no dotfiles, and a symlinked directory is an
      # entry, not a directory to descend into.
      def list(path)
        subdirs = []
        files = []
        cassettes = []
        Dir.children(path).each do |name|
          next if name.start_with?(".")

          entry = File.join(path, name)
          if File.lstat(entry).directory?
            subdirs << entry
          elsif WATCHED_EXTNAMES.include?(File.extname(name)) && !entry.include?(BUILD_OUTPUT)
            (entry.delete_prefix(@prefix).match?(CASSETTES) ? cassettes : files) << entry
          end
        rescue SystemCallError
          next
        end
        [ subdirs, files, cassettes ]
      rescue SystemCallError
        [ [], [], [] ]
      end

      # [mtime, digest]: the digest only while the file is young. What was
      # seen at the last look, if anything, decides whether this is a change;
      # a file new to a listing was counted there.
      def look_at(file, seen, horizon, mtime = File.mtime(file))
        return seen if seen && seen[0] == mtime && !seen[1]

        digest = content(file) if seen && seen[0] == mtime
        @changed = true if seen && (seen[0] != mtime || digest != seen[1])
        [ mtime, (digest || content(file) if mtime >= horizon) ]
      end

      def content(file)
        Digest::SHA256.file(file).digest
      end
    end
  end
end
