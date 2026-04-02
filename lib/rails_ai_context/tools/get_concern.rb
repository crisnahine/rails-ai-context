# frozen_string_literal: true

module RailsAiContext
  module Tools
    class GetConcern < BaseTool
      tool_name "rails_get_concern"
      description "Get ActiveSupport::Concern details: public methods, included modules, and which models/controllers include it. " \
        "Use when: understanding shared behavior, checking concern interfaces, or finding where a concern is used. " \
        "Specify name:\"Searchable\" for full detail, or omit for a list of all concerns. Filter with type:\"model\" or type:\"controller\"."

      input_schema(
        properties: {
          name: {
            type: "string",
            description: "Concern module name (e.g. 'Searchable', 'Authenticatable'). Omit to list all concerns."
          },
          type: {
            type: "string",
            enum: %w[model controller all],
            description: "Filter by concern type. model: app/models/concerns/. controller: app/controllers/concerns/. all: both (default)."
          },
          detail: {
            type: "string",
            enum: %w[summary standard full],
            description: "Detail level. summary: concern names only. standard: names + method signatures (default). full: method signatures with source code."
          }
        }
      )

      annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true, open_world_hint: false)

      def self.call(name: nil, type: "all", detail: "standard", server_context: nil)
        root = rails_app.root.to_s
        max_size = RailsAiContext.configuration.max_file_size

        concern_dirs = resolve_concern_dirs(root, type)

        if concern_dirs.empty?
          return text_response("No concern directories found. Searched: #{searched_dirs(type).join(', ')}")
        end

        # Specific concern — full detail
        if name
          return show_concern(name, concern_dirs, root, max_size, detail)
        end

        # List all concerns
        list_concerns(concern_dirs, root, max_size)
      end

      private_class_method def self.resolve_concern_dirs(root, type)
        dirs = case type
        when "model"
          [ File.join(root, "app", "models", "concerns") ]
        when "controller"
          [ File.join(root, "app", "controllers", "concerns") ]
        else
          [
            File.join(root, "app", "models", "concerns"),
            File.join(root, "app", "controllers", "concerns")
          ]
        end

        dirs.select { |d| Dir.exist?(d) }
      end

      private_class_method def self.searched_dirs(type)
        case type
        when "model" then %w[app/models/concerns/]
        when "controller" then %w[app/controllers/concerns/]
        else %w[app/models/concerns/ app/controllers/concerns/]
        end
      end

      private_class_method def self.show_concern(name, concern_dirs, root, max_size, detail = "standard")
        # Find the concern file — try underscore variants and nested paths
        underscore = name.underscore
        file_path = nil
        concern_type = nil

        concern_dirs.each do |dir|
          candidate = File.join(dir, "#{underscore}.rb")
          if File.exist?(candidate)
            file_path = candidate
            concern_type = dir.include?("models") ? "model" : "controller"
            break
          end
        end

        unless file_path
          # Build available list for fuzzy match
          available = collect_concern_names(concern_dirs)
          return not_found_response("Concern", name, available,
            recovery_tool: "Call rails_get_concern() to see all concerns")
        end

        if File.size(file_path) > max_size
          return text_response("Concern file too large: #{file_path} (#{File.size(file_path)} bytes, max: #{max_size})")
        end

        source = File.read(file_path, encoding: "UTF-8", invalid: :replace, undef: :replace)
        relative_path = file_path.sub("#{root}/", "")

        lines = [ "# #{name}", "" ]
        lines << "**File:** `#{relative_path}` (#{source.lines.size} lines)"
        lines << "**Type:** #{concern_type} concern"

        # Parse included/extended modules
        included_modules = source.scan(/^\s*include\s+(\S+)/).flatten
        extended_modules = source.scan(/^\s*extend\s+(\S+)/).flatten
        if included_modules.any?
          lines << "**Includes:** #{included_modules.join(', ')}"
        end
        if extended_modules.any?
          lines << "**Extends:** #{extended_modules.join(', ')}"
        end

        # Parse class-level macros inside included/class_methods blocks
        macros = parse_concern_macros(source)
        if macros.any?
          lines << "" << "## Macros & DSL"
          macros.each { |m| lines << "- #{m}" }
        end

        # Parse public methods with signatures
        public_methods = parse_public_methods(source)
        if public_methods.any?
          lines << "" << "## Public Methods"
          if detail == "full"
            public_methods.each do |m|
              method_name = m.to_s.split("(").first
              method_source = extract_method_source(source, method_name)
              if method_source
                lines << "### #{m}"
                lines << "```ruby"
                lines << method_source
                lines << "```"
                lines << ""
              else
                lines << "- `#{m}`"
              end
            end
          else
            public_methods.each { |m| lines << "- `#{m}`" }
          end
        end

        # Parse class methods (inside class_methods block or def self.)
        class_methods = parse_class_methods(source)
        if class_methods.any?
          lines << "" << "## Class Methods"
          if detail == "full"
            class_methods.each do |m|
              method_name = m.to_s.split("(").first
              # Try both `def method_name` and `def self.method_name`
              method_source = extract_method_source(source, method_name) || extract_method_source(source, "self.#{method_name}")
              if method_source
                lines << "### #{m}"
                lines << "```ruby"
                lines << method_source
                lines << "```"
                lines << ""
              else
                lines << "- `#{m}`"
              end
            end
          else
            class_methods.each { |m| lines << "- `#{m}`" }
          end
        end

        # Parse callbacks defined in the concern
        callbacks = parse_concern_callbacks(source)
        if callbacks.any?
          lines << "" << "## Callbacks"
          callbacks.each { |c| lines << "- `#{c}`" }
        end

        # Find which models/controllers include this concern
        includers = find_includers(name, root, concern_type)
        if includers.any?
          lines << "" << "## Included By (#{includers.size})"
          includers.each { |i| lines << "- #{i}" }
        else
          lines << "" << "_No models or controllers found that include this concern._"
        end

        # Cross-reference hints
        lines << ""
        if concern_type == "model"
          lines << "_Next: `rails_get_model_details(model:\"ModelName\")` for models using this concern_"
        else
          lines << "_Next: `rails_get_controllers(controller:\"ControllerName\")` for controllers using this concern_"
        end

        text_response(lines.join("\n"))
      end

      private_class_method def self.list_concerns(concern_dirs, root, max_size)
        all_concerns = []

        concern_dirs.each do |dir|
          concern_type = dir.include?("models") ? "model" : "controller"
          Dir.glob(File.join(dir, "**", "*.rb")).sort.each do |file_path|
            relative = file_path.sub("#{root}/", "")
            concern_name = file_path.sub("#{dir}/", "").sub(/\.rb$/, "").camelize

            method_count = 0
            if File.size(file_path) <= max_size
              source = File.read(file_path, encoding: "UTF-8", invalid: :replace, undef: :replace) rescue nil
              if source
                public_methods = parse_public_methods(source)
                class_methods = parse_class_methods(source)
                method_count = public_methods.size + class_methods.size
              end
            end

            all_concerns << {
              name: concern_name,
              type: concern_type,
              path: relative,
              method_count: method_count
            }
          end
        end

        if all_concerns.empty?
          return text_response("No concerns found in #{concern_dirs.map { |d| d.sub("#{root}/", "") }.join(', ')}.")
        end

        model_concerns = all_concerns.select { |c| c[:type] == "model" }
        controller_concerns = all_concerns.select { |c| c[:type] == "controller" }

        lines = [ "# Concerns (#{all_concerns.size})", "" ]

        if model_concerns.any?
          lines << "## Model Concerns (#{model_concerns.size})"
          model_concerns.each do |c|
            lines << "- **#{c[:name]}** — #{c[:method_count]} methods (`#{c[:path]}`)"
          end
          lines << ""
        end

        if controller_concerns.any?
          lines << "## Controller Concerns (#{controller_concerns.size})"
          controller_concerns.each do |c|
            lines << "- **#{c[:name]}** — #{c[:method_count]} methods (`#{c[:path]}`)"
          end
          lines << ""
        end

        lines << "_Use `name:\"ConcernName\"` for full detail including method signatures and includers._"
        text_response(lines.join("\n"))
      end

      private_class_method def self.collect_concern_names(concern_dirs)
        concern_dirs.flat_map do |dir|
          Dir.glob(File.join(dir, "**", "*.rb")).map do |file_path|
            file_path.sub("#{dir}/", "").sub(/\.rb$/, "").camelize
          end
        end.sort
      end

      private_class_method def self.parse_public_methods(source)
        methods = []
        in_private = false
        in_class_methods = false
        class_methods_depth = 0

        source.each_line do |line|
          # Track class_methods block
          if line.match?(/\A\s*(class_methods\s+do|def\s+self\.\w)/)
            in_class_methods = true
            class_methods_depth = line[/\A\s*/].length
          end
          if in_class_methods && line.match?(/\A\s{#{class_methods_depth}}end\b/)
            in_class_methods = false
          end
          next if in_class_methods

          in_private = true if line.match?(/\A\s*(private|protected)\s*$/)
          in_private = false if line.match?(/\A\s*public\s*$/)
          # Reset private on included/class_methods blocks
          if line.match?(/\A\s*included\s+do/)
            in_private = false
          end

          next if in_private

          if (match = line.match(/\A\s*def\s+((?!self\.)[\w?!]+(?:\([^)]*\))?)/))
            method_sig = match[1]
            methods << method_sig unless method_sig.start_with?("_")
          end
        end

        methods
      rescue => e
        $stderr.puts "[rails-ai-context] parse_public_methods failed: #{e.message}" if ENV["DEBUG"]
        []
      end

      private_class_method def self.parse_class_methods(source)
        methods = []

        # Methods inside class_methods do ... end block
        in_class_methods = false
        in_private = false

        source.each_line do |line|
          if line.match?(/\A\s*class_methods\s+do/)
            in_class_methods = true
            in_private = false
            next
          end

          if in_class_methods
            in_private = true if line.match?(/\A\s*(private|protected)\s*$/)

            if line.match?(/\A\s*end\s*$/) && !in_private
              # Could be end of class_methods block — track via indent
              # Simplified: we'll just collect until we see a top-level end
            end

            if !in_private && (match = line.match(/\A\s*def\s+([\w?!]+(?:\([^)]*\))?)/))
              methods << match[1]
            end
          end

          # Also catch def self.method_name outside class_methods blocks
          if !in_class_methods && (match = line.match(/\A\s*def\s+self\.([\w?!]+(?:\([^)]*\))?)/))
            methods << match[1]
          end
        end

        methods
      rescue => e
        $stderr.puts "[rails-ai-context] parse_class_methods failed: #{e.message}" if ENV["DEBUG"]
        []
      end

      private_class_method def self.parse_concern_macros(source)
        macros = []
        # Common Rails macros that might appear in included blocks
        macro_patterns = [
          /\A\s*(has_many|has_one|belongs_to|has_and_belongs_to_many)\s+(.+)/,
          /\A\s*(validates|validate)\s+(.+)/,
          /\A\s*(scope)\s+(.+)/,
          /\A\s*(enum)\s+(.+)/,
          /\A\s*(before_\w+|after_\w+|around_\w+)\s+(.+)/,
          /\A\s*(attr_accessor|attr_reader|attr_writer)\s+(.+)/,
          /\A\s*(delegate)\s+(.+)/
        ]

        in_included = false
        source.each_line do |line|
          in_included = true if line.match?(/\A\s*included\s+do/)

          if in_included
            macro_patterns.each do |pattern|
              if (match = line.match(pattern))
                macros << "#{match[1]} #{match[2].strip}"
                break
              end
            end
          end
        end

        macros
      rescue => e
        $stderr.puts "[rails-ai-context] parse_concern_macros failed: #{e.message}" if ENV["DEBUG"]
        []
      end

      private_class_method def self.parse_concern_callbacks(source)
        callbacks = []
        callback_pattern = /\A\s*(before_validation|after_validation|before_save|after_save|before_create|after_create|before_update|after_update|before_destroy|after_destroy|around_save|around_create|around_update|around_destroy)\s+(.+)/

        source.each_line do |line|
          if (match = line.match(callback_pattern))
            callbacks << "#{match[1]} #{match[2].strip}"
          end
        end

        callbacks
      rescue => e
        $stderr.puts "[rails-ai-context] parse_concern_callbacks failed: #{e.message}" if ENV["DEBUG"]
        []
      end

      # Extract method source from raw source string using indentation-based matching
      private_class_method def self.extract_method_source(source, method_name)
        source_lines = source.lines
        escaped = Regexp.escape(method_name.to_s)
        # Don't use \b after ? or ! — they ARE word boundaries
        pattern = if method_name.to_s.end_with?("?") || method_name.to_s.end_with?("!")
          /\A\s*def\s+#{escaped}/
        else
          /\A\s*def\s+#{escaped}\b/
        end
        start_idx = source_lines.index { |l| l.match?(pattern) }
        return nil unless start_idx

        def_indent = source_lines[start_idx][/\A\s*/].length
        result = []

        source_lines[start_idx..].each_with_index do |line, i|
          result << line.rstrip
          break if i > 0 && line.match?(/\A\s{#{def_indent}}end\b/)
        end

        result.join("\n")
      rescue => e
        $stderr.puts "[rails-ai-context] extract_method_source failed: #{e.message}" if ENV["DEBUG"]
        nil
      end

      private_class_method def self.find_includers(concern_name, root, concern_type)
        includers = []
        search_dirs = []

        case concern_type
        when "model"
          search_dirs << File.join(root, "app", "models")
        when "controller"
          search_dirs << File.join(root, "app", "controllers")
        else
          search_dirs << File.join(root, "app", "models")
          search_dirs << File.join(root, "app", "controllers")
        end

        max_size = RailsAiContext.configuration.max_file_size
        # Build pattern: match `include ConcernName` or `include ModuleName::ConcernName`
        # Handle both simple and namespaced concern names
        # Classify to handle lowercase input: "plan_limitable" → "PlanLimitable"
        simple_name = concern_name.demodulize.classify
        pattern = /^\s*include\s+(?:\w+::)*#{Regexp.escape(simple_name)}\b/

        search_dirs.each do |dir|
          next unless Dir.exist?(dir)
          Dir.glob(File.join(dir, "**", "*.rb")).each do |file_path|
            # Skip concern files themselves
            next if file_path.include?("/concerns/")
            next if File.size(file_path) > max_size

            source = File.read(file_path, encoding: "UTF-8", invalid: :replace, undef: :replace) rescue next
            if source.match?(pattern)
              # Extract the class/module name from the file
              class_match = source.match(/^\s*class\s+(\S+)/) || source.match(/^\s*module\s+(\S+)/)
              class_name = class_match ? class_match[1] : File.basename(file_path, ".rb").camelize
              includers << class_name
            end
          end
        end

        includers.sort
      rescue => e
        $stderr.puts "[rails-ai-context] find_includers failed: #{e.message}" if ENV["DEBUG"]
        []
      end
    end
  end
end
