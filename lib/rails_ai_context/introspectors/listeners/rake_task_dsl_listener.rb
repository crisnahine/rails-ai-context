# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    module Listeners
      # Detects rake task DSL patterns via Prism AST:
      # namespace :name, desc "...", task :name => [:dep1], multitask.
      # Each entry carries its byte offset, and a namespace its end, so a reader can scope tasks.
      class RakeTaskDslListener < BaseListener
        def on_call_node_enter(node)
          return unless node.receiver.nil?

          case node.name
          when :namespace
            extract_namespace(node)
          when :desc
            extract_desc(node)
          when :task, :multitask
            extract_task(node)
          end
        end

        private

        def extract_namespace(node)
          name = extract_first_symbol(node)
          return if name == RailsAiContext::Confidence::INFERRED

          @results << {
            type:       :namespace,
            name:       name.to_s,
            location:   node.location.start_line,
            offset:     node.location.start_offset,
            end_offset: node.location.end_offset
          }
        end

        def extract_desc(node)
          args = node.arguments&.arguments || []
          text = args.first
          return unless text.is_a?(Prism::StringNode)

          @results << {
            type:        :desc,
            description: text.unescaped,
            location:    node.location.start_line,
            offset:      node.location.start_offset
          }
        end

        def extract_task(node)
          args = node.arguments&.arguments || []
          return if args.empty?

          first = args.first
          task_args = []

          case first
          when Prism::SymbolNode, Prism::StringNode
            name = first.unescaped
            deps = extract_task_deps(args)
            # Check for task arguments: task :name, [:arg1, :arg2] => :environment
            # Prism parses this as SymbolNode + KeywordHashNode where key is ArrayNode
            task_args, extra_deps = extract_args_from_keyword_hash(args)
            deps = extra_deps if extra_deps.any?
          when Prism::KeywordHashNode, Prism::HashNode
            # task name: :dep or task name: [:dep1, :dep2]
            name, deps = extract_hash_task(first)
          else
            return
          end

          return unless name

          @results << {
            type:     :task,
            name:     name,
            deps:     deps || [],
            args:     task_args,
            location: node.location.start_line,
            offset:   node.location.start_offset
          }
        end

        # Handle: task :name, [:arg1, :arg2] => :environment
        # Prism parses the array-key hash as a KeywordHashNode with an ArrayNode key
        def extract_args_from_keyword_hash(args)
          args.each do |arg|
            next unless arg.is_a?(Prism::KeywordHashNode) || arg.is_a?(Prism::HashNode)

            arg.elements.each do |assoc|
              next unless assoc.is_a?(Prism::AssocNode) && assoc.key.is_a?(Prism::ArrayNode)

              task_args = assoc.key.elements.filter_map { |e|
                e.is_a?(Prism::SymbolNode) ? e.unescaped : nil
              }
              deps = literal_strings(assoc.value)
              return [ task_args, deps ]
            end
          end
          [ [], [] ]
        end

        def extract_task_deps(args)
          args.each do |arg|
            next unless arg.is_a?(Prism::KeywordHashNode) || arg.is_a?(Prism::HashNode)
            return extract_deps_from_hash_values(arg)
          end
          []
        end

        def extract_hash_task(hash_node)
          assoc = hash_node.elements.first
          return [ nil, [] ] unless assoc.is_a?(Prism::AssocNode)

          name = literal_string(assoc.key)

          deps = literal_strings(assoc.value)
          [ name, deps ]
        end

        def extract_deps_from_hash_values(hash_node)
          hash_node.elements.flat_map { |assoc|
            next [] unless assoc.is_a?(Prism::AssocNode)
            literal_strings(assoc.value)
          }
        end
      end
    end
  end
end
