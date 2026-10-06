# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    # Discovers ViewComponent and Phlex components: class definitions,
    # slots, props, previews, and sidecar assets.
    class ComponentIntrospector < Base
      extend StaticTier
      static_tier :files_only

      # The framework bases, plus the name an app's own base almost always carries, so it
      # still answers when the chain walk cannot read that base.
      COMPONENT_BASES = {
        view_component: %w[ViewComponent::Base ApplicationComponent],
        phlex: %w[Phlex::HTML Phlex::SVG ApplicationView]
      }.freeze

      def call
        bases, components = split_bases(extract_components)
        {
          components: components,
          summary: build_summary(components),
          bases: bases
        }
      end

      private

      # Every app tree's components: an in-repo engine keeps its own app/components.
      def components_dirs
        PathResolver.dirs_for(root, "app/components")
      end

      # File breaks the tie: `sort_by` is not stable, so a name two files
      # declare would otherwise swap places between runs.
      def extract_components
        dirs = components_dirs
        views = PathResolver.view_dirs(root).map { |dir| File.expand_path(dir) }
        # phlex:install pushes app/views itself under Views: a page view is a Phlex class, not a component.
        namespaced = PathResolver.namespaced_roots(root).map(&:first).reject do |dir|
          views.any? { |view| view == dir || view.start_with?("#{dir}/") }
        end - dirs.map { |dir| File.expand_path(dir) }
        paths = (dirs + namespaced).flat_map { |dir| Dir.glob(File.join(dir, "**/*.rb")) }

        components = paths.filter_map do |path|
          next if path.end_with?("_preview.rb")
          next if File.basename(path) == "application_component.rb"

          component = parse_component(path)
          # A push_dir root (Phlex's app/views/components) holds helpers and kits too.
          next if component && component[:type] == :unknown && namespaced.any? { |dir| path.start_with?("#{dir}/") }

          component
        rescue => e
          { file: path.sub("#{root}/", ""), error: e.message }
        end.sort_by { |c| [ c[:name] || "", c[:file] || "" ] }
        link_rendered_previews(components)
        components
      end

      # A base-named component another component inherits from is a base,
      # not one a view renders: the rule services and jobs follow.
      def split_bases(components)
        names = components.filter_map { |c| full_names[c[:file]] }.to_set
        inherited = components.filter_map do |c|
          declared = declared_classes[c[:file]]
          declared&.superclass &&
            SuperclassChain.resolve_in_scope(declared.name, declared.superclass, nesting: declared.nesting) { |name| name if names.include?(name) }
        end.to_set
        # Inherited, always: ApplicationRowComponent is a row, not a base.
        components.partition do |c|
          own = full_names[c[:file]]
          own && inherited.include?(own) && SuperclassChain.abstract_base_name?(own)
        end
      end

      def declared_classes
        @declared_classes ||= {}
      end

      # A preview named for another namespace than its component is linked by what it
      # renders, when that is exactly one component.
      def link_rendered_previews(components)
        by_name = components.each_with_object({}) { |c, index| index[full_names[c[:file]]] = c if full_names[c[:file]] }
        linked = components.filter_map { |c| c[:preview] }.to_set
        previews_index.each_value do |preview|
          next if linked.include?(preview)

          source = RailsAiContext::SafeFile.read(File.join(root, preview)) or next
          owner = DeclaredConstant.declarations(source).first&.name.to_s
          targets = rendered_constants(AstCache.parse_string(source).value).filter_map do |constant|
            SuperclassChain.resolve_in_scope(owner, constant) { |candidate| by_name[candidate] }
          end.uniq
          targets.first[:preview] = preview if targets.one? && targets.first[:preview].nil?
        end
      end

      # `render(Users::AvatarComponent.new(...))`: the constants a file renders.
      def rendered_constants(root)
        AstWalk.each(root).filter_map do |node|
          next unless node.is_a?(Prism::CallNode) && node.name == :render && node.receiver.nil?

          target = node.arguments&.arguments&.first
          next unless target.is_a?(Prism::CallNode) && target.name == :new &&
                      (target.receiver.is_a?(Prism::ConstantReadNode) || target.receiver.is_a?(Prism::ConstantPathNode))

          target.receiver.slice.delete_prefix("::")
        end
      end

      def full_names
        @full_names ||= {}
      end

      def parse_component(path)
        content = RailsAiContext::SafeFile.read(path)
        return nil unless content
        relative = path.sub("#{root}/", "")
        declaration = component_declaration(content, path)
        return nil unless declaration
        class_name = declaration.name
        full_names[relative] = declaration.name
        declared_classes[relative] = declaration

        structure = extract_structure(content)
        type = detect_component_type(content, declaration)
        props = extract_props(content)
        enum_values = extract_enum_values(structure)
        attach_enum_values_to_props(props, enum_values, structure)

        component = {
          name: class_name,
          file: relative,
          type: type,
          props: props,
          slots: extract_slots(structure, type)
        }

        preview = find_preview(path, preview_name(class_name))
        component[:preview] = preview if preview

        sidecar = find_sidecar_assets(path)
        component[:sidecar_assets] = sidecar if sidecar.any?

        component
      end

      # The class this file is named for, not always the first it opens: a sidecar file
      # reopens the parent namespace class, with no superclass, to nest the component.
      def component_declaration(content, path)
        declarations = DeclaredConstant.declarations(content)
        DeclaredConstant.declaration_for(declarations, File.basename(path, ".rb").camelize) ||
          declarations.first
      end

      # A preview is named without the namespace every component shares: "RubyUI::Button" -> "Button".
      def preview_name(full_name)
        parts = full_name.split("::")
        if parts.size > 2 && parts.first == "Components"
          parts[1..].join("::")
        elsif parts.size > 1 && %w[Components RubyUI].include?(parts.first)
          parts.last
        else
          full_name
        end
      end

      # The base the app's own component bases reach decides, not the one name this file
      # writes: a component can sit two app classes below ApplicationComponent.
      def detect_component_type(content, declaration)
        base = Introspectors::SuperclassChain.to(
          content,
          bases: COMPONENT_BASES.values.flatten,
          lookup: superclass_lookup,
          only: declaration.name.split("::").last
        ).last&.superclass
        return :unknown unless base

        COMPONENT_BASES.find { |_type, bases| bases.include?(base) }&.first || :unknown
      end

      def superclass_lookup
        @superclass_lookup ||= Introspectors::SuperclassChain.lookup_for(root)
      end

      def extract_props(content)
        # Use Prism AST to extract initialize parameters
        parse_result = AstCache.parse_string(content)
        init_node = find_initialize_def(parse_result.value)
        return [] unless init_node

        parameters = init_node.parameters
        return [] unless parameters

        props = []

        # Positional required params
        if parameters.respond_to?(:requireds)
          parameters.requireds.each do |p|
            next unless p.is_a?(Prism::RequiredParameterNode)
            props << { name: p.name.to_s, positional: true }
          end
        end

        # Positional optional params
        if parameters.respond_to?(:optionals)
          parameters.optionals.each do |p|
            next unless p.is_a?(Prism::OptionalParameterNode)
            prop = { name: p.name.to_s, positional: true }
            prop[:default] = NodeSource.text(p.value) if p.value
            props << prop
          end
        end

        # Keyword required params
        if parameters.respond_to?(:keywords)
          parameters.keywords.each do |p|
            case p
            when Prism::RequiredKeywordParameterNode
              props << { name: p.name.to_s }
            when Prism::OptionalKeywordParameterNode
              prop = { name: p.name.to_s }
              prop[:default] = NodeSource.text(p.value) if p.value
              props << prop
            end
          end
        end

        # **kwargs splat
        if parameters.respond_to?(:keyword_rest) && parameters.keyword_rest
          kr = parameters.keyword_rest
          if kr.is_a?(Prism::KeywordRestParameterNode)
            name = kr.name&.to_s || "kwargs"
            props << { name: name, splat: true }
          end
        end

        props
      end

      def find_initialize_def(node)
        return node if node.is_a?(Prism::DefNode) && node.name == :initialize
        node.child_nodes.compact.each do |child|
          found = find_initialize_def(child)
          return found if found
        end
        nil
      end

      # Structural facts about the component class, grouped by kind so each
      # consumer reads its own bucket instead of re-filtering the whole list.
      def extract_structure(content)
        results = SourceIntrospector.walk_source(content, {
          structure: Listeners::ComponentStructureListener
        })[:structure]

        results.group_by { |entry| entry[:kind] }
      end

      def extract_slots(structure, type)
        slots = structure.fetch(:slot_macro, []).map do |entry|
          entry.slice(:name, :type, :renderer, :setters).compact
        end

        # Phlex slots are plain methods taking a block.
        if type == :phlex
          structure.fetch(:slot, []).each do |entry|
            slots << { name: entry[:name], type: :phlex_slot }
          end
        end

        slots
      end

      # Enumerable values a prop can take, keyed by downcased constant name
      # (VARIANTS -> "variants") or by the instance variable a `case` branches on.
      def extract_enum_values(structure)
        enums = {}

        structure.fetch(:constant_table, []).each do |entry|
          enums[entry[:name].downcase] = entry[:values]
        end

        # Several case blocks can branch on the same ivar.
        structure.fetch(:variant_branch, []).each do |entry|
          enums[entry[:ivar]] = ((enums[entry[:ivar]] || []) + entry[:values]).uniq
        end

        enums
      end

      # Matches extracted enum values to props by:
      #   1. Direct ivar match: prop "variant" matches case @variant values
      #   2. Constant name match: prop "size" matches SIZES constant, prop "variant" matches VARIANTS constant
      #   3. Constant usage in initialize: @size referenced as SIZES[@size] matches prop "size"
      def attach_enum_values_to_props(props, enum_values, structure)
        props.each do |prop|
          name = prop[:name]
          values = nil

          # Direct match: prop name matches case @ivar
          values = enum_values[name] if enum_values.key?(name)

          # Constant name match: prop "size" -> SIZES, prop "variant" -> VARIANTS/COLORS
          unless values
            # Try pluralized forms and common naming patterns
            candidates = [ name.upcase + "S", name.upcase + "ES", name.upcase ]
            candidates.each do |candidate|
              if enum_values.key?(candidate.downcase)
                values = enum_values[candidate.downcase]
                break
              end
            end
          end

          # Constant usage match: CONST[@ivar] ties the prop to that table
          unless values
            structure.fetch(:constant_index, []).each do |entry|
              next unless entry[:ivar] == name
              table = enum_values[entry[:constant].downcase]
              next unless table
              values = table
              break
            end
          end

          prop[:values] = values if values&.any?
        end
      end

      # A preview lives beside its component, or at the component's own path in a preview
      # directory (previews/common/list_component_preview.rb).
      def find_preview(component_path, class_name)
        sidecar = component_path.sub(/\.rb\z/, "_preview.rb")
        return sidecar.sub("#{root}/", "") if File.exist?(sidecar)

        keys = [ "#{class_name.sub(/Component\z/, "").underscore}_component" ]
        dir = components_dirs.find { |candidate| component_path.start_with?("#{candidate}/") }
        keys << component_path.delete_prefix("#{dir}/").delete_suffix(".rb") if dir
        keys.lazy.filter_map { |key| previews_index[key] }.first
      end

      DEFAULT_PREVIEW_DIRS = %w[test/components/previews spec/components/previews app/components/previews].freeze
      PREVIEW_CONFIG_GLOBS = %w[config/application.rb config/environments/*.rb].freeze

      # Previewed path (without `_preview.rb`) -> the preview file, read once
      # from the default directories and the ones the app configures.
      def previews_index
        @previews_index ||= preview_dirs.each_with_object({}) do |dir, index|
          Dir.glob(File.join(dir, "**/*_preview.rb")).sort.each do |path|
            index[path.delete_prefix("#{dir}/").delete_suffix("_preview.rb")] ||= path.sub("#{root}/", "")
          end
        end
      end

      def preview_dirs
        files = PREVIEW_CONFIG_GLOBS.flat_map { |glob| Dir.glob(File.join(root, glob)).sort } + PathResolver.initializer_paths(root)
        configured = files.flat_map do |file|
          SourceIntrospector.walk(file, { previews: Listeners::PreviewPathsListener })[:previews]
        end
        (DEFAULT_PREVIEW_DIRS + configured).map { |relative| File.join(root, relative) }.uniq.select { |dir| Dir.exist?(dir) }
      end

      def find_sidecar_assets(component_path)
        # Sidecar files: same name with different extensions
        base = component_path.sub(/\.rb\z/, "")
        assets = []

        # Direct sidecar: component_name.html.erb, component_name.css, etc.
        Dir.glob("#{base}.*").each do |path|
          next if path == component_path
          assets << File.basename(path)
        end

        # Sidecar directory: component_name/ with assets
        sidecar_dir = base
        if Dir.exist?(sidecar_dir) && File.directory?(sidecar_dir)
          Dir.glob(File.join(sidecar_dir, "*")).each do |path|
            assets << "#{File.basename(sidecar_dir)}/#{File.basename(path)}" if File.file?(path)
          end
        end

        assets.sort
      end

      def build_summary(components)
        return {} if components.empty?

        types = components.group_by { |c| c[:type] }
        view_component = types[:view_component]&.size || 0
        phlex = types[:phlex]&.size || 0
        {
          total: components.size,
          view_component: view_component,
          phlex: phlex,
          # Whatever the chain walk could not place, so the header's buckets
          # add up to the total rather than leaving a silent remainder.
          unclassified: components.size - view_component - phlex,
          with_slots: components.count { |c| c[:slots]&.any? },
          with_previews: components.count { |c| c[:preview] }
        }
      end
    end
  end
end
