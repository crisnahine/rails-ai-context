# frozen_string_literal: true

require "active_support/core_ext/string/inflections"
require "prism"

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
        include RoutesWalk

        VERB_METHODS = %i[get post put patch delete options].freeze
        PLURAL_ACTIONS = %i[index create new edit show update destroy].freeze
        # Rails' drawing order: the first route asking for a name gets it.
        SINGULAR_ACTIONS = %i[new edit show update destroy create].freeze
        # Mapper::CANONICAL_ACTIONS: in a member, collection or new scope these draw at the scope's path, unnamed by the action.
        CANONICAL_ACTIONS = %w[index create new show update destroy].freeze
        DYNAMIC_MACROS = %i[devise_for draw].freeze
        # `direct` and `resolve` define URL helpers and draw no route.
        URL_HELPER_MACROS = %i[direct resolve].freeze
        # Calls that draw routes; an unknown block that makes none of them configures a gem macro.
        ROUTE_METHODS = (VERB_METHODS + %i[match namespace scope resources resource member collection new nested shallow
                                           concern concerns with_options controller mount root draw devise_for]).freeze
        # Blocks that draw their routes where they stand: Rails' constraints and defaults, Devise's, and route_translator's.
        # Any other method's block may scope its routes in a way the walk cannot see.
        IN_PLACE_BLOCKS = %i[constraints defaults devise_scope as authenticate authenticated unauthenticated localized].freeze
        # Statement-level calls that draw nothing into the table.
        NON_ROUTING = %i[require require_relative puts p pp print warn raise default_url_options extend include].freeze
        # Iterators whose block is drawn once per element when the receiver is a literal list.
        LOOPS = %i[each each_with_index].freeze
        # The block methods of Ruby's collections, numbers and strings, and ActiveSupport's on them: each runs its
        # block during the call, while `Sidekiq::Web.use do` keeps it for each request.
        ITERATORS = %i[
          all? any? bsearch bsearch_index chunk chunk_while collect collect! collect_concat combination count cycle
          delete delete_if detect downto drop_while each each_byte each_char each_codepoint each_cons each_entry
          each_grapheme_cluster each_index each_key each_line each_pair each_slice each_value each_with_index
          each_with_object fetch fetch_values fill filter filter! filter_map find find_all find_index flat_map grep
          grep_v group_by gsub gsub! index inject keep_if map map! max max_by merge merge! min min_by minmax minmax_by
          none? one? partition permutation product reduce reject reject! repeated_combination repeated_permutation
          reverse_each rindex scan select select! slice_after slice_before slice_when sort sort! sort_by sort_by! split
          step sub sub! sum take_while times to_h to_set transform_keys transform_keys! transform_values
          transform_values! uniq uniq! update upto with_index with_object zip
          deep_transform_keys deep_transform_values in_groups in_groups_of index_by index_with many?
        ].to_set.freeze
        # Every write that changes a local, a multi-assignment's target among them; AstWalk::VALUE_WRITES is every kind of write.
        VARIABLE_WRITES = [ Prism::LocalVariableWriteNode, Prism::LocalVariableOperatorWriteNode, Prism::LocalVariableOrWriteNode,
                            Prism::LocalVariableAndWriteNode, Prism::LocalVariableTargetNode ].freeze
        # Calls that change the string they are called on, and calls that keep their argument in their receiver.
        STRING_MUTATORS = InitializerSettings::MUTATORS
        HOLDING_MUTATORS = CallSiteExpansion::MUTATORS
        INDEX_WRITES = [ Prism::IndexOperatorWriteNode, Prism::IndexOrWriteNode, Prism::IndexAndWriteNode, Prism::IndexTargetNode ].freeze
        # Where a value written into one is kept: an element, a hash value, a splat, either arm of a branch.
        HOLDERS = [ Prism::ArgumentsNode, Prism::ArrayNode, Prism::HashNode, Prism::KeywordHashNode, Prism::AssocNode,
                    Prism::SplatNode, Prism::ParenthesesNode, Prism::StatementsNode, Prism::BeginNode, Prism::IfNode,
                    Prism::UnlessNode, Prism::ElseNode, Prism::OrNode, Prism::AndNode ].freeze

        # ponytail: an engine's namespace is its first segment; read isolate_namespace if one differs.
        def self.engine_namespace(engine)
          engine.split("::").first.underscore
        end

        # A name that reads as an engine's, for a constant whose file the app does not hold.
        ENGINE_NAME = /(?:\A|::)Engine\z/

        # Mapper#app_name: a class's name underscored; an engine's railtie_name, which only its file can tell.
        def self.mount_name(class_name)
          underscored(class_name) unless class_name.match?(ENGINE_NAME)
        end

        # Rails' name for a class: `Admin::UI` is admin_ui.
        def self.underscored(class_name)
          class_name.underscore.tr("/", "_")
        end

        # `scope` is the frames a `draw` of this file sits in, as its record carries them.
        # `route_set` answers { prefix:, name_prefix: } for an app class that draws routes.
        # `names` is the set of route names taken so far, shared by every file of one table.
        # `before_8_1`: the app's Rails draws every path of `get "/a", "/b"` and names a mount given `as: nil`; 8.1 does neither.
        # `api_only`: the app sets config.api_only, so its own table draws no new or edit route.
        # `mount_name` answers the name Rails gives a mount of a class, or nil.
        def initialize(scope: [], route_set: nil, names: Set.new, before_8_1: false, api_only: false, mount_name: self.class.method(:mount_name))
          super()
          @before_8_1 = before_8_1
          @mount_name = mount_name
          @api_only = api_only
          @stack = scope.map { |frame| frame.merge(node: nil) }
          @route_set = route_set
          @concern_blocks = {}
          @replaying = []
          @replayed = Set.new.compare_by_identity
          # The block scopes and branches each concern's block and method's def is written in, for its replays.
          @written_under = {}.compare_by_identity
          # The listeners walking this file beside this one, which see each body it replays.
          @joined = []
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
          @methods[node.name] = definitions_in_force(@methods[node.name], node, [ node ]) if @statements.key?(node) && node.receiver.nil?
          push_frame(node, suppress: true, held: node)
        end

        def on_def_node_leave(node)
          @stack.pop if @stack.last && @stack.last[:node].equal?(node)
        end

        def on_call_node_enter(node)
          note_mapper_call(node)
          statement = @statements.key?(node)
          register_statements(node.block.body) if statement && route_body?(node)
          return enter_engine_draw(node) if engine_draw?(node)
          return enter_route_set(node) if route_set_draw?(node)
          # `ActiveAdmin.routes(self)` hands the mapper to code this walk cannot see.
          return emit_dynamic(node) if node.receiver && statement && node.arguments&.arguments&.any?(Prism::SelfNode)
          if after_initialize?(node)
            register_table_changes(node.block.body)
            return push_frame(node, late: true)
          end
          return enter_late_table_change(node) if late_table_change?(node, statement)
          return push_frame(node, prepend: true) if node.receiver && node.name == :prepend && statement && route_body?(node)
          return enter_loop(node) if statement && loop?(node)
          return register_statements(node.block.body) if statement && run_once?(node)
          return enter_repeat(node) if statement && iterator?(node)
          return unless mapper_call?(node)
          return emit_repeated(node) if repeated?(node)

          @routing_calls += 1 if ROUTE_METHODS.include?(node.name)
          case node.name
          when :namespace then enter_namespace(node)
          when :scope then enter_scope(node)
          when :resources then handle_resources(node, singular: false)
          when :resource then handle_resources(node, singular: true)
          when :member then enter_member_collection(node, :member)
          when :collection then enter_member_collection(node, :collection)
          when :new then enter_member_collection(node, :new)
          # A resource's frame already holds its nested scope, which a direct child draws under too.
          when :nested then push_frame(node, nested: true, suppress: current_resource.nil?) if node.block
          when :shallow then push_frame(node, shallow: true) if node.block
          when :concern then define_concern(node)
          when :concerns then apply_concerns(node)
          when :with_options then enter_with_options(node)
          when :controller then enter_controller(node)
          when :resources_path_names then @global_path_names.merge!(path_names_option(path_names: own_options(node)))
          when *URL_HELPER_MACROS then push_frame(node, suppress: true) if node.block
          when :mount then mounted_app?(node) ? take_mount_name(node) : emit_dynamic(node)
          when :root then emit_root(node)
          when *VERB_METHODS, :match then emit_verb_route(node, app: rack_app_target?(node))
          when *DYNAMIC_MACROS then emit_dynamic(node) unless rack_app_target?(node)
          else
            if statement && node.block
              # An empty block (a commented-out `constraints do`) configures nothing.
              push_frame(node, unknown_block: @routing_calls, pending: [], suppress: !IN_PLACE_BLOCKS.include?(node.name)) if node.block.body
            elsif statement && !NON_ROUTING.include?(node.name)
              call_method_or_count(node)
            end
          end
        end

        # Where Rails attaches a Rack app given `path` inside a resource, member or collection scope, which only this walk
        # models: it draws there as a route at that path does. Nil outside one; :unknown where the walk cannot place it
        # (a resource it cannot read, a concern's body where it is defined, a block in a resource that does not draw in place).
        def resource_scoped_path(node, path)
          return :unknown if @stack.any? { |f| f[:unplaced] } || (scope_level && suppressed?)

          return unless scope_level

          on = route_options(node)[:on]
          # Rails draws a canonical action given as a symbol at the scope's own path, as it does a verb route's.
          verb_route_path(path.is_a?(Symbol) && canonical_action?(path, on) ? "" : path.to_s, on)
        end

        # A loop variable's value, or a string or symbol interpolating only literals and loop variables; nil otherwise.
        def bound_value(node)
          case node
          when Prism::LocalVariableReadNode
            block = @blocks[-1 - node.depth]
            frame = block && @stack.reverse.find { |f| f[:block].equal?(block) && f[:bindings]&.key?(node.name) }
            frame && frame[:bindings][node.name]
          when Prism::ImplicitNode then bound_value(node.value)
          when Prism::InterpolatedStringNode, Prism::InterpolatedSymbolNode
            parts = node.parts.map do |part|
              next part.unescaped if part.is_a?(Prism::StringNode)

              inner = part.statements&.body if part.is_a?(Prism::EmbeddedStatementsNode)
              bound_value(inner.first)&.to_s if inner&.size == 1
            end
            text = parts.join unless parts.include?(nil)
            node.is_a?(Prism::InterpolatedSymbolNode) ? text&.to_sym : text
          end
        end

        # A string or symbol the source spells out or a loop binds.
        def literal_or_bound(node)
          value = case node
          when Prism::SymbolNode then node.unescaped.to_sym
          when Prism::StringNode then node.unescaped
          else bound_value(node)
          end
          value if value.is_a?(String) || value.is_a?(Symbol)
        end

        # Walks `listener` through every body this walk replays, as Rails runs it there.
        def join(listener)
          @joined << listener
        end

        # The bodies Rails runs only where they are replayed (a concern's, a routes-file method's) that the walk is in.
        def held_keys
          @stack.filter_map { |f| f[:held] }
        end

        # Whether the walk replayed any of these definitions, each replay drawing what is in it at its own site.
        def replayed?(keys)
          keys.any? { |key| @replayed.include?(key) }
        end

        # An unknown block that draws no route is a gem macro (`use_doorkeeper do`), counted once,
        # and so is one whose routes it does not draw in place.
        def on_call_node_leave(node)
          return unless @stack.last && @stack.last[:node].equal?(node)
          return finish_resources(node) if @stack.last[:draw]
          return finish_loop(node) if @stack.last[:loop]

          frame = @stack.pop
          return unless frame[:unknown_block]
          if frame[:unknown_block] != @routing_calls
            return emit_dynamic(node) if frame[:suppress]

            return frame[:pending].each { |call| emit_dynamic(call) }
          end

          outer = open_unknown_block
          outer ? outer[:pending] << node : emit_dynamic(node)
        end

        private

        # A receiver's block (`Sidekiq::Web.use ... do`) is plain Ruby; only a draw holds routes.
        def route_body?(node)
          node.block.is_a?(Prism::BlockNode) && (mapper_call?(node) || %i[draw append prepend].include?(node.name))
        end

        # `LOC.each_key { }` or `2.times { }`, which the walk does not unroll.
        def iterator?(node)
          node.receiver && node.block.is_a?(Prism::BlockNode) && ITERATORS.include?(node.name) && !route_body?(node)
        end

        def run_once?(node)
          node.block.is_a?(Prism::BlockNode) && RUN_ONCE.include?(node.name)
        end

        # A block Ruby runs any number of times, which the walk reads once without replaying its passes.
        def enter_repeat(node)
          register_statements(node.block.body)
          push_frame(node, repeats: true)
        end

        # Every pass of such a block draws its routes again, so each call that draws some counts as a construct.
        # A Rack app it attaches is MountListener's to list.
        # shortcut: a `draw` there is followed once, count it too if a routes file ever draws one file per pass.
        def repeated?(node)
          @stack.any? { |f| f[:repeats] } && !rack_app_route?(node) &&
            (@methods.key?(node.name) || (ROUTE_METHODS.include?(node.name) && !%i[concern draw].include?(node.name)))
        end

        def rack_app_route?(node)
          node.name == :mount ? mounted_app?(node) : rack_app_target?(node)
        end

        def emit_repeated(node)
          emit_dynamic(node)
          push_frame(node, suppress: true) if node.block
        end

        def loop?(node)
          LOOPS.include?(node.name) && node.receiver && node.arguments.nil? && node.block.is_a?(Prism::BlockNode)
        end

        # Whether the block takes one plain parameter per element (and an index for each_with_index)
        # and leaves it the element on every pass.
        def unrolls?(node)
          params = node.block.parameters.parameters if node.block.parameters.is_a?(Prism::BlockParametersNode)
          return false unless params

          plain = params.optionals.empty? && params.rest.nil? && params.posts.empty? && params.keywords.empty? &&
                  params.keyword_rest.nil? && params.block.nil? && params.requireds.all?(Prism::RequiredParameterNode)
          # A mutation of a symbol, or of a string under `# frozen_string_literal: true`, raises at boot.
          # shortcut: a mutable string held or handed on (`d = { page: x }`, `x.each_char { }`) declines though most never
          # change it, follow the holder's later calls if real route files lose routes to this.
          mutable = node.receiver.elements.any? { |e| e.is_a?(Prism::StringNode) && !e.frozen? }
          plain && params.requireds.size.between?(1, node.name == :each_with_index ? 2 : 1) &&
            !changes_variable?(node.block.body, params.requireds.map(&:name), mutable: mutable)
        end

        # A pass that assigns, mutates or hands on its variable may no longer hold the element. `depth`
        # counts the blocks in between, as Prism's does, so a shadowing parameter is another variable.
        def changes_variable?(node, names, depth = 0, kept: false, mutable: true)
          case node
          when nil, *AstWalk::OWN_SCOPES then return false
          when *VARIABLE_WRITES then return true if own_variable?(node, names, depth)
          when Prism::LocalVariableReadNode then return kept && own_variable?(node, names, depth)
          when *INDEX_WRITES then return true if mutable && own_variable?(element(node.receiver), names, depth)
          when Prism::CallNode
            return true if mutable && own_variable?(element(node.receiver), names, depth) && (node.block || mutator?(node.name))
          end
          inner = node.is_a?(Prism::BlockNode) || node.is_a?(Prism::LambdaNode) ? depth + 1 : depth
          node.compact_child_nodes.any? do |child|
            changes_variable?(child, names, inner, kept: mutable && keeps?(node, child, kept), mutable: mutable)
          end
        end

        def own_variable?(node, names, depth)
          (node.is_a?(Prism::LocalVariableReadNode) || VARIABLE_WRITES.include?(node.class)) && names.include?(node.name) && node.depth == depth
        end

        # The object a call such as `x.to_s` or `x.presence` hands back: its receiver.
        def element(node)
          node = node.receiver while node.is_a?(Prism::CallNode) && node.receiver && !node.block && InitializerSettings::ELEMENT_SELF.include?(node.name)
          node
        end

        def mutator?(name)
          name.end_with?("!") || STRING_MUTATORS.include?(name)
        end

        # Whether `child`'s value is kept where its variable can be changed: a write's value, an argument to `yield`,
        # to a lambda, to a collection's mutator or to a method of this file that changes its own, a list a block
        # runs over, or inside a list, hash or branch that is.
        def keeps?(parent, child, kept)
          case parent
          when Prism::CallNode
            return !parent.block.nil? || (kept && InitializerSettings::ELEMENT_SELF.include?(parent.name)) if child.equal?(parent.receiver)
            return false unless child.equal?(parent.arguments)

            definitions = @methods[parent.name] if parent.receiver.nil?
            return definitions.any? { |definition| changes_arguments?(definition) } if definitions

            parent.receiver && (parent.name == :call || parent.attribute_write? || HOLDING_MUTATORS.include?(parent.name))
          when Prism::YieldNode, Prism::SuperNode then child.equal?(parent.arguments)
          when Prism::MatchRequiredNode, Prism::MatchPredicateNode then child.equal?(parent.value)
          when *HOLDERS then kept
          when *AstWalk::VALUE_WRITES then child.equal?(parent.value)
          end
        end

        # Whether a method of this file may change an argument it is given; one it is still being asked about may.
        def changes_arguments?(definition)
          @changes_arguments ||= {}.compare_by_identity
          return @changes_arguments[definition] if @changes_arguments.key?(definition)

          @changes_arguments[definition] = true
          params = definition.parameters&.compact_child_nodes || []
          names = params.map { |param| param.name if param.respond_to?(:name) }
          @changes_arguments[definition] = names.include?(nil) || changes_variable?(definition.body, names)
        end

        # Ruby runs the block once per element: the first pass is this walk, the others replay it on leave.
        # A block it cannot unroll is walked once, its variable unknown.
        def enter_loop(node)
          list = node.receiver
          return enter_repeat(node) unless list.is_a?(Prism::ArrayNode) && list.elements.all? { |e| e.is_a?(Prism::StringNode) || e.is_a?(Prism::SymbolNode) }

          register_statements(node.block.body)
          return push_frame(node, suppress: true) if list.elements.empty?
          return push_frame(node, repeats: true) unless unrolls?(node)

          values = list.elements.map { |e| literal_or_bound(e) }
          push_frame(node, loop: values, **loop_bindings(node, values.first, 0))
        end

        def finish_loop(node)
          @stack.pop[:loop].each_with_index.drop(1).each do |value, index|
            push_frame(node, **loop_bindings(node, value, index))
            replay_dispatcher.dispatch(node.block)
            @stack.pop
          end
        end

        def loop_bindings(node, value, index)
          names = node.block.parameters.parameters.requireds.map(&:name)
          { bindings: names.zip([ value, index ]).to_h, block: node.block }
        end

        def extract_value(node, source: false)
          value = bound_value(node)
          value.nil? ? super : value
        end

        def extract_symbol_args(node)
          (node.arguments&.arguments || []).filter_map { |a| literal_or_bound(a)&.to_sym }
        end

        def call_method_or_count(node)
          definitions = @methods[node.name]
          key = "def #{node.name}"
          # A gem macro's configuration until its block turns out to draw routes.
          outer = open_unknown_block if definitions.nil?
          return (outer[:pending] << node unless suppressed?) if outer
          return emit_dynamic(node) if definitions.nil? || node.arguments || @replaying.include?(key) || definitions.any? { |d| takes_arguments?(d) }
          return if suppressed?

          each_in_force(definitions) do |definition|
            replaying(key, definition) do
              register_statements(definition.body)
              replay_dispatcher.dispatch(definition.body) if definition.body
            end
          end
        end

        # Rails runs after_initialize hooks before it draws the routes (7.0 to 8.1).
        def after_initialize?(node)
          return false unless node.block.is_a?(Prism::BlockNode)

          hook = node.arguments&.arguments&.first
          node.name == :after_initialize || (node.name == :on_load && hook.is_a?(Prism::SymbolNode) && hook.unescaped == "after_initialize")
        end

        def register_table_changes(body)
          return unless body.is_a?(Prism::StatementsNode)

          body.body.each { |statement| @statements[statement] = true if late_table_change?(statement, false) }
        end

        # A `routes.prepend` inside any other hook may register after the draw, which
        # Rails evaluates only on the next reload.
        def late_table_change?(node, statement)
          !statement && node.is_a?(Prism::CallNode) && %i[append prepend].include?(node.name) && node.block &&
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
          app = mounted_app_node(node)
          !app.nil? && !app_name(app).nil?
        end

        # `mount App, at:` or `mount App => path`.
        def mounted_app_node(node)
          first = node.arguments&.arguments&.first
          first.is_a?(Prism::KeywordHashNode) || first.is_a?(Prism::HashNode) ? first.elements.first&.key : first
        end

        # Rails names a mount like a route, its `as:` or its app's name, so a later route cannot take the name.
        # shortcut: a module app takes no name and is read as a class here, read the app's file if one collides.
        def take_mount_name(node)
          return if suppressed?

          options = route_options(node)
          return if options.key?(:as) && !options[:as] && !@before_8_1

          as = name_or_marker(options[:as]) || mounted_class_name(mounted_app_node(node))&.then { |app| @mount_name.call(app) }
          name = as && verb_route_name(as, nil, nil)
          @taken_names.add([ current_engine, name ]) if name && !name.include?(RailsAiContext::Confidence::INFERRED)
        end

        # The class a mount attaches, as app_name names it; an instance (`Rack::Builder.new`, `App.new`, `ActionCable.server`)
        # has no name for Rails to give, while Ruby names a `Class.new` after its constant.
        def mounted_class_name(app)
          value = written_value(app)
          receiver = value.receiver if value.is_a?(Prism::CallNode) && value.name == :new
          built_class = (receiver.is_a?(Prism::ConstantReadNode) || receiver.is_a?(Prism::ConstantPathNode)) && constant_path_string(receiver) == "Class"
          app_name(app) if built_class || !value.is_a?(Prism::CallNode)
        end

        # `Shop::Core::Engine.routes.draw` adds to the engine's table, controllers under its
        # namespace (shop/admin/orders); the app's own `X::Application.routes.draw` is no engine.
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
        # rest to the mapper, as an app's ApiRouteSet does; read its `route` if an app's differs.
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

        # The app's config.api_only reaches its own route set only: an engine's
        # table, or a route set class the app draws, keeps its own setting.
        def api_only_table?
          @api_only && @stack.none? { |f| f[:engine] || f[:route_set] }
        end

        # The controller a route without one of its own takes: the innermost
        # `scope(controller:)` or resource, else Rails' module path alone.
        def current_controller
          frame = @stack.reverse.find { |f| f[:controller] || f[:resource] }
          return prefixed_controller(frame[:resource][:controller]) if frame && !frame[:controller]

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

        # `bin/rails routes`' defaults then segment constraints; scope options win, as Mapping merges them.
        def route_constraints(node, path)
          route_level = ROUTE_LEVEL.include?(node.name)
          scopes = @stack.reject { |f| f[:node].equal?(node) }.filter_map { |f| f[:route_constraints] }
          own = node_constraints(node) || {}
          scopes << own unless route_level || own.empty?
          own = {} unless route_level
          defaults = (own[:url] || {}).merge(scopes.map { |c| c[:url].merge(c[:defaults]) }.reduce({}, :merge)).merge(own[:defaults] || {})
          defaults = defaults.merge(scopes.map { |c| c[:options] }.reduce({}, :merge)).merge(own[:options] || {})
          params = RouteCoverage.path_params(path) << "format"
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
          if node.name == :constraints && mapper_call?(node)
            read_constraint_hash(hash, found)
          elsif node.name == :defaults && mapper_call?(node)
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
            n.is_a?(Prism::CallNode) && mapper_call?(n) && OPTION_CARRIERS.include?(n.name)
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
          @concern_blocks[name.to_s] = definitions_in_force(@concern_blocks[name.to_s], node.block, @blocks.dup) if name
          push_frame(node, suppress: true, unplaced: true, held: node.block)
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
            blocks = @concern_blocks[key]
            # A concern defined in another drawn file, or one that names
            # itself, has no body this walk can replay; the marker keeps it
            # counted instead of dropping its routes silently.
            if blocks.nil? || @replaying.include?(key)
              emit_dynamic(node, macro: :concerns)
              next
            end

            each_in_force(blocks) do |block|
              replaying(key, block) do
                register_statements(block.body)
                replay_dispatcher.dispatch(block)
              end
            end
          end
        end

        # A later definition under only an earlier one's branches replaces it; under one other if/unless, the earlier one holds where it did not run.
        # shortcut: a case, a guard or nested ifs give the earlier one no opposite condition, negate them if a routes file needs it.
        def definitions_in_force(earlier, definition, blocks)
          conditions = branch_conditions.map(&:dup)
          @written_under[definition] = [ blocks, conditions ]
          (earlier || []).reject do |other|
            kept = @written_under[other].last
            texts = kept.map { |o| branch_text(o) }
            unstated = conditions.reject { |c| texts.include?(branch_text(c)) }
            opposite = unstated.first.slice(:node, :keyword).merge(negated: !unstated.first[:negated]) if unstated.one? && !unstated.first[:text]
            kept << opposite if opposite && !texts.include?(branch_text(opposite))
            unstated.empty?
          end << definition
        end

        # One definition in force runs, so each takes names from those taken before the site.
        def each_in_force(definitions)
          before = @taken_names.dup
          after = Set.new
          definitions.each do |definition|
            @taken_names.replace(before)
            yield definition
            after.merge(@taken_names)
          end
          @taken_names.replace(after)
        end

        # Walks `definition`'s body under `key`, which a body naming itself finds taken, in the block scopes and
        # branches it is written in.
        def replaying(key, definition)
          @replaying.push(key)
          @replayed << definition
          walkers = [ self, *@joined ]
          walking_in = walkers.map { |walker| walker.enter_replay(*@written_under[definition]) }
          yield
        ensure
          @replaying.pop
          walkers.zip(walking_in) { |walker, left| walker.leave_replay(left) }
        end

        def replay_dispatcher
          @replay_dispatcher ||= ListenerRegistration.dispatcher_for(self, *@joined)
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
          opts = route_options(node)
          if name.nil? || unreadable_scope?(opts)
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

          path = (opts[:path] || name).to_s
          as = (opts[:as] || name).to_s
          # Rails wraps a namespace drawn in a resource's own scope in `nested`.
          push_frame(node,
                     nested: resource_scope?,
                     prefix: join_path(current_prefix, path),
                     mod: (opts[:module] || name).to_s,
                     name_prefix: as,
                     shallow_path: join_path(current_shallow_path, (literal_option(opts[:shallow_path]) || path).to_s),
                     shallow_prefix: join_names(current_shallow_prefix, (name_or_marker(opts[:shallow_prefix]) || as).to_s))
        end

        def enter_scope(node)
          return unless node.block

          opts = route_options(node)
          first = literal_first_arg(node)
          # Rails' scope takes a positional path over `path:`.
          if unreadable_scope?(first ? opts.except(:path) : opts) || (first.nil? && positional_prefix?(node))
            emit_dynamic(node)
            return push_frame(node, suppress: true)
          end

          path = (first || opts[:path])&.to_s
          shallow_path = (literal_option(opts[:shallow_path]) || path)&.to_s
          shallow_prefix = (name_or_marker(opts[:shallow_prefix]) || name_or_marker(opts[:as]))&.to_s
          frame = { prefix: path ? join_path(current_prefix, path) : current_prefix,
                    mod: opts[:module]&.to_s,
                    name_prefix: opts[:as]&.to_s,
                    controller: opts[:controller]&.to_s,
                    via: opts[:via],
                    path_names: path_names_option(opts) }
          frame[:shallow_path] = join_path(current_shallow_path, shallow_path) if shallow_path
          frame[:shallow_prefix] = join_names(current_shallow_prefix, shallow_prefix) if shallow_prefix
          frame[:shallow] = opts[:shallow] == true if opts.key?(:shallow)
          frame.merge!(scoped_resource(scope_level, path, opts[:as]&.to_s)) if resource_scope?
          push_frame(node, **frame)
        end

        # A path, module or shallow: the walk cannot read moves every route under it somewhere it cannot say.
        def unreadable_scope?(opts)
          opts.values_at(:path, :module, :shallow_path, :shallow).include?(RailsAiContext::Confidence::INFERRED)
        end

        # The frame that sets Rails' scope level: a member, collection, new or nested block, or a resource.
        def scope_level
          @stack.reverse.find { |f| f[:kind] || f[:resource] || f[:nested] }
        end

        def canonical_action?(segment, on_option)
          CANONICAL_ACTIONS.include?(segment.to_s) && !current_resource.nil? && !member_collection_kind(on_option).nil?
        end

        def resource_scope?
          !scope_level&.dig(:resource).nil?
        end

        # Rails runs a resource's block at the path and name outside the resource, so a scope
        # opened there comes before the resource's own path and name. Its member routes and
        # nested scope start from the shallow path and prefix when the resource is shallow.
        def scoped_resource(level, path, as)
          resource = level[:resource]
          outer = scope_outer(resource[:outer_prefix], resource[:outer_name], path, as)
          member = scope_outer(resource[:member_outer_prefix], resource[:member_outer_name], path, as)
          moved = resource.merge(outer_prefix: outer[:prefix], outer_name: outer[:name],
                                 member_outer_prefix: member[:prefix], member_outer_name: member[:name],
                                 base: outer[:move].(resource[:base]), new_path: outer[:move].(resource[:new_path]),
                                 member_path: member[:move].(resource[:member_path]),
                                 new_route_name: outer[:rename].(resource[:new_route_name]),
                                 plural_route_name: outer[:rename].(resource[:plural_route_name]),
                                 singular_route_name: member[:rename].(resource[:singular_route_name]))
          { prefix: member[:move].(level[:prefix]), name_prefix: join_names(member[:name], resource[:key]), name_root: true,
            resource: moved }
        end

        def scope_outer(prefix, name, path, as)
          inner = path ? join_path(prefix, path) : prefix
          inner_name = join_names(name, as)
          { prefix: inner, name: inner_name,
            move: ->(p) { join_path(inner, p.delete_prefix(prefix)) },
            rename: ->(n) { join_names(inner_name, name ? n.delete_prefix("#{name}_") : n) } }
        end

        def handle_resources(node, singular:)
          return if suppressed?
          # A route set's class defines its own `resources`.
          return emit_dynamic(node) if current_route_set

          names = extract_symbol_args(node)
          if names.empty? || opaque_options?(node) || unreadable_scope?(route_options(node))
            emit_dynamic(node)
            # Same reasoning as the namespace case: a block we can't attach
            # resource info to still opens a nested scope, so its children
            # must be suppressed rather than resolved against the outer
            # prefix and misreported as verified routes.
            push_frame(node, suppress: true, unplaced: true) if node.block
            return
          end

          opts = route_options(node)
          names = names.map(&:to_s)
          return names.each { |name| draw_resource(node, name, opts, singular: singular) } unless node.block

          push_resource_frame(node, names.first, opts, singular: singular)
          @stack.last[:draw] = { names: names, opts: opts, singular: singular }
        end

        # Rails' resources yields the block, then replays the concerns, then draws its own routes,
        # all of it once per name.
        def finish_resources(node)
          draw = @stack.last[:draw]
          close_resource(node, draw[:names].first, draw[:opts], singular: draw[:singular])
          draw[:names].drop(1).each { |name| draw_resource(node, name, draw[:opts], singular: draw[:singular], block: node.block) }
        end

        def draw_resource(node, name, opts, singular:, block: nil)
          push_resource_frame(node, name, opts, singular: singular)
          replay_dispatcher.dispatch(block) if block
          close_resource(node, name, opts, singular: singular)
        end

        def close_resource(node, name, opts, singular:)
          concerns = Array(opts[:concerns])
          replay_concerns(concerns, node) if concerns.any?
          @stack.pop
          emit_resource_routes(node, name, opts, singular: singular)
        end

        # Routes nested under this resource inherit its singular route key as a
        # name prefix (resources :posts { resources :comments } -> the comments
        # index route is named "post_comments", not "comments"). A shallow
        # resource nests its children under the shallow path and prefix alone.
        def push_resource_frame(node, name, opts, singular:)
          layout = resource_layout(name, opts, singular: singular)
          outer_name = current_name_prefix
          outer_prefix = current_prefix
          shallow_prefix = resource_shallow_prefix(opts)
          member_outer_name = layout[:shallow] ? shallow_prefix : outer_name
          member_outer_prefix = layout[:shallow] ? resource_shallow_path(opts) : outer_prefix
          frame = {
            prefix: layout[:nested_prefix],
            mod: opts[:module]&.to_s,
            name_prefix: layout[:shallow] ? join_names(shallow_prefix, layout[:key]) : layout[:key],
            name_root: layout[:shallow],
            path_names: path_names_option(opts),
            resource: {
              name: name,
              singular: singular,
              # Its routes take the modules on the stack where they are drawn, the resource's own module: among them.
              controller: resource_controller_name(name, opts, singular: singular),
              base: layout[:base],
              member_path: layout[:member_path],
              new_path: layout[:new_path],
              singular_route_name: layout[:member_name],
              new_route_name: layout[:singular_name],
              plural_route_name: layout[:plural_name],
              outer_name: outer_name,
              outer_prefix: outer_prefix,
              member_outer_name: member_outer_name,
              member_outer_prefix: member_outer_prefix,
              key: layout[:key],
              collection_key: collection_route_key(name, opts, singular: singular)
            }
          }
          frame[:shallow] = opts[:shallow] == true if opts.key?(:shallow)
          frame[:shallow_path] = resource_shallow_path(opts) if opts.key?(:shallow_path)
          frame[:shallow_prefix] = shallow_prefix if opts.key?(:shallow_prefix)
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
          actions = requested_actions(singular ? SINGULAR_ACTIONS : PLURAL_ACTIONS, opts, api_only: api_only_table?)

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

        # Shallow member routes drop the parents' paths and names; a singleton is never shallow.
        def resource_layout(name, opts, singular:)
          path = (opts[:path] || name).to_s
          base = join_path(current_prefix, path)
          key = singular_route_key(name, opts, singular: singular)
          param = resource_param(opts)
          path_names = current_path_names.merge(path_names_option(opts))
          shallow = !singular && (opts.key?(:shallow) ? opts[:shallow] == true : current_shallow)
          shallow_base = join_path(resource_shallow_path(opts), path)
          member = singular ? base : join_path(shallow ? shallow_base : base, ":#{param}")
          {
            base: base,
            key: key,
            shallow: shallow,
            member_path: member,
            edit_path: join_path(member, (path_names[:edit] || "edit").to_s),
            new_path: join_path(base, (path_names[:new] || "new").to_s),
            nested_prefix: singular ? base : join_path(shallow ? shallow_base : base, ":#{key}_#{param}"),
            singular_name: route_name_for(key),
            member_name: shallow ? join_names(resource_shallow_prefix(opts), key) : route_name_for(key),
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

        # Rails draws a resource inside a scope of its own shallow_path: and shallow_prefix:.
        def resource_shallow_path(opts)
          path = literal_option(opts[:shallow_path])
          path ? join_path(current_shallow_path, path.to_s) : current_shallow_path
        end

        def resource_shallow_prefix(opts)
          join_names(current_shallow_prefix, name_or_marker(opts[:shallow_prefix]))
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

        # A name the source spells out, or the INFERRED marker a held one leaves, which the names built on it carry.
        def name_or_marker(value)
          value if value.is_a?(String) || value.is_a?(Symbol)
        end

        def join_names(*parts)
          joined = parts.compact.map(&:to_s).reject(&:empty?).join("_")
          joined unless joined.empty?
        end

        # Options the source does not spell out: `resources :x, opts`, `**splat`, a computed only:/except:.
        def opaque_options?(node)
          (node.arguments&.arguments || []).any? do |arg|
            case arg
            when Prism::KeywordHashNode, Prism::HashNode
              arg.elements.any? { |assoc| !assoc.is_a?(Prism::AssocNode) || opaque_action_list?(assoc) }
            else literal_or_bound(arg).nil?
            end
          end
        end

        def opaque_action_list?(assoc)
          return false unless %i[only except].include?(extract_key(assoc.key))

          values = assoc.value.is_a?(Prism::ArrayNode) ? assoc.value.elements : [ assoc.value ]
          !values.all? { |v| literal_or_bound(v) }
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

        # `app:` is a route to a Rack app, which MountListener lists: the walk only takes its name.
        def emit_verb_route(node, app: false)
          return if suppressed?

          kept = @results.size
          emit_verb_route!(node)
          @results.slice!(kept..) if app
        end

        def emit_verb_route!(node)
          opts = route_options(node)
          via = opts.key?(:via) ? opts[:via] : @stack.reverse.find { |f| f[:via] }&.dig(:via)
          verb = node.name == :match ? match_verb(via) : node.name.to_s.upcase
          return emit_dynamic(node) if verb.nil? || opaque_options?(node)

          rocket_key = opts.keys.find { |k| k.is_a?(String) }
          return emit_dynamic(node) if !@before_8_1 && (node.arguments&.arguments || []).count { |a| !a.is_a?(Prism::KeywordHashNode) && !a.is_a?(Prism::HashNode) } > 1

          paths = literal_paths(node)
          paths = [ [ rocket_key, false ] ] if paths.empty? && rocket_key
          return emit_dynamic(node) if paths.empty?

          paths.each { |segment, action| emit_verb_path(node, verb, segment, action, opts, rocket_key) }
        end

        # Rails 7.x and 8.0 draw every path of `get "/a", "/b"`, strings before symbols.
        # @return [Array<[String, Boolean]>] each path, and whether it names an action
        def literal_paths(node)
          args = (node.arguments&.arguments || []).filter_map { |a| literal_or_bound(a) }
          args.partition { |a| a.is_a?(String) }.flatten.map { |a| [ a.to_s, a.is_a?(Symbol) ] }
        end

        def emit_verb_path(node, verb, segment, action_given, opts, rocket_key)
          # Rails' match reads `path => :action` as the action and `path => "controller"` as the controller.
          rocket = rocket_key && opts[rocket_key]
          if rocket.is_a?(Symbol) || (rocket.is_a?(String) && !rocket.include?("#") && rocket != RailsAiContext::Confidence::INFERRED)
            opts = opts.except(rocket_key)
            opts[rocket.is_a?(Symbol) ? :action : :controller] ||= rocket
            rocket_key = nil
          end

          target_given = opts.key?(:to) || !rocket_key.nil?
          target = opts[:to] || (rocket_key && opts[rocket_key])

          route_set = current_route_set unless node.name == :match
          if route_set
            segment = "#{route_set[:prefix]}/#{segment}"
            # The class passes `as: nil` when none is given, and Rails generates no name then.
            as = opts[:as] && "#{route_set[:name_prefix]}#{opts[:as]}"
          end
          # A member and a collection route sit at different paths, and a constant on: names neither.
          return emit_dynamic(node) if opts[:on] == RailsAiContext::Confidence::INFERRED

          name = route_set ? as && verb_route_name(as, segment, opts[:on]) : verb_route_name(opts[:as], segment, opts[:on])
          if target_given && unreadable_target?(target)
            # Rails names a route to a redirect or a Rack app like any other, so a later route cannot take the name.
            @taken_names.add([ current_engine, name ]) if name && !name.empty? && !name.include?(RailsAiContext::Confidence::INFERRED)
            return emit_dynamic(node)
          end

          controller, action = resolve_target(target, segment, opts)
          return emit_dynamic(node) unless controller && action
          # Rails maps an action given as a symbol through path_names, unless `path:` names its path; a string is the path.
          option_path = opts[:path] if action_given && !route_set
          return emit_dynamic(node) if option_path && !literal_option(option_path)

          path = option_path&.to_s
          path ||= if !action_given then segment
          elsif canonical_action?(segment, opts[:on]) then ""
          else (current_path_names[segment.to_sym] || segment).to_s
          end
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
          # Rails' member, collection and new scopes add the resource's path and none of its name.
          push_frame(node, prefix: prefix, kind: kind, name_prefix: resource[kind == :member ? :member_outer_name : :outer_name], name_root: true)
        end

        # The member/collection frame a verb route sits in, if any - either
        # from an enclosing member/collection block or an explicit on: keyword.
        # Rails draws a bare verb in a singular resource as a member route.
        def member_collection_kind(on_option)
          return on_option.to_sym if on_option

          frame = scope_level
          return unless frame

          frame[:kind] || (:member if frame[:resource]&.dig(:singular))
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
            # A controller or action the walk could not read leaves the route a guess.
            confidence: inferred_target?(controller, action) ? RailsAiContext::Confidence::INFERRED : confidence_for(node)
          }
          engine = current_engine
          # An engine's table keeps its own names.
          record[:name] = name if name && !name.empty? && (name.include?(RailsAiContext::Confidence::INFERRED) || @taken_names.add?([ engine, name ]))
          record[:engine] = engine if engine
          condition = current_condition
          record[:condition] = condition if condition
          record[:prepend] = true if @stack.any? { |f| f[:prepend] }
          record[:late] = true if @stack.any? { |f| f[:late] }
          constraints = route_constraints(node, path)
          record[:constraints] = constraints if constraints
          params = RouteCoverage.path_params(path)
          record[:params] = params if params.any?
          record[:restful] = RouteCoverage::RESTFUL_ACTIONS.include?(record[:action])
          @results << record
        end

        # `admin/[INFERRED]` too: a namespace prefixes what it could not read.
        def inferred_target?(controller, action)
          "#{controller}##{action}".include?(RailsAiContext::Confidence::INFERRED)
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
            record[:scope] = @stack.map { |frame| frame.except(:node, :loop, :bindings, :block) }
            record[:prefix] = current_prefix
            record[:name_prefix] = current_name_prefix
          end
          @results << record
        end

        def draw_target(node)
          literal_or_bound(node.arguments&.arguments&.first)&.to_sym
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

            key = literal_or_bound(assoc.key)
            next unless key

            # Rails reads a constant's value (`path: PREFIX`); the walk sees only its name, or for a route target the string the file assigns it.
            value = key == :to || key.is_a?(String) ? written_value(assoc.value) : assoc.value
            constant = value.is_a?(Prism::ConstantReadNode) || value.is_a?(Prism::ConstantPathNode)
            acc[key] = constant && key != :to ? RailsAiContext::Confidence::INFERRED : extract_value(value)
          end
        end

        # First positional argument when it is a plain symbol/string literal.
        def literal_first_arg(node)
          arg = node.arguments&.arguments&.first
          literal_or_bound(arg)&.to_s if arg
        end

        # Rails' Resource#default_actions: an api_only route set leaves out new
        # and edit, unless `only:` asks for them by name.
        def requested_actions(all, opts, api_only: false)
          actions = all
          actions -= %i[new edit] if api_only && !opts[:only]
          actions &= Array(opts[:only]).map(&:to_sym) if opts[:only]
          actions -= Array(opts[:except]).map(&:to_sym) if opts[:except]
          actions
        end

        # Rails maps a singular resource to the plural controller
        # (resource :profile -> ProfilesController). `module:` is not a
        # resource option there: Rails peels it into a surrounding scope, so it
        # moves the controller and never the path.
        def resource_controller(name, opts, singular: false)
          controller = resource_controller_name(name, opts, singular: singular)
          return controller.delete_prefix("/") if controller.start_with?("/")

          controller = "#{opts[:module]}/#{controller}" if opts[:module]
          prefixed_controller(controller)
        end

        def resource_controller_name(name, opts, singular:)
          (opts[:controller] || (singular ? name.pluralize : name)).to_s
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
            resource_key = if scope_level[:kind]
              # In a member, collection or new block the name takes the scope's `as:` as it stands there.
              named = join_names(current_name_prefix, kind == :collection ? resource[:collection_key] : resource[:key])
              kind == :new ? "new_#{named}" : named
            else
              { member: resource[:singular_route_name], new: "new_#{resource[:new_route_name]}" }
                .fetch(kind, resource[:plural_route_name])
            end
            return nil if resource_key.nil? || resource_key.empty?
            return resource_key if !as_option && canonical_action?(segment, on_option)

            base = as_option ? as_option.to_s : plain_segment_name(segment)
            return base && "#{base}_#{resource_key}"
          end

          return route_name_for(as_option.to_s) if as_option

          segment_name = plain_segment_name(segment)
          # Mapper#name_for_action: under a parent resource, no `as:` and no nameable path gives no name.
          return nil if segment_name.nil? && resource

          generated_name(route_name_for(segment_name))
        end

        # Rails converts the hyphens of a path-derived name to underscores
        # (`api_v1_gift_cards_redeem`), and uses no part of the path at all
        # when the path carries a character outside [\w\-/], such as the dot
        # of `.well-known`. Then it drops the whole generated name when the
        # result does not start with a letter or an underscore.
        UNNAMEABLE_PATH = %r{[^\w\-/]}
        NAMEABLE = /\A[_a-z]/i

        def plain_segment_name(segment)
          plain = segment.to_s.squeeze("/").delete_prefix("/").delete_suffix("/")
          return nil if plain.empty? || plain.include?(":") || plain.match?(UNNAMEABLE_PATH)

          plain.tr("/", "_").tr("-", "_")
        end

        # A name under an `as:` the walk could not read stays, marked: Rails names it after the value.
        def generated_name(name)
          name if name&.match?(NAMEABLE) || name&.start_with?(RailsAiContext::Confidence::INFERRED)
        end

        def join_path(*segments)
          cleaned = segments.compact.map { |s| s.to_s.gsub(%r{\A/+|/+\z}, "") }.reject(&:empty?)
          normalize_route_path("/#{cleaned.join('/')}")
        end
      end
    end
  end
end
