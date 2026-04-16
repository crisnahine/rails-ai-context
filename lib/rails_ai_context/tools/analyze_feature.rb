# frozen_string_literal: true

module RailsAiContext
  module Tools
    class AnalyzeFeature < BaseTool
      tool_name "rails_analyze_feature"
      description "Full-stack feature analysis: models, controllers, routes, services, jobs, views, " \
        "Stimulus controllers, tests, related models, callbacks, concerns, and environment dependencies. " \
        "Use when: exploring an unfamiliar feature, onboarding to a codebase area, or tracing a feature across layers. " \
        "Pass feature:\"authentication\" or feature:\"User\" for broad cross-cutting discovery."

      input_schema(
        properties: {
          feature: {
            type: "string",
            description: "Feature keyword to search for (e.g. 'authentication', 'User', 'payments', 'orders'). Case-insensitive partial match across all layers."
          }
        },
        required: [ "feature" ]
      )

      annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true, open_world_hint: false)

      # Map well-known feature keywords to gem-based patterns
      AUTH_KEYWORDS = %w[auth authentication login signup signin session devise omniauth].freeze

      # Cap per-directory file scans to avoid unbounded work on large monorepos.
      # Note: Dir.glob materialises the full path array before .first() truncates —
      # the directory walk itself is unbounded; only per-file reading and processing
      # is capped at MAX_SCAN_FILES. Applied to every discover_* method that walks
      # the filesystem. Tool output notes when the cap is hit so the AI agent knows
      # to narrow its feature keyword. v5.8.1 hardening; all glob sites in r2.
      MAX_SCAN_FILES = 500
      AUTH_GEM_NAMES = %w[devise omniauth rodauth sorcery clearance authlogic warden jwt].freeze

      def self.call(feature:, server_context: nil) # rubocop:disable Metrics
        feature = feature.to_s.strip
        return text_response("Please provide a feature keyword (e.g. 'post', 'payment', 'authentication').") if feature.empty?
        set_call_params(feature: feature)

        ctx = cached_context
        pattern = feature.downcase
        root = rails_app.root.to_s
        lines = [ "# Feature Analysis: #{feature}", "" ]

        matched_models = discover_models(ctx, pattern, lines)
        discover_controllers(ctx, pattern, lines)
        discover_routes(ctx, pattern, lines)
        discover_services(root, pattern, lines)
        discover_jobs(root, pattern, lines)
        discover_views(ctx, root, pattern, lines)
        discover_stimulus(ctx, pattern, lines)
        test_files = discover_tests(root, pattern, lines)
        discover_related_models(ctx, matched_models, lines)
        discover_concerns(ctx, matched_models, lines)
        discover_callbacks(ctx, matched_models, lines)
        discover_channels(root, pattern, lines)
        discover_mailers(root, pattern, lines)
        discover_env_dependencies(root, pattern, matched_models, lines)
        discover_test_gaps(root, pattern, matched_models, ctx, test_files || [], lines)
        discover_components(ctx, pattern, lines)

        # For auth-related keywords, also discover auth gems
        if AUTH_KEYWORDS.include?(pattern)
          gems = ctx[:gems]
          if gems.is_a?(Hash) && !gems[:error]
            notable = gems[:notable_gems] || []
            auth_gems = notable.select { |g| AUTH_GEM_NAMES.include?(g[:name]) }
            if auth_gems.any?
              lines << "" << "## Auth Gems" << ""
              auth_gems.each { |g| lines << "- **#{g[:name]}** #{g[:version]}#{g[:config] ? " (config: #{g[:config]})" : ""}" }
            end
          end
        end

        # If nothing was discovered, return a clean "no match" with real suggestions
        has_content = lines.any? { |l| l.start_with?("## ") || l.start_with?("### ") }
        unless has_content
          model_names = (ctx[:models] || {}).keys.map(&:to_s).sort.first(10)
          suggestions = model_names.any? ? model_names.join(", ") : "user, payment, order"
          return text_response("No matches found for '#{feature}'. No models, controllers, routes, services, or views match this keyword.\n\nTry one of your model names: #{suggestions}")
        end

        text_response(lines.join("\n"))
      end

      class << self
        private

        # --- AF: Models ---
        def discover_models(ctx, pattern, lines)
          models = ctx[:models] || {}

          # For auth-related keywords, also match the User model and auth-related concerns
          extra_auth_match = AUTH_KEYWORDS.include?(pattern)

          matched = models.select do |name, data|
            next false if data[:error]
            name.downcase.include?(pattern) ||
              data[:table_name]&.downcase&.include?(pattern) ||
              name.underscore.include?(pattern) ||
              (extra_auth_match && (name == "User" || data[:concerns]&.any? { |c| c.to_s.downcase.match?(/authenticat|devise/) }))
          end

          if matched.any?
            lines << "## Models (#{matched.size})"
            matched.sort.each do |name, data|
              lines << "" << "### #{name}"
              lines << "**Table:** `#{data[:table_name]}`" if data[:table_name]

              table_name = data[:table_name]
              if table_name && (tables = ctx.dig(:schema, :tables))
                table_data = tables[table_name]
                if table_data&.dig(:columns)&.any?
                  cols = table_data[:columns].reject { |c| %w[id created_at updated_at].include?(c[:name]) }
                  col_strs = cols.map { |c| col_type = c[:array] ? "#{c[:type]}[]" : c[:type]; "#{c[:name]}:#{col_type}" }
                  lines << "**Columns:** #{col_strs.join(', ')}" if cols.any?
                end
              end

              if data[:associations].is_a?(Array) && data[:associations].any?
                lines << "**Associations:** #{data[:associations].select { |a| a.is_a?(Hash) }.map { |a| "#{a[:type]} :#{a[:name]}" }.join(', ')}"
              end
              if data[:validations].is_a?(Array) && data[:validations].any?
                lines << "**Validations:** #{data[:validations].select { |v| v.is_a?(Hash) }.map { |v| "#{v[:kind]} on #{Array(v[:attributes]).join(', ')}" }.uniq.join('; ')}"
              end
              if data[:scopes].is_a?(Array) && data[:scopes].any?
                scope_strs = data[:scopes].map { |s| s.is_a?(Hash) ? s[:name] : s.to_s }
                lines << "**Scopes:** #{scope_strs.join(', ')}"
              end
              if data[:enums].is_a?(Hash) && data[:enums].any?
                enum_strs = data[:enums].map do |k, v|
                  v.is_a?(Hash) ? "#{k}: #{v.keys.join(', ')}" : "#{k}: #{Array(v).join(', ')}"
                end
                lines << "**Enums:** #{enum_strs.join('; ')}"
              end
            end
          end

          lines << ""
          matched
        end

        # --- AF: Controllers ---
        def discover_controllers(ctx, pattern, lines)
          controllers = ctx.dig(:controllers, :controllers) || {}
          matched = controllers.select { |name, data| data.is_a?(Hash) && !data[:error] && name.downcase.include?(pattern) }

          if matched.any?
            lines << "## Controllers (#{matched.size})"
            matched.sort.each do |name, info|
              actions = info[:actions]&.join(", ") || "none"
              lines << "" << "### #{name}"
              lines << "- **Actions:** #{actions}"

              # Inherited filters from parent controller
              parent_filters = detect_parent_filters_for_analyze(info[:parent_class], controllers)
              if parent_filters.any?
                lines << "- **Inherited filters:** #{parent_filters.map { |f| "#{f[:name]} _(from #{info[:parent_class]})_" }.join(', ')}"
              end

              filters = (info[:filters] || []).select { |f| f.is_a?(Hash) }.map do |f|
                label = "#{f[:kind]} #{f[:name]}"
                label += " only: #{Array(f[:only]).join(', ')}" if f[:only]&.any?
                label += " except: #{Array(f[:except]).join(', ')}" if f[:except]&.any?
                label
              end
              lines << "- **Filters:** #{filters.join('; ')}" if filters.any?
            end
          end
          lines << ""
        end

        # --- AF: Routes ---
        def discover_routes(ctx, pattern, lines)
          by_controller = ctx.dig(:routes, :by_controller) || {}
          matched = by_controller.select { |ctrl, _| ctrl.downcase.include?(pattern) }

          if matched.any?
            route_count = matched.values.sum(&:size)
            lines << "## Routes (#{route_count})"
            matched.sort.each do |ctrl, actions|
              actions.each do |r|
                params = r[:path].scan(/:(\w+)/).flatten
                helper = if r[:name]
                  args = params.any? ? "(#{params.map { |p| p == "id" ? "@record" : ":#{p}" }.join(', ')})" : ""
                  " `#{r[:name]}_path#{args}`"
                else
                  ""
                end
                lines << "- `#{r[:verb]}` `#{r[:path]}` → #{ctrl}##{r[:action]}#{helper}"
              end
            end
          end
          lines << ""
        end

        # --- AF1: Services ---
        def discover_services(root, pattern, lines)
          dir = File.join(root, "app", "services")
          return unless Dir.exist?(dir)

          candidates = Dir.glob(File.join(dir, "**", "*.rb")).first(MAX_SCAN_FILES)
          # Prefer basename match (fast, no file read) and only fall back to
          # a content scan for files whose basename doesn't match. This
          # avoids reading every service file's full contents on large apps.
          found = candidates.select do |path|
            next true if File.basename(path, ".rb").include?(pattern)
            File.size(path) < 50_000 && (RailsAiContext::SafeFile.read(path) || "").downcase.include?(pattern)
          end
          return if found.empty?

          lines << "## Services (#{found.size}#{candidates.size == MAX_SCAN_FILES ? " — first #{MAX_SCAN_FILES} scanned" : ""})"
          found.each do |path|
            relative = path.sub("#{root}/", "")
            source = RailsAiContext::SafeFile.read(path) or next
            line_count = source.lines.size
            methods = source.scan(/^\s*def (?:self\.)?(\w+)/m).flatten.reject { |m| m == "initialize" }
            lines << "- `#{relative}` (#{line_count} lines)"
            lines << "  Methods: #{methods.first(20).join(', ')}" if methods.any?
          end
          lines << ""
        rescue => e
          $stderr.puts "[rails-ai-context] discover_services failed: #{e.message}" if ENV["DEBUG"]
          nil
        end

        # --- AF2: Jobs ---
        def discover_jobs(root, pattern, lines)
          dir = File.join(root, "app", "jobs")
          return unless Dir.exist?(dir)

          candidates = Dir.glob(File.join(dir, "**", "*.rb")).first(MAX_SCAN_FILES)
          found = candidates.select do |path|
            File.basename(path, ".rb").include?(pattern)
          end
          return if found.empty?

          lines << "## Jobs (#{found.size}#{candidates.size == MAX_SCAN_FILES ? " — first #{MAX_SCAN_FILES} scanned" : ""})"
          found.each do |path|
            relative = path.sub("#{root}/", "")
            source = RailsAiContext::SafeFile.read(path) or next
            queue = source.match(/queue_as\s+[:'"](\w+)/)&.captures&.first || "default"
            retries = source.match(/retry_on.*attempts:\s*(\d+)/)&.captures&.first
            lines << "- `#{relative}` (queue: #{queue}#{retries ? ", retries: #{retries}" : ""})"
          end
          lines << ""
        rescue => e
          $stderr.puts "[rails-ai-context] discover_jobs failed: #{e.message}" if ENV["DEBUG"]
          nil
        end

        # --- AF3: Views + Partials ---
        def discover_views(ctx, root, pattern, lines)
          views_dir = File.join(root, "app", "views")
          return unless Dir.exist?(views_dir)

          candidates = Dir.glob(File.join(views_dir, "**", "*.{erb,haml,slim}")).first(MAX_SCAN_FILES)
          found = candidates.select do |path|
            path.sub("#{views_dir}/", "").downcase.include?(pattern)
          end
          return if found.empty?

          lines << "## Views (#{found.size}#{candidates.size == MAX_SCAN_FILES ? " — first #{MAX_SCAN_FILES} scanned" : ""})"
          found.each do |path|
            relative = path.sub("#{views_dir}/", "")
            source = RailsAiContext::SafeFile.read(path) or next
            line_count = source.lines.size
            partials = source.scan(/render\s+(?:partial:\s*)?["']([^"']+)["']/).flatten
            stimulus = source.scan(/data-controller=["']([^"']+)["']/).flat_map { |m| m.first.split }
            detail = "- `#{relative}` (#{line_count} lines)"
            detail += " renders: #{partials.join(', ')}" if partials.any?
            detail += " stimulus: #{stimulus.join(', ')}" if stimulus.any?
            lines << detail
          end
          lines << ""
        rescue => e
          $stderr.puts "[rails-ai-context] discover_views failed: #{e.message}" if ENV["DEBUG"]
          nil
        end

        # --- AF4: Stimulus Controllers ---
        def discover_stimulus(ctx, pattern, lines)
          stim = ctx[:stimulus]
          return unless stim.is_a?(Hash) && !stim[:error]

          controllers = stim[:controllers] || []
          matched = controllers.select do |c|
            name = c[:name] || c[:file]&.gsub("_controller.js", "")
            name&.downcase&.include?(pattern)
          end
          return if matched.empty?

          lines << "## Stimulus Controllers (#{matched.size})"
          matched.each do |c|
            name = c[:name] || c[:file]&.gsub("_controller.js", "")
            lines << "" << "### #{name}"
            lines << "- **Targets:** #{Array(c[:targets]).join(', ')}" if c[:targets]&.any?
            if c[:values]&.any?
              val_strs = if c[:values].is_a?(Array)
                c[:values].select { |v| v.is_a?(Hash) }.map { |v| "#{v[:name]}:#{v[:type]}" }
              elsif c[:values].is_a?(Hash)
                c[:values].map { |k, v| "#{k}:#{v}" }
              else
                []
              end
              lines << "- **Values:** #{val_strs.join(', ')}" if val_strs.any?
            end
            lines << "- **Actions:** #{Array(c[:actions]).join(', ')}" if c[:actions]&.any?
          end
          lines << ""
        end

        # --- AF5: Tests ---
        def discover_tests(root, pattern, lines)
          test_dirs = [ File.join(root, "spec"), File.join(root, "test") ]
          found = []
          truncated = false

          test_dirs.each do |dir|
            next unless Dir.exist?(dir)
            suffix_glob = Dir.glob(File.join(dir, "**", "*_{test,spec}.rb")).first(MAX_SCAN_FILES)
            truncated = true if suffix_glob.size == MAX_SCAN_FILES
            suffix_glob.each do |path|
              found << path if File.basename(path, ".rb").include?(pattern)
            end
            prefix_glob = Dir.glob(File.join(dir, "**", "{test,spec}_*.rb")).first(MAX_SCAN_FILES)
            truncated = true if prefix_glob.size == MAX_SCAN_FILES
            prefix_glob.each do |path|
              found << path if File.basename(path, ".rb").include?(pattern)
            end
          end
          found.uniq!
          return found if found.empty?

          header = "## Tests (#{found.size}#{truncated ? " — first #{MAX_SCAN_FILES} per glob scanned" : ""})"
          lines << header
          found.each do |path|
            relative = path.sub("#{root}/", "")
            source = RailsAiContext::SafeFile.read(path) or next
            test_count = source.scan(/\b(?:it|test|should)\b/).size
            lines << "- `#{relative}` (#{test_count} tests)"
          end
          lines << ""
          found
        rescue => e
          $stderr.puts "[rails-ai-context] discover_tests failed: #{e.message}" if ENV["DEBUG"]
          []
        end

        # --- Test coverage gaps ---
        def discover_test_gaps(root, pattern, matched_models, ctx, test_files, lines)
          gaps = []
          test_basenames = test_files.map { |f| File.basename(f, ".rb") }

          # Check models
          matched_models&.each do |name, _data|
            snake = name.underscore
            unless test_basenames.any? { |t| t.include?(snake) }
              gaps << "Model `#{name}` — no test file found"
            end
          end

          # Check controllers
          controllers = ctx[:controllers]&.dig(:controllers) || {}
          controllers.each_key do |ctrl_name|
            next unless ctrl_name.downcase.include?(pattern)
            snake = ctrl_name.underscore.delete_suffix("_controller")
            unless test_basenames.any? { |t| t.include?(snake) }
              gaps << "Controller `#{ctrl_name}` — no test file found"
            end
          end

          # Check jobs
          job_dir = File.join(root, "app", "jobs")
          if Dir.exist?(job_dir)
            Dir.glob(File.join(job_dir, "**", "*.rb")).first(MAX_SCAN_FILES).each do |path|
              next unless File.basename(path, ".rb").include?(pattern)
              snake = File.basename(path, ".rb")
              unless test_basenames.any? { |t| t.include?(snake) }
                gaps << "Job `#{snake}` — no test file found"
              end
            end
          end

          # Check services
          service_dir = File.join(root, "app", "services")
          if Dir.exist?(service_dir)
            Dir.glob(File.join(service_dir, "**", "*.rb")).first(MAX_SCAN_FILES).each do |path|
              next unless File.basename(path, ".rb").include?(pattern)
              snake = File.basename(path, ".rb")
              unless test_basenames.any? { |t| t.include?(snake) }
                gaps << "Service `#{snake}` — no test file found"
              end
            end
          end

          return if gaps.empty?

          lines << "## Test Coverage Gaps"
          gaps.each { |g| lines << "- #{g}" }
          lines << ""
        rescue => e
          $stderr.puts "[rails-ai-context] discover_test_gaps failed: #{e.message}" if ENV["DEBUG"]
          nil
        end

        # Detect inherited filters from parent controller
        def detect_parent_filters_for_analyze(parent_class, all_controllers)
          return [] unless parent_class
          parent_data = all_controllers[parent_class]
          if parent_data
            return (parent_data[:filters] || []).select { |f| f.is_a?(Hash) && f[:kind] == "before" && !f[:only]&.any? }
          end

          # Fallback: read source file
          path = Rails.root.join("app", "controllers", "#{parent_class.underscore}.rb")
          return [] unless File.exist?(path)
          source = RailsAiContext::SafeFile.read(path)
          return [] unless source

          source.each_line.filter_map do |line|
            next if line.include?("only:") || line.include?("except:")
            { name: $1 } if line.match(/\A\s*before_action\s+:(\w+)/)
          end
        rescue => e
          $stderr.puts "[rails-ai-context] detect_parent_filters_for_analyze failed: #{e.message}" if ENV["DEBUG"]
          []
        end

        # --- AF6: Related Models via Associations ---
        def discover_related_models(ctx, matched_models, lines)
          return if matched_models.empty?

          related = {}
          matched_models.each do |name, data|
            next unless data.is_a?(Hash)
            (data[:associations] || []).each do |a|
              next unless a.is_a?(Hash)
              related_name = a[:class_name] || a[:name].to_s.classify
              next if matched_models.key?(related_name)
              related[related_name] ||= []
              related[related_name] << "#{a[:type]} from #{name}"
            end
          end
          return if related.empty?

          lines << "## Related Models (#{related.size})"
          related.sort.each { |name, refs| lines << "- **#{name}** — #{refs.join(', ')}" }
          lines << ""
        end

        # --- AF12: Concern Tracing ---
        def discover_concerns(ctx, matched_models, lines)
          return if matched_models.empty?

          concerns = {}
          matched_models.each do |_name, data|
            next unless data.is_a?(Hash)
            (data[:concerns] || []).each do |c|
              next unless c.is_a?(String)
              next if c.include?("::") || %w[Kernel JSON PP].include?(c)
              concerns[c] ||= 0
              concerns[c] += 1
            end
          end
          return if concerns.empty?

          lines << "## Concerns"
          concerns.sort.each { |name, count| lines << "- **#{name}** (used by #{count} model#{'s' if count > 1})" }
          lines << ""
        rescue => e
          $stderr.puts "[rails-ai-context] discover_concerns failed: #{e.message}" if ENV["DEBUG"]
          nil
        end

        # --- AF13: Callback Chains ---
        def discover_callbacks(ctx, matched_models, lines)
          return if matched_models.empty?

          callbacks = []
          matched_models.each do |name, data|
            next unless data.is_a?(Hash)
            (data[:callbacks] || {}).each do |type, methods|
              next unless methods.is_a?(Array)
              methods.each { |m| callbacks << "#{name}: #{type} :#{m}" }
            end
          end
          return if callbacks.empty?

          lines << "## Callbacks"
          callbacks.each { |c| lines << "- #{c}" }
          lines << ""
        end

        # --- AF10: Channels/WebSocket ---
        def discover_channels(root, pattern, lines)
          dir = File.join(root, "app", "channels")
          return unless Dir.exist?(dir)

          candidates = Dir.glob(File.join(dir, "**", "*.rb")).first(MAX_SCAN_FILES)
          found = candidates.select { |p| File.basename(p, ".rb").include?(pattern) }
          return if found.empty?

          lines << "## Channels (#{found.size}#{candidates.size == MAX_SCAN_FILES ? " — first #{MAX_SCAN_FILES} scanned" : ""})"
          found.each do |path|
            relative = path.sub("#{root}/", "")
            lines << "- `#{relative}`"
          end
          lines << ""
        rescue => e
          $stderr.puts "[rails-ai-context] discover_channels failed: #{e.message}" if ENV["DEBUG"]
          nil
        end

        # --- AF11: Mailers ---
        def discover_mailers(root, pattern, lines)
          dir = File.join(root, "app", "mailers")
          return unless Dir.exist?(dir)

          candidates = Dir.glob(File.join(dir, "**", "*.rb")).first(MAX_SCAN_FILES)
          found = candidates.select { |p| File.basename(p, ".rb").include?(pattern) }
          return if found.empty?

          lines << "## Mailers (#{found.size}#{candidates.size == MAX_SCAN_FILES ? " — first #{MAX_SCAN_FILES} scanned" : ""})"
          found.each do |path|
            relative = path.sub("#{root}/", "")
            source = RailsAiContext::SafeFile.read(path) or next
            methods = source.scan(/^\s*def (\w+)/m).flatten.reject { |m| m == "initialize" }
            lines << "- `#{relative}` — #{methods.join(', ')}" if methods.any?
          end
          lines << ""
        rescue => e
          $stderr.puts "[rails-ai-context] discover_mailers failed: #{e.message}" if ENV["DEBUG"]
          nil
        end

        # --- Component usage in feature views ---
        def discover_components(ctx, pattern, lines)
          comp = ctx[:components]
          return unless comp.is_a?(Hash) && !comp[:error] && comp[:components]&.any?

          # Find components whose usage includes views matching the pattern
          matched = comp[:components].select do |c|
            c[:name]&.downcase&.include?(pattern) ||
              c[:used_in]&.any? { |v| v.downcase.include?(pattern) }
          end
          return if matched.empty?

          lines << "## ViewComponents (#{matched.size})"
          matched.first(10).each do |c|
            slots = c[:slots]&.size || 0
            slot_info = slots > 0 ? " (#{slots} slots)" : ""
            used_in = c[:used_in]&.any? ? " — used in: #{c[:used_in].first(5).join(', ')}" : ""
            lines << "- **#{c[:name]}**#{slot_info}#{used_in}"
          end
          lines << ""
        rescue => e
          $stderr.puts "[rails-ai-context] discover_components failed: #{e.message}" if ENV["DEBUG"]
          nil
        end

        # --- AF9: Environment Dependencies ---
        def discover_env_dependencies(root, pattern, matched_models, lines)
          # Scan services, jobs, and model files for ENV references
          dirs = %w[app/services app/jobs].map { |d| File.join(root, d) }.select { |d| Dir.exist?(d) }
          env_vars = Set.new
          truncated = false

          dirs.each do |dir|
            candidates = Dir.glob(File.join(dir, "**", "*.rb")).first(MAX_SCAN_FILES)
            truncated = true if candidates.size == MAX_SCAN_FILES
            candidates.each do |path|
              next unless File.basename(path, ".rb").include?(pattern) || path.downcase.include?(pattern)
              source = RailsAiContext::SafeFile.read(path) or next
              source.scan(/ENV\[["']([^"']+)["']\]|ENV\.fetch\(["']([^"']+)["']\)/).each do |m|
                env_vars << (m[0] || m[1])
              end
            end
          end
          return if env_vars.empty?

          header = "## Environment Dependencies#{truncated ? " (first #{MAX_SCAN_FILES} per dir scanned)" : ""}"
          lines << header
          env_vars.sort.each { |v| lines << "- `#{v}`" }
          lines << ""
        rescue => e
          $stderr.puts "[rails-ai-context] discover_env_dependencies failed: #{e.message}" if ENV["DEBUG"]
          nil
        end
      end
    end
  end
end
