# frozen_string_literal: true

module RailsAiContext
  # Rewrites a path so it means the same thing on another machine. What is
  # generated here ends up in .ai-context.json, which the app commits: an
  # absolute path is wrong on every other checkout, wrong again after a Ruby
  # or gem upgrade, and it carries the generating developer's home directory
  # into the repository. App paths go app-relative; gem paths keep the gem
  # and version and drop the install prefix.
  #
  # Distinct from PathResolver, which answers where a kind of app code lives.
  module PortablePath
    module_function

    def relativize(path, root)
      path = path.to_s
      root = root.to_s
      return path.delete_prefix("#{root}/") if !root.empty? && path.start_with?("#{root}/")

      gem_roots.each do |gem_root|
        return path.delete_prefix(gem_root) if path.start_with?(gem_root)
      end

      gem_checkouts.each do |dir, name|
        return File.join(name, path.delete_prefix(dir)) if path.start_with?(dir)
      end
      path
    end

    # Marker on a path that is relative to a gem, not to the app root.
    GEM_MARKER = "gem:"

    # The form for a field a reader resolves against the app root - a model's
    # file in .ai-context.json, say. A gem-owned path is not there, and the
    # bare relative form ("doorkeeper-5.9.6/lib/...") does not say so.
    def relativize_marked(path, root)
      relative = relativize(path, root)
      return relative if relative == path.to_s

      gem_path?(path, root) ? "#{GEM_MARKER}#{relative}" : relative
    end

    # The way back, for a reader that has to open the file a carried path
    # names. A marked path belongs to a gem and joining it to the app root
    # opens nothing, which is how a gem-owned model lost its structure and its
    # callback bodies. Returns nil when there is no path to open.
    def resolve(carried, root)
      carried = carried.to_s
      return nil if carried.empty?
      return carried if carried.start_with?(File::SEPARATOR)

      unless carried.start_with?(GEM_MARKER)
        return root.to_s.empty? ? carried : File.join(root.to_s, carried)
      end

      within_gem = carried.delete_prefix(GEM_MARKER)
      gem_roots.map { |gem_root| File.join(gem_root, within_gem) }
               .find { |path| File.exist?(path) } ||
        gem_checkouts.filter_map { |dir, name|
          File.join(dir, within_gem.delete_prefix("#{name}/")) if within_gem.start_with?("#{name}/")
        }.find { |path| File.exist?(path) } ||
        File.join(gem_roots.first.to_s, within_gem)
    end

    # True when relativize answers this path against a gem prefix rather than
    # against the app root.
    def gem_path?(path, root)
      path = path.to_s
      root = root.to_s
      return false if !root.empty? && path.start_with?("#{root}/")

      gem_roots.any? { |gem_root| path.start_with?(gem_root) } ||
        gem_checkouts.any? { |dir, _name| path.start_with?(dir) }
    end

    def relativize_all(paths, root)
      Array(paths).map { |path| relativize(path, root) }.uniq
    end

    # Every prefix a gem can be unpacked under, trailing separator included so
    # a prefix cannot match a sibling directory that merely starts the same.
    def gem_roots
      @gem_roots ||= (Gem.path + [ Gem.default_dir ]).compact.uniq
        .map { |dir| File.join(dir, "gems") + File::SEPARATOR }
    end

    # A gem the Gemfile takes from path: or git: is never unpacked under a
    # gem root, so its own checkout is the only prefix that names it. Longest
    # first, because one checkout can sit inside another.
    def gem_checkouts
      @gem_checkouts ||= Gem.loaded_specs.each_value.filter_map { |spec|
        dir = spec.full_gem_path.to_s
        next if dir.empty? || gem_roots.any? { |gem_root| dir.start_with?(gem_root) }
        [ dir + File::SEPARATOR, spec.full_name ]
      }.sort_by { |dir, _name| -dir.length }
    rescue => e
      $stderr.puts "[rails-ai-context] PortablePath.gem_checkouts failed: #{e.message}" if ENV["DEBUG"]
      []
    end
  end
end
