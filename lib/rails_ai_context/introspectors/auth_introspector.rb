# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    # Discovers authentication and authorization setup: Devise, Rails 8 auth,
    # Pundit, CanCanCan, CORS, CSP.
    class AuthIntrospector
      attr_reader :app

      def initialize(app)
        @app = app
      end

      def call
        {
          authentication: detect_authentication,
          authorization: detect_authorization,
          security: detect_security,
          devise_modules_per_model: detect_devise_modules_per_model,
          token_auth: detect_token_auth
        }
      rescue => e
        { error: e.message }
      end

      private

      def root
        app.root.to_s
      end

      def detect_authentication
        auth = {}

        # Devise
        devise_models = scan_models_for(/devise\s+(.+)$/)
        auth[:devise] = devise_models if devise_models.any?

        # Rails 8 built-in auth
        if file_exists?("app/models/session.rb") && file_exists?("app/models/current.rb")
          auth[:rails_auth] = true
        end

        # has_secure_password
        secure_pw = scan_models_for(/has_secure_password/)
        auth[:has_secure_password] = secure_pw.map { |m| m[:model] } if secure_pw.any?

        auth
      end

      def detect_authorization
        authz = {}

        # Pundit
        policies_dir = File.join(root, "app/policies")
        if Dir.exist?(policies_dir)
          policies = Dir.glob(File.join(policies_dir, "**/*.rb")).map do |f|
            File.basename(f, ".rb").camelize
          end.sort
          authz[:pundit] = policies if policies.any?
        end

        # CanCanCan
        ability_path = File.join(root, "app/models/ability.rb")
        authz[:cancancan] = true if File.exist?(ability_path)

        authz
      end

      def detect_security
        security = {}

        # CORS
        if gem_present?("rack-cors")
          cors_init = File.join(root, "config/initializers/cors.rb")
          security[:cors] = { configured: File.exist?(cors_init) }
        end

        # CSP
        csp_init = File.join(root, "config/initializers/content_security_policy.rb")
        security[:csp] = true if File.exist?(csp_init)

        security
      end

      def detect_devise_modules_per_model
        models_dir = File.join(root, "app/models")
        return {} unless Dir.exist?(models_dir)

        result = {}
        Dir.glob(File.join(models_dir, "**/*.rb")).each do |path|
          content = File.read(path) rescue next
          next unless content.match?(/\bdevise\b/)

          model_name = File.basename(path, ".rb").camelize
          # Extract devise modules, handling multiline declarations with trailing commas
          # Join continuation lines (lines starting with whitespace + colon after a line ending with comma)
          devise_block = content.scan(/devise\s+((?:.*,\s*\n)*.*?)$/m).flatten.first
          next unless devise_block

          modules = devise_block.scan(/:(\w+)/).flatten
          result[model_name] = modules if modules.any?
        end

        result
      rescue => e
        $stderr.puts "[rails-ai-context] detect_devise_modules_per_model failed: #{e.message}" if ENV["DEBUG"]
        {}
      end

      def detect_token_auth
        token_auth = {}

        token_auth[:devise_jwt] = detect_devise_jwt
        token_auth[:doorkeeper] = detect_doorkeeper
        token_auth[:http_token_auth] = detect_http_token_auth

        token_auth
      rescue => e
        $stderr.puts "[rails-ai-context] detect_token_auth failed: #{e.message}" if ENV["DEBUG"]
        {}
      end

      def detect_devise_jwt
        return { detected: false } unless gem_present?("devise-jwt")

        devise_init = File.join(root, "config/initializers/devise.rb")
        if File.exist?(devise_init)
          content = File.read(devise_init)
          return { detected: true, jwt_configured: content.match?(/config\.jwt\b/) }
        end

        { detected: true }
      rescue => e
        $stderr.puts "[rails-ai-context] detect_devise_jwt failed: #{e.message}" if ENV["DEBUG"]
        { detected: false }
      end

      def detect_doorkeeper
        return nil unless gem_present?("doorkeeper")

        doorkeeper_init = File.join(root, "config/initializers/doorkeeper.rb")
        return { detected: true } unless File.exist?(doorkeeper_init)

        content = File.read(doorkeeper_init)

        grant_flows = content.scan(/grant_flows\s+%w\[([^\]]+)\]/).flatten.first
        grant_flows = grant_flows&.split&.map(&:strip)

        expires_in = content.match(/access_token_expires_in\s+(\S+)/)&.send(:[], 1)

        result = { detected: true }
        result[:grant_flows] = grant_flows if grant_flows
        result[:access_token_expires_in] = expires_in if expires_in
        result
      rescue => e
        $stderr.puts "[rails-ai-context] detect_doorkeeper failed: #{e.message}" if ENV["DEBUG"]
        nil
      end

      def detect_http_token_auth
        controllers_dir = File.join(root, "app/controllers")
        return [] unless Dir.exist?(controllers_dir)

        Dir.glob(File.join(controllers_dir, "**/*.rb")).filter_map do |path|
          content = File.read(path) rescue next
          if content.match?(/authenticate_with_http_token|authenticate_or_request_with_http_token/)
            path.sub("#{root}/", "")
          end
        end.sort
      rescue => e
        $stderr.puts "[rails-ai-context] detect_http_token_auth failed: #{e.message}" if ENV["DEBUG"]
        []
      end

      def scan_models_for(pattern)
        models_dir = File.join(root, "app/models")
        return [] unless Dir.exist?(models_dir)

        results = []
        Dir.glob(File.join(models_dir, "**/*.rb")).each do |path|
          content = File.read(path)
          matches = content.scan(pattern)
          next if matches.empty?

          model_name = File.basename(path, ".rb").camelize
          results << { model: model_name, matches: matches.flatten.map(&:strip) }
        end
        results.sort_by { |r| r[:model] }
      rescue => e
        $stderr.puts "[rails-ai-context] scan_models_for failed: #{e.message}" if ENV["DEBUG"]
        []
      end

      def gem_present?(name)
        lock_path = File.join(root, "Gemfile.lock")
        return false unless File.exist?(lock_path)
        File.read(lock_path).include?("    #{name} (")
      rescue => e
        $stderr.puts "[rails-ai-context] gem_present? failed: #{e.message}" if ENV["DEBUG"]
        false
      end

      def file_exists?(relative_path)
        File.exist?(File.join(root, relative_path))
      end
    end
  end
end
