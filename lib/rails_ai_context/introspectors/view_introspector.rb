# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    # Scans view layer: layouts, templates, partials, helpers,
    # view components, and template engine detection.
    class ViewIntrospector < Base
      extend StaticTier
      static_tier :files_only

      def call
        {
          layouts: extract_layouts,
          templates: extract_templates,
          partials: extract_partials,
          helpers: extract_helpers,
          view_components: extract_view_components,
          template_engines: detect_template_engines,
          form_builders_detected: detect_form_builders,
          component_usage: detect_component_usage,
          conditional_layouts: detect_conditional_layouts
        }
      end

      private

      # Every view file across every views root, an in-repo engine's or plugin's
      # included, named the way the app renders it.
      def view_files(glob = "**/*")
        @view_files ||= {}
        @view_files[glob] ||= RailsAiContext::ViewFile.each(root, glob)
      end

      def extract_layouts
        view_files("layouts/*").filter_map do |path, _relative|
          next unless File.file?(path) && RailsAiContext::ViewFile.layout?(path)
          content = RailsAiContext::SafeFile.read(path)
          unless content
            next { name: File.basename(path) }
          end
          yields = layout_yields(path, content)
          entry = { name: File.basename(path) }
          entry[:yields] = yields unless yields.empty?
          entry
        end.uniq { |l| l[:name] }.sort_by { |l| l[:name] }
      end

      YIELD = /\byield\b(?:\s*\(?\s*(?::(\w+)|["'](\w+)["']))?/
      # `content_for?(:x)` asks; `content_for(:x)` alone reads. With a value or a block it sets.
      CONTENT_FOR = /\bcontent_for(\?)?\s*\(?\s*(?::(\w+)|["'](\w+)["'])\s*(?:(,)|\)?\s*(do\b|\{))?/
      # The unnamed `yield`, where the action's own template lands.
      MAIN_YIELD = "(main)"
      # A HAML or Slim line's Ruby: after `=`, `-`, `!=`, `==`, `&=` or `~`, bare or after a tag.
      HAML_RUBY = /\A\s*(?:[%.#][\w.#:-]*(?:\{[^}]*\}|\([^)]*\))*)?\s*(?:!=|==|&=|=|~|-)\s?(.*)/
      SLIM_RUBY = /\A\s*(?:[\w.#:-]+(?:\{[^}]*\}|\([^)]*\)|\[[^\]]*\])*)?\s*(?:!=|==|&=|=|~|-)\s?(.*)/

      def layout_yields(path, content)
        ruby = layout_ruby(path, ViewTemplateIntrospector.strip_markup_comments(content))
        found = []
        ruby.scan(Regexp.union(YIELD, CONTENT_FOR)) do
          m = Regexp.last_match
          if m[0].start_with?("yield")
            found << (m[1] || m[2] || MAIN_YIELD)
          elsif m[3] || !(m[6] || m[7])
            found << (m[4] || m[5])
          end
        end
        found.uniq
      end

      HAML_ATTRIBUTES = /\{(?:[^{}]|\{[^{}]*\})*\}/
      SLIM_ATTRIBUTE = /[\w-]+=(\([^)]*\)|[^\s"'][^\s]*)/

      # Only the Ruby a layout runs: ERB tag bodies; HAML and Slim code after
      # an operator, plus a HAML attribute hash or a Slim attribute value.
      def layout_ruby(path, text)
        return RailsAiContext::ErbSource.tag_bodies(text) if path.end_with?(".erb")

        slim = path.end_with?(".slim")
        text.each_line.flat_map { |line|
          attributes = if slim
            line.scan(SLIM_ATTRIBUTE).flatten
          else
            line.match?(/\A\s*[%.#]/) ? line.scan(HAML_ATTRIBUTES) : []
          end
          attributes + [ line[slim ? SLIM_RUBY : HAML_RUBY, 1] ].compact
        }.join("\n")
      end

      def extract_templates
        templates = {}
        view_files.each do |path, relative|
          next unless RailsAiContext::ViewFile.template?(path)
          next if relative.start_with?("layouts/")
          next if File.basename(relative).start_with?("_")

          controller = File.dirname(relative)
          templates[controller] ||= []
          templates[controller] << File.basename(relative)
        end

        templates.transform_values(&:sort)
      end

      def extract_partials
        shared = []
        per_controller = {}

        view_files("**/_*").each do |path, relative|
          next unless RailsAiContext::ViewFile.template?(path)
          dir = File.dirname(relative)
          name = File.basename(relative)

          if dir == "shared" || dir == "application"
            shared << name
          else
            per_controller[dir] ||= []
            per_controller[dir] << name
          end
        end

        { shared: shared.sort, per_controller: per_controller.transform_values(&:sort) }
      end

      def extract_helpers
        dir = File.join(root, "app/helpers")
        return [] unless Dir.exist?(dir)

        Dir.glob(File.join(dir, "**/*.rb")).filter_map do |path|
          relative = path.sub("#{dir}/", "")
          module_name = relative.sub(/\.rb\z/, "").camelize
          ast_data = SourceIntrospector.walk(path, { methods: Listeners::MethodsListener })
          methods = ActionResolver.own_methods(ast_data[:methods], module_name).map { |m| m[:name] }
          {
            file: relative,
            methods: methods
          }
        rescue => e
          RailsAiContext.debug_fail(e, nil, label: "extract_helpers")
        end.sort_by { |h| h[:file] }
      end

      def extract_view_components
        dir = File.join(root, "app/components")
        return [] unless Dir.exist?(dir)

        Dir.glob(File.join(dir, "**/*.rb")).filter_map do |path|
          path.sub("#{dir}/", "").sub(/\.rb\z/, "")
        end.sort
      end

      def detect_template_engines
        extensions = view_files.filter_map do |path, _relative|
          ext = File.extname(path).delete(".")
          ext unless ext.empty?
        end

        engines = []
        engines << "erb" if extensions.include?("erb")
        engines << "haml" if extensions.include?("haml")
        engines << "slim" if extensions.include?("slim")
        engines << "jbuilder" if extensions.include?("jbuilder")
        engines
      end

      FORM_BUILDER_PATTERNS = {
        "form_with" => /\bform_with\b/,
        "form_for" => /\bform_for\b/,
        "simple_form_for" => /\bsimple_form_for\b/,
        "formtastic" => /\bsemantic_form_for\b/
      }.freeze

      def detect_form_builders
        # The glob spans ERB, HAML, Slim and Phlex `.rb`, and only the last has
        # a Ruby AST. One text matcher keeps the count consistent across them.
        counts = Hash.new(0)
        view_files("**/*.{erb,haml,slim,rb}").each do |path, _relative|
          content = RailsAiContext::SafeFile.read(path) or next
          FORM_BUILDER_PATTERNS.each do |name, pattern|
            count = content.scan(pattern).size
            counts[name] += count if count > 0
          end
        end

        counts.sort_by { |_, v| -v }.to_h
      rescue => e
        RailsAiContext.debug_fail(e, {}, label: "detect_form_builders")
      end

      def detect_component_usage
        components = Set.new
        view_files("**/*.{erb,haml,slim,rb}").each do |path, _relative|
          content = RailsAiContext::SafeFile.read(path) or next
          # Same mixed-extension glob as above: text matching, not AST.
          # Match render ComponentName.new(...) or render(ComponentName.new(...))
          content.scan(/render\s*\(?\s*([A-Z]\w+(?:::\w+)*(?:Component)?)\.new/).each do |match|
            components << match[0]
          end
        end

        components.to_a.sort
      rescue => e
        RailsAiContext.debug_fail(e, [], label: "detect_component_usage")
      end

      def detect_conditional_layouts
        layouts = []
        controllers_dir = File.join(app.root, "app", "controllers")
        return layouts unless Dir.exist?(controllers_dir)

        Dir.glob(File.join(controllers_dir, "**", "*.rb")).each do |path|
          ast_data = SourceIntrospector.walk(path, {
            layout_calls: -> { Listeners::GenericMacroListener.new(:layout) }
          })

          ast_data[:layout_calls].each do |macro|
            layout_name = macro[:args]&.first&.to_s
            # Also check options for string-based layout names
            layout_name ||= macro[:options].values.first&.to_s if macro[:options]&.any?
            next unless layout_name

            entry = { layout: layout_name, controller: File.basename(path, ".rb").camelize }
            opts = macro[:options] || {}
            entry[:only] = Array(opts[:only]).map(&:to_s) if opts[:only]
            entry[:except] = Array(opts[:except]).map(&:to_s) if opts[:except]

            # Build condition string from options for backward compat
            condition_parts = []
            condition_parts << "only: #{opts[:only].inspect}" if opts[:only]
            condition_parts << "except: #{opts[:except].inspect}" if opts[:except]
            entry[:condition] = condition_parts.join(", ") if condition_parts.any?

            layouts << entry
          end
        rescue => e
          RailsAiContext.debug_fail(e, label: "detect_conditional_layouts")
        end
        layouts
      rescue => e
        RailsAiContext.debug_fail(e, [], label: "detect_conditional_layouts")
      end
    end
  end
end
