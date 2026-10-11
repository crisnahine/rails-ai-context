# frozen_string_literal: true

require "set"

module RailsAiContext
  # Prunes skipped directories rather than filtering after: globbing `**/*` walks one
  # real node_modules for seconds before the caller can drop its paths.
  module FileWalk
    GLOB_FLAGS = File::FNM_PATHNAME | File::FNM_EXTGLOB

    module_function

    # Every regular file under `dir`. A directory linked in from the app's
    # repository is walked too, after the real tree and once whatever spells
    # it, as Zeitwerk and the JavaScript bundlers follow one
    # (PathResolver.enter_link?); a link back up over `dir` is not, and nor is
    # one that leads anywhere else. A linked file is yielded only when it
    # stays inside the app (PathResolver.linked_out?), and a link that
    # resolves nowhere is not yielded. A `dir` that a link carries out of the
    # app is not walked at all.
    #
    # @param dir [String] directory to walk
    # @param skip [Array<String>] directory names never entered
    # @param root [String] the app root a link may not lead out of
    # @yield [String] each file path, spelled under `dir`
    def each_file(dir, skip: [], root: dir)
      return enum_for(:each_file, dir, skip: skip, root: root) unless block_given?

      dir = dir.to_s
      return unless File.directory?(dir) && !PathResolver.linked_out?(dir, root)

      start = File.realpath(dir)
      visited = Set.new
      # [path as spelled, its real path]: the real tree first, then each linked directory.
      pending = [ [ dir, start ] ]
      links = []
      until pending.empty? && links.empty?
        current, real = pending.empty? ? links.shift : pending.pop
        next unless visited.add?(real)

        children(current).each do |name|
          next if name.start_with?(".") || skip.include?(name)

          path = File.join(current, name)
          stat = File.lstat(path)
          if stat.symlink?
            target = File.stat(path)
            if target.directory?
              link = File.realpath(path)
              links << [ path, link ] if PathResolver.enter_link?(link, start, root)
            elsif target.file? && !PathResolver.linked_out?(path, root)
              yield path
            end
          elsif stat.directory?
            pending << [ path, File.join(real, name) ]
          elsif stat.file?
            yield path
          end
        rescue SystemCallError
          next
        end
      end
    end

    # The files under `dir` whose path below it matches `pattern`, as Dir.glob
    # reads one (`**/` is any depth, a brace is a choice), walked as each_file
    # walks: Dir.glob enters no linked directory and stops at no link out of
    # the app. A pattern's leading plain directories are where the walk
    # starts, and one run walks each start once.
    #
    # @return [Array<String>] sorted paths, spelled under `dir`
    def glob(dir, pattern, root:, skip: [])
      dir = dir.to_s
      segments = pattern.split("/")
      plain = segments.take_while { |segment| !segment.match?(/[*?\[{\\]/) }.first(segments.size - 1)
      start = plain.empty? ? dir : File.join(dir, *plain)
      prefix = SafePath.dir_prefix(dir)
      RunCache.fetch([ :file_walk, start, root.to_s, skip ]) { each_file(start, skip: skip, root: root).sort }
        .select { |path| File.fnmatch?(pattern, path.delete_prefix(prefix), GLOB_FLAGS) }
    end

    def children(dir)
      Dir.children(dir).sort
    rescue SystemCallError
      []
    end
  end
end
