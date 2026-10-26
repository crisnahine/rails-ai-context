# frozen_string_literal: true

require "set"

module RailsAiContext
  # What a class declares once its superclasses, its concerns and the class methods it calls have run.
  # One walk orders them as Ruby runs them, for callbacks, associations, filters and job macros alike.
  module ClassDeclarations
    # A class on the chain, the class first: its file and its body's walk trimmed to the class; `own` is nil when unread.
    Link = Struct.new(:name, :file, :own)
    # What the walk could not read, and why: `:concern`, `:base`, or `:method` for a method a call reaches.
    Unread = Struct.new(:name, :reason)
    # `declarations` per key in run order, a base's naming it in `declared_in`; `files` by module name.
    Result = Struct.new(:declarations, :unread, :hidden, :chain, :files, :class_methods, :origins) do
      def origin(entry) = origins[entry]
    end
    # How a class method's declaration reached the class: by a class body's call, via a concern's block, from a file, inherited or not.
    Origin = Struct.new(:called, :via, :file, :inherited)

    # Where an entry runs, kept while the walk places it; never in a result.
    CHAIN_KEYS = %i[rank chain_at hook owner].freeze
    ORIGIN = :class_declarations_origin
    # Two runs of one line are two callbacks; any other entry placed twice is one declaration.
    EACH_RUN = %i[callbacks associations filters].freeze

    module_function

    # @param class_name [String] the class, as the app names it
    # @param lookup [#call] a constant name to the file that declares it, or nil; walks the superclasses when `bases` is nil
    # @param keys [Array<Symbol>] the listener keys to collect; with `:expanded`, a concern method's call reads as
    #   what the method declares even when that is nothing, which costs a read of every such call
    # @param listeners [Hash] the listener map each file is walked with; it must carry `mixins` and `methods`
    # @param root [String] the app root
    # @param prefer [String, nil] "model" or "controller": whose concerns directory a shared basename means;
    #   "model" also reads what the app mixes into every model from outside the model files
    # @param source [String, nil] the class's own source, when the caller holds one
    # @param file [String, nil] the class's own file
    # @param bases [Array<Array(String, String)>, nil] [name, file] of each superclass, nearest first, when the caller knows them
    # @param read [#call, nil] (file, source, class name) to the listener walk, for a caller that keeps its own; nil reads it here
    # @param text [#call, nil] a file to its source, for a caller that keeps its own
    # @param cache [Hash, nil] a caller-owned store shared by the run's walks
    # @return [Result]
    def for(class_name, lookup:, keys:, listeners:, root:, prefer: nil, source: nil, file: nil, bases: nil, read: nil, text: nil, cache: nil)
      Walker.new(class_name.to_s, lookup: lookup, keys: keys, listeners: listeners, root: root.to_s, prefer: prefer, source: source, file: file,
                                  bases: bases, read: read, text: text, cache: cache).result
    end

    # A class file's source, read once per run; nil when it is too big or unreadable.
    def source(path)
      RunCache.fetch([ :class_source, path ]) { SafeFile.read(path, max_size: RailsAiContext.configuration.max_file_size) }
    end

    # A walk over a file's records, trimmed to `name`: a class nested in the file declares for itself.
    def own_body(data, name, keys = [])
      others = Array(data[:declared_classes]) - [ name.to_s ]
      owned = (ConcernMembership::OWNED_KEYS | keys).to_h do |key|
        # Callbacks and macros keep their owner: the walks that settle them read it.
        records = ConcernMembership.owned_by(data[key], name, others: others)
        [ key, %i[callbacks macros].include?(key) || !ConcernMembership::OWNED_KEYS.include?(key) ? records : records.map { |record| record.except(:owner) } ]
      end
      data.merge(mixins: ConcernMembership.owned_by(data[:mixins], name, others: others), **owned)
    end

    class Walker
      # The walk only collects: where a declaration lands waits for every class's walk.
      Walk = Struct.new(:own, :collected, :unread, :hidden, :skipped, :rank, :placement)

      def initialize(name, lookup:, keys:, listeners:, root:, prefer:, source:, file:, bases:, read:, text:, cache:)
        @name = name
        @lookup = lookup
        @keys = keys
        @listeners = listeners
        @root = root
        @prefer = prefer
        @source = source
        @file = file
        @given_bases = bases
        given_read = read
        @read = ->(path, given, name) { given_read&.call(path, given, name) || default_read(path, given) }
        @text = text || ClassDeclarations.method(:source)
        @cache = cache || {}
      end

      def result
        chain = links
        calls = singleton_lookup(chain)
        extra = @prefer == "model" ? BaseMixins.models(@root) : []
        mine = walk_class(chain.first, calls, extra: extra, rank: 0)
        walked = walk_bases(chain.drop(1), calls)
        # A method one walk's block calls runs in the class wherever the method is defined, so a walk held
        # back by a call it did not know yet is walked again once every walk is known, until none learns one.
        ConcernMacros::MAX_DEPTH.times do
          known = Set.new(calls.sites_by_name.keys)
          mine_held = mine.skipped.intersect?(known)
          bases_held = walked.compact.any? { |walk| walk.skipped.intersect?(known) }
          break unless mine_held || bases_held

          mine = walk_class(chain.first, calls, extra: extra, rank: 0) if mine_held
          walked = walk_bases(chain.drop(1), calls) if bases_held
        end
        declared = base_declarations(calls, chain)
        expanded = Array(declared.delete(:expanded)).group_by { |call| call[:rank] }
        walks = [ mine, *walked ]
        settled = walks.map { |walk| walk && settle(walk, calls, expanded[walk.rank]) }
        origins = {}.compare_by_identity
        Result.new(declarations(settled, declared, chain, origins), unread(walks, chain), walks.compact.flat_map(&:hidden).uniq, chain, files(walks),
                   calls.defined_names, origins)
      end

      private

      def links
        own = own_body(@read.call(@file, @source, @name), @name)
        bases = @given_bases || derived_bases
        [ Link.new(@name, @file, own), *bases.map { |name, path| Link.new(name, path, base_body(name, path)) } ]
      end

      def own_body(data, name) = ClassDeclarations.own_body(data, name, @keys)

      # Each superclass `lookup` has a file for, nearest first, as Ruby resolves the name the class writes.
      # Every class under a base asks again, so the run keeps each class's answer.
      def derived_bases
        @cache[[ :derived_bases, @name, @file, @source ]] ||= begin
          # A file too big to read is still the base; its body is what goes unread.
          source_of = ->(candidate) { (path = @lookup.call(candidate)) && (@text.call(path) || "") }
          text = @source || (@file && @text.call(@file))
          Introspectors::SuperclassChain.superclasses(@name, text, source_of).map { |base| [ base, @lookup.call(base) ] }
        end
      end

      # A base's walk is cached for the run: every class under it reads it.
      def default_read(path, text)
        return walk_text(path, text) if text

        @cache[[ :class_walk, @listeners, path ]] ||= walk_text(path, @text.call(path))
      end

      def walk_text(path, text)
        walked = text ? Introspectors::SourceIntrospector.walk_source(text, @listeners) : Introspectors::SourceIntrospector.walk(path, @listeners)
        walked[:declared_classes] = Introspectors::DeclaredConstant.declarations(text, all: true).map(&:name) if text
        walked
      end

      # A base too big or unreadable costs its own declarations, not the child's whole entry.
      def base_body(name, path)
        return nil unless readable_source?(path)

        @cache[[ :base_body, @listeners, @keys, name, path ]] ||= own_body(@read.call(path, nil, name), name)
      rescue StandardError => e
        RailsAiContext.debug_fail(e, nil, label: "base class #{name}")
      end

      # Asked for a base file once per class that inherits it, so a run asks the filesystem once.
      def readable_source?(path)
        return false unless path

        RunCache.fetch([ :readable_source, path.to_s ]) do
          File.exist?(path) && File.size(path) <= RailsAiContext.configuration.max_file_size
        rescue SystemCallError
          false
        end
      end

      def walk_class(link, calls, extra: [], rank: 0)
        own = link.own
        found = ConcernMacros.collect(
          @root, own[:mixins] || [],
          keys: @keys, prefer: @prefer, within: link.name,
          cache: @cache, calls: calls, extra: extra, file: link.file, listeners: @listeners, owned: ConcernMembership::OWNED_KEYS | @keys
        )
        placement = found.placement
        included_at = included_at(own, placement)
        every = extra.map(&:name).to_set
        bodies = method_bodies(own)
        mixins = found.mixins.map do |label, macro, defs, in_module|
          line, order = included_at.call(label)
          added, line = in_module || [ ConcernMacros::SingletonLookup.added_in(rank, line, bodies), line ]
          ConcernMacros::SingletonLookup::Mixin.new(label, macro, defs, added, [ line, order ], every.include?(placement.dig(label, 0)))
        end
        calls.add(rank, found.included_calls, found.block_sites, mixins)
        Walk.new(own, found.collected, found.unread, found.hidden, found.skipped, rank, placement)
      end

      # Each base read with its concerns; a base's concern macro that sits in a class method runs
      # for the class that calls it, the child as often as the base.
      def walk_bases(bases, calls)
        bases.each_with_index.map { |link, index| link.own && walk_class(link, calls, rank: index + 1) }
      end

      # Where a concern the walk read joins the class's chain: at the line
      # including it, after the concerns that include brought in before it.
      def included_at(own, placement)
        line_of = Array(own[:mixins]).reverse.to_h { |mixin| [ mixin[:name], mixin[:location].to_i ] }
        lambda do |name|
          top, order = placement[name]
          top ? [ line_of[top].to_i, order.to_i ] : [ 0, 0 ]
        end
      end

      # A walk's declarations where Ruby runs them: one in a method body, the class's own or a
      # module's, once per call running that body; a concern's where its code runs.
      def settle(walk, calls, expanded = nil)
        own, rank = walk.own, walk.rank
        collected = walk.collected.to_h { |key, entries| [ key, entries.flat_map { |entry| place(entry, rank, calls) } ] }
        own = without_expanded_calls(own, Array(collected.delete(:expanded)) + Array(expanded))
        bodies = method_bodies(own)
        @keys.to_h do |key|
          placed = Array(own[key]).flat_map { |entry| (entry.is_a?(Hash) && in_method(entry, bodies)) || [ ranked(entry, rank) ] }
          [ key, placed + Array(collected[key]) ]
        end
      end

      def ranked(entry, rank) = entry.is_a?(Hash) ? entry.merge(rank: rank) : entry

      # Nil outside a method body; none inside one: an instance method's runs on a record, and a
      # class method's body is read again at each call, with that call's arguments.
      def in_method(entry, bodies)
        line = entry[:location]
        method = line && ConcernMacros.enclosing(bodies, line)&.last
        [] unless method.nil? || declaration_itself?(entry, method[:name], method[:location])
      end

      # A `def self.default_scope` is the declaration itself, not a body holding one.
      def declaration_itself?(entry, name, line) = entry[:location] == line && entry[:name].to_s == name.to_s

      def place(entry, rank, calls)
        return [ entry ] unless entry.is_a?(Hash)

        site = entry[:site]
        origin = Origin.new(calls.body_call?(site), calls.block_owner(site), nil, rank.positive?) if site
        placed = calls.mixed_in(entry, rank)
        # A hook's call of the module's own method runs that method where the hook runs.
        placed = calls.mixed_in(entry.except(:site, :definer).merge(hook: true), rank) if placed.empty? && site && calls.hook_call?(site)
        origin ? placed.map { |found| found.merge(ORIGIN => origin) } : placed
      end

      def method_bodies(own)
        Array(own[:methods]).filter_map { |m| [ m[:location]..m[:end_location], m ] if m[:location] && m[:end_location] }
      end

      # A `validates_translation :title` call the listener read as a declaration of its own is
      # what the method declares, now read from its body.
      def without_expanded_calls(own, expanded)
        return own if expanded.empty?

        sites = expanded.to_set { |call| [ call[:method], call[:line] ] }
        read = ->(entry) { entry.is_a?(Hash) && sites.include?([ (entry[:kind] || entry[:macro]).to_s, entry[:location] ]) }
        own.merge(@keys.to_h { |key| [ key, Array(own[key]).reject(&read) ] })
      end

      # What the class methods the chain's files and the app's base bodies give the class declare, at each
      # call reaching them, with the calls read that way (`:expanded`) by the rank they stand at.
      def base_declarations(calls, chain)
        found = Hash.new { |hash, key| hash[key] = [] }
        (declaring_defs(chain) + base_defs(chain)).each do |node, definition|
          next unless node.is_a?(Prism::DefNode)

          sites = Array(calls.sites_by_name[definition.name]).compact
          # A base body's def (`at` set) lives in an initializer, not in a class file.
          file = definition.owner.is_a?(Integer) && !definition.at ? chain[definition.owner]&.file : nil
          expansion, = ConcernMacros.expand_calls(node, sites, [ *@keys, :expanded ], @listeners) do |entry, site|
            origin = Origin.new(calls.body_call?(site), calls.block_owner(site), file, definition.owner != 0)
            calls.placed(entry, definition.key, [ entry[:location] ], site).map { |found| found.merge(ORIGIN => origin) }
          end
          expansion.each { |key, entries| found[key].concat(entries) }
        end
        found.to_h
      end

      # Each key's entries in the order Ruby runs them: the outermost class first, each class's
      # own body and the concerns it includes by where they run.
      def declarations(settled, declared, chain, origins)
        (@keys - [ :expanded ]).to_h do |key|
          entries = [ *settled.compact.flat_map { |data| Array(data[key]) }, *Array(declared[key]) ]
          ordered = entries.each_with_index.sort_by do |entry, index|
            next [ 0, [], index ] unless entry.is_a?(Hash)

            [ -entry[:rank].to_i, entry[:chain_at] || [ entry[:location].to_i, -1 ], index ]
          end
          found = ordered.map do |entry, _|
            next entry unless entry.is_a?(Hash)

            base = entry[:rank].to_i.positive? && chain[entry[:rank].to_i]
            bare = entry.except(*CHAIN_KEYS, ORIGIN)
            bare = bare.merge(declared_in: base.name) if base
            origins[bare] = entry[ORIGIN] if entry[ORIGIN]
            bare
          end
          [ key, EACH_RUN.include?(key) ? found : found.uniq ]
        end
      end

      def unread(walks, chain)
        concerns = walks.compact.flat_map(&:unread).uniq.map { |name| Unread.new(name, name.include?("#") ? :method : :concern) }
        bases = chain.drop(1).reject(&:own).map { |link| Unread.new(link.name, :base) }
        concerns + bases
      end

      def files(walks)
        walks.compact.each_with_object({}) { |walk, found| walk.placement.each { |label, (_, _, path)| found[label] ||= path if path } }
      end

      # The class files' side of the lookup, read only when a concern asks: their class-body
      # calls and their own class methods, `alias_method` in `class << self` included.
      def singleton_lookup(chain)
        reader = lambda do
          ranks = {}
          defs = []
          found = chain.each_with_index.each_with_object({}) do |(link, rank), into|
            next if rank.positive? && !link.own

            tree = class_tree(link, rank)
            next unless tree

            scope = class_scope(tree, link.name)
            own = per_tree(tree, [ :calls, link.name ]) do
              scope.select { |node| node.is_a?(Prism::CallNode) && (node.receiver.nil? || node.receiver.is_a?(Prism::SelfNode)) }.group_by { |node| node.name.to_s }
            end
            own.each_value { |sites| sites.each { |site| ranks[site.__id__] = rank } }
            defs.concat(per_tree(tree, [ :defs, link.name, rank ]) { ConcernMacros::SingletonLookup.own_defs(scope, rank) })
            ConcernMacros::Run.merge_calls(into, own)
          rescue StandardError, ScriptError => e
            # A file the walk cannot read calls nothing it can see.
            RailsAiContext.debug_fail(e, nil, label: "class calls of #{link.file}")
          end
          defs.concat(base_defs(chain).map(&:last))
          ConcernMacros::SingletonLookup::Read.new(found, ranks, defs, chain.size)
        end
        ConcernMacros::SingletonLookup.new(reader)
      end

      def class_tree(link, rank)
        text = rank.zero? && @source ? @source : link.file && @text.call(link.file)
        return AstCache.parse_string(text).value if text

        link.file && readable_source?(link.file) ? AstCache.parse(link.file).value : nil
      end

      # [node, definition] for each class method a class on the chain defines whose body declares something.
      def declaring_defs(chain)
        chain.each_with_index.flat_map do |link, rank|
          entries = link.own ? @keys.flat_map { |key| Array(link.own[key]).grep(Hash).select { |entry| entry[:location] } } : []
          next [] if entries.empty?

          tree = class_tree(link, rank)
          next [] unless tree

          per_tree(tree, [ :declaring, link.name, rank, @keys, @listeners ]) do
            ConcernMacros::SingletonLookup.member_defs(class_scope(tree, link.name), rank).select do |node, _|
              node.is_a?(Prism::DefNode) && entries.any? { |entry| declared_inside?(entry, node) }
            end
          end
        end
      end

      def declared_inside?(entry, node)
        (node.location.start_line..node.location.end_line).cover?(entry[:location]) && !declaration_itself?(entry, node.name, node.location.start_line)
      end

      # [node, definition] for each class method a base body outside app/models gives the class: one
      # reopening ApplicationRecord at that base's rank, the rest at the outermost; each after its base's file.
      def base_defs(chain)
        return [] unless @prefer == "model"

        application = chain.index { |link| link.name == "ApplicationRecord" }
        BaseMixins.bodies(@root).flat_map do |body|
          rank = body.target == "ApplicationRecord" ? application : chain.size
          next [] unless rank

          ConcernMacros::SingletonLookup.member_defs(body.statements, rank, body.order)
        end
      end

      # The nodes the class body runs with the class as self: the node opening a
      # method, nested class or `class << x` is there, its body is not.
      # Every class under a base reads the base's body, so a run reads it once.
      def class_scope(tree, class_name)
        per_tree(tree, [ :scope, class_name.to_s ]) { scope_of(tree, class_name) }
      end

      def per_tree(tree, key, &read) = RunCache.fetch_for(:class_trees, tree, key, &read)

      def scope_of(tree, class_name)
        bodies = Introspectors::DeclaredConstant.class_bodies(tree, class_name)
        return bodies.flat_map { |body| Introspectors::AstWalk.scope(body) } if bodies.any?

        short = class_name.to_s.split("::").last.to_s
        roots = Introspectors::AstWalk.each(tree).select { |node| node.is_a?(Prism::ClassNode) && node.constant_path.slice.split("::").last.casecmp?(short) }
        roots.empty? ? Introspectors::AstWalk.scope(tree) : roots.flat_map { |root| Introspectors::AstWalk.scope(root.body) }
      end
    end
  end
end
