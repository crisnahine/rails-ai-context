# frozen_string_literal: true

require "concurrent"
require "prism"

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
          PathResolver.dirs_for(root, "app").flat_map { |app_dir| PathResolver.glob(app_dir, "{concerns,*/concerns}") }
        else
          # A path that is already absolute is taken as given; `File.join`
          # would graft it onto the root and point at nothing.
          Array(configured).map { |rel| File.absolute_path?(rel) ? rel : File.join(root, rel) }
        end

      dirs.uniq.select { |dir| Dir.exist?(dir) }.sort.freeze
    end
    private_class_method :discover

    # The Ruby files under one directory, sorted, walked as Zeitwerk reads it (FileWalk.glob).
    def files(dir, root)
      FileWalk.glob(dir, "**/*.rb", root: root)
    end

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
        files(dir, root).filter_map do |path|
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
      holding = resolve(root).select { |dir| files(dir, root).any? }
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

    # The concerns a file holds: the module its path names, and each module nested in it that extends
    # ActiveSupport::Concern, which Zeitwerk loads with it. A namespace is none itself: its file holds its modules.
    # Nor is a class, where the file defines a concern beside it.
    def names_in(path, dir, source)
      RunCache.fetch([ :concern_names_in, path, dir, source ]) { read_names_in(path, dir, source).freeze }
    end

    def read_names_in(path, dir, source)
      name = name_for(path, dir, source)
      modules = Introspectors::DeclaredConstant.module_nodes(source && AstCache.parse_string(source)&.value)
      # The modules it nests; in a file that declares no module of its name, every one but the namespaces around that name.
      inner = modules.keys.select { |module_name| module_name.start_with?("#{name}::") || (!modules[name] && !"#{name}::".start_with?("#{module_name}::")) }
      return [ name ] if inner.empty?

      concerns = inner.select do |module_name|
        ConcernMembership.owned_by(mixins(source), module_name, others: modules.keys - [ module_name ]).any? { |mixin| mixin[:macro] == :extend && mixin[:name] == "ActiveSupport::Concern" }
      end
      return concerns.presence || [ name ] unless modules[name]
      return [ name, *concerns ] unless Introspectors::DeclaredConstant.namespace?(modules[name])

      members = inner.select { |module_name| concerns.include?(module_name) || namespace_member?(module_name, name, modules) }
      members.presence || [ name ]
    end

    # The MixinsListener records of a file's source, walked once per run.
    def mixins(source)
      RunCache.fetch([ :concern_mixins, source ]) do
        Introspectors::SourceIntrospector.walk_source(source, { mixins: Introspectors::Listeners::MixinsListener })[:mixins].freeze
      end
    end

    # A module the namespace holds, directly or through namespaces, that is no namespace itself.
    def namespace_member?(module_name, namespace, modules)
      parts = module_name.delete_prefix("#{namespace}::").split("::")[0..-2]
      between = parts.each_index.map { |n| [ namespace, *parts.first(n + 1) ].join("::") }
      !Introspectors::DeclaredConstant.namespace?(modules[module_name]) &&
        between.all? { |scope| !modules[scope] || Introspectors::DeclaredConstant.namespace?(modules[scope]) }
    end
    private_class_method :read_names_in, :namespace_member?

    # Source file for a concern named by its constant, or nil.
    #
    # @param root [String] application root
    # @param concern_name [String] constant name, e.g. "Searchable"
    # @param prefer [String, nil] owner kind ("model", "controller") whose
    #   concerns directory is searched first. `resolve` sorts, so without it
    #   app/controllers/concerns wins a basename two owners share.
    # @param within [String, nil] the enclosing constant of the reference. A
    #   bare `include DebugConcern` inside Shop::Provider resolves at runtime
    #   to Shop::Provider::DebugConcern, which the literal spelling misses.
    # @param dirs [Array<String>, nil] pre-resolved concern directories
    # @param outer [Boolean] whether a module with no file of its own is found in its outer constant's file
    def find_file(root, concern_name, prefer: nil, within: nil, dirs: nil, outer: true)
      name, path, in_outer = resolved(root, concern_name, prefer: prefer, within: within, dirs: dirs)
      path if name && (outer || !in_outer)
    end

    # The source of the module a reference resolves to, the modules it nests left out: its file, or its own node
    # in its outer constant's file.
    def module_source(root, concern_name, prefer: nil, within: nil)
      named_module_source(root, concern_name, prefer: prefer, within: within)&.[](1)
    end

    # The module's own source, then the own source of each module it includes or prepends itself, which Ruby
    # mixes in with it, as deep as ActionPresence follows a controller's modules.
    def included_sources(root, concern_name, prefer: nil, within: nil, depth: Introspectors::ActionPresence::MODULE_DEPTH)
      name, own, = named_module_source(root, concern_name, prefer: prefer, within: within)
      return [] unless own
      return [ own ] unless depth.positive? && own.match?(/\b(?:include|prepend)\b/)

      included = ConcernMembership.owned_by(mixins(own), name).select { |mixin| mixin[:ancestor] }.uniq { |mixin| mixin[:name] }
      [ own ] + included.flat_map { |mixin| included_sources(root, mixin[:name], within: name, depth: depth - 1) }
    end

    # [the constant a reference resolves to, its own source, its file's source], or nil.
    def named_module_source(root, concern_name, prefer: nil, within: nil)
      name, path, in_outer = resolved(root, concern_name, prefer: prefer, within: within)
      source = path && SafeFile.read(path) or return nil
      own = Introspectors::DeclaredConstant.own_module_source(source, name)
      return [ name, own, source ] unless in_outer

      node = Introspectors::DeclaredConstant.module_node(AstCache.parse_string(source)&.value, name) or return nil
      [ name, own.byteslice(node.location.start_offset, node.location.length), source ]
    end
    private_class_method :named_module_source

    # [`Outer::Inner`, Outer's file] for a reference that resolves to a module with no file of its own, which
    # Zeitwerk loads with Outer, or nil.
    def outer_named(root, concern_name, within: nil, dirs: nil)
      name, path, in_outer = resolved(root, concern_name, within: within, dirs: dirs)
      [ name, path ] if in_outer
    end

    # [the constant the reference resolves to, its own file], or nil when it resolves to none or to a module in
    # its outer constant's file.
    def find_named(root, concern_name, prefer: nil, within: nil, dirs: nil)
      name, path, in_outer = resolved(root, concern_name, prefer: prefer, within: within, dirs: dirs)
      [ name, path ] if name && !in_outer
    end

    # [constant, file, true, node] for the first candidate Ruby reaches declared in `file` (the file naming it) or its
    # outer constant's file, [constant, file, false] in its own file, or nil.
    def resolved(root, concern_name, prefer: nil, within: nil, dirs: nil, file: nil)
      # Every model asks for the same few names, each across hundreds of directories.
      RunCache.fetch([ :resolved_named, root, concern_name, prefer, within, dirs, file ]) do
        # Wherever Zeitwerk would look, plus an in-repo path gem's lib. A lib the app does
        # not add to its autoload paths holds nothing it autoloads, so it is skipped.
        searched = ordered_dirs(root, prefer, dirs) + PathResolver.app_roots(root) + PathResolver.declared_roots(root) +
                   PathResolver.path_gem_libs(root)
        nesting = scope(root, within)
        Introspectors::DeclaredConstant.candidate_names(concern_name, nesting).lazy.filter_map do |name|
          node = file && defined_at_reference(file, name, concern_name, nesting)
          next [ name, file, true, node ] if node

          path = PathResolver.constant_file(searched, name, declared: true) { |found| !PathResolver.linked_out?(found, root) }
          next [ name, path, false ] if path

          outer = name.rpartition("::").first
          path = !outer.empty? && find_file(root, outer, dirs: dirs)
          node = path && defined_at_reference(path, name, concern_name, nesting)
          [ name, path, true, node ] if node
        end.first
      end
    end

    # The node declaring `name` in `path`, when Ruby has run it by the line naming it.
    def defined_at_reference(path, name, concern_name, nesting)
      node = Introspectors::DeclaredConstant.module_node(AstCache.parse(path).value, name)
      node unless node.nil? || below_reference?(node, path, concern_name, nesting)
    rescue StandardError => e
      RailsAiContext.debug_fail(e, nil, label: "module #{name} in #{path}")
    end
    private_class_method :defined_at_reference

    # shortcut: every block counts as run after the file loads, though one Ruby runs at once (Class.new, Module.new, concerning,
    # class_methods, class_eval, each, tap) runs before what follows it; tell them apart if an app declares the module below one.
    DEFERRED = [ Prism::DefNode, Prism::BlockNode, Prism::LambdaNode ].freeze

    # Ruby has not yet run a module its file declares below the line in that file that names it as the file loads.
    # One in a method or a block runs when called, after the whole file.
    def below_reference?(node, path, concern_name, nesting)
      source = SafeFile.read(path) or return false
      later = Introspectors::AstWalk.each(AstCache.parse_string(source)&.value).filter_map do |deferred|
        deferred.location.start_line..deferred.location.end_line if DEFERRED.any? { |type| deferred.is_a?(type) }
      end
      written = mixins(source).filter_map do |mixin|
        line = mixin[:location]
        line if mixin[:name] == concern_name && mixin[:nesting] == nesting && later.none? { |lines| lines.cover?(line) }
      end.min
      written ? node.location.start_line > written : false
    end
    private_class_method :below_reference?

    def ordered_dirs(root, prefer, dirs = nil)
      dirs ||= resolve(root)
      return dirs unless prefer

      dirs.partition { |dir| type_for(dir) == prefer }.flatten
    end

    # The nesting a reference is written in, for a caller holding only the including constant's name: its body's.
    def scope(root, within)
      return within if within.is_a?(Array)
      return [] if within.to_s.empty?

      RunCache.fetch([ :scope, root.to_s, within.to_s ]) do
        path = PathResolver.file_for_constant(root.to_s, within.to_s)
        Introspectors::DeclaredConstant.body_nesting(path && AstCache.parse(path).value, within.to_s)
      rescue StandardError, ScriptError => e
        RailsAiContext.debug_fail(e, Introspectors::DeclaredConstant.nesting(within.to_s.split("::")), label: "ConcernPaths.scope")
      end
    end
  end
end
