# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    module Listeners
      # Detects Gemfile DSL patterns via Prism AST:
      # gem "name", "version", options...
      # group :development, :test do ... end
      # ruby "3.3.6", and an :unknown_gems entry for each call that adds gems the file does not name.
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
          when :eval_gemfile
            extract_eval_gemfile(node)
          when :ruby
            extract_ruby(node)
          when :gemspec
            unknown_gems(node)
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
          return unknown_gems(node) unless name_arg.is_a?(Prism::StringNode)

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

        # `eval_gemfile "Gemfile.local"`, or `File.expand_path("x", __dir__)`;
        # Bundler reads the path from the evaluating file's directory.
        def extract_eval_gemfile(node)
          arg = node.arguments&.arguments&.first
          if arg.is_a?(Prism::CallNode) && arg.name == :expand_path && arg.receiver&.slice == "File"
            inner = arg.arguments&.arguments || []
            arg = inner.first if inner.size == 2 && inner.last.slice == "__dir__"
          end
          return unknown_gems(node) unless arg.is_a?(Prism::StringNode)

          @results << {
            type:     :eval_gemfile,
            path:     arg.unescaped,
            groups:   @current_groups.flatten.uniq,
            location: node.location.start_line
          }
        end

        # Bundler takes `engine:` and `engine_version:` beside the version.
        def extract_ruby(node)
          options = extract_keyword_nodes(node)
          @results << {
            type:           :ruby,
            version:        literal_string(node.arguments&.arguments&.first),
            engine:         literal_string(options[:engine]),
            engine_version: literal_string(options[:engine_version]),
            location:       node.location.start_line
          }
        end

        def unknown_gems(node)
          @results << { type: :unknown_gems, call: node.name, location: node.location.start_line }
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
