# frozen_string_literal: true

require "concurrent"

module RailsAiContext
  # One answer to "where does this app keep its concerns", for every surface
  # that lists or counts them.
  #
  # `GetConcern` hardcoded two directories and `ActiveSupportIntrospector`
  # hardcoded five, so a single run answered 80 concerns and 81 concerns for
  # the same app, and the mailer concern only the second one found could not be
  # reached through the first at all. Neither list matches Rails, which
  # autoloads these paths by glob - `Rails::Engine::Configuration#paths` adds
  # `app` with `glob: "{*,*/concerns}"` - so any hardcoded list is one entry
  # behind an app that keeps `app/serializers/concerns`.
  module ConcernPaths
    module_function

    # Kept for one run, as PathResolver.dirs_for is: `find_file` asks once per
    # concern reference, and a concerns directory created later has to be seen.
    #
    # @param root [String] application root
    # @return [Array<String>] absolute concern directories that exist
    def resolve(root)
      configured = Array(RailsAiContext.configuration.concern_paths).map(&:to_s)
      RunCache.fetch([ :concern_dirs_spelled, root.to_s, configured ]) do
        RunCache.fetch([ :concern_dirs, PathResolver.root_key(root.to_s), configured ]) { discover(root) }
      end
    end

    def discover(root)
      # An app that names its concern directories means those and no others -
      # the setting has to be able to narrow, or it only ever adds noise. It is
      # unset by default, which is what asks for discovery.
      configured = RailsAiContext.configuration.concern_paths
      dirs =
        if configured.nil?
          # Every app tree the app has, not just the one at the root: a
          # packwerk pack or an in-repo engine keeps its own app/*/concerns.
          # `dirs_for` cannot take the glob directly - it tests each candidate
          # with `Dir.exist?`, which a literal `app/*/concerns` never passes -
          # so the app trees are resolved first and globbed here. app/concerns
          # is one of Rails' `app/*` roots, and holds top-level concerns too.
          PathResolver.dirs_for(root, "app").flat_map { |app_dir| Dir.glob(File.join(app_dir, "{concerns,*/concerns}")) }
        else
          # A path that is already absolute is taken as given; `File.join`
          # would graft it onto the root and point at nothing.
          Array(configured).map { |rel| File.absolute_path?(rel) ? rel : File.join(root, rel) }
        end

      dirs.uniq.select { |dir| Dir.exist?(dir) }.sort.freeze
    end
    private_class_method :discover

    # A concern outside every concerns directory, and the autoload root it is named from.
    Outside = Struct.new(:path, :root_dir, :type)

    # The trees no Ruby constant lives in, which are also the big ones.
    NON_RUBY_ROOTS = %w[assets javascript].freeze

    # An ActiveSupport::Concern under an autoload root, or a module in a nested concerns
    # directory. Configured concern paths mean those and no others, so this finds none.
    #
    # @return [Array<Outside>]
    def outside(root)
      return [] unless RailsAiContext.configuration.concern_paths.nil?

      inside = resolve(root)
      outside_roots(root, inside).flat_map do |dir|
        Dir.glob(File.join(dir, "**", "*.rb")).sort.filter_map do |path|
          next if inside.any? { |concerns| path.start_with?("#{concerns}/") }

          relative = path.delete_prefix("#{dir}/")
          source = SafeFile.read(path)
          next unless relative.split("/")[0..-2].include?("concerns") || source&.include?("ActiveSupport::Concern")
          next unless Introspectors::ServiceClasses.concern?(relative, source)

          Outside.new(path, dir, root_type(dir))
        end
      end
    rescue StandardError => e
      RailsAiContext.debug_fail(e, [], label: "ConcernPaths.outside")
    end

    def outside_roots(root, inside)
      app_roots = PathResolver.app_roots(root).reject { |dir| NON_RUBY_ROOTS.include?(File.basename(dir)) }
      (app_roots + PathResolver.declared_roots(root)).uniq - inside
    end
    private_class_method :outside_roots

    # `app/services` holds service concerns; a declared root such as lib is
    # named for itself.
    def root_type(dir)
      segment = dir[%r{/app/([^/]+)/?\z}, 1]
      segment ? segment.singularize : File.basename(dir)
    end
    private_class_method :root_type

    # The one list the concern listing's headings and its `type:` filter both read,
    # so neither names a value the other refuses.
    def types(root)
      holding = resolve(root).select { |dir| Dir.glob(File.join(dir, "**", "*.rb")).any? }
      (holding.map { |dir| type_for(dir) } + outside(root).map(&:type)).uniq.sort
    end

    # The owner segment names the type: `app/mailers/concerns` holds mailer
    # concerns. Singular so a filter reads `type: "mailer"`.
    def type_for(dir)
      segment = dir[%r{/app/([^/]+)/concerns/?\z}, 1]
      # An app root named app (Docker's /app) puts app/concerns at app/app/concerns.
      segment && segment != "app" ? segment.singularize : "other"
    end

    # The path only approximates the declared constant: an app inflection makes
    # `sdg/tag_list.rb` declare SDG::TagList.
    #
    # @param path [String] the concern file
    # @param dir [String] the concerns directory holding it
    # @param source [String, nil] the file's source; nil leaves the path's name
    def name_for(path, dir, source)
      path_name = path.delete_prefix("#{dir}/").sub(/\.rb\z/, "").camelize
      Introspectors::DeclaredConstant.named(source, path_name)
    end

    # Source file for a concern named by its constant, or nil.
    #
    # @param root [String] application root
    # @param concern_name [String] constant name, e.g. "BulkMailSettingsConcern"
    # @param prefer [String, nil] owner kind ("model", "controller") whose
    #   concerns directory is searched first. `resolve` sorts, so without it
    #   app/controllers/concerns wins a basename two owners share.
    # @param within [String, nil] the enclosing constant of the reference. A
    #   bare `include DebugConcern` inside Fasp::Provider resolves at runtime
    #   to Fasp::Provider::DebugConcern, which the literal spelling misses.
    # @param dirs [Array<String>, nil] pre-resolved concern directories
    # @param outer [Boolean] whether a module with no file of its own is found in its outer constant's file
    def find_file(root, concern_name, prefer: nil, within: nil, dirs: nil, outer: true)
      found = find_named(root, concern_name, prefer: prefer, within: within, dirs: dirs)
      (found || (outer_named(root, concern_name, within: within, dirs: dirs) if outer))&.last
    end

    # The source of the module a reference resolves to: its file, or its own node in its outer constant's file.
    def module_source(root, concern_name, prefer: nil, within: nil)
      path = find_file(root, concern_name, prefer: prefer, within: within, outer: false)
      return SafeFile.read(path) if path

      name, path = outer_named(root, concern_name, within: within)
      path && Introspectors::DeclaredConstant.module_node(AstCache.parse(path).value, name)&.slice
    end

    # [`Outer::Inner`, Outer's file] for a module with no file of its own, which Zeitwerk loads with Outer.
    def outer_named(root, concern_name, within: nil, dirs: nil)
      RunCache.fetch([ :outer_named, root, concern_name, within, dirs ]) do
        candidate_names(concern_name, within).lazy.filter_map do |name|
          outer = name.rpartition("::").first
          path = !outer.empty? && find_file(root, outer, dirs: dirs)
          [ name, path ] if path && Introspectors::DeclaredConstant.module_node(AstCache.parse(path).value, name)
        end.first
      end
    end

    # [the constant the reference resolves to, its file] for `find_file`'s file, or nil.
    def find_named(root, concern_name, prefer: nil, within: nil, dirs: nil)
      # Every model asks for the same few names, each across hundreds of directories.
      RunCache.fetch([ :find_named, root, concern_name, prefer, within, dirs ]) do
        # Wherever Zeitwerk would look, plus an in-repo path gem's lib. A lib the app does
        # not add to its autoload paths holds nothing it autoloads, so it is skipped.
        searched = ordered_dirs(root, prefer, dirs) + PathResolver.app_roots(root) + PathResolver.declared_roots(root) +
                   PathResolver.path_gem_libs(root)
        candidate_names(concern_name, within).lazy.filter_map do |name|
          underscore = name.underscore
          next if underscore.empty? || underscore.include?("..")

          found = searched.find { |dir| file_exist?(dir, "#{underscore}.rb") }
          [ name, File.join(found, "#{underscore}.rb") ] if found
        end.first
      end
    end

    # Each directory is listed once per run and a candidate is walked down
    # from its root, so a name no listing holds costs no stat: OpenProject
    # names concerns against a hundred roots. A listing matches a segment the
    # way the filesystem does, case-folded where the disk ignores case, so a
    # lookup answers the same inside a run and outside one.
    def file_exist?(dir, relative)
      current = dir
      relative.split("/").each do |segment|
        entries = listing(current)
        return false unless entries.include?(segment) || entries.folded&.include?(segment.downcase)

        current = File.join(current, segment)
      end
      RunCache.fetch([ :exist, current ]) { File.exist?(current) }
    end

    # `relative` as the disk spells it: an app acronym underscores `ActivityPub` to `activitypub`,
    # where this process, which has none of the app's acronyms, writes `activity_pub`. Nil when absent.
    def spelled(dir, relative)
      return relative if file_exist?(dir, relative)

      current = dir
      segments = relative.split("/").map do |segment|
        found = listing(current).squashed[segment.delete("_")] or return nil
        current = File.join(current, found)
        found
      end
      RunCache.fetch([ :exist, current ]) { File.exist?(current) } ? segments.join("/") : nil
    end

    Listing = Struct.new(:names, :folded) do
      def include?(name) = names.include?(name)

      def squashed
        @squashed ||= names.each_with_object({}) { |name, found| found[name.delete("_")] ||= name }
      end
    end

    def listing(dir)
      RunCache.fetch([ :children, dir ]) do
        names = PathResolver.children(dir)
        Listing.new(names.to_set, (names.map(&:downcase).to_set if case_insensitive?(dir, names)))
      end
    end
    private_class_method :listing

    # Whether this directory's filesystem ignores case: an entry answers to its
    # name with the case swapped. A directory with no lettered entry has no
    # lookup the answer could change.
    def case_insensitive?(dir, names)
      name = names.find { |entry| entry.swapcase != entry }
      return false unless name

      File.identical?(File.join(dir, name), File.join(dir, name.swapcase))
    end
    private_class_method :case_insensitive?

    def ordered_dirs(root, prefer, dirs = nil)
      dirs ||= resolve(root)
      return dirs unless prefer

      dirs.partition { |dir| type_for(dir) == prefer }.flatten
    end

    # The enclosing namespaces from the innermost outward, then the reference
    # itself - Ruby's own constant lookup order, which reaches the top level
    # last. Bare-name-first would bind Fasp::Provider's `include DebugConcern`
    # to a top-level DebugConcern the runtime never sees. A qualified name's
    # first segment is looked up the same way; only a leading `::` skips it.
    def candidate_names(concern_name, within)
      name = concern_name.to_s
      return [ name.delete_prefix("::") ] if name.start_with?("::")
      return [ name ] if within.nil?

      scopes = within.to_s.split("::")
      scopes.size.downto(1).map { |n| "#{scopes.first(n).join('::')}::#{name}" } + [ name ]
    end
  end
end
