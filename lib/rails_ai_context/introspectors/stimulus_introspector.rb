# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    # Scans Stimulus controllers and extracts targets, values, and actions.
    class StimulusIntrospector
      attr_reader :app

      def initialize(app)
        @app = app
      end

      def call
        root = app.root.to_s
        controllers_dir = File.join(root, "app/javascript/controllers")
        return { controllers: [], cross_controller_composition: [] } unless Dir.exist?(controllers_dir)

        controllers = Dir.glob(File.join(controllers_dir, "**/*_controller.{js,ts}")).sort.filter_map do |path|
          parse_controller(path, controllers_dir)
        end

        {
          controllers: controllers,
          cross_controller_composition: extract_cross_controller_composition(root)
        }
      rescue => e
        { error: e.message }
      end

      private

      def parse_controller(path, base_dir)
        relative = path.sub("#{base_dir}/", "")
        name = relative.sub(/_controller\.(js|ts)\z/, "").tr("/", "--")
        content = File.read(path)

        {
          name: name,
          file: relative,
          targets: extract_targets(content),
          values: extract_values(content),
          actions: extract_actions(content),
          outlets: extract_outlets(content),
          classes: extract_classes(content),
          import_graph: extract_import_graph(content),
          complexity: extract_complexity(content),
          turbo_event_listeners: extract_turbo_event_listeners(content)
        }
      rescue => e
        { name: File.basename(path), error: e.message }
      end

      def extract_targets(content)
        match = content.match(/static\s+targets\s*=\s*\[([^\]]*)\]/)
        return [] unless match

        match[1].scan(/["'](\w+)["']/).flatten
      end

      def extract_values(content)
        start_match = content.match(/static\s+values\s*=\s*\{/)
        return {} unless start_match

        # Use brace-depth counting to find the matching closing brace,
        # handling nested objects like { active: { type: String, default: "overview" } }
        start_pos = start_match.end(0)
        depth = 1
        pos = start_pos

        while pos < content.length && depth > 0
          case content[pos]
          when "{" then depth += 1
          when "}" then depth -= 1
          end
          pos += 1
        end

        return {} if depth != 0

        body = content[start_pos...pos - 1]
        values = {}

        # Handle complex format: name: { type: Type, default: val }
        body.scan(/(\w+)\s*:\s*\{([^}]+)\}/).each do |name, inner|
          type = inner.match(/type:\s*(\w+)/)&.send(:[], 1) || "Object"
          default = inner.match(/default:\s*(\S+)/)&.send(:[], 1)&.chomp(",")
          values[name] = default ? "#{type} (default: #{default})" : type
        end

        # Handle simple format: name: Type (single line or multi-line)
        # Skip 'type' and 'default' — they are keywords inside complex value definitions,
        # not actual Stimulus value names
        body.scan(/(\w+)\s*:\s*([A-Z]\w+)/).each do |name, type|
          next if %w[type default].include?(name)
          values[name] ||= type
        end

        values
      end

      def extract_actions(content)
        content.scan(/^\s+(?:async\s+)?(\w+)\s*\([^)]*\)\s*\{/).flatten
               .reject { |m| %w[constructor connect disconnect initialize if else for while switch catch function].include?(m) }
      end

      def extract_outlets(content)
        match = content.match(/static\s+outlets\s*=\s*\[([^\]]*)\]/)
        return [] unless match

        match[1].scan(/["']([^"']+)["']/).flatten
      end

      def extract_classes(content)
        match = content.match(/static\s+classes\s*=\s*\[([^\]]*)\]/)
        return [] unless match

        match[1].scan(/["']([^"']+)["']/).flatten
      end

      def extract_import_graph(content)
        imports = []
        content.each_line do |line|
          if (match = line.match(/import\s+.*?from\s+["']([^"']+)["']/))
            imports << match[1]
          elsif (match = line.match(/import\s+["']([^"']+)["']/))
            imports << match[1]
          end
        end
        imports
      rescue => e
        $stderr.puts "[rails-ai-context] extract_import_graph failed: #{e.message}" if ENV["DEBUG"]
        []
      end

      JS_KEYWORDS = %w[if else for while switch catch function].freeze

      def extract_complexity(content)
        loc = content.lines.count { |line| line.strip.length > 0 }
        methods = content.scan(/^\s+(?:async\s+)?(\w+)\s*\([^)]*\)\s*\{/).flatten
        method_count = methods.count { |m| !JS_KEYWORDS.include?(m) }
        { loc: loc, method_count: method_count }
      rescue => e
        $stderr.puts "[rails-ai-context] extract_complexity failed: #{e.message}" if ENV["DEBUG"]
        { loc: 0, method_count: 0 }
      end

      def extract_turbo_event_listeners(content)
        events = content.scan(/["']turbo:([\w:-]+)["']/).flatten.uniq
        events.map { |e| "turbo:#{e}" }
      rescue => e
        $stderr.puts "[rails-ai-context] extract_turbo_event_listeners failed: #{e.message}" if ENV["DEBUG"]
        []
      end

      def extract_cross_controller_composition(root)
        views_dir = File.join(root, "app/views")
        return [] unless Dir.exist?(views_dir)

        compositions = []
        Dir.glob(File.join(views_dir, "**/*.{erb,haml,slim}")).each do |path|
          content = File.read(path) rescue next
          relative = path.sub("#{views_dir}/", "")

          content.scan(/data-controller=["']([^"']+)["']/).each do |match|
            controllers = match[0].split
            next unless controllers.size > 1
            compositions << { file: relative, controllers: controllers }
          end
        end

        compositions.uniq
      rescue => e
        $stderr.puts "[rails-ai-context] extract_cross_controller_composition failed: #{e.message}" if ENV["DEBUG"]
        []
      end
    end
  end
end
