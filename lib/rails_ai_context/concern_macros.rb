# frozen_string_literal: true

module RailsAiContext
  # One answer to "what did this class's concerns declare".
  #
  # A model or controller file names the modules it mixes in, and those files
  # are on disk and parse the same way; only the walk stopped at the one file.
  # So a model whose associations all live in concerns answered `0 assoc` in
  # the static tier while the booted tier read 68 off reflection.
  module ConcernMacros
    MAX_DEPTH = 3

    # A call made inside a class method's body, standing where the call that ran
    # that body (`outer`) was made; `definition` is the body it sits in.
    Relayed = Struct.new(:node, :outer, :definition) do
      def arguments = node.arguments
      def location = node.location
      def name = node.name
    end

    # Ruby's class-method lookup over a class (rank 0), its bases nearest first and the modules
    # every model has: which definitions a call runs, and so where what they declare lands.
    class SingletonLookup
      # The lookup order inside one rank.
      PREPENDED = 0
      OWN = 1
      MIXED = 2
      # The lookup order of the defs that join with a module, by how it is added.
      JOINS = { prepended: PREPENDED, mixed: MIXED }.freeze
      # The defs a module gives that run with code, by group: [run by a hook?, lookup order].
      RAN = { block: [ false, OWN ], hook: [ true, OWN ], hook_mixed: [ true, MIXED ], hook_prepended: [ true, PREPENDED ] }.freeze

      # A class method; `owner` is a class file's rank or a module's label, `alias_of` the name an alias copies,
      # `at` its place in the owner's lookup when not its line (a base body's, after the base's file),
      # `joined` [line, argument index] of the hook's call adding the nested module it is in.
      Def = Struct.new(:owner, :name, :line, :super_line, :calls, :alias_of, :at, :joined) do
        def key = at ? [ owner, *at ] : [ owner, line ]
      end
      # One step of a singleton ancestry, existing from `at` ([line, order, ...]).
      Provider = Struct.new(:rank, :group, :at, :defs)
      # The class files' body calls by name, each one's rank, their own class methods, and the outermost rank.
      Read = Struct.new(:found, :ranks, :defs, :outer)
      # A module a walk reached, with the class methods it gives (`module_defs`). Added at `at` ([line, order]), or
      # within each run of the code `added` names (`added_in`); an every-model module at the outermost rank.
      Mixin = Struct.new(:label, :macro, :defs, :added, :at, :every)
      Reached = Struct.new(:included, :blocks, :mixins)
      # Each pass can reach one more module added inside a body, and a walk reads MAX_DEPTH levels;
      # one more pass shows nothing changed.
      PASSES = MAX_DEPTH + 2

      def self.definition(owner, node)
        super_node = node.body && Introspectors::AstWalk.each(node.body).find do |inner|
          inner.is_a?(Prism::SuperNode) || inner.is_a?(Prism::ForwardingSuperNode)
        end
        calls = node.body ? Introspectors::SourceIntrospector.calls_outside_methods(node.body, self_receiver: true) : {}
        Def.new(owner, node.name.to_s, node.location.start_line, super_node&.location&.start_line, calls)
      end

      # Where a base body's def sits in the lookup: after every class file's, then by load order and line.
      AFTER_CLASS_FILES = Float::INFINITY

      # The class methods a body run with the class as self defines: `def self.x`, and `def x` and aliases
      # inside `class << self`. `owner` is a class file's rank or a module's label; `order` a base body's load order.
      def self.own_defs(scope, owner, order = nil) = member_defs(scope, owner, order).map(&:last)

      # [node, Def] for each of `own_defs`.
      def self.member_defs(scope, owner, order = nil)
        singleton_members(scope).map do |node|
          names = alias_names(node)
          found = names ? Def.new(owner, names.first, node.location.start_line, nil, {}, names.last) : definition(owner, node)
          found.at = [ AFTER_CLASS_FILES, order, found.line ] if order
          [ node, found ]
        end
      end

      # The `def` and alias nodes behind `own_defs`.
      def self.singleton_members(scope)
        scope.flat_map do |node|
          case node
          when Prism::DefNode then node.receiver.is_a?(Prism::SelfNode) ? [ node ] : []
          when Prism::SingletonClassNode
            next [] unless node.expression.is_a?(Prism::SelfNode)

            Array(node.body&.body).select { |member| (member.is_a?(Prism::DefNode) && member.receiver.nil?) || alias_names(member) }
          else []
          end
        end
      end

      def self.alias_names(node)
        pair =
          case node
          when Prism::AliasMethodNode then [ node.new_name, node.old_name ]
          when Prism::CallNode then node.name == :alias_method && node.receiver.nil? ? Array(node.arguments&.arguments) : []
          else []
          end
        names = pair.map { |arg| arg.unescaped if arg.respond_to?(:unescaped) }
        names if names.size == 2 && names.all?
      end

      # The class methods the module `own` gives a class, by how they join: `:mixed` and `:prepended` with the
      # module, `:block` (an included block's) at its first add, and at each add `:hook` from its line and
      # `:hook_mixed`/`:hook_prepended` (a nested module's a hook adds) from the line adding it.
      def self.module_defs(own, label, macro)
        given = { prepended: [], mixed: [], block: [], hook: [], hook_mixed: [], hook_prepended: [] }
        return given unless own&.body

        hook_defs = hooks(own, macro)
        if ConcernMembership::SINGLETON_MACROS.include?(macro)
          given[group(macro)] = body_defs(own.body)
        else
          concern = macro == :prepend ? :prepended : :mixed
          class_methods = concern?(own)
          own.body.compact_child_nodes.each do |node|
            if node.is_a?(Prism::CallNode) && node.name == :class_methods && node.block then given[concern].concat(body_defs(node.block.body))
            elsif node.is_a?(Prism::CallNode) && node.name == ConcernMembership::CONCERN_BLOCKS[macro] && node.block
              given[:block].concat(singleton_scope_defs(node.block.body, label))
            elsif node.is_a?(Prism::ModuleNode) && class_methods && module_name(node) == "ClassMethods"
              given[concern].concat(body_defs(node.body))
            end
          end
        end
        short = label.to_s.split("::").last
        hook_defs.flat_map { |hook| hook_joins(hook) }.each do |added, arg, call|
          next unless ConcernMembership::SINGLETON_MACROS.include?(added)

          name = short_name(arg, short)
          given[group(added)].concat(body_defs(own.body)) if name == short
          nested_modules(own).select { |node| module_name(node) == name }.each do |node|
            given[RAN.key([ true, JOINS[group(added)] ])].concat(body_defs(node.body).map { |inner| definition(label, inner).tap { |found| found.joined = [ call.location.start_line, call.arguments.arguments.index(arg) ] } })
          end
        end
        given[:hook] = hook_defs.flat_map { |hook| singleton_defs(hook, label) }
        given.to_h { |group, nodes| [ group, nodes.map { |node| node.is_a?(Def) ? node : definition(label, node) } ] }
      end

      def self.nested_modules(own) = own.body.compact_child_nodes.grep(Prism::ModuleNode)

      def self.module_name(node) = node.constant_path.slice.split("::").last

      # A `def self.included` (or the hook `macro` runs) on the module itself.
      def self.hook?(node, macro)
        node.receiver.is_a?(Prism::SelfNode) && ConcernMembership::HOOKS_BY_MACRO.fetch(macro, []).include?(node.name.to_s)
      end

      def self.concern?(own)
        own.body.compact_child_nodes.any? do |node|
          node.is_a?(Prism::CallNode) && node.name == :extend && node.receiver.nil? &&
            Array(node.arguments&.arguments).any? { |arg| arg.slice.delete_prefix("::") == "ActiveSupport::Concern" }
        end
      end

      def self.group(macro) = macro == :singleton_prepend ? :prepended : :mixed

      def self.short_name(arg, short) = arg.is_a?(Prism::SelfNode) ? short : arg.slice.split("::").last

      # The hooks `macro` runs that the module `own` defines: `extended` for an extend, none for a `singleton_class` mixin.
      def self.hooks(own, macro)
        return [] if own&.body.nil?

        own.body.compact_child_nodes.select { |node| node.is_a?(Prism::DefNode) && hook?(node, macro) && node.body }
      end

      # A reader of the hook's parameter, the class mixing the module in; nil when the hook takes none.
      def self.base_reader(hook)
        param = hook.parameters&.requireds&.first
        ->(node) { node.is_a?(Prism::LocalVariableReadNode) && node.name == param.name } if param.respond_to?(:name)
      end

      # [macro, argument, call] for each module a hook adds to the class: `base.include`, `prepend` and `extend`,
      # and `base.singleton_class.include`/`prepend`, `base` being the hook's parameter.
      def self.hook_joins(hook)
        base = base_reader(hook)
        return [] unless base

        Introspectors::AstWalk.each(hook.body).flat_map do |call|
          next [] unless call.is_a?(Prism::CallNode)

          name = call.name
          arguments = Array(call.arguments&.arguments)
          if %i[send public_send].include?(name) && arguments.first.is_a?(Prism::SymbolNode)
            name = arguments.first.unescaped.to_sym
            arguments = arguments.drop(1)
          end
          macro =
            if base.call(call.receiver) then name if Introspectors::Listeners::MixinsListener::MIXIN_MACROS.include?(name)
            elsif Introspectors::Listeners::MixinsListener.singleton_class_of?(call.receiver, &base)
              { include: :singleton_include, prepend: :singleton_prepend }[name]
            end
          next [] unless macro

          arguments.filter_map do |arg|
            [ macro, arg, call ] if arg.is_a?(Prism::SelfNode) || arg.is_a?(Prism::ConstantReadNode) || arg.is_a?(Prism::ConstantPathNode)
          end
        end
      end

      # A mixin record the walk follows for each module from elsewhere a hook adds;
      # `module_defs` reads the module itself and one nested in it.
      def self.hook_mixins(own, label, macro)
        short = label.to_s.split("::").last
        read = [ short, *(own&.body ? nested_modules(own).map { |node| module_name(node) } : []) ]
        hooks(own, macro).flat_map { |hook| hook_joins(hook) }.filter_map do |added, arg, call|
          next if read.include?(short_name(arg, short))

          Introspectors::Listeners::MixinsListener.record(
            call, added, arg.slice.delete_prefix("::"), ancestor: Introspectors::Listeners::MixinsListener::ANCESTOR_MACROS.include?(added)
          )
        end
      end

      # The class's own methods a hook defines: `def x` in `class << base`, and `def self.x` or
      # `class << self` in `base.class_eval`, `base` being the class mixing the module in.
      def self.singleton_defs(hook, label)
        base = base_reader(hook)
        return [] unless base

        Introspectors::AstWalk.each(hook.body).flat_map do |node|
          if node.is_a?(Prism::SingletonClassNode) && base.call(node.expression) then body_defs(node.body).map { |inner| definition(label, inner) }
          elsif node.is_a?(Prism::CallNode) && %i[class_eval class_exec].include?(node.name) && base.call(node.receiver) && node.block
            singleton_scope_defs(node.block.body, label)
          else []
          end
        end
      end

      # The `def self.x` and `class << self` defs a block run with the class as self makes.
      def self.singleton_scope_defs(body, label)
        own_defs(body.is_a?(Prism::StatementsNode) ? body.body : [], label)
      end

      # The `def x` a module body runs with the module as self, `private def x` included.
      def self.body_defs(node, found = [])
        case node
        when nil then found
        when Prism::DefNode then node.receiver.nil? ? found << node : found
        when Prism::ClassNode, Prism::ModuleNode, Prism::SingletonClassNode then found
        when Prism::CallNode
          return found if %i[class_methods included prepended].include?(node.name) && node.block

          node.compact_child_nodes.each_with_object(found) { |child, into| body_defs(child, into) }
        else node.compact_child_nodes.each_with_object(found) { |child, into| body_defs(child, into) }
        end
      end

      # Where code adding a module at `line` of `owner` runs, when not where `owner` itself joins:
      # [:body, [owner, def line]] in a method, [:block, owner, hook?] in a Concern's block or a hook's class_eval.
      def self.added_in(owner, line, bodies, blocks = [], evals = [])
        body = ConcernMacros.enclosing(bodies, line)
        if body then [ :body, [ owner, body.first.begin ] ]
        elsif blocks.any? { |range| range.cover?(line) } then [ :block, owner, false ]
        elsif evals.any? { |range| range.cover?(line) } then in_hook(owner)
        end
      end

      # Where a hook of `owner` runs, each time `owner` is added.
      def self.in_hook(owner) = [ :block, owner, true ]

      # Whether a mixin record adds to the class: an include or prepend, or an `extend` or `singleton_class`
      # include or prepend run with the class as self; in a module's own body `extend` extends the module.
      def self.joins?(mixin, class_self)
        mixin[:ancestor] || (ConcernMembership::SINGLETON_MACROS.include?(mixin[:macro]) && !mixin[:receiver] && class_self)
      end

      def initialize(reader)
        @reader = reader
        @walks = {}
        forget
      end

      # What the walk of the class at `rank` found: the calls its concerns' blocks and hooks make, each
      # one's [label, hook?] by object id, and the modules it reached. A later walk of a rank replaces it.
      def add(rank, included, blocks, mixins)
        @walks[rank] = Reached.new(included, blocks, mixins.to_h { |mixin| [ mixin.label, mixin ] })
        forget
      end

      # Every call the classes may make, by name. Resolving one needs every walk,
      # so a body is read for any call of its name.
      def sites_by_name
        @sites_by_name ||= begin
          found = Run.merge_calls({}, read.found)
          @walks.each_value { |walk| Run.merge_calls(found, walk.included) }
          queue = found.flat_map { |name, sites| sites.compact.map { |site| [ name, site ] } }
          read_bodies = Set.new
          until queue.empty?
            name, site = queue.shift
            defs_named(name).each do |definition|
              next unless read_bodies.add?([ definition.key, root(site).__id__ ])

              # A call of an alias runs the original's body.
              if definition.alias_of
                (found[definition.alias_of] ||= []) << site
                queue << [ definition.alias_of, site ]
              end
              definition.calls.each do |inner, nodes|
                nodes.each do |node|
                  relayed = Relayed.new(node, site, definition)
                  (found[inner] ||= []) << relayed
                  queue << [ inner, relayed ]
                end
              end
            end
          end
          found
        end
      end

      # A copy of `entry` for each run of a call that reaches `definer`'s body
      # ([owner, line]), placed at that call with `tail` after it; none when no call does.
      def placed(entry, definer, tail, site = nil)
        resolve
        sites = site ? [ site ] : @running.fetch(definer, [])
        sites.flat_map { |each| placements(each, definer, tail) }.uniq.map do |rank, at|
          entry.merge(rank: rank, chain_at: at.map(&:to_i))
        end
      end

      # A copy of `entry`, which a module the walk at `rank` reached declares, at each run of that code.
      # One in a method stands at each call reaching it, read from one walk: the method's key is the module's.
      def mixed_in(entry, rank)
        resolve
        mixin = @walks[rank]&.mixins&.[](entry[:from_concern])
        return [ entry.merge(rank: rank) ] unless mixin
        return placed(entry.except(:site, :definer), entry[:definer], [ entry[:location] ], entry[:site]) if entry[:site] && first(mixin.label)&.first == rank
        return [] if entry[:site]

        ran(rank, mixin, entry[:hook]).map { |_, run, at| entry.merge(rank: run, chain_at: [ *at, entry[:location].to_i ]) }
      end

      private

      # Where code of `mixin`, reached by the walk at `rank`, runs: a hook's each time the walk's class
      # adds the module, the rest once, where the chain first adds it (Ruby adds a module once).
      def ran(rank, mixin, hook)
        hook ? events(rank, mixin) : [ first(mixin.label) ].select { |walk, *| walk == rank }
      end

      # [walk rank, rank, at] for each time the code adding `mixin` runs.
      def events(rank, mixin)
        key = [ rank, mixin.label ]
        return @events[key] if @events.key?(key)

        # A module reached again while its own adds are worked out adds nothing more.
        @events[key] = []
        kind, where, hook = mixin.added
        @events[key] =
          case kind
          when :body
            @running.fetch(where, []).flat_map { |site| placements(site, where, mixin.at) }.uniq.map { |run, at| [ rank, run, at ] }
          when :block
            parent = @walks[rank].mixins[where]
            parent ? ran(rank, parent, hook).map { |_, run, at| [ rank, run, [ *at, *mixin.at ] ] } : []
          else [ [ rank, mixin.every ? read.outer : rank, mixin.at ] ]
          end
      end

      def first(label)
        return @first[label] if @first.key?(label)

        # A module whose first add depends on its own (a hook adding it again) has none until one is found.
        @first[label] = nil
        @first[label] = @walks.flat_map { |rank, walk| walk.mixins.key?(label) ? events(rank, walk.mixins[label]) : [] }
                              .min_by { |_, run, at| [ -run, at ] }
      end

      def placements(site, definer, tail)
        runs(root(site)).filter_map do |rank, at|
          path = run_path(site, rank, at)
          chain = path && chain(site, rank, at)
          index = chain&.index { |definition| definition.key == definer }
          [ rank, path + chain.first(index).map(&:super_line) + tail ] if index
        end
      end

      # Where a call stands in the run of its root call: nil when the body making it never runs.
      def run_path(site, rank, at)
        return at unless site.is_a?(Relayed)

        path = run_path(site.outer, rank, at)
        chain = path && chain(site.outer, rank, at)
        index = chain&.index { |definition| definition.key == site.definition.key }
        path + chain.first(index).map(&:super_line) + [ site.location.start_line ] if index
      end

      # The definitions a call runs: the first the lookup finds, then each one a `super` reaches.
      def chain(site, rank, at)
        @chains[[ site.__id__, rank, at ]] ||= begin
          found = lookup(site.name.to_s, rank, at)
          found.take_while.with_index { |_, index| index.zero? || found[index - 1].super_line }
        end
      end

      # Defs one hook call adds share its place: as in Ruby, its earlier argument wins, then the later def in one module.
      def lookup(name, rank, at)
        place = lambda do |provider|
          found = provider.defs[name]
          [ provider.at, -found.joined.to_a.last.to_i, found.line, found.owner.to_s ]
        end
        @providers.select { |provider| provider.defs.key?(name) && provider.rank >= rank && (provider.rank > rank || (provider.at <=> at) <= 0) }
                  .sort { |a, b| ([ a.rank, a.group ] <=> [ b.rank, b.group ]).nonzero? || (place.call(b) <=> place.call(a)) }
                  .flat_map { |provider| resolved(provider.defs[name], provider) }
      end

      # An alias runs what its original name ran where the alias stands.
      def resolved(definition, provider)
        definition.alias_of ? lookup(definition.alias_of, provider.rank, provider.at).first(1) : [ definition ]
      end

      # Each [rank, at] a call outside any method runs in: a class-body call once, at its line;
      # a call a concern's block or hook makes where `ran` puts that concern's code.
      def runs(site)
        rank = read.ranks[site.__id__]
        return [ [ rank, [ site.location.start_line, -1 ] ] ] if rank

        @walks.flat_map do |walk_rank, walk|
          label, hook = walk.blocks[site.__id__]
          mixin = label && walk.mixins[label]
          mixin ? ran(walk_rank, mixin, hook) : []
        end.uniq.map { |_, run, at| [ run, [ *at, site.location.start_line ] ] }
      end

      # Modules join where code adding them runs, and which code a call runs depends on the
      # modules joined before it, so both are read again until neither changes.
      def resolve
        return if @running

        @running = {}
        @providers = []
        inside = @walks.each_value.any? { |walk| walk.mixins.each_value.any? { |mixin| mixin.added&.first == :body } }
        PASSES.times do
          # Cleared so each pass rereads them against the new providers.
          @chains = {}
          @events = {}
          @first = {}
          @providers = providers
          @chains = {}
          running = running_sites
          signature = [ @providers.map { |provider| [ provider.rank, provider.group, provider.at, provider.defs.values.map(&:key) ] },
                        running.transform_values { |sites| sites.map(&:__id__) } ]
          settled = signature == @signature
          @signature = signature
          @running = running
          break if settled || !inside
        end
      end

      # The class files' own methods, each module's where the chain first adds it, and the class's own
      # methods a block or hook defines and a nested module's a hook adds, from their line in each run of that code.
      def providers
        own = read.defs.map { |definition| Provider.new(definition.owner, OWN, definition.at || [ definition.line, 0 ], by_name([ definition ])) }
        joined = @walks.each_value.flat_map { |walk| walk.mixins.keys }.uniq.flat_map do |label|
          walk, rank, at = first(label)
          mixin = walk && @walks[walk].mixins[label]
          next [] unless mixin

          JOINS.filter_map do |kind, group|
            Provider.new(rank, group, at, by_name(mixin.defs[kind])) if mixin.defs[kind].any?
          end
        end
        ran_defs = @walks.flat_map do |rank, walk|
          walk.mixins.each_value.flat_map do |mixin|
            RAN.flat_map do |kind, (hook, group)|
              next [] if mixin.defs[kind].empty?

              ran(rank, mixin, hook).flat_map do |_, run, at|
                mixin.defs[kind].map { |definition| Provider.new(run, group, [ *at, definition.joined&.first || definition.line ], by_name([ definition ])) }
              end
            end
          end
        end
        own + joined + ran_defs
      end

      def by_name(defs) = defs.to_h { |definition| [ definition.name, definition ] }

      # The sites whose call may run each body, by the body's key.
      def running_sites
        sites_by_name.each_value.with_object(Hash.new { |hash, key| hash[key] = [] }) do |sites, index|
          sites.compact.each do |site|
            runs(root(site)).each { |rank, at| chain(site, rank, at).each { |definition| index[definition.key] |= [ site ] } }
          end
        end
      end

      def defs_named(name)
        @defs_named ||= (read.defs + @walks.each_value.flat_map { |walk| walk.mixins.each_value.flat_map { |mixin| mixin.defs.values.flatten } })
                        .group_by(&:name)
        @defs_named.fetch(name, [])
      end

      def root(site)
        site = site.outer while site.is_a?(Relayed)
        site
      end

      def forget
        @sites_by_name = @running = @defs_named = @signature = nil
        @chains = {}
      end

      def read = (@read ||= @reader.call)
    end

    # One walk's state. The root, the directories, the keys and the cache are
    # fixed for the run and `seen`, `collected` and `unresolved` accumulate
    # across it, so they belong to the run rather than to every call.
    class Run
      # Each runs its block with the class as self.
      EVALS = %i[class_eval class_exec instance_eval instance_exec].freeze

      attr_reader :unresolved, :hidden, :included_calls, :skipped_methods, :placement, :block_sites, :mixins

      # The default block belongs to the walk. Once the entries leave it, a
      # caller reading a key the walk never produced would grow one.
      def collected
        {}.merge(@collected)
      end

      # The method names the walk asked the class's calls about, and whether
      # the class calls any of them: a walk it calls none of answers the same
      # for every class that calls none of them.
      attr_reader :consulted

      def calls_any_consulted?
        @consulted.any? { |name| called.include?(name) }
      end

      def initialize(root, dirs, keys, cache, listeners, calls = nil, extra = [], file = nil, known: nil)
        # The class's own file, which can declare a module it includes.
        @own_file = file
        # Written at the top level, so each name is the constant it resolves to.
        @paths = extra.to_h { |mixin| [ mixin.name, mixin.path ] }
        @root = root
        @dirs = dirs
        @keys = keys
        @cache = cache
        @listeners = listeners
        @calls = calls
        @known = known
        @seen = Set.new
        @collected = Hash.new { |hash, key| hash[key] = [] }
        @unresolved = []
        @hidden = []
        @included_calls = {}
        @block_sites = {}
        @skipped_methods = Set.new
        @consulted = Set.new
        @placement = {}
        @mixins = []
        @inside = nil
      end

      # Raw mixin names in, so the exclusion happens here: this is the only
      # place that sees every name at every depth, with the namespace and the
      # directories the lookup needs. `file` is the concern file the names
      # were written in, which can declare the module a name means.
      def walk(names, within, depth, file = nil)
        return if depth.negative?

        # `names` may be the mixin records themselves, which say how each
        # module is mixed in; that decides which of its hooks run.
        names.each do |mixin|
          name, written, given = mixin.is_a?(Hash) ? mixin.values_at(:name, :macro, :path) : mixin
          # A base module comes with the file its top-level name resolves to.
          base = mixin.is_a?(Hash) && mixin.key?(:path)
          @top = name if file.nil?
          next unless ConcernMembership.candidate?(name)

          source = file || @own_file
          nested = !base && source && nested_module(source, name, within)
          label, path =
            if base then [ name, given ]
            elsif nested then [ nested.first, source ]
            else named(name, within) || beside(file, name, within)
            end
          if path.nil? && !base && (outer = in_outer_file(name, within))
            source, nested = outer
            label, path = nested.first, source
          end
          # A module is walked once, as the constant the name resolves to where it is written;
          # a name resolving to none keeps no module's place.
          next unless @seen.add?(path ? label : [ :unresolved, name ])

          macro = written || :include
          singleton = ConcernMembership::SINGLETON_MACROS.include?(macro)
          if ConcernMembership.excluded?(name)
            # Hiding a concern hides what it declared. Only one whose file is
            # here would have been read, so only that one is worth counting.
            # A module mixed in from outside the class's file is not its concern to hide.
            @hidden << name if path && !@paths.key?(label) && !singleton
            next
          end

          data = nested ? introspect_nested(source, nested) : path && introspect(path)
          if data.nil?
            # A module a class extends itself with from a gem is no concern of the app's.
            @unresolved << name unless singleton && path.nil?
            next
          end

          # A nested module's lines count from its own slice, so the ranges parse that.
          tree = nested ? AstCache.parse_string(nested.last.slice).value : AstCache.parse(path).value
          source_key = nested ? "#{source}##{nested.first}" : path
          block_calls, hooked, blocks, evals, unrun = memo([ :included_calls, source_key, label, macro ]) { included_block_calls(tree, label, macro) }
          Run.merge_calls(@included_calls, block_calls)
          hooked = hooked.to_set
          block_calls.each_value { |sites| sites.each { |site| @block_sites[site.__id__] ||= [ label, hooked.include?(site.__id__) ] if site } }
          @mixins << [ label, macro, memo([ :module_defs, source_key, label, macro ]) { module_defs(tree, label, macro) }, @inside ]
          bodies, hooks = method_bodies(data, macro)
          own_lines, inner, concern = memo([ :ranges, source_key, label ]) { own_and_nested_ranges(tree, label) }
          scope = [ singleton, inner + unrun, own_lines, hooks ]
          # The class's own file was read with the class; only its callbacks go by owner.
          keys = nested && source == @own_file ? @keys & [ :callbacks ] : @keys
          keys.each do |key|
            applied(data[key], bodies, *scope).each { |entry| @collected[key] << tagged(entry, label, hook: in_hook?(entry, hooks)) }
          end
          expand_called(tree, data, own_lines, label, keys).each do |key, entries|
            entries.each { |entry| @collected[key] << tagged(entry, label) }
          end

          joined = applied(data[:mixins], bodies, *scope, keep_called: true).filter_map do |mixin|
            added = SingletonLookup.added_in(label, mixin[:location], bodies, blocks, evals)
            [ mixin, added ] if SingletonLookup.joins?(mixin, !added.nil?)
          end
          hooked_mixins = memo([ :hook_mixins, source_key, label, macro ]) { hook_mixins(tree, label, macro) }
          joined.concat(hooked_mixins.map { |mixin| [ mixin, SingletonLookup.in_hook(label) ] })
          joined.sort_by.with_index { |(mixin, _), index| [ mixin[:location].to_i, index ] }.each do |mixin, added|
            outer = @inside
            @inside = [ added, mixin[:location] ] if added
            walk([ dependency(mixin, macro, concern && !added) ], label, depth - 1, path)
            @inside = outer
          end
          # ActiveSupport::Concern runs a concern's dependencies before it, so
          # the walk's post-order is the order the class receives them.
          @placement[label] = [ @top, @placement.size, path ]
        end
      end

      private

      # What depends on a file and a name only, kept in the run's cache: one
      # base-class mixin reaches every model, and Canvas walked its 2,000-line
      # initializer three ways per model. The cache carries a file the walk
      # could not read as well, so 100 models including one reads it once.
      def memo(key)
        return yield if @cache.nil?
        return @cache[key] if @cache.key?(key)

        @cache[key] = yield
      end

      # Resolved as Ruby does, from the enclosing namespace outward: `prepend Wrapper`
      # in DryRunnable is DryRunnable::Wrapper when the concern file declares it.
      def nested_module(file, name, within)
        memo([ :nested, file, name, within ]) { find_nested_module(file, name, within) }
      end

      def find_nested_module(file, name, within)
        modules = memo([ :modules, file ]) { Introspectors::DeclaredConstant.module_nodes(AstCache.parse(file).value) }
        ConcernPaths.candidate_names(name, within).each do |candidate|
          node = modules[candidate]
          return [ candidate, node ] if node
        end
        nil
      rescue StandardError => e
        RailsAiContext.debug_fail(e, nil, label: "nested module #{name} in #{file}")
      end

      # The first candidate Ruby would find, a base module or a file.
      def named(name, within)
        found = memo([ :named, @dirs, name, within ]) { ConcernPaths.find_named(@root, name, within: within, dirs: @dirs) }
        candidates = ConcernPaths.candidate_names(name, within)
        extra = candidates.find { |candidate| @paths.key?(candidate) }
        return found unless extra && (found.nil? || candidates.index(extra) <= candidates.index(found.first))

        [ extra, @paths[extra] ]
      end

      # A plugin's lib is on the load path, so a module it names can sit under the
      # namer's own directory by its constant path, required by a glob.
      def beside(file, name, within)
        return nil unless file

        memo([ :beside, file, name, within ]) do
          dir = File.dirname(file)
          candidates = ConcernPaths.candidate_names(name, within)
          candidate, path = candidates.map { |each| [ each, File.join(dir, "#{each.underscore}.rb") ] }.find { |_, each| File.file?(each) }
          # The file can sit under a shorter path than the constant it declares.
          declared = path && Introspectors::DeclaredConstant.named(SafeFile.read(path), candidate)
          [ candidates.include?(declared) ? declared : candidate, path ] if path
        end
      end

      # `Outer::Inner` with no file of its own, from Outer's file, which Zeitwerk loads it with.
      def in_outer_file(name, within)
        memo([ :outer, name, within ]) do
          candidate, file = ConcernPaths.outer_named(@root, name, within: within, dirs: @dirs)
          found = file && nested_module(file, candidate, nil)
          [ file, found ] if found
        end
      end

      def introspect_nested(file, (qualified, node))
        memo("#{file}##{qualified}") { Introspectors::SourceIntrospector.walk_source(node.slice, @listeners) }
      end

      def introspect(path)
        memo(path) { read(path) }
      end

      # A concern too big or unreadable costs its own declarations, not the
      # including class's whole entry. The size check stays in front of the
      # rescue: max_file_size can be configured above AstCache::MAX_PARSE_SIZE,
      # and the parse raises on its own limit.
      def read(path)
        return nil if File.size(path) > RailsAiContext.configuration.max_file_size

        Introspectors::SourceIntrospector.walk(path, @listeners)
      rescue StandardError => e
        # A permission bit, a directory in place of a file and a bug in a
        # listener all land in `unresolved` alike, so the cause is worth
        # saying where the booted walk already says it.
        RailsAiContext.debug_fail(e, nil, label: "concern introspection of #{path}")
      end

      # A macro inside a `def` runs when the method is called, not when the module is
      # mixed in, so only a class that calls the method gets what it declares.
      #
      # The hooks `macro` runs come back apart: their bodies run for the class,
      # and a hook for another way of mixing in is a method nobody calls.
      def method_bodies(data, macro = :include)
        runs = ConcernMembership::HOOKS_BY_MACRO.fetch(macro, [])
        bodies = []
        hooks = []
        Array(data[:methods]).each do |method|
          next unless method[:location] && method[:end_location]

          range = method[:location]..method[:end_location]
          hook = method[:scope] == :class && runs.include?(method[:name].to_s)
          hook ? hooks << range : bodies << [ range, method[:name].to_s ]
        end
        [ bodies, hooks ]
      end

      # Only this module's own body counts (not a nested module, not other code in the file);
      # an extended module runs none of its body, and called methods are read per call.
      def applied(entries, bodies, extended = false, inner = [], own_lines = nil, hooks = [], keep_called: false)
        Array(entries).select do |entry|
          line = entry.is_a?(Hash) && entry[:location]
          next false if line && own_lines && !own_lines.cover?(line)

          enclosing = ConcernMacros.enclosing(bodies, line)
          next true if enclosing.nil? && hooks.any? { |range| range.cover?(line) }
          next !extended && inner.none? { |range| range.cover?(line) } if enclosing.nil?
          next keep_called if calls?(enclosing.last)

          @skipped_methods << enclosing.last
          false
        end
      end

      # Each called method is read again with that call's literal arguments.
      def expand_called(tree, data, own_lines, label, keys)
        found = Hash.new { |hash, key| hash[key] = [] }
        # A method that declares none of the keys expands to nothing, so the class's calls of it
        # need not be asked about; `:expanded` marks every call read, so it asks about all.
        declared = keys.include?(:expanded) ? nil : keys.flat_map { |key| Array(data[key]) }.filter_map { |entry| entry[:location] if entry.is_a?(Hash) }
        Array(data[:methods]).each do |method|
          name = method[:name].to_s
          next unless method[:location]
          next if declared && declared.none? { |line| (method[:location]..method[:end_location].to_i).cover?(line) }
          next unless calls?(name)
          next if method[:scope] == :class && ConcernMembership::MIXIN_HOOKS.include?(name)
          next if own_lines && !own_lines.cover?(method[:location])

          definition = Introspectors::AstWalk.each(tree).find do |node|
            node.is_a?(Prism::DefNode) && node.name.to_s == name && node.location.start_line == method[:location]
          end
          next unless definition

          expansion, read = ConcernMacros.expand_calls(definition, call_sites.fetch(name), keys, @listeners) do |entry, call|
            [ at_call(entry, call, [ label, method[:location] ]) ]
          end
          expansion.each { |key, entries| found[key].concat(entries) }
          next if read

          owner = Array(method[:owner]).join("::")
          @unresolved |= [ "#{owner.empty? ? label : owner}##{name}" ]
        end
        found
      end

      def own_node(tree, name)
        short = name.to_s.split("::").last.to_s
        Introspectors::DeclaredConstant.definition(Introspectors::AstWalk.each(tree).select do |node|
          constant_node?(node) && node.constant_path.slice.split("::").last.casecmp?(short)
        end)
      end

      def own_and_nested_ranges(tree, name)
        own = own_node(tree, name)
        return [ nil, [], false ] unless own

        # A class nested deeper sits inside one of these ranges already.
        ranges = Introspectors::AstWalk.each(own).filter_map do |node|
          node.location.start_line..node.location.end_line if !node.equal?(own) && constant_node?(node)
        end
        [ own.location.start_line..own.location.end_line, ranges, own.body && SingletonLookup.concern?(own) ]
      end

      # A Concern keeps an include or prepend written in its body as a dependency, and mixes it into
      # the class the way the class mixes in the Concern.
      def dependency(mixin, macro, in_concern_body)
        mixable = %i[include prepend]
        return mixin unless in_concern_body && mixable.include?(macro) && mixable.include?(mixin[:macro] || :include)

        mixin.merge(macro: macro)
      end

      def constant_node?(node)
        node.is_a?(Prism::ModuleNode) || node.is_a?(Prism::ClassNode)
      end

      # Receiverless calls in `included do` outside any method are the includer's;
      # the ids of a plain mixin hook's calls come back apart, as it reruns per include.
      # Also the lines of those blocks, of the `base.class_eval` blocks in hooks, and of the
      # Concern blocks this way of mixing in does not run.
      def included_block_calls(tree, name, macro = :include)
        short = name.to_s.split("::").last.to_s
        block = ConcernMembership::CONCERN_BLOCKS[macro]
        found = {}
        hooked = {}
        ranges = []
        evals = []
        unrun = []
        visit = lambda do |node, owner|
          case node
          when Prism::ClassNode, Prism::ModuleNode
            owner = node.constant_path.slice.split("::").last
          when Prism::CallNode
            if node.name == block && node.receiver.nil? && node.block && owner.to_s.casecmp?(short)
              Introspectors::SourceIntrospector.calls_outside_methods(node.block, found)
              ranges << (node.location.start_line..node.location.end_line)
              return
            end
            if node.receiver.nil? && node.block && ConcernMembership::CONCERN_BLOCKS.value?(node.name) && owner.to_s.casecmp?(short)
              unrun << (node.location.start_line..node.location.end_line)
              return
            end
          when Prism::DefNode
            return hook_calls(node, hooked, evals) if SingletonLookup.hook?(node, macro) && owner.to_s.casecmp?(short)
          end
          node.child_nodes.compact.each { |child| visit.call(child, owner) }
        end
        visit.call(tree, nil)
        [ Run.merge_calls(found, hooked), hooked.values.flatten.map(&:__id__), ranges, evals, unrun ]
      rescue StandardError => e
        RailsAiContext.debug_fail(e, [ {}, [], [], [], [] ], label: "included block calls of #{name}")
      end

      # A hook runs in the includer: its receiverless calls (inside
      # `base.class_eval`) and its calls sent to the includer (`base.x`) are
      # calls the includer makes.
      def hook_calls(node, found, evals)
        return unless node.body

        Introspectors::SourceIntrospector.calls_outside_methods(node.body, found)
        base = SingletonLookup.base_reader(node)
        return unless base

        Introspectors::AstWalk.each(node.body).each do |call|
          next unless call.is_a?(Prism::CallNode) && base.call(call.receiver)

          (found[call.name.to_s] ||= []) << call
          evals << (call.location.start_line..call.location.end_line) if EVALS.include?(call.name) && call.block
        end
      end

      # Asked only once a mixin declares something inside a method, which
      # few do, so most classes never pay for the look.
      def calls?(name)
        @consulted << name
        called.include?(name)
      end

      def called
        @called ||= call_sites.keys.to_set
      end

      # Method name => its call sites; nil stands for a call whose arguments
      # are not known (a caller that names the methods only).
      def call_sites
        @call_sites ||= Run.merge_calls(Run.merge_calls({}, @calls&.sites_by_name), @known).transform_values { |sites| sites.uniq(&:__id__) }
      end

      # Folds `more` - a Hash of call sites, or bare names - into `into`.
      def self.merge_calls(into, more)
        case more
        when Hash then more.each { |name, sites| (into[name.to_s] ||= []).concat(Array(sites)) }
        when nil then nil
        else Array(more).each { |name| (into[name.to_s] ||= []) << nil }
        end
        into
      end

      # A mixin hook runs again for a subclass that includes the module again; a Concern's block does not.
      def tagged(entry, concern_name, hook: false)
        return entry unless entry.is_a?(Hash)

        hook ? entry.merge(from_concern: concern_name, hook: true) : entry.merge(from_concern: concern_name)
      end

      # The call and the body it runs travel with the entry; the class places
      # it once every walk is known.
      def at_call(entry, call, definer)
        call && entry.is_a?(Hash) ? entry.merge(site: call, definer: definer) : entry
      end

      def module_defs(tree, label, macro)
        SingletonLookup.module_defs(own_node(tree, label), label, macro)
      rescue StandardError => e
        RailsAiContext.debug_fail(e, SingletonLookup.module_defs(nil, label, macro), label: "class methods of #{label}")
      end

      def hook_mixins(tree, label, macro)
        SingletonLookup.hook_mixins(own_node(tree, label), label, macro)
      rescue StandardError => e
        RailsAiContext.debug_fail(e, [], label: "hook mixins of #{label}")
      end

      def in_hook?(entry, hooks)
        line = entry.is_a?(Hash) && entry[:location]
        line && hooks.any? { |range| range.cover?(line) }
      end
    end

    module_function

    # What the method `definition` declares at each call in `sites`, by key, each entry placed by the block
    # ([entry, call] in, entries out), with the calls it read as `:expanded`; false second when a call was not.
    def expand_calls(definition, sites, keys, listeners)
      found = Hash.new { |hash, key| hash[key] = [] }
      read = true
      sites.each do |call|
        # `:conditional` and `:foreign` come back as keys too, when asked for.
        Introspectors::CallSiteExpansion.entries(definition, call, listeners).each do |key, entries|
          found[key].concat(Array(entries).flat_map { |entry| yield entry, call }) if keys.include?(key)
        end
        # The call now reads as what the method declares; a caller that read the call itself as a
        # declaration (`validates_translation` as a validation) drops that reading by its line.
        found[:expanded].concat(yield({ method: definition.name.to_s, line: call.location.start_line }, call)) if call && keys.include?(:expanded)
      rescue StandardError => e
        # One call the expansion cannot read costs that call.
        read = false
        RailsAiContext.debug_fail(e, nil, label: "called method expansion of #{definition.name}")
      end
      [ found, read ]
    end

    # The innermost of `bodies`, [range, name] pairs, around `line`.
    def enclosing(bodies, line)
      line && bodies.select { |range, _| range.cover?(line) }.min_by { |range, _| range.size }
    end

    # @param root [String] application root
    # @param mixins [Array<Hash>] MixinsListener records
    # @param keys [Array<Symbol>] payload keys to collect
    # @param prefer [String, nil] owner kind, so a basename two owners share
    #   resolves to this one's concerns directory
    # @param within [String, nil] the enclosing constant of the class, for a
    #   namespace-relative `include`
    # @param calls [SingletonLookup, nil] the class methods the including class
    #   calls in its body; nil counts none
    # @param cache [Hash, nil] a caller-owned store keyed by concern file, so
    #   one run walks a file once however many classes include it. The caller
    #   owns its lifetime: a process-wide store would go stale, because the
    #   configured paths and the files themselves change in-process.
    # @param file [String, nil] the class's own file, which can declare a module it includes
    # @param extra [Array<BaseMixins::Mixin>] modules mixed into every class of
    #   the kind from outside its file, read from the file they name
    # @param listeners [Hash] the listener map each concern file is walked
    #   with; it must carry `mixins` for the walk to follow nested concerns
    # @return [Array(Hash, Array<String>, Array<String>, Hash, Hash, Set, Hash, Array)]
    #   the collected entries per key, the names whose file could not be read,
    #   the names `excluded_concerns` hid that the walk would otherwise have
    #   read, the methods `included` blocks call with their call sites, and for
    #   each concern read the top-level mixin that reached it, its place in
    #   the order Ruby adds them and its file, the methods whose declarations the walk held
    #   back because nothing it knew of calls them, the concern each `included`
    #   block call site belongs to and whether it is a plain hook, by the site's
    #   object id, and for each module read [label, macro, the class methods it gives
    #   (`SingletonLookup.module_defs`), and [added, line] when code a module runs later adds it
    #   (`SingletonLookup.added_in`)]
    def collect(root, mixins, keys:, prefer: nil, within: nil, cache: nil, calls: nil,
                listeners: Introspectors::SourceIntrospector::LISTENER_MAP, extra: [], file: nil)
      # A module the class extends itself with gives it class methods, though no ancestor.
      walked = Array(mixins).select { |mixin| SingletonLookup.joins?(mixin, true) } +
               extra.map { |mixin| { name: mixin.name, macro: mixin.macro, path: mixin.path } }
      return [ {}, [], [], {}, {}, Set.new, {}, [] ] if walked.empty?

      # Most walks never look at the class's calls, so a base's walk is the
      # same for every subclass: kept in the caller's per-run cache.
      memo_key = cache && [ :collect, root.to_s, mixins, keys, prefer, within, listeners, extra, file ]
      if memo_key && (consulted, result = cache[memo_key])
        return fresh(result) if consulted.empty? || !consulted.intersect?(Run.merge_calls({}, calls&.sites_by_name).keys.to_set)
      end

      # Resolved once per call and held by the run: the configured paths
      # change in-process, so a cache keyed on root goes stale with no reset
      # hook.
      dirs = ConcernPaths.ordered_dirs(root.to_s, prefer)
      run = Run.new(root.to_s, dirs, keys, cache, listeners, calls, extra, file)
      run.walk(walked, within, MAX_DEPTH)
      depends_on_calls = run.calls_any_consulted?
      # An `included do` can call a method a concern read before the block did, so walk
      # again with the known calls until no method the walk asked about has a new call.
      known = {}
      MAX_DEPTH.times do
        asked = run.skipped_methods | run.consulted
        break if run.included_calls.none? { |name, sites| asked.include?(name) && (sites.map(&:__id__) - Array(known[name]).map(&:__id__)).any? }

        depends_on_calls = true
        known = run.included_calls
        run = Run.new(root.to_s, dirs, keys, cache, listeners, calls, extra, file, known: known)
        run.walk(walked, within, MAX_DEPTH)
      end

      result = [ run.collected, run.unresolved, run.hidden, run.included_calls, run.placement, run.skipped_methods,
                 run.block_sites, run.mixins ]
      cache[memo_key] = [ run.consulted, fresh(result) ] if memo_key && !depends_on_calls
      result
    end

    # A copy a caller may change without changing the cached walk.
    def fresh(result)
      collected, unresolved, hidden, included, placement, skipped, blocks, mixins = result
      [ collected.transform_values { |entries| entries.map { |entry| entry.is_a?(Hash) ? entry.dup : entry } },
        unresolved.dup, hidden.dup, included.transform_values(&:dup), placement.dup, skipped.dup, blocks.dup, mixins.dup ]
    end
    private_class_method :fresh
  end
end
