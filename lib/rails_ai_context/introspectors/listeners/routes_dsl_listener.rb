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
      # :dynamic markers rather than guessed at. Leading-slash paths and
      # constraints are simplified: paths anchor at the accumulated prefix,
      # constraints are ignored.
      class RoutesDslListener < BaseListener
        VERB_METHODS = %i[get post put patch delete].freeze
        PLURAL_ACTIONS = %i[index create new edit show update destroy].freeze
        SINGULAR_ACTIONS = %i[create new edit show update destroy].freeze
        RESTFUL_ACTIONS = %w[index show new create edit update destroy].freeze
        DYNAMIC_MACROS = %i[devise_for draw direct resolve match].freeze

        def initialize
          super
          @stack = []
          @concern_blocks = {}
          @replaying = []
        end

        def on_call_node_enter(node)
          return unless node.receiver.nil?

          case node.name
          when :namespace then enter_namespace(node)
          when :scope then enter_scope(node)
          when :resources then handle_resources(node, singular: false)
          when :resource then handle_resources(node, singular: true)
          when :member then enter_member_collection(node, :member)
          when :collection then enter_member_collection(node, :collection)
          when :concern then define_concern(node)
          when :concerns then apply_concerns(node)
          when :with_options then enter_with_options(node)
          when :root then emit_root(node)
          when *VERB_METHODS then emit_verb_route(node)
          when *DYNAMIC_MACROS then emit_dynamic(node)
          end
        end

        def on_call_node_leave(node)
          @stack.pop if @stack.last && @stack.last[:node].equal?(node)
        end

        private

        def push_frame(node, **attrs)
          @stack << { node: node }.merge(attrs)
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
            replay_dispatcher.dispatch(block)
            @replaying.pop
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
          push_frame(node,
                     prefix: join_path(current_prefix, (opts[:path] || name).to_s),
                     mod: (opts[:module] || name).to_s,
                     name_prefix: (opts[:as] || name).to_s)
        end

        def enter_scope(node)
          return unless node.block

          opts = route_options(node)
          first = literal_first_arg(node)
          path = (first || opts[:path])&.to_s
          push_frame(node,
                     prefix: path ? join_path(current_prefix, path) : current_prefix,
                     mod: opts[:module]&.to_s,
                     name_prefix: opts[:as]&.to_s)
        end

        def handle_resources(node, singular:)
          return if suppressed?

          names = extract_symbol_args(node)
          if names.empty?
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
        # index route is named "post_comments", not "comments").
        def push_resource_frame(node, name, opts, singular:)
          base = join_path(current_prefix, (opts[:path] || name).to_s)
          key = singular_route_key(name, opts, singular: singular)
          param = resource_param(opts)
          push_frame(node,
                     prefix: singular ? base : "#{base}/:#{key}_#{param}",
                     mod: opts[:module]&.to_s,
                     name_prefix: key,
                     resource: {
                       name: name,
                       singular: singular,
                       controller: resource_controller(name, opts, singular: singular),
                       base: base,
                       member_path: member_path(base, singular, param),
                       singular_route_name: route_name_for(key),
                       plural_route_name: route_name_for(route_key(name, opts))
                     })
        end

        def emit_resource_routes(node, name, opts, singular:)
          base = join_path(current_prefix, (opts[:path] || name).to_s)
          controller = resource_controller(name, opts, singular: singular)
          actions = requested_actions(singular ? SINGULAR_ACTIONS : PLURAL_ACTIONS, opts)
          param = resource_param(opts)
          plural_name = route_name_for(route_key(name, opts))
          singular_name = route_name_for(singular_route_key(name, opts, singular: singular))

          actions.each do |action|
            case action
            when :index   then emit(node, "GET", base, controller, "index", plural_name)
            when :create  then emit(node, "POST", base, controller, "create", singular ? singular_name : plural_name)
            when :new     then emit(node, "GET", "#{base}/new", controller, "new", "new_#{singular_name}")
            when :edit    then emit(node, "GET", edit_path(base, singular, param), controller, "edit", "edit_#{singular_name}")
            when :show    then emit(node, "GET", member_path(base, singular, param), controller, "show", singular_name)
            when :update
              emit(node, "PATCH", member_path(base, singular, param), controller, "update", nil)
              emit(node, "PUT", member_path(base, singular, param), controller, "update", nil)
            when :destroy then emit(node, "DELETE", member_path(base, singular, param), controller, "destroy", nil)
            end
          end
        end

        # `as:` renames the route helpers and the nested param, and leaves the
        # path and the controller on the resource's own name.
        def route_key(name, opts)
          (opts[:as] || name).to_s
        end

        def singular_route_key(name, opts, singular:)
          key = route_key(name, opts)
          singular ? key : key.singularize
        end

        def resource_param(opts)
          (opts[:param] || "id").to_s
        end

        def member_path(base, singular, param)
          singular ? base : "#{base}/:#{param}"
        end

        def edit_path(base, singular, param)
          singular ? "#{base}/edit" : "#{base}/:#{param}/edit"
        end

        def emit_verb_route(node)
          return if suppressed?

          opts = route_options(node)
          segment = literal_first_arg(node)&.to_s
          rocket_key = opts.keys.find { |k| k.is_a?(String) }
          segment ||= rocket_key
          return emit_dynamic(node) unless segment

          target_given = opts.key?(:to) || !rocket_key.nil?
          target = opts[:to] || (rocket_key && opts[rocket_key])
          return emit_dynamic(node) if target_given && unreadable_target?(target)

          controller, action = resolve_target(target, segment)
          return emit_dynamic(node) unless controller && action

          emit(node, node.name.to_s.upcase, verb_route_path(segment, opts[:on]),
               controller, action, verb_route_name(opts[:as], segment, opts[:on]))
        end

        # member/collection blocks push their own prefix, so inside them the
        # general prefix already points at the right base; only the explicit
        # on: keyword needs special handling.
        def enter_member_collection(node, kind)
          return unless node.block

          resource = current_resource
          return unless resource

          prefix = kind == :member ? resource[:member_path] : resource[:base]
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
            base = on_option.to_sym == :member ? resource[:member_path] : resource[:base]
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

        def resolve_target(target, segment)
          if target.is_a?(String) && target.include?("#")
            controller, action = target.split("#", 2)
            [ prefixed_controller(controller), action ]
          elsif current_resource
            [ current_resource[:controller], segment.delete_prefix("/") ]
          else
            parts = segment.delete_prefix("/").split("/")
            return [ nil, nil ] if parts.size < 2

            [ prefixed_controller(parts[0..-2].join("/")), parts.last ]
          end
        end

        def emit_root(node)
          return if suppressed?

          target = literal_first_arg(node)&.to_s || route_options(node)[:to]
          return emit_dynamic(node) unless target.is_a?(String) && target.include?("#")

          controller, action = target.split("#", 2)
          emit(node, "GET", current_prefix, prefixed_controller(controller), action,
               [ current_name_prefix, "root" ].compact.reject(&:empty?).join("_"))
        end

        def emit(node, verb, path, controller, action, name)
          record = {
            type: :route,
            verb: verb,
            path: path,
            controller: controller,
            action: action.to_s,
            location: node.location.start_line,
            confidence: confidence_for(node)
          }
          record[:name] = name if name && !name.empty?
          params = path.scan(/:(\w+)/).flatten
          record[:params] = params if params.any?
          record[:restful] = RESTFUL_ACTIONS.include?(record[:action])
          @results << record
        end

        def emit_dynamic(node, macro: node.name)
          return if suppressed?

          record = { type: :dynamic, macro: macro, location: node.location.start_line }
          # `draw(:admin)` names a file, and Rails resolves it by literal path.
          # Recording the name is what lets the introspector follow it instead
          # of writing off everything the file defines.
          record[:target] = draw_target(node) if macro == :draw
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
          controller = (opts[:controller] || (singular ? name.pluralize : name)).to_s.delete_prefix("/")
          controller = "#{opts[:module]}/#{controller}" if opts[:module]
          prefixed_controller(controller)
        end

        def prefixed_controller(controller)
          controller = controller.delete_prefix("/")
          mods = @stack.filter_map { |f| f[:mod] }
          ([ *mods, controller ] - [ "" ]).join("/")
        end

        def current_name_prefix
          parts = @stack.filter_map { |f| f[:name_prefix] }
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
            resource_key = kind == :member ? resource[:singular_route_name] : resource[:plural_route_name]
            base = as_option ? as_option.to_s : plain_segment_name(segment)
            return nil unless base && resource_key && !resource_key.empty?

            return "#{base}_#{resource_key}"
          end

          return route_name_for(as_option.to_s) if as_option

          plain = plain_segment_name(segment)
          plain ? route_name_for(plain) : nil
        end

        def plain_segment_name(segment)
          plain = segment.to_s.delete_prefix("/").tr("/", "_")
          plain.empty? || plain.include?(":") ? nil : plain
        end

        def join_path(*segments)
          cleaned = segments.compact.map { |s| s.to_s.gsub(%r{\A/+|/+\z}, "") }.reject(&:empty?)
          "/#{cleaned.join('/')}"
        end
      end
    end
  end
end
