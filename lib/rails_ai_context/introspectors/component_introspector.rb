# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    # Discovers ViewComponent and Phlex components: class definitions,
    # slots, props, previews, and sidecar assets.
    class ComponentIntrospector
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

        props = extract_props(content)
        enum_values = extract_enum_values(content)
        attach_enum_values_to_props(props, enum_values, content)

        component = {
          name: class_name,
          file: relative,
          type: detect_component_type(content),
          props: props,
          slots: extract_slots(content)
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

      def extract_slots(content)
        slots = []

        # Use AST for renders_one / renders_many detection
        ast_data = SourceIntrospector.walk_source(content, {
          slot_macros: -> { Listeners::GenericMacroListener.new(:renders_one, :renders_many) }
        })

        ast_data[:slot_macros].each do |macro|
          slot_name = macro[:args]&.first&.to_s
          next unless slot_name

          type = macro[:macro] == :renders_one ? :one : :many
          slot = { name: slot_name, type: type }

          # Check if there's a renderer argument (second arg or options)
          remaining_args = macro[:args][1..]
          if remaining_args&.any?
            slot[:renderer] = remaining_args.map(&:to_s).join(", ")
          end

          slots << slot
        end

        # Phlex slots: def slot_name(&block) - keep regex for this (Phlex-specific, diminishing returns)
        if detect_component_type(content) == :phlex
          content.scan(/def\s+(\w+)\s*\(\s*&\s*\w*\s*\)/).each do |name,|
            next if %w[initialize template view_template before_template after_template].include?(name)
            slots << { name: name, type: :phlex_slot }
          end
        end

        slots
      end

      # Extracts enumerable values from constants and case statements.
      # Returns a hash mapping downcased constant/variable names to arrays of symbol values.
      # Detects three patterns:
      #   1. Hash constants: VARIANTS = { primary: "...", secondary: "..." } -> keys
      #   2. Array constants: SIZES = [:sm, :md, :lg] -> elements
      #   3. Case statements: case @variant; when :primary; when :secondary -> when values
      def extract_enum_values(content)
        enums = {}

        # Pattern 1: Hash constants — NAME = { key: "value", ... }
        content.scan(/([A-Z][A-Z_0-9]*)\s*=\s*\{([^}]*)\}/m) do |name, body|
          keys = body.scan(/(\w+):/).map(&:first)
          enums[name.downcase] = keys if keys.any?
        end

        # Pattern 2: Array constants — NAME = [:sym, :sym, ...]
        content.scan(/([A-Z][A-Z_0-9]*)\s*=\s*\[([^\]]*)\]/) do |name, body|
          values = body.scan(/:(\w+)/).map(&:first)
          enums[name.downcase] = values if values.any?
        end

        # Pattern 3: Case statements — case @ivar; when :val1 ... when :val2
        # Use a non-greedy match that stops at the next `end`, `case`, or `def` keyword
        content.scan(/case\s+@(\w+)\s*\n(.*?)(?=\n\s*(?:end|case|def)\b)/m) do |ivar, block|
          values = block.scan(/when\s+:(\w+)/).map(&:first)
          next if values.empty?
          # Merge with existing values for same ivar (handles multiple case blocks)
          existing = enums[ivar] || []
          enums[ivar] = (existing + values).uniq
        end

        enums
      end

      # Matches extracted enum values to props by:
      #   1. Direct ivar match: prop "variant" matches case @variant values
      #   2. Constant name match: prop "size" matches SIZES constant, prop "variant" matches VARIANTS constant
      #   3. Constant usage in initialize: @size referenced as SIZES[@size] matches prop "size"
      def attach_enum_values_to_props(props, enum_values, content)
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

          # Constant usage match: find CONST[@ivar] patterns in the file
          unless values
            content.scan(/([A-Z][A-Z_0-9]*)\[@#{name}\]/) do |const_name,|
              if enum_values.key?(const_name.downcase)
                values = enum_values[const_name.downcase]
                break
              end
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
