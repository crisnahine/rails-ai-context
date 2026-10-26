# frozen_string_literal: true

require "digest"
require "set"

module RailsAiContext
  # Computes a SHA256 fingerprint of key application files to detect changes.
  # Used by BaseTool to invalidate cached introspection when files change.
  class Fingerprinter
    # One scope for fingerprint and watcher; app/, test/ and spec/ whole since readers scan any file there.
    WATCHED_DIRS = (%w[
      app/models
      app/controllers
      app/views
      app/mailers
      app/channels
      app/components
      app/helpers
      app/javascript/controllers
      app/middleware
      config
      db
      lib
      rakelib
    ] + Introspectors::ServiceClasses::ROOTS + Introspectors::JobIntrospector::JOB_DIRS + Introspectors::GrapeEndpoints::DIRS +
      %w[app test spec]).freeze

    # The file kinds a change can hide in. One list, so a walk that reports
    # a change and a walk that names it read the same tree.
    WATCHED_EXTNAMES = SourceFiles::EXTNAMES
    WATCHED_EXTENSIONS = "**/*{#{WATCHED_EXTNAMES.join(",")}}"

    # What every reader shares: the bundle and the Ruby version.
    SHARED_READS = (%w[Gemfile Gemfile.lock gems.rb gems.locked *.gemspec] + GemLock::VERSION_FILES).freeze

    # A READS glob of this shape is a tree: its folders, walked like WATCHED_DIRS, for the extensions it names.
    TREE_GLOB = %r{\A(?<dirs>[^*?\[\]]+)/\*\*/\*(?<exts>\.[\w.]+|\{\.[^{}]+\})\z}

    def self.unbrace(text)
      text.start_with?("{") && text.end_with?("}") ? text[1..-2].split(",") : [ text ]
    end
    private_class_method :unbrace

    # A folder a reader walks, the extensions it reads there, and what it skips there (READS_SKIP, root-relative).
    Tree = Struct.new(:dir, :extnames, :skip) do
      def reads?(relative, extname = File.extname(relative))
        extnames.include?(extname) && relative.start_with?("#{dir}/") && !skip&.match?(relative)
      end

      def skips_dir?(relative)
        skip&.match?("#{relative}/") || false
      end
    end

    # One outermost folder's walk: WATCHED_EXTNAMES where a source folder is inside, the trees inside it, and the
    # app's configured build output folders and the folders PathResolver.pruned? leaves out, which no walk enters.
    Walk = Struct.new(:extnames, :trees, :built, :pruned) do
      def reads?(relative)
        return false if Fingerprinter.under_any?(relative, built) || pruned&.call(File.dirname(relative))

        extname = File.extname(relative)
        extnames.include?(extname) || trees.any? { |tree| tree.reads?(relative, extname) }
      end

      # Only a folder walked for trees alone is pruned; a source walk reads every folder but the build output.
      def prunes?(relative)
        Fingerprinter.under_any?(relative, built) || pruned&.call(relative) || (extnames.empty? && trees.all? { |tree| tree.skips_dir?(relative) })
      end
    end

    # The globs from the app root each reader declares as READS, the files it opens or checks for, with its READS_SKIP.
    declared = [ [ SHARED_READS, nil ] ] + Introspector::INTROSPECTOR_MAP.values.filter_map do |reader|
      [ reader::READS, (reader::READS_SKIP if reader.const_defined?(:READS_SKIP, false)) ] if reader.const_defined?(:READS, false)
    end

    WATCHED_TREES = declared.flat_map do |globs, skip|
      globs.filter_map { |glob| glob.match(TREE_GLOB) }.flat_map do |tree|
        unbrace(tree[:dirs]).map { |dir| Tree.new(dir, unbrace(tree[:exts]).freeze, skip).freeze }
      end
    end.freeze

    # The other globs, less the ones a walk reads already. An entry that names a folder stands for every file under it.
    WATCHED_FILES = declared.flat_map(&:first).uniq.reject do |glob|
      glob.match?(TREE_GLOB) || WATCHED_TREES.any? { |tree| tree.reads?(glob) } ||
        (WATCHED_EXTNAMES.include?(File.extname(glob)) && WATCHED_DIRS.any? { |dir| glob.start_with?("#{dir}/") })
    end.freeze

    # The kinds whose homes PathResolver resolves beyond the conventional
    # tree - packs/*, engines/* and configured extras. Derived at compute
    # time so an edit in a pack invalidates the cache the way one in app/
    # does; a stale answer that looks fresh is the failure this exists to
    # prevent.
    RESOLVED_KINDS = (%w[
      app/models app/controllers app/views app/mailers
      app/channels app/components app/helpers
    ] + Introspectors::ServiceClasses::ROOTS + Introspectors::JobIntrospector::JOB_DIRS).freeze

    # jsbundling and cssbundling rewrite this on every frontend save, and no reader reads it.
    BUILD_OUTPUT = "/app/assets/builds/"
    # A test run re-records these; the VCR reader counts them and never opens one.
    CASSETTES = %r{\A(?:spec|test)/(?:[^/]+/)*(?:vcr_)?cassettes/}

    # What a reader holds so it can ask later whether the app moved. Taken
    # before the read it protects: a mark taken after introspection records
    # edits the answer never saw.
    Mark = Data.define(:digest)

    class << self
      def mark(app)
        Mark.new(digest: compute(app))
      end

      def stale?(app, mark)
        compute(app) != mark.digest
      end

      def compute(app)
        root = app.root.to_s
        digest = Digest::SHA256.new

        # Include the gem's own version so cache invalidates during gem development
        digest.update(RailsAiContext::VERSION)

        # Include gem lib directory fingerprint when using a local/path gem.
        # MEMOIZED - the gem lib contents don't change within a single process
        # lifetime unless a developer is actively editing the gem source (rare
        # audience, they should restart the server to see changes). Previously
        # this walked 123 gem files on every tool call, adding ~12ms to the
        # cached_context hot path for path:-installed users.
        digest.update(gem_lib_fingerprint(root))

        # Each path with its mtime, so a rename that keeps both moves the digest.
        watched(root).each do |file|
          digest.update(file)
          digest.update(File.mtime(File.expand_path(file, root)).to_f.to_s)
        rescue Errno::ENOENT
          # File deleted between glob and mtime read - skip
        end

        prefix = SafePath.dir_prefix(root)
        # One run, so the resolvers and the link checks answer once per fingerprint.
        RunCache.around do
          walks(root).each do |full_dir, walk|
            watched_files(full_dir, root, walk).sort.each do |path|
              digest.update(path)
              digest.update(File.mtime(path).to_f.to_s) unless cassette?(path, prefix)
            rescue Errno::ENOENT
              # File deleted between glob and mtime read - skip
            end
          end
        end

        digest.hexdigest
      end

      # The files a walk leaves out: the WATCHED_FILES that exist and the manifests in each frontend root,
      # root-relative, then the ones PackageJson reads outside the app (declared frontend_paths, the
      # workspace root), absolute.
      def watched(root)
        root = root.to_s
        prefix = SafePath.dir_prefix(root)
        names = Introspectors::FrontendFrameworkIntrospector::MANIFESTS
        inside = PackageJson.manifest_dirs(root).reject { |dir| dir == root }.flat_map do |dir|
          Dir.glob(names, base: dir).filter_map { |name| File.join(dir.delete_prefix(prefix), name) if File.file?(File.join(dir, name)) }
        end
        outside = (PackageJson.configured_outside(root) + [ PackageJson.workspace_root(root) ].compact).flat_map do |dir|
          Dir.glob(names, base: dir[:dir]).filter_map { |name| PackageJson.outside_file(dir[:dir], name)&.to_s }
        end
        (matching(root, WATCHED_FILES) + inside + outside).uniq
      end

      # The folders outside the scope dirs that hold a WATCHED_FILES file (bin,
      # .github/workflows), for a watcher; a frontend root is left out, since
      # Listen would recurse into its node_modules.
      def manifest_dirs(root)
        root = root.to_s
        scope = watched_dirs(root)
        matching(root, WATCHED_FILES).filter_map { |file| File.join(root, File.dirname(file)) unless File.dirname(file) == "." }.uniq
                                     .reject { |dir| scope.any? { |other| SafePath.contained?(dir, other) } }
      end

      # The source folders a watcher listens to: the conventional dirs plus what
      # the resolvers add for this app (packs, engines, extra_app_paths,
      # concern homes such as app/serializers/concerns). A folder only a
      # reader's tree reaches (public, docs) is left to the per-call look, as
      # the root files are, since Listen would watch every folder in it.
      def watched_dirs(root)
        # A dir under another one is already globbed and watched through it.
        SafePath.outermost(source_dirs(root))
      end

      # The outermost folders below the watched roots that PathResolver.pruned? leaves out, found by a walk that
      # enters none of them.
      def pruned_dirs(root)
        root = root.to_s
        RunCache.around do
          pending = (PathResolver.app_roots(root) + PathResolver.declared_roots(root) + PathResolver.path_gem_libs(root)).uniq - PathResolver.unwatched_roots(root)
          found = []
          while (dir = pending.pop)
            PathResolver.children(dir).each do |name|
              path = File.join(dir, name)
              next if File.symlink?(path) || !File.directory?(path)

              (PathResolver.pruned?(root, path, dir: true) ? found : pending) << path
            end
          end
          found.uniq.sort
        end
      end

      # Each outermost folder the looks walk, with its Walk.
      def walks(root)
        trees = WATCHED_TREES.select { |tree| Dir.exist?(File.join(root, tree.dir)) }
        sources = source_dirs(root)
        built = build_dirs(root)
        pruned = ->(relative) { PathResolver.pruned?(root, relative, dir: true) }
        SafePath.outermost(sources + trees.map { |tree| File.join(root, tree.dir) }).to_h do |top|
          inside = trees.select { |tree| SafePath.contained?(File.join(root, tree.dir), top) }
          [ top, Walk.new(sources.any? { |dir| SafePath.contained?(dir, top) } ? WATCHED_EXTNAMES : [], inside, built, pruned) ]
        end
      end

      # Where the app's Shakapacker or Webpacker (public_output_path) and Vite (publicOutputDir) write a build, per
      # environment, app-relative; the default folders are skipped by name already.
      def build_dirs(root)
        root = root.to_s
        RunCache.fetch([ :build_dirs, root ]) do
          packers = %w[config/shakapacker.yml config/webpacker.yml].flat_map do |file|
            sections(ConfigYaml.read(root, file, label: "build output")).filter_map do |section|
              [ section["public_root_path"] || "public", section["public_output_path"] ] if section.key?("public_output_path")
            end
          end
          (packers + vite_outputs(root)).filter_map { |public_dir, output| inside_public(root, public_dir.to_s, output.to_s) }.uniq.freeze
        end
      end

      def under_any?(relative, dirs)
        dirs.any? { |dir| relative == dir || relative.start_with?("#{dir}/") }
      end

      def scope_dirs(root)
        (source_dirs(root) + WATCHED_TREES.map { |tree| File.join(root, tree.dir) }.select { |dir| Dir.exist?(dir) }).uniq
      end

      def source_dirs(root)
        conventional = WATCHED_DIRS.map { |dir| File.join(root, dir) }
        resolved = RESOLVED_KINDS.flat_map { |kind| PathResolver.dirs_for(root, kind) }

        (conventional + resolved + ConcernPaths.searched(root) + stimulus_dirs(root)).uniq.select { |dir| Dir.exist?(dir) }
      end

      # The controller homes the Stimulus introspector reads, so an edit under
      # app/webpacker or frontend/ invalidates the cache like one in app/javascript.
      def stimulus_dirs(root)
        Introspectors::StimulusIntrospector.controller_paths(root.to_s)
                                           .map { |path, _js_root| File.dirname(path) }.uniq
      end

      # Which directories hold a file newer than the given time, each named by
      # the narrowest scope dir that holds it, the way an app author would write it.
      def changed_since(root, time)
        base = File.expand_path(root.to_s)
        RunCache.around do
          named = scope_dirs(base)
          prefix = SafePath.dir_prefix(base)
          walks(base).flat_map { |dir, walk| watched_files(dir, base, walk).select { |path| !cassette?(path, prefix) && newer?(path, time) } }
                            .map { |path| named.select { |dir| path.start_with?("#{dir}/") }.max_by(&:size) }
                            .uniq.map { |dir| dir.delete_prefix(prefix) }
        end
      end

      private

      def sections(data)
        data.is_a?(Hash) ? data.values.select { |section| section.is_a?(Hash) } : []
      end

      # vite_ruby's defaults per environment, under its `all` section and then the environment's own.
      VITE_OUTPUT = Hash.new("vite").merge("development" => "vite-dev", "test" => "vite-test").freeze

      def vite_outputs(root)
        data = ConfigYaml.read(root, "config/vite.json", label: "build output")
        return [] unless data.is_a?(Hash)

        all = data["all"].is_a?(Hash) ? data["all"] : {}
        ([ [ "all", all ] ] + data.except("all").select { |_, section| section.is_a?(Hash) }.map { |env, section| [ env, all.merge(section) ] })
          .filter_map do |env, section|
            next unless section.key?("publicDir") || section.key?("publicOutputDir")

            [ section["publicDir"] || "public", section["publicOutputDir"] || VITE_OUTPUT[env] ]
          end
      end

      # A folder inside the app below its public root, or nil: an empty output path names the public root itself.
      def inside_public(root, public_dir, output)
        prefix = SafePath.dir_prefix(File.expand_path(root))
        public_path = File.expand_path(public_dir, root)
        path = File.expand_path(output, public_path)
        path.delete_prefix(prefix) if path.start_with?(prefix) && path != public_path
      end

      # A folder counts only where an entry names it (`.github/workflows`), not where a
      # wildcard meant for files meets one (`bin/*`), and a linked folder is never entered
      # (tested without the trailing slash, which would follow the link).
      def matching(root, globs)
        globs.flat_map do |glob|
          Dir.glob(glob, base: root).flat_map do |hit|
            full = File.join(root, hit)
            next [ hit ] if File.file?(full)
            next [] if glob.end_with?("*") || File.symlink?(full.chomp("/")) || !File.directory?(full)

            Dir.glob("**/*", base: full).filter_map { |file| File.join(hit, file) if File.file?(File.join(full, file)) }
          end
        end.uniq
      end

      # One walk with an extension filter: a brace glob walks the tree once per extension.
      # The glob lists a directory link and enters none, so a directory linked in
      # from the app's repository, which the readers walk (FileWalk), is globbed
      # on its own, whatever its name (`shared.v2` too, as the readers take it).
      def watched_files(dir, root, walk, seen = Set.new)
        real_dir = File.realpath(dir)
        return [] unless seen.add?(real_dir)

        prefix = SafePath.dir_prefix(root)
        files = []
        linked = []
        entries(dir, walk, prefix).each do |relative|
          path = File.join(dir, relative)
          if walk.reads?(path.delete_prefix(prefix))
            files << path unless path.include?(BUILD_OUTPUT)
          elsif File.symlink?(path) && File.directory?(path)
            target = File.realpath(path)
            # A link into the tree globbed here leads where the glob went already.
            linked << path if !SafePath.contained?(target, real_dir) && PathResolver.enter_link?(target, real_dir, root)
          end
        rescue SystemCallError
          next
        end
        files + linked.flat_map { |path| watched_files(path, root, walk, seen) }
      rescue SystemCallError
        []
      end

      # The entries below `dir` as `**/*` lists them, relative to it so its path is never read as glob
      # syntax. A walk for trees alone never enters a folder its trees skip (node_modules, uploads),
      # and gives only the files it reads and the folder links, so no other file is stat'd.
      def entries(dir, walk, prefix)
        return Dir.glob("**/*", base: dir) unless walk.extnames.empty?

        found = []
        pending = [ "" ]
        while (below = pending.pop)
          names = begin
            Dir.children(File.join(dir, below))
          rescue SystemCallError
            []
          end
          # `*/` names the folders, links to one included, without a stat per file.
          folders = Dir.glob("*/", base: File.join(dir, below)).to_set { |name| name.chomp("/") }
          names.each do |name|
            next if name.start_with?(".")

            relative = below.empty? ? name : File.join(below, name)
            full = File.join(dir, relative)
            if !folders.include?(name)
              found << relative if walk.reads?(full.delete_prefix(prefix))
            elsif File.symlink?(full)
              found << relative
            elsif !walk.prunes?(full.delete_prefix(prefix))
              pending << relative
            end
          end
        end
        found
      end

      def cassette?(path, prefix)
        path.delete_prefix(prefix).match?(CASSETTES)
      end

      def newer?(path, time)
        File.mtime(path) > time
      rescue Errno::ENOENT
        false
      end

      # Memoized gem-lib fingerprint. Sampled once per process: only a
      # developer editing the gem's own source sees it move, and a restart
      # shows that edit.
      def gem_lib_fingerprint(root)
        @gem_lib_fingerprint ||= compute_gem_lib_fingerprint(root)
      end

      def compute_gem_lib_fingerprint(root)
        gem_lib = File.expand_path("../../..", __FILE__)
        return "" unless gem_lib.start_with?(root) || (defined?(Bundler) && local_gem_path?)

        sub = Digest::SHA256.new
        PathResolver.glob(gem_lib, "**/*.rb").sort.each do |path|
          sub.update(File.mtime(path).to_f.to_s)
        rescue Errno::ENOENT
          # File deleted between glob and mtime read - skip
        end
        sub.hexdigest
      end

      # Detect if this gem is loaded via a local path (path: in Gemfile)
      def local_gem_path?
        spec = Bundler.rubygems.find_name("rails-ai-context").first
        return false unless spec
        spec.source.is_a?(Bundler::Source::Path)
      rescue => e
        RailsAiContext.debug_fail(e, false, label: "local_gem_path?")
      end
    end
  end
end
