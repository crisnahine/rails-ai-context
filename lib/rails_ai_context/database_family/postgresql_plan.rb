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
      READS_BY_NAME = [ "Aggregate", "Hash Join", "Merge Join", "Nested Loop", "Result" ].freeze

      # Catalogs and TOAST tables: the never-read list and the catalog credentials hold what is secret there.
      SYSTEM_SCHEMA = /\A(?:pg_catalog|information_schema|pg_toast(?:_temp_\d+)?)\z/

      # Before PostgreSQL 15 a plan names the session's temporary schema by its number, where the catalog reads say pg_temp.
      # No session can plan another session's temporary table, so the number is always the session's own.
      OWN_TEMP_SCHEMA = /\Apg_temp_\d+\z/

      APPENDS = [ "Append", "Merge Append" ].freeze
      REMOTE_NAME = /"(?:""|[^"])+"|[^\s()."]+/
      REMOTE_RELATION = /\((?:(#{REMOTE_NAME})\.)?(#{REMOTE_NAME})(?: (#{REMOTE_NAME}))?\)/

      # aliases: alias => the relations it stands for, each as `schema.relation` where the plan gives a schema that is no system one.
      attr_reader :nodes, :aliases

      # @param top [Hash] the plan's top node, as Family#plan returns it
      def initialize(top)
        @top = top
        @nodes = []
        @parents = {}.compare_by_identity
        @appended = {}.compare_by_identity
        collect(top)
        # The alias defaults to the relation name when the query gave none, which is how `users.*` resolves.
        # Keyed as EXPLAIN prints it: `t` and "T" are two aliases.
        @names = {}
        @aliases = @nodes.each_with_object({}) do |node, map|
          scanned(node).each do |schema, rel, as|
            key = [ (schema unless schema.to_s.match?(SYSTEM_SCHEMA)), rel ].compact.join(".").downcase
            @names[key] = rel.downcase
            # The members of an Append over partitions are `name_1`, `name_2`, and a node over them names their columns by `name`.
            # Anywhere else `name_1` is the plan's own name for a second use of `name`, which stands for another relation.
            [ as, (as[/\A(.+)_\d+\z/m, 1] if @appended[node]) ].compact.each { |name| (map[name] ||= []) << key }
          end
        end
        @aliases.each_value(&:uniq!)
      end

      # The relation's own name, with no schema, for an answer.
      def name(relation)
        @names.fetch(relation, relation)
      end

      # @return [Array<Array(String, String)>] [schema, `schema.relation`] for each relation the plan reads
      #   outside the system schemas
      def relations
        @nodes.flat_map { |node| scanned(node) }.filter_map do |schema, rel, _as|
          [ schema, "#{schema}.#{rel}".downcase ] if schema && !schema.match?(SYSTEM_SCHEMA)
        end.uniq
      end

      # @return [Array<Array<String>>] the expressions that can stand at result column i, with any sort or group key
      #   past the result width. An Append prints no Output, and each of its members hands up a row of its own.
      def output
        return Array(@top["Output"]).map { |expr| [ expr ] } if @top.key?("Output") || !APPENDS.include?(@top["Node Type"])

        members = Array(@top["Plans"])
        outputs = members.map { |member| Array(member["Output"]) }
        # Read only where each member is a relation that hands up the same columns in the same places.
        columns = outputs.map { |exprs| exprs.map { |expr| expr.to_s.match(BASE_VAR)&.then { |m| m[3] || m[4] } } }.uniq
        members.all? { |member| member["Relation Name"] } && columns.size == 1 ? outputs.transpose : []
      end

      # @return [Array<Array(String, String)>] [relation, column] for a plain Var of a base relation, the column
      #   folded as the secret column rule folds a name: one for each relation its alias stands for
      def base_columns(expr)
        m = expr.to_s.strip.match(BASE_VAR) or return []
        column = SecretColumns.fold(m[3] || m[4].gsub('""', '"'))
        Array(aliases[m[1] || m[2].gsub('""', '"')]).map { |rel| [ rel, column ] }
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

      # [schema, relation, alias] of each relation the node scans. A join or an aggregate that a foreign server runs has
      # no relation of its own: postgres_fdw names its tables there, each with its alias, as `(schema.table alias)`.
      def scanned(node)
        rel = node["Relation Name"]
        return [ [ node["Schema"]&.sub(OWN_TEMP_SCHEMA, "pg_temp"), rel.to_s, (node["Alias"] || rel).to_s ] ] if rel

        node["Relations"].to_s.scan(REMOTE_RELATION).map do |parts|
          schema, name, as = parts.map { |part| part&.delete_prefix('"')&.delete_suffix('"')&.gsub('""', '"') }
          [ schema, name, as || name ]
        end
      end

      def collect(node, parent = nil)
        return unless node.is_a?(Hash)

        @nodes << node
        @parents[node] = parent
        @appended[node] = true if parent && (@appended[parent] || APPENDS.include?(parent["Node Type"]))
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
