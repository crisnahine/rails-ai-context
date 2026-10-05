# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    module Listeners
      # Detects method definitions via Prism AST: `def` and `def self.`.
      # Tracks visibility (public/private/protected) by observing
      # visibility modifier calls, including inline forms like
      # `private :method_name`.
      class MethodsListener < BaseListener
        # A constructor is not part of the callable interface every other
        # caller asks for, so it stays out unless one asks for it by name.
        def initialize(include_initialize: false)
          super()
          @include_initialize = include_initialize
          @visibility_stack = [ :public ]
          @in_singleton_class = false
          @singleton_depth = 0
          @inline_visibility_stack = [ {} ] # stack of { method_name => visibility }
          @owner_stack = []
          # `class_methods do` and `included do` bodies, keyed by their block
          # node so the block's own enter/leave can open and close a scope.
          @concern_blocks = {}.compare_by_identity
          @open_blocks = []
          @scope_stack = []
          @def_depth = 0
        end

        # Reset visibility when entering a new class/module scope
        def on_class_node_enter(node)
          @visibility_stack.push(:public)
          @inline_visibility_stack.push({})
          @owner_stack.push(constant_path_string(node.constant_path))
        end

        def on_class_node_leave(node)
          @visibility_stack.pop
          @inline_visibility_stack.pop
          @owner_stack.pop
        end

        def on_module_node_enter(node)
          @visibility_stack.push(:public)
          @inline_visibility_stack.push({})
          @owner_stack.push(constant_path_string(node.constant_path))
        end

        def on_module_node_leave(node)
          @visibility_stack.pop
          @inline_visibility_stack.pop
          @owner_stack.pop
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
              # Inline form: `private :method_name` - retroactively update
              # already-recorded methods and mark for future defs. The def in
              # `private def x` is visited after this call, so marking its
              # name here is enough.
              args = node.arguments.arguments
              args.each do |arg|
                case arg
                when Prism::DefNode
                  @inline_visibility_stack.last[arg.name.to_s] = node.name
                when Prism::SymbolNode
                  method_name = arg.unescaped
                  @inline_visibility_stack.last[method_name] = node.name
                  existing = @results.find { |r| r[:name] == method_name && r[:owner] == @owner_stack }
                  existing[:visibility] = node.name if existing
                end
              end
            end
          when :class_methods, :included
            @concern_blocks[node.block] = node.name if node.block.is_a?(Prism::BlockNode)
          when *DELEGATORS
            record_delegated(node) if @def_depth.zero?
          end
        end

        # A concern block is a visibility scope of its own: a `private` inside
        # `class_methods do` does not reach the module's instance methods.
        def on_block_node_enter(node)
          kind = @concern_blocks.delete(node)
          return unless kind

          @open_blocks.push(node)
          @scope_stack.push(kind)
          @visibility_stack.push(:public)
          @inline_visibility_stack.push({})
        end

        def on_block_node_leave(node)
          return unless @open_blocks.last.equal?(node)

          @open_blocks.pop
          @scope_stack.pop
          @visibility_stack.pop
          @inline_visibility_stack.pop
        end

        def on_def_node_leave(node)
          @def_depth -= 1
        end

        def on_def_node_enter(node)
          @def_depth += 1
          is_class_method = @in_singleton_class || node.receiver&.is_a?(Prism::SelfNode) || @scope_stack.last == :class_methods
          method_name = node.name.to_s

          return if method_name == "initialize" && !is_class_method && !@include_initialize

          # Inline visibility (`private :foo`) takes precedence over positional
          visibility = @inline_visibility_stack.last[method_name] || @visibility_stack.last

          params = extract_params(node)

          @results << {
            name:         method_name,
            scope:        is_class_method ? :class : :instance,
            visibility:   visibility,
            params:       params,
            # Enclosing class/module names, outermost first. A caller that
            # wants one class's own methods needs this: a helper class nested
            # inside a service is a separate owner, not part of its interface.
            owner:        @owner_stack.dup,
            # Sliced off the node so defaults read as written (`options = {}`);
            # `params` records names only.
            signature:    signature_source(node, is_class_method),
            location:     node.location.start_line,
            end_location: node.location.end_line,
            # Offsets, unlike lines, tell a call that shares a line with a def from one inside it.
            offset:       node.location.start_offset,
            end_offset:   node.location.end_offset,
            confidence:   RailsAiContext::Confidence::VERIFIED
          }
        end

        # Each defines a public method whatever `private` section it sits in;
        # only Rails' `private: true` makes one private.
        DELEGATORS = %i[delegate def_delegators def_instance_delegators def_delegator def_instance_delegator instance_delegate].freeze

        private

        def record_delegated(node)
          args = node.arguments&.arguments || []
          positional = args.reject { |a| a.is_a?(Prism::KeywordHashNode) }
          options = extract_keyword_options(node)
          visibility = :public
          names = case node.name
          when :def_delegators, :def_instance_delegators
            positional.drop(1).filter_map { |a| literal_string(a) } - %w[__send__ __id__]
          when :def_delegator, :def_instance_delegator
            Array(literal_string(positional[2] || positional[1]))
          else
            if options.key?(:to)
              visibility = :private if options[:private] == true
              prefix = delegation_prefix(options)
              return unless prefix

              positional.filter_map { |a| literal_string(a) }.map { |name| "#{prefix}#{name}" }
            else
              # Forwardable's `delegate [:a, :b] => :@x`.
              args.grep(Prism::KeywordHashNode).flat_map(&:elements).grep(Prism::AssocNode).flat_map { |assoc| literal_strings(assoc.key) }
            end
          end
          names.each { |name| record_delegated_name(node, name, visibility) }
        end

        def delegation_prefix(options)
          case options[:prefix]
          # Rails raises on `prefix: true` with an ivar target, so nothing is defined.
          when true then options[:to].to_s.start_with?("@") ? nil : "#{options[:to]}_"
          when Symbol, String then "#{options[:prefix]}_"
          else ""
          end
        end

        def record_delegated_name(node, name, visibility)
          @results << {
            name:         name,
            scope:        @in_singleton_class || @scope_stack.last == :class_methods ? :class : :instance,
            visibility:   @inline_visibility_stack.last[name] || visibility,
            params:       [],
            owner:        @owner_stack.dup,
            signature:    name,
            # No end: a delegation has no body for a call to sit inside.
            location:     node.location.start_line,
            confidence:   confidence_for(node)
          }
        end

        # `class << self` members carry no receiver of their own, so they read
        # as the bare name, which is how they are written.
        def signature_source(node, is_class_method)
          prefix = (is_class_method && node.receiver) ? "self." : ""
          params = parameter_slices(node.parameters)
          return "#{prefix}#{node.name}" if params.empty?

          "#{prefix}#{node.name}(#{params.join(', ')})"
        end

        # Each parameter is sliced on its own rather than taking the whole list
        # in one piece: a list split over several lines carries its newlines,
        # and a comment written between two parameters would otherwise swallow
        # the ones after it. Slicing keeps defaults as written, which is the
        # reason for reading source here at all.
        def parameter_slices(parameters)
          return [] unless parameters

          parts = []
          %i[requireds optionals].each do |group|
            next unless parameters.respond_to?(group)
            parameters.public_send(group).each { |p| parts << p.location.slice }
          end
          parts << parameters.rest.location.slice if parameters.respond_to?(:rest) && parameters.rest
          parameters.posts.each { |p| parts << p.location.slice } if parameters.respond_to?(:posts)
          parameters.keywords.each { |p| parts << p.location.slice } if parameters.respond_to?(:keywords)
          parts << parameters.keyword_rest.location.slice if parameters.respond_to?(:keyword_rest) && parameters.keyword_rest
          parts << parameters.block.location.slice if parameters.respond_to?(:block) && parameters.block

          parts.compact.map { |slice| slice.gsub(/\s+/, " ").strip }
        end

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
