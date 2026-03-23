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

      def self.call(feature:, server_context: nil) # rubocop:disable Metrics
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
        discover_tests(root, pattern, lines)
        discover_related_models(ctx, matched_models, lines)
        discover_concerns(ctx, matched_models, lines)
        discover_callbacks(ctx, matched_models, lines)
        discover_channels(root, pattern, lines)
        discover_mailers(root, pattern, lines)
        discover_env_dependencies(root, pattern, matched_models, lines)

        text_response(lines.join("\n"))
      end

      class << self
        private

        # --- AF: Models ---
        def discover_models(ctx, pattern, lines)
          models = ctx[:models] || {}
          matched = models.select do |name, data|
            next false if data[:error]
            name.downcase.include?(pattern) ||
              data[:table_name]&.downcase&.include?(pattern) ||
              name.underscore.include?(pattern)
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

              lines << "**Associations:** #{data[:associations].map { |a| "#{a[:type]} :#{a[:name]}" }.join(', ')}" if data[:associations]&.any?
              lines << "**Validations:** #{data[:validations].map { |v| "#{v[:kind]} on #{v[:attributes].join(', ')}" }.uniq.join('; ')}" if data[:validations]&.any?
              lines << "**Scopes:** #{data[:scopes].join(', ')}" if data[:scopes]&.any?
              lines << "**Enums:** #{data[:enums].map { |k, v| "#{k}: #{v.join(', ')}" }.join('; ')}" if data[:enums]&.any?
            end
          else
            lines << "## Models" << "_No models matching '#{pattern}'._"
          end

          lines << ""
          matched
        end

        # --- AF: Controllers ---
        def discover_controllers(ctx, pattern, lines)
          controllers = ctx.dig(:controllers, :controllers) || {}
          matched = controllers.select { |name, data| !data[:error] && name.downcase.include?(pattern) }

          if matched.any?
            lines << "## Controllers (#{matched.size})"
            matched.sort.each do |name, info|
              actions = info[:actions]&.join(", ") || "none"
              lines << "" << "### #{name}"
              lines << "- **Actions:** #{actions}"
              filters = (info[:filters] || []).map do |f|
                label = "#{f[:kind]} #{f[:name]}"
                label += " only: #{f[:only].join(', ')}" if f[:only]&.any?
                label += " except: #{f[:except].join(', ')}" if f[:except]&.any?
                label += " unless: #{f[:unless]}" if f[:unless]
                label
              end
              lines << "- **Filters:** #{filters.join('; ')}" if filters.any?
            end
          else
            lines << "## Controllers" << "_No controllers matching '#{pattern}'._"
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
                name_part = r[:name] ? " `#{r[:name]}`" : ""
                lines << "- `#{r[:verb]}` `#{r[:path]}` → #{ctrl}##{r[:action]}#{name_part}"
              end
            end
          else
            lines << "## Routes" << "_No routes matching '#{pattern}'._"
          end
          lines << ""
        end

        # --- AF1: Services ---
        def discover_services(root, pattern, lines)
          dir = File.join(root, "app", "services")
          return unless Dir.exist?(dir)

          found = Dir.glob(File.join(dir, "**", "*.rb")).select do |path|
            File.basename(path, ".rb").include?(pattern) ||
              (File.size(path) < 50_000 && File.read(path, encoding: "UTF-8", invalid: :replace, undef: :replace).downcase.include?(pattern))
          end
          return if found.empty?

          lines << "## Services (#{found.size})"
          found.each do |path|
            relative = path.sub("#{root}/", "")
            source = File.read(path, encoding: "UTF-8", invalid: :replace, undef: :replace) rescue next
            line_count = source.lines.size
            methods = source.scan(/\A\s*def (?:self\.)?(\w+)/m).flatten.reject { |m| m == "initialize" }
            lines << "- `#{relative}` (#{line_count} lines)"
            lines << "  Methods: #{methods.first(10).join(', ')}" if methods.any?
          end
          lines << ""
        rescue
          nil
        end

        # --- AF2: Jobs ---
        def discover_jobs(root, pattern, lines)
          dir = File.join(root, "app", "jobs")
          return unless Dir.exist?(dir)

          found = Dir.glob(File.join(dir, "**", "*.rb")).select do |path|
            File.basename(path, ".rb").include?(pattern)
          end
          return if found.empty?

          lines << "## Jobs (#{found.size})"
          found.each do |path|
            relative = path.sub("#{root}/", "")
            source = File.read(path, encoding: "UTF-8", invalid: :replace, undef: :replace) rescue next
            queue = source.match(/queue_as\s+[:'"](\w+)/)&.captures&.first || "default"
            retries = source.match(/retry_on.*attempts:\s*(\d+)/)&.captures&.first
            lines << "- `#{relative}` (queue: #{queue}#{retries ? ", retries: #{retries}" : ""})"
          end
          lines << ""
        rescue
          nil
        end

        # --- AF3: Views + Partials ---
        def discover_views(ctx, root, pattern, lines)
          views_dir = File.join(root, "app", "views")
          return unless Dir.exist?(views_dir)

          found = Dir.glob(File.join(views_dir, "**", "*.{erb,haml,slim}")).select do |path|
            path.sub("#{views_dir}/", "").downcase.include?(pattern)
          end
          return if found.empty?

          lines << "## Views (#{found.size})"
          found.each do |path|
            relative = path.sub("#{views_dir}/", "")
            source = File.read(path, encoding: "UTF-8", invalid: :replace, undef: :replace) rescue next
            line_count = source.lines.size
            partials = source.scan(/render\s+(?:partial:\s*)?["']([^"']+)["']/).flatten
            stimulus = source.scan(/data-controller=["']([^"']+)["']/).flat_map { |m| m.first.split }
            detail = "- `#{relative}` (#{line_count} lines)"
            detail += " renders: #{partials.join(', ')}" if partials.any?
            detail += " stimulus: #{stimulus.join(', ')}" if stimulus.any?
            lines << detail
          end
          lines << ""
        rescue
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
            lines << "- **Targets:** #{c[:targets].join(', ')}" if c[:targets]&.any?
            lines << "- **Values:** #{c[:values].map { |v| "#{v[:name]}:#{v[:type]}" }.join(', ')}" if c[:values]&.any?
            lines << "- **Actions:** #{c[:actions].join(', ')}" if c[:actions]&.any?
          end
          lines << ""
        end

        # --- AF5: Tests ---
        def discover_tests(root, pattern, lines)
          test_dirs = [ File.join(root, "spec"), File.join(root, "test") ]
          found = []

          test_dirs.each do |dir|
            next unless Dir.exist?(dir)
            Dir.glob(File.join(dir, "**", "*_{test,spec}.rb")).each do |path|
              found << path if File.basename(path, ".rb").include?(pattern)
            end
            Dir.glob(File.join(dir, "**", "{test,spec}_*.rb")).each do |path|
              found << path if File.basename(path, ".rb").include?(pattern)
            end
          end
          found.uniq!
          return if found.empty?

          lines << "## Tests (#{found.size})"
          found.each do |path|
            relative = path.sub("#{root}/", "")
            source = File.read(path, encoding: "UTF-8", invalid: :replace, undef: :replace) rescue next
            test_count = source.scan(/\b(?:it|test|should)\b/).size
            lines << "- `#{relative}` (#{test_count} tests)"
          end
          lines << ""
        rescue
          nil
        end

        # --- AF6: Related Models via Associations ---
        def discover_related_models(ctx, matched_models, lines)
          return if matched_models.empty?

          related = {}
          matched_models.each do |name, data|
            (data[:associations] || []).each do |a|
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
            (data[:concerns] || []).each do |c|
              next if c.include?("::") || %w[Kernel JSON PP].include?(c)
              concerns[c] ||= 0
              concerns[c] += 1
            end
          end
          return if concerns.empty?

          lines << "## Concerns"
          concerns.sort.each { |name, count| lines << "- **#{name}** (used by #{count} model#{'s' if count > 1})" }
          lines << ""
        end

        # --- AF13: Callback Chains ---
        def discover_callbacks(ctx, matched_models, lines)
          return if matched_models.empty?

          callbacks = []
          matched_models.each do |name, data|
            (data[:callbacks] || {}).each do |type, methods|
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

          found = Dir.glob(File.join(dir, "**", "*.rb")).select { |p| File.basename(p, ".rb").include?(pattern) }
          return if found.empty?

          lines << "## Channels (#{found.size})"
          found.each do |path|
            relative = path.sub("#{root}/", "")
            lines << "- `#{relative}`"
          end
          lines << ""
        rescue
          nil
        end

        # --- AF11: Mailers ---
        def discover_mailers(root, pattern, lines)
          dir = File.join(root, "app", "mailers")
          return unless Dir.exist?(dir)

          found = Dir.glob(File.join(dir, "**", "*.rb")).select { |p| File.basename(p, ".rb").include?(pattern) }
          return if found.empty?

          lines << "## Mailers (#{found.size})"
          found.each do |path|
            relative = path.sub("#{root}/", "")
            source = File.read(path, encoding: "UTF-8", invalid: :replace, undef: :replace) rescue next
            methods = source.scan(/\A\s*def (\w+)/m).flatten.reject { |m| m == "initialize" }
            lines << "- `#{relative}` — #{methods.join(', ')}" if methods.any?
          end
          lines << ""
        rescue
          nil
        end

        # --- AF9: Environment Dependencies ---
        def discover_env_dependencies(root, pattern, matched_models, lines)
          # Scan services, jobs, and model files for ENV references
          dirs = %w[app/services app/jobs].map { |d| File.join(root, d) }.select { |d| Dir.exist?(d) }
          env_vars = Set.new

          dirs.each do |dir|
            Dir.glob(File.join(dir, "**", "*.rb")).each do |path|
              next unless File.basename(path, ".rb").include?(pattern) || path.downcase.include?(pattern)
              source = File.read(path, encoding: "UTF-8", invalid: :replace, undef: :replace) rescue next
              source.scan(/ENV\[["']([^"']+)["']\]|ENV\.fetch\(["']([^"']+)["']\)/).each do |m|
                env_vars << (m[0] || m[1])
              end
            end
          end
          return if env_vars.empty?

          lines << "## Environment Dependencies"
          env_vars.sort.each { |v| lines << "- `#{v}`" }
          lines << ""
        rescue
          nil
        end
      end
    end
  end
end
