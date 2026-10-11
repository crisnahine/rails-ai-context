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
      # Read where the file is too: a name inside the linked directory.
      return refuse(:sensitive) if linked && sensitive?(real.delete_prefix(dir_prefix(linked)))
      return refuse(:missing) unless File.file?(real)

      limit = max_size || RailsAiContext.configuration.max_file_size
      return refuse(:too_large, realpath: real, relative: root_relative) if File.size(real) > limit

      Resolution.new(realpath: real, relative: root_relative, refusal: nil)
    rescue Errno::ENOENT, Errno::EACCES, Errno::ELOOP, Errno::ENAMETOOLONG, Errno::ENOTDIR
      refuse(:missing)
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
      relative.include?("..") || relative.start_with?("/") || relative.include?("\0")
    end

    PLACEHOLDER_SUFFIXES = %w[.example .sample .template .dist].freeze

    # A placeholder (.env.example) is committed to be read, so a basename glob
    # does not block it; a path pattern (`.ssh/*`) or its exact name does.
    def sensitive?(relative)
      path = relative.to_s
      basename = File.basename(path)
      flags = File::FNM_DOTMATCH | File::FNM_CASEFOLD
      matching = RailsAiContext.configuration.sensitive_patterns.select do |pattern|
        File.fnmatch(pattern, path, flags) || File.fnmatch(pattern, basename, flags)
      end
      return false if matching.empty?
      return true unless PLACEHOLDER_SUFFIXES.any? { |suffix| basename.downcase.end_with?(suffix) }

      # Without FNM_EXTGLOB a brace is literal, so only these make a pattern a glob.
      matching.any? do |pattern|
        pattern.include?("/") || (!pattern.match?(/[*?\[\\]/) && (pattern.casecmp?(path) || pattern.casecmp?(basename)))
      end
    end

    def contained?(real, real_dir)
      real == real_dir || real.start_with?(dir_prefix(real_dir))
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
