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
    # that body (`via`) was made; `definition` is the body it sits in.
    Relayed = Struct.new(:node, :via, :definition) do
      def arguments = node.arguments
      def location = node.location
      def name = node.name
    end

    # Ruby's class-method lookup over a class (rank 0), its bases nearest first and the modules
    # every model has: which definitions a call runs, and so where what they declare lands.
    class ClassCalls
      # A class method one provider defines; `owner` is a class file's rank or a module's label.
      Def = Struct.new(:owner, :name, :line, :super_line, :calls) do
        def key = [ owner, line ]
      end
      # One step of a singleton ancestry, existing from `at` ([line, order]): `group` 0 prepended,
      # 1 the class's own def, 2 mixed in. A module a called method includes ranks by that `site`.
      Provider = Struct.new(:rank, :group, :at, :defs, :site)
      # The class files' body calls by name, each one's rank, their own defs, and the outermost rank.
      Read = Struct.new(:found, :ranks, :providers, :outer)

      def self.definition(owner, node)
        super_node = node.body && Introspectors::AstWalk.each(node.body).find do |inner|
          inner.is_a?(Prism::SuperNode) || inner.is_a?(Prism::ForwardingSuperNode)
        end
        calls = node.body ? Introspectors::SourceIntrospector.calls_outside_methods(node.body, self_receiver: true) : {}
        Def.new(owner, node.name.to_s, node.location.start_line, super_node&.location&.start_line, calls)
      end

      def initialize(reader)
        @reader = reader
        @walks = {}
        forget
      end

      # What the walk of the class at `rank` found: the calls its concerns' blocks make, each
      # block site's [at, hook?], and the providers it mixes in. A later walk of a rank replaces it.
      def add(rank, included, blocks, providers)
        @walks[rank] = [ included, blocks, providers ]
        forget
      end

      # Every call the classes may make, by name. Resolving one needs every walk,
      # so a body is read for any call of its name.
      def call
        @call ||= begin
          found = Run.merge_calls({}, read.found)
          @walks.each_value { |included, *| Run.merge_calls(found, included) }
          queue = found.flat_map { |name, sites| sites.compact.map { |site| [ name, site ] } }
          read_bodies = Set.new
          until queue.empty?
            name, site = queue.shift
            providers.each do |_, provider|
              definition = provider.defs[name]
              next unless definition && read_bodies.add?([ definition.key, root(site).__id__ ])

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
        sites = site ? [ site ] : running(definer)
        sites.flat_map { |each| placements(each, definer, tail) }.uniq.map do |rank, at|
          entry.merge(rank: rank, chain_at: at.map(&:to_i), rerun: true)
        end
      end

      private

      def placements(site, definer, tail)
        runs(root(site)).filter_map do |rank, at|
          keys = keys_at(site, rank, at)
          chain = keys && chain(site, rank, at)
          index = chain&.index { |definition| definition.key == definer }
          [ rank, keys + chain.first(index).map(&:super_line) + tail ] if index
        end
      end

      # Where a call stands in the run of its root call: nil when the body making it never runs.
      def keys_at(site, rank, at)
        return at unless site.is_a?(Relayed)

        keys = keys_at(site.via, rank, at)
        chain = keys && chain(site.via, rank, at)
        index = chain&.index { |definition| definition.key == site.definition.key }
        keys + chain.first(index).map(&:super_line) + [ site.location.start_line ] if index
      end

      # The definitions a call runs: the first the lookup finds, then each one a `super` reaches.
      def chain(site, rank, at)
        @chains[[ site.__id__, rank ]] ||= begin
          found = lookup(site.name.to_s, rank, at)
          found.take_while.with_index { |_, index| index.zero? || found[index - 1].super_line }
        end
      end

      def lookup(name, rank, at)
        providers.select { |from, provider| provider.defs.key?(name) && from >= rank && (from > rank || (provider.at <=> at) <= 0) }
                 .sort { |(a_rank, a), (b_rank, b)| ([ a_rank, a.group ] <=> [ b_rank, b.group ]).nonzero? || (b.at <=> a.at) }
                 .map { |_, provider| provider.defs[name] }
      end

      # Each [rank, at] a call outside any method runs in: a class-body call once; a
      # Concern's block once, in the outermost class including it; a plain hook on each include.
      def runs(site)
        rank = read.ranks[site.__id__]
        return [ [ rank, [ site.location.start_line, -1 ] ] ] if rank

        found = @walks.filter_map { |walk_rank, (_, blocks)| [ walk_rank, *blocks[site.__id__] ] if blocks.key?(site.__id__) }
        found = found.max_by(1, &:first) unless found.any? { |*, hook| hook }
        found.map { |walk_rank, at, _| [ walk_rank, at ] }
      end

      # [rank, provider] pairs. Ruby adds a module to an ancestry once, at the
      # outermost class mixing it in.
      def providers
        @providers ||= begin
          mixed = @walks.each_value.flat_map { |*, list| list }.flat_map do |provider|
            next [ [ provider.rank || read.outer, provider ] ] unless provider.site

            runs(root(provider.site)).map { |rank, _| [ rank, provider ] }
          end
          read.providers.map { |provider| [ provider.rank, provider ] } +
            mixed.group_by { |_, provider| provider.defs.each_value.first.owner }.map { |_, pairs| pairs.max_by(&:first) }
        end
      end

      # The sites whose call runs the body `key` names.
      def running(key)
        @running ||= call.each_value.with_object(Hash.new { |hash, k| hash[k] = [] }) do |sites, index|
          sites.compact.each do |site|
            runs(root(site)).each { |rank, at| chain(site, rank, at).each { |definition| index[definition.key] |= [ site ] } }
          end
        end
        @running.fetch(key, [])
      end

      def root(site)
        site = site.via while site.is_a?(Relayed)
        site
      end

      def forget
        @call = @providers = @running = nil
        @chains = {}
      end

      def read = (@read ||= @reader.call)
    end

    # One walk's state. The root, the directories, the keys and the cache are
    # fixed for the run and `seen`, `collected` and `unresolved` accumulate
    # across it, so they belong to the run rather than to every call.
    class Run
      attr_reader :unresolved, :hidden, :included_calls, :skipped_methods, :placement, :block_sites, :providers

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
        @paths = extra.to_h { |mixin| [ mixin.name, mixin.path ] }
        @macros = extra.to_h { |mixin| [ mixin.name, mixin.macro ] }
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
        @providers = []
        @via = nil
      end

      # Raw mixin names in, so the exclusion happens here: this is the only
      # place that sees every name at every depth, with the namespace and the
      # directories the lookup needs. `file` is the concern file the names
      # were written in, which can declare the module a name means.
      def walk(names, within, depth, file = nil)
        return if depth.negative?

        # `names` may be the mixin records themselves, which say how each
        # module is mixed in; that decides which of its hooks run.
        if names.first.is_a?(Hash)
          names.each { |mixin| @macros[mixin[:name]] ||= mixin[:macro] }
          names = names.map { |mixin| mixin[:name] }.uniq
        end

        names.each do |name|
          @top = name if file.nil?
          next unless @seen.add?(name)
          next unless ConcernMembership.candidate?(name)

          source = file || @own_file
          nested = source && nested_module(source, name, within)
          path =
            if nested then source
            elsif @paths.key?(name) then @paths[name]
            else ConcernPaths.find_file(@root, name, within: within, dirs: @dirs) || beside(file, name, within)
            end
          macro = @macros[name] || :include
          if ConcernMembership.excluded?(name)
            # Hiding a concern hides what it declared. Only one whose file is
            # here would have been read, so only that one is worth counting.
            # A module mixed in from outside the class's file is not its concern to hide.
            @hidden << name if path && !@paths.key?(name) && macro != :extend
            next
          end

          data = nested ? introspect_nested(source, nested) : path && introspect(path)
          if data.nil?
            # A module a class extends itself with from a gem is no concern of the app's.
            @unresolved << name unless macro == :extend && path.nil?
            next
          end

          label = nested ? nested.first : name
          # A nested module's lines count from its own slice, so the ranges parse that.
          tree = nested ? AstCache.parse_string(nested.last.slice).value : AstCache.parse(path).value
          source_key = nested ? "#{source}##{nested.first}" : path
          block_calls, hooked = memo([ :included_calls, source_key, label, macro ]) { included_block_calls(tree, label, macro) }
          Run.merge_calls(@included_calls, block_calls)
          hooked = hooked.to_set
          block_calls.each_value { |sites| sites.each { |site| @block_sites[site.__id__] ||= [ label, hooked.include?(site.__id__) ] if site } }
          defs = memo([ :provided, source_key, label, macro ]) { provided(tree, label, macro) }
          @providers << [ label, macro, defs, @via ] if defs.any?
          bodies, hooks = method_bodies(data, macro)
          own_lines, inner = memo([ :ranges, source_key, label ]) { own_and_nested_ranges(tree, label) }
          scope = [ macro == :extend, inner, own_lines, hooks ]
          # The class's own file was read with the class; only its callbacks go by owner.
          keys = nested && source == @own_file ? @keys & [ :callbacks ] : @keys
          keys.each do |key|
            applied(data[key], bodies, *scope).each do |entry|
              rerun = key == :callbacks && in_hook?(entry, hooks)
              via(tagged(entry, label, rerun: rerun), rerun).each { |copy| @collected[key] << copy }
            end
          end
          expand_called(tree, data, own_lines, label, keys).each do |key, entries|
            entries.each { |entry| via(tagged(entry, label), false).each { |copy| @collected[key] << copy } }
          end

          applied(data[:mixins], bodies, *scope, keep_called: true).each do |mixin|
            next unless mixin[:ancestor]

            enclosing = ConcernMacros.enclosing(bodies, mixin[:location])
            sites = enclosing ? call_sites.fetch(enclosing.last, []).compact : []
            outer = @via
            @via = [ [ label, enclosing.first.begin ], mixin[:location], sites ] if sites.any?
            walk([ mixin ], label, depth - 1, path)
            @via = outer
          end
          # ActiveSupport::Concern runs a concern's dependencies before it, so
          # the walk's post-order is the order the class receives them.
          @placement[label] = [ @top, @placement.size ]
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

      # A plugin's lib is on the load path, so a module it names can sit under the
      # namer's own directory by its constant path, required by a glob.
      def beside(file, name, within)
        return nil unless file

        memo([ :beside, file, name, within ]) do
          dir = File.dirname(file)
          ConcernPaths.candidate_names(name, within).map { |candidate| File.join(dir, "#{candidate.underscore}.rb") }.find { |path| File.file?(path) }
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
        Array(data[:methods]).each do |method|
          name = method[:name].to_s
          next unless calls?(name) && method[:location]
          next if method[:scope] == :class && ConcernMembership::MIXIN_HOOKS.include?(name)
          next if own_lines && !own_lines.cover?(method[:location])

          definition = Introspectors::AstWalk.each(tree).find do |node|
            node.is_a?(Prism::DefNode) && node.name.to_s == name && node.location.start_line == method[:location]
          end
          next unless definition

          call_sites.fetch(name).each do |call|
            expansion = Introspectors::CallSiteExpansion.entries(definition, call, @listeners)
            # `:conditional` and `:foreign` come back as keys too, when asked for.
            expansion.each do |key, entries|
              next unless keys.include?(key)

              found[key].concat(Array(entries).map { |entry| at_call(entry, call, [ label, method[:location] ]) })
            end
            # The call site now reads as what the method declares; a caller that
            # read the call itself as a declaration (`validates_translation` as a
            # validation) drops that reading by its line.
            if call && keys.include?(:expanded)
              found[:expanded] << at_call({ method: name, line: call.location.start_line }, call, [ label, method[:location] ])
            end
          rescue StandardError => e
            # One call the expansion cannot read costs that method, named as unread.
            owner = Array(method[:owner]).join("::")
            @unresolved |= [ "#{owner.empty? ? label : owner}##{name}" ]
            RailsAiContext.debug_fail(e, nil, label: "called method expansion of #{name}")
          end
        end
        found
      end

      def own_node(tree, name)
        short = name.to_s.split("::").last.to_s
        Introspectors::AstWalk.each(tree).find do |node|
          constant_node?(node) && node.constant_path.slice.split("::").last.casecmp?(short)
        end
      end

      def own_and_nested_ranges(tree, name)
        own = own_node(tree, name)
        return [ nil, [] ] unless own

        # A class nested deeper sits inside one of these ranges already.
        ranges = Introspectors::AstWalk.each(own).filter_map do |node|
          node.location.start_line..node.location.end_line if !node.equal?(own) && constant_node?(node)
        end
        [ own.location.start_line..own.location.end_line, ranges ]
      end

      def constant_node?(node)
        node.is_a?(Prism::ModuleNode) || node.is_a?(Prism::ClassNode)
      end

      # Receiverless calls in `included do` outside any method are the includer's;
      # the ids of a plain mixin hook's calls come back apart, as it reruns per include.
      def included_block_calls(tree, name, macro = :include)
        short = name.to_s.split("::").last.to_s
        block = ConcernMembership::CONCERN_BLOCKS[macro]
        runs = ConcernMembership::HOOKS_BY_MACRO.fetch(macro, [])
        found = {}
        hooked = {}
        visit = lambda do |node, owner|
          case node
          when Prism::ClassNode, Prism::ModuleNode
            owner = node.constant_path.slice.split("::").last
          when Prism::CallNode
            if node.name == block && node.receiver.nil? && node.block && owner.to_s.casecmp?(short)
              Introspectors::SourceIntrospector.calls_outside_methods(node.block, found)
              return
            end
          when Prism::DefNode
            return hook_calls(node, hooked) if mixin_hook?(node, runs) && owner.to_s.casecmp?(short)
          end
          node.child_nodes.compact.each { |child| visit.call(child, owner) }
        end
        visit.call(tree, nil)
        [ Run.merge_calls(found, hooked), hooked.values.flatten.map(&:__id__) ]
      rescue StandardError => e
        RailsAiContext.debug_fail(e, [ {}, [] ], label: "included block calls of #{name}")
      end


      def mixin_hook?(node, runs)
        node.receiver.is_a?(Prism::SelfNode) && runs.include?(node.name.to_s)
      end

      # A hook runs in the includer: its receiverless calls (inside
      # `base.class_eval`) and its calls sent to the includer (`base.x`) are
      # calls the includer makes.
      def hook_calls(node, found)
        return unless node.body

        Introspectors::SourceIntrospector.calls_outside_methods(node.body, found)
        param = node.parameters&.requireds&.first
        return unless param.respond_to?(:name)

        Introspectors::AstWalk.each(node.body).each do |call|
          next unless call.is_a?(Prism::CallNode) && call.receiver.is_a?(Prism::LocalVariableReadNode)
          next unless call.receiver.name == param.name

          (found[call.name.to_s] ||= []) << call
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
        @call_sites ||= Run.merge_calls(Run.merge_calls({}, @calls&.call), @known).transform_values { |sites| sites.uniq(&:__id__) }
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

      # A mixin hook or a called class method runs again for a subclass that
      # includes or calls it again; a Concern's `included` block does not.
      def tagged(entry, concern_name, rerun: false)
        return entry unless entry.is_a?(Hash)

        rerun ? entry.merge(from_concern: concern_name, rerun: true) : entry.merge(from_concern: concern_name)
      end

      # The call and the body it runs travel with the entry; the class places
      # it once every walk is known.
      def at_call(entry, call, definer)
        call && entry.is_a?(Hash) ? entry.merge(site: call, definer: definer) : entry
      end

      # An entry of a module a called method includes stands at each call of that method;
      # a Concern's block in it runs at the first.
      def via(entry, rerun)
        return [ entry ] unless @via && entry.is_a?(Hash) && !entry.key?(:site)

        definer, line, sites = @via
        sites.map { |site| entry.merge(site: site, definer: definer, via_line: line, **(rerun ? {} : { once: true })) }
      end

      # The class methods the module gives a class it is mixed into: on extend its own
      # methods; otherwise its `class_methods`, its ClassMethods and what its hooks extend.
      def provided(tree, label, macro)
        own = own_node(tree, label)
        return [] unless own&.body

        nodes =
          if macro == :extend then body_defs(own.body)
          else
            extended = hook_extends(own, macro) | [ "ClassMethods" ]
            blocks = own.body.compact_child_nodes.select { |node| node.is_a?(Prism::CallNode) && node.name == :class_methods && node.block }
            nested = own.body.compact_child_nodes.select { |node| node.is_a?(Prism::ModuleNode) && extended.include?(node.constant_path.slice.split("::").last) }
            short = label.to_s.split("::").last
            blocks.flat_map { |block| body_defs(block.block.body) } + nested.flat_map { |node| body_defs(node.body) } +
              (extended.include?(short) ? body_defs(own.body) : [])
          end
        nodes.map { |node| ClassCalls.definition(label, node) }
      rescue StandardError => e
        RailsAiContext.debug_fail(e, [], label: "class methods of #{label}")
      end

      # The constants a mixin hook extends its includer with.
      def hook_extends(own, macro)
        runs = ConcernMembership::HOOKS_BY_MACRO.fetch(macro, [])
        own.body.compact_child_nodes.select { |node| node.is_a?(Prism::DefNode) && mixin_hook?(node, runs) && node.body }.flat_map do |hook|
          Introspectors::AstWalk.each(hook.body).flat_map do |call|
            next [] unless call.is_a?(Prism::CallNode)

            arguments = Array(call.arguments&.arguments)
            if %i[send public_send].include?(call.name) && arguments.first&.slice == ":extend" then arguments = arguments.drop(1)
            elsif call.name != :extend then next []
            end

            arguments.filter_map { |arg| arg.slice.split("::").last if arg.is_a?(Prism::ConstantReadNode) || arg.is_a?(Prism::ConstantPathNode) }
          end
        end
      end

      # The `def x` a module body runs with the module as self, `private def x` included.
      def body_defs(node, found = [])
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

      def in_hook?(entry, hooks)
        line = entry.is_a?(Hash) && entry[:location]
        line && hooks.any? { |range| range.cover?(line) }
      end
    end

    module_function

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
    # @param calls [ClassCalls, nil] the class methods the including class
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
    #   each concern read the top-level mixin that reached it and its place in
    #   the order Ruby adds them, the methods whose declarations the walk held
    #   back because nothing it knew of calls them, the concern each `included`
    #   block call site belongs to and whether it is a plain hook, by the site's
    #   object id, and [label, macro, class methods, via] for each module giving the class some
    def collect(root, mixins, keys:, prefer: nil, within: nil, cache: nil, calls: nil,
                listeners: Introspectors::SourceIntrospector::LISTENER_MAP, extra: [], file: nil)
      # A module the class extends itself with gives it class methods, though no ancestor.
      walked = Array(mixins).select { |mixin| mixin[:ancestor] || (mixin[:macro] == :extend && !mixin[:receiver]) } +
               extra.map { |mixin| { name: mixin.name, macro: mixin.macro } }
      return [ {}, [], [], {}, {}, Set.new, {}, [] ] if walked.empty?

      # Most walks never look at the class's calls, so a base's walk is the
      # same for every subclass: kept in the caller's per-run cache.
      memo_key = cache && [ :collect, root.to_s, mixins, keys, prefer, within, listeners, extra, file ]
      if memo_key && (consulted, result = cache[memo_key])
        return fresh(result) if consulted.empty? || !consulted.intersect?(Run.merge_calls({}, calls&.call).keys.to_set)
      end

      # Resolved once per call and held by the run: the configured paths
      # change in-process, so a cache keyed on root goes stale with no reset
      # hook.
      dirs = ConcernPaths.ordered_dirs(root.to_s, prefer)
      run = Run.new(root.to_s, dirs, keys, cache, listeners, calls, extra, file)
      run.walk(walked, within, MAX_DEPTH)
      depends_on_calls = run.calls_any_consulted?
      # An `included do` can call a method whose macros an earlier concern held back,
      # so walk again with the known calls until nothing held back is called.
      MAX_DEPTH.times do
        break unless run.skipped_methods.intersect?(run.included_calls.keys.to_set)

        depends_on_calls = true

        run = Run.new(root.to_s, dirs, keys, cache, listeners, calls, extra, file, known: run.included_calls)
        run.walk(walked, within, MAX_DEPTH)
      end

      result = [ run.collected, run.unresolved, run.hidden, run.included_calls, run.placement, run.skipped_methods,
                 run.block_sites, run.providers ]
      cache[memo_key] = [ run.consulted, fresh(result) ] if memo_key && !depends_on_calls
      result
    end

    # A copy a caller may change without changing the cached walk.
    def fresh(result)
      collected, unresolved, hidden, included, placement, skipped, blocks, providers = result
      [ collected.transform_values { |entries| entries.map { |entry| entry.is_a?(Hash) ? entry.dup : entry } },
        unresolved.dup, hidden.dup, included.transform_values(&:dup), placement.dup, skipped.dup, blocks.dup, providers.dup ]
    end
    private_class_method :fresh
  end
end
