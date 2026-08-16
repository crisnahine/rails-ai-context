# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    # The constant a source file declares, for the static tier's naming.
    #
    # Camelizing the path is right often enough to look right always, and
    # wrong wherever the app registers an inflection: `app/controllers/
    # activitypub/` is `ActivityPub` in Mastodon and `Oauth` is nothing at all.
    # Zeitwerk resolves the path through the app's own inflector, which the
    # static tier has not loaded, so the source is the only place the real
    # constant is written down.
    #
    # An inflection only ever changes the case of a segment, so the declared
    # class that names a file is the one equal to the path name ignoring case.
    # Anything else - a second class in the file, a nested error class, a
    # partial tree Prism recovered from a syntax error - is not this file's
    # class, and there the path stays the answer: it is the only thing carrying
    # the namespace when the source does not, which is what
    # `application_cable/channel.rb` needs.
    module DeclaredConstant
      module_function

      # @param source [String] the file's source
      # @param path_name [String] the name the file's path camelizes to
      # @return [String] the constant to call this file's class
      def resolve(source, path_name)
        declared_names(source).find { |name| name.casecmp?(path_name) } || path_name
      end

      # Fully qualified name of every class the source declares, module
      # nesting included. Empty when nothing parses.
      def declared_names(source)
        return [] unless source

        root = AstCache.parse_string(source)&.value
        return [] unless root

        [].tap { |found| collect(root, [], found) }
      rescue StandardError, ScriptError => e
        $stderr.puts "[rails-ai-context] DeclaredConstant failed: #{e.message}" if ENV["DEBUG"]
        []
      end

      def collect(node, scope, found)
        case node
        when Prism::ClassNode
          found << qualify(scope, node)
          descend(node, scope + [ segment(node) ], found)
        when Prism::ModuleNode
          descend(node, scope + [ segment(node) ], found)
        else
          descend(node, scope, found)
        end
      end

      def descend(node, scope, found)
        node.child_nodes.compact.each { |child| collect(child, scope, found) }
      end

      def qualify(scope, node)
        (scope + [ segment(node) ]).join("::")
      end

      # `class ::Foo::Bar` is the same constant as `class Foo::Bar`; the root
      # scope operator is not part of the name.
      def segment(node)
        node.constant_path.slice.delete_prefix("::")
      end

      private_class_method :declared_names, :collect, :descend, :qualify, :segment
    end
  end
end
