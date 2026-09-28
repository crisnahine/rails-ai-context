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
        VERB_MACROS = %i[match get post put patch delete].freeze

        # The blocks that prefix every path drawn inside them.
        SCOPE_MACROS = %i[namespace scope].freeze

        # `prefix` and `name_prefix` are the path and route name a `draw` of this file sits under.
        def initialize(prefix: nil, name_prefix: nil)
          super()
          @scopes = [ { node: nil, prefix: prefix && prefix != "/" ? prefix : nil, name: name_prefix } ]
        end

        def on_call_node_enter(node)
          return unless node.receiver.nil?

          if node.block && SCOPE_MACROS.include?(node.name)
            @scopes << { node: node, prefix: scope_prefix(node), name: scope_name(node) }
            return
          end

          return unless node.name == :mount || VERB_MACROS.include?(node.name)

          args = node.arguments&.arguments || []
          return if args.empty?

          engine, path = node.name == :mount ? [ resolve_engine(args), resolve_path(args) ] : resolve_rack_endpoint(args)
          return unless engine

          record = { engine: engine, path: prefixed_path(path), location: node.location.start_line }
          # The mount's route name, which names an engine's route proxy.
          if node.name == :mount
            as = extract_keyword_nodes(node)[:as]
            record[:as] = as.unescaped if as.is_a?(Prism::SymbolNode) || as.is_a?(Prism::StringNode)
            names = @scopes.filter_map { |scope| scope[:name] }.reject(&:empty?)
            record[:name_prefix] = names.join("_") if names.any?
          end
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
          return :unknown if path_node && !path_node.is_a?(Prism::StringNode) && !path_node.is_a?(Prism::SymbolNode)

          options = { path: path_node && extract_value(path_node) }
          literal = case first
          when Prism::SymbolNode then first.unescaped
          when Prism::StringNode then first.unescaped
          end

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
          as = extract_keyword_nodes(node)[:as]
          return as.unescaped if as.is_a?(Prism::SymbolNode) || as.is_a?(Prism::StringNode)
          return unless node.name == :namespace

          first = node.arguments&.arguments&.first
          first.unescaped if first.is_a?(Prism::SymbolNode) || first.is_a?(Prism::StringNode)
        end

        # A first positional argument that is not a literal string or symbol
        # is a prefix expression: `scope PREFIX do`, `scope "/v#{version}" do`.
        def positional_prefix?(node)
          first = node.arguments&.arguments&.first
          return false if first.nil?

          !first.is_a?(Prism::KeywordHashNode) && !first.is_a?(Prism::HashNode)
        end

        def prefixed_path(path)
          prefixes = @scopes.filter_map { |scope| scope[:prefix] }
          return nil if prefixes.include?(:unknown)
          return path if prefixes.empty? || path.nil?

          joined = "#{prefixes.join.chomp("/")}/#{path.to_s.delete_prefix("/")}"
          normalize_route_path(joined == "/" ? joined : joined.chomp("/"))
        end

        def resolve_rack_endpoint(args)
          target = rack_app_constant(args)
          return [ nil, nil ] unless target

          first = args.first
          path = first.is_a?(Prism::StringNode) ? first.unescaped : rocket_path(args)
          [ target, path ]
        end

        # `get "/metrics" => MetricsApp`: the key is the path.
        def rocket_path(args)
          args.each do |arg|
            next unless arg.is_a?(Prism::KeywordHashNode) || arg.is_a?(Prism::HashNode)

            arg.elements.each do |assoc|
              return assoc.key.unescaped if assoc.is_a?(Prism::AssocNode) && assoc.key.is_a?(Prism::StringNode) && app_name(assoc.value)
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
                val = extract_value(assoc.value)
                return val.is_a?(String) ? val : nil
              end
            end
          end

          # Check hash rocket syntax: mount Engine => "/path"
          args.each do |arg|
            next unless arg.is_a?(Prism::KeywordHashNode) || arg.is_a?(Prism::HashNode)

            arg.elements.each do |assoc|
              next unless assoc.is_a?(Prism::AssocNode)

              if app_name(assoc.key)
                val = extract_value(assoc.value)
                return val.is_a?(String) ? val : nil
              end
            end
          end

          nil
        end
      end
    end
  end
end
