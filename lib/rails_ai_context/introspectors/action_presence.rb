# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    # "Does controller X have action Y", read from the app's source: the
    # controller and its ancestors up to Rails' own base, the modules each one
    # includes, and the view prefixes Rails renders a template-only action
    # from. What the chain names that no app source holds is kept as unread,
    # since a gem class or module there could define the action.
    module ActionPresence
      BASES = %w[ActionController::Base ActionController::API ActionController::Metal].freeze
      # How deep included modules are followed into the modules they include.
      MODULE_DEPTH = 3

      # `defs` are the def nodes of the controller and its ancestors, nearest
      # first; `names` every public method and `define_method` name the chain
      # and its modules give; `unread_parent` the ancestor class the walk
      # stopped at short of Rails' base (a gem's Devise::SessionsController);
      # `sources` the source of each class and included module read.
      Chain = Data.define(:defs, :names, :prefixes, :unread, :unread_parent, :sources) do
        def defines?(action)
          names.include?(action.to_s)
        end
      end

      module_function

      # @param prefix [String] the controller's own view prefix (its route key)
      # @param lookup [#call] constant name -> the source declaring it, or nil
      # @return [Chain]
      def read(root, class_name, source, prefix:, lookup: SuperclassChain.lookup_for(root))
        defs = {}
        names = Set.new
        prefixes = [ prefix ]
        unread = []
        unread_parent = nil
        sources = []
        name = class_name
        SuperclassChain::MAX_DEPTH.times do
          declaration = source && DeclaredConstant.declarations(source, path_name: name).find { |d| d.name == name }
          # A file the walk cannot match to the class leaves the class unread.
          break unread << name unless declaration

          sources << source
          read_class(source, name, defs, names)
          read_modules(source, name, root, names, unread, 0, sources)
          parent = declaration.superclass
          break if parent.nil? || BASES.include?(parent)

          found = SuperclassChain.resolve_in_scope(name, parent, nesting: declaration.nesting) { |c| (src = lookup.call(c)) && [ c, src ] }
          unless found
            unread_parent = parent
            break unread << parent
          end

          name, source = found
          prefixes << name.delete_suffix("Controller").underscore
        end
        Chain.new(defs: defs, names: names, prefixes: prefixes.uniq, unread: unread.uniq, unread_parent: unread_parent,
                  sources: sources.uniq)
      end

      # The controller listing's file for a name it holds, else the file the
      # name resolves to: an inflected controller is not at its underscored path.
      def lookup(root, controllers)
        by_path = SuperclassChain.lookup_for(root)
        lambda do |name|
          file = controllers.is_a?(Hash) && controllers[name].is_a?(Hash) ? controllers[name][:file] : nil
          path = file && File.expand_path(file, root)
          (path && PathResolver.project_file?(path, root) && SafeFile.read(path)) || by_path.call(name)
        end
      end

      def template?(root, chain, action)
        roots = [ root.to_s, *PathResolver.enclosing_engine_roots(root.to_s) ]
        chain.prefixes.any? { |prefix| roots.any? { |dir| Dir.glob(File.join(dir, "app", "views", prefix, "#{action}.*")).any? } }
      end

      def read_class(source, name, defs, names)
        AstWalk.each(AstCache.parse_string(source)&.value).grep(Prism::DefNode).each do |node|
          defs[node.name] ||= node if node.receiver.nil?
        end
        names.merge(public_names(source, name))
        names.merge(built_names(source))
      end

      # Included modules give their public methods; an extended one gives
      # the actions its class macros build with define_method, and an unread
      # one only hides class methods.
      def read_modules(source, owner, root, names, unread, depth, sources)
        mixins = ConcernMembership.owned_by(
          SourceIntrospector.walk_source(source, { mixins: Listeners::MixinsListener })[:mixins], owner, root: root
        )
        mixins.select { |m| m[:ancestor] || (m[:macro] == :extend && !m[:receiver]) }.uniq { |m| m[:name] }.each do |mixin|
          mod = mixin[:name]
          next unless ConcernMembership.candidate?(mod)

          mod_source = module_source(root, mod, owner)
          unless mixin[:ancestor]
            names.merge(built_names(mod_source)) if mod_source
            next
          end
          next unread << mod unless mod_source

          sources << mod_source
          names.merge(public_names(mod_source, nil))
          names.merge(built_names(mod_source))
          read_modules(mod_source, mod, root, names, unread, depth + 1, sources) if depth < MODULE_DEPTH
        end
      end

      def module_source(root, mod, owner)
        source = ConcernPaths.module_source(root.to_s, mod, within: owner)
        return source if source

        path = SuperclassChain.resolve_in_scope(owner, mod) { |c| PathResolver.file_for_constant(root.to_s, c) }
        path && SafeFile.read(path)
      end

      # A route that names a method is dispatched to it, `merged?` included.
      def public_names(source, owner)
        ActionResolver.own_methods_in(source, owner)
          .select { |m| m[:scope] == :instance && m[:visibility] == :public }.map { |m| m[:name].to_s }
      end

      # A `define_method` in a class macro builds an action no def names.
      def built_names(source)
        SourceIntrospector.walk_source(source, { built: -> { Listeners::GenericMacroListener.new(:define_method) } })[:built]
          .map { |hit| hit[:args].first.to_s }.reject(&:empty?)
      end

      private_class_method :read_class, :read_modules, :module_source, :public_names, :built_names
    end
  end
end
