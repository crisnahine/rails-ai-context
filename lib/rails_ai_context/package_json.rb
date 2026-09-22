# frozen_string_literal: true

require "json"

module RailsAiContext
  # Which npm packages an app depends on, read once per package.json, and the
  # one answer every caller gets: a package is present when it is named in
  # dependencies or devDependencies, so an `overrides` pin for a CVE fix is
  # not the app's bundler. A tool reached through its own scope counts, since
  # `@tailwindcss/vite` is how an app depends on tailwindcss.
  module PackageJson
    MAX_SIZE = 256 * 1024

    MUTEX = Mutex.new
    CACHE = {}
    private_constant :MUTEX, :CACHE

    module_function

    def deps(root)
      path = File.join(root.to_s, "package.json")
      stamp = stamp(path)

      MUTEX.synchronize do
        cached = CACHE[path]
        return cached[:deps] if cached && cached[:stamp] == stamp

        parsed = stamp ? parse(path) : {}
        CACHE[path] = { stamp: stamp, deps: parsed }
        parsed
      end
    end

    def present?(root, name)
      all = deps(root)
      return true if all.key?(name.to_s)

      scope = "@#{name}/"
      all.any? { |dep, _| dep.start_with?(scope) }
    end

    def stamp(path)
      [ File.mtime(path), File.size(path) ]
    rescue SystemCallError
      nil
    end
    private_class_method :stamp

    def parse(path)
      content = SafeFile.read(path, max_size: MAX_SIZE)
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
