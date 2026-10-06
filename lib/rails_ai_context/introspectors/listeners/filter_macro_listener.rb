# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    module Listeners
      # ConditionalMacroListener plus `callbacks`: what each positional argument of a filter macro
      # adds, named at the node as the booted tier names the callback it reflects.
      class FilterMacroListener < ConditionalMacroListener
        def on_call_node_enter(node)
          count = @results.size
          super
          @results.last[:callbacks] = callbacks(node) if @results.size > count
        end

        private

        # [:name, "x"] for a symbol, string or class; [:object, "Klass"] for an instance;
        # [:block] for a lambda or proc; nil for anything else.
        def callbacks(node)
          Array(node.arguments&.arguments).reject { |arg| arg.is_a?(Prism::KeywordHashNode) }.map do |arg|
            if (text = literal_string(arg)) then [ :name, text ]
            elsif proc_argument?(arg) then [ :block ]
            elsif (const = constant_name(arg)) then [ :name, const ]
            elsif (klass = object_name(arg)) then [ :object, klass ]
            end
          end
        end

        # The class the booted tier names an object filter by: `Class` for an anonymous class,
        # an instance's nearest named class (`Class.new(Base) {}.new` is Base's, `Class.new {}.new` Object's).
        def object_name(node)
          return nil unless node.is_a?(Prism::CallNode) && node.name == :new && node.receiver
          return "Class" if %w[Class Struct].include?(constant_name(node.receiver))

          named_class(node.receiver)
        end

        def named_class(node)
          return constant_name(node) unless node.is_a?(Prism::CallNode) && node.name == :new

          case constant_name(node.receiver)
          when "Class" then (superclass = node.arguments&.arguments&.first) ? named_class(superclass) : "Object"
          when "Struct" then "Struct"
          end
        end

        def constant_name(node)
          node.slice.delete_prefix("::") if node.is_a?(Prism::ConstantReadNode) || node.is_a?(Prism::ConstantPathNode)
        end
      end
    end
  end
end
