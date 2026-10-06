# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    # The helper methods a view can call: every method the app's helper
    # modules define, in every code root, and those of a module they include.
    module HelperNames
      MAX_INCLUDES = 50

      module_function

      # @return [Set<String>]
      def for(root)
        root = root.to_s
        names = Set.new
        included = []
        PathResolver.dirs_for(root, "app/helpers").each do |dir|
          FileWalk.each_file(dir).select { |path| path.end_with?(".rb") }.each do |path|
            source = RailsAiContext::SafeFile.read(path)
            next if source && !view_helper?(source, path, dir)

            walked = SourceIntrospector.walk(path, { methods: Listeners::MethodsListener, mixins: Listeners::MixinsListener }, source: source)
            names.merge(Array(walked[:methods]).map { |m| m[:name].to_s })
            included.concat(Array(walked[:mixins]).select { |m| m[:macro] == :include && m[:ancestor] }.map { |m| m[:name] })
          end
        end
        roots = PathResolver.autoload_roots(root)
        included.uniq.first(MAX_INCLUDES).each do |constant|
          path = module_file(root, constant, roots) or next
          names.merge(defined_methods(path, constant))
        end
        names
      rescue => e
        RailsAiContext.debug_fail(e, Set.new, label: "HelperNames")
      end

      # `helper :all` mixes in the modules of `**/*_helper.rb` files only; a class there reaches no view.
      def view_helper?(source, path, dir)
        return false unless path.end_with?("_helper.rb")

        path_name = path.delete_prefix("#{dir}/").delete_prefix("concerns/").delete_suffix(".rb").camelize
        !DeclaredConstant.declared_names(source, path_name: path_name).include?(DeclaredConstant.named(source, path_name))
      end

      # The instance methods `owner` defines in a file: what including it gives a view.
      def defined_methods(path, owner)
        methods = SourceIntrospector.walk(path, { methods: Listeners::MethodsListener })[:methods]
        ActionResolver.own_methods(methods, owner).select { |m| m[:scope] == :instance }.map { |m| m[:name].to_s }
      end

      # The first file, its own or an enclosing namespace's, that declares the module.
      def module_file(root, constant, roots)
        PathResolver.namespace_files(root, constant, roots: roots).find do |path|
          DeclaredConstant.declared_module_names(RailsAiContext::SafeFile.read(path).to_s).include?(constant)
        end
      end
    end
  end
end
