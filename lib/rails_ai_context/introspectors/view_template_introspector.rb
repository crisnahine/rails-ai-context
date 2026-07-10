# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    # Reads actual view template contents and extracts metadata:
    # partial references, Stimulus controller usage, line counts.
    # Separate from ViewIntrospector which focuses on structural discovery.
    class ViewTemplateIntrospector
      attr_reader :app

      def initialize(app)
        @app = app
      end

      def call
        views_dir = File.join(app.root.to_s, "app", "views")
        return { templates: {}, partials: {} } unless Dir.exist?(views_dir)

        {
          templates: scan_templates(views_dir),
          partials: scan_partials(views_dir)
        }
      rescue => e
        { error: e.message }
      end

      private

      def scan_templates(views_dir)
        templates = {}
        Dir.glob(File.join(views_dir, "**", "*")).each do |path|
          next if File.directory?(path)
          next if File.basename(path).start_with?("_") # skip partials
          next if path.include?("/layouts/")

          relative = path.sub("#{views_dir}/", "")
          content = RailsAiContext::SafeFile.read(path) or next

          slots = extract_slot_refs(content)

          if phlex_view?(path, content)
            entry = {
              lines: content.lines.count,
              partials: extract_partial_refs(content),
              stimulus: extract_stimulus_refs(content),
              components: extract_phlex_component_renders(content),
              helpers: extract_phlex_helper_calls(content),
              phlex: true
            }
            entry[:slots] = slots unless slots.empty?
            templates[relative] = entry
          else
            entry = {
              lines: content.lines.count,
              partials: extract_partial_refs(content),
              stimulus: extract_stimulus_refs(content)
            }
            entry[:slots] = slots unless slots.empty?
            templates[relative] = entry
          end
        end
        templates
      end

      def scan_partials(views_dir)
        partials = {}
        Dir.glob(File.join(views_dir, "**", "_*")).each do |path|
          next if File.directory?(path)
          relative = path.sub("#{views_dir}/", "")
          content = RailsAiContext::SafeFile.read(path) or next
          partials[relative] = {
            lines: content.lines.count,
            fields: extract_model_fields(content),
            helpers: extract_helper_calls(content)
          }
        end
        partials
      end

      # Detect whether a view file is a Phlex view (Ruby DSL, not ERB)
      def phlex_view?(path, content)
        return false unless path.end_with?(".rb")
        # Check for Phlex class patterns: inherits from a View/Base class and defines view_template
        content.match?(/class\s+\S+\s*<\s*\S+/) && content.match?(/def\s+view_template\b/)
      end

      # Extract component render calls from Phlex Ruby DSL
      # Matches: render ComponentName.new(...), render(ComponentName.new(...))
      # Also matches: render Components::Nested::Name.new(...)
      def extract_phlex_component_renders(content)
        components = Set.new
        content.scan(/render[\s(]+([A-Z]\w+(?:::\w+)*)\.new/).each do |match|
          components << match[0]
        end
        components.to_a.sort
      end

      # Extract helper method calls from Phlex views
      # Phlex views use include to pull in helpers, and call them directly
      PHLEX_HELPER_METHODS = %w[
        link_to image_tag content_for button_to form_with form_for
        content_tag tag number_to_currency number_to_human
        time_ago_in_words distance_of_time_in_words
        truncate pluralize raw sanitize dom_id
      ].freeze

      def extract_phlex_helper_calls(content)
        helpers = []
        PHLEX_HELPER_METHODS.each do |method|
          helpers << method if content.match?(/\b#{method}\b/)
        end
        helpers
      end

      EXCLUDED_METHODS = %w[
        each map select reject first last size count any? empty? present? blank?
        new build create find where order limit nil? join class html_safe
        to_s to_i to_f inspect strip chomp downcase upcase capitalize
        humanize pluralize singularize truncate gsub sub scan match split
        freeze dup clone length bytes chars reverse uniq compact flatten
        flat_map zip sort sort_by min max sum group_by
        persisted? new_record? valid? errors reload save destroy update
        delete respond_to? is_a? kind_of? send try
        abs round ceil floor
        strftime iso8601 beginning_of_day end_of_day ago from_now
      ].freeze

      def extract_model_fields(content)
        fields = []
        # Only extract from @variable.field patterns (instance variable receivers)
        content.scan(/@\w+\.(\w+)/).each do |m|
          field = m[0]
          next if field.length < 3 || field.length > 40
          next if field.match?(/\A[0-9a-f]+\z/)
          next if field.match?(/\A[A-Z]/)
          next if EXCLUDED_METHODS.include?(field)
          next if field.start_with?("to_", "html_")
          next if field.end_with?("?", "!")
          fields << field
        end
        # Also extract from form helper symbols: f.text_field :name, f.select :status
        content.scan(/f\.\w+(?:_field|_area|_select)?\s+:(\w+)/).each do |m|
          fields << m[0] if m[0].length >= 2
        end
        fields.uniq.first(15)
      end

      def extract_helper_calls(content)
        helpers = []
        # Custom helper methods (render_*, format_*, *_path, *_url)
        content.scan(/\b(render_\w+|format_\w+)\b/).each { |m| helpers << m[0] }
        helpers.uniq
      end

      RENDER_KEYWORD_ARGS = %w[
        partial layout collection json plain html text xml body file inline
        js status location content_type template formats spacer_template
        cached as object each_serializer
      ].to_set.freeze

      def extract_partial_refs(content)
        refs = []
        # render "partial_name" or render partial: "name"
        content.scan(/render\s+(?:partial:\s*)?["']([^"']+)["']/).each { |m| refs << m[0] }
        # render @collection
        content.scan(/render\s+@(\w+)/).each { |m| refs << m[0] }
        # render article / render(article) - Rails 7+ bare local-variable/object
        # render (the scaffold default: `render @articles.each { |article| render article }`).
        # The negative lookahead excludes keyword-argument hashes like
        # `render json: ...` / `render partial: ...`, where a colon immediately
        # follows the identifier instead of a statement boundary.
        content.scan(/\brender[\s(]+([a-z_]\w*)\b(?!\s*:)/).each do |m|
          refs << m[0] unless RENDER_KEYWORD_ARGS.include?(m[0])
        end
        # Phlex: render ComponentName.new(...) or render(ComponentName.new(...))
        content.scan(/render[\s(]+([A-Z]\w+(?:::\w+)*)\.new/).each { |m| refs << m[0] }
        refs.uniq
      end

      def extract_stimulus_refs(content)
        refs = []
        # data-controller="name" or data-controller="name1 name2" (ERB/HTML)
        content.scan(/data-controller=["']([^"']+)["']/).each do |m|
          m[0].split.each { |c| refs << c }
        end
        # data: { controller: "name" } (ERB helpers / Phlex hash syntax)
        content.scan(/controller:\s*["']([^"']+)["']/).each do |m|
          m[0].split.each { |c| refs << c }
        end
        # Phlex keyword: data_controller: "name" (Phlex HTML attributes)
        content.scan(/data_controller:\s*["']([^"']+)["']/).each do |m|
          m[0].split.each { |c| refs << c }
        end
        refs.uniq
      end

      def extract_slot_refs(content)
        content.scan(/\b(?:renders_one|renders_many)\s+:(\w+)/).flatten
      rescue => e
        $stderr.puts "[rails-ai-context] extract_slot_refs failed: #{e.message}" if ENV["DEBUG"]
        []
      end
    end
  end
end
