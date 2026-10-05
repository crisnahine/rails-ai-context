# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    # One reader for the filter macros a controller body declares.
    #
    # The listing reads them to build each entry, and the chain walk reads them
    # for a base class the listing leaves out. Two readers would answer one
    # question two ways, which is what happened while the walk had none: a
    # `before_action` in ApplicationController reached the generated overview
    # through its own file read and reached no tool at all.
    module ControllerFilters
      MACROS = %i[
        before_action after_action around_action
        prepend_before_action append_before_action
        prepend_after_action prepend_around_action append_after_action append_around_action
        skip_before_action skip_after_action skip_around_action skip_forgery_protection
        http_basic_authenticate_with
      ].freeze

      # The block filter http_authentication.rb adds, named for the macro: its keywords are credentials.
      BASIC_AUTH = { macro: :before_action, args: [ :http_basic_authenticate_with ], proc_lines: [] }.freeze

      # actionpack's request_forgery_protection.rb defines it as this skip.
      FORGERY_SKIP = { macro: :skip_before_action, args: [ :verify_authenticity_token ] }.freeze

      LISTENERS = {
        filters: -> { Listeners::GenericMacroListener.new(*MACROS) },
        mixins: Listeners::MixinsListener,
        # A macro inside a `def` runs when the method is called, so ConcernMacros holds it back by these.
        methods: Listeners::MethodsListener
      }.freeze

      # How deep the walk follows a class's app-defined bases for a class method its body calls.
      MAX_BASES = 8

      # The class body's receiverless calls by name, read only once a mixin's class method declares a filter.
      CallSites = Struct.new(:source) do
        def sites_by_name
          @sites_by_name ||= begin
            tree = AstCache.parse_string(source)&.value
            tree ? SourceIntrospector.calls_outside_methods(tree, self_receiver: true) : {}
          end
        end
      end

      module_function

      # @param source [String] one controller's Ruby source
      # @return [Array<Hash>] { name:, kind:, skipped:/declared:, only:, except:, if:, unless: }
      def from_source(source)
        class_level(walk(source)).flat_map { |entry| record(entry) }
      rescue => e
        RailsAiContext.debug_fail(e, [], label: "controller filter read")
      end

      # The class body's filters and every included concern's, in Rails' order: an `include`
      # adds its concern's filters where it stands, each named in `from_concern`. A class
      # method the body calls (`allow_unauthenticated_access`) declares what its body does,
      # with the call's options, where the call stands, wherever on the chain it is defined.
      #
      # @param within [String] the class's constant, for a namespace-relative `include`
      # @param cache [Hash, nil] see ConcernMacros.collect
      # @return [Array(Array<Hash>, Array<String>)] the filters, and the
      #   included modules whose file could not be read
      def with_concerns(source, root:, within:, cache: nil)
        walked = SourceIntrospector.walk_source(source, LISTENERS)
        mixins = Array(walked[:mixins])
        calls = CallSites.new(source)
        # One walk, so a concern two includes reach is added once, as Ruby does.
        collected, unread, _hidden, _calls, placement = ConcernMacros.collect(
          root, mixins, keys: [ :filters ], prefer: "controller", within: within, cache: cache, calls: calls, listeners: LISTENERS
        )
        line_of = mixins.reverse.to_h { |mixin| [ mixin[:name], mixin[:location].to_i ] }
        own_defs = singleton_expansions(source, walked, calls, Set.new)
        defined = own_defs.map { |entry| entry[:site].name }.to_set
        # A concern method the body calls declares for the body; one a concern's own block calls stays the concern's.
        by_body, by_concern = Array(collected[:filters]).partition { |entry| body_call?(entry, calls) }
        called = by_body.reject { |entry| defined.include?(entry[:site].name) }
        defined.merge(called.map { |entry| entry[:site].name })
        inherited = base_expansions(source, within, root, calls, defined, cache)
        placed = class_level(walked).map { |entry| [ entry[:location].to_i, -1, entry ] } +
                 (own_defs + called + inherited).map { |entry| [ entry[:site].location.start_line, -1, entry.except(:site, :definer, :from_concern) ] } +
                 by_concern.map do |entry|
                   top, order = placement[entry[:from_concern]]
                   [ line_of[top].to_i, order.to_i, entry ]
                 end
        entries = placed.each_with_index.sort_by { |(line, order, _), index| [ line, order, index ] }.map { |(_, _, entry), _| entry }
        filters = entries.flat_map do |entry|
          record(entry).map { |filter| entry[:from_concern] ? filter.merge(from_concern: entry[:from_concern]) : filter }
        end
        [ filters, unread ]
      rescue => e
        RailsAiContext.debug_fail(e, [ [], [] ], label: "controller filter read with concerns")
      end

      def walk(source)
        SourceIntrospector.walk_source(source, LISTENERS.slice(:filters, :methods))
      end

      # The filters the class body declares itself: one inside a `def` runs only when the method is called.
      def class_level(walked)
        SourceIntrospector.outside_defs(walked[:filters], walked[:methods])
      end

      # What the class methods `source` defines itself (`def self.x`, `class << self`) declare at
      # each call `calls` makes of one, skipping the names in `taken`.
      def singleton_expansions(source, walked, calls, taken)
        declaring = Array(walked[:methods]).select { |m| m[:scope] == :class && !taken.include?(m[:name].to_s) }
        declaring = declaring.select { |m| declares_filters?(walked, m) }
        return [] if declaring.empty?

        sites = calls.sites_by_name
        declaring = declaring.select { |m| sites.key?(m[:name].to_s) }
        return [] if declaring.empty?

        tree = AstCache.parse_string(source).value
        declaring.flat_map do |method|
          definition = AstWalk.each(tree).find do |node|
            node.is_a?(Prism::DefNode) && node.name.to_s == method[:name].to_s && node.location.start_line == method[:location]
          end
          next [] unless definition

          found, = ConcernMacros.expand_calls(definition, sites.fetch(method[:name].to_s), [ :filters ], LISTENERS) do |entry, call|
            [ entry.merge(site: call) ]
          end
          Array(found[:filters])
        end
      end

      # Whether the method's body holds a filter macro the walk saw.
      def declares_filters?(walked, method)
        range = method[:offset].to_i...method[:end_offset].to_i
        Array(walked[:filters]).any? { |entry| range.cover?(entry[:offset].to_i) }
      end

      # What a class method an app-defined base or one of its concerns defines declares at
      # each call this class makes of it, nearest base first.
      def base_expansions(source, within, root, calls, taken, cache)
        found = []
        seen = Set.new
        name, scope = superclass_of(source, within)
        MAX_BASES.times do
          break unless name && root

          label, base, path = base_source(root, name, scope)
          break unless base && seen.add?(path)

          # Every controller reaches ApplicationController, so its walk is read once per run.
          key = [ :controller_base_walk, path, base ]
          walked = cache ? (cache[key] ||= SourceIntrospector.walk_source(base, LISTENERS)) : RunCache.fetch(key) { SourceIntrospector.walk_source(base, LISTENERS) }
          own = singleton_expansions(base, walked, calls, taken)
          taken.merge(own.map { |entry| entry[:site].name })
          collected, = ConcernMacros.collect(root, Array(walked[:mixins]), keys: [ :filters ], prefer: "controller",
                                             within: label, cache: cache, calls: calls, listeners: LISTENERS)
          mixed = Array(collected[:filters]).select { |entry| body_call?(entry, calls) && !taken.include?(entry[:site].name) }
          taken.merge(mixed.map { |entry| entry[:site].name })
          found.concat(own + mixed)
          name, scope = superclass_of(base, label)
        end
        found
      end

      # Whether the entry is what a method declares at a call the class body makes.
      def body_call?(entry, calls)
        site = entry[:site]
        site && Array(calls.sites_by_name[site.name.to_s]).any? { |call| call.equal?(site) }
      end

      # [superclass, the namespace it is written in] of the class `within` names in `source`.
      def superclass_of(source, within)
        declarations = DeclaredConstant.declarations(source)
        written = (declarations.find { |d| d.name == within.to_s } || declarations.find(&:superclass))&.superclass
        return nil unless written

        written.start_with?("::") ? [ written.delete_prefix("::"), nil ] : [ written, within ]
      end

      # [constant, source, realpath] of the app controller base the name resolves to, as Ruby looks it up.
      def base_source(root, name, scope)
        prefix = "#{root.to_s.chomp("/")}/"
        dirs = PathResolver.controller_dirs(root.to_s).select { |dir| dir.start_with?(prefix) }
        ConcernPaths.candidate_names(name, scope).each do |candidate|
          dirs.each do |dir|
            relative = File.join(dir.delete_prefix(prefix), "#{candidate.underscore}.rb")
            source, resolution = SafePath.read(relative, under: root.to_s)
            return [ candidate, source, resolution.realpath ] if source
          end
        end
        nil
      end

      # One filter per callback the call adds: each name, then each block or lambda, named by its line.
      def record(entry)
        entry = entry.merge(FORGERY_SKIP) if entry[:macro] == :skip_forgery_protection
        entry = entry.merge(BASIC_AUTH) if entry[:macro] == :http_basic_authenticate_with
        macro = entry[:macro].to_s
        skipped = macro.start_with?("skip_")
        names = positional_names(entry)
        names += Array(entry[:proc_lines]).map { |line| "block (line #{line})" } unless skipped
        # An excluded name is framework noise only while it runs. A skip of it
        # is the app's own decision, which the per-action answer reports.
        names -= RailsAiContext.configuration.excluded_filters.map(&:to_s) unless skipped
        return [] if names.empty?

        kind = macro.sub(/_action\z/, "").sub(/\A(?:prepend|append|skip)_/, "")
        # A skip states the opposite of what the plain kind says, so it has to
        # survive the fold into `before`/`after`/`around`. A declaration marks
        # the body that made it, so an ancestor's skip of the same name does
        # not reach it.
        mark = skipped ? { skipped: true } : { declared: true }
        tail = constraints(entry)
        names.map { |name| { name: name, kind: kind, **mark, **tail } }
      end

      # Each name the call gives, in order. A class (`before_action Gatekeeper`) is named as
      # written, an instance (`around_action TimingFilter.new`) by its class, as the booted tier names both.
      def positional_names(entry)
        literals = Array(entry[:args]).map(&:to_s)
        return literals if Array(entry[:values]).empty?

        entry[:values].filter_map do |value|
          text = value.to_s
          if value.is_a?(Symbol) || literals.include?(text) then text
          elsif (const = text[/\A(?:::)?([A-Z]\w*(?:::[A-Z]\w*)*)\.new\b/, 1]) then "#{const} (object)"
          elsif text.match?(/\A(?:::)?[A-Z]\w*(?:::[A-Z]\w*)*\z/) then text.delete_prefix("::")
          end
        end
      end

      def constraints(entry)
        opts = entry[:options] || {}
        sources = entry[:option_values] || {}
        out = {}
        only = normalize(opts[:only])
        except = normalize(opts[:except])
        out[:only] = only if only&.any?
        out[:except] = except if except&.any?
        out[:unless] = condition_text(opts[:unless], sources[:unless]) if opts[:unless]
        if opts[:if]
          # When the condition compares action_name the AST can say which
          # action it names; that is worth more than the line itself.
          actions = action_condition(entry[:option_nodes]&.[](:if))
          out[:if] = actions ? %(action_name == "#{actions.first}") : condition_text(opts[:if], sources[:if])
        end
        out
      end

      # A lambda has no literal value, so the line the file holds is what
      # there is to print. A symbol stays one, so the renderer can spell it.
      def condition_text(value, source)
        value.to_s == RailsAiContext::Confidence::INFERRED ? source.to_s : value
      end

      def normalize(value)
        case value
        when Array then value.map(&:to_s)
        when Symbol then [ value.to_s ]
        when String then [ value ]
        when nil then nil
        else [ value.to_s ]
        end
      end

      def action_condition(node)
        node = lambda_body(node)
        return nil unless node.is_a?(Prism::CallNode) && node.name == :==

        receiver = node.receiver
        return nil unless receiver.is_a?(Prism::CallNode) && receiver.name == :action_name && receiver.receiver.nil?

        case node.arguments&.arguments&.first
        when Prism::StringNode then [ node.arguments.arguments.first.unescaped ]
        when Prism::SymbolNode then [ node.arguments.arguments.first.unescaped ]
        end
      end

      def lambda_body(node)
        return node unless node.is_a?(Prism::LambdaNode) || node.is_a?(Prism::BlockNode)

        statements = node.body
        return nil unless statements.is_a?(Prism::StatementsNode) && statements.body.size == 1

        statements.body.first
      end

      private_class_method :walk, :class_level, :singleton_expansions, :declares_filters?, :base_expansions,
                           :superclass_of, :base_source, :body_call?, :record, :positional_names, :constraints, :condition_text, :normalize, :action_condition, :lambda_body
    end
  end
end
