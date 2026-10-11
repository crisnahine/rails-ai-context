# frozen_string_literal: true

require "concurrent"
require "pathname"
require_relative "safe_path"

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

      enclosing = enclosing_relative(path, root)
      return enclosing if enclosing

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
      return carried if SafePath.absolute?(carried)

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
      return true if gem_roots.any? { |gem_root| path.start_with?(gem_root) }
      return false if enclosing_relative(path, root)

      gem_checkouts.any? { |dir, _name| path.start_with?(dir) }
    end

    # The relative form, or nil for a path no portable form names: the
    # context is committed, so an absolute path is never carried.
    def portable(path, root)
      relative = relativize(path, root)
      relative unless SafePath.absolute?(relative)
    end

    # For free text such as an exception message, which names a file by its
    # absolute path, often through the resolved form of the root (/private/tmp).
    def relativize_text(text, root)
      root = root.to_s
      return text.to_s if root.empty?

      real = File.realpath(root) rescue root
      prefixes = [ root, real ].uniq.sort_by { |prefix| -prefix.length }.map { |prefix| Regexp.escape(prefix) }
      alternation = prefixes.join("|")
      text.to_s
        .gsub(%r{(\A|[\s"'`(:\[=,])(?:#{alternation})/}, '\1')
        .gsub(%r{(\A|[\s"'`(:\[=,])(?:#{alternation})(?=\z|[\s"'`)\],;:])}, '\1.')
    end

    # A file of the gem the app sits inside (an engine's test/dummy) is the
    # app's own source: "../../app/models/x.rb". Compared as real paths, since
    # Bundler and the autoloader can spell one directory two ways (/tmp, /private/tmp).
    def enclosing_relative(path, root)
      real_root, gem_dir = enclosing_gem(root)
      return nil unless gem_dir

      real = real_path(path)
      return nil unless real.start_with?("#{gem_dir}/")

      Pathname.new(real).relative_path_from(Pathname.new(real_root)).to_s
    end

    ENCLOSING = Concurrent::Map.new
    private_constant :ENCLOSING

    # [real root, real dir of the loaded gem holding it, or nil].
    def enclosing_gem(root)
      return nil if root.empty?

      ENCLOSING.compute_if_absent(root) do
        real_root = real_path(root)
        dir = Gem.loaded_specs.each_value.filter_map { |spec|
          next if spec.default_gem?

          dir = real_path(spec.full_gem_path.to_s)
          dir if real_root.start_with?("#{dir}/")
        }.max_by(&:length)
        [ real_root, dir ].freeze
      end
    end

    def real_path(path)
      File.realpath(path)
    rescue SystemCallError
      File.expand_path(path)
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

    # A file a loaded gem ships. A `path:` gem kept in the repo, or a gem the
    # app sits inside (an engine's dummy app), is the app's own source; a
    # bundle installed under the root (vendor/bundle, .bundle) is still the gems'.
    def gem_file?(path, root)
      path = path.to_s
      root = "#{root.to_s.chomp(File::SEPARATOR)}#{File::SEPARATOR}"
      Gem.loaded_specs.each_value.any? do |spec|
        dir = "#{spec.full_gem_path}#{File::SEPARATOR}"
        path.start_with?(dir) && !app_owned_gem?(spec, dir, root)
      end
    end

    def app_owned_gem?(spec, dir, root)
      return true if root.start_with?(dir)
      return false unless dir.start_with?(root) && defined?(Bundler::Source::Path)

      source = spec.respond_to?(:source) ? spec.source : nil
      source.is_a?(Bundler::Source::Path) && !source.is_a?(Bundler::Source::Git)
    end

    # A gem the Gemfile takes from path: or git: is never unpacked under a
    # gem root, so its own checkout is the only prefix that names it. Longest
    # first, because one checkout can sit inside another. Kept per set of
    # loaded gems: a gem activated later is a checkout too.
    def gem_checkouts
      specs = Gem.loaded_specs
      key = [ specs.object_id, specs.size ]
      return @gem_checkouts if @gem_checkouts_key == key

      @gem_checkouts = specs.each_value.filter_map { |spec|
        dir = spec.full_gem_path.to_s
        next if dir.empty? || gem_roots.any? { |gem_root| dir.start_with?(gem_root) }
        [ dir + File::SEPARATOR, spec.full_name ]
      }.sort_by { |dir, _name| -dir.length }
      @gem_checkouts_key = key
      @gem_checkouts
    rescue => e
      RailsAiContext.debug_fail(e, [], label: "PortablePath.gem_checkouts")
    end
  end
end
