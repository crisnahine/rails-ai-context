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

        def initialize
          super
          @scopes = []
        end

        def on_call_node_enter(node)
          return unless node.receiver.nil?

          if node.block && SCOPE_MACROS.include?(node.name)
            @scopes << { node: node, prefix: scope_prefix(node) }
            return
          end

          return unless node.name == :mount || VERB_MACROS.include?(node.name)

          args = node.arguments&.arguments || []
          return if args.empty?

          engine, path = node.name == :mount ? [ resolve_engine(args), resolve_path(args) ] : resolve_rack_endpoint(args)
          return unless engine

          @results << {
            engine:   engine,
            path:     prefixed_path(path),
            location: node.location.start_line
          }
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
          options = extract_keyword_options(node)
          literal = case first
          when Prism::SymbolNode then first.value
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

          "#{prefixes.join.chomp("/")}/#{path.to_s.delete_prefix("/")}"
        end

        # `match "/metrics", to: MetricsApp`: a constant as the `to:` value is
        # a Rack app. A string ("orders#edit") is a controller action, which
        # is not this listener's business.
        def resolve_rack_endpoint(args)
          target = nil
          args.each do |arg|
            next unless arg.is_a?(Prism::KeywordHashNode) || arg.is_a?(Prism::HashNode)

            arg.elements.each do |assoc|
              next unless assoc.is_a?(Prism::AssocNode)
              next unless extract_key(assoc.key) == :to

              case assoc.value
              when Prism::ConstantReadNode then target = assoc.value.name.to_s
              when Prism::ConstantPathNode then target = constant_path_string(assoc.value)
              end
            end
          end
          return [ nil, nil ] unless target

          first = args.first
          path = first.is_a?(Prism::StringNode) ? first.unescaped : nil
          [ target, path ]
        end

        def resolve_engine(args)
          first = args.first
          case first
          when Prism::ConstantReadNode
            first.name.to_s
          when Prism::ConstantPathNode
            constant_path_string(first)
          when Prism::KeywordHashNode, Prism::HashNode
            # Hash rocket syntax: mount Engine => "/path"
            # The engine is the key of the first assoc
            assoc = first.elements.first
            return nil unless assoc.is_a?(Prism::AssocNode)

            case assoc.key
            when Prism::ConstantReadNode then assoc.key.name.to_s
            when Prism::ConstantPathNode then constant_path_string(assoc.key)
            else nil
            end
          else
            nil
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

              if assoc.key.is_a?(Prism::ConstantReadNode) || assoc.key.is_a?(Prism::ConstantPathNode)
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
