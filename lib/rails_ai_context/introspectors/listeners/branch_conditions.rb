# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    module Listeners
      # The `if`/`unless`/`case` branches open around the node being visited, as
      # text (`if Rails.env.development?`). A declaration under one runs only when
      # it holds, which source cannot tell, so the record carries the condition.
      # A listener that sets `@statements` counts only the branches registered there.
      module BranchConditions
        def on_if_node_enter(node)
          enter_condition(node, "if", node.subsequent)
        end

        def on_unless_node_enter(node)
          enter_condition(node, "unless", node.else_clause)
        end

        def on_else_node_enter(node)
          current = branch_conditions.last
          current[:negated] = true if current && current[:other].equal?(node)
          on_when_node_enter(node)
        end

        def on_else_node_leave(node)
          on_when_node_leave(node)
        end

        def on_case_node_enter(node)
          return unless branch_statement?(node)

          subject = node.predicate&.slice&.gsub(/\s+/, " ")
          seen = []
          node.conditions.each do |branch|
            register_statements(branch.statements)
            conditions = branch.conditions.map { |c| c.slice.gsub(/\s+/, " ") }
            seen.concat(conditions)
            case_branches[branch] = subject ? "when #{subject} is #{conditions.join(', ')}" : "if #{conditions.join(' or ')}"
          end
          return unless node.else_clause

          register_statements(node.else_clause.statements)
          case_branches[node.else_clause] = subject ? "when #{subject} is none of #{seen.join(', ')}" : "unless #{seen.join(' or ')}"
        end

        def on_when_node_enter(node)
          text = case_branches[node]
          branch_conditions << { node: node, text: text } if text
        end

        def on_when_node_leave(node)
          branch_conditions.pop if branch_conditions.last && branch_conditions.last[:node].equal?(node)
        end

        def on_if_node_leave(node)
          branch_conditions.pop if branch_conditions.last && branch_conditions.last[:node].equal?(node)
        end

        def on_unless_node_leave(node)
          on_if_node_leave(node)
        end

        private

        def branch_conditions
          @branch_conditions ||= []
        end

        def case_branches
          @case_branches ||= {}.compare_by_identity
        end

        def branch_statement?(node)
          @statements.nil? || @statements.key?(node)
        end

        def register_statements(statements)
          return unless @statements

          Array(statements&.body).each { |statement| @statements[statement] = true } if statements.is_a?(Prism::StatementsNode)
        end

        def enter_condition(node, keyword, other)
          return unless branch_statement?(node)

          register_statements(node.statements)
          @statements[other] = true if @statements && other.is_a?(Prism::IfNode)
          register_statements(other.statements) if other.is_a?(Prism::ElseNode)
          # An elsif runs only when the condition before it failed.
          outer = branch_conditions.last
          outer[:negated] = true if outer && outer[:other].equal?(node)
          branch_conditions << { node: node, other: other, keyword: keyword }
        end

        def current_condition
          branch_conditions.map { |c| c[:text] || condition_text(c) }.join(" and ").then { |text| text unless text.empty? }
        end

        # [chain offset, arm, arms] when every open branch is an arm of one if/unless chain that ends
        # in else, so copies on every arm add up to no condition at all.
        def chain_arm
          stack = branch_conditions
          return nil if stack.empty? || stack.any? { |c| c[:text] }
          return nil unless stack.each_cons(2).all? { |outer, inner| outer[:other].equal?(inner[:node]) }

          arms = 1
          other = stack.first[:other]
          while other.is_a?(Prism::IfNode)
            arms += 1
            other = other.subsequent
          end
          return nil unless other.is_a?(Prism::ElseNode)

          [ stack.first[:node].location.start_offset, stack.size - (stack.last[:negated] ? 0 : 1), arms + 1 ]
        end

        # Built only when a record asks, since most branches a walk passes hold nothing it records.
        def condition_text(branch)
          keyword = branch[:keyword]
          keyword = keyword == "if" ? "unless" : "if" if branch[:negated]
          "#{keyword} #{branch[:node].predicate.slice.gsub(/\s+/, " ")}"
        end
      end
    end
  end
end
