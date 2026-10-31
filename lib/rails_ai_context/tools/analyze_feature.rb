# frozen_string_literal: true

require "pathname"

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

      guide_row(
        order: 2,
        mcp: "rails_analyze_feature(feature:\"X\")",
        cli_args: "feature=X",
        summary: "Full-stack: models + controllers + routes + services + jobs + views + tests"
      )

      annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true, open_world_hint: false)

      # Map well-known feature keywords to gem-based patterns
      AUTH_KEYWORDS = %w[auth authentication login signup signin session devise omniauth].freeze

      # Names are matched over every file a glob finds; only the files read per directory, and the
      # matches listed per section, stop at MAX_SCAN_FILES, and the answer says where they did.
      MAX_SCAN_FILES = 500
      # The callers named under each service; rails_get_service_pattern(service:) lists more.
      CALLERS_SHOWN = 5
      # Receiverless calls that define an example; `def test_*` defines a Minitest one.
      TEST_CALLS = %i[test it specify].freeze

      AUTH_GEM_NAMES = %w[devise omniauth rodauth sorcery clearance authlogic warden jwt].freeze

      def self.call(feature:, server_context: nil)
        feature = feature.to_s.strip
        return text_response("Please provide a feature keyword (e.g. 'post', 'payment', 'authentication').") if feature.empty?
        # Every layer word-matches the keyword against every name it holds, so
        # a 100 KB keyword took ten seconds to match nothing.
        if name_too_long?(feature)
          return empty_response("No matches found for '#{echo_input(feature)}'. A feature keyword is a word or two, such as 'payment'.")
        end
        ctx = cached_context
        pattern = feature
        root = rails_app.root.to_s
        lines = [ "# Feature Analysis: #{feature}", "" ]
        unread = Set.new

        matched_models = discover_models(ctx, pattern, lines)
        discover_controllers(ctx, pattern, lines)
        discover_routes(ctx, pattern, lines)
        discover_services(root, pattern, lines, unread)
        discover_admin(root, pattern, lines)
        discover_jobs(ctx, pattern, lines)
        discover_views(ctx, root, pattern, lines)
        discover_stimulus(ctx, pattern, lines)
        all_tests = discover_tests(root, pattern, lines)
        discover_related_models(ctx, matched_models, lines)
        discover_concerns(ctx, matched_models, lines)
        discover_callbacks(ctx, matched_models, lines)
        discover_channels(ctx, pattern, lines)
        discover_mailers(ctx, pattern, lines)
        discover_env_dependencies(root, pattern, matched_models, lines)
        discover_test_gaps(root, pattern, matched_models, ctx, all_tests, lines)
        discover_components(ctx, pattern, lines)

        # For auth-related keywords, also discover auth gems
        if auth_keyword?(pattern)
          notable = Payload.notable_gems(ctx)
          if notable.any?
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
          return text_response("No matches found for '#{echo_input(feature)}'. No models, controllers, routes, services, or views match this keyword.#{model_names_hint(ctx)}#{unread_note(unread)}")
        end

        text_response(lines.join("\n") + unread_note(unread))
      end

      # Files past MAX_SCAN_FILES in a directory are matched by name alone, so a match by content may be missing.
      def self.unread_note(unread)
        return "" if unread.empty?

        "\n\n_Only the first #{MAX_SCAN_FILES} files of a directory are read, so any past them in #{unread.sort.join(', ')} were matched by name alone._"
      end

      # The names a keyword that matched nothing could have been.
      def self.model_names_hint(ctx)
        model_names = Payload.models(ctx).keys.map(&:to_s).sort.first(10)
        if model_names.any?
          "\n\nTry one of your model names: #{model_names.join(', ')}"
        else
          "\n\nThis app has no models yet, so there are no feature names to suggest."
        end
      end

      # Whether the pattern's words are a run of whole words in text, either in singular or plural: "post" is not "postmark".
      def self.feature_word_match?(text, pattern)
        return false if text.nil? || pattern.nil? || pattern.empty?

        text_words = text.to_s.underscore.scan(/[a-z0-9]+/)
        # A class name splits at its capitals (HTMLPage) or, where an app
        # acronym joins them, not at all (Token::ICal in token/ical.rb).
        [ pattern.to_s.underscore, pattern.to_s.downcase.underscore ].uniq.any? do |form|
          pattern_words = form.scan(/[a-z0-9]+/)
          next false if pattern_words.empty?

          text_words.each_cons(pattern_words.size).any? do |window|
            window.zip(pattern_words).all? { |w, p| same_word?(w, p) }
          end
        end
      end

      class << self
        private

        def listed_suffix(found) = found.size > MAX_SCAN_FILES ? " - first #{MAX_SCAN_FILES} listed" : ""

        # A conditional skip names the condition it is taken out on.
        def inherited_filter_label(filter)
          "#{filter[:name]}#{Serializers::SectionFacts.filter_origin(filter)}" \
            "#{Serializers::SectionFacts.filter_condition_tail(filter)}"
        end

        def same_word?(word, other) = word == other || word.singularize == other.singularize

        # SignUp, sign_up and signup alike.
        def auth_keyword?(pattern)
          AUTH_KEYWORDS.include?(pattern.underscore.delete("_"))
        end

        def discover_admin(root, pattern, lines)
          matched = Introspectors::AdminResources.call(root).select { |r| feature_word_match?(r[:model], pattern) }
          return if matched.empty?

          lines << "## Admin Resources (#{matched.size})"
          matched.each { |resource| lines << "- #{Introspectors::AdminResources.line(resource)}" }
          lines << ""
        end

        # --- AF: Models ---
        def discover_models(ctx, pattern, lines)
          models = Payload.models(ctx)

          # For auth-related keywords, also match the User model and auth-related concerns
          extra_auth_match = auth_keyword?(pattern)

          matched = models.select do |name, data|
            next false if data[:error]
            feature_word_match?(name, pattern) ||
              feature_word_match?(data[:table_name], pattern) ||
              (extra_auth_match && (name == "User" || data[:concerns]&.any? { |c| c.to_s.downcase.match?(/authenticat|devise/) }))
          end

          if matched.any?
            lines << "## Models (#{matched.size})"
            matched.sort.each do |name, data|
              lines << "" << "### #{name}"
              table_line = data[:table_name] ? "`#{data[:table_name]}`" : Serializers::SectionFacts.table_note(ctx[:schema], data)
              lines << "**Table:** #{table_line}" if table_line

              table_name = data[:table_name]
              if table_name && (table_data = RailsAiContext::Payload.model_schema_table(ctx[:schema], data))
                if table_data&.dig(:columns)&.any?
                  cols = table_data[:columns].reject { |c| %w[id created_at updated_at].include?(c[:name]) }
                  col_strs = cols.map { |c| col_type = c[:array] ? "#{c[:type]}[]" : c[:type]; [ c[:name], col_type ].compact.join(":") }
                  lines << "**Columns:** #{col_strs.join(', ')}" if cols.any?
                end
              end

              if data[:associations].is_a?(Array) && data[:associations].any?
                lines << "**Associations:** #{Serializers::SectionFacts.associations_list(data).join(', ')}"
              end
              if data[:validations].is_a?(Array) && data[:validations].any?
                lines << "**Validations:** #{data[:validations].select { |v| v.is_a?(Hash) }.map { |v| [ v[:kind], Serializers::SectionFacts.validation_target(v) ].reject(&:empty?).join(" ") }.uniq.join('; ')}"
              end
              if data[:scopes].is_a?(Array) && data[:scopes].any?
                scope_strs = data[:scopes].map { |s| s.is_a?(Hash) ? s[:name] : s.to_s }
                lines << "**Scopes:** #{scope_strs.join(', ')}"
              end
              if data[:enums].is_a?(Hash) && data[:enums].any?
                enum_strs = data[:enums].map do |k, v|
                  "#{k}: #{Serializers::SectionFacts.enum_values(v)}"
                end
                lines << "**Enums:** #{enum_strs.join('; ')}"
              end
            end
            # Only after a section: an empty one left a blank line per layer,
            # four in a row under the heading of a feature with no models.
            lines << ""
          end

          matched
        end

        # --- AF: Controllers ---
        def discover_controllers(ctx, pattern, lines)
          controllers = Payload.controllers(ctx)
          matched = controllers.select { |name, data| data.is_a?(Hash) && !data[:error] && feature_word_match?(name, pattern) }

          if matched.any?
            lines << "## Controllers (#{matched.size})"
            matched.sort.each do |name, info|
              lines << "" << "### #{name}"
              lines << "- **Actions:** #{Serializers::SectionFacts.actions_phrase(info)}"

              split = RailsAiContext::ActionFilters.for_controller(ctx, name, root: rails_app.root.to_s)
              if split[:inherited].any?
                lines << "- **Inherited filters:** #{split[:inherited].map { |f| inherited_filter_label(f) }.join(', ')}"
              end

              filters = split[:own].map do |f|
                label = "#{f[:kind]} #{f[:name]}#{Serializers::SectionFacts.filter_origin(f)}"
                label += " only: #{Array(f[:only]).join(', ')}" if f[:only]&.any?
                label += " except: #{Array(f[:except]).join(', ')}" if f[:except]&.any?
                label + Serializers::SectionFacts.filter_condition_tail(f)
              end
              lines << "- **Filters:** #{filters.join('; ')}" if filters.any?

              if split[:skipped].any?
                lines << "- **Skipped filters:** #{split[:skipped].map { |n| "~~#{n}~~" }.join(', ')}"
              end
            end
            lines << ""
          end
        end

        # --- AF: Routes ---
        def discover_routes(ctx, pattern, lines)
          by_controller = RouteCoverage.all_by_controller(ctx[:routes])
          matched = by_controller.select { |ctrl, _| feature_word_match?(ctrl, pattern) }

          if matched.any?
            route_count = matched.values.sum(&:size)
            lines << "## Routes (#{route_count})"
            matched.sort.each do |ctrl, actions|
              actions.each do |r|
                params = RouteCoverage.path_params(r[:path])
                helper = if r[:name]
                  args = params.any? ? "(#{params.map { |p| p == "id" ? "@record" : ":#{p}" }.join(', ')})" : ""
                  " `#{r[:name]}_path#{args}`"
                else
                  ""
                end
                lines << "- `#{r[:verb]}` `#{r[:path]}` → #{ctrl}##{r[:action]}#{helper}"
              end
            end
            lines << ""
          end
        end

        # --- AF1: Services ---
        def discover_services(root, pattern, lines, unread)
          dir = File.join(root, "app", "services")
          return unless Dir.exist?(dir)

          real_root = File.realpath(root).to_s
          real_dir = File.realpath(dir).to_s
          files = safe_glob(dir, "**/*.rb", real_root)
          # A name matches without a read; only the files whose name does not are read for the word.
          by_name, rest = files.partition { |path| feature_word_match?(File.basename(path, ".rb"), pattern) }
          unread << "app/services" if rest.size > MAX_SCAN_FILES
          by_content = rest.first(MAX_SCAN_FILES).select do |path|
            File.size(path) < 50_000 && feature_word_match?(RailsAiContext::SafeFile.read(path), pattern)
          end
          found = files & (by_name + by_content)
          return if found.empty?

          services = found.first(MAX_SCAN_FILES).filter_map do |path|
            source = RailsAiContext::SafeFile.read(path) or next
            # The path carries the namespace Zeitwerk expects, as rails_get_service_pattern reads it.
            constant = path.delete_prefix("#{real_dir}/").delete_suffix(".rb").camelize
            { path: path, source: source, name: Introspectors::ServiceClasses.declaration(source, constant).first }
          end
          # A feature's services are usually run from controllers its name does
          # not match: CheckoutService from two OrdersControllers.
          named = services.select { |s| s[:name] }
          callers, callers_truncated = GetServicePattern.callers_of(named.to_h { |s| [ s[:name], s[:path] ] }, real_root)

          lines << "## Services (#{found.size}#{listed_suffix(found)})"
          services.each do |service|
            relative = service[:path].sub("#{real_root}/", "")
            methods = service[:name] ? service_methods(service[:source], service[:name]) : []
            lines << "- `#{relative}` (#{count_phrase(service[:source].lines.size, "line")})"
            lines << "  Methods: #{methods.first(20).join(', ')}" if methods.any?
            called_by = callers.fetch(service[:name], [])
            next if called_by.empty?

            more = called_by.size > CALLERS_SHOWN ? " and #{called_by.size - CALLERS_SHOWN} more" : ""
            lines << "  Called by: #{called_by.first(CALLERS_SHOWN).map { |c| "`#{c}`" }.join(', ')}#{more}"
          end
          if callers_truncated
            lines << "_The caller scan stopped after #{count_phrase(GetServicePattern::MAX_CALLER_SCAN_FILES, "file")}._"
          end
          lines << ""
        rescue => e
          RailsAiContext.debug_fail(e, nil, label: "discover_services")
        end

        # The service class's own public methods, by the names Ruby calls
        # them: a line scan listed `success` for CheckoutService, read off the
        # `success?` of the Result struct nested in it.
        def service_methods(source, name)
          Introspectors::ActionResolver.own_methods_in(source, name)
            .select { |m| m[:visibility] == :public }
            .map { |m| m[:scope] == :class ? "self.#{m[:name]}" : m[:name].to_s }
        end

        # --- AF2: Jobs ---
        def discover_jobs(ctx, pattern, lines)
          payload_section(Payload.jobs(ctx), pattern, lines, "Jobs") do |job|
            bits = []
            bits << "queue: #{job[:queue]}" if job[:queue]
            bits << Array(job[:retries]).join("; ") if Array(job[:retries]).any?
            bits << "perform(#{job[:perform_signature]})" if job[:perform_signature]
            bits.any? ? " (#{bits.join(', ')})" : ""
          end
          # A Sidekiq worker is not an ActiveJob job, and in an app that runs
          # its background work that way it is the only job there is.
          payload_section(Payload.workers(ctx), pattern, lines, "Sidekiq Workers") do |worker|
            bits = []
            queue = (worker[:options] || {}).find { |key, _| key.to_s == "queue" }&.last
            bits << "queue: #{queue}" if queue
            bits << Array(worker[:retries]).join("; ") if Array(worker[:retries]).any?
            bits << "#{worker[:entry_point] || "perform"}(#{worker[:perform_signature]})" if worker[:perform_signature]
            bits.any? ? " (#{bits.join(', ')})" : ""
          end
        end

        # The jobs, mailers and channels the :jobs introspector read, matched
        # by class name. A section the introspector did not produce stays out
        # rather than being re-derived from a directory walk.
        def payload_section(records, pattern, lines, heading)
          matched = records.select { |r| r.is_a?(Hash) && feature_word_match?(r[:name], pattern) }
          return if matched.empty?

          lines << "## #{heading} (#{matched.size})"
          matched.each do |record|
            label = record[:file] ? "`#{record[:file]}`" : "**#{record[:name]}**"
            lines << "- #{label}#{yield(record)}"
          end
          lines << ""
        end

        # --- AF3: Views + Partials ---
        def discover_views(ctx, root, pattern, lines)
          views_dir = File.join(root, "app", "views")
          return unless Dir.exist?(views_dir)

          real_root = File.realpath(root).to_s
          real_views_dir = File.realpath(views_dir).to_s
          found = safe_glob(views_dir, "**/*.{erb,haml,slim,jbuilder}", real_root).select do |path|
            feature_word_match?(path.sub("#{real_views_dir}/", ""), pattern)
          end
          return if found.empty?

          lines << "## Views (#{found.size}#{listed_suffix(found)})"
          found.first(MAX_SCAN_FILES).each do |path|
            relative = path.sub("#{real_views_dir}/", "")
            source = RailsAiContext::SafeFile.read(path) or next
            line_count = source.lines.size
            partials = rendered_partials(source, path)
            stimulus = Introspectors::ViewTemplateIntrospector.template_stimulus_refs(source)
            detail = "- `#{relative}` (#{count_phrase(line_count, "line")})"
            detail += " renders: #{partials.join(', ')}" if partials.any?
            detail += " stimulus: #{stimulus.join(', ')}" if stimulus.any?
            lines << detail
          end
          lines << ""
        rescue => e
          RailsAiContext.debug_fail(e, nil, label: "discover_views")
        end

        # A render call's partial or template names, and for a record render
        # (`render @post`) the record, read as rails_get_view reads them.
        def rendered_partials(source, path = nil)
          reader = Introspectors::RenderCalls
          reader.render_calls(source, path: path).flat_map do |_, args, block|
            named = reader.rendered_names(args, block: block).select { |name| name.match?(reader::PARTIAL_NAME) }
            next named if named.any?

            record = reader.render_line(args)[reader::IMPLICIT_RENDER, 1]&.split(".")&.last&.delete_prefix("@")
            record && !reader::RENDER_KEYWORD_ARGS.include?(record) ? [ record ] : []
          end.uniq
        end

        # --- AF4: Stimulus Controllers ---
        def discover_stimulus(ctx, pattern, lines)
          stim = Payload.section(ctx, :stimulus)
          return unless stim

          controllers = stim[:controllers] || []
          matched = controllers.select do |c|
            name = c[:name] || c[:file]&.gsub("_controller.js", "")
            feature_word_match?(name, pattern)
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
        # @return [Array<String>] every test in the suite, relative to the suite's root
        def discover_tests(root, pattern, lines)
          real_root = File.realpath(root).to_s
          found = []
          all = []

          base = RailsAiContext::PathResolver.test_root(root)
          real_base = File.realpath(base).to_s
          # An in-repo engine or pack keeps its tests in its own spec/ or test/.
          (PathResolver.dirs_for(base, "spec") + PathResolver.dirs_for(base, "test")).each do |dir|
            suffix_glob = safe_glob(dir, "**/*_{test,spec}.rb", real_base)
            # The path, not the basename: the gap checker below matches this
            # way for the same reason, and a spec whose feature word is a
            # directory (billing/invoices/create_spec.rb) is the normal shape
            # of a namespaced suite.
            suffix_glob.each do |path|
              found << path if feature_word_match?(TestFramework.test_name(path.delete_prefix("#{real_base}/")), pattern)
            end
            prefix_glob = safe_glob(dir, "**/{test,spec}_*.rb", real_base)
            prefix_glob.each do |path|
              found << path if feature_word_match?(TestFramework.test_name(path.delete_prefix("#{real_base}/")), pattern)
            end
            all.concat(suffix_glob, prefix_glob)
          end
          found.uniq!
          all = all.uniq.map { |path| path.delete_prefix("#{real_base}/") }
          return all if found.empty?

          lines << "## Tests (#{found.size}#{listed_suffix(found)})"
          found.first(MAX_SCAN_FILES).each do |path|
            relative = Pathname.new(path).relative_path_from(Pathname.new(real_root)).to_s
            source = RailsAiContext::SafeFile.read(path) or next
            lines << "- `#{relative}` (#{count_phrase(test_count(source), "test")})"
          end
          lines << ""
          all
        rescue => e
          RailsAiContext.debug_fail(e, [], label: "discover_tests")
        end

        def test_count(source)
          Introspectors::AstWalk.each(AstCache.parse_uncached(source).value).count do |node|
            case node
            when Prism::CallNode then node.receiver.nil? && TEST_CALLS.include?(node.name) && !(node.arguments || node.block).nil?
            when Prism::DefNode then node.receiver.nil? && node.name.start_with?("test_")
            else false
            end
          end
        end

        # --- Test coverage gaps ---
        # A gap is a claim that something has no test, so it reads the name of every test in the suite:
        # a large suite holds thousands of spec files, and the first 500 can miss the ones that cover it.
        def discover_test_gaps(root, pattern, matched_models, ctx, test_files, lines)
          gaps = []
          # Paths, not basenames: a namespaced name underscores to admin/badges,
          # which no basename can contain, so every namespaced controller was
          # reported as having no test, such as an Admin::BadgesController
          # against spec/requests/admin/badges_controller_spec.rb. Every test
          # in the suite, not only those the feature word names: the auth rule
          # matches User for `authentication`, a word its user_test.rb lacks.
          real_root = File.realpath(root).to_s
          suite = TestFramework::Suite.new(PathResolver.test_root(root), test_files, app_root: root)

          # Check models
          matched_models&.each do |name, data|
            # The file carries the app's inflection, which underscoring the name here
            # does not, when it is the model's own file and not one it shares.
            stem = data[:file].to_s[%r{app/models/(.+)\.rb\z}, 1]
            snake = stem && Introspectors::DeclaredConstant.path_for?(stem, name) ? stem : name.underscore
            unless suite.tested?(:model, snake, name, file: data[:file])
              gaps << "Model `#{name}` - no test file found"
            end
          end

          # Check controllers
          controllers = Payload.controllers(ctx)
          routes = RouteCoverage.table(ctx[:routes])
          controllers.each_key do |ctrl_name|
            next unless feature_word_match?(ctrl_name, pattern)
            snake = RailsAiContext::Payload.controller_route_key(ctx, ctrl_name)
            unless suite.tested?(:controller, snake, ctrl_name, file: Payload.controller_file(ctx, ctrl_name), routes: routes)
              gaps << "Controller `#{ctrl_name}` - no test file found"
            end
          end

          { job: "jobs", service: "services" }.each do |kind, dir|
            path_dir = File.join(root, "app", dir)
            next unless Dir.exist?(path_dir)

            real_dir = File.realpath(path_dir)
            safe_glob(path_dir, "**/*.rb", real_root).each do |path|
              snake = path.delete_prefix("#{real_dir}/").delete_suffix(".rb")
              next unless feature_word_match?(File.basename(snake), pattern)
              next if suite.tested?(kind, snake, TestFramework.declared_constant(path, snake), file: path)

              gaps << "#{kind.to_s.capitalize} `#{snake}` - no test file found"
            end
          end

          return if gaps.empty?

          lines << "## Test Coverage Gaps"
          gaps.each { |g| lines << "- #{g}" }
          lines << ""
        rescue => e
          RailsAiContext.debug_fail(e, nil, label: "discover_test_gaps")
        end

        # --- AF6: Related Models via Associations ---
        def discover_related_models(ctx, matched_models, lines)
          return if matched_models.empty?

          related = {}
          all_models = Payload.models(ctx)
          matched_models.each do |name, data|
            next unless data.is_a?(Hash)
            by_name = Introspectors::AssociationClass.by_name(data[:associations])
            Array(data[:associations]).grep(Hash).each do |a|
              related_name = Introspectors::AssociationClass.resolve(a, all_models, by_name: by_name, owner: name) or next
              next if matched_models.key?(related_name)
              related[related_name] ||= []
              related[related_name] << "#{a[:type]} from #{name}"
            end
          end
          return if related.empty?

          lines << "## Related Models (#{related.size})"
          related.sort.each { |name, refs| lines << "- **#{name}** - #{refs.join(', ')}" }
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
              concerns[c] ||= 0
              concerns[c] += 1
            end
          end
          return if concerns.empty?

          lines << "## Concerns"
          concerns.sort.each { |name, count| lines << "- **#{name}** (used by #{count_phrase(count, 'model')})" }
          lines << ""
        rescue => e
          RailsAiContext.debug_fail(e, nil, label: "discover_concerns")
        end

        # --- AF13: Callback Chains ---
        def discover_callbacks(ctx, matched_models, lines)
          return if matched_models.empty?

          callbacks = []
          matched_models.each do |name, data|
            next unless data.is_a?(Hash)
            (data[:callbacks] || {}).each do |type, methods|
              next unless methods.is_a?(Array)
              methods.each { |m| callbacks << "#{name}: #{callback_type_label(type)} #{callback_target(m)}" }
            end
          end
          return if callbacks.empty?

          lines << "## Callbacks"
          callbacks.each { |c| lines << "- #{c}" }
          lines << ""
        end

        # --- AF10: Channels/WebSocket ---
        def discover_channels(ctx, pattern, lines)
          payload_section(Payload.channels(ctx), pattern, lines, "Channels") do |channel|
            streams = Array(channel[:stream_methods])
            streams.any? ? " - #{streams.join(', ')}" : ""
          end
        end

        # --- AF11: Mailers ---
        def discover_mailers(ctx, pattern, lines)
          payload_section(Payload.mailers(ctx), pattern, lines, "Mailers") do |mailer|
            actions = Array(mailer[:actions])
            actions.any? ? " - #{actions.join(', ')}" : ""
          end
        end

        # --- Component usage in feature views ---
        def discover_components(ctx, pattern, lines)
          comp = Payload.section(ctx, :components)
          return unless comp && comp[:components]&.any?

          # Find components whose usage includes views matching the pattern
          matched = comp[:components].select do |c|
            feature_word_match?(c[:name], pattern) ||
              c[:used_in]&.any? { |v| feature_word_match?(v, pattern) }
          end
          return if matched.empty?

          lines << "## ViewComponents (#{matched.size})"
          matched.first(10).each do |c|
            slots = c[:slots]&.size || 0
            slot_info = slots > 0 ? " (#{count_phrase(slots, "slot")})" : ""
            used_in = c[:used_in]&.any? ? " - used in: #{c[:used_in].first(5).join(', ')}" : ""
            lines << "- **#{c[:name]}**#{slot_info}#{used_in}"
          end
          lines << ""
        rescue => e
          RailsAiContext.debug_fail(e, nil, label: "discover_components")
        end

        # --- AF9: Environment Dependencies ---
        def discover_env_dependencies(root, pattern, matched_models, lines)
          # Scan services, jobs, and model files for ENV references
          real_root = File.realpath(root).to_s
          dirs = %w[app/services app/jobs].map { |d| File.join(root, d) }.select { |d| Dir.exist?(d) }
          env_vars = Set.new
          truncated = false

          dirs.each do |dir|
            real_dir = File.realpath(dir).to_s
            # The path under the directory: the folders above the app hold any word.
            matched = safe_glob(dir, "**/*.rb", real_root).select do |path|
              feature_word_match?(path.delete_prefix("#{real_dir}/"), pattern)
            end
            truncated ||= matched.size > MAX_SCAN_FILES
            matched.first(MAX_SCAN_FILES).each do |path|
              source = RailsAiContext::SafeFile.read(path) or next
              Introspectors::EnvReferences.references(source).each { |ref| env_vars << ref[:name] }
            end
          end
          return if env_vars.empty?

          header = "## Environment Dependencies#{truncated ? " (first #{MAX_SCAN_FILES} per dir scanned)" : ""}"
          lines << header
          env_vars.sort.each { |v| lines << "- `#{v}`" }
          lines << ""
        rescue => e
          RailsAiContext.debug_fail(e, nil, label: "discover_env_dependencies")
        end
      end
    end
  end
end
