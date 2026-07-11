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
        DYNAMIC_MACROS = %i[devise_for draw direct resolve concerns match].freeze

        def initialize
          super
          @stack = []
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
          when :concern then push_frame(node, suppress: true) if node.block
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

        def enter_namespace(node)
          name = literal_first_arg(node)
          return emit_dynamic(node) unless name
          return unless node.block

          opts = extract_keyword_options(node)
          push_frame(node,
                     prefix: join_path(current_prefix, (opts[:path] || name).to_s),
                     mod: name.to_s,
                     name_prefix: name.to_s)
        end

        def enter_scope(node)
          return unless node.block

          opts = extract_keyword_options(node)
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
          else
            opts = extract_keyword_options(node)
            names.each { |n| emit_resource_routes(node, n.to_s, opts, singular: singular) }
          end

          return unless node.block && names.size == 1

          name = names.first.to_s
          opts = extract_keyword_options(node)
          base = join_path(current_prefix, (opts[:path] || name).to_s)
          nested = singular ? base : "#{base}/:#{name.singularize}_id"
          # Routes nested under this resource inherit its singular route key as
          # a name prefix (resources :posts { resources :comments } -> the
          # comments index route is named "post_comments", not "comments").
          push_frame(node,
                     prefix: nested,
                     name_prefix: singular ? name : name.singularize,
                     resource: {
                       name: name,
                       singular: singular,
                       controller: resource_controller(name, opts, singular: singular),
                       base: base,
                       member_path: singular ? base : "#{base}/:id",
                       singular_route_name: singular ? route_name_for(name) : route_name_for(name.singularize),
                       plural_route_name: route_name_for(name)
                     })
        end

        def emit_resource_routes(node, name, opts, singular:)
          base = join_path(current_prefix, (opts[:path] || name).to_s)
          controller = resource_controller(name, opts, singular: singular)
          actions = requested_actions(singular ? SINGULAR_ACTIONS : PLURAL_ACTIONS, opts)
          plural_name = route_name_for(name)
          singular_name = route_name_for(singular ? name : name.singularize)

          actions.each do |action|
            case action
            when :index   then emit(node, "GET", base, controller, "index", plural_name)
            when :create  then emit(node, "POST", base, controller, "create", singular ? singular_name : plural_name)
            when :new     then emit(node, "GET", "#{base}/new", controller, "new", "new_#{singular_name}")
            when :edit    then emit(node, "GET", edit_path(base, singular), controller, "edit", "edit_#{singular_name}")
            when :show    then emit(node, "GET", member_path(base, singular), controller, "show", singular_name)
            when :update
              emit(node, "PATCH", member_path(base, singular), controller, "update", nil)
              emit(node, "PUT", member_path(base, singular), controller, "update", nil)
            when :destroy then emit(node, "DELETE", member_path(base, singular), controller, "destroy", nil)
            end
          end
        end

        def member_path(base, singular)
          singular ? base : "#{base}/:id"
        end

        def edit_path(base, singular)
          singular ? "#{base}/edit" : "#{base}/:id/edit"
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

        def emit_dynamic(node)
          return if suppressed?

          @results << { type: :dynamic, macro: node.name, location: node.location.start_line }
        end

        # Keyword options including hash-rocket string keys, so
        # `get "up" => "rails/health#show", as: :x` yields
        # {"up" => "rails/health#show", as: :x}.
        def route_options(node)
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
        # (resource :profile -> ProfilesController).
        def resource_controller(name, opts, singular: false)
          controller = (opts[:controller] || (singular ? name.pluralize : name)).to_s
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
