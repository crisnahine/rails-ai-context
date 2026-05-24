# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    module Listeners
      # Detects engine mount declarations in route files via Prism AST:
      # mount Sidekiq::Web, at: "/sidekiq"
      # mount Sidekiq::Web => "/sidekiq"
      class MountListener < BaseListener
        def on_call_node_enter(node)
          return unless node.name == :mount && node.receiver.nil?

          args = node.arguments&.arguments || []
          return if args.empty?

          engine = resolve_engine(args)
          path = resolve_path(args)
          return unless engine

          @results << {
            engine:   engine,
            path:     path,
            location: node.location.start_line
          }
        end

        private

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
