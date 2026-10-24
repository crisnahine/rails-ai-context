# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    module Listeners
      # Detects a Rack app attached in a route file via Prism AST:
      #   mount Sidekiq::Web, at: "/sidekiq"
      #   mount Sidekiq::Web => "/sidekiq"
      #   match "/metrics", to: MetricsApp, via: :all
      #
      # `mount` is `match(path, to: app, via: :all, anchor: false)` with a
      # name derived, so the two forms produce the same endpoint. An app is
      # written with `match` when it must answer one exact path - an
      # unanchored mount at /metrics also answers /metrics-admin - and that
      # form was invisible here, which left the endpoint out of every tool.
      class MountListener < BaseListener
        include BranchConditions
        include RoutesWalk

        VERB_MACROS = %i[match get post put patch delete].freeze

        # The blocks that prefix every path drawn inside them.
        SCOPE_MACROS = %i[namespace scope].freeze

        # `prefix` and `name_prefix` are the path and route name a `draw` of this file sits under.
        # `routes` is the RoutesDslListener walking the same tree, which places an app a resource scope holds,
        # binds a loop's variable, reads a literal and walks this listener through each body it replays; without one,
        # a routes listener that walks nothing reads only what the source spells out.
        def initialize(prefix: nil, name_prefix: nil, routes: nil)
          super()
          @routes = routes || RoutesDslListener.new
          @scopes = [ { node: nil, prefix: prefix && prefix != "/" ? prefix : nil, name: name_prefix } ]
          # A record read in a body Rails runs only where it is replayed, with that body's keys.
          @held = {}.compare_by_identity
          @routes.join(self)
        end

        # A held body's records stand only when the routes walk never replays it; each replay lists its own.
        def results
          @results.reject { |record| (keys = @held[record]) && @routes.replayed?(keys) }
        end

        def on_call_node_enter(node)
          note_mapper_call(node)
          return unless mapper_call?(node)

          if node.block && SCOPE_MACROS.include?(node.name)
            @scopes << { node: node, prefix: scope_prefix(node), name: scope_name(node) }
            return
          end

          return unless node.name == :mount || VERB_MACROS.include?(node.name)

          args = node.arguments&.arguments || []
          return if args.empty?

          engine, path = node.name == :mount ? [ resolve_engine(args), resolve_path(args) ] : resolve_rack_endpoint(args)
          return unless engine

          record = { engine: engine, path: attached_path(node, path), location: node.location.start_line }
          condition = current_condition
          if condition
            record[:condition] = condition
            arm = chain_arm
            record[:arm] = arm if arm
          end
          # The mount's route name, which names an engine's route proxy.
          if node.name == :mount
            as = @routes.literal_or_bound(extract_keyword_nodes(node)[:as])&.to_s
            record[:as] = as if as
            names = @scopes.filter_map { |scope| scope[:name] }.reject(&:empty?)
            record[:name_prefix] = names.join("_") if names.any?
          end
          keys = @routes.held_keys
          @held[record] = keys if keys.any?
          @results << record
        end

        def on_call_node_leave(node)
          @scopes.pop if @scopes.last && @scopes.last[:node].equal?(node)
        end

        private

        # `namespace :admin` and `scope "/internal"` prefix what they wrap, so
        # a path read off the mount call alone names a path the app does not
        # serve. A scope whose own name is an expression prefixes an unknown
        # amount, and the honest answer there is no path at all rather than
        # the unprefixed one.
        def scope_prefix(node)
          first = node.arguments&.arguments&.first
          path_node = extract_keyword_nodes(node)[:path]
          # `path: ADMIN_PATH` or `path: "/v#{n}"` is a prefix too, and one this
          # walk cannot read.
          # `path: nil` is Rails' way of adding no segment, which is known.
          return nil if path_node.is_a?(Prism::NilNode)
          return :unknown if path_node && !@routes.literal_or_bound(path_node)

          options = { path: path_node && @routes.literal_or_bound(path_node)&.to_s }
          literal = @routes.literal_or_bound(first)&.to_s

          if node.name == :namespace
            name = options[:path] || literal
            return :unknown if name.nil?

            "/#{name.to_s.delete_prefix("/")}"
          else
            # `scope module: :admin` and `scope constraints: {...}` add no path
            # segment at all, and a first argument that is not a literal adds
            # one this walk cannot read - which is not the same as none.
            path = options[:path] || literal
            return :unknown if path.nil? && positional_prefix?(node)

            path.nil? ? nil : "/#{path.to_s.delete_prefix("/")}"
          end
        end

        # What a scope adds to the names inside it: `namespace :admin` adds
        # admin, a scope only its `as:`.
        def scope_name(node)
          as = @routes.literal_or_bound(extract_keyword_nodes(node)[:as])&.to_s
          return as if as
          return unless node.name == :namespace

          @routes.literal_or_bound(node.arguments&.arguments&.first)&.to_s
        end

        def attached_path(node, path)
          scoped = @routes.resource_scoped_path(node, path) unless path.nil? || @scopes.any? { |scope| scope[:prefix] == :unknown }
          scoped == :unknown ? nil : scoped || prefixed_path(path)
        end

        def prefixed_path(path)
          prefixes = @scopes.filter_map { |scope| scope[:prefix] }
          return nil if path.nil? || prefixes.include?(:unknown)

          # Rails' normalize_path gives every path its leading slash, prefixed or not.
          joined = "#{prefixes.join.chomp("/")}/#{path.to_s.delete_prefix("/")}"
          normalize_route_path(joined == "/" ? joined : joined.chomp("/"))
        end

        def resolve_rack_endpoint(args)
          target = rack_app_constant(args)
          return [ nil, nil ] unless target

          first = args.first
          path = @routes.literal_or_bound(first) || rocket_path(args)
          [ target, path ]
        end

        # `get "/metrics" => MetricsApp`: the key is the path.
        def rocket_path(args)
          args.each do |arg|
            next unless arg.is_a?(Prism::KeywordHashNode) || arg.is_a?(Prism::HashNode)

            arg.elements.each do |assoc|
              return assoc.key.unescaped if assoc.is_a?(Prism::AssocNode) && assoc.key.is_a?(Prism::StringNode) && rack_app_name(assoc.value)
            end
          end
          nil
        end

        def resolve_engine(args)
          first = args.first
          case first
          when Prism::KeywordHashNode, Prism::HashNode
            # Hash rocket syntax: mount Engine => "/path"
            # The engine is the key of the first assoc
            assoc = first.elements.first
            assoc.is_a?(Prism::AssocNode) ? app_name(assoc.key) : nil
          else
            app_name(first)
          end
        end

        def resolve_path(args)
          # Check keyword options: mount Engine, at: "/path"
          args.each do |arg|
            next unless arg.is_a?(Prism::KeywordHashNode)

            arg.elements.each do |assoc|
              next unless assoc.is_a?(Prism::AssocNode)

              key = extract_key(assoc.key)
              if key == :at
                return literal_path(assoc.value)
              end
            end
          end

          # Check hash rocket syntax: mount Engine => "/path"
          args.each do |arg|
            next unless arg.is_a?(Prism::KeywordHashNode) || arg.is_a?(Prism::HashNode)

            arg.elements.each do |assoc|
              next unless assoc.is_a?(Prism::AssocNode)

              if app_name(assoc.key)
                return literal_path(assoc.value)
              end
            end
          end

          nil
        end

        # Only a string or symbol the source spells out or a loop binds: a constant or a call
        # is a path nothing here can read, and an expression prints no path at all.
        def literal_path(node)
          literal = @routes.literal_or_bound(node)
          return literal if literal
          return nil unless node.is_a?(Prism::InterpolatedStringNode)

          value = extract_value(node)
          value == RailsAiContext::Confidence::INFERRED ? nil : value
        end
      end
    end
  end
end
