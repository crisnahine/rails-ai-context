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
        declarations(source)
          .map { |d| d[:name] }
          .find { |name| name.casecmp?(path_name) } || path_name
      end

      # Whether the file declares, at its own level, a class that inherits
      # something. A mailer and a channel always do; app/mailers is also where
      # ActionMailer interceptors live, written as a module or as a bare class,
      # and reporting one of those offers `delivering_email` - a hook the
      # framework calls - as an email somebody can send.
      #
      # "At its own level" excludes a class nested deeper than the file's own
      # constant, which belongs to whatever declares it rather than to the file.
      def own_subclass?(source, path_name)
        depth = path_name.split("::").size

        declarations(source).any? do |d|
          d[:superclass] && d[:name].split("::").size <= depth
        end
      end

      # Every class the source declares: fully qualified name, module nesting
      # included, and the superclass as written. Empty when nothing parses.
      def declarations(source)
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
          found << { name: qualify(scope, node), superclass: node.superclass&.slice }
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

      private_class_method :collect, :descend, :qualify, :segment
    end
  end
end
