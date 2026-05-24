# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    module Listeners
      # Detects Gemfile DSL patterns via Prism AST:
      # gem "name", "version", options...
      # group :development, :test do ... end
      class GemfileDslListener < BaseListener
        def initialize
          super
          @current_groups = []
        end

        def on_call_node_enter(node)
          return unless node.receiver.nil?

          case node.name
          when :gem
            extract_gem(node)
          when :source
            extract_source(node)
          when :group
            return unless node.block

            groups = extract_symbol_args(node)
            @current_groups.push(groups)

            @results << {
              type:     :group,
              groups:   groups,
              location: node.location.start_line
            }
          end
        end

        def on_call_node_leave(node)
          return unless node.receiver.nil? && node.name == :group && node.block

          @current_groups.pop
        end

        private

        def extract_gem(node)
          args = node.arguments&.arguments || []
          return if args.empty?

          name_arg = args.first
          return unless name_arg.is_a?(Prism::StringNode)

          name = name_arg.unescaped
          version = nil
          options = {}

          args[1..].each do |arg|
            case arg
            when Prism::StringNode
              version = arg.unescaped
            when Prism::KeywordHashNode
              options = hash_node_to_hash(arg)
            end
          end

          # Inherit groups from enclosing group blocks
          groups = options.delete(:group)
          groups = Array(groups) if groups
          groups ||= @current_groups.flatten.uniq if @current_groups.any?
          groups ||= []

          @results << {
            type:     :gem,
            name:     name,
            version:  version,
            options:  options,
            groups:   groups,
            location: node.location.start_line
          }
        end

        def extract_source(node)
          args = node.arguments&.arguments || []
          url_arg = args.first
          return unless url_arg.is_a?(Prism::StringNode)

          @results << {
            type:     :source,
            url:      url_arg.unescaped,
            location: node.location.start_line
          }
        end
      end
    end
  end
end
