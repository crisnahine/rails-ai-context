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
          return text_response("No services directory found. Searched app/services/, packs/*/app/services/ and engines/*/app/services/. " \
            "This app may not use the service objects pattern.")
        end

        real_root = File.realpath(root).to_s
        real_service_dirs = service_dirs.map { |d| File.realpath(d).to_s }

        service_files = service_dirs.flat_map { |d| safe_glob(d, "**/*.rb", real_root) }.uniq.sort
        if service_files.empty?
          return text_response("A services directory exists but contains no Ruby files.")
        end

        # One lookup for the whole call: it walks the service tree on first
        # use and only a class whose superclass is not ActiveInteraction::Base
        # ever asks it anything.
        lookup = Introspectors::Interaction.lookup_for(root)

        if service
          return format_single_service(service, service_files, real_service_dirs, real_root, lookup)
        end

        format_service_listing(service_files, real_service_dirs, real_root, detail, lookup)
      end

      # A service lives under app/services, a pack, an in-repo engine or a
      # configured extra path; only its path under whichever one holds it
      # carries the namespace Zeitwerk expects.
      private_class_method def self.relative_under(file, service_dirs)
        dir = service_dirs.find { |d| file.start_with?("#{d}#{File::SEPARATOR}") }
        dir ? file.delete_prefix("#{dir}#{File::SEPARATOR}") : File.basename(file)
      end

      private_class_method def self.format_single_service(service, service_files, service_dirs, root, lookup = nil)
        matches = match_service_files(service, service_files, service_dirs)

        if matches.size > 1
          # Paths are printed from the app root, not re-prefixed with
          # `app/services/`: a pack or engine service carries the same relative
          # path, and the re-prefixed line names a file that exists in neither.
          names = matches.map { |f| relative_under(f, service_dirs).delete_suffix(".rb") }
          counts = names.tally
          unambiguous = names.find { |n| counts[n] == 1 }
          hint = if unambiguous
            "_Pass the namespaced name, for example `service:\"#{unambiguous.camelize}\"`._"
          elsif counts.size == 1
            "_These sit at the same relative path under different roots, so they declare the same `#{names.first.camelize}`. Open the path you want directly._"
          else
            # No name is unique, but several distinct ones are here: narrowing
            # shortens the list without ever reaching a single file.
            constants = counts.keys.map { |n| "`#{n.camelize}`" }.join(", ")
            "_Each of #{constants} sits under more than one root. Pass one to narrow the list, then open the path you want directly._"
          end

          return text_response(
            [ "Service '#{service}' matches #{count_phrase(matches.size, 'file')}:", "",
              *matches.map { |f| "- `#{f.sub("#{root}/", "")}`" }, "",
              hint ].join("\n")
          )
        end

        file = matches.first

        unless file
          available = service_files.map { |f| constant_for(f, service_dirs) }.uniq
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

        inputs = interaction_inputs(source, lookup, class_name)
        if inputs.any?
          lines << "" << "## Inputs (ActiveInteraction)"
          lines.concat(inputs)
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
        callers, scan_truncated = find_callers(class_name, root, file)
        if callers.any?
          lines << "" << "## Called By"
          callers.first(CALLER_LIMIT).each { |c| lines << "- `#{c}`" }
          if callers.size > CALLER_LIMIT
            lines << "_#{callers.size} callers in all; the #{CALLER_LIMIT} listed are the first by path._"
          end
        end
        if scan_truncated
          lines << "" << "_The caller scan stopped after #{count_phrase(MAX_CALLER_SCAN_FILES, "file")}; " \
                        "run `rails_search_code(pattern:\"#{class_name}\")` for the rest._"
        end

        # Cross-reference hints
        lines << "" << "_Next: `rails_search_code(pattern:\"#{class_name}\")` for all references_"

        text_response(lines.join("\n"))
      end

      private_class_method def self.format_service_listing(service_files, service_dirs, root, detail, lookup = nil)
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
          pattern_stats[:active_interaction] += 1 if Introspectors::Interaction.interaction?(source, lookup: lookup)

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
      #
      # app/services/concerns is its own autoload root (railties globs
      # "{*,*/concerns}"), so concerns/payloadable.rb defines Payloadable, not
      # Concerns::Payloadable, and an agent told to include the latter writes a
      # NameError.
      private_class_method def self.constant_for(file, service_dirs)
        relative_under(file, service_dirs).delete_prefix("concerns/").delete_suffix(".rb").camelize
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
      # One line per filter, nested filters indented under the filter whose
      # block declares them, and an inherited one named with the class that
      # declares it: it is not in this file, and a reader looking for it
      # needs somewhere to look.
      private_class_method def self.interaction_inputs(source, lookup = nil, own_class = nil)
        Introspectors::Interaction.filters(source, lookup: lookup).flat_map do |filter|
          [ "- #{input_line(filter, own_class)}" ] +
            filter.nested.map { |nested| "  - #{input_line(nested, filter.declared_by)}" }
        end
      end

      private_class_method def self.input_line(filter, own_class)
        options = filter.options || {}
        suffix = options.any? ? " (#{options.map { |k, v| "#{k}: #{v.nil? ? 'nil' : v}" }.join(', ')})" : ""
        origin = own_class && filter.declared_by != own_class ? " - from `#{filter.declared_by}`" : ""
        "`#{filter.macro} :#{filter.name}`#{suffix}#{origin}"
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
        RailsAiContext.debug_fail(e, [], label: "owned_methods AST")
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

      # Every caller is capped at CALLER_LIMIT, and the renderer says so: a
      # list that stops at twenty with no word looks complete. The scan reads
      # every file under app/ and lib/ rather than six named directories,
      # which is the only way to see a caller in app/tools or lib/ - the cost
      # is one pass over the tree per named service.
      CALLER_LIMIT = 20

      # The scan is raw file reading with no cache behind it, so on a monorepo
      # it is the most expensive thing this tool does. It stops here and says
      # so, the way analyze_feature states its own scan cap.
      MAX_CALLER_SCAN_FILES = 5_000

      private_class_method def self.find_callers(class_name, real_root, own_file = nil)
        callers = Set.new
        search_dirs = %w[app lib].flat_map { |d| PathResolver.dirs_for(real_root, d) }
        # A bare `include?` matched `Billing::Invoices::Create` inside
        # `Workers::Billing::Invoices::CreateOrUpdateSheetWorker`, and the
        # underscored-path skip dropped the one real caller, whose path
        # contains the service's own path as a prefix.
        reference = /(?<![\w:])(?:::)?#{Regexp.escape(class_name)}(?![\w:])/
        # A second file declaring the same short name under its own namespace
        # is not a caller of this one, so the declaration is not a reference.
        definition = /\b(?:class|module)\s+(?:::)?#{Regexp.escape(class_name)}(?![\w:])/

        # The paths first, so the ceiling is measured against the files there
        # are rather than against the files read: a tree of exactly the cap
        # skipped nothing and used to say it stopped.
        paths = search_dirs.flat_map { |dir| safe_glob(dir, "**/*.rb", real_root) }
        paths.reject! { |real| real == own_file } if own_file
        truncated = paths.size > MAX_CALLER_SCAN_FILES

        paths.first(MAX_CALLER_SCAN_FILES).each do |real|
          source = safe_read(real)
          next unless source
          next unless source.match?(reference)
          next unless source.gsub(definition, "").match?(reference)

          callers << real.sub("#{real_root}/", "")
        end

        [ callers.to_a.sort, truncated ]
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
