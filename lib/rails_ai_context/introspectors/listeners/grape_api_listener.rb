# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    module Listeners
      # What a Grape API class body declares: its superclass, version and
      # prefix, each endpoint with the namespaces around it and the params
      # block before it, and the APIs it mounts. Whether a class is a Grape API
      # is the consumer's call, since a superclass can be another API class.
      class GrapeApiListener < BaseListener
        VERBS = %i[get post put patch delete head options query].freeze
        NAMESPACES = %i[namespace group resource resources segment route_param].freeze
        PARAMS = %i[requires optional].freeze

        def initialize
          super
          @scopes = [ nil ]
          @blocks = []
          @pending = []
        end

        def on_class_node_enter(node)
          name = scope_name(node)
          superclass = node.superclass && (node.superclass.is_a?(Prism::ConstantReadNode) || node.superclass.is_a?(Prism::ConstantPathNode)) ? constant_path_string(node.superclass) : nil
          @results << { kind: :class, owner: name, superclass: superclass }
          @scopes.push(name)
        end

        def on_class_node_leave(_node)
          @scopes.pop
        end

        def on_module_node_enter(node)
          @scopes.push(scope_name(node))
        end

        def on_module_node_leave(_node)
          @scopes.pop
        end

        def on_call_node_enter(node)
          frame = frame_for(node)
          @blocks.push(frame) if node.block.is_a?(Prism::BlockNode)
        end

        def on_call_node_leave(node)
          return unless node.block.is_a?(Prism::BlockNode)

          @pending = [] if @blocks.pop.first == :namespace
        end

        private

        # Records what the call declares and returns the frame its block opens.
        def frame_for(node)
          owner = @scopes.last
          return [ :body ] if owner.nil? || node.receiver || in_endpoint?

          args = Array(node.arguments&.arguments)
          case node.name
          when *VERBS
            @results << { kind: :endpoint, owner: owner, verb: node.name.to_s.upcase, path: literal_string(args.first) || "",
                          namespace: namespace, params: inherited_params + @pending }
            @pending = []
            [ :endpoint ]
          when *NAMESPACES
            space = literal_string(args.first)
            if node.name == :route_param && space
              type = keyword(node, :type)
              @pending += [ { name: space, type: type, required: true } ] if type
              space = ":#{space}"
            end
            # Grape declares these on the setting the namespace inherits, so every endpoint inside gets them.
            params, @pending = @pending, []
            [ :namespace, space, params ]
          when :params
            [ :params ]
          when *PARAMS
            if @blocks.last&.first == :params
              type = keyword(node, :type)
              args.filter_map { |arg| literal_string(arg) }.each do |name|
                @pending << { name: name, type: type, required: node.name == :requires }
              end
            end
            [ :body ]
          when :version, :prefix
            value = literal_string(args.first)
            @results << { kind: node.name, owner: owner, value: value, using: keyword(node, :using) || "path" } if value
            [ :body ]
          when :mount
            mounts(args).each { |target, path| @results << { kind: :mount, owner: owner, target: target, path: path, namespace: namespace } }
            [ :body ]
          else
            [ :body ]
          end
        end

        def in_endpoint?
          @blocks.any? { |frame| frame.first == :endpoint }
        end

        def namespace
          @blocks.filter_map { |kind, space| space if kind == :namespace }
        end

        def inherited_params
          @blocks.flat_map { |kind, _, params| kind == :namespace ? params : [] }
        end

        def keyword(node, key)
          value = extract_keyword_nodes(node)[key]
          value && (literal_string(value) || value.slice)
        end

        # `mount V1::Users`, `mount V1::Users => "/v1"` and the braced form.
        def mounts(args)
          args.flat_map do |arg|
            case arg
            when Prism::ConstantReadNode, Prism::ConstantPathNode then [ [ constant_path_string(arg), "/" ] ]
            when Prism::KeywordHashNode, Prism::HashNode
              arg.elements.grep(Prism::AssocNode).filter_map do |assoc|
                next unless assoc.key.is_a?(Prism::ConstantReadNode) || assoc.key.is_a?(Prism::ConstantPathNode)

                [ constant_path_string(assoc.key), literal_string(assoc.value) || "/" ]
              end
            else []
            end
          end
        end

        def scope_name(node)
          path = node.constant_path.slice
          outer = @scopes.last
          path.start_with?("::") || outer.nil? ? path.delete_prefix("::") : "#{outer}::#{path}"
        end
      end
    end
  end
end
