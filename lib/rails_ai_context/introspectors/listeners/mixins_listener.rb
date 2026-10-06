# frozen_string_literal: true

require "prism"

module RailsAiContext
  module Introspectors
    module Listeners
      # Detects `include`, `prepend` and `extend` with a constant argument.
      #
      # `ancestor` marks the ones that reach the ancestor chain, which is what
      # reflection reports - so a caller can answer the same question the
      # booted tier answers.
      class MixinsListener < BaseListener
        MIXIN_MACROS = %i[include prepend extend].to_set.freeze
        ANCESTOR_MACROS = %i[include prepend].to_set.freeze
        # GitLab's `prepend_mod_with("Note")` mixes in EE::Note and JH::Note, each where that edition defines it;
        # `prepend_mod` names the class itself.
        EDITION_MACROS = {
          include_mod_with: :include, prepend_mod_with: :prepend, extend_mod_with: :extend,
          include_mod: :include, prepend_mod: :prepend, extend_mod: :extend
        }.freeze
        EDITIONS = %w[EE JH].freeze

        include OwnerScope

        def initialize
          super
          @singleton_depth = 0
        end

        # `include` inside `class << self` lands on the singleton class, so it
        # never reaches `ancestors` - extend semantics wearing an include's name.
        def on_singleton_class_node_enter(_node)
          @singleton_depth += 1
        end

        def on_singleton_class_node_leave(_node)
          @singleton_depth -= 1
        end

        # `singleton_class` called on what stands for the class: nothing or `self` in its body, `base` in a hook.
        # `singleton_class.include M` gives the class M's methods, as `extend` does, without `extended`.
        def self.singleton_class_of?(node, &stands_for_class)
          node.is_a?(Prism::CallNode) && node.name == :singleton_class && node.arguments.nil? && stands_for_class.call(node.receiver)
        end

        # The record of `node` mixing in `name`.
        def self.record(node, macro, name, ancestor:, owner: [])
          { macro: macro, name: name, ancestor: ancestor, owner: owner, location: node.location.start_line,
            confidence: confidence_for(node) }
        end

        # `Type.include(StatusPatch)` mixes into Type, not the class the line sits in, so the
        # record names Type as `receiver` and it is never an ancestor of the enclosing class.
        def on_call_node_enter(node)
          receiver = node.receiver && constant_name(node.receiver)
          singleton = self.class.singleton_class_of?(node.receiver) { |inner| inner.nil? || inner.is_a?(Prism::SelfNode) }
          return unless node.receiver.nil? || receiver || singleton

          return record_edition(node, receiver) if EDITION_MACROS.key?(node.name)
          return record_concerning(node) if node.name == :concerning && node.receiver.nil?

          macro, arguments = mixin_call(node)
          return unless macro
          return if singleton && macro == :extend

          macro = :"singleton_#{macro}" if singleton

          # Ruby adds `include A, B` last argument first: B's hook runs first and A ends up nearer.
          arguments.reverse_each do |arg|
            name = constant_name(arg)
            next unless name

            ancestor = receiver.nil? && @singleton_depth.zero? && ANCESTOR_MACROS.include?(macro)
            record = self.class.record(node, macro, name, ancestor: ancestor, owner: @owner_stack.dup)
            record[:receiver] = receiver if receiver
            @results << record
          end
        end

        private

        def record_edition(node, receiver)
          macro = EDITION_MACROS[node.name]
          arguments = node.arguments&.arguments || []
          name = if node.name.end_with?("_with")
            arguments.first.unescaped if arguments.size == 1 && arguments.first.is_a?(Prism::StringNode)
          elsif arguments.empty?
            receiver || @owner_stack.join("::").presence
          end
          return unless name

          ancestor = receiver.nil? && @singleton_depth.zero? && ANCESTOR_MACROS.include?(macro)
          EDITIONS.each do |edition|
            record = self.class.record(node, macro, "#{edition}::#{name}", ancestor: ancestor, owner: @owner_stack.dup)
            record[:receiver] = receiver if receiver
            @results << record.merge(edition: true)
          end
        end

        # `concerning :Topic do` defines Owner::Topic and mixes it in; `inline`
        # says its body is the block, already read as the class's own.
        def record_concerning(node)
          topic = node.arguments&.arguments&.first
          return unless topic.is_a?(Prism::SymbolNode) && node.block && !@owner_stack.empty?

          macro = extract_keyword_nodes(node)[:prepend].is_a?(Prism::TrueNode) ? :prepend : :include
          name = "#{@owner_stack.join("::")}::#{topic.unescaped}"
          @results << self.class.record(node, macro, name, ancestor: @singleton_depth.zero?, owner: @owner_stack.dup).merge(inline: true)
        end

        # `include X`, and `send :include, X`, the same include written to reach a private method.
        def mixin_call(node)
          arguments = node.arguments&.arguments || []
          return [ node.name, arguments ] if MIXIN_MACROS.include?(node.name)
          return unless %i[send public_send __send__].include?(node.name)

          first = arguments.first
          macro = first.unescaped.to_sym if first.is_a?(Prism::SymbolNode)
          [ macro, arguments.drop(1) ] if MIXIN_MACROS.include?(macro)
        end

        def constant_name(node)
          return unless node.is_a?(Prism::ConstantReadNode) || node.is_a?(Prism::ConstantPathNode)

          extract_value(node)
        end
      end
    end
  end
end
