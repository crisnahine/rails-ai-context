# frozen_string_literal: true

require "json"
require "pathname"

module RailsAiContext
  # Which npm packages an app depends on, read once per package.json, and the
  # one answer every caller gets: a package is present when it is named in
  # dependencies or devDependencies, so an `overrides` pin for a CVE fix is
  # not the app's bundler. A tool reached through its own scope counts, since
  # `@tailwindcss/vite` is how an app depends on tailwindcss.
  #
  # An app's manifest is not always at its root. A Rails app can keep a root
  # package.json for importmap and a whole Vue app under frontend/, so every
  # manifest is read and merged, the root one winning a version disagreement.
  # Callers ask what the app depends on, never which directory holds the file.
  #
  # Two kinds of directory outside the app root are read, for frontend
  # manifests only: a `frontend_paths` entry the app declared, and the JS
  # workspace root a lockfile sits in. Each is read with the sensitive-file
  # and symlink rules applied relative to that directory.
  module PackageJson
    # Where a frontend app lives when it has not been declared through
    # `frontend_paths`. Same list the frontend introspector falls back to.
    FRONTEND_DIRS = %w[app/frontend app/javascript frontend client].freeze

    # In the order a package manager is named when several lockfiles exist.
    LOCKFILES = {
      "bun.lock" => "bun", "bun.lockb" => "bun", "pnpm-lock.yaml" => "pnpm",
      "yarn.lock" => "yarn", "package-lock.json" => "npm"
    }.freeze

    MUTEX = Mutex.new
    CACHE = {}
    private_constant :MUTEX, :CACHE

    module_function

    def deps(root)
      outside = configured_outside(root).filter_map { |dir| outside_file(dir[:dir], "package.json") }
      inside = manifest_dirs(root).map { |dir| File.join(dir, "package.json") }
      (outside + inside).reduce({}) { |merged, path| merged.merge(read(path)) }
    end

    # The first lockfile found in the app root, then in each frontend directory,
    # with that directory's label (nil for the app root).
    def package_manager(root)
      root = root.to_s
      name = LOCKFILES.find { |file, _| File.exist?(File.join(root, file)) }&.last
      return [ name, nil ] if name

      (frontend_roots(root) + [ workspace_root(root) ].compact).each do |dir|
        name = LOCKFILES.find { |file, _| outside_file(dir[:dir], file) }&.last
        return [ name, dir[:label] ] if name
      end
      nil
    end

    # Every directory besides the app root that holds frontend config: the
    # frontend dirs inside it, then the declared ones outside it.
    def frontend_roots(root)
      root = root.to_s
      inside = manifest_dirs(root)[0...-1].map { |dir| { dir: dir, label: dir.delete_prefix("#{root}/") } }
      inside + configured_outside(root)
    end

    # Declared frontend_paths entries that resolve to a directory outside the
    # app root, labelled as the app wrote them.
    def configured_outside(root)
      real_root = File.realpath(root.to_s)
      declared_paths.filter_map do |path|
        real = File.realpath(File.join(root.to_s, path.to_s))
        next if SafePath.contained?(real, real_root) || !File.directory?(real)

        { dir: real, label: path.to_s, source: "configuration" }
      rescue SystemCallError
        nil
      end
    rescue SystemCallError
      []
    end

    # The nearest ancestor that holds a lockfile or declares workspaces,
    # never above the git root, and never outside a git repository: package
    # managers write one lockfile at the workspace root.
    def workspace_root(root)
      real_root = File.realpath(root.to_s)
      repo = SafePath.git_root(real_root) or return nil
      candidates = []
      dir = real_root
      candidates << (dir = File.dirname(dir)) until dir == repo
      found = candidates.find { |candidate| workspace?(candidate) }
      return nil unless found

      { dir: found, label: Pathname.new(found).relative_path_from(Pathname.new(real_root)).to_s, source: "workspace" }
    rescue SystemCallError
      nil
    end

    # The realpath of a file in a directory outside the app root, or nil when
    # it is missing, sensitive or a symlink out of that directory. A lockfile
    # past max_file_size still exists.
    def outside_file(dir, name)
      found = SafePath.locate(name, under: dir, links: false)
      found.realpath if found.ok? || found.refusal == :too_large
    end

    def present?(root, name)
      all = deps(root)
      return true if all.key?(name.to_s)

      scope = "@#{name}/"
      all.any? { |dep, _| dep.start_with?(scope) }
    end

    # Frontend dirs first, app root last, so the root manifest wins a clash.
    def manifest_dirs(root)
      root = root.to_s
      frontend_dirs(root).select { |dir| Dir.exist?(dir) && contained?(dir, root) } << root
    end

    def frontend_dirs(root)
      declared = declared_paths
      (declared.any? ? declared : FRONTEND_DIRS).map { |dir| File.join(root, dir.to_s) }
    end
    private_class_method :frontend_dirs

    def declared_paths
      configured = RailsAiContext.configuration.respond_to?(:frontend_paths) &&
                   RailsAiContext.configuration.frontend_paths
      configured.is_a?(Array) ? configured : []
    end
    private_class_method :declared_paths

    def workspace?(dir)
      return true if LOCKFILES.keys.any? { |file| outside_file(dir, file) }

      content, = SafePath.read("package.json", under: dir)
      data = content && JSON.parse(content)
      data.is_a?(Hash) && data.key?("workspaces")
    rescue JSON::ParserError
      false
    end
    private_class_method :workspace?

    def contained?(dir, root)
      SafePath.contained?(File.realpath(dir), File.realpath(root))
    rescue SystemCallError
      false
    end
    private_class_method :contained?

    def read(path)
      stamp = stamp(path)

      MUTEX.synchronize do
        cached = CACHE[path]
        return cached[:deps] if cached && cached[:stamp] == stamp

        parsed = stamp ? parse(path) : {}
        CACHE[path] = { stamp: stamp, deps: parsed }
        parsed
      end
    end
    private_class_method :read

    def stamp(path)
      [ File.mtime(path), File.size(path) ]
    rescue SystemCallError
      nil
    end
    private_class_method :stamp

    def parse(path)
      content = SafeFile.read(path)
      return {} unless content

      data = JSON.parse(content)
      return {} unless data.is_a?(Hash)

      deps = data["dependencies"]
      dev = data["devDependencies"]
      (deps.is_a?(Hash) ? deps : {}).merge(dev.is_a?(Hash) ? dev : {})
    rescue JSON::ParserError, SystemCallError
      {}
    end
    private_class_method :parse
  end
end
