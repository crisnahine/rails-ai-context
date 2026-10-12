# frozen_string_literal: true

module RailsAiContext
  module DatabaseFamily
    # A PostgreSQL EXPLAIN (VERBOSE, FORMAT JSON) plan, read for the relations
    # and base columns its expressions name.
    class PostgresqlPlan
      # A plain qualified Var. A quoted or spaced alias (a set operation's
      # "*SELECT* 1") never matches, so only a real relation's column is read.
      BASE_VAR = /\A"?([A-Za-z_]\w*)"?\.([A-Za-z_]\w*)\z/

      attr_reader :nodes, :aliases

      # @param top [Hash] the plan's top node, as Family#plan returns it
      def initialize(top)
        @top = top
        @nodes = []
        collect(top)
        # The alias defaults to the relation name when the query gave none, which is how `users.*` resolves.
        @aliases = @nodes.each_with_object({}) do |node, map|
          rel = node["Relation Name"] or next
          map[(node["Alias"] || rel).to_s.downcase] = rel.to_s.downcase
        end
      end

      # The top node's Output: its i-th entry is result column i, with any sort or group key past the result width.
      def output
        Array(@top["Output"])
      end

      # @return [Array(String, String), nil] [relation, column], downcased, for a plain Var of a base relation
      def base_column(expr)
        m = expr.to_s.strip.match(BASE_VAR) or return nil
        rel = aliases[m[1].downcase]
        rel ? [ rel, m[2].downcase ] : nil
      end

      private

      def collect(node)
        return unless node.is_a?(Hash)

        @nodes << node
        Array(node["Plans"]).each { |child| collect(child) }
      end
    end
  end
end
