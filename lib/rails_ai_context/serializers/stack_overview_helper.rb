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

        auth = ctx[:auth]
        if auth.is_a?(Hash) && !auth[:error]
          parts = []
          parts << "Devise" if auth.dig(:authentication, :devise)&.any?
          parts << "Rails 8 auth" if auth.dig(:authentication, :rails_auth)
          parts << "Pundit" if auth.dig(:authorization, :pundit)&.any?
          parts << "CanCanCan" if auth.dig(:authorization, :cancancan)
          lines << "- Auth: #{parts.join(' + ')}" if parts.any?
        end

        turbo = ctx[:turbo]
        if turbo.is_a?(Hash) && !turbo[:error]
          parts = []
          parts << count_phrase((turbo[:frames] || []).size, "frame") if turbo[:frames]&.any?
          parts << count_phrase((turbo[:streams] || []).size, "stream") if turbo[:streams]&.any?
          parts << "broadcasts" if turbo[:broadcasts]&.any?
          lines << "- Hotwire: #{parts.join(', ')}" if parts.any?
        end

        api = ctx[:api]
        if api.is_a?(Hash) && !api[:error]
          parts = []
          parts << "API-only" if api[:api_only]
          parts << count_phrase((api[:versions] || []).size, "version") if api[:versions]&.any?
          parts << "GraphQL" if api[:graphql]&.any?
          parts << api[:serializer_library] if api[:serializer_library]
          lines << "- API: #{parts.join(', ')}" if parts.any?
        end

        i18n_data = ctx[:i18n]
        if i18n_data.is_a?(Hash) && !i18n_data[:error]
          locales = i18n_data[:available_locales] || []
          lines << "- I18n: #{count_phrase(locales.size, "locale")} (#{locales.first(5).join(', ')})" if locales.size > 1
        end

        storage = ctx[:active_storage]
        if storage.is_a?(Hash) && !storage[:error] && storage[:attachments]&.any?
          lines << "- Storage: ActiveStorage (#{count_phrase(storage[:attachments].size, "model")} with attachments)"
        end

        action_text = ctx[:action_text]
        if action_text.is_a?(Hash) && !action_text[:error] && action_text[:rich_text_fields]&.any?
          lines << "- RichText: ActionText (#{count_phrase(action_text[:rich_text_fields].size, "field")})"
        end

        assets = ctx[:assets]
        if assets.is_a?(Hash) && !assets[:error]
          parts = []
          parts << assets[:pipeline] if assets[:pipeline]
          parts << assets[:js_bundler] if assets[:js_bundler]
          parts << assets[:css_framework] if assets[:css_framework]
          lines << "- Assets: #{parts.join(', ')}" if parts.any?
        end

        engines = ctx[:engines]
        if engines.is_a?(Hash) && !engines[:error] && engines[:mounted]&.any?
          names = engines[:mounted].map { |e| e[:name] || e[:engine] }.compact.first(5)
          lines << "- Engines: #{names.join(', ')}" if names.any?
        end

        multi_db = ctx[:multi_database]
        if multi_db.is_a?(Hash) && !multi_db[:error] && multi_db[:databases]&.size.to_i > 1
          db_names = multi_db[:databases].is_a?(Array) ? multi_db[:databases].map { |d| d[:name] } : multi_db[:databases].keys
          lines << "- Databases: #{multi_db[:databases].size} (#{db_names.first(3).join(', ')})"
        end

        components = ctx[:components]
        if components.is_a?(Hash) && !components[:error] && components.dig(:summary, :total).to_i > 0
          summary = components[:summary]
          parts = [ count_phrase(summary[:total], "component") ]
          parts << count_phrase(summary[:view_component].to_i, "ViewComponent") if summary[:view_component].to_i > 0
          parts << "#{summary[:phlex]} Phlex" if summary[:phlex].to_i > 0
          lines << "- Components: #{parts.join(', ')}"
        end

        perf = ctx[:performance]
        if perf.is_a?(Hash) && !perf[:error] && perf[:summary]
          total = perf.dig(:summary, :total_issues).to_i
          lines << "- Performance: #{count_phrase(total, "issue")} detected" if total > 0
        end

        fe = ctx[:frontend_frameworks]
        if fe.is_a?(Hash) && !fe[:error]
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
      def render_compact_controllers_list(controllers_hash, limit: 25)
        lines = []
        controllers_hash.keys.sort.first(limit).each do |name|
          info = controllers_hash[name]
          action_count = info[:actions]&.size || 0
          lines << "- #{name} (#{count_phrase(action_count, "action")})"
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

      # `static_parse` is the marker SchemaIntrospector sets when it read
      # db/schema.rb instead of the connection. It is an internal detail, and
      # printing it as the database taught every generated file that the app
      # runs on something called static_parse. onboard already substitutes the
      # live adapter; the generated files did not.
      def database_adapter_label(schema)
        adapter = schema[:adapter]
        return adapter unless adapter.nil? || adapter == "static_parse" || adapter == "unknown"

        config = context[:config]
        live = SectionGuard.usable?(config) ? (config[:database_adapter] || config[:adapter]) : nil
        live && !live.to_s.empty? ? live : "unknown"
      end
    end
  end
end
