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
