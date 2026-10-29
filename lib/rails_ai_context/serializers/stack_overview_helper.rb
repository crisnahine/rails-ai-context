# frozen_string_literal: true

module RailsAiContext
  module Serializers
    # Shared helper for rendering stack overview lines from full-preset introspectors.
    # Include in any serializer that has a `context` reader and renders a project overview.
    module StackOverviewHelper
      include CountPhrase
      include ToolGuideHelper
      include ModelSection
      include StackSections

      # One rule file on its way to disk. The reason travels with the path it
      # explains; when it lived in a second hash keyed by the same path, an
      # entry missing from that hash lost its reason silently.
      RuleFile = Struct.new(:path, :content, :reason)

      # The models listings' line on reading, in the tools guide's terms: the
      # tools are the reference, and a file is read to edit it. "Read model
      # files for business logic" sat beside "NEVER read ... model files".
      MODELS_READING = "Check here first for scopes, constants, associations. Read a model file only when you edit it."

      # Returns an array of summary lines for full-preset introspectors.
      # Each line is only added if the introspector returned meaningful data.
      def full_preset_stack_lines(ctx = context)
        lines = []

        auth_line = SectionFacts.auth_line(ctx)
        lines << auth_line if auth_line

        parts = []
        frames = Payload.turbo_frames(ctx)
        streams = Payload.turbo_streams(ctx)
        parts << count_phrase(frames.size, "frame") if frames.any?
        parts << count_phrase(streams.size, "stream") if streams.any?
        parts << "broadcasts" if Payload.model_broadcasts(ctx).any?
        lines << "- Hotwire: #{parts.join(', ')}" if parts.any?

        if (api = Payload.section(ctx, :api))
          parts = []
          parts << "API-only" if api[:api_only]
          parts << count_phrase((api[:versions] || []).size, "version") if api[:versions]&.any?
          parts << "GraphQL" if api[:graphql]&.any?
          parts << api[:serializer_library] if api[:serializer_library]
          lines << "- API: #{parts.join(', ')}" if parts.any?
        end

        i18n_line = SectionFacts.i18n_line(ctx)
        lines << i18n_line if i18n_line

        attachments = Payload.storage_attachments(ctx)
        if attachments.any?
          # One entry per attachment, so the models are the distinct owners.
          models = attachments.map { |a| a[:model] }.uniq.size
          lines << "- Storage: ActiveStorage (#{count_phrase(models, "model")} with #{count_phrase(attachments.size, "attachment")})"
        end

        rich_text = Payload.rich_text_fields(ctx)
        lines << "- RichText: ActionText (#{count_phrase(rich_text.size, "field")})" if rich_text.any?

        assets_line = SectionFacts.assets_line(ctx)
        lines << assets_line if assets_line

        # What routes.rb mounts, engine or plain Rack app: the key predates
        # the widening, the line should not.
        # One name per app, however many paths mount it.
        mounted = Payload.mounted_engines(ctx).filter_map { |e| e[:engine] }.tally
        if mounted.any?
          lines << Budget.list(mounted.map { |name, paths| paths > 1 ? "#{name} (#{paths} paths)" : name },
                               cap: Budget.cap(:mounted), lead: "- Mounted: ")
        end

        # What routes.rb mounts is not what the repository holds: an in-repo
        # engine is often mounted by its own initializer, or not at all.
        in_repo = Payload.in_repo_engines(ctx).filter_map { |e| e[:name] }
        if in_repo.any?
          lines << "#{Budget.list(in_repo, cap: Budget.cap(:in_repo_engines), lead: "- In-repo engines: #{in_repo.size} (", width: Budget::LINE_WIDTH - 1)})"
        end

        raw_databases = Payload.section(ctx, :multi_database)&.dig(:databases)
        db_list = raw_databases.is_a?(Hash) ? raw_databases.keys : Array(raw_databases)
        if db_list.size > 1
          db_names = db_list.map { |d| d.is_a?(Hash) ? "#{d[:name]}#{Payload.database_mark(d)}" : d }
          # The names it leaves out are counted, as the mounted apps' are.
          cap = Budget.cap(:databases)
          shown = db_names.first(cap)
          if db_names.size > cap
            elsewhere = db_list.drop(cap).count { |d| Payload.scope_words(d) }
            shown << "...#{db_names.size - cap} more#{", #{elsewhere} of them not configured in this environment" if elsewhere > 0}"
          end
          lines << "- Databases: #{db_list.size} (#{shown.join(', ')})"
        end

        components = Payload.section(ctx, :components)
        if components && components.dig(:summary, :total).to_i > 0
          summary = components[:summary]
          lines << "- Components: #{count_phrase(summary[:total], "component")} " \
            "(#{SectionFacts.component_buckets(summary).join(', ')})"
        end

        perf = Payload.section(ctx, :performance)
        if perf && perf[:summary]
          total = perf.dig(:summary, :total_issues).to_i
          lines << "- Performance: #{count_phrase(total, "issue")} detected" if total > 0
        end

        if (fe = Payload.section(ctx, :frontend_frameworks))
          parts = []
          parts << "#{fe[:framework]} #{fe[:version]}".strip if fe[:framework]
          parts << fe[:mounting] if fe[:mounting]
          lines << "- Frontend: #{parts.join(', ')}" if parts.any?
        end

        lines
      end

      # The project-overview body, between a rule file's own frontmatter and its
      # own trailing MCP hint: what the root file states, for a rules file that
      # stands in for it.
      def overview_lines
        lines = SectionFacts.static_notice_lines(context)
        lines << SectionFacts.database_line(context)
        lines << SectionFacts.models_line(context)

        if (routes = Payload.section(context, :routes))
          lines << "- Routes: #{RouteCoverage.summary(routes)}"
        end

        lines.concat(gems_lines(:overview))
        lines.concat(architecture_lines(:overview))
        lines.concat(full_preset_stack_lines)
        lines.concat([ services_line("- Services: "), jobs_line("- Jobs: ") ].compact)
        if (filters = before_actions_line("**Global before_actions:** "))
          lines.push("", filters)
        end
        lines.compact
      end

      # Extract scope names from scope data (handles both Hash and String forms).
      def scope_names(scopes)
        scopes.map { |s| s.is_a?(Hash) ? s[:name] : s }
      end

      # Render a compact controllers listing: "- Name (N actions)" + "...X more".
      # Shared by cursor_rules and copilot_instructions serializers.
      # `with_actions:` names the actions instead of counting them - the
      # depth is the caller's choice, the rendering is not.
      def render_compact_controllers_list(controllers_hash, with_actions: false)
        limit = Budget.cap(:listed_controllers)
        lines = []
        controllers_hash.keys.sort.first(limit).each do |name|
          info = controllers_hash[name]
          if (unread = SectionFacts.unread_row(with_actions ? "- **#{name}**" : "- #{name}", info))
            lines << unread
            next
          end

          if with_actions
            actions = (info[:actions] || []).map { |a| a.is_a?(Hash) ? a[:name] : a }.compact
            lines << (actions.empty? ? "- **#{name}**" : Budget.list(actions, lead: "- **#{name}** - "))
          else
            action_count = info[:actions]&.size || 0
            lines << "- #{name} (#{count_phrase(action_count, "action")})"
          end
        end
        lines << Budget.more_row(controllers_hash.size - limit, "controller") if controllers_hash.size > limit
        lines
      end

      # Safely resolve architecture labels from GetConventions tool.
      def arch_labels_hash
        RailsAiContext::Tools::GetConventions::ARCH_LABELS rescue {}
      end

      def pattern_labels_hash
        RailsAiContext::Tools::GetConventions::PATTERN_LABELS rescue {}
      end

      # Render and write a serializer's whole rule-file table, each file under
      # the frontmatter its scope takes in this AI tool.
      # @param dir [String] directory the table's relative names hang off
      # @param table [Hash<String, Hash>] name => { renderer:, reason:, scope:, name:, exclude_agent:, kind: },
      #   reason, scope and name a value or the method that answers it, kind the Budget::BYTES one
      #   (a rule's, or the root file's for a rule that stands in for it)
      def write_rule_table(dir, table, root:, tool:)
        write_rule_files(
          table.map do |name, rule|
            RuleFile.new(File.join(dir, name), scoped(rule, tool), answer(rule[:reason]))
          end,
          root: root
        )
      end

      # The run's LoadPlan, or one for this rules serializer's AI tools alone
      # (its TOOLS) where it runs by itself.
      def plan
        @plan ||= LoadPlan.new(self.class::TOOLS)
      end

      # Whether a root file these AI tools read carries the root content, which
      # their overview and tools guide rules would state again.
      def rooted?
        self.class::TOOLS.any? { |key| plan.root_carries?(key) }
      end

      # The overview a rules file carries where no root file states it; the
      # guide rule beside it, loaded in every session too, says how to use the tools.
      def overview_rule
        return nil if rooted?

        [ *header_lines(:overview, title: "Overview"), *overview_lines ].join("\n")
      end

      def overview_reason
        rooted? ? "in the root file" : "nothing to document"
      end

      # The root file's guide, for a rules file that stands in for it.
      def guide_unless_rooted
        rooted? ? nil : render_tools_guide_compact.join("\n")
      end

      def scoped(rule, tool)
        body = send(rule[:renderer]) or return nil
        frontmatter = answer(rule.fetch(:scope)).frontmatter(tool, name: answer(rule[:name]), exclude_agent: rule[:exclude_agent])
        fit_rule(frontmatter, body, rule.fetch(:kind, :rule))
      end

      # A RULE_FILES value, or the method that answers it.
      def answer(value)
        value.is_a?(Symbol) ? send(value) : value
      end

      # A rule file's text within the Budget of its kind, or nil for no text.
      def fit_rule(head, body, kind)
        body && Budget.fit(head: head, body: body.split("\n", -1), keep: [], kind: kind, note: trim_note)
      end

      # What a file cut to its budget says where the cut is: the tools answer the rest.
      def trim_note
        "_Cut to fit: the #{tools_noun} answer the rest._"
      end

      # Write split-rule files with diff-check and atomic writes.
      # A nil render means the app has nothing to put in that file. It is
      # reported rather than dropped, so a deliberate omission never looks
      # like a failed generation, and one left from an earlier run is removed.
      #
      # A rules directory's names are the gem's own. `shared:` is for names
      # users write by hand too (OpenCode's app/models/AGENTS.md): a file
      # there the gem did not generate whole keeps its text and gets the
      # gem's block, as a root file does.
      # @param entries [Array<RuleFile>]
      # @return [Hash] { written:, skipped:, removed:, trimmed: [paths], not_applicable: { path => reason } }
      def write_rule_files(entries, root:, shared: false)
        result = { written: [], skipped: [], not_applicable: {}, removed: [], trimmed: [] }

        entries.each do |entry|
          # A file an earlier run wrote says what is no longer so, or what a
          # root file this tool reads now says, so it goes.
          if entry.content.nil? && (File.file?(entry.path) || File.symlink?(entry.path))
            SectionMarkerWriter.drop(entry.path, root: root, whole: !shared, result: result)
            next
          elsif entry.content.nil?
            result[:not_applicable][entry.path] = entry.reason || "nothing to document"
            next
          end

          outcome = if shared
            SectionMarkerWriter.write_whole_or_block(entry.path, entry.content, root: root)
          else
            SectionMarkerWriter.write_whole(entry.path, entry.content, root: root)
          end
          SectionMarkerWriter.report(outcome, entry.path, result)
        end

        result
      end

      def detect_test_command
        TestFramework.command(Payload.section(context, :tests)&.dig(:framework))
      end

      def project_root
        defined?(Rails) && Rails.respond_to?(:root) && Rails.root ? Rails.root.to_s : Dir.pwd
      end

      # Keyed by the context object: every serializer in one run shares it, and
      # a later run (watch, a new fingerprint) brings a new one.
      SERVICE_NAMES = ObjectSpace::WeakMap.new

      # The same scan rails_get_service_pattern lists from. Several files print the line and
      # a large app's scan takes most of a second, so a run pays for it once.
      def service_names(root = project_root)
        per_run = (SERVICE_NAMES[context] ||= {})
        per_run[root.to_s] ||= Introspectors::ServiceClasses.names(root).freeze
      end

      # The jobs and Sidekiq workers the introspector recorded, so this line
      # and rails_get_job_pattern name the same set.
      def job_names
        jobs = Payload.section(context, :jobs)
        return [] unless jobs

        (Array(jobs[:jobs]) + Array(jobs[:workers])).filter_map { |job| job[:name] if job.is_a?(Hash) }
      end

      # A large app's services take one line of a generated file, not kilobytes of it.
      # A cut list names the tool that has it whole.
      def names_line(names, lead, tool = nil)
        return nil if names.empty?

        pointer = tool && served?(tool) ? " (#{tool_ref(tool)})" : ""
        line = Budget.list(names, cap: Budget.cap(:names), lead: lead, width: Budget::LINE_WIDTH - pointer.size)
        line.end_with?(" more") ? line + pointer : line
      end

      def services_line(lead)
        names_line(service_names, lead, "rails_get_service_pattern")
      end

      def jobs_line(lead)
        names_line(job_names, lead, "rails_get_job_pattern")
      end

      # The filters ApplicationController runs on every request, through the
      # reader the chain walk uses, so this line and `rails_get_controllers`
      # cannot disagree about one file. "Global" is the claim the generated
      # files make, so a `skip_before_action` and a filter carrying
      # only:/except:/if:/unless: or an if around it are both out.
      def detect_before_actions(root = project_root)
        source = ActionFilters.base_controller_source("ApplicationController", root)
        return [] unless source

        Introspectors::ControllerFilters.with_concerns(source, root: root.to_s, within: "ApplicationController").first
          .select { |filter| filter[:kind] == "before" && !filter[:skipped] }
          .reject { |filter| filter[:only] || filter[:except] || filter[:if] || filter[:unless] || filter[:condition] }
          .map { |filter| filter[:name] }
      rescue => e
        RailsAiContext.debug_fail(e, [], label: "Before actions scan")
      end
    end
  end
end
