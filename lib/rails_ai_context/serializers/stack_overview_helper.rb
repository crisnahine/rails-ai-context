# frozen_string_literal: true

module RailsAiContext
  module Serializers
    # Shared helper for rendering stack overview lines from full-preset introspectors.
    # Include in any serializer that has a `context` reader and renders a project overview.
    module StackOverviewHelper
      include CountPhrase

      # Returns an array of summary lines for full-preset introspectors.
      # Each line is only added if the introspector returned meaningful data.
      def full_preset_stack_lines(ctx = context)
        lines = []

        if (auth = Payload.section(ctx, :auth))
          parts = []
          parts << "Devise" if auth.dig(:authentication, :devise)&.any?
          parts << "Rails 8 auth" if auth.dig(:authentication, :rails_auth)
          parts << "Pundit" if auth.dig(:authorization, :pundit)&.any?
          parts << "CanCanCan" if auth.dig(:authorization, :cancancan)
          lines << "- Auth: #{parts.join(' + ')}" if parts.any?
        end

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

        locales = Payload.available_locales(ctx)
        lines << "- I18n: #{count_phrase(locales.size, "locale")} (#{locales.first(5).join(', ')})" if locales.size > 1

        attachments = Payload.storage_attachments(ctx)
        if attachments.any?
          lines << "- Storage: ActiveStorage (#{count_phrase(attachments.size, "model")} with attachments)"
        end

        rich_text = Payload.rich_text_fields(ctx)
        lines << "- RichText: ActionText (#{count_phrase(rich_text.size, "field")})" if rich_text.any?

        if (assets = Payload.section(ctx, :assets))
          parts = []
          parts << assets[:pipeline] if assets[:pipeline]
          parts << assets[:js_bundler] if assets[:js_bundler]
          parts << assets[:css_framework] if assets[:css_framework]
          lines << "- Assets: #{parts.join(', ')}" if parts.any?
        end

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

      # Extract notable gems with triple-fallback for varying introspector output shapes.
      def notable_gems_list(gems_data)
        return [] unless gems_data.is_a?(Hash) && !gems_data[:error]
        gems_data[:notable_gems] || gems_data[:notable] || gems_data[:detected] || []
      end

      # Safely resolve architecture labels from GetConventions tool.
      def arch_labels_hash
        RailsAiContext::Tools::GetConventions::ARCH_LABELS rescue {}
      end

      def pattern_labels_hash
        RailsAiContext::Tools::GetConventions::PATTERN_LABELS rescue {}
      end

      # Write split-rule files with diff-check and atomic writes.
      # @param files [Hash<String, String|nil>] filepath => content mapping
      # @return [Hash] { written: [paths], skipped: [paths] }
      def write_rule_files(files)
        written = []
        skipped = []

        files.each do |filepath, content|
          next unless content
          if File.exist?(filepath) && File.read(filepath) == content
            skipped << filepath
          else
            dir = File.dirname(filepath)
            FileUtils.mkdir_p(dir)
            tmp = File.join(dir, ".#{File.basename(filepath)}.#{SecureRandom.hex(4)}.tmp")
            File.write(tmp, content)
            File.rename(tmp, filepath)
            written << filepath
          end
        end

        { written: written, skipped: skipped }
      end

      # Shared utility: resolve the project root directory.
      # Used by serializers that scan app/ for services, jobs, controllers, etc.
      def project_root
        defined?(Rails) && Rails.respond_to?(:root) && Rails.root ? Rails.root.to_s : Dir.pwd
      end

      # Scan app/services/ for service object class names.
      def detect_service_files
        dir = File.join(project_root, "app", "services")
        return [] unless Dir.exist?(dir)
        Dir.glob(File.join(dir, "*.rb"))
          .map { |f| File.basename(f, ".rb").camelize }
          .reject { |s| s == "ApplicationService" }
      rescue => e
        $stderr.puts "[rails-ai-context] Service file scan skipped: #{e.message}" if ENV["DEBUG"]
        []
      end

      # Scan app/jobs/ for job class names.
      def detect_job_files
        dir = File.join(project_root, "app", "jobs")
        return [] unless Dir.exist?(dir)
        Dir.glob(File.join(dir, "*.rb"))
          .map { |f| File.basename(f, ".rb").camelize }
          .reject { |j| j == "ApplicationJob" }
      rescue => e
        $stderr.puts "[rails-ai-context] Job file scan skipped: #{e.message}" if ENV["DEBUG"]
        []
      end

      # Extract before_action names from ApplicationController source.
      def detect_before_actions
        app_ctrl_file = File.join(project_root, "app", "controllers", "application_controller.rb")
        return [] unless File.exist?(app_ctrl_file)
        File.read(app_ctrl_file).scan(/before_action\s+:([\w!?]+)/).flatten
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
