# frozen_string_literal: true

require "prism"

module RailsAiContext
  module Introspectors
    # The constant a source file declares, for the static tier's naming.
    #
    # Camelizing the path is right often enough to look right always, and
    # wrong wherever the app registers an inflection: `app/controllers/
    # xml_feed/` is `XMLFeed` in an app with that acronym and `Xml` is nothing at all.
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
      # `body_nesting` is Module.nesting inside the class body.
      Declaration = Data.define(:name, :superclass, :nesting, :body_nesting)

      DECLARATIONS = ObjectSpace::WeakMap.new
      MODULE_NODES = ObjectSpace::WeakMap.new
      CLASS_NODES = ObjectSpace::WeakMap.new
      SCOPE_NODES = ObjectSpace::WeakMap.new
      WRITES = [ Prism::ConstantWriteNode, Prism::ConstantPathWriteNode, Prism::ConstantOrWriteNode, Prism::ConstantPathOrWriteNode ].freeze

      module_function

      # @param source [String] the file's source
      # @param path_name [String] the name the file's path camelizes to
      # @return [String] the constant to call this file's class
      def resolve(source, path_name)
        declared_names(source, path_name: path_name).find { |name| name.casecmp?(path_name) } ||
          declared_module_names(source).find { |name| name.casecmp?(path_name) } ||
          path_name
      end

      # The constant a file declares for `path_name`: the same name ignoring case, else the
      # shortest that ends in it (a plugin nests its tree under its own namespace).
      #
      # @return [String] the declared constant, or `path_name` when none fits
      def named(source, path_name)
        names = declared_names(source, path_name: path_name) + declared_module_names(source)
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
        declarations.find { |d| d.name.casecmp?(path_name.to_s) } ||
          declarations.find { |d| names_segment?(d.name, path_name) }
      end

      # Whether the path spells this constant: in full, or its last segment, ignoring case.
      def path_names?(name, path_name)
        name.casecmp?(path_name.to_s) || names_segment?(name, path_name)
      end

      def names_segment?(name, path_name)
        name.split("::").last.casecmp?(path_name.to_s.split("::").last.to_s)
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
      # @param relative [String] e.g. "html/sanitize_service"
      # @param name [String] e.g. "HTML::SanitizeService"
      def path_for?(relative, name)
        want = name.to_s.underscore.split("/")
        have = relative.to_s.split("/")
        want.size == have.size && want.zip(have).all? { |w, h| same_segment?(w, h) }
      end

      def same_segment?(one, other)
        one.delete("_").casecmp?(other.delete("_"))
      end

      # A loaded class that answers a name no constant carries belongs to no file: the join class Rails names
      # "HABTM_Tags" through a singleton `name=`, or a class whose constant was removed and is not yet collected.
      #
      # @param klass [Class] a loaded class
      # @return [Boolean]
      def renamed?(klass)
        scope = Object
        klass.name.to_s.split("::").each do |part|
          return true unless scope.const_defined?(part, false)
          # Asking loads no file: a constant still waiting to autoload is taken to name the class.
          return false if scope.autoload?(part, false)

          scope = scope.const_get(part, false)
        end
        !scope.equal?(klass)
      rescue NameError
        # A name that is no constant path, or a path through a value that is no module.
        true
      end

      # The loaded classes among these that their own constants still name.
      def carried(classes)
        classes.reject { |klass| renamed?(klass) }
      end

      # @return [Boolean] whether the source declares a class at all. A file
      #   that declares only modules is a mixin, whatever directory it sits in.
      def declares_class?(source, path_name:)
        declared_names(source, path_name: path_name).any?
      end

      # Fully qualified name of every class the source declares, module
      # nesting included. Empty when nothing parses.
      def declared_names(source, path_name: nil)
        declarations(source, path_name: path_name).map(&:name)
      end

      # The same for modules, for a file that declares no class: a mixin is
      # named by an inflection the same way a class is, and the camelized path
      # is wrong for it in the same way.
      def declared_module_names(source)
        return [] unless source

        root = AstCache.parse_string(source)&.value
        return [] unless root

        module_nodes(root).keys
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

      # The source as one class of it reads: every class beside it blanked to spaces, lines and
      # offsets kept. A class it nests stays; a class that nests it keeps only its opening and
      # its `end`, as the outer body does not run in the inner class. Unchanged when the file declares one.
      def own_source(source, name)
        tree = AstCache.parse_string(source)&.value or return source
        classes = (CLASS_NODES[tree] ||= constants(tree).select { |_, node| node.is_a?(Prism::ClassNode) }.freeze)
        blank_beside(source, classes, name.to_s, nested: true)
      end

      # As `own_source`, for a module: every other class and module blanked, the ones it nests too,
      # as a nested module's body runs for that module alone. Unchanged when the file declares none of that name.
      def own_module_source(source, name)
        tree = source && AstCache.parse_string(source)&.value or return source
        scopes = (SCOPE_NODES[tree] ||= constants(tree, assignments: true).select { |_, node| scope?(node) }.freeze)
        blank_beside(source, scopes, name.to_s, nested: false)
      end

      def blank_beside(source, nodes, name, nested:)
        own = nodes.filter_map { |found, node| node.location if found == name }
        beside = nodes.flat_map do |found, node|
          location = node.location
          next [] if found == name || (nested && own.any? { |at| contains?(at, location) })
          next [ location.start_offset...location.end_offset ] unless own.any? { |at| contains?(location, at) }

          statements = body(node).is_a?(Prism::StatementsNode) ? body(node).body : []
          statements.reject { |child| own.any? { |at| contains?(child.location, at) } }
                    .map { |child| child.location.start_offset...child.location.end_offset }
        end
        return source if own.empty? || beside.empty?

        bytes = source.b
        beside.each { |range| bytes[range] = bytes[range].gsub(/[^\n]/n, " ") }
        bytes.force_encoding(source.encoding)
      end

      # A class or module open, or a write whose `Module.new` or `Class.new` block is a body.
      def scope?(node)
        return true if node.is_a?(Prism::ClassNode) || node.is_a?(Prism::ModuleNode)

        node.respond_to?(:value) && (module_new?(node.value) || (class_new?(node.value) && node.value.block.is_a?(Prism::BlockNode)))
      end

      def contains?(outer, inner)
        outer.start_offset <= inner.start_offset && inner.end_offset <= outer.end_offset
      end

      # The body of each class statement or Class.new block that writes `name`,
      # reached through the namespaces alone, never a method body.
      def class_bodies(node, name, names = nil, found = [])
        names ||= (DECLARATIONS[node] ||= declarations_in(node))[:names]
        case node
        when Prism::ProgramNode then class_bodies(node.statements, name, names, found)
        when Prism::StatementsNode then node.body.each { |child| class_bodies(child, name, names, found) }
        when Prism::ClassNode, Prism::ModuleNode
          found << node.body if node.is_a?(Prism::ClassNode) && node.body && names[node] == name.to_s
          class_bodies(node.body, name, names, found)
        when *WRITES
          block = node.value.block if class_new?(node.value)
          # An `||=` that assigns nothing never runs its block.
          return found unless block.is_a?(Prism::BlockNode) && block.body && names[node]

          found << block.body if names[node] == name.to_s
          class_bodies(block.body, name, names, found)
        end
        found
      end

      # Every class the source declares, with the superclass it names -
      # nil for a class with no superclass or a computed one. A module
      # declares no class and so appears here not at all. An `X = Class.new(Base)`
      # counts only when `path_name` (the constant the file's path spells) names X,
      # as Zeitwerk would: an error constant beside a class or in a mixin is never the file's class.
      # `all: true` answers every one, eager loading's view of the file.
      def declarations(source, path_name: nil, all: false)
        return [] unless source

        root = AstCache.parse_string(source)&.value
        return [] unless root

        # Keyed by the cached tree, so the entry lives as long as the parse:
        # one run asks the same file three or four times.
        found = (DECLARATIONS[root] ||= declarations_in(root))
        return found[:all].dup if all
        return found[:classes].dup unless path_name

        found[:all].select { |d| found[:classes].include?(d) || path_names?(d.name, path_name) }
      rescue StandardError, ScriptError => e
        RailsAiContext.debug_fail(e, [], label: "DeclaredConstant")
      end

      def declarations_in(root)
        all = []
        classes = []
        names = {}.compare_by_identity
        constants(root, assignments: true) do |name, node, nesting|
          body_nesting = nesting
          if node.is_a?(Prism::ClassNode)
            parent = node.superclass
            nesting = nesting.drop(1)
          elsif node.respond_to?(:value) && class_new?(node.value)
            # The block body opens no scope: the superclass reads in the assignment's nesting.
            parent = node.value.arguments&.arguments&.first
          else
            next
          end

          declaration = Declaration.new(name: name, superclass: superclass_name(parent), nesting: parent&.slice&.start_with?("::") ? [] : nesting,
                                        body_nesting: body_nesting)
          all << declaration
          classes << declaration if node.is_a?(Prism::ClassNode)
          names[node] = name
        end
        { all: all.freeze, classes: classes.freeze, names: names.freeze }.freeze
      end

      # The module a parsed file declares under this fully qualified name, for
      # a mixin that lives inside another module's file rather than its own.
      #
      # @param root [Prism::Node] the file's parse tree
      # @return [Prism::ModuleNode, Prism::ConstantWriteNode, Prism::ConstantPathWriteNode, nil] the write for a `Module.new` module
      def module_node(root, name)
        module_nodes(root)[name]
      end

      # Every module the tree declares, by qualified name: the first that is
      # not a stub, as a namespace stub above the definition is not it. An
      # `X = Module.new do ... end` is one too, its write standing for the node.
      #
      # @return [Hash{String => Prism::ModuleNode, Prism::ConstantWriteNode, Prism::ConstantPathWriteNode}]
      def module_nodes(root)
        return {} unless root

        MODULE_NODES[root] ||= constants(root, assignments: true).select { |_, node| node.is_a?(Prism::ModuleNode) || (node.respond_to?(:value) && module_new?(node.value)) }
                                                                 .group_by(&:first).transform_values { |found| definition(found.map { |_, node| node }) }.freeze
      end

      # Of the nodes writing one constant, the one defining it: the first that is not a stub.
      def definition(nodes)
        nodes.find { |node| !stub?(node) } || nodes.first
      end

      # A class or module holding nothing but such stubs: `module Shop; module Tagging; end; end`.
      def stub?(node)
        namespace?(node) && Array(body(node)&.compact_child_nodes).all? { |child| stub?(child) }
      end

      # A class or module holding nothing but class and module opens and constant writes.
      def namespace?(node)
        Array(body(node)&.compact_child_nodes).all? { |child| written(child) }
      end

      # The statements a class or module node holds, or the block of a builder write; nil for a write with no block.
      def body(node)
        return node.body if node.respond_to?(:body)

        block = node.value.block if node.value.respond_to?(:block)
        block.body if block.is_a?(Prism::BlockNode)
      end

      # Each class and module the tree declares, in source order: its
      # qualified name (`full_name`), its node, and Module.nesting inside its
      # body, innermost first. `assignments: true` also yields each `X = ...`,
      # `A::X = ...` and assigning `||=` write, with the nesting it is written in.
      def constants(root, assignments: false)
        return enum_for(:constants, root, assignments: assignments) unless block_given?

        declared = {}
        stack = [ [ root, [] ] ]
        until stack.empty?
          node, nesting = stack.pop
          if (name = declare_node(node, nesting, declared)&.delete_prefix("::"))
            if node.is_a?(Prism::ClassNode) || node.is_a?(Prism::ModuleNode)
              nesting = [ name ] + nesting
              yield name, node, nesting
            elsif assignments && node.respond_to?(:value)
              yield name, node, nesting
            end
          end
          stack.concat(node.compact_child_nodes.reverse.map { |child| [ child, nesting ] })
        end
      end

      # The name a class or module open or a constant write gives, as written (an `||=` and a multiple
      # assignment's targets too); nil for any other node.
      def written(node)
        case node
        when Prism::ClassNode, Prism::ModuleNode then node.constant_path.slice
        when Prism::ConstantWriteNode, Prism::ConstantOrWriteNode, Prism::ConstantTargetNode then node.name.to_s
        when Prism::ConstantPathWriteNode, Prism::ConstantPathOrWriteNode then path_written(node.target)
        when Prism::ConstantPathTargetNode then path_written(node)
        end
      end

      # `self::X` in a class or module body writes X in the scope it is written in.
      def path_written(path)
        path.parent.is_a?(Prism::SelfNode) ? path.name.to_s : path.slice
      end

      # The name a class or module open or a constant write defines where Module.nesting is `nesting`, added to
      # `declared`; nil for any other node and for an `||=` that defines nothing. Every walk declares here, so a
      # later `A::B` reads A against every constant written above it. A name read from the root keeps its `::`.
      def declare_node(node, nesting, declared)
        written = written(node) or return nil
        return nil unless assigned?(node, nesting, declared)

        declare(written, nesting, declared, superclass: (node.superclass if node.is_a?(Prism::ClassNode)))
      end

      # Whether the node defines its constant: an `||=` only when the name resolves to none declared yet.
      def assigned?(node, nesting, declared)
        return true unless node.is_a?(Prism::ConstantOrWriteNode) || node.is_a?(Prism::ConstantPathOrWriteNode)

        lookup(written(node), nesting, declared).nil?
      end

      # `declared` maps each name to the superclass its class names, when this file declares that superclass too.
      def declare(written, nesting, declared, superclass: nil)
        full = full_name(written, nesting, declared)
        name = written.start_with?("::") ? "::#{full}" : full
        inherited = superclass && superclass_name(superclass) && lookup(superclass.slice, nesting, declared)
        declared[name] = inherited || declared[name]
        name
      end

      # The declared constant a reference reaches where Module.nesting is `nesting`, as Ruby looks it up, or nil: a bare
      # name through the nesting, the innermost scope's superclasses and the top level; a path through its head.
      def lookup(reference, nesting, declared)
        name = reference.to_s
        path = resolved_path(name, nesting, declared)
        forms = path ? inherited_forms(path, declared) : lookup_names(name, nesting, declared)
        forms.lazy.filter_map { |form| key(form, declared) }.first&.delete_prefix("::")
      end

      # The form of `name`, with or without a leading `::`, that `declared` holds; nil when it holds none.
      def key(name, declared)
        [ name, "::#{name}", name.delete_prefix("::") ].find { |form| declared.key?(form) }
      end

      # The constant `written` names where Module.nesting is `nesting`: A in `A::B` is the nearest declared, else the innermost scope's.
      def full_name(written, nesting, declared)
        resolved_path(written, nesting, declared) ||
          if written.start_with?("::") then written.delete_prefix("::")
          else nesting.empty? ? written : "#{nesting.first}::#{written}"
          end
      end

      # A path whose head is declared or read from the root, each later segment but the last read through the
      # superclasses of the scope before it; nil for a bare name or an undeclared head.
      def resolved_path(written, nesting, declared)
        rooted = written.start_with?("::")
        first, *middle, last = written.delete_prefix("::").split("::")
        return nil if last.nil?

        head = rooted ? first : lookup_names(first, nesting, declared).lazy.filter_map { |name| key(name, declared) }.first or return nil
        scope = middle.reduce(head) do |outer, segment|
          inherited_forms("#{outer}::#{segment}", declared).find { |form| key(form, declared) } || "#{outer}::#{segment}"
        end
        "#{scope}::#{last}"
      end

      # As candidate_names, with the innermost scope's superclasses before the top level, as Ruby looks a constant up.
      # shortcut: only a superclass this file declares is searched, never one in another file nor an included module;
      # widen it when an app's `||=` or compact path depends on one.
      def lookup_names(reference, nesting, declared)
        names = candidate_names(reference, nesting)
        return names if reference.to_s.start_with?("::") || nesting.empty?

        names[0...-1] + superclasses(nesting.first, declared).map { |scope| "#{scope}::#{reference}" } + names.last(1)
      end

      # A path and the same name under each superclass of its owner: `A::M` is found in A's ancestors too.
      def inherited_forms(full, declared)
        owner, _, short = full.rpartition("::")
        [ full ] + superclasses(owner, declared).map { |scope| "#{scope}::#{short}" }
      end

      def superclasses(name, declared)
        chain = []
        while (name = [ name, "::#{name}", name.delete_prefix("::") ].lazy.filter_map { |form| declared[form] }.first) && !chain.include?(name)
          chain << name
        end
        chain
      end

      # The names Ruby tries for a reference, nearest first: each scope of `within` (a nesting, or a name read per segment), then the top level.
      def candidate_names(reference, within)
        name = reference.to_s
        return [ name.delete_prefix("::") ] if name.start_with?("::")

        (within.is_a?(Array) ? within : nesting(within.to_s.split("::"))).map { |scope| "#{scope}::#{name}" } + [ name ]
      end

      # Module.nesting inside a module per segment of `owners`, innermost first: ["A::B", "C"] nests A::B::C then A::B, never A.
      def nesting(owners)
        owners.size.downto(1).map { |n| owners.first(n).join("::") }
      end

      # Module.nesting where a listener record was written, in a slice whose root has Module.nesting `outer` and is
      # written `root` (nil for a `Module.new`, which opens no scope).
      def record_nesting(record, outer = [], root = nil)
        Array(record[:nesting]).map do |scope|
          if outer.empty? || scope.start_with?("::") then scope.delete_prefix("::")
          elsif root.nil? then "#{outer.first}::#{scope}"
          elsif scope == root || scope.start_with?("#{root}::") then "#{outer.first}#{scope.delete_prefix(root)}"
          else scope
          end
        end + (root ? outer.drop(1) : outer)
      end

      # Module.nesting inside the body `tree` declares as `name`, or at `node`; per segment when it declares none.
      # A `Module.new` block opens no scope, so the nesting at its write is the one it is written in.
      # shortcut: by name alone a reopened class reads its first body's nesting; pass `node:` where the caller holds it.
      def body_nesting(tree, name, node: nil)
        found = tree && constants(tree, assignments: !node.nil?).find { |declared, at, _| node ? at.equal?(node) : declared == name }
        found ? found.last : nesting(name.to_s.split("::"))
      end

      # `Class.new(Base)` or `Class.new(Base) do ... end`: a class the assignment names.
      def class_new?(node)
        new_of?(node, "Class")
      end

      # `Module.new do ... end`: a module the assignment names, its block the body.
      def module_new?(node)
        new_of?(node, "Module") && node.block.is_a?(Prism::BlockNode)
      end

      def new_of?(node, builder)
        node.is_a?(Prism::CallNode) && node.name == :new &&
          node.receiver.respond_to?(:slice) && node.receiver.slice.delete_prefix("::") == builder
      end

      # nil for an anonymous or computed superclass (`< Struct.new(:a)`).
      def superclass_name(node)
        return nil unless node.is_a?(Prism::ConstantReadNode) || node.is_a?(Prism::ConstantPathNode)

        node.slice.delete_prefix("::")
      end

      private_class_method :contains?, :blank_beside, :path_written, :new_of?, :path_names?, :names_segment?, :only_own_class, :superclass_name, :declarations_in,
                           :key, :resolved_path, :lookup_names, :inherited_forms, :superclasses
    end
  end
end
