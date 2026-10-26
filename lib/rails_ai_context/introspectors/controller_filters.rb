# frozen_string_literal: true

require "set"

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
      # Macros a gem defines to add one callback, with the gem: cancancan's controller_additions.rb
      # (load and authorize blocks, check_authorization after) and acts_as_tenant's
      # controller extensions, which add a named before_action.
      GEM_FILTERS = {
        load_and_authorize_resource: [ :before_action, :load_and_authorize_resource, "cancancan" ],
        load_resource: [ :before_action, :load_resource, "cancancan" ],
        authorize_resource: [ :before_action, :authorize_resource, "cancancan" ],
        check_authorization: [ :after_action, :check_authorization, "cancancan" ],
        skip_authorization_check: [ :before_action, :skip_authorization_check, "cancancan" ],
        set_current_tenant_by_subdomain: [ :before_action, :find_tenant_by_subdomain, "acts_as_tenant" ],
        set_current_tenant_by_subdomain_or_domain: [ :before_action, :find_tenant_by_subdomain_or_domain, "acts_as_tenant" ]
      }.freeze

      # cancancan's controller_resource.rb adds these with prepend_before_action when passed `prepend: true`.
      GEM_PREPENDABLE = %i[load_and_authorize_resource load_resource authorize_resource].freeze

      MACROS = (%i[
        before_action after_action around_action
        prepend_before_action append_before_action
        prepend_after_action prepend_around_action append_after_action append_around_action
        skip_before_action skip_after_action skip_around_action skip_forgery_protection
        http_basic_authenticate_with
      ] + GEM_FILTERS.keys).freeze

      # The block filter http_authentication.rb adds, named for the macro: its keywords are credentials.
      BASIC_AUTH = { macro: :before_action, args: [ :http_basic_authenticate_with ], callbacks: nil, proc_lines: [] }.freeze

      # actionpack's request_forgery_protection.rb defines it as this skip.
      FORGERY_SKIP = { macro: :skip_before_action, args: [ :verify_authenticity_token ] }.freeze

      LISTENERS = {
        filters: -> { Listeners::FilterMacroListener.new(*MACROS) },
        nested: Listeners::NestedConstantsListener,
        mixins: Listeners::MixinsListener,
        # A macro inside a `def` runs when the method is called, so ConcernMacros holds it back by these.
        methods: Listeners::MethodsListener
      }.freeze

      # The chain walk reads the class-level settings ControllerSettings reports with the filters.
      CHAIN_LISTENERS = LISTENERS.merge(settings_calls: ControllerSettings::LISTENERS[:settings_calls]).freeze

      module_function

      # @param source [String] one controller's Ruby source
      # @return [Array<Hash>] { name:, kind:, skipped:/declared:, only:, except:, if:, unless: }
      def from_source(source, root: nil)
        walked = walk(source)
        SourceIntrospector.class_level(walked[:filters], walked).flat_map { |entry| record(entry, root) }
      rescue => e
        RailsAiContext.debug_fail(e, [], label: "controller filter read")
      end

      # The class body's filters and every included concern's, in Rails' order, each concern's named in
      # `from_concern`; a parent's own filters come from their entries.
      #
      # @param within [String] the class's constant, for a namespace-relative `include`
      # @param cache [Hash, nil] see ConcernMacros.collect
      # @return [Array(Array<Hash>, Array<String>)] the filters, and the
      #   included modules whose file could not be read
      def with_concerns(source, root:, within:, cache: nil)
        found = declarations(source, root: root, within: within, cache: cache)
        own_file = nil
        # A class method the chain defines answers the call, not the gem's macro of that name.
        entries = Array(found.declarations[:filters]).reject do |entry|
          entry[:declared_in] || (GEM_FILTERS.key?(entry[:macro]) && found.class_methods.include?(entry[:macro].to_s))
        end
        filters = entries.flat_map do |entry|
          origin = found.origin(entry)
          # A concern method the body calls declares for the body; a base's method a concern's block calls, for that concern.
          concern = if origin&.called then nil
          elsif origin&.inherited then origin.via || entry[:from_concern]
          else entry[:from_concern] || origin&.via
          end
          path = entry[:from_concern] ? found.files[entry[:from_concern]] : origin&.file
          own_file ||= [ base_source(root, within, nil)&.last ] if path
          record(with_file(entry, path, root, own_file&.first), root).map { |filter| concern ? filter.merge(from_concern: concern) : filter }
        end
        unread = found.unread.reject { |entry| entry.reason == :base }.map(&:name)
        found.chain.each { |link| unread |= outside_modules(Array(link.own&.dig(:mixins)), root, link.name) }
        [ filters, unread ]
      rescue => e
        RailsAiContext.debug_fail(e, [ [], [] ], label: "controller filter read with concerns")
      end

      # The filters and the settings calls a controller's chain declares, read in one walk for both.
      def declarations(source, root:, within:, cache: nil)
        RunCache.fetch([ :controller_declarations, root.to_s, within.to_s, source ]) do
          # A tool reading each route's base controller walks the same concerns for every route.
          cache ||= RunCache.fetch([ :controller_concern_walks ]) { {} }
          ClassDeclarations.for(within, lookup: ->(name) { base_file(root, name) }, keys: %i[filters settings_calls], listeners: CHAIN_LISTENERS,
                                        root: root.to_s, prefer: "controller", source: source, cache: cache, bases: bases(root, within, source))
        end
      end

      # [name, file] of each app controller the class inherits from, nearest first, through a gem controller whose
      # parent the app's initializers name.
      def bases(root, within, source)
        source_of = ->(name) { (file = base_file(root, name)) && (ClassDeclarations.source(file) || "") }
        onward = ->(name) { ActionFilters.gem_controller_base(name, root) }
        SuperclassChain.superclasses(within.to_s, source, source_of, onward: onward).map { |name| [ name, base_file(root, name) ] }
      end

      # actionpack and actionview declare callbacks only in class macros (allow_browser), so including one of theirs adds none.
      SILENT_FRAMEWORK = "ActionView::"

      # The walk skips a module excluded_concerns names, but a filter one adds
      # (ActiveStorage::SetBlob's set_blob) still runs.
      def outside_modules(mixins, root, within)
        mixins.filter_map do |mixin|
          name = mixin[:name].to_s
          next unless mixin[:ancestor] && !mixin[:inline]
          next unless ConcernMembership.candidate?(name) && ConcernMembership.excluded?(name) && !name.start_with?(SILENT_FRAMEWORK)

          name unless ConcernPaths.module_source(root.to_s, name, prefer: "controller", within: within, line: mixin[:location])
        end
      end

      def walk(source)
        SourceIntrospector.walk_source(source, LISTENERS.slice(:filters, :methods, :nested))
      end

      # The file of the app controller the name means, for the chain walk; nil for one outside the app.
      def base_file(root, name)
        RunCache.fetch([ :controller_base_source, root.to_s, name ]) { constant_source(root, name) }&.[](2)
      end

      # [constant, source, realpath, app-relative path] of the app controller base the name resolves to, as Ruby looks it up.
      def base_source(root, name, scope)
        RunCache.fetch([ :controller_base, root.to_s, name, scope ]) do
          sources = {}
          exists = ->(candidate) { sources[candidate] = RunCache.fetch([ :controller_base_source, root.to_s, candidate ]) { constant_source(root, candidate) } }
          source_of = ->(candidate) { exists.call(candidate)&.[](1) }
          found = DeclaredConstant.lookup(name, nesting: Array(scope), exists: exists, ancestors_of: SuperclassChain.ancestors_of(source_of))
          found && sources[found]
        end
      end

      def constant_source(root, candidate)
        prefix = "#{root.to_s.chomp("/")}/"
        PathResolver.controller_dirs(root.to_s).each do |dir|
          file = dir.start_with?(prefix) && PathResolver.constant_path(dir, candidate, declared: true)
          next unless file

          relative = file.delete_prefix(prefix)
          source, resolution = SafePath.read(relative, under: root.to_s)
          next unless source

          return [ candidate, source, resolution.realpath, relative ]
        end
        nil
      end

      # The file a block the entry declares sits in, when that is not the class's own.
      def with_file(entry, path, root, own = nil)
        file = path && PortablePath.relativize(path, root.to_s)
        file && file != own ? entry.merge(file: file) : entry
      end

      BARE_BLOCK = /\A(?:block|lambda) \(line \d+\)\z/

      # A block outside the class's own file names that file: two blocks on one line number are two callbacks.
      # A lambda says so, as Proc#lambda? tells it from the block it may share a line with.
      def block_name(line, file = nil, lambda: false)
        "#{lambda ? 'lambda' : 'block'} (line #{line}#{" of #{file}" if file})"
      end

      # A class body's filters as a class elsewhere names them: its own blocks by the file it is in.
      def in_file(filters, file)
        return filters unless file

        filters.map { |filter| filter[:name].to_s.match?(BARE_BLOCK) ? filter.merge(name: "#{filter[:name].to_s.chomp(")")} of #{file})") : filter }
      end

      def block?(name)
        name.to_s.start_with?("block (line ", "lambda (line ")
      end

      # One filter per callback the call adds, a block or lambda named by its line.
      def record(entry, root = nil)
        entry = entry.merge(FORGERY_SKIP) if entry[:macro] == :skip_forgery_protection
        entry = entry.merge(BASIC_AUTH) if entry[:macro] == :http_basic_authenticate_with
        if (macro, name, gem = GEM_FILTERS[entry[:macro]])
          return [] unless bundled?(gem, root)

          macro = :prepend_before_action if GEM_PREPENDABLE.include?(entry[:macro]) && (entry[:options] || {})[:prepend] == true
          entry = entry.merge(macro: macro, args: [ name ], callbacks: nil, proc_lines: [])
        end
        macro = entry[:macro].to_s
        skipped = macro.start_with?("skip_")
        names = positional_names(entry, skipped ? [] : Array(entry[:proc_lines]))
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
        # Rails unshifts each name onto the chain the class inherited, for a prepend_* macro and for
        # prepend: true on any other; ActionFilters places it.
        mark[:prepend] = true if macro.start_with?("prepend_") || (!skipped && (entry[:options] || {})[:prepend] == true)
        tail = constraints(entry)
        names.map { |name| { name: name, kind: kind, **mark, **tail } }
      end

      # Whether the app's lockfile resolves the gem; an app whose gems are unknown is given the benefit.
      def bundled?(gem, root)
        return true unless root

        lock = GemLock.for(root)
        lock.missing? || lock.present?(gem)
      end

      # Each callback the call gives, in the order Rails adds them: positional arguments as written,
      # the block last, each named by FilterMacroListener.
      def positional_names(entry, lines)
        callbacks = entry[:callbacks]
        lines = lines.dup
        named = Array(callbacks).filter_map do |kind, name|
          case kind
          when :name then name
          when :block, :lambda then block_name(lines.shift, entry[:file], lambda: kind == :lambda)
          when :object then "#{name} (object)"
          when :unread then "#{name} (not read)"
          end
        end
        named = Array(entry[:args]).map(&:to_s) if callbacks.blank?
        named + lines.map { |line| block_name(line, entry[:file]) }
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
        out[:condition] = entry[:condition] if entry[:condition]
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

      private_class_method :walk, :bases, :outside_modules, :base_file, :base_source, :constant_source, :with_file, :record, :bundled?, :positional_names, :constraints, :condition_text, :normalize, :action_condition, :lambda_body
    end
  end
end
