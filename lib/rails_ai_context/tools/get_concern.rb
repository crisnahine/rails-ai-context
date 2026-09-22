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
            enum: %w[model controller mailer job channel helper other all],
            description: "Filter by concern type, named for the directory: model reads app/models/concerns/, mailer reads app/mailers/concerns/. other: a configured directory outside app/*/concerns. all: everything (default)."
          },
          detail: {
            type: "string",
            enum: RailsAiContext::DetailLevel::SCHEMA_ENUM,
            description: "Detail level. summary: concern names only. standard: names + method signatures (default). full: method signatures with source code."
          }
        }
      )

      guide_row(
        order: 12,
        mcp: "rails_get_concern(name:\"X\", detail:\"full\")",
        cli_args: "name=X detail=full",
        summary: "Concern methods with source + which models include it"
      )

      annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true, open_world_hint: false)

      # Model and controller concerns lead because that is where most apps keep
      # most of them; anything else follows in discovery order.
      SECTION_ORDER = %w[model controller mailer job channel helper].freeze

      def self.call(name: nil, type: "all", detail: "standard", server_context: nil)
        root = rails_app.root.to_s
        max_size = RailsAiContext.configuration.max_file_size

        concern_dirs = resolve_concern_dirs(root, type)

        # The name is refused on its own terms. Deciding this inside the
        # directory loop meant an app with no concern directory answered
        # "not found" for a traversal.
        refused = refuse_name(name, root)
        return refused if refused

        if concern_dirs.empty?
          return text_response("No concern directories found. Searched: #{searched_dirs(type).join(', ')}")
        end

        # Specific concern - full detail
        if name
          return show_concern(name, concern_dirs, root, max_size, detail)
        end

        # List all concerns
        list_concerns(concern_dirs, root)
      end

      private_class_method def self.refuse_name(name, root)
        return nil if name.nil? || name.to_s.empty?

        located = RailsAiContext::SafePath.locate(concern_relative(name), under: root, root: root)
        case located.refusal
        when :traversal then error_response("Path not allowed: #{name}")
        when :sensitive then error_response("Path not allowed: #{name} (sensitive file)")
        end
      end

      private_class_method def self.concern_relative(name)
        "#{name.to_s.underscore}.rb"
      end

      private_class_method def self.resolve_concern_dirs(root, type)
        dirs = ConcernPaths.resolve(root)
        return dirs if type.nil? || type == "all"

        dirs.select { |dir| ConcernPaths.type_for(dir) == type }
      end

      private_class_method def self.searched_dirs(type)
        return [ "app/*/concerns/" ] if type.nil? || type == "all"
        return [ "any configured directory outside app/*/concerns" ] if type == "other"

        [ "app/#{type.pluralize}/concerns/" ]
      end

      private_class_method def self.show_concern(name, concern_dirs, root, max_size, detail = "standard")
        if name.nil? || name.to_s.empty?
          return text_response("The `name` parameter is required.")
        end

        relative = concern_relative(name)
        file_path = nil
        relative_path = nil
        concern_type = nil

        concern_dirs.each do |dir|
          located = RailsAiContext::SafePath.locate(relative, under: dir, root: root, max_size: max_size)
          case located.refusal
          when :too_large
            return text_response("Concern file too large: #{located.realpath} (#{File.size(located.realpath)} bytes, max: #{max_size})")
          when :sensitive then return error_response("Path not allowed: #{name} (sensitive file)")
          when :missing, :outside then next
          end

          file_path = located.realpath
          relative_path = located.relative
          concern_type = ConcernPaths.type_for(dir)
          break
        end

        unless file_path
          # Build available list for fuzzy match
          available = collect_concern_names(concern_dirs, File.realpath(root).to_s)
          return not_found_response("Concern", name, available,
            recovery_tool: "Call rails_get_concern() to see all concerns")
        end

        source = RailsAiContext::SafeFile.read(file_path)
        return text_response("Could not read concern file: #{file_path}") unless source
        lines = [ "# #{name}", "" ]
        lines << "**File:** `#{relative_path}` (#{count_phrase(source.lines.size, "line")})"
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
        public_methods = Introspectors::ActionResolver.public_methods_from_source(source)
        if public_methods.any?
          lines << "" << "## Public Methods"
          if RailsAiContext::DetailLevel.full?(detail)
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
        class_methods = Introspectors::ActionResolver.class_methods_from_source(source)
        if class_methods.any?
          lines << "" << "## Class Methods"
          if RailsAiContext::DetailLevel.full?(detail)
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
          lines << "" << "_Nothing in #{includer_locations(concern_type)} includes this concern._"
        end

        # Cross-reference hints
        lines << ""
        case concern_type
        when "model"
          lines << "_Next: `rails_get_model_details(model:\"ModelName\")` for models using this concern_"
        when "controller"
          lines << "_Next: `rails_get_controllers(controller:\"ControllerName\")` for controllers using this concern_"
        else
          lines << "_Next: `rails_search_code(pattern:\"include #{name.demodulize.camelize}\")` for everything using this concern_"
        end

        text_response(lines.join("\n"))
      end

      private_class_method def self.list_concerns(concern_dirs, root)
        all_concerns = []
        excluded_count = 0
        real_root = File.realpath(root).to_s

        concern_dirs.each do |dir|
          concern_type = ConcernPaths.type_for(dir)
          real_dir = File.realpath(dir).to_s
          safe_glob(dir, "**/*.rb", real_root).sort.each do |real|
            relative = real.sub("#{real_root}/", "")
            concern_name = real.sub("#{real_dir}/", "").sub(/\.rb$/, "").camelize
            if ConcernMembership.excluded?(concern_name)
              excluded_count += 1
              next
            end

            method_count = 0
            source = RailsAiContext::SafeFile.read(real)
            if source
              public_methods = Introspectors::ActionResolver.public_methods_from_source(source)
              class_methods = Introspectors::ActionResolver.class_methods_from_source(source)
              method_count = public_methods.size + class_methods.size
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
          dirs = concern_dirs.map { |d| d.sub("#{root}/", "") }.join(", ")
          if excluded_count > 0
            return text_response("No concerns to list in #{dirs}: " \
              "#{count_phrase(excluded_count, "concern")} hidden by `excluded_concerns`.")
          end

          return text_response("No concerns found in #{dirs}.")
        end

        lines = [ "# Concerns (#{all_concerns.size})", "" ]
        if excluded_count > 0
          lines << "_#{count_phrase(excluded_count, "concern")} hidden by `excluded_concerns`._"
          lines << ""
        end

        # Grouped by whatever types the app actually has. Rendering a fixed
        # pair of sections meant a concern outside them counted toward the
        # total and then appeared nowhere, which is a worse answer than the
        # undercount it replaced.
        # Name breaks the tie: `sort_by` is not stable, so two types outside
        # SECTION_ORDER would otherwise swap places between runs.
        all_concerns.group_by { |c| c[:type] }
                    .sort_by { |type, _| [ SECTION_ORDER.index(type) || SECTION_ORDER.size, type ] }
                    .each do |type, concerns|
          lines << "## #{type.camelize} Concerns (#{concerns.size})"
          concerns.each do |c|
            lines << "- **#{c[:name]}** - #{count_phrase(c[:method_count], "method")} (`#{c[:path]}`)"
          end
          lines << ""
        end

        lines << "_Use `name:\"ConcernName\"` for full detail including method signatures and includers._"
        text_response(lines.join("\n"))
      end

      private_class_method def self.collect_concern_names(concern_dirs, real_root)
        concern_dirs.flat_map do |dir|
          real_dir = File.realpath(dir).to_s
          safe_glob(dir, "**/*.rb", real_root).map do |real|
            real.delete_prefix("#{real_dir}/").sub(/\.rb$/, "").camelize
          end
        end.sort
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

      # The listener knows every callback macro Rails has, so the section no
      # longer spells its own list and drops the ones it forgot. One
      # declaration resolves to one record per `on:` event, so the rendered
      # lines are deduped back down to the lines the file holds.
      private_class_method def self.parse_concern_callbacks(source)
        Introspectors::SourceIntrospector
          .walk_source(source, { callbacks: Introspectors::Listeners::CallbacksListener })[:callbacks]
          .map { |cb| callback_declaration(cb) }
          .uniq
      rescue => e
        $stderr.puts "[rails-ai-context] parse_concern_callbacks failed: #{e.message}" if ENV["DEBUG"]
        []
      end

      # Names the directories find_includers actually searched, so the empty
      # answer says where it looked rather than naming two it may not have.
      private_class_method def self.includer_locations(concern_type)
        return "app/models or app/controllers" if concern_type.nil? || concern_type == "other"
        "app/#{concern_type.pluralize}"
      end

      private_class_method def self.find_includers(concern_name, root, concern_type)
        includers = []
        search_dirs = []

        # The type names the directory that holds the includers: a mailer
        # concern is included by mailers. Only a concern from outside
        # app/*/concerns has no directory to name, so that one searches both
        # of the places a concern is usually included from.
        if concern_type.nil? || concern_type == "other"
          search_dirs.concat(PathResolver.dirs_for(root, "app/models"))
          search_dirs.concat(PathResolver.dirs_for(root, "app/controllers"))
        else
          search_dirs.concat(PathResolver.dirs_for(root, "app/#{concern_type.pluralize}"))
        end

        # Build pattern: match `include ConcernName` or `include ModuleName::ConcernName`
        # Handle both simple and namespaced concern names.
        # Use `camelize` (not `classify`) - `classify` singularizes, which drops
        # the final `s` from plural concern names like `WorksheetImports` and
        # then fails to match `include WorksheetImports` in the model.
        simple_name = concern_name.demodulize.camelize
        pattern = /^\s*include\s+(?:\w+::)*#{Regexp.escape(simple_name)}\b/

        real_root = File.realpath(root).to_s
        search_dirs.each do |dir|
          safe_glob(dir, "**/*.rb", real_root).each do |file_path|
            # Skip concern files themselves
            next if file_path.include?("/concerns/")

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
