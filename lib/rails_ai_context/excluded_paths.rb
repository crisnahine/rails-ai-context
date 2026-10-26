# frozen_string_literal: true

module RailsAiContext
  # The one reading of `excluded_paths`: each entry a gitignore rule from the
  # app root, as ripgrep reads its `--glob=!` globs, so `docs` is a name at any
  # depth, `app/javascript/legacy` a path from the root, and `log` never `logo`.
  module ExcludedPaths
    module_function

    # A predicate over a path below `root` (relative, or spelled under it) and
    # whether that path is a directory. A walk that prunes on it asks only for
    # the entries it reaches, so an excluded folder's contents never come up.
    def matcher(root, patterns)
      rules = GitIgnore.parse(Array(patterns).join("\n"))
      prefix = SafePath.dir_prefix(root.to_s)
      ->(path, dir) { GitIgnore.verdict(rules, path.to_s.delete_prefix(prefix), dir: dir) == :ignore }
    end
  end
end
