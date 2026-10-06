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
      # `nesting` is Module.nesting where the superclass is read, innermost
      # first: `class Api::UsersController < BaseController` reads it at the
      # top level, and `< ::BaseController` reads it from the root anywhere.
      Declaration = Data.define(:name, :superclass, :nesting)

      DECLARATIONS = ObjectSpace::WeakMap.new
      MODULE_NAMES = ObjectSpace::WeakMap.new

      module_function

      # @param source [String] the file's source
      # @param path_name [String] the name the file's path camelizes to
      # @return [String] the constant to call this file's class
      def resolve(source, path_name)
        declared_names(source).find { |name| name.casecmp?(path_name) } ||
          declared_module_names(source).find { |name| name.casecmp?(path_name) } ||
          path_name
      end

      # The constant a file declares for `path_name`: the same name ignoring case, else the
      # shortest that ends in it (a plugin nests its tree under its own namespace).
      #
      # @return [String] the declared constant, or `path_name` when none fits
      def named(source, path_name)
        names = declared_names(source) + declared_module_names(source)
        suffix = "::#{path_name.to_s.downcase}"
        names.find { |name| name.casecmp?(path_name.to_s) } ||
          names.select { |name| name.downcase.end_with?(suffix) }.min_by(&:length) ||
          path_name
      end

      # Which of the classes a file declares the file is named for: the path
      # in full first, then the declaration whose last segment the path names.
      #
      # @param declarations [Array<Declaration>]
      # @param path_name [String] the name the file's path camelizes to
      # @return [Declaration, nil]
      def declaration_named(declarations, path_name)
        segment = path_name.to_s.split("::").last.to_s
        declarations.find { |d| d.name.casecmp?(path_name.to_s) } ||
          declarations.find { |d| d.name.split("::").last.casecmp?(segment) }
      end

      # As `declaration_named`, but a file declaring one class is named for it however the
      # path spells it. For a named class, ask `declaration_named`.
      #
      # @return [Declaration, nil]
      def declaration_for(declarations, path_name)
        declaration_named(declarations, path_name) || only_own_class(declarations, path_name)
      end

      # The file's one class, when the file can be named for it: not a class reopened with
      # no superclass (an override or a namespace), nor one nested in the path's constant.
      def only_own_class(declarations, path_name)
        return nil unless declarations.one?

        declaration = declarations.first
        return nil if declaration.superclass.nil?
        return nil if declaration.name.downcase.start_with?("#{path_name.to_s.downcase}::")

        declaration
      end

      # Whether a relative path, without extension, is where a constant lives whatever
      # acronyms the app registers: segments compare without underscores, ignoring case.
      #
      # @param relative [String] e.g. "activitypub/process_account_service"
      # @param name [String] e.g. "ActivityPub::ProcessAccountService"
      def path_for?(relative, name)
        want = name.to_s.underscore.split("/")
        have = relative.to_s.split("/")
        want.size == have.size && want.zip(have).all? { |w, h| same_segment?(w, h) }
      end

      def same_segment?(one, other)
        one.delete("_").casecmp?(other.delete("_"))
      end

      # A loaded class that answers a name no constant carries belongs to no
      # file - Rails names the anonymous join class it builds for a
      # has_and_belongs_to_many through a singleton `name=`, so it answers
      # "HABTM_Tags" while it lives at "Account::HABTM_Tags". Keyed by that
      # name it would overwrite the real entry, or collapse two owners of one
      # association name onto one.
      #
      # @param klass [Class] a loaded class
      # @return [Boolean]
      def renamed?(klass)
        klass.name != klass.to_s
      end

      # @return [Boolean] whether the source declares a class at all. A file
      #   that declares only modules is a mixin, whatever directory it sits in.
      def declares_class?(source)
        declared_names(source).any?
      end

      # Fully qualified name of every class the source declares, module
      # nesting included. Empty when nothing parses.
      def declared_names(source)
        declarations(source).map(&:name)
      end

      # The same for modules, for a file that declares no class: a mixin is
      # named by an inflection the same way a class is, and the camelized path
      # is wrong for it in the same way.
      def declared_module_names(source)
        return [] unless source

        root = AstCache.parse_string(source)&.value
        return [] unless root

        (MODULE_NAMES[root] ||= constants(root).filter_map { |name, node| name if node.is_a?(Prism::ModuleNode) }.freeze).dup
      rescue StandardError, ScriptError => e
        RailsAiContext.debug_fail(e, [], label: "DeclaredConstant")
      end

      # The declaration naming this file's superclass. A file may declare more
      # than one class, so the one matching class_name answers first; anything
      # else in the file only answers when it does not.
      def parent_declaration(source, class_name)
        found = declarations(source)
        named = found.find { |d| d.name == class_name }
        named&.superclass ? named : found.find(&:superclass)
      end

      # The body of each class statement or Class.new block that writes `name`,
      # reached through the namespaces alone, never a method body.
      def class_bodies(node, name, scope = [], found = [])
        case node
        when Prism::ProgramNode then class_bodies(node.statements, name, scope, found)
        when Prism::StatementsNode then node.body.each { |child| class_bodies(child, name, scope, found) }
        when Prism::ClassNode, Prism::ModuleNode
          inner = scoped(scope, node)
          found << node.body if node.is_a?(Prism::ClassNode) && node.body && inner.join("::") == name.to_s
          class_bodies(node.body, name, inner, found)
        when Prism::ConstantWriteNode, Prism::ConstantPathWriteNode
          block = node.value.block if class_new?(node.value)
          return found unless block.is_a?(Prism::BlockNode) && block.body

          written = node.is_a?(Prism::ConstantWriteNode) ? node.name.to_s : node.target.slice
          found << block.body if (written.start_with?("::") ? [ written.delete_prefix("::") ] : scope + [ written ]).join("::") == name.to_s
          # The block opens no constant scope, so a class inside it keeps the assignment's.
          class_bodies(block.body, name, scope, found)
        end
        found
      end

      # Every class the source declares, with the superclass it names -
      # nil for a class with no superclass or a computed one. A module
      # declares no class and so appears here not at all. `assignments: true`
      # adds each `X = Class.new(Base)`, which only the model and config
      # listings read: elsewhere the first declaration is the file's class.
      def declarations(source, assignments: false)
        return [] unless source

        root = AstCache.parse_string(source)&.value
        return [] unless root

        # Keyed by the cached tree, so the entry lives as long as the parse:
        # one run asks the same file three or four times.
        found = (DECLARATIONS[root] ||= declarations_in(root))
        (assignments ? found[:all] : found[:classes]).dup
      rescue StandardError, ScriptError => e
        RailsAiContext.debug_fail(e, [], label: "DeclaredConstant")
      end

      def declarations_in(root)
        all = []
        classes = []
        constants(root, assignments: true) do |name, node, nesting|
          if node.is_a?(Prism::ClassNode)
            parent = node.superclass
            nesting = nesting.drop(1)
          elsif node.respond_to?(:value) && class_new?(node.value)
            # The block body opens no scope: the superclass reads in the assignment's nesting.
            parent = node.value.arguments&.arguments&.first
          else
            next
          end

          declaration = Declaration.new(name: name, superclass: superclass_name(parent), nesting: parent&.slice&.start_with?("::") ? [] : nesting)
          all << declaration
          classes << declaration if node.is_a?(Prism::ClassNode)
        end
        { all: all.freeze, classes: classes.freeze }.freeze
      end

      # The module a parsed file declares under this fully qualified name, for
      # a mixin that lives inside another module's file rather than its own.
      #
      # @param root [Prism::Node] the file's parse tree
      # @return [Prism::ModuleNode, nil]
      def module_node(root, name)
        module_nodes(root)[name]
      end

      # Every module the tree declares, by qualified name: the first that is
      # not a stub, as a namespace stub above the definition is not it.
      #
      # @return [Hash{String => Prism::ModuleNode}]
      def module_nodes(root)
        constants(root).select { |_, node| node.is_a?(Prism::ModuleNode) }
                       .group_by(&:first).transform_values { |found| definition(found.map { |_, node| node }) }
      end

      # Of the nodes writing one constant, the one defining it: the first that is not a stub.
      def definition(nodes)
        nodes.find { |node| !stub?(node) } || nodes.first
      end

      # A class or module holding nothing but such stubs: `module Acts; module Journalized; end; end`.
      def stub?(node)
        Array(node.body&.compact_child_nodes).all? { |child| (child.is_a?(Prism::ModuleNode) || child.is_a?(Prism::ClassNode)) && stub?(child) }
      end

      # Each class and module the tree declares, in source order: its
      # qualified name, its node, and Module.nesting inside its body,
      # innermost first. A class is part of the name of anything inside it;
      # `class ::Foo` inside `module A` is the top-level Foo, and `class A::B`
      # nests only A::B where `module A; class B` nests both.
      # `assignments: true` also yields each `X = ...` and `A::X = ...` write, nesting unchanged.
      def constants(root, assignments: false)
        return enum_for(:constants, root, assignments: assignments) unless block_given?

        stack = [ [ root, [], [] ] ]
        until stack.empty?
          node, scope, nesting = stack.pop
          if node.is_a?(Prism::ClassNode) || node.is_a?(Prism::ModuleNode)
            scope = scoped(scope, node)
            nesting = [ scope.join("::") ] + nesting
            yield scope.join("::"), node, nesting
          elsif assignments && (node.is_a?(Prism::ConstantWriteNode) || node.is_a?(Prism::ConstantPathWriteNode))
            written = node.is_a?(Prism::ConstantWriteNode) ? node.name.to_s : node.target.slice
            yield (written.start_with?("::") ? [ written.delete_prefix("::") ] : scope + [ written ]).join("::"), node, nesting
          end
          stack.concat(node.compact_child_nodes.reverse.map { |child| [ child, scope, nesting ] })
        end
      end

      def scoped(scope, node)
        node.constant_path.slice.start_with?("::") ? [ segment(node) ] : scope + [ segment(node) ]
      end

      # `class ::Foo::Bar` is the same constant as `class Foo::Bar`; the root
      # scope operator is not part of the name.
      def segment(node)
        node.constant_path.slice.delete_prefix("::")
      end

      # `Class.new(Base)` or `Class.new(Base) do ... end`: a class the assignment names.
      def class_new?(node)
        node.is_a?(Prism::CallNode) && node.name == :new &&
          node.receiver.respond_to?(:slice) && node.receiver.slice.delete_prefix("::") == "Class"
      end

      # nil for an anonymous or computed superclass (`< Struct.new(:a)`).
      def superclass_name(node)
        return nil unless node.is_a?(Prism::ConstantReadNode) || node.is_a?(Prism::ConstantPathNode)

        node.slice.delete_prefix("::")
      end

      private_class_method :only_own_class, :scoped, :segment, :superclass_name, :class_new?, :declarations_in
    end
  end
end
