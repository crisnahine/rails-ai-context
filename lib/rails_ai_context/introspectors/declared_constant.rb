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
      # @param path_name [String] the name derived from the file's path
      # @return [String] the constant to call this file's class
      def resolve(source, path_name)
        name_for(declared_classes(source), path_name)
      end

      # Whether the file declares a class of its own, as opposed to a module
      # that happens to hold one. app/mailers is where ActionMailer
      # interceptors live, and reporting one as a mailer offers
      # `delivering_email` - a hook the framework calls - as an email to send.
      def declares_own_class?(source, path_name)
        own_class?(declared_classes(source), path_name)
      end

      # Fully qualified names of every class the source declares, module
      # nesting included, in source order. Empty when nothing parses.
      def declared_classes(source)
        return [] unless source

        root = AstCache.parse_string(source)&.value
        return [] unless root

        [].tap { |names| collect(root, [], names) }
      rescue StandardError, ScriptError => e
        $stderr.puts "[rails-ai-context] DeclaredConstant failed: #{e.message}" if ENV["DEBUG"]
        []
      end

      # --- decisions over an already-collected list ---

      def name_for(declared, path_name)
        declared.find { |name| name.casecmp?(path_name) } || path_name
      end

      # A class nested deeper than the file's own constant belongs to whatever
      # declares it, not to the file.
      def own_class?(declared, path_name)
        depth = path_name.split("::").size
        declared.any? { |name| name.split("::").size <= depth }
      end

      # --- walking ---

      def collect(node, scope, names)
        case node
        when Prism::ClassNode
          names << qualify(scope, node)
          descend(node, scope + [ segment(node) ], names)
        when Prism::ModuleNode
          descend(node, scope + [ segment(node) ], names)
        else
          descend(node, scope, names)
        end
      end

      def descend(node, scope, names)
        node.child_nodes.compact.each { |child| collect(child, scope, names) }
      end

      def qualify(scope, node)
        (scope + [ segment(node) ]).join("::")
      end

      # `class ::Foo::Bar` is the same constant as `class Foo::Bar`; the root
      # scope operator is not part of the name.
      def segment(node)
        node.constant_path.slice.delete_prefix("::")
      end
    end
  end
end
