# frozen_string_literal: true

require "set"

module RailsAiContext
  module Introspectors
    # The join tables every has_and_belongs_to_many under the app's code and
    # lib names, patches and engines included: a join table has no model.
    module HabtmJoinTables
      module_function

      SKIP = %w[node_modules tmp log vendor spec test].freeze

      # @param models [Hash] the payload's models section, for owner tables
      # @return [Set<String>]
      def declared(root, models = {})
        root = File.expand_path(root.to_s)
        sources = ruby_files(root).filter_map do |path|
          source = SafeFile.read(path, max_size: RailsAiContext.configuration.max_file_size)
          [ path, source ] if source
        end
        declarations = sources.flat_map do |_, source|
          source.include?("has_and_belongs_to_many") ? habtm_calls(source) : []
        end
        includers = nil
        declarations.each_with_object(Set.new) do |(call, owner), found|
          table = join_table(call, root)
          if table.nil?
            owners = if owner[:module]
              (includers ||= Includers.of(root, sources, module_owners(declarations), macros: %i[include prepend]))[owner[:module]] || []
            else
              [ owner[:class] ]
            end
            owners.each { |name| found << derive(call, name, models) }
            found.delete(nil)
          else
            found << table
          end
        end
      rescue StandardError, ScriptError => e
        RailsAiContext.debug_fail(e, Set.new, label: "habtm_join_tables")
      end

      # Rails' own name (the has_and_belongs_to_many builder, 7.0 and 8.1).
      def join_table_name(owner_table, other_table)
        [ owner_table.to_s, other_table.to_s ].sort.join("\0").gsub(/^(.*[._])(.+)\0\1(.+)/, '\1\2_\3').tr("\0", "_")
      end

      def ruby_files(root)
        ([ root ] + PathResolver.code_roots(root)).uniq.flat_map do |dir|
          %w[app lib].flat_map { |sub| FileWalk.each_file(File.join(dir, sub), skip: SKIP).select { |f| f.end_with?(".rb") } }
        end.uniq
      end

      # [[call, {class:} or {module:}], ...]: each habtm and what it runs on,
      # the innermost class, module or `X.class_eval` block around it.
      def habtm_calls(source)
        tree = AstCache.parse_string(source)&.value
        return [] unless tree

        owners = DeclaredConstant.constants(tree).map do |name, node|
          [ node.location, node.is_a?(Prism::ClassNode) ? { class: name } : { module: name } ]
        end
        calls = AstWalk.each(tree).grep(Prism::CallNode)
        calls.each do |node|
          next unless %i[class_eval class_exec].include?(node.name) && constant?(node.receiver) && node.block

          owners << [ node.location, { class: node.receiver.slice.delete_prefix("::") } ]
        end
        calls.filter_map do |node|
          next unless node.name == :has_and_belongs_to_many && node.receiver.nil?

          at = node.location.start_offset
          owner = owners.select { |loc, _| loc.start_offset < at && at < loc.end_offset }.max_by { |loc, _| loc.start_offset }
          [ node, owner.last ] if owner
        end
      end

      def module_owners(declarations)
        declarations.filter_map { |_, owner| owner[:module] }.uniq
      end

      def join_table(call, root)
        option = option_node(call, :join_table)
        return nil unless option

        case option
        when Prism::StringNode, Prism::SymbolNode then option.unescaped
        else TableName.affixed(option.slice, {}, root)
        end
      end

      def derive(call, owner, models)
        name = call.arguments&.arguments&.first
        return nil unless name.is_a?(Prism::SymbolNode) || name.is_a?(Prism::StringNode)

        name = name.unescaped
        class_option = option_node(call, :class_name)
        written = class_option.respond_to?(:unescaped) ? class_option.unescaped : name.to_s.camelize.singularize
        other = TableName.resolve_class(written, owner) { |candidate| candidate if models.key?(candidate) }
        join_table_name(TableName.for_model_name(owner, models), TableName.for_model_name(other, models))
      end

      def option_node(call, key)
        hash = (call.arguments&.arguments || []).find { |arg| arg.is_a?(Prism::KeywordHashNode) }
        pair = hash&.elements&.find { |e| e.is_a?(Prism::AssocNode) && e.key.is_a?(Prism::SymbolNode) && e.key.unescaped.to_sym == key }
        pair&.value
      end

      def constant?(node)
        node.is_a?(Prism::ConstantReadNode) || node.is_a?(Prism::ConstantPathNode)
      end
    end
  end
end
