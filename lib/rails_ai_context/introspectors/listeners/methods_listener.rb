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
          @frames = [ Frame.new(:body, :public, {}) ]
          @owner_stack = []
          # Blocks that open a body of their own, keyed by their block node so
          # the block's own enter/leave can open and close the frame.
          @scoped_blocks = {}.compare_by_identity
          @open_blocks = []
          @def_depth = 0
          @builders = []
        end

        # One visibility scope: a class or module body, a `class << self`
        # body, or a block Rails evaluates as a module body. `marks` holds the
        # inline `private :x` forms, keyed by [scope, name].
        Frame = Struct.new(:kind, :visibility, :marks)

        CLASS_SCOPE_FRAMES = %i[singleton class_methods].freeze
        # A scope's or an association's block extends the relation, and
        # `concern` builds a module the class does not include: a def in
        # one is no method of the class.
        BLOCK_FRAMES = {
          class_methods: :class_methods, included: :included, concerning: :body,
          scope: :extension, has_many: :extension, has_and_belongs_to_many: :extension,
          has_one: :extension, belongs_to: :extension, concern: :extension
        }.freeze

        # Each defines a public method whatever `private` section it sits in;
        # only Rails' `private: true` makes one private.
        DELEGATORS = %i[delegate def_delegators def_instance_delegators def_delegator def_instance_delegator instance_delegate].freeze

        # Ruby's own definers: these honor the section's visibility, as `def` does.
        ATTR_DEFINERS = { attr_reader: [ :reader ], attr_writer: [ :writer ], attr_accessor: %i[reader writer], attr: [ :reader ] }.freeze
        # Active Support's: each defines public class and instance accessors from a string `class_eval`.
        CLASS_ACCESSORS = {
          class_attribute: %i[reader writer], mattr_reader: [ :reader ], cattr_reader: [ :reader ],
          mattr_writer: [ :writer ], cattr_writer: [ :writer ], mattr_accessor: %i[reader writer], cattr_accessor: %i[reader writer]
        }.freeze

        def on_class_node_enter(node)
          open_frame(:body)
          @owner_stack.push(constant_path_string(node.constant_path))
        end

        def on_class_node_leave(node)
          @frames.pop
          @owner_stack.pop
        end

        def on_module_node_enter(node)
          open_frame(:body)
          @owner_stack.push(constant_path_string(node.constant_path))
        end

        def on_module_node_leave(node)
          @frames.pop
          @owner_stack.pop
        end

        # A singleton class body starts public, and a `private` in it stays in it.
        def on_singleton_class_node_enter(node)
          open_frame(:singleton)
        end

        def on_singleton_class_node_leave(node)
          @frames.pop
        end

        # Bare `private` affects every later def in this frame; `private :x`
        # and `private def x` mark the one name, retroactively for :x.
        def on_call_node_enter(node)
          @scoped_blocks[node.block] = :extension if new_class_body?(node) && !@scoped_blocks.key?(node.block)
          return unless node.receiver.nil?

          case node.name
          when :private, :protected, :public
            if node.arguments.nil?
              @frames.last.visibility = node.name
            else
              mark(node.arguments.arguments, node.name, frame_scope)
            end
          when :private_class_method, :public_class_method
            mark(Array(node.arguments&.arguments), node.name == :private_class_method ? :private : :public, :class)
          when :module_function
            if node.arguments.nil?
              @frames.last.visibility = :module_function
            else
              mark(node.arguments.arguments, :module_function, :instance)
            end
          when *BLOCK_FRAMES.keys
            @scoped_blocks[node.block] = BLOCK_FRAMES[node.name] if node.block.is_a?(Prism::BlockNode)
          when *DELEGATORS
            record_delegated(node) if @def_depth.zero?
          when *ATTR_DEFINERS.keys, :define_method, :alias_method, *CLASS_ACCESSORS.keys
            record_defined(node) if @def_depth.zero? && @frames.last.kind != :extension
          end
        end

        # `Name = Struct.new do ... end` is Name's body.
        def on_constant_write_node_enter(node)
          open_builder(node, node.name.to_s)
        end

        def on_constant_write_node_leave(node)
          close_builder(node)
        end

        def on_constant_path_write_node_enter(node)
          open_builder(node, constant_path_string(node.target))
        end

        def on_constant_path_write_node_leave(node)
          close_builder(node)
        end

        # ponytail: a Module.new held in a local is read as the enclosing class's, which is where it is
        # nearly always included; follow the local to its `include` if another use turns up.
        def on_local_variable_write_node_enter(node)
          value = node.value
          @scoped_blocks[value.block] = :body if value.is_a?(Prism::CallNode) && new_class_body?(value) && value.name == :new &&
                                                 value.receiver.name == :Module
        end

        def on_alias_method_node_enter(node)
          return unless @def_depth.zero? && @frames.last.kind != :extension

          new_name = literal_string(node.new_name)
          old_name = literal_string(node.old_name)
          record_alias(node, new_name, old_name) if new_name && old_name
        end

        def on_block_node_enter(node)
          kind = @scoped_blocks.delete(node)
          return unless kind

          @open_blocks.push(node)
          open_frame(kind)
        end

        def on_block_node_leave(node)
          return unless @open_blocks.last.equal?(node)

          @open_blocks.pop
          @frames.pop
        end

        def on_def_node_leave(node)
          @def_depth -= 1
        end

        def on_def_node_enter(node)
          @def_depth += 1
          scope = def_scope(node)
          method_name = node.name.to_s
          return unless scope
          return if @frames.last.kind == :extension
          return if method_name == "initialize" && scope == :instance && !@include_initialize

          frame = @frames.last
          # A bare `private` reaches only defs written without a receiver.
          visibility = frame.marks[[ scope, method_name ]] || (node.receiver ? :public : frame.visibility)
          if visibility == :module_function
            record(node, method_name, :instance, :private, prefixed: false)
            record(node, method_name, :class, :public, prefixed: true)
          else
            record(node, method_name, scope, visibility, prefixed: !node.receiver.nil?)
          end
        end

        private

        # These evaluate their block as a new class or module body.
        CLASS_BUILDERS = { Struct: :new, Class: :new, Module: :new, Data: :define }.freeze

        def new_class_body?(node)
          receiver = node.receiver
          return false unless node.block.is_a?(Prism::BlockNode)
          return false unless receiver.is_a?(Prism::ConstantReadNode) || (receiver.is_a?(Prism::ConstantPathNode) && receiver.parent.nil?)

          CLASS_BUILDERS[receiver.name] == node.name
        end

        def open_builder(node, name)
          value = node.value
          return unless value.is_a?(Prism::CallNode) && new_class_body?(value)

          @scoped_blocks[value.block] = :body
          @owner_stack.push(name)
          @builders.push(node)
        end

        def close_builder(node)
          return unless @builders.last.equal?(node)

          @builders.pop
          @owner_stack.pop
        end

        # What an includer gains: a `class_methods` def, or a class method written in `included do`.
        def includer_gains?(scope)
          @frames.reverse_each do |frame|
            return true if frame.kind == :class_methods || (frame.kind == :included && scope == :class)
            return false unless frame.kind == :singleton
          end
          false
        end

        def open_frame(kind)
          @frames.push(Frame.new(kind, :public, {}))
        end

        def frame_scope
          CLASS_SCOPE_FRAMES.include?(@frames.last.kind) ? :class : :instance
        end

        # nil for a singleton def on anything but this class (`def other.x`):
        # it is no method of the class.
        def def_scope(node)
          receiver = node.receiver
          return frame_scope if receiver.nil?
          return :class if receiver.is_a?(Prism::SelfNode)
          return unless receiver.is_a?(Prism::ConstantReadNode) || receiver.is_a?(Prism::ConstantPathNode)

          owner = @owner_stack.join("::")
          name = constant_path_string(receiver).delete_prefix("::")
          :class if owner == name || owner.end_with?("::#{name}")
        end

        def mark(args, visibility, scope)
          marks = @frames.last.marks
          args.each do |arg|
            case arg
            when Prism::DefNode
              marks[[ def_scope(arg), arg.name.to_s ]] = visibility
            when Prism::SymbolNode
              name = arg.unescaped
              marks[[ scope, name ]] = visibility
              existing = @results.reverse_each.find { |r| r[:name] == name && r[:scope] == scope && r[:owner] == @owner_stack }
              apply_visibility(existing, visibility) if existing
            when Prism::CallNode
              # Since Ruby 3.0 these return the names they define, so `private attr_reader :x` works.
              defined_names(arg).each { |name| marks[[ scope, name ]] = visibility } unless visibility == :module_function
            end
          end
        end

        def defined_names(call)
          return [] unless call.receiver.nil?

          names = Array(call.arguments&.arguments).filter_map { |a| literal_string(a) }
          case call.name
          when :define_method, :alias_method then names.first(1)
          when *ATTR_DEFINERS.keys
            kinds = ATTR_DEFINERS[call.name]
            names.flat_map { |name| [ (name if kinds.include?(:reader)), ("#{name}=" if kinds.include?(:writer)) ].compact }
          else []
          end
        end

        def apply_visibility(entry, visibility)
          return entry[:visibility] = visibility unless visibility == :module_function

          entry[:visibility] = :private
          @results << entry.merge(scope: :class, visibility: :public, signature: "self.#{entry[:signature]}")
        end

        def record(node, method_name, scope, visibility, prefixed:)
          entry = {
            name:         method_name,
            scope:        scope,
            visibility:   visibility,
            params:       extract_params(node),
            # Enclosing class/module names, outermost first. A caller that
            # wants one class's own methods needs this: a helper class nested
            # inside a service is a separate owner, not part of its interface.
            owner:        @owner_stack.dup,
            # Sliced off the node so defaults read as written (`options = {}`);
            # `params` records names only.
            signature:    signature_source(node, prefixed),
            location:     node.location.start_line,
            end_location: node.location.end_line,
            # Offsets, unlike lines, tell a call that shares a line with a def from one inside it.
            offset:       node.location.start_offset,
            end_offset:   node.location.end_offset,
            confidence:   RailsAiContext::Confidence::VERIFIED
          }
          # Outside `included do`, a `def self.x` or `class << self` method stays on the module.
          entry[:class_methods_block] = true if includer_gains?(scope)
          @results << entry
        end

        def record_defined(node)
          names = Array(node.arguments&.arguments).filter_map { |a| literal_string(a) }
          case node.name
          when :define_method
            record_name(node, names.first, frame_scope, @frames.last.visibility) if names.first
          when :alias_method
            record_alias(node, *names.first(2)) if names.size >= 2
          when *ATTR_DEFINERS.keys
            names.each { |name| record_accessors(node, name, ATTR_DEFINERS[node.name], frame_scope, @frames.last.visibility) }
          else
            record_class_accessors(node, names)
          end
        end

        def record_class_accessors(node, names)
          kinds = CLASS_ACCESSORS[node.name]
          options = extract_keyword_options(node)
          off = ->(key) { options[key] == false || options[:instance_accessor] == false }
          instance = kinds.reject { |kind| off.call(kind == :reader ? :instance_reader : :instance_writer) }
          predicate = node.name == :class_attribute && options[:instance_predicate] != false
          names.each do |name|
            record_accessors(node, name, kinds, :class, :public)
            record_name(node, "#{name}?", :class, :public) if predicate
            record_accessors(node, name, instance, :instance, :public)
            record_name(node, "#{name}?", :instance, :public) if predicate && instance.include?(:reader)
          end
        end

        def record_accessors(node, name, kinds, scope, visibility)
          record_name(node, name, scope, visibility) if kinds.include?(:reader)
          record_name(node, "#{name}=", scope, visibility, signature: "#{name}=(value)") if kinds.include?(:writer)
        end

        # An alias carries its original's visibility and parameters, whatever section it sits in.
        def record_alias(node, new_name, old_name)
          scope = frame_scope
          original = @results.reverse_each.find { |r| r[:name] == old_name && r[:scope] == scope && r[:owner] == @owner_stack }
          params = original ? original[:signature].to_s[/\(.*\)\z/m] : nil
          record_name(node, new_name, scope, original ? original[:visibility] : :public, signature: "#{new_name}#{params}")
        end

        def record_name(node, name, scope, visibility, signature: name)
          visibility = :public if visibility == :module_function
          entry = {
            name:         name,
            scope:        scope,
            visibility:   @frames.last.marks[[ scope, name ]] || visibility,
            params:       [],
            owner:        @owner_stack.dup,
            signature:    signature,
            # No end: these have no body for a call to sit inside.
            location:     node.location.start_line,
            confidence:   node.is_a?(Prism::CallNode) ? confidence_for(node) : RailsAiContext::Confidence::VERIFIED
          }
          entry[:class_methods_block] = true if includer_gains?(scope)
          @results << entry
        end

        def record_delegated(node)
          return if @frames.last.kind == :extension

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
          names.each { |name| record_name(node, name, frame_scope, visibility) }
        end

        def delegation_prefix(options)
          case options[:prefix]
          # Rails raises on `prefix: true` with an ivar target, so nothing is defined.
          when true then options[:to].to_s.start_with?("@") ? nil : "#{options[:to]}_"
          when Symbol, String then "#{options[:prefix]}_"
          else ""
          end
        end

        # `class << self` members carry no receiver of their own, so they read
        # as the bare name, which is how they are written.
        def signature_source(node, prefixed)
          prefix = prefixed ? "self." : ""
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
