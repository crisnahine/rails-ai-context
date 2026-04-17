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
        # Rule 1 (security conventions): reject path traversal and sensitive
        # names on the caller-supplied string BEFORE any filesystem stat.
        # `String#underscore` only maps CamelCase → snake_case; it does NOT
        # sanitize `../` or slashes, so a bare `File.join + File.exist?` on
        # `name.underscore` would resolve `name: "../../config/initializers/devise"`
        # and read arbitrary .rb files under Rails.root.
        if name.nil? || name.to_s.empty?
          return text_response("The `name` parameter is required.")
        end
        if name.to_s.include?("..") || name.to_s.include?("\0") || name.to_s.start_with?("/")
          return text_response("Path not allowed: #{name}")
        end
        if sensitive_file?(name.to_s)
          return text_response("Path not allowed: #{name} (sensitive file)")
        end

        # Find the concern file — try underscore variants and nested paths
        underscore = name.underscore
        # Re-check traversal on the post-underscore string in case `underscore`
        # introduces unexpected transformations on future AS versions.
        if underscore.include?("..") || underscore.start_with?("/")
          return text_response("Path not allowed: #{name}")
        end

        file_path = nil
        concern_type = nil

        concern_dirs.each do |dir|
          candidate = File.join(dir, "#{underscore}.rb")
          next unless File.exist?(candidate)

          # Rules 2-5: realpath + separator-aware containment under the
          # concern dir, post-realpath sensitive recheck, then use the
          # realpath for all subsequent file operations. A symlink inside
          # app/models/concerns/ pointing at config/master.key would pass
          # the bare existence check without this.
          real =
            begin
              File.realpath(candidate).to_s
            rescue Errno::ENOENT
              nil
            end
          next unless real

          real_dir = File.realpath(dir).to_s
          next unless real == real_dir || real.start_with?(real_dir + File::SEPARATOR)

          relative_real = real.sub("#{File.realpath(root)}/", "")
          next if sensitive_file?(relative_real)

          file_path = real
          concern_type = dir.include?("models") ? "model" : "controller"
          break
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

        source = RailsAiContext::SafeFile.read(file_path)
        return text_response("Could not read concern file: #{file_path}") unless source
        relative_path = file_path.sub("#{File.realpath(root)}/", "")

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
              method_source = extract_method_source_from_string(source, method_name)
              if method_source
                lines << "### #{m}"
                lines << "```ruby"
                lines << method_source[:code]
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
              method_source = extract_method_source_from_string(source, method_name) || extract_method_source_from_string(source, "self.#{method_name}")
              if method_source
                lines << "### #{m}"
                lines << "```ruby"
                lines << method_source[:code]
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
        real_root = File.realpath(root).to_s

        concern_dirs.each do |dir|
          concern_type = dir.include?("models") ? "model" : "controller"
          real_dir = File.realpath(dir).to_s
          Dir.glob(File.join(dir, "**", "*.rb")).sort.each do |file_path|
            # Apply the 5-rule file-reading pattern per CLAUDE.md. Even though
            # file_path comes from Dir.glob (not caller-supplied), a symlink
            # planted inside `app/models/concerns/` pointing at
            # `config/master.key` would otherwise be silently read.
            real =
              begin
                File.realpath(file_path).to_s
              rescue Errno::ENOENT
                nil
              end
            next unless real
            next unless real == real_dir || real.start_with?(real_dir + File::SEPARATOR)

            relative_real = real.sub("#{real_root}/", "")
            next if sensitive_file?(relative_real)

            relative = real.sub("#{real_root}/", "")
            concern_name = real.sub("#{real_dir}/", "").sub(/\.rb$/, "").camelize

            method_count = 0
            if File.size(real) <= max_size
              source = RailsAiContext::SafeFile.read(real)
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
          if line.match?(/\A\s*class_methods\s+do/)
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

        class_methods_indent = 0

        source.each_line do |line|
          if line.match?(/\A\s*class_methods\s+do/)
            in_class_methods = true
            in_private = false
            class_methods_indent = line[/\A\s*/].length
            next
          end

          if in_class_methods
            in_private = true if line.match?(/\A\s*(private|protected)\s*$/)

            if line.match?(/\A\s*end\s*$/)
              current_indent = line[/\A\s*/].length
              if current_indent <= class_methods_indent
                in_class_methods = false
                in_private = false
                next
              end
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
        # Handle both simple and namespaced concern names.
        # Use `camelize` (not `classify`) — `classify` singularizes, which drops
        # the final `s` from plural concern names like `WorksheetImports` and
        # then fails to match `include WorksheetImports` in the model.
        simple_name = concern_name.demodulize.camelize
        pattern = /^\s*include\s+(?:\w+::)*#{Regexp.escape(simple_name)}\b/

        search_dirs.each do |dir|
          next unless Dir.exist?(dir)
          Dir.glob(File.join(dir, "**", "*.rb")).each do |file_path|
            # Skip concern files themselves
            next if file_path.include?("/concerns/")
            next if File.size(file_path) > max_size

            source = RailsAiContext::SafeFile.read(file_path) or next
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
