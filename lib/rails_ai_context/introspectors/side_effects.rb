# frozen_string_literal: true

require "prism"
require "set"

module RailsAiContext
  module Introspectors
    # What a job's or a service's source does to the world beyond its return
    # value. The job and service tools list the same effects for one body.
    module SideEffects
      # Names no Hash, Array, Set or String answers, so any receiver that is not a file or a path counts.
      PERSISTENCE = %w[save destroy touch].flat_map { |name| [ name, "#{name}!" ] } +
                    %w[update! update_column update_columns increment! decrement! toggle! delete_all destroy_all update_all
                       insert_all upsert_all find_or_create_by first_or_create create_or_find_by touch_all].flat_map { |name| [ name, "#{name}!" ] } +
                    %w[update_counters increment_counter decrement_counter]
      # Raw SQL through a connection: a write unless the statement is a literal that only reads.
      CONNECTION_WRITES = %w[execute exec_update exec_insert exec_delete insert update delete].to_set.freeze
      READING_SQL = /\A\s*(?:select|show|pragma|explain|with\b[^;]*\bselect)\b/i
      # Rails' own request objects and cache or Redis clients answer these names without touching a record.
      FRAMEWORK_OBJECTS = %w[session cookies flash].to_set.freeze
      CLIENT_NAME = /cache|redis/i
      # Hash, Array, Set, Rails.cache and API clients answer these too, so the receiver must be a known record.
      NEEDS_RECORD = %w[update create create! delete delete! update_attribute update_attribute! upsert upsert! delete_by].to_set.freeze
      DATABASE_WRITES = (PERSISTENCE + NEEDS_RECORD.to_a).to_set.freeze
      # File, Dir, ENV and Pathname share those names and touch no database.
      NON_RECORD_CONSTANTS = %w[File FileUtils Dir ENV Pathname].to_set.freeze
      # Methods that return a value derived from records, not a record or a relation.
      NOT_RECORDS = %w[column_names pluck ids attributes attribute_names as_json to_h to_a to_s to_json to_param serializable_hash
                       count size length sum average minimum maximum exists? present? blank? nil? inspect map collect flat_map pick].to_set.freeze
      # A verb call is HTTP only with a path or URL literal: `redis.get("key")` reads a store.
      HTTP = %r{Faraday|Net::HTTP|HTTParty|RestClient|\.(?:get|post|put|patch|delete)\(\s*["'](?:/|https?:)}
      FILE_WRITE = /File\.(?:write|binwrite)\b|File\.open\([^)\n]*,\s*(?:mode:\s*)?["'](?:[wa]|r[bt]?\+)/

      EFFECTS = {
        "email delivery" => /\.deliver_later|\.deliver_now/,
        "Turbo broadcast" => /broadcast_|Turbo::StreamsChannel/,
        "HTTP request" => HTTP,
        "file write" => FILE_WRITE,
        "cache write" => /Rails\.cache\.write|Rails\.cache\.fetch/,
        "transaction" => /\.transaction\b/,
        "logging" => /Rails\.logger|logger\./,
        "notification" => /ActiveSupport::Notifications\.instrument/
      }.freeze

      module_function

      # The effects, sorted; enqueue_helpers are the app's own enqueue methods, models the names of its model classes,
      # columns the app's column names (a column reader returns a value, not a record).
      def of(source, enqueue_helpers, models: Set.new, columns: Set.new)
        writes = database_writes(source, Scope.new(models, columns))
        # A regex raises on bytes that are not UTF-8; Prism reads them as they are.
        text = RubySource.without_comments(source.valid_encoding? ? source : source.scrub("?"))
        effects = EFFECTS.filter_map { |label, pattern| label if text.match?(pattern) }
        effects << "database write (#{writes.join(', ')})" if writes.any?
        effects << "job enqueue" if SourceCalls.enqueue_calls(source, enqueue_helpers).any?
        effects.sort
      end

      # What the names in one source stand for: the models, the column names, the instance variables that hold a record
      # (shared by every method) and the locals that do (per method).
      Scope = Struct.new(:models, :columns) do
        def ivars = (@ivars ||= Set.new)
        def locals(owner) = ((@locals ||= {}.compare_by_identity)[owner] ||= Set.new)
      end

      def database_writes(source, scope)
        tree = AstCache.parse_string(source).value
        nodes = nodes_with_owner(tree)
        record_holders(nodes, scope)
        found = Set.new
        nodes.each do |node, owner|
          next unless node.is_a?(Prism::CallNode) && node.receiver

          name = node.name.to_s
          if connection_write?(node)
            found << name
          elsif DATABASE_WRITES.include?(name)
            found << name if record?(node.receiver, scope, owner) || (!NEEDS_RECORD.include?(name) && !non_record?(node.receiver))
          end
        end
        found.sort
      end

      # `connection.execute(sql)` and its siblings, unless the statement is a literal that only reads.
      def connection_write?(call)
        return false unless CONNECTION_WRITES.include?(call.name.to_s) && connection?(call.receiver)

        sql = call.arguments&.arguments&.first
        !(sql.is_a?(Prism::StringNode) && sql.unescaped.match?(READING_SQL))
      end

      def connection?(node)
        case node
        when Prism::CallNode then %i[connection lease_connection].include?(node.name)
        when Prism::LocalVariableReadNode then %i[conn connection].include?(node.name)
        else false
        end
      end

      # [node, the def it sits in or nil] for every node.
      def nodes_with_owner(tree)
        found = []
        stack = [ [ tree, nil ] ]
        while (node, owner = stack.pop)
          found << [ node, owner ]
          inner = node.is_a?(Prism::DefNode) ? node : owner
          node.compact_child_nodes.each { |child| stack << [ child, inner ] }
        end
        found
      end

      # Locals and ivars assigned a record, block parameters over one, and parameters named for a model.
      def record_holders(nodes, scope)
        loop do
          before = scope.ivars.size + scope.instance_variable_get(:@locals).to_h.values.sum(&:size)
          nodes.each do |node, owner|
            case node
            when Prism::LocalVariableWriteNode, Prism::LocalVariableOrWriteNode
              scope.locals(owner) << node.name if record?(node.value, scope, owner)
            when Prism::InstanceVariableWriteNode, Prism::InstanceVariableOrWriteNode
              scope.ivars << node.name if record?(node.value, scope, owner)
            when Prism::DefNode
              scope.locals(node).merge(model_named(node.parameters, scope.models))
            when Prism::CallNode
              params = node.block.is_a?(Prism::BlockNode) && node.block.parameters&.parameters&.requireds
              scope.locals(owner).merge(params.filter_map { |param| param.name if param.is_a?(Prism::RequiredParameterNode) }) if params && node.receiver && record?(node.receiver, scope, owner)
            end
          end
          break if before == scope.ivars.size + scope.instance_variable_get(:@locals).to_h.values.sum(&:size)
        end
      end

      # A method parameter named for a model (`order` for Order) holds one, as a job's record argument does.
      def model_named(parameters, models)
        return [] unless parameters

        named = parameters.requireds + parameters.optionals + parameters.keywords
        named.filter_map { |param| param.name if param.respond_to?(:name) }
             .select { |name| model?(name.to_s.split("_").map(&:capitalize).join, models) }
      end

      def record?(node, scope, owner)
        case node
        when Prism::ConstantReadNode, Prism::ConstantPathNode then model?(node.slice.delete_prefix("::"), scope.models)
        when Prism::LocalVariableReadNode then scope.locals(owner).include?(node.name)
        when Prism::InstanceVariableReadNode then scope.ivars.include?(node.name)
        when Prism::CallNode then !node.receiver.nil? && !returns_value?(node, scope) && record?(node.receiver, scope, owner)
        when Prism::OrNode then record?(node.left, scope, owner) || record?(node.right, scope, owner)
        else false
        end
      end

      def returns_value?(call, scope)
        NOT_RECORDS.include?(call.name.to_s) || scope.columns.include?(call.name.to_s)
      end

      # A chain rooted at File, FileUtils, Dir, ENV, Pathname, `Pathname()` or Rails.root.
      def non_record?(receiver)
        return true if framework_object?(receiver)

        receiver = receiver.receiver while receiver.is_a?(Prism::CallNode) && receiver.receiver && !rails_root?(receiver)
        return true if rails_root?(receiver)
        return receiver.receiver.nil? && receiver.name == :Pathname if receiver.is_a?(Prism::CallNode)

        (receiver.is_a?(Prism::ConstantReadNode) || receiver.is_a?(Prism::ConstantPathNode)) &&
          NON_RECORD_CONSTANTS.include?(receiver.slice.delete_prefix("::"))
      end

      # `session`, `cookies`, `flash`, and anything named for a cache or a Redis client, by its last name.
      def framework_object?(node)
        name = case node
        when Prism::CallNode, Prism::LocalVariableReadNode, Prism::InstanceVariableReadNode, Prism::GlobalVariableReadNode,
             Prism::ConstantReadNode, Prism::ConstantPathNode then node.name.to_s
        end
        !name.nil? && (FRAMEWORK_OBJECTS.include?(name) || name.match?(CLIENT_NAME))
      end

      def rails_root?(node)
        node.is_a?(Prism::CallNode) && node.name == :root && node.receiver&.slice&.delete_prefix("::") == "Rails"
      end

      # A name written inside a namespace is the model's last segments.
      def model?(written, models)
        models.include?(written) || models.any? { |name| name.end_with?("::#{written}") }
      end
    end
  end
end
