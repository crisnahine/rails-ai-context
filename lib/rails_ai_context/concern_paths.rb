# frozen_string_literal: true

require "concurrent"
require "prism"
require "set"

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
      FileWalk.glob(dir, "**/*.rb", root: root, exclude: PathResolver.pruned_walk(root)).reject { |path| PathResolver.sensitive?(root, path) }
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
    # @param line [Integer, nil] the line of the including constant's file naming the reference
    def find_file(root, concern_name, prefer: nil, within: nil, dirs: nil, outer: true, line: nil)
      name, path, in_outer = resolved(root, concern_name, prefer: prefer, within: within, dirs: dirs, line: line)
      path if name && (outer || !in_outer)
    end

    # The source of the module a reference resolves to, the modules it nests left out: its file, or its own node
    # in its outer constant's file.
    def module_source(root, concern_name, prefer: nil, within: nil, line: nil)
      module_slice(root, concern_name, prefer: prefer, within: within, line: line)&.first
    end

    # [the module's own source, the lines of its file above it], so a line of the source is a line of the file.
    def module_slice(root, concern_name, prefer: nil, within: nil, line: nil)
      named_module_source(root, concern_name, prefer: prefer, within: within, line: line)&.values_at(1, 3)
    end

    # The module's own source, then the own source of each module it includes or prepends itself, which Ruby
    # mixes in with it, as deep as ActionPresence follows a controller's modules.
    def included_sources(root, concern_name, prefer: nil, within: nil, depth: Introspectors::ActionPresence::MODULE_DEPTH)
      included_modules(root, concern_name, prefer: prefer, within: within, depth: depth).map(&:last)
    end

    # [name, own source] of the module a reference resolves to and of each module it mixes in, in Ruby's method
    # lookup order: what it prepends, the module, then what it includes, the last mixed in first.
    def included_modules(root, concern_name, prefer: nil, within: nil, depth: Introspectors::ActionPresence::MODULE_DEPTH, line: nil)
      name, own, _, offset = named_module_source(root, concern_name, prefer: prefer, within: within, line: line)
      return [] unless own
      return [ [ name, own ] ] unless depth.positive? && own.match?(/\b(?:include|prepend)\b/)

      included = ConcernMembership.owned_by(mixins(own), name).select { |mixin| mixin[:ancestor] }.uniq { |mixin| mixin[:name] }
      prepended, appended = included.reverse.partition { |mixin| mixin[:macro] == :prepend }
      nested = ->(mixins) { mixins.flat_map { |mixin| included_modules(root, mixin[:name], prefer: prefer, within: name, depth: depth - 1, line: mixin[:location] + offset) } }
      nested.call(prepended) + [ [ name, own ] ] + nested.call(appended)
    end

    # [the constant a reference resolves to, its own source, its file's source, the lines in the file above the own
    # source], or nil.
    def named_module_source(root, concern_name, prefer: nil, within: nil, line: nil)
      name, path, in_outer = resolved(root, concern_name, prefer: prefer, within: within, line: line)
      source = path && SafeFile.read(path) or return nil
      own = Introspectors::DeclaredConstant.own_module_source(source, name)
      return [ name, own, source, 0 ] unless in_outer

      node = Introspectors::DeclaredConstant.module_node(AstCache.parse_string(source)&.value, name) or return nil
      [ name, own.byteslice(node.location.start_offset, node.location.length), source, node.location.start_line - 1 ]
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

    # [constant, file, true, node] for the constant Ruby picks declared in `file` (the file naming it) or its
    # outer constant's file, [constant, file, false] in its own file, or nil. `ancestors` are the including class's,
    # read after its nesting; `known` maps constants the caller already holds to their files. `line` is the line of
    # `file` naming the reference, when the caller has it; without it, the reference stands where the scope's body ends.
    def resolved(root, concern_name, prefer: nil, within: nil, dirs: nil, file: nil, ancestors: [], known: {}, line: nil)
      # Every model asks for the same few names, each across hundreds of directories.
      RunCache.fetch([ :resolved_named, root, concern_name, prefer, within, dirs, file, ancestors, known, line ]) do
        searched = searched_dirs(root, prefer, dirs)
        nesting = scope(root, within)
        # A line given alone is a line of the innermost scope's file.
        file ||= line && nesting.any? ? scope_source(root, prefer, dirs, nesting.first)&.first : nil
        hits = {}
        exists = lambda do |name|
          hits[name] = known.key?(name) ? [ name, known[name] ] : declared_at(root, name, file, [ prefer, searched ], dirs, [ concern_name, nesting, line ])
        end
        model = [ root, prefer, dirs ]
        # Ruby reads the innermost scope's ancestors, as they stand at the line naming the reference, before the top level.
        later = -> { nesting.empty? ? [] : ancestors(*model, nesting.first, at: [ line, file ]) }
        found = Introspectors::DeclaredConstant.lookup(concern_name, nesting: nesting, ancestors: ancestors, exists: exists,
                                                                     ancestors_of: ->(name) { ancestors(*model, name) - [ name ] }, later_ancestors: later)
        found && hits[found]
      end
    end

    # Wherever Zeitwerk would look, plus an in-repo path gem's lib. A lib the app does
    # not add to its autoload paths holds nothing it autoloads, so it is skipped.
    def searched_dirs(root, prefer, dirs)
      PathResolver.leading_roots(root) + ordered_dirs(root, prefer, dirs) + PathResolver.app_roots(root) + PathResolver.declared_roots(root) +
        PathResolver.path_gem_libs(root)
    end

    # Every dir a reference is looked up in, whatever the owner order, that the fingerprint watches: an index kept
    # across calls is dropped when a file in any of them moves. An unwatched root's index lasts one run.
    def searched(root) = searched_dirs(root, nil, nil) - PathResolver.unwatched_roots(root)

    # What `exists` says for the constant Ruby picks for `written` where Module.nesting is `nesting`: each scope's own
    # constants innermost first, then the innermost scope's ancestors, then the top level. `exists` answers
    # for a constant that a file declares in that scope, never one it reaches through an ancestor.
    def reach(root, written, nesting, prefer: nil, &exists)
      Introspectors::DeclaredConstant.reach(
        written, nesting: nesting, exists: exists, ancestors_of: ->(name) { ancestors(root.to_s, prefer, nil, name) - [ name ] },
        later_ancestors: -> { nesting.empty? ? [] : ancestors(root.to_s, prefer, nil, nesting.first) - [ nesting.first ] }
      )
    end

    # [the constant, its file] when `name` is declared in a file as written, else nil.
    def declared(root, name)
      found, path = resolved(root, name)
      [ found, path ] if found == name
    end

    # `name`'s ancestors as Ruby lists them, `name` itself among them: what it prepends, itself, what it includes, each
    # mixed-in module bringing its own ancestors, then its superclass's. `at` is [a line, the file it is in or nil]: only
    # the mixin lines of `name`'s body above it count, as Ruby reads the body there. Without a line, a line of another
    # file, or a line in a method or block, which runs once the body has loaded, every line counts.
    def ancestors(root, prefer, dirs, name, at: nil)
      line, file = at
      path, source = scope_source(root, prefer, dirs, name) if line
      rank = path && file && !same_file?(file, path) && reopenings(root, prefer, dirs, name).index { |each, _| same_file?(each, file) }
      return reopened_at(root, prefer, dirs, name, rank, line) if rank
      return ancestry(root, prefer, dirs, name).full if source.nil? || (file && !same_file?(file, path)) || deferred(source).any? { |range| range.cover?(line) }

      # A `concerning` block runs before its Concern joins the scope, the Concern's own blocks just after, or once the
      # body has loaded for a Concern that a Concern hands its includers.
      if (topic = body_lines(source)[:concerning].find { |range| range.cover?(line) })
        hooked = body_lines(source)[:hooks].any? { |_, range| topic.cover?(range) && range.cover?(line) }
        return ancestry(root, prefer, dirs, name).full if hooked && ancestry(root, prefer, dirs, name).mixins.find { |mixin| mixin.line == topic.begin }&.dependency

        line = topic.begin + (hooked ? 1 : 0)
      end
      # No line above the reference mixes anything in, read off the text, so its file is not walked.
      return [ name, *inherited(root, prefer, dirs, name) ] if line <= body_lines(source)[:first_mixin]
      lines = ancestry(root, prefer, dirs, name)
      cut = lines.mixins.index { |mixin| mixin.file || mixin.line >= line }
      cut ? assemble(root, prefer, dirs, name, lines.mixins.first(cut), lines.inherited) : lines.full
    end

    # One include or prepend line of a scope's own body: its line and the module it resolved to there. `dependency`
    # marks one an ActiveSupport::Concern holds for its includers rather than mixing it in itself. `file` names the
    # file reopening the scope that holds the line, nil for the scope's own file.
    Mixin = Struct.new(:macro, :line, :module_name, :dependency, :file)
    # A scope's own mixin lines in source order, its superclass's ancestors and the whole list; for an
    # ActiveSupport::Concern, the Concerns it hands its includers first and its blocks' [macro, module]s by the macro
    # that runs them; for a module, the [macro, module]s its `included`/`prepended` hook mixes into each includer, by the
    # macro that runs it; and the Ancestry of each Concern its `concerning` blocks make, by name.
    Ancestry = Struct.new(:mixins, :inherited, :full, :concern, :dependencies, :blocks, :callbacks, :concerned)

    OPEN_ANCESTRIES = :rails_ai_context_open_ancestries

    # Kept per scope for the run; a scope reached again while its own lines resolve (a cycle the source writes)
    # answers itself alone.
    def ancestry(root, prefer, dirs, name)
      RunCache.fetch([ :ancestry, root, search_order(root, prefer, dirs), name ]) do
        open = (Thread.current[OPEN_ANCESTRIES] ||= Set.new)
        key = [ root, prefer, dirs, name ]
        next alone(name) unless open.add?(key)

        begin
          read_ancestry(root, prefer, dirs, name)
        ensure
          open.delete(key)
        end
      end
    end

    def alone(name) = Ancestry.new([], [], [ name ], false, [], {}, {}, {})

    # [the file declaring `name`, its source], or nil, kept for the run: every reference with a line reads it.
    def scope_source(root, prefer, dirs, name)
      RunCache.fetch([ :scope_source, root, search_order(root, prefer, dirs), name ]) do
        path = declared_at(root, name, nil, [ prefer, searched_dirs(root, prefer, dirs) ], dirs, [ nil, nil ])&.[](1)
        source = path && SafeFile.read(path)
        [ path, source ] if source
      end
    end

    # The ancestors of the class `name` inherits from, empty for a module or a class outside the app.
    def inherited(root, prefer, dirs, name)
      RunCache.fetch([ :ancestry_inherited, root, search_order(root, prefer, dirs), name ]) do
        _, source = scope_source(root, prefer, dirs, name)
        parent = source && superclass(name, source, ->(constant) { scope_source(root, prefer, dirs, constant)&.last })
        parent ? ancestors(root, prefer, dirs, parent) : []
      end
    end

    # The body's include and prepend lines that run as it loads, each resolved at its line: the nesting, then the
    # ancestors the lines above it built, then the top level. An `extend ActiveSupport::Concern` above a line makes a
    # Concern that line names a dependency, and an `included`/`prepended` block's lines resolve once the body has loaded.
    # A `concerning` block's lines are its Concern's, resolved against the scope's ancestors where the block stands.
    def read_ancestry(root, prefer, dirs, name)
      path, source = scope_source(root, prefer, dirs, name)
      return concerned(root, prefer, dirs, name) unless source

      lines = body_lines(source)
      owned = ConcernMembership.owned_by(mixins(source), name).reject { |mixin| mixin[:receiver] || lines[:defs].any? { |range| range.cover?(mixin[:location]) } }
      topics = owned.select { |mixin| mixin[:inline] }.to_h { |topic| [ topic[:name], lines[:concerning].find { |range| range.begin == topic[:location] } ] }
      in_topic = ->(range, mixin) { range&.cover?(mixin[:location]) && !mixin[:inline] }
      context = [ path, [ prefer, searched_dirs(root, prefer, dirs) ] ]
      inherited = inherited(root, prefer, dirs, name)
      concerned = {}
      own = owned.reject { |mixin| topics.each_value.any? { |range| in_topic.(range, mixin) } }
      concern_at = own.find { |mixin| mixin[:macro] == :extend && mixin[:name] == "ActiveSupport::Concern" }&.[](:location)
      above = ->(done) { assemble(root, prefer, dirs, name, done, inherited, concerned) }
      handed = []
      ancestry = from_lines(root, prefer, dirs, name, own, [ lines, context, concerned ], concern_at, inherited, name, [ above, :full.to_proc ]) do |topic, done|
        at = above.call(done)
        records = owned.select { |mixin| in_topic.(topics[topic[:name]], mixin) }
        # Its blocks run as the scope receives it, before the lines below; a Concern's dependency's run in the includer.
        received = lambda do |partial|
          concerned[topic[:name]] = partial
          above.call([ *done, Mixin.new(topic[:macro], topic[:location], topic[:name], false) ])
        end
        handed << [ topic[:name], records ] if concern_at && concern_at < topic[:location]
        concerned[topic[:name]] = from_lines(root, prefer, dirs, topic[:name], records, [ lines, context, {} ], 0, [], name, [ ->(_) { at }, (received unless handed.last&.first == topic[:name]) ])
        topic[:name]
      end
      handed.each { |topic, records| concerned[topic].blocks = blocks_of(root, prefer, dirs, name, [ lines, context ], records, ancestry.full) }
      reopened(root, prefer, dirs, name, ancestry, concerned)
      ancestry.callbacks = callbacks(root, prefer, dirs, name, source, context, ancestry.full).freeze
      ancestry.concerned = concerned.freeze
      ancestry
    end

    # The Ancestry of `name` from its own mixin `records`, each written in the body of `scope` and resolved against
    # `above`, given the lines resolved so far, and its blocks' lines against what `settle` gives for the Ancestry read
    # so far; `concern_at` is the line making `name` an ActiveSupport::Concern, and a block yields each `concerning`
    # record's module.
    def from_lines(root, prefer, dirs, name, records, (lines, context, concerned), concern_at, inherited, scope, (above, settle))
      own = records.select { |mixin| mixin[:ancestor] && hook_of(lines, mixin).nil? }.sort_by { |mixin| mixin[:location] }
      dependencies = []
      mixed = own.each_with_object([]) do |mixin, done|
        module_name = mixin[:inline] && block_given? ? yield(mixin, done) : mixin_module(root, prefer, dirs, scope, context, mixin) { above.call(done) }
        dependency = !concern_at.nil? && concern_at < mixin[:location] && !module_name.nil? && (concerned[module_name] || ancestry(root, prefer, dirs, module_name)).concern
        mixin[:macro] == :prepend ? dependencies.unshift(module_name) : dependencies.push(module_name) if dependency
        done << Mixin.new(mixin[:macro], mixin[:location], module_name, dependency)
      end
      full = assemble(root, prefer, dirs, name, mixed, inherited, concerned).freeze
      ancestry = Ancestry.new(mixed.freeze, inherited, full, !concern_at.nil?, dependencies.freeze, {}, {}, {})
      ancestry.blocks = blocks_of(root, prefer, dirs, scope, [ lines, context ], records, settle.call(ancestry)) if settle
      ancestry
    end

    # [file, source] of each later file adding lines to `name` while opening it around its own constant, in the order
    # Zeitwerk's eager load runs them, after the file declaring `name`.
    # shortcut: an app loading lazily runs them in the order its code first names each file's constant; this keeps
    # eager load's.
    def reopenings(root, prefer, dirs, name)
      RunCache.fetch([ :reopenings, root, search_order(root, prefer, dirs), name ]) do
        path, = scope_source(root, prefer, dirs, name)
        files = path ? adding_files(root, prefer, searched_dirs(root, prefer, dirs), dirs, name).reject { |each| same_file?(each, path) } : []
        files.filter_map { |each| (source = AstCache.source(each)) && [ each, source ].freeze }.freeze
      end
    end

    # The include and prepend lines of each reopening, run after the scope's own file, each resolved at its own line
    # against the lines run before it.
    # shortcut: a reopening's hooks, Concern lines and `concerning` blocks are not read; read them as read_ancestry does
    # if an app adds those to a namespace from a reopening.
    def reopened(root, prefer, dirs, name, ancestry, concerned)
      openings = reopenings(root, prefer, dirs, name)
      return if openings.empty?

      mixed = ancestry.mixins.dup
      searched = [ prefer, searched_dirs(root, prefer, dirs) ]
      openings.each do |path, source|
        lines = body_lines(source)
        records = ConcernMembership.owned_by(mixins(source), name).select do |mixin|
          mixin[:ancestor] && !mixin[:receiver] && !hook_of(lines, mixin) && lines[:deferred].none? { |range| range.cover?(mixin[:location]) }
        end
        records.sort_by { |mixin| mixin[:location] }.each do |mixin|
          module_name = mixin_module(root, prefer, dirs, name, [ path, searched ], mixin) { assemble(root, prefer, dirs, name, mixed, ancestry.inherited, concerned) }
          mixed << Mixin.new(mixin[:macro], mixin[:location], module_name, false, path)
        end
      end
      ancestry.mixins = mixed.freeze
      ancestry.full = assemble(root, prefer, dirs, name, mixed, ancestry.inherited, concerned).freeze
    end

    # `name`'s ancestors at `line` of its reopening `rank`: every line of its own file and the reopenings before, and
    # this one's lines above the line. A line in a method or block runs once every file has loaded.
    def reopened_at(root, prefer, dirs, name, rank, line)
      path, source = reopenings(root, prefer, dirs, name)[rank]
      lines = ancestry(root, prefer, dirs, name)
      return lines.full if deferred(source).any? { |range| range.cover?(line) }

      later = reopenings(root, prefer, dirs, name).drop(rank + 1).map(&:first)
      cut = lines.mixins.index { |mixin| later.include?(mixin.file) || (mixin.file == path && mixin.line >= line) }
      cut ? assemble(root, prefer, dirs, name, lines.mixins.first(cut), lines.inherited, lines.concerned) : lines.full
    end

    # The [macro, module]s of the `included`/`prepended` block lines among `records`, by the macro that runs them, each
    # resolved in `scope`'s body against `settled`, its ancestors when the block runs.
    def blocks_of(root, prefer, dirs, scope, (lines, context), records, settled)
      hooked = records.select { |mixin| mixin[:ancestor] && hook_of(lines, mixin) }.sort_by { |mixin| mixin[:location] }
      hooked.group_by { |mixin| hook_of(lines, mixin) }.transform_values do |block|
        block.filter_map { |mixin| (found = mixin_module(root, prefer, dirs, scope, context, mixin) { settled }) && [ mixin[:macro], found ] }
      end.freeze
    end

    # A module a `concerning` block of its outer scope makes, read with that scope; else `name` alone.
    def concerned(root, prefer, dirs, name)
      outer = name.rpartition("::").first
      (outer.empty? ? nil : ancestry(root, prefer, dirs, outer).concerned[name]) || alone(name)
    end

    # The [macro, module]s a module's `def self.included(base)` or `def self.prepended(base)` mixes into `base`, by the
    # macro that runs the hook, each resolved in the module's body once it has loaded.
    def callbacks(root, prefer, dirs, name, source, context, full)
      tree = AstCache.parse_string(source)&.value
      node = Introspectors::DeclaredConstant.module_node(tree, name)
      return {} unless node.is_a?(Prism::ModuleNode)

      nesting = Introspectors::DeclaredConstant.body_nesting(tree, name, node: node)
      %i[include prepend].to_h do |macro|
        joins = ConcernMacros::SingletonLookup.hooks(node, macro).flat_map { |hook| ConcernMacros::SingletonLookup.hook_joins(hook) }
        [ macro, joins.filter_map do |added, arg, call|
          next unless Introspectors::Listeners::MixinsListener::ANCESTOR_MACROS.include?(added) && !arg.is_a?(Prism::SelfNode)

          record = { name: arg.slice.delete_prefix("::"), top_level: arg.slice.start_with?("::"), location: call.location.start_line, nesting: nesting }
          (found = mixin_module(root, prefer, dirs, name, context, record) { full }) && [ added, found ]
        end ]
      end.reject { |_, joins| joins.empty? }
    end

    # The module a mixin line of `scope`'s body names; `above` gives `scope`'s ancestors as they stand there.
    def mixin_module(root, prefer, dirs, scope, (path, searched), mixin, &above)
      nesting = Introspectors::DeclaredConstant.record_nesting(mixin)
      reference = mixin[:top_level] ? "::#{mixin[:name]}" : mixin[:name]
      exists = ->(constant) { declared_at(root, constant, path, searched, dirs, [ mixin[:name], nesting, mixin[:location] ]) }
      Introspectors::DeclaredConstant.lookup(reference, nesting: nesting, exists: exists, later_ancestors: -> { nesting.first == scope ? above.call : [] },
                                                        ancestors_of: ->(constant) { ancestors(root, prefer, dirs, constant) - [ constant ] })
    end

    # The macro (include or prepend) whose ActiveSupport::Concern block holds the mixin line, or nil.
    def hook_of(lines, mixin)
      lines[:hooks].find { |_, range| range.cover?(mixin[:location]) }&.first
    end

    # The line ranges of a source's methods, of every method, block and lambda run after what follows them, of each
    # receiverless `included do`/`prepended do` block, by the macro that runs it, and of each `concerning` call, whose
    # block runs at once; and the first line that so much as mentions include, prepend or concerning.
    def body_lines(source)
      RunCache.fetch([ :concern_body_lines, source ]) do
        mention = source.match(/\b(?:include|prepend|concerning)\b/)
        found = { defs: [], deferred: [], hooks: [], concerning: [], first_mixin: mention ? source[0, mention.begin(0)].count("\n") + 1 : Float::INFINITY }
        at_once = []
        Introspectors::AstWalk.each(AstCache.parse_string(source)&.value).each do |node|
          range = node.location.start_line..node.location.end_line
          found[:defs] << range if node.is_a?(Prism::DefNode)
          found[:deferred] << range if DEFERRED.any? { |type| node.is_a?(type) }
          next unless node.is_a?(Prism::CallNode) && node.receiver.nil? && node.block.is_a?(Prism::BlockNode)

          hook = ConcernMembership::CONCERN_BLOCKS.key(node.name)
          found[:hooks] << [ hook, range ] if hook
          next unless node.name == :concerning

          found[:concerning] << range
          at_once << (node.block.location.start_line..node.block.location.end_line)
        end
        # The Concern's own blocks run as the scope receives it, at once too.
        at_once.concat(found[:hooks].filter_map { |_, range| range if found[:concerning].any? { |topic| topic != range && topic.cover?(range) } })
        found[:deferred] -= at_once
        found.transform_values { |value| value.frozen? ? value : value.freeze }.freeze
      end
    end

    def deferred(source) = body_lines(source)[:deferred]

    # Ruby's include and prepend: each module of the mixed-in module's ancestors goes in after the last one placed,
    # unless the list has it already; an include sees the whole list, a prepend only what is prepended. An
    # ActiveSupport::Concern the list lacks brings its dependencies first, then itself, then its block's mixins. A
    # module's `included`/`prepended` hook then runs whether or not the list had it. `concerned` holds the Ancestry of
    # each Concern the scope's own `concerning` blocks make.
    def assemble(root, prefer, dirs, name, mixed, inherited, concerned = {})
      prepended = []
      included = []
      place = lambda do |macro, chain|
        # Ruby finds a module the scope prepends ahead of one it includes, and moves nothing past it.
        into, ahead, others = macro == :prepend ? [ prepended, [], [] ] : [ included, [ name, *prepended ], inherited ]
        at = 0
        chain.each do |constant|
          next if ahead.include?(constant)

          if (index = into.index(constant))
            at = index + 1 if index >= at
          elsif !others.include?(constant)
            into.insert(at, constant)
            at += 1
          end
        end
      end
      receive = lambda do |macro, module_name|
        from = concerned[module_name] || ancestry(root, prefer, dirs, module_name)
        if !from.concern
          place.call(macro, from.full)
        elsif ![ *prepended, *included, *inherited ].include?(module_name)
          from.dependencies.each { |dependency| receive.call(macro, dependency) }
          place.call(macro, from.full)
          from.blocks.fetch(macro, []).each { |block_macro, block_module| receive.call(block_macro, block_module) }
        end
        from.callbacks.fetch(macro, []).each { |hook_macro, hook_module| receive.call(hook_macro, hook_module) }
      end
      mixed.each { |mixin| receive.call(mixin.macro, mixin.module_name) if mixin.module_name && !mixin.dependency }
      [ *prepended, name, *included, *inherited ]
    end

    # The class `name` declares in `source` inherits from, as Ruby resolves the name it writes; nil for a module.
    def superclass(name, source, source_of)
      declaration = Introspectors::DeclaredConstant.declarations(source).find { |each| each.name == name }
      return nil unless declaration&.superclass

      Introspectors::SuperclassChain.resolve_in_scope(declaration.name, declaration.superclass, nesting: declaration.nesting,
                                                                                       ancestors_of: Introspectors::SuperclassChain.ancestors_of(source_of)) do |candidate|
        source_of.call(candidate) && candidate
      end
    end

    def declared_at(root, name, file, (prefer, searched), dirs, reference)
      node = file && defined_at_reference(file, name, *reference)
      return [ name, file, true, node ] if node

      path = constant_file(root, name, prefer, searched, dirs)
      return [ name, path, false ] if path

      path = outer_file(root, name, prefer, searched, dirs)
      # The line names a line of `file` alone.
      node = path && defined_at_reference(path, name, *(path == file ? reference : reference.first(2)))
      return [ name, path, true, node ] if node

      path = declared_beside(root, prefer, searched, dirs).first[name]
      path, node = path ? [ path, declared_node(path, name) ] : opened_around(root, prefer, searched, dirs, name)
      # A kept index can name a file that has since stopped declaring the name, or no longer parses.
      [ name, path, true, node ] if node && !(file && same_file?(path, file) && below_reference?(node, path, *reference))
    end

    # Every class and module declared in a file beside the file's own constant, which no path names, by name: the
    # first file in search order. A file declaring one constant declares the one its path names, and an opening that
    # only wraps the constant its path names (`module Shop` around `class Order` in shop/order.rb) is that namespace's
    # opening, not its definition.
    # Also the files that open a namespace around their own constant, by namespace downcased, in search order.
    def declared_beside(root, prefer, searched, dirs)
      RunCache.fetch([ :declared_beside, root, search_order(root, prefer, dirs) ]) do
        index = searched.uniq.each_with_object({}) { |dir, found| found.merge!(declared_in(root, dir).first) { |_, first, _| first } }
        # Eager load runs a namespace's dirs in Rails' root order, its sorted `{*,*/concerns}` glob among the declared roots,
        # not the search's.
        rails = (PathResolver.leading_roots(root) + (PathResolver.app_roots(root) + resolve(root)).sort + PathResolver.declared_roots(root)) & searched
        wrapping = (rails + searched.uniq).uniq.each_with_object({}) do |dir, adding|
          adding.merge!(declared_in(root, dir).last) { |_, first, later| first + later }
        end
        [ index, wrapping ]
      end
    end

    # [file, node] of the first opening of `name` that adds to it, in a file that opens it only around its path's own
    # constant (`module Shop; include X; class Order; end; end` in shop/order.rb), or nil: Ruby runs those lines in the
    # module Zeitwerk makes for the namespace's directory, and the later such files' lines after them (reopenings).
    # Asked only for a namespace no file declares.
    def opened_around(root, prefer, searched, dirs, name)
      RunCache.fetch([ :opened_around, root, search_order(root, prefer, dirs), name ]) do
        path = adding_files(root, prefer, searched, dirs, name).first
        path && [ path, Introspectors::DeclaredConstant.module_node(AstCache.parse_string(AstCache.source(path))&.value, name) ]
      end
    end

    # The files that open `name` around their own constant and add to it, by dir in search order, then in the order
    # Zeitwerk's eager load reads a dir.
    def adding_files(root, prefer, searched, dirs, name)
      RunCache.fetch([ :adding_files, root, search_order(root, prefer, dirs), name ]) do
        declared_beside(root, prefer, searched, dirs).last.fetch(name.downcase, []).select { |each| adding_openings(each).include?(name) }.freeze
      end
    end

    # One file spelled through a link and through its target is one file.
    def same_file?(one, other) = one == other || File.identical?(one, other)

    DECLARATION = /^[ \t]*(?:(?:class|module)[ \t]+(?:::)?([A-Z][\w:]*)|([A-Z][\w:]*)[ \t]*(?:\|\|)?=[ \t]*(?:::)?(?:Class|Module)\.new\b)/

    # [what a dir's files declare beside their own constants, the files opening more than one of their constant's
    # segments and nothing else by each namespace downcased they can open around it, which `opened_around` reads].
    # The modules a file opens around its own constant that hold lines of their own, read once per run with a parse
    # that keeps no tree: a namespace no file declares can be asked of a thousand such files, and few add anything.
    def adding_openings(path)
      RunCache.fetch([ :adding_openings, path ]) do
        tree = (source = AstCache.source(path)) && AstCache.parse_uncached(source).value
        Introspectors::DeclaredConstant.module_nodes(tree).filter_map { |name, node| name unless Introspectors::DeclaredConstant.namespace?(node) }.to_set
      end
    end

    def declared_in(root, dir)
      # A server keeps it across calls: one costs half a second on an app with thousands of files.
      RunCache.public_send(PathResolver.unwatched_roots(root).include?(dir) ? :fetch : :kept, [ :declared_in, root, dir ]) do
        # Zeitwerk loads nothing under a dir `autoload_lib(ignore:)` names.
        ignored = PathResolver.ignored_dirs(root)
        wrapping = Hash.new { |hash, key| hash[key] = [] }
        found = files(dir, root).each_with_object({}) do |path, index|
          next if ignored.any? { |each| SafePath.contained?(path, each) }

          source = AstCache.source(path) or next
          own = path.delete_prefix("#{dir}/").delete_suffix(".rb").camelize.downcase
          # Read off the text: a file whose declarations write only segments of its path's constant declares nothing beside
          # it, though a namespace it opens around that constant can hold lines of its own.
          written = source.scan(DECLARATION).map { |opened, assigned| (opened || assigned).downcase.split("::") }
          if (written.flatten - own.split("::")).empty?
            segments = own.split("::")
            (1...segments.size).each { |count| wrapping[segments.first(count).join("::")] << path } if written.size > 1
            next
          end

          Introspectors::DeclaredConstant.constants(AstCache.parse_string(source)&.value, assignments: true) do |constant, node|
            next unless Introspectors::DeclaredConstant.scope?(node)
            # Only the file its path names declares a namespace; an opening around the file's own constant reopens it.
            next wrapping[constant.downcase] << path if own.start_with?("#{constant.downcase}::")

            index[constant] ||= path
          end
        end
        # Zeitwerk's eager load reads a dir's files by name, then each subdir's, a level at a time.
        by_load = ->(path) { (segments = path.delete_prefix("#{dir}/").split("/")) && [ segments.size, segments ] }
        [ found.freeze, wrapping.transform_values { |paths| paths.uniq.sort_by(&by_load).freeze }.freeze ].freeze
      end
    end

    # The node declaring `name` that declared_in found in `path`, read again in the run: the index a server keeps holds
    # no tree.
    def declared_node(path, name)
      RunCache.fetch([ :declared_node, path, name ]) do
        Introspectors::DeclaredConstant.constants(AstCache.parse(path).value, assignments: true)
                                       .find { |constant, node, _| constant == name && Introspectors::DeclaredConstant.scope?(node) }&.[](1)
      end
    rescue StandardError => e
      RailsAiContext.debug_fail(e, nil, label: "module #{name} in #{path}")
    end

    # The lookup asks for a namespace and each scope it tries, which other references ask for too.
    def constant_file(root, name, prefer, searched, dirs)
      RunCache.fetch([ :concern_constant_file, root, name, search_order(root, prefer, dirs) ]) do
        PathResolver.constant_file(searched, name, declared: true) { |found| !PathResolver.linked_out?(found, root) && !PathResolver.pruned?(root, found) && !PathResolver.sensitive?(root, found) }
      end
    end

    # One token per order the concern directories are searched in, whether a caller passed the directories or the
    # owner kind that orders them, so both share one answer per name.
    def search_order(root, prefer, dirs)
      RunCache.fetch([ :concern_search_order, root, prefer, dirs ]) { RunCache.fetch([ :concern_search_token, root, ordered_dirs(root, prefer, dirs) ]) { Object.new } }
    end

    # The file declaring the outer constant of `name`, by path alone: Zeitwerk loads `Outer::Inner` with Outer.
    def outer_file(root, name, prefer, searched, dirs)
      outer = name.rpartition("::").first
      return nil if outer.empty?

      constant_file(root, outer, prefer, searched, dirs) ||
        ((path = outer_file(root, outer, prefer, searched, dirs)) && module_in(path, outer) && path)
    end

    # Kept for the run: a lookup asks it of one file for each name it tries, and a parse cache hit still stats the file.
    def module_in(path, name)
      RunCache.fetch([ :module_in, path, name ]) { Introspectors::DeclaredConstant.module_node(AstCache.parse(path).value, name) }
    rescue StandardError => e
      RailsAiContext.debug_fail(e, nil, label: "module #{name} in #{path}")
    end
    private_class_method :declared_at, :constant_file, :outer_file, :module_in, :searched_dirs, :ancestry, :read_ancestry, :assemble, :superclass,
                         :scope_source, :inherited, :search_order, :alone, :from_lines, :blocks_of, :concerned, :callbacks, :mixin_module, :hook_of, :body_lines, :deferred, :declared_beside, :opened_around, :adding_openings, :adding_files, :declared_node, :reopenings, :reopened, :reopened_at, :declared_in, :same_file?

    # The node declaring `name` in `path`, when Ruby has run it by the line naming it.
    def defined_at_reference(path, name, concern_name, nesting, line = nil)
      node = module_in(path, name)
      node unless node.nil? || below_reference?(node, path, concern_name, nesting, line)
    rescue StandardError => e
      RailsAiContext.debug_fail(e, nil, label: "module #{name} in #{path}")
    end
    private_class_method :defined_at_reference

    # shortcut: every block counts as run after the file loads, though one Ruby runs at once (Class.new, Module.new, concerning,
    # class_methods, class_eval, each, tap) runs before what follows it; tell them apart if an app declares the module below one.
    DEFERRED = [ Prism::DefNode, Prism::BlockNode, Prism::LambdaNode ].freeze

    # Ruby has not yet run a module its file declares below the line in that file that names it as the file loads.
    # One in a method or a block runs when called, after the whole file.
    def below_reference?(node, path, concern_name, nesting, at = nil)
      source = SafeFile.read(path) or return false
      later = deferred(source)
      lines = at ? [ at ] : mixins(source).filter_map { |mixin| mixin[:location] if mixin[:name] == concern_name && mixin[:nesting] == nesting }
      written = lines.reject { |line| later.any? { |range| range.cover?(line) } }.min
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
