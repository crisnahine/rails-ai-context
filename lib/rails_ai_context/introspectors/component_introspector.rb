# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    # Discovers ViewComponent and Phlex components: class definitions,
    # slots, props, previews, and sidecar assets.
    class ComponentIntrospector
      extend StaticTier
      static_tier :files_only

      attr_reader :app

      def initialize(app)
        @app = app
      end

      def call
        components = extract_components
        {
          components: components,
          summary: build_summary(components)
        }
      rescue => e
        { error: e.message }
      end

      private

      def root
        app.root.to_s
      end

      def components_dir
        File.join(root, "app/components")
      end

      def extract_components
        return [] unless Dir.exist?(components_dir)

        Dir.glob(File.join(components_dir, "**/*.rb")).filter_map do |path|
          next if path.end_with?("_preview.rb")
          next if File.basename(path) == "application_component.rb"

          parse_component(path)
        rescue => e
          { file: path.sub("#{root}/", ""), error: e.message }
        end.sort_by { |c| c[:name] || "" }
      end

      def parse_component(path)
        content = RailsAiContext::SafeFile.read(path)
        return nil unless content
        relative = path.sub("#{root}/", "")
        class_name = extract_class_name(content)
        return nil unless class_name

        structure = extract_structure(content)
        type = detect_component_type(content)
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

        preview = find_preview(path, class_name)
        component[:preview] = preview if preview

        sidecar = find_sidecar_assets(path)
        component[:sidecar_assets] = sidecar if sidecar.any?

        component
      end

      def extract_class_name(content)
        # Use Prism AST to extract class name and simplify for display
        parse_result = AstCache.parse_string(content)
        class_node = find_first_class_node(parse_result.value)
        return nil unless class_node

        full_name = constant_path_to_string(class_node.constant_path)
        return nil unless full_name

        # Return the last meaningful segment for display, but keep namespace context
        # e.g., "Components::Articles::Article" -> "Articles::Article"
        #        "RubyUI::Button" -> "Button"
        #        "AlertComponent" -> "AlertComponent"
        parts = full_name.split("::")
        if parts.size > 2 && parts.first == "Components"
          parts[1..].join("::")
        elsif parts.size > 1 && %w[Components RubyUI].include?(parts.first)
          parts.last
        else
          full_name
        end
      end

      def find_first_class_node(node)
        return node if node.is_a?(Prism::ClassNode)
        node.child_nodes.compact.each do |child|
          found = find_first_class_node(child)
          return found if found
        end
        nil
      end

      def constant_path_to_string(node)
        case node
        when Prism::ConstantReadNode
          node.name.to_s
        when Prism::ConstantPathNode
          parts = []
          current = node
          while current.is_a?(Prism::ConstantPathNode)
            parts.unshift(current.name.to_s)
            current = current.parent
          end
          parts.unshift(current.name.to_s) if current.is_a?(Prism::ConstantReadNode)
          parts.join("::")
        else
          nil
        end
      end

      def detect_component_type(content)
        parse_result = AstCache.parse_string(content)
        class_node = find_first_class_node(parse_result.value)
        return :unknown unless class_node&.superclass

        superclass_name = constant_path_to_string(class_node.superclass)
        return :unknown unless superclass_name

        vc_bases = %w[ViewComponent::Base ApplicationComponent]
        phlex_bases = %w[Phlex::HTML Phlex::SVG ApplicationView]

        if vc_bases.include?(superclass_name)
          :view_component
        elsif phlex_bases.include?(superclass_name) || @phlex_bases&.include?(superclass_name)
          :phlex
        elsif inherits_from_phlex_base?(superclass_name)
          :phlex
        else
          :unknown
        end
      end

      def inherits_from_phlex_base?(superclass_name)
        @phlex_bases ||= detect_phlex_bases
        @phlex_bases.include?(superclass_name)
      end

      def detect_phlex_bases
        bases = Set.new
        return bases unless Dir.exist?(components_dir)

        Dir.glob(File.join(components_dir, "**/*.rb")).each do |path|
          begin
            parse_result = AstCache.parse(path)
            class_node = find_first_class_node(parse_result.value)
            next unless class_node&.superclass

            parent = constant_path_to_string(class_node.superclass)
            if %w[Phlex::HTML Phlex::SVG].include?(parent)
              bases << constant_path_to_string(class_node.constant_path)
            end
          rescue => _e
            next
          end
        end

        bases
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
            prop[:default] = p.value.slice if p.value
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
              prop[:default] = p.value.slice if p.value
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
          entry.slice(:name, :type, :renderer).compact
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

      def find_preview(component_path, class_name)
        # Check common preview locations
        preview_name = class_name.sub(/Component\z/, "").underscore
        locations = [
          File.join(root, "spec/components/previews/#{preview_name}_component_preview.rb"),
          File.join(root, "test/components/previews/#{preview_name}_component_preview.rb"),
          File.join(root, "app/components/previews/#{preview_name}_component_preview.rb"),
          component_path.sub(/\.rb\z/, "_preview.rb")
        ]

        preview_path = locations.find { |p| File.exist?(p) }
        preview_path&.sub("#{root}/", "")
      end

      def find_sidecar_assets(component_path)
        # Sidecar files: same name with different extensions
        base = component_path.sub(/\.rb\z/, "")
        dir = File.dirname(component_path)
        stem = File.basename(base)

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

      def build_summary(components = nil)
        components ||= extract_components
        return {} if components.empty?

        types = components.group_by { |c| c[:type] }
        {
          total: components.size,
          view_component: types[:view_component]&.size || 0,
          phlex: types[:phlex]&.size || 0,
          with_slots: components.count { |c| c[:slots]&.any? },
          with_previews: components.count { |c| c[:preview] }
        }
      end
    end
  end
end
