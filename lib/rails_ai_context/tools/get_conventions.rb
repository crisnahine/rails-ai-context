# frozen_string_literal: true

module RailsAiContext
  module Tools
    class GetConventions < BaseTool
      tool_name "rails_get_conventions"
      description "Detect app architecture and conventions: API-only vs Hotwire, design patterns, directory layout. " \
        "Use when: starting work on an unfamiliar codebase, choosing implementation patterns, or checking what frameworks are in use. " \
        "No parameters needed. Returns architecture style, detected patterns (STI, service objects), and notable config files."

      input_schema(properties: {})

      annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true, open_world_hint: false)

      def self.call(server_context: nil)
        conventions = cached_context[:conventions]
        return text_response("Convention detection not available. Add :conventions to introspectors.") unless conventions
        return text_response("Convention detection failed: #{conventions[:error]}") if conventions[:error]

        lines = [ "# App Conventions & Architecture", "" ]

        # Architecture
        if conventions[:architecture]&.any?
          lines << "## Architecture"
          conventions[:architecture].each { |a| lines << "- #{humanize_arch(a)}" }
        end

        # Patterns
        if conventions[:patterns]&.any?
          lines << "" << "## Detected patterns"
          conventions[:patterns].each { |p| lines << "- #{humanize_pattern(p)}" }
        end

        # Directory structure
        if conventions[:directory_structure]&.any?
          lines << "" << "## Directory structure"
          conventions[:directory_structure].sort_by { |k, _| k }.each do |dir, count|
            lines << "- `#{dir}/` → #{count} files"
          end
        end

        # Frontend stack from package.json
        frontend = detect_frontend_stack
        if frontend.any?
          lines << "" << "## Frontend stack"
          frontend.each { |f| lines << "- #{f}" }
        end

        # App-specific patterns detected from controller source
        app_patterns = detect_app_patterns
        if app_patterns.any?
          lines << "" << "## App Patterns"
          app_patterns.each { |section| lines << section }
        end

        # Custom directories
        if conventions[:custom_directories]&.any?
          lines << "" << "## Custom Directories"
          conventions[:custom_directories].each do |dir, desc|
            lines << "- `#{dir}/` — #{desc}"
          end
        end

        # Config files — only show non-obvious ones (skip files every Rails app has)
        if conventions[:config_files]&.any?
          obvious = %w[
            config/application.rb config/puma.rb config/locales/en.yml
            Gemfile package.json Rakefile
          ]
          notable = conventions[:config_files].reject { |f| obvious.include?(f) }
          if notable.any?
            lines << "" << "## Notable config files"
            notable.each { |f| lines << "- `#{f}`" }
          end
        end

        # I18n / Locale info
        locale_info = detect_locale_info
        if locale_info.any?
          lines << "" << "## I18n"
          locale_info.each { |l| lines << "- #{l}" }
        end

        # Convention Fingerprint — one-paragraph summary of the app's detected conventions
        fingerprint_parts = []
        fingerprint_parts << conventions[:architecture].map { |a| humanize_arch(a) }.join(", ") if conventions[:architecture]&.any?
        fingerprint_parts << conventions[:patterns].map { |p| humanize_pattern(p) }.join(", ") if conventions[:patterns]&.any?
        top_dirs = conventions[:directory_structure]&.sort_by { |_, v| -v }&.first(5)&.map { |k, _| k }
        fingerprint_parts << "key dirs: #{top_dirs.join(', ')}" if top_dirs&.any?
        if fingerprint_parts.any?
          lines << "" << "## Convention Fingerprint"
          lines << "This app uses #{fingerprint_parts.join('; ')}."
        end

        text_response(lines.join("\n"))
      end

      ARCH_LABELS = {
        "api_only" => "API-only mode (no views/assets)",
        "hotwire" => "Hotwire (Turbo + Stimulus)",
        "graphql" => "GraphQL API (app/graphql/)",
        "grape_api" => "Grape API framework (app/api/)",
        "service_objects" => "Service objects pattern (app/services/)",
        "form_objects" => "Form objects (app/forms/)",
        "query_objects" => "Query objects (app/queries/)",
        "presenters" => "Presenters/Decorators",
        "view_components" => "ViewComponent (app/components/)",
        "stimulus" => "Stimulus controllers (app/javascript/controllers/)",
        "importmaps" => "Import maps (no JS bundler)",
        "docker" => "Dockerized",
        "kamal" => "Kamal deployment",
        "ci_github_actions" => "GitHub Actions CI"
      }.freeze

      PATTERN_LABELS = {
        "sti" => "Single Table Inheritance (STI)",
        "polymorphic" => "Polymorphic associations",
        "soft_delete" => "Soft deletes (paranoia/discard)",
        "versioning" => "Model versioning/auditing",
        "state_machine" => "State machines (AASM/workflow)",
        "multi_tenancy" => "Multi-tenancy",
        "searchable" => "Full-text search (Searchkick/pg_search/Ransack)",
        "taggable" => "Tagging",
        "sluggable" => "Friendly URLs/slugs",
        "nested_set" => "Tree/nested set structures"
      }.freeze

      private_class_method def self.humanize_arch(key)
        ARCH_LABELS[key] || key.humanize
      end

      private_class_method def self.humanize_pattern(key)
        PATTERN_LABELS[key] || key.humanize
      end

      private_class_method def self.detect_frontend_stack
        pkg_path = Rails.root.join("package.json")
        return [] unless File.exist?(pkg_path)

        content = File.read(pkg_path) rescue ""
        stack = []

        # CSS frameworks
        stack << "Tailwind CSS" if content.include?("tailwindcss")
        stack << "Bootstrap" if content.include?("bootstrap")
        stack << "DaisyUI" if content.include?("daisyui")

        # JS bundlers
        stack << "esbuild" if content.include?("esbuild")
        stack << "Vite" if content.include?("vite")
        stack << "Webpack" if content.include?("webpack")

        # JS frameworks
        stack << "React" if content.include?("\"react\"")
        stack << "Vue" if content.include?("\"vue\"")
        stack << "Svelte" if content.include?("svelte")

        # Utilities
        stack << "TypeScript" if content.include?("typescript")
        stack << "Turbo" if content.include?("@hotwired/turbo")
        stack << "Stimulus" if content.include?("@hotwired/stimulus")

        # Package manager
        pm = detect_package_manager
        stack << "#{pm} (package manager)" if pm

        stack
      end

      private_class_method def self.detect_package_manager
        return "pnpm" if File.exist?(Rails.root.join("pnpm-lock.yaml"))
        return "yarn" if File.exist?(Rails.root.join("yarn.lock"))
        return "bun" if File.exist?(Rails.root.join("bun.lockb"))
        return "npm" if File.exist?(Rails.root.join("package-lock.json"))
        nil
      end

      # Scan controllers for app-specific authorization, flash, and error-handling patterns
      private_class_method def self.detect_app_patterns
        controllers_dir = Rails.root.join("app", "controllers")
        return [] unless Dir.exist?(controllers_dir)

        auth_checks = []
        auth_denials = []
        flash_notices = []
        flash_alerts = []
        not_found_patterns = []
        create_flows = []
        show_only_controllers = []
        has_services = Dir.exist?(Rails.root.join("app", "services"))

        Dir.glob(File.join(controllers_dir, "**", "*.rb")).each do |path|
          content = File.read(path, encoding: "UTF-8", invalid: :replace, undef: :replace) rescue next
          controller_name = File.basename(path, ".rb")

          # Authorization: can_*? method calls with redirect + alert
          content.scan(/\b(can_\w+\??)/).each do |match|
            auth_checks << match[0] unless auth_checks.include?(match[0])
          end

          # Authorization denials: redirect_to ... alert: "..."
          content.scan(/redirect_to\s+.+?,\s*alert:\s*"([^"]*)"/).each do |match|
            denial = "redirect_to ..., alert: \"#{match[0]}\""
            auth_denials << denial unless auth_denials.include?(denial)
          end

          # Flash notices: redirect_to ... notice: "..."
          content.scan(/notice:\s*"([^"]*)"/).each do |match|
            flash_notices << match[0] unless flash_notices.include?(match[0])
          end

          # Flash alerts: redirect_to ... alert: "..."
          content.scan(/alert:\s*"([^"]*)"/).each do |match|
            flash_alerts << match[0] unless flash_alerts.include?(match[0])
          end

          # Not-found handling: set_* methods that rescue or redirect on missing records
          content.scan(/def\s+(set_\w+).*?(?=\n\s*def\s|\n\s*end\s*\z)/m).each do |match_data|
            method_name = match_data[0]
            # Look for the block around this method for rescue/redirect
            if content.match?(/def\s+#{Regexp.escape(method_name)}.*?(?:rescue\s+ActiveRecord::RecordNotFound|rescue\b)/m)
              redirect_match = content.match(/def\s+#{Regexp.escape(method_name)}.*?redirect_to\s+(\S+)/m)
              target = redirect_match ? redirect_match[1].sub(/,.*/, "") : "..."
              not_found_patterns << "#{method_name} → rescue → redirect_to #{target}" unless not_found_patterns.include?("#{method_name} → rescue → redirect_to #{target}")
            end
          end

          # Create action flow detection
          if content.match?(/def\s+create\b/)
            create_block = content[/def\s+create\b.*?(?=\n\s{2}def\s|\n\s{2}private|\z)/m]
            if create_block
              flow_parts = []
              flow_parts << "permission check" if create_block.match?(/can_\w+\??|authorize|authorize!/)
              flow_parts << "build" if create_block.match?(/\.new\(|\.build\(|\.create\(/)
              flow_parts << "save" if create_block.match?(/\.save\b|\.create\b/)
              flow_parts << "redirect/render" if create_block.match?(/redirect_to|render\b/)
              if flow_parts.size >= 2
                create_flows << "#{controller_name.camelize}: #{flow_parts.join(' → ')}"
              end
            end
          end

          # Read-only page detection: controllers with show but no create/update/destroy
          has_show = content.match?(/def\s+show\b/)
          has_write = content.match?(/def\s+(create|update|destroy)\b/)
          if has_show && !has_write
            show_only_controllers << controller_name.camelize.sub(/Controller$/, "")
          end
        end

        sections = []

        if auth_checks.any? || auth_denials.any?
          sections << "" << "### Authorization"
          auth_checks.first(5).each { |c| sections << "- Check: `#{c}`" }
          auth_denials.first(5).each { |d| sections << "- Deny: #{d}" }
        end

        if flash_notices.any? || flash_alerts.any?
          sections << "" << "### Flash Messages"
          flash_notices.first(5).each { |n| sections << "- Success: notice: \"#{n}\"" }
          flash_alerts.first(5).each { |a| sections << "- Failure: alert: \"#{a}\"" }
        end

        if not_found_patterns.any?
          sections << "" << "### Error Handling"
          not_found_patterns.first(5).each { |p| sections << "- Not found: #{p}" }
        end

        if create_flows.any?
          sections << "" << "### Create Action Pattern (follow this for new actions)"
          sections << "```ruby"
          sections << "def create"
          sections << "  unless current_user.can_[permission]?"
          sections << '    redirect_to [path], alert: "[limit message]"'
          sections << "    return"
          sections << "  end"
          sections << ""
          sections << "  @record = current_user.[association].build([params_method])"
          sections << ""
          sections << "  if @record.save"
          sections << '    redirect_to @record, notice: "[success message]"'
          sections << "  else"
          sections << "    @[collection] = current_user.[association].[scope]"
          sections << "    render :new, status: :unprocessable_entity"
          sections << "  end"
          sections << "end"
          sections << "```"
          sections << ""
          sections << "Detected in: #{create_flows.map { |f| f.split(':').first }.join(', ')}"
        end

        if show_only_controllers.any?
          sections << "" << "### Read-Only Page Pattern (follow this for dashboard/analytics/report pages)"
          sections << "```ruby"
          sections << "# Route: get \"analytics\", to: \"analytics#show\""
          sections << "#"
          sections << "class AnalyticsController < ApplicationController"
          sections << "  def show"
          sections << "    @records = current_user.[association].[scope]"
          sections << "    @stats = current_user.[association].[aggregation]"
          sections << "  end"
          sections << "end"
          sections << "```"
          sections << ""
          sections << "Detected in: #{show_only_controllers.join(', ')}"
        end

        # Test pattern detection
        test_pattern = detect_test_pattern
        sections.concat(test_pattern) if test_pattern.any?

        if has_services
          service_files = Dir.glob(Rails.root.join("app", "services", "**", "*.rb"))
          if service_files.any?
            sections << "" << "### Service Objects"
            service_files.first(10).each do |sf|
              rel = sf.sub("#{Rails.root}/", "")
              sections << "- `#{rel}`"
            end
          end
        end

        sections
      rescue => e
        [] # Graceful degradation — never break the tool
      end

      private_class_method def self.detect_locale_info
        info = []
        locales_dir = Rails.root.join("config", "locales")
        return info unless Dir.exist?(locales_dir)

        locale_files = Dir.glob(File.join(locales_dir, "**", "*.{yml,yaml,rb}"))
        locales = locale_files.map { |f| File.basename(f, ".*").split(".").first }.uniq.sort

        return info if locales.empty?

        info << "**Locales:** #{locales.join(', ')} (#{locales.size} total)"

        # Detect default locale from config
        app_config = Rails.root.join("config", "application.rb")
        if File.exist?(app_config)
          content = File.read(app_config, encoding: "UTF-8", invalid: :replace, undef: :replace) rescue ""
          if (match = content.match(/config\.i18n\.default_locale\s*=\s*[:"'](\w+)/))
            info << "**Default locale:** #{match[1]}"
          end
        end

        # Detect primary UI language by sampling flash messages from controllers
        controllers_dir = Rails.root.join("app", "controllers")
        if Dir.exist?(controllers_dir)
          samples = []
          Dir.glob(File.join(controllers_dir, "**", "*.rb")).first(10).each do |path|
            content = File.read(path, encoding: "UTF-8", invalid: :replace, undef: :replace) rescue next
            content.scan(/(?:notice|alert|flash\[:\w+\]):\s*"([^"]+)"/).each { |m| samples << m[0] }
          end
          if samples.any?
            # Check if majority contains non-ASCII (CJK, Korean, etc.)
            non_ascii = samples.count { |s| s.match?(/[^\x00-\x7F]/) }
            ratio = non_ascii.to_f / samples.size
            if ratio > 0.5
              if samples.any? { |s| s.match?(/[\uAC00-\uD7AF]/) }
                info << "**Primary UI language:** Korean (detected from flash messages)"
              elsif samples.any? { |s| s.match?(/[\u4E00-\u9FFF]/) }
                info << "**Primary UI language:** Chinese (detected from flash messages)"
              elsif samples.any? { |s| s.match?(/[\u3040-\u309F\u30A0-\u30FF]/) }
                info << "**Primary UI language:** Japanese (detected from flash messages)"
              else
                info << "**Primary UI language:** non-English (detected from flash messages)"
              end
            end
          end
        end

        info
      rescue => e
        $stderr.puts "[rails-ai-context] detect_locale_info failed: #{e.message}" if ENV["DEBUG"]
        []
      end

      private_class_method def self.detect_test_pattern
        sections = []
        test_dir = Rails.root.join("test", "controllers")
        return sections unless Dir.exist?(test_dir)

        test_files = Dir.glob(File.join(test_dir, "**", "*_test.rb"))
        return sections if test_files.empty?

        has_devise = false
        has_sign_in = false
        has_assert_select = false
        has_assert_response = false
        has_auth_test = false
        detected_in = []

        test_files.first(5).each do |path|
          content = File.read(path, encoding: "UTF-8", invalid: :replace, undef: :replace) rescue next
          has_devise = true if content.include?("Devise::Test::IntegrationHelpers")
          has_sign_in = true if content.include?("sign_in")
          has_assert_select = true if content.include?("assert_select")
          has_assert_response = true if content.include?("assert_response")
          has_auth_test = true if content.match?(/requires?\s+authentication/i)
          detected_in << File.basename(path, ".rb").camelize.sub(/Test$/, "")
        end

        return sections unless has_assert_response

        sections << "" << "### Controller Test Pattern (follow this for new tests)"
        sections << "```ruby"
        sections << "require \"test_helper\""
        sections << ""
        sections << "class [Feature]ControllerTest < ActionDispatch::IntegrationTest"
        sections << "  include Devise::Test::IntegrationHelpers" if has_devise
        sections << ""
        if has_auth_test
          sections << "  test \"requires authentication\" do"
          sections << "    get [path]"
          sections << "    assert_response :redirect"
          sections << "  end"
          sections << ""
        end
        sections << "  test \"[action] renders page\" do"
        sections << "    sign_in users(:chef_one)" if has_sign_in
        sections << "    get [path]"
        sections << "    assert_response :success"
        sections << "    assert_select \"h1\", \"[Expected Title]\"" if has_assert_select
        sections << "  end"
        sections << "end"
        sections << "```"
        sections << ""
        sections << "Detected from: #{detected_in.first(3).join(', ')}"

        sections
      rescue => e
        $stderr.puts "[rails-ai-context] detect_test_pattern failed: #{e.message}" if ENV["DEBUG"]
        []
      end
    end
  end
end
