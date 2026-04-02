# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    # Scans view layer: layouts, templates, partials, helpers,
    # view components, and template engine detection.
    class ViewIntrospector
      attr_reader :app

      def initialize(app)
        @app = app
      end

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
          layout_mapping: extract_layout_mapping
        }
      rescue => e
        { error: e.message }
      end

      private

      def root
        app.root.to_s
      end

      def views_dir
        File.join(root, "app/views")
      end

      def extract_layouts
        dir = File.join(views_dir, "layouts")
        return [] unless Dir.exist?(dir)

        Dir.glob(File.join(dir, "*")).filter_map do |path|
          File.basename(path) if File.file?(path)
        end.sort
      end

      def extract_templates
        return {} unless Dir.exist?(views_dir)

        templates = {}
        Dir.glob(File.join(views_dir, "**/*")).each do |path|
          next if File.directory?(path)
          relative = path.sub("#{views_dir}/", "")
          next if relative.start_with?("layouts/")
          next if File.basename(relative).start_with?("_")

          controller = File.dirname(relative)
          templates[controller] ||= []
          templates[controller] << File.basename(relative)
        end

        templates.transform_values(&:sort)
      end

      def extract_partials
        return { shared: [], per_controller: {} } unless Dir.exist?(views_dir)

        shared = []
        per_controller = {}

        Dir.glob(File.join(views_dir, "**/_*")).each do |path|
          relative = path.sub("#{views_dir}/", "")
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
          content = File.read(path)
          methods = content.scan(/^\s*def\s+(\w+)/).flatten
          {
            file: relative,
            methods: methods
          }
        rescue => e
          $stderr.puts "[rails-ai-context] extract_helpers failed: #{e.message}" if ENV["DEBUG"]
          nil
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
        return [] unless Dir.exist?(views_dir)

        extensions = Dir.glob(File.join(views_dir, "**/*")).filter_map do |path|
          next if File.directory?(path)
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
        return {} unless Dir.exist?(views_dir)

        counts = Hash.new(0)
        view_files = Dir.glob(File.join(views_dir, "**/*.{erb,haml,slim,rb}"))
        view_files.each do |path|
          content = File.read(path) rescue next
          FORM_BUILDER_PATTERNS.each do |name, pattern|
            count = content.scan(pattern).size
            counts[name] += count if count > 0
          end
        end

        counts.sort_by { |_, v| -v }.to_h
      rescue => e
        $stderr.puts "[rails-ai-context] detect_form_builders failed: #{e.message}" if ENV["DEBUG"]
        {}
      end

      def detect_component_usage
        return [] unless Dir.exist?(views_dir)

        components = Set.new
        view_files = Dir.glob(File.join(views_dir, "**/*.{erb,haml,slim,rb}"))
        view_files.each do |path|
          content = File.read(path) rescue next
          # Match render ComponentName.new(...) or render(ComponentName.new(...))
          content.scan(/render\s*\(?\s*([A-Z]\w+(?:::\w+)*(?:Component)?)\.new/).each do |match|
            components << match[0]
          end
        end

        components.to_a.sort
      rescue => e
        $stderr.puts "[rails-ai-context] detect_component_usage failed: #{e.message}" if ENV["DEBUG"]
        []
      end

      def extract_layout_mapping
        dir = File.join(views_dir, "layouts")
        return [] unless Dir.exist?(dir)

        Dir.glob(File.join(dir, "*")).filter_map do |path|
          next unless File.file?(path)
          basename = File.basename(path)
          # Strip template extensions to get the layout name
          name = basename.sub(/\.(html|xml|json)\.(erb|haml|slim)\z/, "").sub(/\.(erb|haml|slim)\z/, "")
          name
        end.uniq.sort
      rescue => e
        $stderr.puts "[rails-ai-context] extract_layout_mapping failed: #{e.message}" if ENV["DEBUG"]
        []
      end
    end
  end
end
