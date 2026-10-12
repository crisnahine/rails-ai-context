# frozen_string_literal: true

module RailsAiContext
  module DatabaseFamily
    # A PostgreSQL EXPLAIN (VERBOSE, FORMAT JSON) plan, read for the relations
    # and base columns its expressions name.
    class PostgresqlPlan
      # A plain qualified Var, either part bare or quoted. A set operation's "*SELECT* 1"
      # is no relation's alias, so only a real relation's column is read.
      NAME = /(?:([A-Za-z_]\w*)|"((?:""|[^"])+)")/
      BASE_VAR = /\A#{NAME}\.#{NAME}\z/
      # Nodes whose every read of a child's column is an expression of their own that names it.
      READS_BY_NAME = [ "Aggregate", "Hash Join", "Merge Join", "Nested Loop" ].freeze

      # Catalogs and TOAST tables: the never-read list and the catalog credentials hold what is secret there.
      SYSTEM_SCHEMA = /\A(?:pg_catalog|information_schema|pg_toast(?:_temp_\d+)?)\z/

      # aliases: alias => the relation it names, as `schema.relation` where the plan gives a schema that is no system one.
      attr_reader :nodes, :aliases

      # @param top [Hash] the plan's top node, as Family#plan returns it
      def initialize(top)
        @top = top
        @nodes = []
        @parents = {}.compare_by_identity
        collect(top)
        # The alias defaults to the relation name when the query gave none, which is how `users.*` resolves.
        # Keyed as EXPLAIN prints it: `t` and "T" are two aliases.
        @names = {}
        @aliases = @nodes.each_with_object({}) do |node, map|
          rel = node["Relation Name"] or next
          key = [ (node["Schema"] unless node["Schema"].to_s.match?(SYSTEM_SCHEMA)), rel ].compact.join(".").downcase
          @names[key] = rel.to_s.downcase
          map[(node["Alias"] || rel).to_s] = key
        end
      end

      # The relation's own name, with no schema, for an answer.
      def name(relation)
        @names.fetch(relation, relation)
      end

      # @return [Array<Array(String, String)>] [schema, `schema.relation`] for each relation the plan reads
      #   outside the system schemas
      def relations
        @nodes.filter_map do |node|
          schema = node["Schema"]
          [ schema, "#{schema}.#{node["Relation Name"]}".downcase ] if schema && node["Relation Name"] && !schema.match?(SYSTEM_SCHEMA)
        end.uniq
      end

      # The top node's Output: its i-th entry is result column i, with any sort or group key past the result width.
      def output
        Array(@top["Output"])
      end

      # @return [Array(String, String), nil] [relation, column], downcased, for a plain Var of a base relation
      def base_column(expr)
        m = expr.to_s.strip.match(BASE_VAR) or return nil
        rel = aliases[m[1] || m[2].gsub('""', '"')]
        rel ? [ rel, (m[3] || m[4].gsub('""', '"')).downcase ] : nil
      end

      # The node that takes this node's rows as its input and reads their columns by name, or nil. A scan
      # under one hands up every column of its table, read or not. A subplan's columns are read by position.
      def reader(node)
        parent = @parents[node]
        parent if parent && READS_BY_NAME.include?(parent["Node Type"]) && %w[Outer Inner].include?(node["Parent Relationship"])
      end

      # Every expression the node itself holds, under whatever key.
      def expressions(node)
        strings(node.except("Plans"))
      end

      private

      def collect(node, parent = nil)
        return unless node.is_a?(Hash)

        @nodes << node
        @parents[node] = parent
        Array(node["Plans"]).each { |child| collect(child, node) }
      end

      def strings(value)
        case value
        when Hash then value.values.flat_map { |held| strings(held) }
        when Array then value.flat_map { |held| strings(held) }
        else [ value.to_s ]
        end
      end
    end
  end
end
