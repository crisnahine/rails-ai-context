# frozen_string_literal: true

require "json"

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
  module PackageJson
    # Where a frontend app lives when it has not been declared through
    # `frontend_paths`. Same list the frontend introspector falls back to.
    FRONTEND_DIRS = %w[app/frontend app/javascript frontend client].freeze

    MUTEX = Mutex.new
    CACHE = {}
    private_constant :MUTEX, :CACHE

    module_function

    def deps(root)
      manifest_dirs(root).reduce({}) do |merged, dir|
        merged.merge(read(File.join(dir, "package.json")))
      end
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
      configured = RailsAiContext.configuration.respond_to?(:frontend_paths) &&
                   RailsAiContext.configuration.frontend_paths
      declared = configured.is_a?(Array) && configured.any? ? configured : FRONTEND_DIRS
      declared.map { |dir| File.join(root, dir.to_s) }
    end
    private_class_method :frontend_dirs

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
