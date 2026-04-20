# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    # Inspects Rails security configuration NOT already covered by
    # `auth_introspector` (Devise/Pundit/etc). Captures the framework-level
    # controls: CSRF, force_ssl, HSTS, host_authorization, PermissionsPolicy,
    # ContentSecurityPolicy directives, cookie config, browser-version gates.
    # Covers RAILS_NERVOUS_SYSTEM.md §32 (Security layer).
    class SecurityIntrospector
      attr_reader :app

      def initialize(app)
        @app = app
      end

      def call
        {
          force_ssl: !!app.config.force_ssl,
          ssl_options: extract_ssl_options,
          host_authorization: extract_host_authorization,
          content_security_policy: extract_csp,
          permissions_policy: extract_permissions_policy,
          csrf: extract_csrf,
          cookies: extract_cookie_config,
          allow_browser: extract_allow_browser,
          signed_global_id: extract_signed_gid
        }
      rescue => e
        $stderr.puts "[rails-ai-context] SecurityIntrospector#call failed: #{e.message}" if ENV["DEBUG"]
        { error: e.message }
      end

      private

      def root
        app.root.to_s
      end

      def extract_ssl_options
        options = app.config.respond_to?(:ssl_options) ? app.config.ssl_options : nil
        return {} unless options.is_a?(Hash) && options.any?

        result = {}
        hsts = options[:hsts]
        if hsts.is_a?(Hash)
          result[:hsts] = hsts.slice(:expires, :subdomains, :preload).transform_values { |v| v.is_a?(ActiveSupport::Duration) ? v.to_s : v }
        elsif hsts == true || hsts == false
          result[:hsts] = hsts
        end
        result[:redirect] = options[:redirect] if options.key?(:redirect)
        result[:secure_cookies] = options[:secure_cookies] if options.key?(:secure_cookies)
        result
      rescue => e
        $stderr.puts "[rails-ai-context] extract_ssl_options failed: #{e.message}" if ENV["DEBUG"]
        {}
      end

      def extract_host_authorization
        hosts = app.config.respond_to?(:hosts) ? app.config.hosts : []
        exclude = app.config.respond_to?(:host_authorization) ? app.config.host_authorization : nil

        entry = { hosts: Array(hosts).map(&:to_s) }
        entry[:options] = exclude.keys.map(&:to_s) if exclude.is_a?(Hash) && exclude.any?
        entry
      rescue => e
        $stderr.puts "[rails-ai-context] extract_host_authorization failed: #{e.message}" if ENV["DEBUG"]
        { hosts: [] }
      end

      def extract_csp
        init_path = File.join(root, "config/initializers/content_security_policy.rb")
        return { configured: false } unless File.exist?(init_path)

        content = RailsAiContext::SafeFile.read(init_path) || ""
        directives = content.scan(/policy\.(\w+)\s+(:\w+(?:\s*,\s*:\w+)*|\*?['"][^'"]+['"])/).map { |dir, val| { directive: dir, value: val.strip } }
        report_only = content.match?(/config\.content_security_policy_report_only\s*=\s*true/)

        {
          configured: true,
          file: "config/initializers/content_security_policy.rb",
          report_only: report_only,
          directives: directives.first(30)
        }
      rescue => e
        $stderr.puts "[rails-ai-context] extract_csp failed: #{e.message}" if ENV["DEBUG"]
        { configured: false }
      end

      def extract_permissions_policy
        init_path = File.join(root, "config/initializers/permissions_policy.rb")
        return { configured: false } unless File.exist?(init_path)

        content = RailsAiContext::SafeFile.read(init_path) || ""
        directives = content.scan(/policy\.(\w+)\s+(:\w+(?:\s*,\s*:\w+)*)/).map { |feature, allowlist| { feature: feature, allowlist: allowlist.strip } }
        { configured: true, file: "config/initializers/permissions_policy.rb", directives: directives }
      rescue => e
        $stderr.puts "[rails-ai-context] extract_permissions_policy failed: #{e.message}" if ENV["DEBUG"]
        { configured: false }
      end

      def extract_csrf
        app_controller = File.join(root, "app/controllers/application_controller.rb")
        result = { default: "enabled" }
        return result unless File.exist?(app_controller)

        content = RailsAiContext::SafeFile.read(app_controller) or return result

        if (match = content.match(/protect_from_forgery\s+(.+)$/))
          result[:protect_from_forgery] = match[1].strip
        elsif content.include?("skip_forgery_protection")
          result[:default] = "skipped (skip_forgery_protection present)"
        end

        per_request_token = app.config.action_controller.respond_to?(:per_form_csrf_tokens) ? app.config.action_controller.per_form_csrf_tokens : nil
        result[:per_form_csrf_tokens] = !!per_request_token unless per_request_token.nil?

        origin_check = app.config.action_controller.respond_to?(:forgery_protection_origin_check) ? app.config.action_controller.forgery_protection_origin_check : nil
        result[:origin_check] = !!origin_check unless origin_check.nil?
        result
      rescue => e
        $stderr.puts "[rails-ai-context] extract_csrf failed: #{e.message}" if ENV["DEBUG"]
        { default: "unknown" }
      end

      def extract_cookie_config
        session = app.config.session_options
        result = {}
        if session.is_a?(Hash)
          [ :key, :secure, :httponly, :same_site, :domain, :path, :expire_after ].each do |key|
            result[key] = serializable(session[key]) if session.key?(key)
          end
        end
        result
      rescue => e
        $stderr.puts "[rails-ai-context] extract_cookie_config failed: #{e.message}" if ENV["DEBUG"]
        {}
      end

      # Rails 7.2 introduced `allow_browser` to block unsupported browsers.
      # Scan controllers for the declaration + any `versions:` argument.
      def extract_allow_browser
        controllers_dir = File.join(root, "app/controllers")
        return [] unless Dir.exist?(controllers_dir)

        findings = []
        # Cap at 2000 files + sort — matches pattern in active_support_introspector
        # and env_introspector. Determinism + bounded wall-clock on large apps.
        Dir.glob(File.join(controllers_dir, "**/*.rb")).sort.first(2000).each do |path|
          content = RailsAiContext::SafeFile.read(path) or next
          content.scan(/^\s*allow_browser\s+([^\n]+)/).each do |match|
            findings << { file: path.sub("#{root}/", ""), args: match[0].strip }
          end
        end
        findings
      rescue => e
        $stderr.puts "[rails-ai-context] extract_allow_browser failed: #{e.message}" if ENV["DEBUG"]
        []
      end

      def extract_signed_gid
        sgid_expiration = app.config.respond_to?(:global_id) && app.config.global_id.respond_to?(:expires_in) ? app.config.global_id.expires_in : nil
        { expires_in: sgid_expiration&.to_s }.compact
      rescue => e
        $stderr.puts "[rails-ai-context] extract_signed_gid failed: #{e.message}" if ENV["DEBUG"]
        {}
      end

      def serializable(value)
        case value
        when Symbol then value.to_s
        when Hash then value.transform_keys(&:to_s)
        when Array then value.map(&:to_s)
        else value
        end
      end
    end
  end
end
