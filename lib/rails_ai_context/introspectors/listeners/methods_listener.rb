# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    module Listeners
      # Detects method definitions via Prism AST: `def` and `def self.`.
      # Tracks visibility (public/private/protected) by observing
      # visibility modifier calls, including inline forms like
      # `private :method_name`.
      class MethodsListener < BaseListener
        def initialize
          super
          @visibility_stack = [ :public ]
          @in_singleton_class = false
          @singleton_depth = 0
          @inline_visibility_stack = [ {} ] # stack of { method_name => visibility }
        end

        # Reset visibility when entering a new class/module scope
        def on_class_node_enter(node)
          @visibility_stack.push(:public)
          @inline_visibility_stack.push({})
        end

        def on_class_node_leave(node)
          @visibility_stack.pop
          @inline_visibility_stack.pop
        end

        def on_module_node_enter(node)
          @visibility_stack.push(:public)
          @inline_visibility_stack.push({})
        end

        def on_module_node_leave(node)
          @visibility_stack.pop
          @inline_visibility_stack.pop
        end

        # Track `class << self` blocks
        def on_singleton_class_node_enter(node)
          @in_singleton_class = true
          @singleton_depth += 1
        end

        def on_singleton_class_node_leave(node)
          @singleton_depth -= 1
          @in_singleton_class = false if @singleton_depth == 0
        end

        # Track visibility modifiers: private, protected, public
        # Handles both bare form (`private`) and inline form (`private :method_name`)
        def on_call_node_enter(node)
          return unless node.receiver.nil?

          case node.name
          when :private, :protected, :public
            if node.arguments.nil?
              # Bare modifier: affects all subsequent defs in this scope
              @visibility_stack[-1] = node.name
            else
              # Inline form: `private :method_name` — retroactively update
              # already-recorded methods and mark for future defs
              args = node.arguments.arguments
              args.each do |arg|
                if arg.is_a?(Prism::SymbolNode)
                  method_name = arg.value.to_s
                  @inline_visibility_stack.last[method_name] = node.name
                  # Retroactively fix already-recorded result
                  existing = @results.find { |r| r[:name] == method_name }
                  existing[:visibility] = node.name if existing
                end
              end
            end
          end
        end

        def on_def_node_enter(node)
          is_class_method = @in_singleton_class || node.receiver&.is_a?(Prism::SelfNode)
          method_name = node.name.to_s

          # Skip initialize for instance methods
          return if method_name == "initialize" && !is_class_method

          # Inline visibility (`private :foo`) takes precedence over positional
          visibility = @inline_visibility_stack.last[method_name] || @visibility_stack.last

          params = extract_params(node)

          @results << {
            name:         method_name,
            scope:        is_class_method ? :class : :instance,
            visibility:   visibility,
            params:       params,
            location:     node.location.start_line,
            end_location: node.location.end_line,
            confidence:   RailsAiContext::Confidence::VERIFIED
          }
        end

        private

        def extract_params(node)
          parameters = node.parameters
          return [] unless parameters

          params = []

          parameters.requireds.each { |p| params << { name: param_name(p), type: :required } } if parameters.respond_to?(:requireds)
          parameters.optionals.each { |p| params << { name: param_name(p), type: :optional } } if parameters.respond_to?(:optionals)
          params << { name: param_name(parameters.rest), type: :rest } if parameters.respond_to?(:rest) && parameters.rest
          parameters.keywords.each { |p| params << { name: param_name(p), type: :keyword } } if parameters.respond_to?(:keywords)
          params << { name: param_name(parameters.keyword_rest), type: :keyword_rest } if parameters.respond_to?(:keyword_rest) && parameters.keyword_rest
          params << { name: param_name(parameters.block), type: :block } if parameters.respond_to?(:block) && parameters.block

          params
        end

        def param_name(node)
          case node
          when Prism::RequiredParameterNode         then node.name.to_s
          when Prism::OptionalParameterNode         then node.name.to_s
          when Prism::RestParameterNode             then node.name&.to_s || "*"
          when Prism::RequiredKeywordParameterNode  then node.name.to_s
          when Prism::OptionalKeywordParameterNode  then node.name.to_s
          when Prism::KeywordRestParameterNode      then node.name&.to_s || "**"
          when Prism::BlockParameterNode            then node.name&.to_s || "&"
          else "unknown"
          end
        end
      end
    end
  end
end
