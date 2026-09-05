# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    # The table a model reads, for the static tier and for every reader that
    # only has a model name in hand.
    #
    # Rails builds it as prefix + demodulized name + suffix, unless the class
    # assigns one itself or inherits its parent's table as an STI child. The
    # prefix and the suffix are declared by an enclosing module, in a file that
    # is not the model's, so reading them takes a second source. This module
    # reads those declarations and holds the two derivations; who walks the
    # namespace and the superclass chain is the caller's business, because only
    # it knows the other files.
    #
    # It reads table_name, table_name_prefix and table_name_suffix and nothing
    # else: a class-level `self.primary_key =` is just as invisible to the
    # static tier, and answering one of those and not the other would be worse
    # than answering neither.
    module TableName
      module_function

      # @param source [String] the model file's source
      # @param class_name [String] the qualified name of this file's class
      # @return [String, nil] the table the class assigns itself, nil when it
      #   assigns none or computes one
      def explicit(source, class_name)
        read(source, class_name) { |body| assigned(body, :table_name=) }
      end

      # @return [String, nil] the prefix the module declares, either form
      def prefix(source, module_name)
        affix(source, module_name, :table_name_prefix)
      end

      # @return [String, nil] the suffix the module declares, either form
      def suffix(source, module_name)
        affix(source, module_name, :table_name_suffix)
      end

      # Rails derives the table through the app's own inflector, and the file's
      # name already carries that inflection - Zeitwerk resolved the constant
      # from it. Underscoring the constant instead turns OAuthClientConfig into
      # o_auth_client_configs, a table no app has.
      def stem(path)
        File.basename(path.to_s, ".rb").pluralize
      end

      # The table a model name alone implies. The namespace is not part of it:
      # Rails demodulizes the name and lets table_name_prefix carry the
      # namespace, so `Admin::ActionLog` is `action_logs` until a prefix says
      # otherwise - never `admin/action_logs`.
      def derive(model_name)
        model_name.to_s.split("::").last.to_s.underscore.pluralize
      end

      # The table a caller's model name refers to: the one the model tier
      # recorded, which already knows the prefix and the STI parent, and the
      # convention only when no model answers to that name.
      #
      # @param models [Hash] the payload's models section
      def for_model_name(name, models = {})
        recorded = models.find do |model_name, details|
          model_name.to_s.casecmp?(name.to_s) && details.is_a?(Hash) && details[:table_name]
        end

        recorded ? recorded.last[:table_name] : derive(name)
      end

      def affix(source, module_name, name)
        read(source, module_name) do |body|
          assigned(body, :"#{name}=") || returned(body, name)
        end
      end

      def read(source, name)
        return nil unless source && name

        root = AstCache.parse_string(source)&.value
        return nil unless root

        body = body_of(root, [], name.to_s)
        body && yield(body)
      rescue StandardError, ScriptError => e
        $stderr.puts "[rails-ai-context] TableName failed: #{e.message}" if ENV["DEBUG"]
        nil
      end

      # The statements of the class or module declared under this exact
      # qualified name, nil when the file declares no such scope.
      def body_of(node, scope, name)
        case node
        when Prism::ClassNode, Prism::ModuleNode
          qualified = (scope + [ segment(node) ]).join("::")
          return statements(node) if qualified == name

          descend(node, scope + [ segment(node) ], name)
        else
          descend(node, scope, name)
        end
      end

      def descend(node, scope, name)
        node.child_nodes.compact.each do |child|
          found = body_of(child, scope, name)
          return found if found
        end
        nil
      end

      def statements(node)
        node.body.is_a?(Prism::StatementsNode) ? node.body.body : []
      end

      def segment(node)
        node.constant_path.slice.delete_prefix("::")
      end

      # `self.table_name = "x"`, only in this scope's own body.
      def assigned(body, name)
        call = body.find do |node|
          node.is_a?(Prism::CallNode) && node.name == name && node.receiver.is_a?(Prism::SelfNode)
        end
        call && literal(call.arguments&.arguments)
      end

      # `def self.table_name_prefix; "x"; end` - the form Rails documents and
      # the one apps write. A method that computes its value answers nothing.
      def returned(body, name)
        node = body.find do |child|
          child.is_a?(Prism::DefNode) && child.name == name && child.receiver.is_a?(Prism::SelfNode)
        end
        node && literal(node.body.is_a?(Prism::StatementsNode) ? node.body.body : nil)
      end

      def literal(nodes)
        return nil unless nodes.is_a?(Array) && nodes.size == 1

        case (node = nodes.first)
        when Prism::StringNode, Prism::SymbolNode then node.unescaped
        end
      end

      private_class_method :affix, :read, :body_of, :descend, :statements, :segment,
                           :assigned, :returned, :literal
    end
  end
end
