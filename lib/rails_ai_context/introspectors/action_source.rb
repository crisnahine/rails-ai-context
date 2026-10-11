# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    # Where an action's `def` is written, in the order Ruby's method lookup
    # takes: a prepended module, the controller's own body, the modules it
    # includes (the last one included first), then the same again for each
    # parent controller. An action from a concern or from a base controller
    # is not in the controller's own file, and reading only that file
    # answered as if its source could not be found.
    module ActionSource
      module_function

      # The walk starts at the file the controller listing recorded and never
      # at one guessed from the name, as every other answer about the
      # controller does; a parent is found the way ActionPresence finds it,
      # through the listing first.
      #
      # @param file [String, nil] the controller's own file, relative to root
      # @param controllers [Hash] the controller listing, name => details
      # @return [Hash, nil] the body from ActionResolver.method_body, plus
      #   :file, the file it was read from, relative to root
      def find(root, controller_name, action, file:, controllers: {})
        return nil unless file

        root = root.to_s
        name = controller_name.to_s
        path = File.expand_path(file, root)
        lookup = ->(candidate) { listed_path(root, candidate, controllers) || PathResolver.file_for_constant(root, candidate) }
        SuperclassChain::MAX_DEPTH.times do
          source = path && PathResolver.project_file?(path, root) && SafeFile.read(path)
          break unless source

          declaration = DeclaredConstant.declarations(source, path_name: name).find { |d| d.name == name }
          break unless declaration

          # Module.nesting inside the class body, which is where its
          # `include` reads a name: the class, then what encloses it.
          found = in_class(root, path, source, name, action, [ name, *declaration.nesting ])
          return found if found

          parent = declaration.superclass
          break if parent.nil? || ActionPresence::BASES.include?(parent)

          name, path = SuperclassChain.resolve_in_scope(name, parent, nesting: declaration.nesting) do |candidate|
            (candidate_path = lookup.call(candidate)) && [ candidate, candidate_path ]
          end
          break unless name
        end
        nil
      rescue => e
        RailsAiContext.debug_fail(e, nil, label: "ActionSource.find")
      end

      def listed_path(root, name, controllers)
        entry = controllers.is_a?(Hash) ? controllers[name] : nil
        recorded = entry.is_a?(Hash) ? entry[:file] : nil
        path = recorded && File.expand_path(recorded, root)
        path if path && File.file?(path)
      end

      def in_class(root, path, source, name, action, scopes)
        mixins = mixins_of(root, source, name)
        prepended, included = mixins.partition { |mixin| mixin[:macro] == :prepend }
        in_modules(root, prepended, scopes, action, 0) ||
          own_def(root, path, source, name, action) ||
          in_modules(root, included, scopes, action, 0)
      end

      # Only a def the owner itself carries: ActionResolver.method_body falls
      # back to the first `def` of that name anywhere in the file, which in a
      # parent's file can be another class's.
      def own_def(root, path, source, owner, action)
        method = ActionResolver.public_methods_in(source, owner: owner, skip_underscored: false)
                               .find { |m| m[:name].to_s.casecmp?(action.to_s) }
        body = method && ActionResolver.body_of(source, method)
        body&.merge(file: PortablePath.relativize(path, root))
      end

      # @param scopes [Array<String>] Module.nesting where the mixins are
      #   written, innermost first
      def in_modules(root, mixins, scopes, action, depth)
        return nil if depth > ActionPresence::MODULE_DEPTH

        mixins.reverse_each do |mixin|
          next unless ConcernMembership.candidate?(mixin[:name])

          mod, path = resolve(root, mixin[:name].to_s, scopes)
          source = path && PathResolver.project_file?(path, root) && SafeFile.read(path)
          next unless source

          found = own_def(root, path, source, mod, action) ||
                  in_modules(root, mixins_of(root, source, mod), namespaces(mod), action, depth + 1)
          return found if found
        end
        nil
      end

      # [the constant a name written in those scopes resolves to, its file],
      # the way Ruby looks it up: each enclosing scope, then the top level.
      # `include Exportable` in `module Admin; class WidgetsController` can be
      # Admin::Exportable, and in a compact `class Admin::WidgetsController`
      # it cannot.
      def resolve(root, name, scopes)
        candidates = name.start_with?("::") ? [ name.delete_prefix("::") ] : [ *scopes.map { |scope| "#{scope}::#{name}" }, name ]
        candidates.each do |candidate|
          found = ConcernPaths.find_named(root, candidate, prefer: "controller") || ConcernPaths.outer_named(root, candidate)
          return found if found && found.first == candidate
        end
        nil
      end

      # A module's own body: the module, then each namespace around its name.
      def namespaces(name)
        parts = name.to_s.split("::")
        parts.size.downto(1).map { |n| parts.first(n).join("::") }
      end

      def mixins_of(root, source, owner)
        walked = SourceIntrospector.walk_source(source, { mixins: Listeners::MixinsListener })
        ConcernMembership.owned_by(walked[:mixins], owner, root: root)
                         .select { |mixin| mixin[:ancestor] && !mixin[:inline] }
                         .uniq { |mixin| mixin[:name] }
      end
    end
  end
end
