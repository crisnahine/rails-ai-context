# frozen_string_literal: true

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
    def locate(relative, under:, root: under, max_size: nil)
      relative = relative.to_s
      return refuse(:traversal) if traversal?(relative)
      return refuse(:sensitive) if sensitive?(relative)

      real = File.realpath(File.join(under.to_s, relative))
      real_under = File.realpath(under.to_s)
      return refuse(:outside) unless contained?(real, real_under)

      real_root = File.realpath(root.to_s)
      root_relative = real == real_root ? "" : real.delete_prefix(dir_prefix(real_root))
      return refuse(:sensitive) if sensitive?(root_relative)
      return refuse(:missing) unless File.file?(real)

      limit = max_size || RailsAiContext.configuration.max_file_size
      return refuse(:too_large, realpath: real, relative: root_relative) if File.size(real) > limit

      Resolution.new(realpath: real, relative: root_relative, refusal: nil)
    rescue Errno::ENOENT, Errno::EACCES, Errno::ELOOP, Errno::ENAMETOOLONG, Errno::ENOTDIR
      refuse(:missing)
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
