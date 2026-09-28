# frozen_string_literal: true

require "set"

module RailsAiContext
  module Introspectors
    module MigrationReplay
      # The methods a migration calls: its own private methods, the modules it
      # includes, the app's schema classes, and a table file's create_table wrappers.
      module Helpers
        module_function

        SCHEMA_STATEMENTS = (Listeners::MigrationDslListener::ALL_ACTIONS.to_a +
                             %i[remove_columns create_join_table add_timestamps]).to_set.freeze

        # A method name that says it changes the schema, one word at a time
        # (execute_drop, add_temp_column).
        SCHEMA_VERBS = %w[add alter change create drop remove rename].to_set.freeze

        # The line ranges of the methods here that pass their first parameter
        # and the caller's block on to create_table, like Tables::Base.create_unlogged_table.
        def table_helper_defs(tree, helpers)
          return [] unless tree

          AstWalk.each(tree).filter_map do |node|
            next unless node.is_a?(Prism::DefNode) && node.parameters&.block &&
                        (param = node.parameters.requireds.first).is_a?(Prism::RequiredParameterNode) &&
                        wraps_create_table?(node.body, param.name, helpers)

            helpers << node.name
            node.location.start_line..node.location.end_line
          end
        rescue StandardError, ScriptError => e
          RailsAiContext.debug_fail(e, [], label: "table_helper_defs")
        end

        def wraps_create_table?(body, param, helpers)
          return false if body.nil?

          AstWalk.each(body).any? do |node|
            next false unless node.is_a?(Prism::CallNode) && node.receiver.nil? &&
                              (node.name == :create_table || helpers.include?(node.name))

            first = node.arguments&.arguments&.first
            first.is_a?(Prism::LocalVariableReadNode) && first.name == param && node.block.is_a?(Prism::BlockArgumentNode)
          end
        end

        # A migration's private methods run where up or change call them, and
        # not when only down does; a rescue clause is the exceptional path.
        def follow_local_methods(tree, entries, wrappers)
          klass = tree && migration_class(tree)
          return entries unless klass

          body = klass.body.is_a?(Prism::StatementsNode) ? klass.body.body : []
          defs = body.select { |n| n.is_a?(Prism::DefNode) && n.receiver.nil? }
          entry_defs = defs.select { |d| %i[up change].include?(d.name) }
          local = defs.reject { |d| %i[up change down].include?(d.name) || wrappers.include?(d.name) }.to_h { |d| [ d.name, d ] }
          rescues = defs.flat_map { |d| AstWalk.each(d).grep(Prism::RescueNode) }
            .map { |node| node.location.start_line..node.location.end_line }

          hidden = local.values.map { |d| d.location.start_line..d.location.end_line } + rescues
          kept = entries.reject { |e| hidden.any? { |range| range.cover?(e[:location]) } }

          expanded = []
          order = 0
          splice = lambda do |def_node, anchor, stack|
            range = def_node.location.start_line..def_node.location.end_line
            own = entries.select { |e| range.cover?(e[:location]) && rescues.none? { |r| r.cover?(e[:location]) } }
            called = calls(def_node).select do |call|
              call.receiver.nil? && local.key?(call.name) && !stack.include?(call.name) &&
                rescues.none? { |r| r.cover?(call.location.start_line) }
            end
            items = own.map { |e| [ e[:location], 0, e ] } + called.map { |c| [ c.location.start_line, 1, c ] }
            items.sort_by { |line, kind, _| [ line, kind ] }.each do |_, kind, item|
              if kind.zero?
                expanded << item.merge(location: anchor || item[:location], order: (order += 1))
              else
                splice.call(local[item.name], anchor || item.location.start_line, stack + [ item.name ])
              end
            end
          end
          entry_defs.each { |d| splice.call(d, nil, []) }

          # A file with neither up nor change keeps its source order.
          entry_ranges = entry_defs.map { |d| d.location.start_line..d.location.end_line }
          kept.reject { |e| entry_ranges.any? { |range| range.cover?(e[:location]) } } + expanded
        end

        def migration_class(tree)
          AstWalk.each(tree).find do |node|
            node.is_a?(Prism::ClassNode) && node.body.is_a?(Prism::StatementsNode) &&
              node.body.body.any? { |n| n.is_a?(Prism::DefNode) && n.receiver.nil? && %i[up change].include?(n.name) }
          end
        end

        # Calls into included modules: a one-statement helper replays with the
        # caller's arguments in place, another that reaches the schema is counted.
        def module_helper_entries(tree, root)
          return [] unless tree && root

          helpers = included_module_names(tree).each_with_object({}) do |name, found|
            found.merge!(module_methods(name, root))
          end
          return [] if helpers.empty?

          calls(tree).each_with_object([]) do |call, entries|
            next unless call.receiver.nil? && helpers.key?(call.name)

            source = forwarded_source(helpers[call.name], call)
            if source
              listener = { migration: -> { Listeners::MigrationDslListener.new } }
              SourceIntrospector.walk_source(source, listener)[:migration].each do |entry|
                entries << entry.merge(location: call.location.start_line)
              end
            elsif reaches_schema?(helpers[call.name], helpers)
              entries << { kind: :not_replayed, location: call.location.start_line }
            end
          end
        end

        # Whether a method's body calls a schema statement, directly or through
        # the other methods it is given (a module's own helpers).
        def reaches_schema?(def_node, methods, seen = Set.new)
          return false if def_node.nil? || seen.include?(def_node.name)

          seen << def_node.name
          calls(def_node).any? do |call|
            call.receiver.nil? && (SCHEMA_STATEMENTS.include?(call.name) ||
              (methods.key?(call.name) && reaches_schema?(methods[call.name], methods, seen)))
          end
        end

        # A class method on one of the app's constants under lib/ that could
        # change the schema, marked so the note says it was not replayed.
        def app_constant_call_markers(tree, root)
          return [] unless tree && root

          calls(tree).filter_map do |call|
            receiver = call.receiver
            next unless receiver.is_a?(Prism::ConstantReadNode) || receiver.is_a?(Prism::ConstantPathNode)

            file = File.join(root, "lib", "#{receiver.slice.delete_prefix('::').underscore}.rb")
            next unless File.file?(file) && schema_class_method?(file, call.name)

            { kind: :not_replayed, location: call.location.start_line }
          end
        end

        # A class method named for a schema verb, or whose body reaches a schema statement.
        def schema_class_method?(file, name)
          return true if name.to_s.split("_").any? { |word| SCHEMA_VERBS.include?(word) }

          content = RailsAiContext::SafeFile.read(file, max_size: RailsAiContext.configuration.max_file_size)
          tree = content && AstCache.parse_string(content)&.value
          return false unless tree

          methods = AstWalk.each(tree).select { |node| node.is_a?(Prism::DefNode) && node.receiver.is_a?(Prism::SelfNode) }
            .to_h { |node| [ node.name, node ] }
          reaches_schema?(methods[name], methods)
        end

        def included_module_names(tree)
          calls(tree).filter_map do |call|
            next unless call.receiver.nil? && %i[include extend].include?(call.name)

            arg = call.arguments&.arguments&.first
            arg.slice.delete_prefix("::") if arg.is_a?(Prism::ConstantReadNode) || arg.is_a?(Prism::ConstantPathNode)
          end.uniq
        end

        # The module's instance methods, from the file under lib/ or app/*/
        # its name resolves to the way Zeitwerk would find it.
        def module_methods(name, root)
          relative = "#{name.underscore}.rb"
          file = ([ File.join(root, "lib", relative) ] + Dir.glob(File.join(root, "app", "*", relative))).find { |f| File.file?(f) }
          return {} unless file

          content = RailsAiContext::SafeFile.read(file, max_size: RailsAiContext.configuration.max_file_size)
          tree = content && AstCache.parse_string(content)&.value
          mod = tree && DeclaredConstant.module_node(tree, name)
          return {} unless mod&.body.is_a?(Prism::StatementsNode)

          mod.body.body.each_with_object({}) { |node, found| found[node.name] = node if node.is_a?(Prism::DefNode) && node.receiver.nil? }
        rescue StandardError, ScriptError => e
          RailsAiContext.debug_fail(e, {}, label: "module_methods")
        end

        def calls(node)
          AstWalk.each(node).grep(Prism::CallNode)
        end

        # The helper's one statement with the caller's arguments in place of its
        # parameters; nil when it is more than that or the arguments do not fit.
        def forwarded_source(helper, call)
          statements = helper.body.is_a?(Prism::StatementsNode) ? helper.body.body : []
          return nil unless statements.size == 1

          inner = statements.first
          return nil unless inner.is_a?(Prism::CallNode) && inner.receiver.nil? &&
                            Listeners::MigrationDslListener::ALL_ACTIONS.include?(inner.name)

          values = parameter_values(helper.parameters, call)
          return nil unless values

          substitute(inner, values)
        end

        # {param name => caller's argument source}, or nil when they do not line up.
        def parameter_values(params, call)
          return {} if params.nil? && call.arguments.nil?
          return nil if params.nil? || params.rest || params.keyword_rest || params.posts.any? || call.block
          # Only plain parameters: a destructured one (`(a, b)`) has no name to fill.
          plain = [ Prism::RequiredParameterNode, Prism::OptionalParameterNode,
                    Prism::RequiredKeywordParameterNode, Prism::OptionalKeywordParameterNode ]
          return nil unless (params.requireds + params.optionals + params.keywords).all? { |p| plain.any? { |k| p.is_a?(k) } }

          # A copy: the node belongs to the shared parse cache.
          args = (call.arguments&.arguments || []).dup
          keywords = args.last.is_a?(Prism::KeywordHashNode) ? args.pop.elements : []
          return nil if args.any? { |a| a.is_a?(Prism::SplatNode) } || keywords.any? { |e| !e.is_a?(Prism::AssocNode) }

          positional = params.requireds + params.optionals
          return nil if args.size < params.requireds.size || args.size > positional.size

          values = {}
          positional.each_with_index do |param, i|
            values[param.name] = args[i] ? args[i].slice : param.value.slice
          end
          given = keywords.to_h { |e| [ e.key.is_a?(Prism::SymbolNode) ? e.key.unescaped.to_sym : nil, e.value.slice ] }
          params.keywords.each do |param|
            if given.key?(param.name)
              values[param.name] = given.delete(param.name)
            elsif param.is_a?(Prism::OptionalKeywordParameterNode)
              values[param.name] = param.value.slice
            else
              return nil
            end
          end
          given.empty? ? values : nil
        end

        # The call's source with each parameter read replaced, back to front so
        # the offsets hold; a local that is no parameter makes it unreadable.
        def substitute(inner, values)
          reads = AstWalk.each(inner).grep(Prism::LocalVariableReadNode)
          return nil unless reads.all? { |read| values.key?(read.name) }

          source = inner.slice.dup
          base = inner.location.start_offset
          reads.sort_by { |read| -read.location.start_offset }.each do |read|
            source[read.location.start_offset - base, read.location.length] = values[read.name]
          end
          source
        end
      end
    end
  end
end
