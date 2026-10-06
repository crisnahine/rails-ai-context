# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    module Listeners
      # Reads settings declared on a config object in an initializer:
      #
      #   config.timeout_in = 30.minutes        → path [:timeout_in], assignment
      #   config.action_mailer.delivery = :smtp → path [:action_mailer, :delivery], assignment
      #   config.jwt do |jwt| ... end           → path [:jwt], not an assignment, write :block
      #   config.hosts << "x"                   → path [:hosts, :<<], write :call
      #   config.headers["X"] = "y"             → path [:headers, :[]=], write :call
      #   config.filter_parameters += [:pin]    → path [:filter_parameters], write :operator
      #   config.paths["app/views"] << "x"      → path [:paths, :<<], write :call
      #
      # The chain is matched from a root receiver name, so
      # `Rails.application.config.assets.paths = x` reports [:assets, :paths].
      # The root `on_load(:active_record)` reads `self`, or the block's one parameter, inside that hook's block.
      class ConfigAssignmentListener < BaseListener
        DEFAULT_ROOTS = %w[config].freeze
        SETTER = /\A[A-Za-z_]\w*=\z/
        # A predicate or comparison with arguments reads a setting rather than changing it.
        MUTATOR = /\A(?:<<|\[\]=|[A-Za-z_]\w*!?)\z/

        def initialize(*roots)
          super()
          names = roots.flatten.map(&:to_s)
          @roots = (names.empty? ? DEFAULT_ROOTS : names).to_set
          @conditions = []
          @statements = Set.new.compare_by_identity
          @def_params = []
          @self_roots = []
        end

        # A call with arguments changes a setting only when it runs as a statement;
        # `x = config.root.join("tmp")` reads one.
        def on_statements_node_enter(node)
          @statements.merge(node.body)
        end

        def on_rescue_modifier_node_enter(node)
          @statements << node.expression if @statements.include?(node)
        end

        # Inside `def initialize(config)` the local is that argument, not the app's config.
        def on_def_node_enter(node)
          params = node.parameters
          names = params ? params.child_nodes.flatten.compact.flat_map { |p| p.respond_to?(:name) ? [ p.name ] : [] } : []
          @def_params.push(names)
          @self_roots.push(nil)
        end

        def on_def_node_leave(_node)
          @def_params.pop
          @self_roots.pop
        end

        # The branch an assignment sits in. Rails' own generated
        # `config/environments/development.rb` assigns `perform_caching` in
        # both halves of one `if`, and reporting the first as the value made
        # this tool disagree with the running app.
        def on_if_node_enter(node)
          @conditions.push(condition_text(node.predicate))
        end

        def on_if_node_leave(_node)
          @conditions.pop
        end

        def on_unless_node_enter(node)
          @conditions.push("not #{condition_text(node.predicate)}")
        end

        def on_unless_node_leave(_node)
          @conditions.pop
        end

        def on_else_node_enter(_node)
          @conditions.push("else")
        end

        def on_else_node_leave(_node)
          @conditions.pop
        end

        def on_call_node_enter(node)
          if (hook = load_hook(node)) then @self_roots.push(hook) end
          return if node.receiver.nil?

          if node.name.to_s.match?(SETTER)
            record_assignment(node)
          elsif node.arguments
            return unless node.name.to_s.match?(MUTATOR) && @statements.include?(node)

            # `config.hosts << "a" << "b"` writes through the inner call.
            receiver = node.receiver
            @statements << receiver if receiver.is_a?(Prism::CallNode) && receiver.arguments && receiver.name.to_s.match?(MUTATOR)
            record_write(node.receiver, node.name, :call, node)
          else
            record_reference(node)
          end
        end

        def on_call_node_leave(node)
          @self_roots.pop if load_hook(node)
        end

        def on_call_operator_write_node_enter(node)
          record_write(node.receiver, node.read_name, :operator, node)
        end

        def on_call_or_write_node_enter(node)
          record_write(node.receiver, node.read_name, :operator, node)
        end

        def on_call_and_write_node_enter(node)
          record_write(node.receiver, node.read_name, :operator, node)
        end

        private

        # `ActiveSupport.on_load(:active_record) { |base| }` names the root `on_load(:active_record)`,
        # as [root, the parameter that is the base].
        def load_hook(node)
          receiver = node.receiver
          return unless node.name == :on_load && node.block.is_a?(Prism::BlockNode) &&
                        (receiver.is_a?(Prism::ConstantReadNode) || receiver.is_a?(Prism::ConstantPathNode)) &&
                        constant_path_string(receiver) == "ActiveSupport"

          hook = node.arguments&.arguments&.first
          return unless hook.is_a?(Prism::SymbolNode)

          base = Array(node.block.parameters&.parameters&.requireds).first
          [ "on_load(:#{hook.unescaped})", (base.name if base.is_a?(Prism::RequiredParameterNode)) ]
        end

        def record_assignment(node)
          prefix = chain_path(node.receiver)
          return unless prefix
          return record_write(node.receiver, node.name, :call, node) if prefix.include?(:[])

          value_node = node.arguments&.arguments&.first
          setting = node.name.to_s.delete_suffix("=").to_sym

          # Redacted here rather than by each consumer: an initializer's
          # `config.secret_key = "..."` is a real credential, and a new reader
          # of this listener is safe without remembering anything.
          value = value_node ? extract_value(value_node) : nil
          # The whole path, not the leaf: `primary_key` is ordinary
          # ActiveRecord vocabulary, and only `active_record.encryption`
          # around it says the value is a credential.
          path = prefix + [ setting ]

          # One decision for both fields, or a reader pattern-matching the
          # marker finds it on one and the datum on the other.
          redacted = RailsAiContext::Redaction.redact_assignment(
            path, value: value, source: value_node && NodeSource.text(value_node)
          )

          entry = {
            path:       path,
            assignment: true,
            value:      redacted[:value],
            source:     redacted[:source],
            condition:  @conditions.compact.last,
            location:   node.location.start_line
          }
          # Read off the node rather than the source, which is redacted under a secret-shaped key.
          if (call = config_for(value_node))
            entry[:config_for] = call
          end
          @results << entry
        end

        # `config_for(:name, env: "production")`: the YAML file it reads, nil for a path
        # that is not a literal, and its env:, :expression when that is not a literal.
        def config_for(node)
          return nil unless node.is_a?(Prism::CallNode) && node.name == :config_for
          return nil unless node.receiver.nil? || rails_call?(node.receiver, "Rails.application")

          argument = node.arguments&.arguments&.first
          env = extract_keyword_nodes(node)[:env]
          env = nil if env && rails_call?(env, "Rails.env")
          { argument: argument && RailsAiContext::Redaction.call(NodeSource.text(argument)), file: config_for_file(argument),
            env: env && (literal_string(env) || :expression) }.compact
        end

        # Rails reads `config/<name>.yml` for a name, and the Pathname itself for `Rails.root.join(...)`.
        def config_for_file(node)
          return nil if node.nil? || node.is_a?(Prism::KeywordHashNode)

          name = literal_string(node)
          return "config/#{name}.yml" if name
          return nil unless node.is_a?(Prism::CallNode) && node.name == :join && rails_call?(node.receiver, "Rails.root")

          parts = (node.arguments&.arguments || []).map { |part| literal_string(part) }
          File.join(*parts) if parts.any? && parts.all?
        end

        def rails_call?(node, text)
          node.is_a?(Prism::CallNode) && NodeSource.text(node).delete_prefix("::") == text
        end

        def condition_text(node)
          return nil unless node

          NodeSource.text(node).gsub(/\s+/, " ").strip
        end

        # A bare `config.jwt` reference, with or without a block. Enough to tell
        # that a section of the initializer exists at all.
        def record_reference(node)
          prefix = chain_path(node.receiver)
          return unless prefix && !prefix.include?(:[])

          entry = {
            path:       prefix + [ node.name ],
            assignment: false,
            value:      nil,
            source:     nil,
            location:   node.location.start_line
          }
          entry[:write] = :block if node.block
          @results << entry
        end

        # A setting changed without `=`: a call with arguments or an operator write.
        def record_write(receiver, name, kind, node)
          return if receiver.nil?

          prefix = chain_path(receiver)
          return unless prefix

          # An element of a setting (`config.paths["app/views"]`) is changed through it.
          setting = prefix.take_while { |part| part != :[] }
          return if setting.empty? && prefix.include?(:[])

          path = setting + [ name ]
          # A one-argument call (`<<`, `merge!`) carries what it adds; `[]=` and the like carry a key too.
          args = kind == :call ? node.arguments&.arguments : nil
          value = args&.size == 1 ? extract_value(args.first) : nil
          redacted = RailsAiContext::Redaction.redact_assignment(path, value: value, source: NodeSource.text(node))
          @results << {
            path:       path,
            assignment: false,
            write:      kind,
            value:      redacted[:value],
            source:     redacted[:source],
            location:   node.location.start_line
          }
        end

        # Returns the path segments after the root, or nil when the chain is not
        # rooted at a configured root name.
        def chain_path(node)
          parts = []
          current = node

          while current
            case current
            when Prism::CallNode
              return nil unless current.block.nil? && (current.arguments.nil? || current.name == :[])
              parts.unshift(current.name)
              current = current.receiver
            when Prism::LocalVariableReadNode
              return nil if @def_params.last&.include?(current.name)

              root, base = @self_roots.last
              parts.unshift(base && current.name == base ? root.to_sym : current.name)
              current = nil
            when Prism::ConstantReadNode, Prism::ConstantPathNode
              parts.unshift(constant_path_string(current).to_sym)
              current = nil
            when Prism::SelfNode
              return nil unless @self_roots.last

              parts.unshift(@self_roots.last.first.to_sym)
              current = nil
            else
              return nil
            end
          end

          root_index = parts.rindex { |part| @roots.include?(part.to_s) }
          return nil unless root_index && app_owned?(parts.first(root_index))

          parts[(root_index + 1)..] || []
        end

        # What the root hangs off: nothing, a local (`app`), `Rails.application` or
        # the app's Application class. `OmniAuth.config` is another library's config.
        def app_owned?(prefix)
          first = prefix.first.to_s
          prefix.empty? || !first.match?(/\A[A-Z]/) || prefix.first(2) == %i[Rails application] ||
            first == "Application" || first.end_with?("::Application")
        end
      end
    end
  end
end
