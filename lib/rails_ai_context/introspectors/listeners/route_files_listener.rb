# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    module Listeners
      # The route files config/application.rb registers beyond config/routes.rb:
      #
      #   config.paths["config/routes.rb"] = %w(config/routes/api.rb config/routes.rb)
      #   config.paths["config/routes.rb"] << "config/routes/extra.rb"
      #   config.paths["config/routes.rb"].concat(Dir[Rails.root.join("config/routes/*.rb")])
      #
      # Literal paths and literal globs only; a list the app computes is
      # recorded as computed so the answer can say routes are missing.
      class RouteFilesListener < BaseListener
        include LiteralPaths

        ROUTES_KEY = "config/routes.rb"
        APPENDING = { :<< => :append, push: :append, append: :append, concat: :append,
                      unshift: :prepend, prepend: :prepend }.freeze

        def on_call_node_enter(node)
          if node.name == :[]= && routes_paths?(node)
            record(:set, Array(node.arguments&.arguments)[1])
          elsif APPENDING.key?(node.name) && node.receiver.is_a?(Prism::CallNode) && routes_paths?(node.receiver)
            Array(node.arguments&.arguments).each { |argument| record(APPENDING[node.name], argument) }
          end
        end

        private

        # `config.paths["config/routes.rb"]`, read or assigned.
        def routes_paths?(node)
          return false unless %i[[] []=].include?(node.name)
          return false unless node.receiver.is_a?(Prism::CallNode) && node.receiver.name == :paths

          key = Array(node.arguments&.arguments).first
          key.is_a?(Prism::StringNode) && key.unescaped == ROUTES_KEY
        end

        def record(op, value)
          paths = []
          globs = []
          collected = collect(value, paths, globs)
          return @results << { op: op, computed: true } unless collected

          entry = { op: op }
          entry[:paths] = paths if paths.any?
          entry[:globs] = globs if globs.any?
          @results << entry
        end

        # False when any part of the value is something the file computes.
        def collect(node, paths, globs)
          case node
          when Prism::StringNode then paths << node.unescaped
          when Prism::ArrayNode then node.elements.all? { |element| collect(element, paths, globs) }
          when Prism::CallNode then collect_call(node, paths, globs)
          else false
          end
        end

        def collect_call(node, paths, globs)
          case node.name
          # `%w(...).map { |p| Rails.root.join(p) }` names the same files.
          when :map then node.receiver.is_a?(Prism::ArrayNode) && collect(node.receiver, paths, globs)
          when :to_s then collect(node.receiver, paths, globs)
          when :join
            segments = app_root_join(node)
            segments ? (paths << File.join(*segments)) : false
          when :[], :glob
            return false unless dir_constant?(node.receiver)

            pattern = Array(node.arguments&.arguments).first
            literal = pattern.is_a?(Prism::StringNode) ? [ pattern.unescaped ] : (pattern.is_a?(Prism::CallNode) && app_root_join(pattern))
            literal ? (globs << File.join(*literal)) : false
          else false
          end
        end

        def dir_constant?(node)
          node.is_a?(Prism::ConstantReadNode) && node.name == :Dir
        end
      end
    end
  end
end
