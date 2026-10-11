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
      # Why an action #unlisted_action finds is missing from the listing.
      UNLISTED_NOTE = "The action list takes a method a concern or a parent controller gives only where a route " \
                      "names it for this controller. Rails counts it among this controller's actions all the same."

      module_function

      # The walk starts at the file the controller listing recorded and never
      # at one guessed from the name, as every other answer about the
      # controller does; a parent is found the way ActionPresence finds it,
      # through the listing first.
      #
      # @param file [String, nil] the controller's own file, relative to root
      # @param controllers [Hash] the controller listing, name => details
      # @return [Hash, nil] the body from ActionResolver.method_body, plus
      #   :file, the file it was read from, relative to root, and :owner, the
      #   class in the controller's chain whose body, or a module it
      #   includes, holds the def
      def find(root, controller_name, action, file:, controllers: {})
        body, _method, owner = walk(root, controller_name, action, file: file, controllers: controllers)
        body&.merge(owner: owner)
      end

      # An action the listing leaves out: a public method a concern or a
      # parent controller gives, which the listing takes only where a route
      # names it for the controller. Rails counts every one among the
      # controller's actions (an ApplicationController concern's page_info is
      # an action of every controller), so a lookup by name reads it here,
      # under the rules the listing applies: no callback, no `_`, `?` or `!`
      # name, no required argument. The nearest def decides, whatever its
      # visibility, as in Ruby's lookup: a private def below a public one
      # hides it from Rails too.
      #
      # @return [Hash, nil] as #find gives it, plus :name, the action as the
      #   def spells it
      def unlisted_action(root, controller_name, action, file:, controllers: {})
        name = action.to_s
        return nil if name.start_with?("_") || name.end_with?("?", "!")

        body, method, owner = walk(root, controller_name, name, file: file, controllers: controllers, visibility: :any)
        return nil unless method && method[:visibility] == :public && !ActionResolver.requires_argument?(method)

        name = method[:name].to_s
        body.merge(name: name, owner: owner) unless callback_names(controllers, controller_name.to_s).include?(name)
      end

      # The walk behind both: the body, the walked method, and the class in
      # the chain it was found under.
      def walk(root, controller_name, action, file:, controllers:, visibility: :public)
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
          found = in_class(root, path, source, name, action, [ name, *declaration.nesting ], visibility)
          return [ *found, name ] if found

          parent = declaration.superclass
          break if parent.nil? || ActionPresence::BASES.include?(parent)

          name, path = SuperclassChain.resolve_in_scope(name, parent, nesting: declaration.nesting) do |candidate|
            (candidate_path = lookup.call(candidate)) && [ candidate, candidate_path ]
          end
          break unless name
        end
        nil
      rescue => e
        RailsAiContext.debug_fail(e, nil, label: "ActionSource.walk")
      end

      # Every callback the listing records on the controller and on each
      # parent it holds: a statically read entry carries only its own.
      def callback_names(controllers, name)
        return [] unless controllers.is_a?(Hash)

        names = []
        seen = []
        while (info = controllers[name]).is_a?(Hash) && !seen.include?(name)
          seen << name
          names.concat(Array(info[:filters]).filter_map { |filter| filter[:name].to_s if filter.is_a?(Hash) })
          name = ActionResolver.resolve_entry_name(controllers, info[:parent_class], name)
        end
        names
      end

      def listed_path(root, name, controllers)
        entry = controllers.is_a?(Hash) ? controllers[name] : nil
        recorded = entry.is_a?(Hash) ? entry[:file] : nil
        path = recorded && File.expand_path(recorded, root)
        path if path && File.file?(path)
      end

      def in_class(root, path, source, name, action, scopes, visibility)
        mixins = mixins_of(root, source, name)
        prepended, included = mixins.partition { |mixin| mixin[:macro] == :prepend }
        in_modules(root, prepended, scopes, action, 0, visibility) ||
          own_def(root, path, source, name, action, visibility) ||
          in_modules(root, included, scopes, action, 0, visibility)
      end

      # Only a def the owner itself carries: ActionResolver.method_body falls
      # back to the first `def` of that name anywhere in the file, which in a
      # parent's file can be another class's. A public def unless
      # `visibility` is :any.
      #
      # @return [Array(Hash, Hash), nil] the body with its :file, and the walked method
      def own_def(root, path, source, owner, action, visibility)
        method = ActionResolver.own_methods_in(source, owner).find do |m|
          m[:scope] == :instance && (visibility == :any || m[:visibility] == :public) && m[:name].to_s.casecmp?(action.to_s)
        end
        body = method && ActionResolver.body_of(source, method)
        body && [ body.merge(file: PortablePath.relativize(path, root)), method ]
      end

      # @param scopes [Array<String>] Module.nesting where the mixins are
      #   written, innermost first
      def in_modules(root, mixins, scopes, action, depth, visibility)
        return nil if depth > ActionPresence::MODULE_DEPTH

        mixins.reverse_each do |mixin|
          next unless ConcernMembership.candidate?(mixin[:name])

          mod, path = resolve(root, mixin[:name].to_s, scopes)
          source = path && PathResolver.project_file?(path, root) && SafeFile.read(path)
          next unless source

          found = own_def(root, path, source, mod, action, visibility) ||
                  in_modules(root, mixins_of(root, source, mod), namespaces(mod), action, depth + 1, visibility)
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
