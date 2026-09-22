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
          detail: RailsAiContext::DetailLevel.schema("Detail level. summary: names only. standard: names + method signatures + line counts (default). full: everything including side effects, error handling, and callers.")
        }
      )

      guide_row(
        order: 15,
        mcp: "rails_get_service_pattern",
        summary: "Service objects: interface, dependencies, side effects, callers"
      )

      annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true, open_world_hint: false)

      def self.call(service: nil, detail: "standard", server_context: nil)
        root = rails_app.root.to_s
        service_dirs = PathResolver.dirs_for(root, "app/services")

        if service_dirs.empty?
          return text_response("No app/services/ directory found. This app may not use the service objects pattern.")
        end

        real_root = File.realpath(root).to_s
        real_service_dirs = service_dirs.map { |d| File.realpath(d).to_s }

        service_files = service_dirs.flat_map { |d| safe_glob(d, "**/*.rb", real_root) }.uniq.sort
        if service_files.empty?
          return text_response("app/services/ directory exists but contains no Ruby files.")
        end

        if service
          return format_single_service(service, service_files, real_service_dirs, real_root)
        end

        format_service_listing(service_files, real_service_dirs, real_root, detail)
      end

      # A service lives under app/services, a pack, an in-repo engine or a
      # configured extra path; only its path under whichever one holds it
      # carries the namespace Zeitwerk expects.
      private_class_method def self.relative_under(file, service_dirs)
        dir = service_dirs.find { |d| file.start_with?("#{d}#{File::SEPARATOR}") }
        dir ? file.delete_prefix("#{dir}#{File::SEPARATOR}") : File.basename(file)
      end

      private_class_method def self.format_single_service(service, service_files, service_dirs, root)
        matches = match_service_files(service, service_files, service_dirs)

        if matches.size > 1
          names = matches.map { |f| relative_under(f, service_dirs) }
          return text_response(
            [ "Service '#{service}' matches #{count_phrase(matches.size, 'file')}:", "",
              *names.map { |n| "- `app/services/#{n}`" }, "",
              "_Pass the namespaced name, for example `service:\"#{names.first.delete_suffix('.rb').camelize}\"`._" ].join("\n")
          )
        end

        file = matches.first

        unless file
          available = service_files.map { |f| constant_for(f, service_dirs) }
          return not_found_response("Service", service, available.sort,
            recovery_tool: "Call rails_get_service_pattern(detail:\"summary\") to see all services")
        end

        return text_response("Service file too large to analyze.") if File.size(file) > max_file_size

        source = safe_read(file)
        return text_response("Could not read service file.") unless source

        relative = file.sub("#{root}/", "")
        line_count = source.lines.size
        class_name = service_class_name(source, file, service_dirs)

        lines = [ "# #{class_name}", "" ]
        lines << "**File:** `#{relative}` (#{count_phrase(line_count, "line")})"

        inputs = interaction_inputs(source)
        if inputs.any?
          lines << "" << "## Inputs (ActiveInteraction)"
          inputs.each { |i| lines << "- #{i}" }
        end

        owned = owned_methods(source, constant_for(file, service_dirs))

        # Initialize params
        init_params = extract_initialize_params(owned)
        lines << "**Initialize:** `#{init_params}`" if init_params

        # Public methods
        public_methods = extract_public_methods(owned)
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
        callers = find_callers(class_name, root, file)
        if callers.any?
          lines << "" << "## Called By"
          callers.each { |c| lines << "- `#{c}`" }
        end

        # Cross-reference hints
        lines << "" << "_Next: `rails_search_code(pattern:\"#{class_name}\")` for all references_"

        text_response(lines.join("\n"))
      end

      private_class_method def self.format_service_listing(service_files, service_dirs, root, detail)
        # Detect common pattern across all services
        pattern_stats = { initialize_call: 0, initialize_single_method: 0, class_method_call: 0, result_object: 0, active_interaction: 0, total: 0 }
        service_data = []

        service_files.each do |file|
          source = safe_read(file)
          next unless source

          relative = file.sub("#{root}/", "")
          class_name = service_class_name(source, file, service_dirs)
          line_count = source.lines.size
          owned = owned_methods(source, constant_for(file, service_dirs))
          public_methods = extract_public_methods(owned)
          init_params = extract_initialize_params(owned)

          pattern_stats[:total] += 1
          has_initialize = !init_params.nil?
          pattern_stats[:initialize_call] += 1 if has_initialize && public_methods.any? { |m| m.start_with?("call") }
          pattern_stats[:initialize_single_method] += 1 if has_initialize && public_methods.size == 1
          pattern_stats[:class_method_call] += 1 if owned.any? { |m| m[:scope] == :class && m[:name] == "call" }
          pattern_stats[:result_object] += 1 if source.match?(/Result\.new|OpenStruct\.new|Struct\.new|\.success|\.failure/)
          pattern_stats[:active_interaction] += 1 if active_interaction?(source)

          service_data << {
            file: relative,
            class_name: class_name,
            line_count: line_count,
            public_methods: public_methods,
            init_params: init_params
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
            lines << "- **#{s[:class_name]}** (#{count_phrase(s[:line_count], "line")}) - #{methods_str}"
          end
          lines << "" << "_Use `service:\"Name\"` for dependencies, error handling, and callers._"

        when "full"
          service_data.each do |s|
            lines << "## #{s[:class_name]}"
            lines << "- **File:** `#{s[:file]}` (#{count_phrase(s[:line_count], "line")})"
            methods_str = s[:public_methods].any? ? s[:public_methods].join(", ") : "none"
            lines << "- **Methods:** #{methods_str}"

            lines << "- **Initialize:** `#{s[:init_params]}`" if s[:init_params]

            # Read source for additional detail
            full_path = File.join(root, s[:file])
            source = safe_read(full_path)
            if source
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

      # Zeitwerk requires the constant to match the path, and only the path
      # carries the namespace: `admin/suspend_service.rb` is `Admin::SuspendService`,
      # which no single `class` line in the file spells out.
      private_class_method def self.constant_for(file, service_dirs)
        relative_under(file, service_dirs).delete_suffix(".rb").camelize
      end

      # The name the file's own class or module declares, resolved against the
      # path the way every other static name is. A regex over raw source read
      # the word after "class" in a comment, never matched `module`, and its
      # basename fallback dropped the namespace every nested service carries.
      private_class_method def self.service_class_name(source, file, service_dirs)
        Introspectors::DeclaredConstant.resolve(source, constant_for(file, service_dirs))
      end

      # Exact relative path first. A bare name with no namespace may still
      # match on basename, but `Users::Create` must never answer with
      # `api/v1/addresses/create.rb` just because it sorts first.
      private_class_method def self.match_service_files(service, service_files, service_dirs)
        snake = service.underscore.delete_suffix(".rb")
        relative_of = ->(f) { relative_under(f, service_dirs).delete_suffix(".rb") }

        exact = service_files.select { |f| relative_of.call(f) == snake }
        return exact if exact.any?
        return [] if snake.include?("/")

        service_files.select { |f| relative_of.call(f).split("/").last == snake }
      end

      # ActiveInteraction declares its interface as filter macros rather than
      # an `initialize`, so a service that looks argument-less from its
      # methods alone is documented entirely by these lines.
      INTERACTION_FILTERS = %w[
        array boolean date date_time decimal file float hash integer
        interface object record string symbol time
      ].freeze

      private_class_method def self.active_interaction?(source)
        Introspectors::DeclaredConstant.declarations(source)
          .any? { |d| d.superclass == "ActiveInteraction::Base" }
      end

      private_class_method def self.interaction_inputs(source)
        return [] unless active_interaction?(source)

        walked = Introspectors::SourceIntrospector.walk_source(
          source, { filters: -> { Introspectors::Listeners::GenericMacroListener.new(INTERACTION_FILTERS) } }
        )
        (walked[:filters] || []).flat_map do |record|
          options = record[:option_values] || {}
          suffix = options.any? ? " (#{options.map { |k, v| "#{k}: #{v.nil? ? 'nil' : v}" }.join(', ')})" : ""
          Array(record[:args]).map { |name| "`#{record[:macro]} :#{name}`#{suffix}" }
        end
      end

      # The methods the service class defines itself. Nesting a query builder
      # or a set of condition objects inside the service that uses them is a
      # normal way to organise a large one, and a line scan cannot see that:
      # it reported the nested class's first `def` as the entry point, its
      # constructor as the service's, and a `private` inside it hid the real
      # `call` that followed the nested class's `end`.
      #
      # `expected_constant` comes from the path rather than the source, the way
      # JobIntrospector names its classes - Zeitwerk requires the two to agree,
      # and only the path carries the namespace. A file that does not follow
      # the convention falls back to the shallowest nesting, which is the
      # outermost definition in the file.
      #
      # One walk per file: the interface and the constructor have to resolve
      # the same owner, and a second walk could pick a different one.
      private_class_method def self.owned_methods(source, expected_constant = nil)
        ast = Introspectors::SourceIntrospector.walk_source(
          source, { methods: -> { Introspectors::Listeners::MethodsListener.new(include_initialize: true) } }
        )
        methods = ast[:methods] || []
        return [] if methods.empty?

        owner = primary_owner(methods, expected_constant)
        Introspectors::ActionResolver.own_methods(methods, owner)
      rescue => e
        $stderr.puts "[rails-ai-context] owned_methods AST failed: #{e.message}" if ENV["DEBUG"]
        []
      end

      # A service that defines no constructor answers `.new` with no arguments.
      private_class_method def self.extract_initialize_params(owned)
        ctor = owned.find { |m| m[:name] == "initialize" && m[:scope] == :instance }
        ctor && ctor[:signature]
      end

      # The constructor is reported on its own line, not as part of the
      # interface, which is why it is dropped here rather than at the walk.
      private_class_method def self.extract_public_methods(owned)
        owned.select { |m| m[:visibility] == :public && m[:name] != "initialize" }
             .map { |m| m[:signature] }
      end

      private_class_method def self.primary_owner(methods, expected_constant)
        owners = methods.map { |m| Introspectors::ActionResolver.owner_name(m) }
        return expected_constant if expected_constant && owners.include?(expected_constant)

        owners.min_by { |o| [ o.count(":"), o.length ] }
      end

      private_class_method def self.extract_dependencies(source, own_class_name)
        deps = Set.new

        # Class.new(...) or Class.call(...) or Class.perform_later(...)
        source.scan(/([A-Z][\w:]+)\.(new|call|perform_later|perform_async|perform_now|create|find|where)\b/).each do |match|
          cls = match[0]
          next if cls == own_class_name
          next if %w[Rails ActiveRecord ApplicationRecord File Dir ENV String Integer Float Array Hash Set Time Date DateTime URI Regexp].include?(cls)
          deps << cls
        end

        # Mailers are invoked through their action name (PostMailer.published_email),
        # which the verb whitelist above can't anticipate.
        source.scan(/([A-Z][\w:]*Mailer)\.\w+/).each do |match|
          cls = match[0]
          next if cls == own_class_name || cls == "ActionMailer"
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

      private_class_method def self.find_callers(class_name, real_root, own_file = nil)
        callers = Set.new
        search_dirs = %w[app/controllers app/jobs app/models app/services app/workers app/mailers]
                        .flat_map { |d| PathResolver.dirs_for(real_root, d) }
        # A bare `include?` matched `Billing::Invoices::Create` inside
        # `Workers::Billing::Invoices::CreateOrUpdateSheetWorker`, and the
        # underscored-path skip dropped the one real caller, whose path
        # contains the service's own path as a prefix.
        reference = /(?<![\w:])(?:::)?#{Regexp.escape(class_name)}(?![\w:])/

        search_dirs.each do |dir|
          safe_glob(dir, "**/*.rb", real_root).each do |real|
            next if own_file && real == own_file
            source = safe_read(real)
            next unless source
            next unless source.match?(reference)

            callers << real.sub("#{real_root}/", "")
          end
        end

        callers.to_a.sort.first(20)
      end

      private_class_method def self.detect_common_pattern(stats)
        return nil if stats[:total] == 0

        parts = []
        if stats[:active_interaction].to_i > stats[:total] / 2
          parts << "ActiveInteraction::Base, run with `.run` / `.run!` (#{stats[:active_interaction]}/#{stats[:total]})"
        end
        if stats[:initialize_call] > stats[:total] / 2
          parts << "initialize + #call instance method (#{stats[:initialize_call]}/#{stats[:total]})"
        elsif stats[:initialize_single_method] > stats[:total] / 2
          parts << "initialize + single public method (#{stats[:initialize_single_method]}/#{stats[:total]})"
        end
        if stats[:class_method_call] > stats[:total] / 2
          parts << "self.call class method (#{stats[:class_method_call]}/#{stats[:total]})"
        end
        if stats[:result_object] > stats[:total] / 4
          parts << "Result/value object return (#{stats[:result_object]}/#{stats[:total]})"
        end

        parts.any? ? parts.join(", ") : "mixed/no dominant pattern"
      end
    end
  end
end
