# frozen_string_literal: true

module RailsAiContext
  # Modules mixed into every model from outside the model files (`ActiveRecord::Base.include X`,
  # an `on_load(:active_record)` block): a walk of the model's own includes never meets them.
  module BaseMixins
    # `path` is nil when the declaring file is not the app's (a gem's module).
    Mixin = Struct.new(:name, :path, :macro)

    TARGETS = %w[ActiveRecord::Base ApplicationRecord].freeze
    HOOK = :active_record
    MACROS = %i[include prepend extend].freeze
    MARKERS = [ *TARGETS, "on_load(:active_record", "on_load :active_record" ].freeze

    module_function

    # One scan per run: `watch` and the MCP server run again after an edit.
    # @return [Array<Mixin>]
    def models(root)
      root = File.expand_path(root.to_s)
      RunCache.fetch([ :base_mixins, root ]) { discover(root) }
    end

    def discover(root)
      scanned_files(root).flat_map do |file|
        source = SafeFile.read(file)
        next [] unless source && MARKERS.any? { |marker| source.include?(marker) }

        tree = AstCache.parse(file).value
        mixed_in(tree).map { |macro, name| Mixin.new(name, declaring_file(root, name, file), macro) }
      end.uniq(&:name)
    rescue StandardError => e
      RailsAiContext.debug_fail(e, [], label: "BaseMixins.discover")
    end
    private_class_method :discover

    # Everywhere the app configures itself but app/models: a model file's includes are
    # its own, and the model walk reads that file already.
    def scanned_files(root)
      app_dirs = PathResolver.dirs_for(root, "app").flat_map do |tree|
        Dir.glob(File.join(tree, "*")).select { |dir| File.directory?(dir) && File.basename(dir) != "models" }
      end
      trees = [ File.join(root, "config"), File.join(root, "lib"), *PathResolver.declared_roots(root), *app_dirs ]
      code = PathResolver.code_roots(root).flat_map do |code_root|
        [ File.join(code_root, "config"), File.join(code_root, "lib") ].map { |dir| File.join(dir, "**", "*.rb") } +
          [ File.join(code_root, "*.rb") ]
      end
      (trees.map { |dir| File.join(dir, "**", "*.rb") } + code).flat_map { |glob| Dir.glob(glob) }.uniq.sort
    end
    private_class_method :scanned_files

    # [macro, constant] for each module the tree mixes into a model base:
    # sent to it, run in its `on_load` hook, or written in its reopened body.
    def mixed_in(tree)
      Introspectors::AstWalk.each(tree).flat_map do |node|
        next [] unless node.is_a?(Prism::CallNode)
        next hook_mixins(node) if hook?(node)

        target?(node.receiver) ? mixin_calls(node) : []
      end + reopened_mixins(tree)
    end

    # `class ActiveRecord::Base; include X; end`, however the namespace is written.
    def reopened_mixins(tree)
      Introspectors::DeclaredConstant.constants(tree).flat_map do |name, node|
        next [] unless node.is_a?(Prism::ClassNode) && TARGETS.include?(name) && node.body

        node.body.body.flat_map { |call| call.is_a?(Prism::CallNode) && call.receiver.nil? ? mixin_calls(call) : [] }
      end
    end
    private_class_method :reopened_mixins

    # Inside `on_load(:active_record) { ... }` the block runs in the base.
    def hook_mixins(node)
      Introspectors::AstWalk.each(node.block).flat_map do |call|
        call.is_a?(Prism::CallNode) && call.receiver.nil? ? mixin_calls(call) : []
      end
    end
    private_class_method :hook_mixins

    # `include X` and `send(:include, X)`, as [macro, constant] pairs.
    def mixin_calls(node)
      macro = node.name
      if %i[send public_send].include?(macro)
        first = Array(node.arguments&.arguments).first
        macro = first.is_a?(Prism::SymbolNode) && first.unescaped.to_sym
      end
      MACROS.include?(macro) ? constants(node).map { |name| [ macro, name ] } : []
    end
    private_class_method :mixin_calls
    private_class_method :mixed_in

    def target?(receiver)
      receiver && TARGETS.include?(receiver.slice.delete_prefix("::"))
    end
    private_class_method :target?

    def hook?(node)
      node.name == :on_load && node.block &&
        Array(node.arguments&.arguments).first.then { |arg| arg.is_a?(Prism::SymbolNode) && arg.unescaped.to_sym == HOOK }
    end
    private_class_method :hook?

    def constants(node)
      Array(node.arguments&.arguments).filter_map do |arg|
        arg.slice.delete_prefix("::") if arg.is_a?(Prism::ConstantReadNode) || arg.is_a?(Prism::ConstantPathNode)
      end
    end
    private_class_method :constants

    # Past Zeitwerk's path, a plugin's module sits in a lib file its init.rb
    # requires, under a name its path does not spell.
    def declaring_file(root, name, file)
      ConcernPaths.find_file(root, name) ||
        ([ file ] + required_files(root, file, 2)).find do |candidate|
          Introspectors::DeclaredConstant.module_node(AstCache.parse(candidate).value, name)
        end
    rescue StandardError => e
      RailsAiContext.debug_fail(e, nil, label: "BaseMixins.declaring_file #{name}")
    end
    private_class_method :declaring_file

    REQUIRES = %i[require require_relative require_dependency].freeze

    # A bare feature is looked up beside the file, in its lib, the app's lib, and
    # each in-repo path gem's lib.
    def required_files(root, file, depth)
      return [] if depth.zero?

      dir = File.dirname(file)
      lookup = [ dir, File.join(dir, "lib"), File.join(root, "lib"), *PathResolver.path_gem_libs(root) ]
      found = Introspectors::AstWalk.each(AstCache.parse(file).value).filter_map do |node|
        next unless node.is_a?(Prism::CallNode) && node.receiver.nil? && REQUIRES.include?(node.name)

        feature = feature_path(Array(node.arguments&.arguments).first, dir) or next
        bases = feature.start_with?("/") ? [ feature ] : lookup.map { |base| File.join(base, feature) }
        candidate = bases.map { |base| base.end_with?(".rb") ? base : "#{base}.rb" }.find { |path| File.file?(path) }
        File.expand_path(candidate) if candidate
      end
      found.uniq.flat_map { |required| [ required, *required_files(root, required, depth - 1) ] }.uniq
    end
    private_class_method :required_files

    # `"x"`, `File.dirname(__FILE__) + "/x"`, `File.join(__dir__, "x")` and
    # `File.expand_path("x", __dir__)`; any other path is not a literal.
    def feature_path(node, dir)
      return node.unescaped if node.is_a?(Prism::StringNode)
      return nil unless node.is_a?(Prism::CallNode)

      arguments = Array(node.arguments&.arguments)
      strings = ->(nodes) { nodes.all?(Prism::StringNode) ? nodes.map(&:unescaped) : nil }
      if node.name == :+ && node.receiver && dir_of_file?(node.receiver)
        tail = strings.call(arguments.first(1))
        File.join(dir, *tail) if tail
      elsif file_call?(node, :join) && arguments.first && dir_of_file?(arguments.first)
        tail = strings.call(arguments.drop(1))
        File.join(dir, *tail) if tail
      elsif file_call?(node, :expand_path) && arguments.size == 2 && dir_of_file?(arguments.last)
        path = strings.call(arguments.first(1))
        File.expand_path(path.first, dir) if path
      end
    end

    def file_call?(node, name)
      node.name == name && node.receiver.is_a?(Prism::ConstantReadNode) && node.receiver.name == :File
    end
    private_class_method :file_call?
    private_class_method :feature_path

    def dir_of_file?(node)
      %w[File.dirname(__FILE__) __dir__].include?(node.slice.delete(" "))
    end
    private_class_method :dir_of_file?
  end
end
