# frozen_string_literal: true

require "digest"
require "set"

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
    # it, a cassette counting by its presence alone, and each directory
    # linked in from the app's repository, which the readers walk too.
    #
    # A stat cannot show a second write in the same clock tick as the first,
    # so a file younger than AstCache::RACY_WINDOW at one look has its
    # content compared at the next, and a directory that young is listed
    # again.
    class Snapshot
      # What a look keeps of one directory: its stat, whether that stat was
      # old enough to trust, its listing - the directory links in it apart -
      # and per watched file what look_at saw of it.
      Listing = Struct.new(:mtime, :ino, :settled, :subdirs, :links, :files, :seen, :cassettes)

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
        entered = Set.new
        # One run, so the link checks answer once per look.
        RunCache.around do
          Fingerprinter.watched_dirs(@root).each { |top| walk(top, horizon, dirs, entered) }
        end
        # A directory the walk no longer reaches took its files with it.
        @changed = true if @dirs&.any? { |path, dir| !dirs.key?(path) && (dir.files.any? || dir.cassettes.any?) }
        @dirs = dirs
        !@first && @changed
      end

      private

      # The real tree first, then each directory linked in from the app's
      # repository, as the readers walk one (FileWalk).
      def walk(top, horizon, dirs, entered)
        start = real_dir(top) or return
        pending = [ top ]
        linked = []
        while (path = pending.pop || linked.shift)
          next if dirs.key?(path)

          stat = dir_stat(path)
          next unless stat

          dir = listing(path, stat, horizon)
          dirs[path] = dir
          look_at_all(dir.files, dir.seen, horizon)
          pending.concat(dir.subdirs)
          dir.links.each { |link| linked << link if enter?(link, start, entered) }
        end
      end

      # Whether the walk enters a directory link, asked at every look, since
      # where it leads can move without its directory's stat moving. As the
      # readers do, only one into the app's repository, never one back up
      # over the walk's start (PathResolver.enter_link?); and as compute
      # does, by real path, never one into the tree walked here or into a
      # directory a link has led to already, which also ends a circle of
      # links.
      def enter?(link, start, entered)
        target = File.realpath(link)
        return false if [ start, *entered ].any? { |dir| SafePath.contained?(target, dir) }
        return false unless File.directory?(target) && PathResolver.enter_link?(target, start, @root)

        entered << target
        true
      rescue SystemCallError
        false
      end

      def real_dir(path)
        File.realpath(path)
      rescue SystemCallError
        nil
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

        subdirs, links, files, cassettes = list(path)
        before = kept ? kept.files.zip(kept.seen).to_h : {}
        seen = files.map { |file| before[file] }
        if kept
          @changed = true if files.size != kept.files.size || files.any? { |file| !before.key?(file) } || cassettes.sort != kept.cassettes.sort
        elsif !@first && (files.any? || cassettes.any?)
          @changed = true
        end
        Listing.new(stat.mtime, stat.ino, stat.mtime < horizon, subdirs, links, files, seen, cassettes)
      end

      # What glob's `**/*` walks - no dotfiles - and apart from it each link
      # that may lead to a directory: one that does, or that leads nowhere
      # yet. walk decides at every look whether to enter it. In name order,
      # so a directory two links lead to is spelled the same way each time.
      def list(path)
        subdirs = []
        links = []
        files = []
        cassettes = []
        Dir.children(path).sort.each do |name|
          next if name.start_with?(".")

          entry = File.join(path, name)
          stat = File.lstat(entry)
          if stat.directory?
            subdirs << entry
          elsif WATCHED_EXTNAMES.include?(File.extname(name))
            (entry.delete_prefix(@prefix).match?(CASSETTES) ? cassettes : files) << entry unless entry.include?(BUILD_OUTPUT)
          elsif stat.symlink? && !File.file?(entry)
            links << entry
          end
        rescue SystemCallError
          next
        end
        [ subdirs, links, files, cassettes ]
      rescue SystemCallError
        [ [], [], [], [] ]
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
