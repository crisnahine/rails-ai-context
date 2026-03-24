# frozen_string_literal: true

module RailsAiContext
  module Tools
    class GetServicePattern < BaseTool
      tool_name "rails_get_service_pattern"
      description "Analyze service objects in app/services/: patterns, interfaces, dependencies, and side effects. " \
        "Use when: understanding how services are structured, adding a new service, or tracing what a service does. " \
        "Specify service:\"CreateOrder\" for full detail, or omit to detect the common pattern and list all services."

      input_schema(
        properties: {
          service: {
            type: "string",
            description: "Service class name or filename (e.g. 'CreateOrder', 'create_order'). Omit to list all services with pattern detection."
          },
          detail: {
            type: "string",
            enum: %w[summary standard full],
            description: "Detail level. summary: names only. standard: names + method signatures + line counts (default). full: everything including side effects, error handling, and callers."
          }
        }
      )

      annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true, open_world_hint: false)

      def self.call(service: nil, detail: "standard", server_context: nil)
        root = Rails.root.to_s
        services_dir = File.join(root, "app", "services")

        unless Dir.exist?(services_dir)
          return text_response("No app/services/ directory found. This app may not use the service objects pattern.")
        end

        service_files = Dir.glob(File.join(services_dir, "**", "*.rb")).sort
        if service_files.empty?
          return text_response("app/services/ directory exists but contains no Ruby files.")
        end

        if service
          return format_single_service(service, service_files, services_dir, root)
        end

        format_service_listing(service_files, services_dir, root, detail)
      end

      private_class_method def self.format_single_service(service, service_files, services_dir, root)
        # Match by class name or filename: "CreateOrder", "create_order", "create_order.rb"
        snake = service.underscore.delete_suffix(".rb")
        file = service_files.find do |f|
          relative = f.sub("#{services_dir}/", "").delete_suffix(".rb")
          relative == snake || relative.split("/").last == snake.split("/").last
        end

        unless file
          available = service_files.map { |f| File.basename(f, ".rb").camelize }
          return not_found_response("Service", service, available.sort,
            recovery_tool: "Call rails_get_service_pattern(detail:\"summary\") to see all services")
        end

        return text_response("Service file too large to analyze.") if File.size(file) > max_file_size

        source = safe_read(file)
        return text_response("Could not read service file.") unless source

        relative = file.sub("#{root}/", "")
        line_count = source.lines.size
        class_name = extract_class_name(source) || File.basename(file, ".rb").camelize

        lines = [ "# #{class_name}", "" ]
        lines << "**File:** `#{relative}` (#{line_count} lines)"

        # Initialize params
        init_params = extract_initialize_params(source)
        lines << "**Initialize:** `#{init_params}`" if init_params

        # Public methods
        public_methods = extract_public_methods(source)
        if public_methods.any?
          lines << "" << "## Public Methods"
          public_methods.each { |m| lines << "- `#{m}`" }
        end

        # What it calls (other classes instantiated or called)
        dependencies = extract_dependencies(source, class_name)
        if dependencies.any?
          lines << "" << "## Dependencies"
          dependencies.each { |d| lines << "- `#{d}`" }
        end

        # Error handling
        rescue_blocks = extract_rescue_blocks(source)
        if rescue_blocks.any?
          lines << "" << "## Error Handling"
          rescue_blocks.each { |r| lines << "- `rescue #{r}`" }
        end

        # Side effects
        side_effects = extract_side_effects(source)
        if side_effects.any?
          lines << "" << "## Side Effects"
          side_effects.each { |s| lines << "- #{s}" }
        end

        # Cross-reference: who calls this service
        callers = find_callers(class_name, root)
        if callers.any?
          lines << "" << "## Called By"
          callers.each { |c| lines << "- `#{c}`" }
        end

        # Cross-reference hints
        lines << "" << "_Next: `rails_search_code(pattern:\"#{class_name}\")` for all references_"

        text_response(lines.join("\n"))
      end

      private_class_method def self.format_service_listing(service_files, services_dir, root, detail)
        # Detect common pattern across all services
        pattern_stats = { initialize_call: 0, class_method_call: 0, result_object: 0, total: 0 }
        service_data = []

        service_files.each do |file|
          next if File.size(file) > max_file_size
          source = safe_read(file)
          next unless source

          relative = file.sub("#{root}/", "")
          class_name = extract_class_name(source) || File.basename(file, ".rb").camelize
          line_count = source.lines.size
          public_methods = extract_public_methods(source)

          pattern_stats[:total] += 1
          pattern_stats[:initialize_call] += 1 if source.match?(/def initialize/) && public_methods.any? { |m| m.start_with?("call") }
          pattern_stats[:class_method_call] += 1 if source.match?(/def self\.call/)
          pattern_stats[:result_object] += 1 if source.match?(/Result\.new|OpenStruct\.new|Struct\.new|\.success|\.failure/)

          service_data << {
            file: relative,
            class_name: class_name,
            line_count: line_count,
            public_methods: public_methods
          }
        end

        total = service_data.size
        lines = [ "# Service Objects (#{total})", "" ]

        # Pattern detection
        detected = detect_common_pattern(pattern_stats)
        lines << "**Common pattern:** #{detected}" if detected
        lines << ""

        case detail
        when "summary"
          service_data.each { |s| lines << "- #{s[:class_name]}" }
          lines << "" << "_Use `service:\"Name\"` for full detail, or `detail:\"standard\"` for method signatures._"

        when "standard"
          service_data.each do |s|
            methods_str = s[:public_methods].any? ? s[:public_methods].join(", ") : "none"
            lines << "- **#{s[:class_name]}** (#{s[:line_count]} lines) — #{methods_str}"
          end
          lines << "" << "_Use `service:\"Name\"` for dependencies, error handling, and callers._"

        when "full"
          service_data.each do |s|
            lines << "## #{s[:class_name]}"
            lines << "- **File:** `#{s[:file]}` (#{s[:line_count]} lines)"
            methods_str = s[:public_methods].any? ? s[:public_methods].join(", ") : "none"
            lines << "- **Methods:** #{methods_str}"

            # Read source for additional detail
            full_path = File.join(root, s[:file])
            source = safe_read(full_path)
            if source
              init_params = extract_initialize_params(source)
              lines << "- **Initialize:** `#{init_params}`" if init_params

              side_effects = extract_side_effects(source)
              lines << "- **Side effects:** #{side_effects.join(', ')}" if side_effects.any?

              rescue_blocks = extract_rescue_blocks(source)
              lines << "- **Rescues:** #{rescue_blocks.join(', ')}" if rescue_blocks.any?
            end
            lines << ""
          end
          lines << "_Use `service:\"Name\"` to see callers and cross-references._"
        end

        text_response(lines.join("\n"))
      end

      private_class_method def self.extract_class_name(source)
        match = source.match(/class\s+([\w:]+)/)
        match[1] if match
      end

      private_class_method def self.extract_initialize_params(source)
        match = source.match(/def initialize\(([^)]*)\)/m)
        return nil unless match
        "initialize(#{match[1].strip})"
      end

      private_class_method def self.extract_public_methods(source)
        methods = []
        in_private = false

        source.each_line do |line|
          in_private = true if line.match?(/\A\s*(private|protected)\s*$/)
          in_private = false if line.match?(/\A\s*public\s*$/)
          next if in_private

          if (match = line.match(/\A\s*def\s+((?:self\.)?[\w?!]+(?:\([^)]*\))?)/))
            sig = match[1]
            next if sig.start_with?("initialize")
            methods << sig
          end
        end

        methods
      end

      private_class_method def self.extract_dependencies(source, own_class_name)
        deps = Set.new

        # Class.new(...) or Class.call(...) or Class.perform_later(...)
        source.scan(/([A-Z][\w:]+)\.(new|call|perform_later|perform_async|create|find|where)\b/).each do |match|
          cls = match[0]
          next if cls == own_class_name
          next if %w[Rails ActiveRecord ApplicationRecord File Dir ENV String Integer Float Array Hash Set Time Date DateTime URI Regexp].include?(cls)
          deps << cls
        end

        # Explicit require or include
        source.scan(/(?:include|prepend)\s+([\w:]+)/).each do |match|
          deps << match[0]
        end

        deps.to_a.sort
      end

      private_class_method def self.extract_rescue_blocks(source)
        rescues = Set.new
        source.scan(/rescue\s+([\w:]+(?:\s*,\s*[\w:]+)*)/).each do |match|
          match[0].split(",").each { |r| rescues << r.strip }
        end
        # Also detect bare rescue
        rescues << "StandardError (implicit)" if source.match?(/rescue\s*$/) || source.match?(/rescue\s*=>/)
        rescues.to_a.sort
      end

      private_class_method def self.extract_side_effects(source)
        effects = Set.new

        effects << "database write (save!)" if source.match?(/\.save!/)
        effects << "database write (save)" if source.match?(/\.save\b/) && !source.match?(/\.save!/)
        effects << "database write (update!)" if source.match?(/\.update!/)
        effects << "database write (update)" if source.match?(/\.update\b/) && !source.match?(/\.update!/)
        effects << "database write (create!)" if source.match?(/\.create!/)
        effects << "database write (create)" if source.match?(/\.create\b/) && !source.match?(/\.create!/)
        effects << "database write (destroy)" if source.match?(/\.destroy[!]?/)
        effects << "database write (delete)" if source.match?(/\.delete\b/)
        effects << "email delivery (deliver)" if source.match?(/\.deliver_later|\.deliver_now/)
        effects << "job enqueue" if source.match?(/\.perform_later|\.perform_async/)
        effects << "Turbo broadcast" if source.match?(/broadcast_|Turbo::StreamsChannel/)
        effects << "HTTP request" if source.match?(/Faraday|Net::HTTP|HTTParty|RestClient|\.post\(|\.get\(/)
        effects << "file write" if source.match?(/File\.write|File\.open.*["']w/)
        effects << "cache write" if source.match?(/Rails\.cache\.write|Rails\.cache\.fetch/)
        effects << "transaction" if source.match?(/\.transaction\b/)
        effects << "logging" if source.match?(/Rails\.logger|logger\./)

        effects.to_a.sort
      end

      private_class_method def self.find_callers(class_name, root)
        callers = Set.new
        search_dirs = %w[app/controllers app/jobs app/models app/services app/workers app/mailers].map { |d| File.join(root, d) }

        search_dirs.each do |dir|
          next unless Dir.exist?(dir)
          Dir.glob(File.join(dir, "**", "*.rb")).each do |file|
            next if File.size(file) > max_file_size
            source = safe_read(file)
            next unless source
            next unless source.include?(class_name)

            relative = file.sub("#{root}/", "")
            # Skip the service's own file
            next if relative.include?(class_name.underscore)

            callers << relative
          end
        end

        callers.to_a.sort.first(20)
      end

      private_class_method def self.detect_common_pattern(stats)
        return nil if stats[:total] == 0

        parts = []
        if stats[:initialize_call] > stats[:total] / 2
          parts << "initialize + call instance method (#{stats[:initialize_call]}/#{stats[:total]})"
        end
        if stats[:class_method_call] > stats[:total] / 2
          parts << "self.call class method (#{stats[:class_method_call]}/#{stats[:total]})"
        end
        if stats[:result_object] > stats[:total] / 4
          parts << "Result/value object return (#{stats[:result_object]}/#{stats[:total]})"
        end

        parts.any? ? parts.join(", ") : "mixed/no dominant pattern"
      end

      private_class_method def self.safe_read(path)
        File.read(path, encoding: "UTF-8", invalid: :replace, undef: :replace)
      rescue
        nil
      end

      private_class_method def self.max_file_size
        RailsAiContext.configuration.max_file_size
      end
    end
  end
end
