# frozen_string_literal: true

module RailsAiContext
  module Serializers
    # Shared helper for rendering stack overview lines from full-preset introspectors.
    # Include in any serializer that has a `context` reader and renders a project overview.
    module StackOverviewHelper
      include CountPhrase

      # One rule file on its way to disk. The reason travels with the path it
      # explains; when it lived in a second hash keyed by the same path, an
      # entry missing from that hash lost its reason silently.
      RuleFile = Struct.new(:path, :content, :reason)

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
          lines << "- Storage: ActiveStorage (#{count_phrase(attachments.size, "model")} with attachments)"
        end

        rich_text = Payload.rich_text_fields(ctx)
        lines << "- RichText: ActionText (#{count_phrase(rich_text.size, "field")})" if rich_text.any?

        assets_line = SectionFacts.assets_line(ctx)
        lines << assets_line if assets_line

        engine_names = Payload.mounted_engines(ctx).map { |e| e[:engine] }.compact.first(5)
        lines << "- Engines: #{engine_names.join(', ')}" if engine_names.any?

        raw_databases = Payload.section(ctx, :multi_database)&.dig(:databases)
        db_list = raw_databases.is_a?(Hash) ? raw_databases.keys : Array(raw_databases)
        if db_list.size > 1
          db_names = db_list.map { |d| d.is_a?(Hash) ? d[:name] : d }
          lines << "- Databases: #{db_list.size} (#{db_names.first(3).join(', ')})"
        end

        components = Payload.section(ctx, :components)
        if components && components.dig(:summary, :total).to_i > 0
          summary = components[:summary]
          parts = [ count_phrase(summary[:total], "component") ]
          parts << count_phrase(summary[:view_component].to_i, "ViewComponent") if summary[:view_component].to_i > 0
          parts << "#{summary[:phlex]} Phlex" if summary[:phlex].to_i > 0
          lines << "- Components: #{parts.join(', ')}"
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

      # Extract scope names from scope data (handles both Hash and String forms).
      def scope_names(scopes)
        scopes.map { |s| s.is_a?(Hash) ? s[:name] : s }
      end

      # Render a compact controllers listing: "- Name (N actions)" + "...X more".
      # Shared by cursor_rules and copilot_instructions serializers.
      # `with_actions:` names the actions instead of counting them - the
      # depth is the caller's choice, the rendering is not.
      def render_compact_controllers_list(controllers_hash, limit: 25, with_actions: false)
        lines = []
        controllers_hash.keys.sort.first(limit).each do |name|
          info = controllers_hash[name]
          if with_actions
            actions = (info[:actions] || []).map { |a| a.is_a?(Hash) ? a[:name] : a }.compact
            line = "- **#{name}**"
            line += " - #{actions.join(', ')}" unless actions.empty?
            lines << line
          else
            action_count = info[:actions]&.size || 0
            lines << "- #{name} (#{count_phrase(action_count, "action")})"
          end
        end
        lines << "- ...#{controllers_hash.size - limit} more" if controllers_hash.size > limit
        lines
      end

      # Render scopes and constants as a one-line extras summary for a model entry.
      # Returns "  scopes: a, b | STATUS: draft, active" or nil if no extras exist.
      # Shared by cursor_rules, opencode_rules, copilot_instructions, compact_serializer_helper.
      def model_extras_line(data)
        scopes = data[:scopes] || []
        constants = data[:constants] || []
        return nil unless scopes.any? || constants.any?
        extras = []
        extras << "scopes: #{scope_names(scopes).join(', ')}" if scopes.any?
        constants.each { |c| extras << "#{c[:name]}: #{c[:values].join(', ')}" }
        "  #{extras.join(' | ')}"
      end

      # Safely resolve architecture labels from GetConventions tool.
      def arch_labels_hash
        RailsAiContext::Tools::GetConventions::ARCH_LABELS rescue {}
      end

      def pattern_labels_hash
        RailsAiContext::Tools::GetConventions::PATTERN_LABELS rescue {}
      end

      # Render and write a serializer's whole rule-file table.
      # @param dir [String] directory the table's relative names hang off
      # @param table [Hash<String, Hash>] name => { renderer:, reason: }
      def write_rule_table(dir, table)
        write_rule_files(
          table.map do |name, rule|
            RuleFile.new(File.join(dir, name), send(rule[:renderer]), rule[:reason])
          end
        )
      end

      # Write split-rule files with diff-check and atomic writes.
      # A nil render means the app has nothing to put in that file. It is
      # reported rather than dropped, so a deliberate omission never looks
      # like a failed generation.
      # @param entries [Array<RuleFile>]
      # @return [Hash] { written: [paths], skipped: [paths], not_applicable: { path => reason } }
      def write_rule_files(entries)
        written = []
        skipped = []
        not_applicable = {}

        entries.each do |entry|
          if entry.content.nil?
            not_applicable[entry.path] = entry.reason || "nothing to document"
            next
          end

          if File.exist?(entry.path) && File.read(entry.path) == entry.content
            skipped << entry.path
          else
            SafeFile.atomic_write(entry.path, entry.content)
            written << entry.path
          end
        end

        { written: written, skipped: skipped, not_applicable: not_applicable }
      end

      # Shared utility: resolve the project root directory.
      # Used by serializers that scan app/ for services, jobs, controllers, etc.
      def project_root
        defined?(Rails) && Rails.respond_to?(:root) && Rails.root ? Rails.root.to_s : Dir.pwd
      end

      # Scan app/services/ for service object class names. The root
      # parameter is the test seam - specs point it at a fixture tree.
      def detect_service_files(root = project_root)
        dir = File.join(root, "app", "services")
        return [] unless Dir.exist?(dir)
        Dir.glob(File.join(dir, "*.rb"))
          .map { |f| File.basename(f, ".rb").camelize }
          .reject { |s| s == "ApplicationService" }
      rescue => e
        $stderr.puts "[rails-ai-context] Service file scan skipped: #{e.message}" if ENV["DEBUG"]
        []
      end

      # Scan app/jobs/ for job class names.
      def detect_job_files(root = project_root)
        dir = File.join(root, "app", "jobs")
        return [] unless Dir.exist?(dir)
        Dir.glob(File.join(dir, "*.rb"))
          .map { |f| File.basename(f, ".rb").camelize }
          .reject { |j| j == "ApplicationJob" }
      rescue => e
        $stderr.puts "[rails-ai-context] Job file scan skipped: #{e.message}" if ENV["DEBUG"]
        []
      end

      # The filters ApplicationController runs on every request.
      #
      # "Global" is the claim the generated files make, so two shapes are not
      # it: `skip_before_action`, which says the opposite, and a filter carrying
      # only:/except:/if:/unless:, which runs on some requests.
      def detect_before_actions(root = project_root)
        app_ctrl_file = File.join(root, "app", "controllers", "application_controller.rb")
        return [] unless File.exist?(app_ctrl_file)

        File.read(app_ctrl_file).lines.filter_map do |line|
          match = line.match(/(?<!skip_)\bbefore_action\s+:(?<name>[\w!?]+)(?<rest>.*)/)
          next unless match
          next if match[:rest].match?(/\b(only|except|if|unless):/)

          match[:name]
        end
      rescue => e
        $stderr.puts "[rails-ai-context] Before actions scan skipped: #{e.message}" if ENV["DEBUG"]
        []
      end

      # One seam for every surface that names the database, so the generated
      # files, the tools and the rake task cannot answer differently for one
      # app. See RailsAiContext::SchemaAdapter.
      def database_adapter_label(_schema = nil)
        SchemaAdapter.label(context)
      end
    end
  end
end
