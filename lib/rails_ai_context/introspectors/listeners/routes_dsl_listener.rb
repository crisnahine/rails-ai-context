# frozen_string_literal: true

require "active_support/core_ext/string/inflections"

module RailsAiContext
  module Introspectors
    module Listeners
      # Static walker for config/routes.rb. Resolves the routing DSL's block
      # nesting (namespace/scope/resources/member/collection) into flat route
      # records so "does this route exist and which controller serves it" can
      # be answered without booting the app. Constructs whose routes depend on
      # runtime state (devise_for, draw, computed names) are recorded as
      # :dynamic markers rather than guessed at. Leading-slash paths anchor
      # at the accumulated prefix.
      class RoutesDslListener < BaseListener
        include BranchConditions

        VERB_METHODS = %i[get post put patch delete options].freeze
        PLURAL_ACTIONS = %i[index create new edit show update destroy].freeze
        # Rails' drawing order: the first route asking for a name gets it.
        SINGULAR_ACTIONS = %i[new edit show update destroy create].freeze
        RESTFUL_ACTIONS = %w[index show new create edit update destroy].freeze
        DYNAMIC_MACROS = %i[devise_for draw].freeze
        # `direct` and `resolve` define URL helpers and draw no route.
        URL_HELPER_MACROS = %i[direct resolve].freeze
        # Calls that draw routes; an unknown block that makes none of them configures a gem macro.
        ROUTE_METHODS = (VERB_METHODS + %i[match namespace scope resources resource member collection new shallow
                                           concern concerns with_options controller mount root draw devise_for]).freeze
        # Statement-level calls that draw nothing into the table.
        NON_ROUTING = %i[require require_relative puts p pp print warn raise default_url_options extend include].freeze

        # `scope` is the frames a `draw` of this file sits in, as its record carries them.
        # `route_set` answers { prefix:, name_prefix: } for an app class that draws routes.
        # `names` is the set of route names taken so far, shared by every file of one table.
        # ponytail: an engine's namespace is its first segment; read isolate_namespace if one differs.
        def self.engine_namespace(engine)
          engine.split("::").first.underscore
        end

        def initialize(scope: [], route_set: nil, names: Set.new)
          super()
          @stack = scope.map { |frame| frame.merge(node: nil) }
          @route_set = route_set
          @concern_blocks = {}
          @replaying = []
          # Rails leaves a route unnamed when another route already took its name.
          @taken_names = names
          # The calls that stand as statements of a route body, as opposed to
          # arguments or lambda bodies: only those can draw a route.
          @statements = {}.compare_by_identity
          @global_path_names = {}
          @methods = {}
          @routing_calls = 0
        end

        def on_program_node_enter(node)
          register_statements(node.statements)
        end

        # Ruby runs a method's body where it is called, so it is replayed there.
        def on_def_node_enter(node)
          @methods[node.name] = node if @statements.key?(node) && node.receiver.nil?
          push_frame(node, suppress: true)
        end

        def on_def_node_leave(node)
          @stack.pop if @stack.last && @stack.last[:node].equal?(node)
        end

        def on_call_node_enter(node)
          statement = @statements.key?(node)
          register_statements(node.block.body) if statement && route_body?(node)
          return enter_engine_draw(node) if engine_draw?(node)
          return enter_route_set(node) if route_set_draw?(node)
          # `ActiveAdmin.routes(self)` hands the mapper to code this walk cannot see.
          return emit_dynamic(node) if node.receiver && statement && node.arguments&.arguments&.any?(Prism::SelfNode)
          return enter_late_table_change(node) if late_table_change?(node, statement)
          return push_frame(node, prepend: true) if node.receiver && node.name == :prepend && statement && route_body?(node)
          return unless node.receiver.nil?

          @routing_calls += 1 if ROUTE_METHODS.include?(node.name)
          case node.name
          when :namespace then enter_namespace(node)
          when :scope then enter_scope(node)
          when :resources then handle_resources(node, singular: false)
          when :resource then handle_resources(node, singular: true)
          when :member then enter_member_collection(node, :member)
          when :collection then enter_member_collection(node, :collection)
          when :new then enter_member_collection(node, :new)
          when :shallow then push_frame(node, shallow: true) if node.block
          when :concern then define_concern(node)
          when :concerns then apply_concerns(node)
          when :with_options then enter_with_options(node)
          when :controller then enter_controller(node)
          when :resources_path_names then @global_path_names.merge!(path_names_option(path_names: own_options(node)))
          when *URL_HELPER_MACROS then push_frame(node, suppress: true) if node.block
          when :mount then emit_dynamic(node) unless mounted_app?(node)
          when :root then emit_root(node)
          when *VERB_METHODS, :match then emit_verb_route(node) unless rack_app_target?(node)
          when *DYNAMIC_MACROS then emit_dynamic(node) unless rack_app_target?(node)
          else
            if statement && node.block
              # An empty block (a commented-out `constraints do`) configures nothing.
              push_frame(node, unknown_block: @routing_calls, pending: []) if node.block.body
            elsif statement && !NON_ROUTING.include?(node.name)
              call_method_or_count(node)
            end
          end
        end

        # A block call this walk does not know is read through when it holds
        # routes (`constraints`, `devise_scope`), and the unknown calls in it
        # count one each; one that holds none is a gem macro configured by its
        # block (`use_doorkeeper do controllers ... end`) and counts once.
        def on_call_node_leave(node)
          return unless @stack.last && @stack.last[:node].equal?(node)

          frame = @stack.pop
          return unless frame[:unknown_block]
          return frame[:pending].each { |call| emit_dynamic(call) } if frame[:unknown_block] != @routing_calls

          outer = open_unknown_block
          outer ? outer[:pending] << node : emit_dynamic(node)
        end

        private

        # A receiver's block (`Sidekiq::Web.use ... do`) is plain Ruby; only a draw holds routes.
        def route_body?(node)
          node.block.is_a?(Prism::BlockNode) && (node.receiver.nil? || %i[draw append prepend].include?(node.name))
        end

        def call_method_or_count(node)
          definition = @methods[node.name]
          key = "def #{node.name}"
          # A gem macro's configuration until its block turns out to draw routes.
          outer = open_unknown_block if definition.nil?
          return (outer[:pending] << node unless suppressed?) if outer
          return emit_dynamic(node) if definition.nil? || node.arguments || @replaying.include?(key) || takes_arguments?(definition)
          return if suppressed?

          @replaying.push(key)
          begin
            register_statements(definition.body)
            replay_dispatcher.dispatch(definition.body) if definition.body
          ensure
            @replaying.pop
          end
        end

        # A `routes.prepend` inside `after_initialize` or `on_load` registers after
        # the draw, and Rails evaluates it only on the next reload.
        def late_table_change?(node, statement)
          !statement && %i[append prepend].include?(node.name) && node.block &&
            node.receiver.is_a?(Prism::CallNode) && node.receiver.name == :routes
        end

        def enter_late_table_change(node)
          emit_dynamic(node)
          push_frame(node, suppress: true)
        end

        def open_unknown_block
          @stack.reverse.find { |f| f[:unknown_block] }
        end

        def takes_arguments?(definition)
          params = definition.parameters
          !params.nil? && (params.requireds.any? || params.posts.any? || params.keywords.any? { |k| k.is_a?(Prism::RequiredKeywordParameterNode) })
        end

        # `controller :pages do` is `scope(controller: :pages)`.
        def enter_controller(node)
          return unless node.block

          name = literal_first_arg(node)
          return push_frame(node, controller: name.to_s) if name

          emit_dynamic(node)
          push_frame(node, suppress: true)
        end

        # A mount MountListener names. A lambda or a variable is an app no walk
        # can name, and the booted tier counts a lambda as a dynamic construct.
        def mounted_app?(node)
          first = node.arguments&.arguments&.first
          first = first.elements.first&.key if first.is_a?(Prism::KeywordHashNode) || first.is_a?(Prism::HashNode)
          !first.nil? && !app_name(first).nil?
        end

        # `Spree::Core::Engine.routes.draw` adds to the engine's table, controllers under its
        # namespace (spree/admin/orders); the app's own `X::Application.routes.draw` is no engine.
        def engine_draw?(node)
          return false unless node.name == :draw && node.block

          routes = node.receiver
          return false unless routes.is_a?(Prism::CallNode) && routes.name == :routes

          owner = routes.receiver
          (owner.is_a?(Prism::ConstantPathNode) || owner.is_a?(Prism::ConstantReadNode)) &&
            owner.slice.end_with?("Engine")
        end

        def enter_engine_draw(node)
          engine = node.receiver.receiver.slice.delete_prefix("::")
          push_frame(node, mod: self.class.engine_namespace(engine), engine: engine)
        end

        def route_set_draw?(node)
          node.name == :draw && node.block && node.arguments&.arguments&.first.is_a?(Prism::SelfNode) &&
            (node.receiver.is_a?(Prism::ConstantPathNode) || node.receiver.is_a?(Prism::ConstantReadNode))
        end

        # ponytail: assumes the class's verb methods prefix the path and `as:` and hand the
        # rest to the mapper, as Canvas's ApiRouteSet does; read its `route` if another app differs.
        def enter_route_set(node)
          return if suppressed?

          known = @route_set&.call(node.receiver.slice.delete_prefix("::"))
          literal = node.arguments.arguments[1]
          prefix = literal.is_a?(Prism::StringNode) ? literal.unescaped : known&.dig(:prefix)
          unless known && prefix
            emit_dynamic(node, macro: :route_set)
            return push_frame(node, suppress: true)
          end

          push_frame(node, route_set: { prefix: prefix, name_prefix: known[:name_prefix].to_s })
        end

        def current_route_set
          @stack.reverse.find { |f| f[:route_set] }&.dig(:route_set)
        end

        # The controller a route without one of its own takes: the innermost
        # `scope(controller:)` or resource, else Rails' module path alone.
        def current_controller
          frame = @stack.reverse.find { |f| f[:controller] || f[:resource] }
          return frame[:resource][:controller] if frame && !frame[:controller]

          controller = prefixed_controller(frame ? frame[:controller] : "")
          controller unless controller.empty?
        end

        def current_engine
          @stack.reverse.find { |f| f[:engine] }&.dig(:engine)
        end

        # `match "/metrics", to: MetricsApp` attaches a Rack app, which
        # MountListener names with its path. Counting it here as well, as a
        # construct this walk could not expand, described one endpoint twice.
        def rack_app_target?(node)
          return false unless MountListener::VERB_MACROS.include?(node.name)

          !rack_app_constant(node.arguments&.arguments || []).nil?
        end

        def push_frame(node, **attrs)
          frame = { node: node }
          constraints = node_constraints(node) if node.is_a?(Prism::CallNode)
          frame[:route_constraints] = constraints if constraints
          @stack << frame.merge(attrs)
        end

        # Mapper's URL options, which a hash constraint turns into route defaults.
        URL_OPTIONS = %w[protocol subdomain domain host port].freeze
        ROUTE_LEVEL = (VERB_METHODS + %i[match root]).freeze
        # Calls whose options Rails passes on to the mapping, where one it does not know becomes a default.
        OPTION_CARRIERS = (ROUTE_LEVEL + %i[scope namespace resources resource with_options]).freeze
        MAPPER_OPTIONS = %w[as via to controller action on defaults constraints anchor format path internal shallow_path
                            shallow_prefix module path_names shallow blocks options only except param concerns].freeze

        # What `bin/rails routes` prints beside a route: its defaults, then the
        # constraints on its path segments. Scope URL options win over the
        # route's own, as Mapping merges them.
        def route_constraints(node, path)
          route_level = ROUTE_LEVEL.include?(node.name)
          scopes = @stack.reject { |f| f[:node].equal?(node) }.filter_map { |f| f[:route_constraints] }
          own = node_constraints(node) || {}
          scopes << own unless route_level || own.empty?
          own = {} unless route_level
          defaults = (own[:url] || {}).merge(scopes.map { |c| c[:url].merge(c[:defaults]) }.reduce({}, :merge)).merge(own[:defaults] || {})
          defaults = defaults.merge(scopes.map { |c| c[:options] }.reduce({}, :merge)).merge(own[:options] || {})
          params = path.scan(/[:*](\w+)/).flatten << "format"
          segments = scopes.map { |c| c[:segment] }.reduce({}, :merge).merge(own[:segment] || {}).select { |key, value| value && params.include?(key) }
          all = defaults.merge(segments)
          "{#{all.map { |key, value| "#{key}: #{value}" }.join(', ')}}" if all.any?
        end

        # Literal constraints and defaults a call carries, rendered as Ruby inspects them.
        def node_constraints(node)
          hash = hash_arg(node)
          return unless hash

          # `scoped` is what Rails keeps in the scope's constraints, which nested resources read.
          found = { url: {}, defaults: {}, segment: {}, scoped: {}, options: {} }
          if node.name == :constraints && node.receiver.nil?
            read_constraint_hash(hash, found)
          elsif node.name == :defaults && node.receiver.nil?
            each_literal(hash) { |k, v| found[:defaults][k] = constraint_value(v) }
          else
            hash.elements.each do |assoc|
              key = assoc_key(assoc)
              next unless key

              case key
              when "constraints" then read_constraint_hash(assoc.value, found)
              when "defaults" then each_literal(assoc.value) { |k, v| found[:defaults][k] = constraint_value(v) }
              when "format" then read_format(assoc.value, found) if OPTION_CARRIERS.include?(node.name)
              else
                unless assoc.value.is_a?(Prism::RegularExpressionNode)
                  found[:options][key] = constraint_value(assoc.value) if OPTION_CARRIERS.include?(node.name) && !MAPPER_OPTIONS.include?(key)
                  next
                end

                found[:segment][key] = constraint_value(assoc.value)
                # A resource moves its regexp options into its constraints.
                found[:scoped][key] = assoc.value if %i[resources resource].include?(node.name)
              end
            end
          end
          found if found.values.any?(&:any?)
        end

        def read_constraint_hash(hash, found)
          each_literal(hash) do |key, value|
            if URL_OPTIONS.include?(key)
              found[:url][key] = constraint_value(value) if value.is_a?(Prism::StringNode) || value.is_a?(Prism::IntegerNode)
            else
              found[:segment][key] = constraint_value(value)
              found[:scoped][key] = value
            end
          end
        end

        # Mapping#normalize_format: `true` requires a format, a string also defaults it, `false` clears a scope's.
        def read_format(value, found)
          case value
          when Prism::TrueNode then found[:segment]["format"] = "/.+/"
          when Prism::FalseNode then found[:segment]["format"] = nil
          when Prism::RegularExpressionNode then found[:segment]["format"] = constraint_value(value)
          when Prism::StringNode
            found[:defaults]["format"] = constraint_value(value)
            found[:segment]["format"] = Regexp.new(value.unescaped).inspect
          end
        rescue RegexpError
          nil
        end

        # The innermost `format:` a route or its scopes give; `true` makes the segment required.
        def required_format?(node)
          carriers = [ node, *@stack.reverse_each.map { |f| f[:node] } ].select do |n|
            n.is_a?(Prism::CallNode) && n.receiver.nil? && OPTION_CARRIERS.include?(n.name)
          end
          carrier = carriers.find { |n| own_options(n).key?(:format) }
          carrier && own_options(carrier)[:format] == true
        end

        def hash_arg(node)
          (node.arguments&.arguments || []).find { |a| a.is_a?(Prism::KeywordHashNode) || a.is_a?(Prism::HashNode) }
        end

        def each_literal(hash)
          return unless hash.is_a?(Prism::KeywordHashNode) || hash.is_a?(Prism::HashNode)

          hash.elements.each do |assoc|
            key = assoc_key(assoc)
            yield key, assoc.value if key
          end
        end

        def assoc_key(assoc)
          assoc.key.unescaped if assoc.is_a?(Prism::AssocNode) && assoc.key.is_a?(Prism::SymbolNode)
        end

        def constraint_value(node)
          case node
          when Prism::StringNode, Prism::SymbolNode then (node.is_a?(Prism::SymbolNode) ? node.unescaped.to_sym : node.unescaped).inspect
          when Prism::RegularExpressionNode
            flags = (node.ignore_case? ? Regexp::IGNORECASE : 0) | (node.extended? ? Regexp::EXTENDED : 0) | (node.multi_line? ? Regexp::MULTILINE : 0)
            Regexp.new(node.unescaped, flags).inspect
          else node.slice
          end
        rescue RegexpError
          node.slice
        end

        def suppressed?
          @stack.any? { |f| f[:suppress] }
        end

        # Each scope-introducing frame precomputes the absolute path prefix
        # its children see, so nesting composes in any order (namespace
        # inside resources, resources inside scope, ...).
        def current_prefix
          frame = @stack.reverse.find { |f| f[:prefix] }
          frame ? frame[:prefix] : "/"
        end

        # Rails stores a concern's block and re-runs it with the mapper as it
        # stands at each `concerns` site, so the definition itself routes
        # nothing and the body has to be kept for replay.
        def define_concern(node)
          return unless node.block

          name = literal_first_arg(node)
          @concern_blocks[name.to_s] = node.block if name
          push_frame(node, suppress: true)
        end

        def apply_concerns(node)
          return if suppressed?

          names = extract_symbol_args(node)
          names.empty? ? emit_dynamic(node) : replay_concerns(names, node)
        end

        # Walks the stored body again with the current stack in place, which is
        # what makes the same concern produce different paths at each site.
        def replay_concerns(names, node)
          names.each do |name|
            key = name.to_s
            block = @concern_blocks[key]
            # A concern defined in another drawn file, or one that names
            # itself, has no body this walk can replay; the marker keeps it
            # counted instead of dropping its routes silently.
            if block.nil? || @replaying.include?(key)
              emit_dynamic(node, macro: :concerns)
              next
            end

            @replaying.push(key)
            begin
              register_statements(block.body)
              replay_dispatcher.dispatch(block)
            ensure
              @replaying.pop
            end
          end
        end

        def replay_dispatcher
          @replay_dispatcher ||= ListenerRegistration.dispatcher_for(self)
        end

        # `with_options` is ActiveSupport's OptionMerger, not a routing method:
        # every call inside the block is re-sent with the outer options merged
        # in, the inner call's own keys winning.
        def enter_with_options(node)
          return unless node.block

          if node.block.respond_to?(:parameters) && node.block.parameters
            # The routes inside are sent to the block parameter, so they reach
            # this walker with a receiver it deliberately ignores. A marker
            # keeps them counted rather than dropped.
            emit_dynamic(node)
            push_frame(node, suppress: true)
            return
          end

          push_frame(node, defaults: route_options(node))
        end

        def current_defaults
          @stack.filter_map { |f| f[:defaults] }.reduce({}, :merge)
        end

        def enter_namespace(node)
          name = literal_first_arg(node)
          unless name
            emit_dynamic(node)
            # A block whose name we can't read still opens a nested scope -
            # without suppressing it, children resolve against the OUTER
            # prefix and get tagged as verified routes, when in fact they
            # live under an unknown namespace. Treat it like a concern: mark
            # the whole subtree dynamic instead of guessing.
            push_frame(node, suppress: true) if node.block
            return
          end
          return unless node.block

          opts = route_options(node)
          path = (opts[:path] || name).to_s
          as = (opts[:as] || name).to_s
          push_frame(node,
                     prefix: join_path(current_prefix, path),
                     mod: (opts[:module] || name).to_s,
                     name_prefix: as,
                     shallow_path: join_path(current_shallow_path, (literal_option(opts[:shallow_path]) || path).to_s),
                     shallow_prefix: join_names(current_shallow_prefix, (literal_option(opts[:shallow_prefix]) || as).to_s))
        end

        def enter_scope(node)
          return unless node.block

          opts = route_options(node)
          first = literal_first_arg(node)
          path = (first || opts[:path])&.to_s
          shallow_path = (literal_option(opts[:shallow_path]) || path)&.to_s
          shallow_prefix = (literal_option(opts[:shallow_prefix]) || literal_option(opts[:as]))&.to_s
          frame = { prefix: path ? join_path(current_prefix, path) : current_prefix,
                    mod: opts[:module]&.to_s,
                    name_prefix: opts[:as]&.to_s,
                    controller: opts[:controller]&.to_s,
                    via: opts[:via],
                    path_names: path_names_option(opts) }
          frame[:shallow_path] = join_path(current_shallow_path, shallow_path) if shallow_path
          frame[:shallow_prefix] = join_names(current_shallow_prefix, shallow_prefix) if shallow_prefix
          frame[:shallow] = opts[:shallow] == true if opts.key?(:shallow)
          push_frame(node, **frame)
        end

        def handle_resources(node, singular:)
          return if suppressed?
          # A route set's class defines its own `resources`.
          return emit_dynamic(node) if current_route_set

          names = extract_symbol_args(node)
          if names.empty? || opaque_options?(node)
            emit_dynamic(node)
            # Same reasoning as the namespace case: a block we can't attach
            # resource info to still opens a nested scope, so its children
            # must be suppressed rather than resolved against the outer
            # prefix and misreported as verified routes.
            push_frame(node, suppress: true) if node.block
            return
          end

          opts = route_options(node)
          names.each { |n| emit_resource_routes(node, n.to_s, opts, singular: singular) }
          concerns = Array(opts[:concerns])

          if node.block
            return unless names.size == 1

            push_resource_frame(node, names.first.to_s, opts, singular: singular)
            replay_concerns(concerns, node) if concerns.any?
          elsif concerns.any?
            # A concern applied without a block still runs inside the resource's
            # scope, so the frame has to exist for the replay and go again
            # straight after it - there is no block leave to pop it.
            names.each do |n|
              push_resource_frame(node, n.to_s, opts, singular: singular)
              replay_concerns(concerns, node)
              @stack.pop
            end
          end
        end

        # Routes nested under this resource inherit its singular route key as a
        # name prefix (resources :posts { resources :comments } -> the comments
        # index route is named "post_comments", not "comments"). A shallow
        # resource nests its children under the shallow path and prefix alone.
        def push_resource_frame(node, name, opts, singular:)
          layout = resource_layout(name, opts, singular: singular)
          frame = {
            prefix: layout[:nested_prefix],
            mod: opts[:module]&.to_s,
            name_prefix: layout[:shallow] ? join_names(current_shallow_prefix, layout[:key]) : layout[:key],
            name_root: layout[:shallow],
            path_names: path_names_option(opts),
            resource: {
              name: name,
              singular: singular,
              controller: resource_controller(name, opts, singular: singular),
              base: layout[:base],
              member_path: layout[:member_path],
              new_path: layout[:new_path],
              singular_route_name: layout[:member_name],
              new_route_name: layout[:singular_name],
              plural_route_name: layout[:plural_name]
            }
          }
          frame[:shallow] = opts[:shallow] == true if opts.key?(:shallow)
          push_frame(node, **frame)
          nest_param_constraint(layout, opts)
        end

        # Rails' nested_options: a regexp constraint on the resource's param
        # also constrains the param its nested routes name it by.
        def nest_param_constraint(layout, opts)
          param = resource_param(opts)
          value = @stack.filter_map { |f| f[:route_constraints]&.dig(:scoped) }.reduce({}, :merge)[param]
          return unless value.is_a?(Prism::RegularExpressionNode)

          key = "#{layout[:key]}_#{param}"
          frame = @stack.last
          own = frame[:route_constraints] || { url: {}, defaults: {}, segment: {}, scoped: {}, options: {} }
          frame[:route_constraints] = own.merge(segment: own[:segment].merge(key => constraint_value(value)),
                                                scoped: own[:scoped].merge(key => value))
        end

        def emit_resource_routes(node, name, opts, singular:)
          layout = resource_layout(name, opts, singular: singular)
          base = layout[:base]
          member = layout[:member_path]
          member_name = layout[:member_name]
          controller = resource_controller(name, opts, singular: singular)
          actions = requested_actions(singular ? SINGULAR_ACTIONS : PLURAL_ACTIONS, opts)

          actions.each do |action|
            case action
            when :index   then emit(node, "GET", base, controller, "index", layout[:plural_name])
            when :create  then emit(node, "POST", base, controller, "create", singular ? layout[:singular_name] : layout[:plural_name])
            when :new     then emit(node, "GET", layout[:new_path], controller, "new", "new_#{layout[:singular_name]}")
            when :edit    then emit(node, "GET", layout[:edit_path], controller, "edit", "edit_#{member_name}")
            when :show    then emit(node, "GET", member, controller, "show", member_name)
            when :update
              emit(node, "PATCH", member, controller, "update", member_name)
              emit(node, "PUT", member, controller, "update", member_name)
            when :destroy then emit(node, "DELETE", member, controller, "destroy", member_name)
            end
          end
        end

        # Rails draws a shallow resource's member routes in the shallow scope: the
        # namespace and scope paths and names around it, none of its parents'.
        # A singleton resource is never shallow. `new` and `edit` come from path_names.
        def resource_layout(name, opts, singular:)
          path = (opts[:path] || name).to_s
          base = join_path(current_prefix, path)
          key = singular_route_key(name, opts, singular: singular)
          param = resource_param(opts)
          path_names = current_path_names.merge(path_names_option(opts))
          shallow = !singular && (opts.key?(:shallow) ? opts[:shallow] == true : current_shallow)
          shallow_base = join_path(current_shallow_path, path)
          member = singular ? base : "#{shallow ? shallow_base : base}/:#{param}"
          {
            base: base,
            key: key,
            shallow: shallow,
            member_path: member,
            edit_path: join_path(member, (path_names[:edit] || "edit").to_s),
            new_path: join_path(base, (path_names[:new] || "new").to_s),
            nested_prefix: singular ? base : "#{shallow ? shallow_base : base}/:#{key}_#{param}",
            singular_name: route_name_for(key),
            member_name: shallow ? join_names(current_shallow_prefix, key) : route_name_for(key),
            plural_name: route_name_for(collection_route_key(name, opts, singular: singular))
          }
        end

        def current_shallow
          @stack.reverse.find { |f| f.key?(:shallow) }&.dig(:shallow) == true
        end

        def current_shallow_path
          @stack.reverse.find { |f| f[:shallow_path] }&.dig(:shallow_path) || "/"
        end

        def current_shallow_prefix
          @stack.reverse.find { |f| f[:shallow_prefix] }&.dig(:shallow_prefix)
        end

        def current_path_names
          @stack.filter_map { |f| f[:path_names] }.reduce(@global_path_names, :merge)
        end

        def path_names_option(opts)
          names = opts[:path_names]
          names.is_a?(Hash) ? names.transform_keys(&:to_sym) : {}
        end

        # A value the source spells out; an expression reads as INFERRED and adds nothing.
        def literal_option(value)
          value if (value.is_a?(String) || value.is_a?(Symbol)) && value != RailsAiContext::Confidence::INFERRED
        end

        def join_names(*parts)
          joined = parts.compact.map(&:to_s).reject(&:empty?).join("_")
          joined unless joined.empty?
        end

        # Options Rails reads that the source does not spell out: a positional
        # variable (`resources :x, opts`), a `**splat`, or an only:/except: list
        # held in a constant or a call.
        def opaque_options?(node)
          (node.arguments&.arguments || []).any? do |arg|
            case arg
            when Prism::SymbolNode, Prism::StringNode then false
            when Prism::KeywordHashNode, Prism::HashNode
              arg.elements.any? { |assoc| !assoc.is_a?(Prism::AssocNode) || opaque_action_list?(assoc) }
            else true
            end
          end
        end

        def opaque_action_list?(assoc)
          return false unless %i[only except].include?(extract_key(assoc.key))

          values = assoc.value.is_a?(Prism::ArrayNode) ? assoc.value.elements : [ assoc.value ]
          !values.all? { |v| v.is_a?(Prism::SymbolNode) || v.is_a?(Prism::StringNode) }
        end

        # `as:` renames the route helpers and the nested param, and leaves the
        # path and the controller on the resource's own name.
        def route_key(name, opts)
          (opts[:as] || name).to_s
        end

        # Rails' Resource#collection_name: the route key as written, with
        # `_index` appended when that key is already singular, so
        # `resources :sheep` names its index route sheep_index and
        # `resources :photos, as: :image` names it image_index.
        # SingletonResource aliases collection_name to the singular, so a
        # `collection` block inside `resource :confirmation` stays singular.
        def collection_route_key(name, opts, singular:)
          key = route_key(name, opts)
          return key if singular

          key.singularize == key ? "#{key}_index" : key
        end

        def singular_route_key(name, opts, singular:)
          key = route_key(name, opts)
          singular ? key : key.singularize
        end

        def resource_param(opts)
          (opts[:param] || "id").to_s
        end

        def emit_verb_route(node)
          return if suppressed?

          opts = route_options(node)
          via = opts.key?(:via) ? opts[:via] : @stack.reverse.find { |f| f[:via] }&.dig(:via)
          verb = node.name == :match ? match_verb(via) : node.name.to_s.upcase
          return emit_dynamic(node) if verb.nil? || opaque_options?(node)

          rocket_key = opts.keys.find { |k| k.is_a?(String) }
          paths = literal_paths(node)
          paths = [ [ rocket_key, false ] ] if paths.empty? && rocket_key
          return emit_dynamic(node) if paths.empty?

          paths.each { |segment, action| emit_verb_path(node, verb, segment, action, opts, rocket_key) }
        end

        # Rails 7.x and 8.0 draw every path of `get "/a", "/b"`, strings before symbols.
        # @return [Array<[String, Boolean]>] each path, and whether it names an action
        def literal_paths(node)
          args = (node.arguments&.arguments || []).select { |a| a.is_a?(Prism::StringNode) || a.is_a?(Prism::SymbolNode) }
          args.sort_by { |a| a.is_a?(Prism::StringNode) ? 0 : 1 }.map { |a| [ a.unescaped, a.is_a?(Prism::SymbolNode) ] }
        end

        def emit_verb_path(node, verb, segment, action_given, opts, rocket_key)
          target_given = opts.key?(:to) || !rocket_key.nil?
          target = opts[:to] || (rocket_key && opts[rocket_key])
          return emit_dynamic(node) if target_given && unreadable_target?(target)

          route_set = current_route_set unless node.name == :match
          if route_set
            segment = "#{route_set[:prefix]}/#{segment}"
            # The class passes `as: nil` when none is given, and Rails generates no name then.
            as = opts[:as] && "#{route_set[:name_prefix]}#{opts[:as]}"
          end

          controller, action = resolve_target(target, segment, opts)
          return emit_dynamic(node) unless controller && action

          name = route_set ? as && verb_route_name(as, segment, opts[:on]) : verb_route_name(opts[:as], segment, opts[:on])
          # Rails maps an action given as a symbol through path_names; a string is the path.
          path = action_given ? (current_path_names[segment.to_sym] || segment).to_s : segment
          emit(node, verb, verb_route_path(path, opts[:on]), controller, action, name)
        end

        # Rails draws one route answering every verb in `via:` ("GET|POST"), and
        # `via: :all` answers any verb, as the booted table shows it.
        def match_verb(via)
          verbs = Array(via)
          return if verbs.empty? || verbs.include?(RailsAiContext::Confidence::INFERRED)
          return "ANY" if verbs.map(&:to_s).include?("all")

          verbs.map { |v| v.to_s.upcase }.join("|")
        end

        # member/collection blocks push their own prefix, so inside them the
        # general prefix already points at the right base; only the explicit
        # on: keyword needs special handling.
        def enter_member_collection(node, kind)
          return unless node.block

          resource = current_resource
          return unless resource

          prefix = { member: resource[:member_path], new: resource[:new_path] }.fetch(kind, resource[:base])
          push_frame(node, prefix: prefix, kind: kind)
        end

        # The member/collection frame a verb route sits in, if any - either
        # from an enclosing member/collection block or an explicit on: keyword.
        def member_collection_kind(on_option)
          return on_option.to_sym if on_option

          frame = @stack.reverse.find { |f| f[:kind] }
          frame && frame[:kind]
        end

        def verb_route_path(segment, on_option)
          resource = current_resource
          if on_option && resource
            base = { member: resource[:member_path], new: resource[:new_path] }.fetch(on_option.to_sym, resource[:base])
            return join_path(base, segment)
          end

          join_path(current_prefix, segment)
        end

        # A to: value the parser can't read as a literal "controller#action"
        # string (a helper call like redirect(...), a symbol, a constant, or
        # a string with no "#") can't be split into a controller and action,
        # so it must not feed the segment-based guessing in resolve_target.
        def unreadable_target?(target)
          !(target.is_a?(String) && target.include?("#"))
        end

        # Rails' order: a "controller#action" target, then the `a/b` path
        # shorthand when no action is given, then the route's or scope's
        # controller with the given action or the path as one.
        def resolve_target(target, segment, opts)
          action = opts[:action].to_s if opts[:action].is_a?(Symbol) || opts[:action].is_a?(String)
          target ||= shorthand_target(segment) unless action
          if target.is_a?(String) && target.include?("#")
            controller, action = target.split("#", 2)
            return [ prefixed_controller(controller), action ]
          end

          controller = opts[:controller] ? prefixed_controller(opts[:controller].to_s) : current_controller
          action ||= segment.tr("-", "_") if segment.match?(%r{\A[\w\-]+\z})
          [ controller, action ]
        end

        def shorthand_target(segment)
          return unless segment.match?(%r{\A/?[-\w]+/[-\w/]+\z})

          segment.delete_prefix("/").sub(%r{/([^/]*)\z}, '#\\1').tr("-", "_")
        end

        def emit_root(node)
          return if suppressed?

          target = literal_first_arg(node)&.to_s || route_options(node)[:to]
          return emit_dynamic(node) unless target.is_a?(String) && target.include?("#")

          controller, action = target.split("#", 2)
          as = route_options(node)[:as]
          emit(node, "GET", current_prefix, prefixed_controller(controller), action,
               [ current_name_prefix, (as.is_a?(Symbol) || as.is_a?(String)) ? as.to_s : "root" ].compact.reject(&:empty?).join("_"))
        end

        def emit(node, verb, path, controller, action, name)
          path = "#{path}.:format" if required_format?(node)
          record = {
            type: :route,
            verb: verb,
            path: path,
            controller: controller,
            action: action.to_s,
            location: node.location.start_line,
            confidence: confidence_for(node)
          }
          engine = current_engine
          # An engine's table keeps its own names.
          record[:name] = name if name && !name.empty? && @taken_names.add?([ engine, name ])
          record[:engine] = engine if engine
          condition = current_condition
          record[:condition] = condition if condition
          record[:prepend] = true if @stack.any? { |f| f[:prepend] }
          constraints = route_constraints(node, path)
          record[:constraints] = constraints if constraints
          params = path.scan(/:(\w+)/).flatten
          record[:params] = params if params.any?
          record[:restful] = RESTFUL_ACTIONS.include?(record[:action])
          @results << record
        end

        def emit_dynamic(node, macro: node.name)
          return if suppressed?

          record = { type: :dynamic, macro: macro, location: node.location.start_line }
          engine = current_engine
          record[:engine] = engine if engine
          # `draw(:admin)` names a file, and Rails resolves it by literal path.
          # Recording the name is what lets the introspector follow it instead
          # of writing off everything the file defines.
          if macro == :draw
            record[:target] = draw_target(node)
            record[:scope] = @stack.map { |frame| frame.except(:node) }
            record[:prefix] = current_prefix
            record[:name_prefix] = current_name_prefix
          end
          @results << record
        end

        def draw_target(node)
          target = extract_first_symbol(node)
          target unless target == RailsAiContext::Confidence::INFERRED
        end

        # Keyword options including hash-rocket string keys, so
        # `get "up" => "rails/health#show", as: :x` yields
        # {"up" => "rails/health#show", as: :x}, with any enclosing
        # with_options defaults underneath them.
        def route_options(node)
          current_defaults.merge(own_options(node))
        end

        def own_options(node)
          args = node.arguments&.arguments || []
          hash = args.find { |a| a.is_a?(Prism::KeywordHashNode) || a.is_a?(Prism::HashNode) }
          return {} unless hash

          hash.elements.each_with_object({}) do |assoc, acc|
            next unless assoc.is_a?(Prism::AssocNode)

            key = case assoc.key
            when Prism::SymbolNode then assoc.key.unescaped.to_sym
            when Prism::StringNode then assoc.key.unescaped
            end
            acc[key] = extract_value(assoc.value) if key
          end
        end

        # First positional argument when it is a plain symbol/string literal.
        def literal_first_arg(node)
          arg = node.arguments&.arguments&.first
          case arg
          when Prism::SymbolNode, Prism::StringNode then arg.unescaped
          end
        end

        def requested_actions(all, opts)
          actions = all
          actions &= Array(opts[:only]).map(&:to_sym) if opts[:only]
          actions -= Array(opts[:except]).map(&:to_sym) if opts[:except]
          actions
        end

        # Rails maps a singular resource to the plural controller
        # (resource :profile -> ProfilesController). `module:` is not a
        # resource option there: Rails peels it into a surrounding scope, so it
        # moves the controller and never the path.
        def resource_controller(name, opts, singular: false)
          controller = (opts[:controller] || (singular ? name.pluralize : name)).to_s
          return controller.delete_prefix("/") if controller.start_with?("/")

          controller = "#{opts[:module]}/#{controller}" if opts[:module]
          prefixed_controller(controller)
        end

        # A leading slash makes the controller absolute: Rails' own
        # add_controller_module drops the slash and applies no module.
        def prefixed_controller(controller)
          return controller.delete_prefix("/") if controller.start_with?("/")

          mods = @stack.filter_map { |f| f[:mod] }
          ([ *mods, controller ] - [ "" ]).join("/")
        end

        def current_name_prefix
          parts = []
          @stack.reverse_each do |frame|
            parts.unshift(frame[:name_prefix]) if frame[:name_prefix]
            break if frame[:name_root]
          end
          parts.empty? ? nil : parts.join("_")
        end

        def current_resource
          frame = @stack.reverse.find { |f| f[:resource] }
          frame && frame[:resource]
        end

        def route_name_for(resource_name)
          [ current_name_prefix, resource_name ].compact.reject(&:empty?).join("_")
        end

        # Member/collection-scoped verb routes name themselves "<action>_<resource>"
        # (preview_post, archived_posts) rather than the ordinary
        # "<prefix>_<action>" pattern used elsewhere, and an as: override
        # replaces only the action part, not the whole name.
        def verb_route_name(as_option, segment, on_option)
          kind = member_collection_kind(on_option)
          resource = current_resource
          if kind && resource
            resource_key = { member: resource[:singular_route_name], new: "new_#{resource[:new_route_name]}" }
              .fetch(kind, resource[:plural_route_name])
            base = as_option ? as_option.to_s : plain_segment_name(segment)
            return nil unless base && resource_key && !resource_key.empty?

            return "#{base}_#{resource_key}"
          end

          return route_name_for(as_option.to_s) if as_option

          generated_name(route_name_for(plain_segment_name(segment)))
        end

        # Rails converts the hyphens of a path-derived name to underscores
        # (`api_v1_gift_cards_redeem`), and uses no part of the path at all
        # when the path carries a character outside [\w\-/], such as the dot
        # of `.well-known`. Then it drops the whole generated name when the
        # result does not start with a letter or an underscore.
        UNNAMEABLE_PATH = %r{[^\w\-/]}
        NAMEABLE = /\A[_a-z]/i

        def plain_segment_name(segment)
          plain = segment.to_s.delete_prefix("/")
          return nil if plain.empty? || plain.include?(":") || plain.match?(UNNAMEABLE_PATH)

          plain.tr("/", "_").tr("-", "_")
        end

        def generated_name(name)
          name if name&.match?(NAMEABLE)
        end

        def join_path(*segments)
          cleaned = segments.compact.map { |s| s.to_s.gsub(%r{\A/+|/+\z}, "") }.reject(&:empty?)
          normalize_route_path("/#{cleaned.join('/')}")
        end
      end
    end
  end
end
