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
    # The path stays the answer when the source does not carry the whole name -
    # `application_cable/channel.rb` declaring a bare `class Channel` is the
    # case the path exists for. A declared name is taken only when it names the
    # same file: same number of segments, same last segment. Prism parses a
    # file with a syntax error into a partial tree, so without the second
    # condition a half-written `class Broken` renames the whole controller.
    module DeclaredConstant
      module_function

      # @param source [String] the file's source
      # @param path_name [String] the name derived from the file's path
      # @return [String] the constant to call this file's class
      def resolve(source, path_name)
        declared = first_declared(source)
        return path_name unless declared
        return path_name unless declared.count(":") == path_name.count(":")
        return path_name unless declared.split("::").last == path_name.split("::").last

        declared
      end

      # Fully qualified name of the first class the source declares, module
      # nesting included. Nil when nothing parses or nothing is declared.
      def first_declared(source)
        return nil unless source

        root = AstCache.parse_string(source)&.value
        root && search(root, [])
      rescue StandardError, ScriptError => e
        $stderr.puts "[rails-ai-context] DeclaredConstant failed: #{e.message}" if ENV["DEBUG"]
        nil
      end

      def search(node, scope)
        case node
        when Prism::ClassNode
          (scope + [ node.constant_path.slice ]).join("::")
        when Prism::ModuleNode
          descend(node, scope + [ node.constant_path.slice ])
        else
          descend(node, scope)
        end
      end

      def descend(node, scope)
        node.child_nodes.compact.each do |child|
          found = search(child, scope)
          return found if found
        end
        nil
      end
    end
  end
end
