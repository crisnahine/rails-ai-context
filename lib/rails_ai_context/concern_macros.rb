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

    # One walk's state. The root, the directories, the keys and the cache are
    # fixed for the run and `seen`, `collected` and `unresolved` accumulate
    # across it, so they belong to the run rather than to every call.
    class Run
      attr_reader :unresolved, :hidden, :included_calls, :skipped_methods, :placement

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

      def initialize(root, dirs, keys, cache, listeners, calls = nil, extra = [], file = nil)
        # The class's own file: a module it declares there and includes is
        # its own body, already read with it.
        @own_file = file
        @paths = extra.to_h { |mixin| [ mixin.name, mixin.path ] }
        @macros = extra.to_h { |mixin| [ mixin.name, mixin.macro ] }
        @extended = extra.select { |mixin| mixin.macro == :extend }.map(&:name).to_set
        @root = root
        @dirs = dirs
        @keys = keys
        @cache = cache
        @listeners = listeners
        @calls = calls
        @seen = Set.new
        @collected = Hash.new { |hash, key| hash[key] = [] }
        @unresolved = []
        @hidden = []
        @included_calls = {}
        @skipped_methods = Set.new
        @consulted = Set.new
        @placement = {}
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
          next if file.nil? && @own_file && nested_module(@own_file, name, within)

          nested = file && nested_module(file, name, within)
          path =
            if nested then file
            elsif @paths.key?(name) then @paths[name]
            else ConcernPaths.find_file(@root, name, within: within, dirs: @dirs)
            end
          if ConcernMembership.excluded?(name)
            # Hiding a concern hides what it declared. Only one whose file is
            # here would have been read, so only that one is worth counting.
            # A module mixed in from outside the class's file is not its concern to hide.
            @hidden << name if path && !@paths.key?(name)
            next
          end

          data = nested ? introspect_nested(file, nested) : path && introspect(path)
          if data.nil?
            @unresolved << name
            next
          end

          label = nested ? nested.first : name
          # A nested module's lines count from its own slice, so the ranges parse that.
          tree = nested ? AstCache.parse_string(nested.last.slice).value : AstCache.parse(path).value
          macro = @macros[name] || :include
          source_key = nested ? "#{file}##{nested.first}" : path
          Run.merge_calls(@included_calls,
                          memo([ :included_calls, source_key, label, macro ]) { included_block_calls(tree, label, macro) })
          bodies, hooks = method_bodies(data, macro)
          own_lines, inner = memo([ :ranges, source_key, label ]) { own_and_nested_ranges(tree, label) }
          extended = @extended.include?(name)
          scope = [ extended, inner, own_lines, hooks ]
          @keys.each do |key|
            applied(data[key], bodies, *scope).each { |entry| @collected[key] << tagged(entry, label) }
          end
          expand_called(tree, data, own_lines, label).each do |key, entries|
            entries.each { |entry| @collected[key] << tagged(entry, label) }
          end

          mixins = applied(data[:mixins], bodies, *scope, keep_called: true)
          walk(mixins.select { |mixin| mixin[:ancestor] }, label, depth - 1, path)
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

          enclosing = line && bodies.select { |range, _| range.cover?(line) }.min_by { |range, _| range.size }
          next true if enclosing.nil? && hooks.any? { |range| range.cover?(line) }
          next !extended && inner.none? { |range| range.cover?(line) } if enclosing.nil?
          next keep_called if calls?(enclosing.last)

          @skipped_methods << enclosing.last
          false
        end
      end

      # Each called method is read again with that call's literal arguments.
      def expand_called(tree, data, own_lines, label)
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
            expansion.each { |key, entries| found[key].concat(Array(entries)) if @keys.include?(key) }
            # The call site now reads as what the method declares; a caller that
            # read the call itself as a declaration (`validates_translation` as a
            # validation) drops that reading by its line.
            found[:expanded] << { method: name, line: call.location.start_line } if call && @keys.include?(:expanded)
          rescue StandardError => e
            # One call the expansion cannot read costs that method, named as unread.
            owner = Array(method[:owner]).join("::")
            @unresolved |= [ "#{owner.empty? ? label : owner}##{name}" ]
            RailsAiContext.debug_fail(e, nil, label: "called method expansion of #{name}")
          end
        end
        found
      end

      def own_and_nested_ranges(tree, name)
        short = name.to_s.split("::").last.to_s
        own = Introspectors::AstWalk.each(tree).find do |node|
          constant_node?(node) && node.constant_path.slice.split("::").last.casecmp?(short)
        end
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

      # Receiverless calls in `included do` outside any method run in the includer's
      # class, so the includer calls them.
      def included_block_calls(tree, name, macro = :include)
        short = name.to_s.split("::").last.to_s
        block = ConcernMembership::CONCERN_BLOCKS[macro]
        runs = ConcernMembership::HOOKS_BY_MACRO.fetch(macro, [])
        found = {}
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
            return hook_calls(node, found) if mixin_hook?(node, runs) && owner.to_s.casecmp?(short)
          end
          node.child_nodes.compact.each { |child| visit.call(child, owner) }
        end
        visit.call(tree, nil)
        found
      rescue StandardError => e
        RailsAiContext.debug_fail(e, {}, label: "included block calls of #{name}")
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
        @call_sites ||= Run.merge_calls({}, @calls&.call).transform_values { |sites| sites.uniq(&:__id__) }
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

      def tagged(entry, concern_name)
        entry.is_a?(Hash) ? entry.merge(from_concern: concern_name) : entry
      end
    end

    module_function

    # @param root [String] application root
    # @param mixins [Array<Hash>] MixinsListener records
    # @param keys [Array<Symbol>] payload keys to collect
    # @param prefer [String, nil] owner kind, so a basename two owners share
    #   resolves to this one's concerns directory
    # @param within [String, nil] the enclosing constant of the class, for a
    #   namespace-relative `include`
    # @param calls [#call, nil] answers the class methods the including class
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
    # @return [Array(Hash, Array<String>, Array<String>, Hash, Hash, Set)] the
    #   collected entries per key, the names whose file could not be read, the
    #   names `excluded_concerns` hid that the walk would otherwise have read,
    #   the methods `included` blocks call with their call sites, and for each
    #   concern read the top-level mixin that reached it and its place in the
    #   order Ruby adds them, and the methods whose declarations the walk held
    #   back because nothing it knew of calls them
    def collect(root, mixins, keys:, prefer: nil, within: nil, cache: nil, calls: nil,
                listeners: Introspectors::SourceIntrospector::LISTENER_MAP, extra: [], file: nil)
      names = ConcernMembership.mixin_names(mixins) | extra.map(&:name)
      return [ {}, [], [], {}, {}, Set.new ] if names.empty?

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
      walked = Array(mixins).select { |mixin| mixin[:ancestor] } + extra.map { |mixin| { name: mixin.name, macro: mixin.macro } }
      run.walk(walked, within, MAX_DEPTH)
      depends_on_calls = run.calls_any_consulted?
      # An `included do` can call a method whose macros an earlier concern held back,
      # so walk again with the known calls until nothing held back is called.
      MAX_DEPTH.times do
        break unless run.skipped_methods.intersect?(run.included_calls.keys.to_set)

        depends_on_calls = true

        known = run.included_calls
        run = Run.new(root.to_s, dirs, keys, cache, listeners, -> { Run.merge_calls(Run.merge_calls({}, calls&.call), known) },
                      extra, file)
        run.walk(walked, within, MAX_DEPTH)
      end

      result = [ run.collected, run.unresolved, run.hidden, run.included_calls, run.placement, run.skipped_methods ]
      cache[memo_key] = [ run.consulted, fresh(result) ] if memo_key && !depends_on_calls
      result
    end

    # A copy a caller may change without changing the cached walk.
    def fresh(result)
      collected, unresolved, hidden, included, placement, skipped = result
      [ collected.transform_values { |entries| entries.map { |entry| entry.is_a?(Hash) ? entry.dup : entry } },
        unresolved.dup, hidden.dup, included.transform_values(&:dup), placement.dup, skipped.dup ]
    end
    private_class_method :fresh
  end
end
