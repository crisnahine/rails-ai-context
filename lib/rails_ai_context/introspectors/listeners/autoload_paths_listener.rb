# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    module Listeners
      # Autoload roots an app adds in config/application.rb, each with the list railties keeps it in:
      #
      #   config.autoload_paths << "lib_static"          → ["lib_static", :autoload]
      #   config.eager_load_paths += %W(#{config.root}/x) → ["x", :eager]
      #   config.autoload_lib(ignore: %w[tasks])          → ["lib", :autoload], and autoload_lib_once → :once
      #   config.paths.add "x", eager_load: true          → ["x", :paths_eager], autoload: → :paths_autoload,
      #                                                      autoload_once: → :paths_once
      #   config.autoload_paths = ["x"]                   → [:reset, :autoload], then ["x", :autoload]
      #
      #   config.autoload_paths += Dir["#{config.root}/x/**/"] → ["x/**/", :autoload, :glob]
      #
      # Literal paths and literal Dir globs only; a root built at run time stays unread.
      class AutoloadPathsListener < BaseListener
        include LiteralPaths

        PATH_SETTINGS = { autoload_paths: :autoload, eager_load_paths: :eager, autoload_once_paths: :once }.freeze
        ASSIGNED = PATH_SETTINGS.transform_keys { |name| :"#{name}=" }.freeze

        def on_call_node_enter(node)
          return @results << [ "lib", node.name == :autoload_lib ? :autoload : :once ] if AutoloadIgnoreListener::AUTOLOAD_LIB.include?(node.name) && node.receiver
          return collect_added_path(node) if node.name == :add && paths_receiver?(node.receiver)
          return collect_assigned(node) if node.receiver && ASSIGNED.key?(node.name)
          return unless APPENDING.include?(node.name) && path_setting?(node.receiver)

          @kind = PATH_SETTINGS[node.receiver.name]
          Array(node.arguments&.arguments).each { |argument| collect_paths(argument) }
        end

        # `-=` removes a root; only an addition adds one.
        def on_call_operator_write_node_enter(node)
          return unless PATH_SETTINGS.key?(node.read_name) && node.binary_operator == :+

          @kind = PATH_SETTINGS[node.read_name]
          collect_paths(node.value)
        end

        private

        # `config.paths.add "lib/base", eager_load: true` is railties' own way
        # of adding a root; the same call without those options adds no code.
        def collect_added_path(node)
          arguments = Array(node.arguments&.arguments)
          options = arguments.find { |argument| argument.is_a?(Prism::KeywordHashNode) }
          @kind = options && added_kind(options)
          collect_paths(arguments.first) if @kind
        end

        # `config.autoload_paths = [...]` replaces what the list held; a value built from the list itself
        # (`+`, `|`, `[*list, ...]`, `.uniq`) adds to it; any other value leaves the list as it was, unread.
        def collect_assigned(node)
          @kind = ASSIGNED[node.name]
          value = node.arguments&.arguments&.first
          setting = node.name.to_s.chomp("=").to_sym
          operands = operands_of(value, setting) or return
          reset = operands.none? { |operand| self_reference?(operand, setting) }
          @results << [ :reset, @kind ] if reset
          operands.each { |operand| collect_paths(operand) unless self_reference?(operand, setting) }
        end

        # The list nodes a value is made of when it is a sum, a union or a splatting array of literals and the list itself; nil otherwise.
        def operands_of(value, setting)
          value = value.receiver while value.is_a?(Prism::CallNode) && %i[uniq compact flatten].include?(value.name) && value.arguments.nil? && value.receiver
          value = value.body.body.first if value.is_a?(Prism::ParenthesesNode) && value.body.is_a?(Prism::StatementsNode) && value.body.body.size == 1
          return [ value ] if self_reference?(value, setting) || dir_glob?(value)

          case value
          when Prism::ArrayNode
            splats, rest = value.elements.partition { |element| element.is_a?(Prism::SplatNode) }
            return unless splats.all? { |splat| self_reference?(splat.expression, setting) }

            splats.empty? ? [ value ] : [ splats.first.expression, *rest ]
          when Prism::CallNode
            return unless %i[+ |].include?(value.name) && value.receiver && value.arguments&.arguments&.size == 1

            parts = [ value.receiver, value.arguments.arguments.first ].map { |part| operands_of(part, setting) }
            return if parts.any?(&:nil?)

            parts.flatten
          end
        end

        def dir_glob?(node)
          node.is_a?(Prism::CallNode) && %i[[] glob].include?(node.name) && node.receiver&.slice&.delete_prefix("::") == "Dir"
        end

        # The first argument of a Dir glob, as a path pattern under the app; a base: or a path outside the app stays unread.
        def collect_call_path(node)
          return if dir_glob?(node.receiver)
          return super unless dir_glob?(node)

          arguments = Array(node.arguments&.arguments)
          pattern = arguments.first
          return if arguments.any?(Prism::KeywordHashNode) || (pattern.is_a?(Prism::StringNode) && pattern.unescaped.start_with?("/"))

          @glob = true
          collect_paths(pattern)
        ensure
          @glob = false
        end

        def self_reference?(node, setting)
          node.is_a?(Prism::CallNode) && node.name == setting && node.arguments.nil?
        end

        # An autoload path comes before an eager load one in railties' lists, which hold the once paths apart.
        def added_kind(options)
          set = options.elements.filter_map do |element|
            element.key.slice.delete_suffix(":") if element.is_a?(Prism::AssocNode) && element.value.is_a?(Prism::TrueNode)
          end
          { "autoload" => :paths_autoload, "eager_load" => :paths_eager, "autoload_once" => :paths_once }.find { |key, _| set.include?(key) }&.last
        end

        def record_path(path)
          @results << (@glob ? [ path, @kind, :glob ] : [ path, @kind ])
        end

        def path_setting?(node)
          node.is_a?(Prism::CallNode) && PATH_SETTINGS.key?(node.name)
        end
      end
    end
  end
end
