# frozen_string_literal: true

require "open3"

module RailsAiContext
  # git's ignore-file rules (globs, anchoring, last match wins, negation) for
  # the doctor, and ripgrep's walk over a tree for the search fallback.
  module GitIgnore
    module_function

    # `base`: the file's directory, which its patterns are relative to.
    # `source`: the file, since the last match wins within one file only.
    def parse(content, base: "", source: base)
      content.to_s.each_line.filter_map do |line|
        pattern = line.strip
        next if pattern.empty? || pattern.start_with?("#")

        negation = pattern.start_with?("!")
        pattern = pattern.delete_prefix("!")
        dir_only = pattern.end_with?("/")
        anchored = pattern.chomp("/").include?("/")
        pattern = pattern.delete_prefix("/").chomp("/")
        next if pattern.empty?

        { negation: negation, dir_only: dir_only, anchored: anchored, pattern: pattern, base: base, source: source }
      end
    end

    # An ignored ancestor hides everything beneath it; ancestors are walked
    # from the top, so reaching one means none above it was ignored.
    def ignored?(rules, path, dir: false, case_insensitive: false)
      parts = path.split("/")
      (1...parts.size).each do |depth|
        return true if verdict(rules, parts.first(depth).join("/"), dir: true, case_insensitive: case_insensitive) == :ignore
      end
      verdict(rules, path, dir: dir, case_insensitive: case_insensitive) == :ignore
    end

    # `rules` highest precedence first: the first file with a match decides,
    # by its last matching rule. :ignore, :whitelist, or nil.
    def verdict(rules, path, dir:, case_insensitive: false)
      rules.chunk_while { |a, b| a[:source] == b[:source] }.each do |file_rules|
        answer = file_verdict(file_rules, path, dir: dir, case_insensitive: case_insensitive)
        return answer if answer
      end
      nil
    end

    def file_verdict(file_rules, path, dir:, case_insensitive: false)
      file_rules.reverse_each do |rule|
        # `pattern/` entries concern directories only, in both polarities.
        next if rule[:dir_only] && !dir
        next unless matches?(rule, path, case_insensitive: case_insensitive)

        return rule[:negation] ? :whitelist : :ignore
      end
      nil
    end

    def for_tree(root)
      Walk.new(root)
    end

    # ripgrep's walk and ignore precedence (ignore 0.4.31, dir.rs
    # `matched_ignore`, `add_parents`); docs/TOOLS.md states the rules.
    class Walk
      Context = Struct.new(:rgignore, :ignore, :gitignore, :exclude, :any_git, :ordered, keyword_init: true)
      EMPTY = Context.new(rgignore: [], ignore: [], gitignore: [], exclude: [], any_git: false, ordered: []).freeze

      def initialize(root)
        @root = File.realpath(root.to_s)
        @contexts = {}
        @entered = {}
      end

      def ignored?(path, dir: false)
        parts = path.split("/")
        (1...parts.size).each do |depth|
          return true if dir_ignored?(File.join(@root, *parts.first(depth)))
        end
        verdict(File.join(@root, path), dir) == :ignore
      end

      # Files ripgrep would search under `start`, in its order, with root-relative
      # paths; `skip` is the caller's overrides, asked of directories too.
      def each_file(start = @root, skip: nil, &block)
        Dir.children(start).sort.each do |name|
          next if name.start_with?(".")

          path = File.join(start, name)
          stat = File.lstat(path)
          next if stat.symlink? || !(stat.directory? || stat.file?)

          relative = path.delete_prefix("#{@root}/")
          next if skip&.call(relative, stat.directory?)
          next if verdict(path, stat.directory?) == :ignore

          stat.directory? ? each_file(path, skip: skip, &block) : yield(path, relative)
        rescue SystemCallError
          next
        end
      rescue SystemCallError
        nil
      end

      private

      def dir_ignored?(path)
        @entered.fetch(path) { @entered[path] = verdict(path, true) == :ignore }
      end

      def verdict(path, dir)
        context(File.dirname(path)).ordered.each do |source|
          relative = source[:dir] == "/" ? path.delete_prefix("/") : path.delete_prefix("#{source[:dir]}/")
          answer = GitIgnore.file_verdict(source[:rules], relative, dir: dir)
          return answer if answer
        end
        nil
      end

      def context(dir)
        @contexts[dir] ||= begin
          parent = File.dirname(dir) == dir ? EMPTY : context(File.dirname(dir))
          has_git = File.exist?(File.join(dir, ".git"))
          own = ->(name) { source(dir, File.join(dir, name)) }
          gitignore = [ own.call(".gitignore") ].compact + (has_git ? [] : parent.gitignore)
          exclude = has_git ? [ source(dir, GitIgnore.exclude_path(dir)) ].compact : parent.exclude
          any_git = has_git || parent.any_git
          Context.new(
            rgignore: [ own.call(".rgignore") ].compact + parent.rgignore,
            ignore: [ own.call(".ignore") ].compact + parent.ignore,
            gitignore: gitignore, exclude: exclude, any_git: any_git
          ).tap do |ctx|
            ctx.ordered = ctx.rgignore + ctx.ignore + (any_git ? gitignore + exclude + [ global ].compact : [])
          end
        end
      end

      def source(dir, path)
        content = path && File.file?(path) ? SafeFile.read(path) : nil
        rules = content ? GitIgnore.parse(content) : []
        rules.empty? ? nil : { dir: dir, rules: rules }
      end

      # Matched against the root, as ripgrep matches its global file against
      # the directory it searches.
      def global
        return @global if defined?(@global)

        @global = source(@root, GitIgnore.global_excludes_path(@root))
      end
    end

    # A `.git` file's `gitdir:` leads to a worktree's `commondir`; a submodule
    # has none and reads no exclude (dir.rs `resolve_git_commondir`).
    def exclude_path(dir)
      dot_git = File.join(dir, ".git")
      return File.join(dot_git, "info", "exclude") if File.directory?(dot_git)

      line = File.foreach(dot_git).first.to_s.strip
      return nil unless line.start_with?("gitdir: ")

      git_dir = File.expand_path(line.delete_prefix("gitdir: "), dir)
      common = File.foreach(File.join(git_dir, "commondir")).first.to_s.strip
      return nil if common.empty?

      File.join(File.expand_path(common, git_dir), "info", "exclude")
    rescue SystemCallError, IOError
      nil
    end

    # `core.excludesFile` as git resolves it from the app's directory, or the
    # default git uses when it is unset.
    def global_excludes_path(root)
      configured, status = Open3.capture2("git", "config", "--get", "core.excludesFile", chdir: root)
      configured = configured.to_s.strip
      return File.expand_path(configured) if status.success? && !configured.empty?

      xdg = ENV["XDG_CONFIG_HOME"].to_s
      File.join(xdg.empty? ? File.join(Dir.home, ".config") : xdg, "git", "ignore")
    rescue StandardError
      nil
    end

    # git's core.ignorecase, probed through .gitignore's own name: the doctor's
    # question, not the search's (ripgrep matches case-sensitively).
    def case_insensitive?(root)
      gitignore = File.join(root.to_s, ".gitignore")
      File.exist?(gitignore) && File.identical?(gitignore, File.join(root.to_s, ".GITIGNORE"))
    rescue StandardError
      false
    end

    def matches?(rule, path, case_insensitive: false)
      base = rule[:base].to_s
      unless base.empty?
        return false unless path.start_with?("#{base}/")

        path = path.delete_prefix("#{base}/")
      end

      flags = File::FNM_PATHNAME | File::FNM_DOTMATCH
      flags |= File::FNM_CASEFOLD if case_insensitive
      if rule[:anchored]
        File.fnmatch?(rule[:pattern], path, flags) || path == rule[:pattern]
      else
        File.fnmatch?(rule[:pattern], File.basename(path), flags)
      end
    end
  end
end
