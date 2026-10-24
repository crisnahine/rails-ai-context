# frozen_string_literal: true

require "pathname"
require_relative "polyfill/data"

module RailsAiContext
  # One answer to "may this caller-supplied path be read, and which file is
  # it". The checks run in an order that matters: a sensitive name is refused
  # before any stat so not-found and not-allowed cannot leak whether a secret
  # exists, containment is separator-aware so a sibling directory sharing the
  # prefix does not pass, and the sensitive check runs again on the realpath
  # so a symlink from a benign name cannot reach one.
  module SafePath
    Resolution = Data.define(:realpath, :relative, :refusal) do
      def ok?
        refusal.nil?
      end
    end

    module_function

    # relative: the caller's path, relative to `under`. root: the directory
    # the sensitive patterns are matched against (the app root for most tools).
    # listed: the path came from a listing of `under`, so it is spelled as on disk.
    # links: a path through a directory linked in from the repository holding
    # `root` (linked_in) is one of `under`'s; off, only `under` itself holds.
    def locate(relative, under:, root: under, max_size: nil, listed: false, links: true)
      relative = relative.to_s
      return refuse(:traversal) if traversal?(relative)
      return refuse(:missing) if relative.bytesize > MAX_PATH
      return refuse(:sensitive) if sensitive?(relative)

      path = File.join(under.to_s, relative)
      real = listed ? real_file(path) : File.realpath(path)
      real_under = real_base(under)
      linked = links && !contained?(real, real_under) ? linked_in(path, real, under, root) : nil
      return refuse(:outside) unless linked || contained?(real, real_under)

      real_root = real_base(root)
      # `under` can itself be a linked-in directory, a pack's app/views, so the
      # root's spelling of the path is asked for the link too.
      linked ||= links && !contained?(real, real_root) ? linked_in(path, real, root, root) : nil
      root_relative = if real == real_root then ""
      elsif contained?(real, real_root) then real.delete_prefix(dir_prefix(real_root))
      # Named the way the app spells it: packs/billing/app/models/invoice.rb.
      elsif linked then spelled_relative(path, root)
      # A directory the caller trusts outside the root, such as the engine around a test/dummy.
      else Pathname.new(real).relative_path_from(Pathname.new(real_root)).to_s
      end
      return refuse(:sensitive) if sensitive?(root_relative)
      # Read where the file is too: a name inside the linked directory, and inside its repository.
      return refuse(:sensitive) if linked && (sensitive?(real.delete_prefix(dir_prefix(linked))) || in_repository_sensitive?(real, root))
      return refuse(:missing) unless File.file?(real)

      limit = max_size || RailsAiContext.configuration.max_file_size
      return refuse(:too_large, realpath: real, relative: root_relative) if File.size(real) > limit

      Resolution.new(realpath: real, relative: root_relative, refusal: nil)
    # EINVAL: Windows refuses a name holding `:`, `<`, `|` and the like.
    rescue Errno::ENOENT, Errno::EACCES, Errno::ELOOP, Errno::ENAMETOOLONG, Errno::ENOTDIR, Errno::EINVAL
      refuse(:missing)
    end

    # A file a link brings in, asked by the names it has where it lives: in the app when the link leads
    # back into it, and in the repository holding `root` (link_bound), where a link to a pack's config/
    # names database.yml without the config/ a pattern looks for.
    def in_repository_sensitive?(real, root)
      real_root = real_base(root)
      bound = link_bound(root)
      (contained?(real, real_root) && sensitive?(real.delete_prefix(dir_prefix(real_root)))) ||
        (contained?(real, bound) && sensitive?(real.delete_prefix(dir_prefix(bound))))
    end

    # A directory resolves to the same path for every lookup in a run.
    def real_base(dir)
      RunCache.fetch([ :safe_path_base, dir.to_s ]) { File.realpath(dir.to_s) }
    end

    # A file that is not a link is its directory's real path plus its name, so a
    # scan of hundreds of files in one directory resolves the directory once. A
    # typed path keeps realpath, which also corrects its case on macOS.
    def real_file(path)
      return File.realpath(path) unless File.lstat(path).file?

      File.join(real_base(File.dirname(path)), File.basename(path))
    end

    # Where a directory link inside the app may lead and still be the app's:
    # the git work tree holding `root`, so a monorepo's shared package counts
    # and a home directory does not. Outside any repository nothing marks
    # where the project ends, so only `root` itself.
    def link_bound(root)
      RunCache.fetch([ :safe_path_link_bound, root.to_s ]) do
        real_root = real_base(root)
        repo = git_root(real_root)
        repo ? File.realpath(repo) : real_root
      end
    end

    # The real path of the linked-in directory that holds `real`: a directory
    # link on `path`'s spelling below `base` that leads inside link_bound(root).
    # Nil when no such link leads to it, as for a file linked out on its own.
    # A spelled `..` is read lexically, so it cannot climb out through a link.
    def linked_in(path, real, base, root)
      spelled = File.expand_path(path.to_s)
      prefix = dir_prefix(File.expand_path(base.to_s))
      return nil unless spelled.start_with?(prefix)

      bound = link_bound(root)
      segments = spelled.delete_prefix(prefix).split(File::SEPARATOR)
      segments.size.downto(1) do |depth|
        linked = linked_dir(File.join(prefix, *segments.first(depth)), bound)
        return linked if linked && contained?(real, linked)
      end
      nil
    end

    # A directory link's real path when it leads inside `bound`, else nil.
    def linked_dir(dir, bound)
      RunCache.fetch([ :safe_path_linked_dir, dir, bound ]) do
        real = File.symlink?(dir) && File.directory?(dir) && File.realpath(dir)
        real if real && contained?(real, bound)
      end
    rescue SystemCallError
      nil
    end

    # `path` relative to `root` as both are spelled.
    def spelled_relative(path, root)
      spelled = File.expand_path(path.to_s)
      spelled_root = File.expand_path(root.to_s)
      return spelled.delete_prefix(dir_prefix(spelled_root)) if spelled.start_with?(dir_prefix(spelled_root))

      Pathname.new(spelled).relative_path_from(Pathname.new(spelled_root)).to_s
    end

    def read(relative, under:, root: under, max_size: nil)
      resolution = locate(relative, under: under, root: root, max_size: max_size)
      return [ nil, resolution ] unless resolution.ok?

      [ RailsAiContext::SafeFile.read(resolution.realpath, max_size: max_size), resolution ]
    end

    # A path that escapes by construction, refused before any stat so the
    # answer cannot depend on what is out there. Named on its own for callers
    # that resolve a directory rather than a file and so cannot use `locate`.
    def traversal?(relative)
      relative = relative.to_s
      relative.include?("\0") || relative.include?("..") || absolute?(relative)
    end

    # Whether a path names its place whatever directory it is joined to:
    # `/x` everywhere, and on Windows `C:/x`, `C:\x` and `\\server\share`,
    # which File.absolute_path? answers there, as well as `\x` (the current
    # drive's root) and `C:x` (that drive's current directory). A NUL byte
    # names no file at all, and File.absolute_path? raises on one.
    def absolute?(path)
      path = path.to_s
      return true if path.start_with?("/")
      return false if path.include?("\0")
      return true if File.absolute_path?(path)

      !File::ALT_SEPARATOR.nil? && path.match?(/\A(?:\\|[A-Za-z]:)/)
    end

    PLACEHOLDER_SUFFIXES = %w[.example .sample .template .dist].freeze
    # Longer than any path a file system holds, so only a caller can name one.
    MAX_PATH = 4096

    # A placeholder (.env.example) is committed to be read, so a basename glob
    # does not block it; a path pattern (`.ssh/*`), its exact name or a folder
    # it sits in does.
    def sensitive?(relative)
      path = relative.to_s
      return true if path.bytesize > MAX_PATH

      basename = File.basename(path)
      down = path.downcase
      base_down = basename.downcase
      matched = compiled_patterns.filter_map { |pattern| (how = pattern.match(path, basename, down, base_down)) && [ pattern, how ] }
      return false if matched.empty?
      return true unless PLACEHOLDER_SUFFIXES.any? { |suffix| base_down.end_with?(suffix) }

      # Without FNM_EXTGLOB a brace is literal, so only these make a pattern a glob.
      matched.any? do |pattern, how|
        glob = pattern.glob
        how == :folder || glob.include?("/") || (!glob.match?(/[*?\[\\]/) && (glob.casecmp?(path) || glob.casecmp?(basename)))
      end
    end

    MATCH_FLAGS = File::FNM_DOTMATCH | File::FNM_CASEFOLD
    PATHNAME_FLAGS = MATCH_FLAGS | File::FNM_PATHNAME

    # A pattern read as a .gitignore line is: a leading `/` (or `./`) anchors it at the root, where a
    # `*` stays in its folder; a trailing `/` names a folder and everything in it; `**/` stands for any
    # number of folders, none included; and a pattern names a folder too, so everything in a folder it
    # names is covered. Unanchored, a path pattern names its file at any depth, as an engine, a pack or
    # a test/dummy app keeps its own config/database.yml, and without FNM_PATHNAME a `*` crosses `/`.
    # `lead` and `tail` are the glob's literal start and end, lowercased: a path that does not hold them
    # is passed over before fnmatch, which runs per pattern on every file a search walks. `within` and
    # `nested_within` are the globs with a folder's contents after them, so one fnmatch asks whether any
    # folder of the path matches, however many folders a caller's path has.
    Pattern = Data.define(:source, :glob, :nested, :mode, :lead, :tail, :within, :nested_within) do
      # :file when the pattern names the path, :folder when it names a folder the path is in, else nil.
      def match(path, basename, down, base_down)
        if mode == :name
          return :file if base_down.start_with?(lead) && fnmatch(glob, basename)
          return :folder if down.include?(lead) && down.include?("#{tail}/") &&
                            path.split("/")[0...-1].any? { |folder| folder.downcase.start_with?(lead) && fnmatch(glob, folder) }

          # Its `*` crosses `/`, so it can match the whole path through no folder's name: the file's.
          :file if path.include?("/") && down.start_with?(lead) && fnmatch(glob, path)
        else
          return nil unless down.include?(lead)
          return :file if matches?(glob, nested, path, down)
          return nil unless down.include?("#{tail}/")

          :folder if matches?(within, nested_within, path, down)
        end
      end

      private

      def matches?(glob, nested, path, down)
        case mode
        when :path then (down.start_with?(lead) && fnmatch(glob, path)) || (down.include?("/#{lead}") && fnmatch(nested, path))
        when :anchored then down.start_with?(lead) && File.fnmatch(glob, path, PATHNAME_FLAGS)
        else File.fnmatch(glob, path, PATHNAME_FLAGS) || (!nested.nil? && File.fnmatch(nested, path, PATHNAME_FLAGS))
        end
      end

      def fnmatch(pattern, path)
        File.fnmatch(pattern, path, MATCH_FLAGS)
      end
    end

    def compile_pattern(source)
      bare = source.start_with?("./") ? source[2..] : source.delete_prefix("/")
      anchored = bare != source
      bare = "#{bare}*" if bare.end_with?("/")
      bare = bare.delete_prefix("**/") unless anchored
      lead = bare[/\A[^*?\[\\{]*/].downcase
      tail = bare[/[^*?\[\]\\{}]*\z/].downcase
      # Without FNM_PATHNAME a `*` crosses `/`, so `/*` covers a folder's contents; with it, `/**/*` does.
      if bare.include?("**/")
        nested = anchored ? nil : "**/#{bare}"
        Pattern.new(source, bare, nested, :pathname, lead, tail, "#{bare}/**/*", nested && "#{nested}/**/*")
      elsif anchored then Pattern.new(source, bare, nil, :anchored, lead, tail, "#{bare}/**/*", nil)
      elsif bare.include?("/") then Pattern.new(source, bare, "*/#{bare}", :path, lead, tail, "#{bare}/*", "*/#{bare}/*")
      else Pattern.new(source, bare, nil, :name, lead, tail, nil, nil)
      end
    end

    # The configured patterns compiled once per list, read again when the list changes.
    def compiled_patterns
      patterns = RailsAiContext.configuration.sensitive_patterns
      cached = @compiled_patterns
      return cached[2] if cached && cached[0].equal?(patterns) && cached[1] == patterns

      compiled = patterns.map { |pattern| compile_pattern(pattern.to_s) }.freeze
      @compiled_patterns = [ patterns, patterns.dup, compiled ].freeze
      compiled
    end

    def contained?(real, real_dir)
      real == real_dir || real.start_with?(dir_prefix(real_dir))
    end

    # The dirs no other one in the list holds.
    def outermost(dirs)
      dirs = dirs.uniq
      dirs.reject { |dir| dirs.any? { |other| other != dir && contained?(dir, other) } }
    end

    # Whether `path` is `dir` or below it, compared by real paths, either of
    # which may not exist yet or sit behind a symlink.
    def inside?(path, dir)
      contained?(canonical(path), canonical(dir))
    end

    # One spelling of a place whatever links lead to it, for comparing two
    # paths: the real path, or for a path not there yet its nearest existing
    # ancestor's real path with the rest appended. Stdlib only, so it serves
    # before the gem entry loads too.
    #
    # Worked in bytes: a name that is not UTF-8 arrives as a broken UTF-8
    # string, which Ruby 3.1's delete_prefix leaves whole, and realpath
    # answers it as bytes, which File.join will not mix with a UTF-8 rest.
    def canonical(path)
      path = File.expand_path(path.to_s)
      existing = path
      existing = File.dirname(existing) until File.exist?(existing) || File.dirname(existing) == existing
      rest = path.b.delete_prefix(existing.b)
      real = File.realpath(existing)
      return real if rest.empty?

      joined = File.join(real.b, rest)
      text = joined.dup.force_encoding(Encoding::UTF_8)
      text.valid_encoding? ? text : joined
    rescue SystemCallError
      path
    end

    # The nearest directory at or above `dir` that holds `.git` (a directory, or a
    # file in a worktree or submodule), or nil outside any repository.
    def git_root(dir)
      until File.exist?(File.join(dir, ".git"))
        parent = File.dirname(dir)
        return nil if parent == dir

        dir = parent
      end
      dir
    end

    # The filesystem root already ends in the separator, so it is its own prefix.
    def dir_prefix(dir)
      dir.end_with?(File::SEPARATOR) ? dir : dir + File::SEPARATOR
    end

    # A too-large file was found, so its resolution keeps the path for the
    # caller to name.
    def refuse(reason, realpath: nil, relative: nil)
      Resolution.new(realpath: realpath, relative: relative, refusal: reason)
    end
    private_class_method :refuse
  end
end
