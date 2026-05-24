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
        devise_models = scan_models_for_devise
        auth[:devise] = devise_models if devise_models.any?

        # Rails 8 built-in auth (`bin/rails generate authentication`)
        rails_auth = detect_rails_auth
        auth[:rails_auth] = rails_auth if rails_auth

        # has_secure_password
        secure_pw = scan_models_for_macro(:has_secure_password)
        auth[:has_secure_password] = secure_pw.map { |m| m[:model] } if secure_pw.any?

        # OmniAuth providers
        omniauth = detect_omniauth_providers
        auth[:omniauth_providers] = omniauth if omniauth.any?

        # Devise settings (timeout, lockout, etc.)
        devise_settings = extract_devise_settings
        auth[:devise_settings] = devise_settings unless devise_settings.empty?

        auth
      end

      # Rails 8's `bin/rails generate authentication` produces a Session model,
      # a Current attributes model, an Authentication concern in app/controllers/concerns,
      # a SessionsController, and a PasswordsController. AI agents need to know:
      #
      #   1. that this app uses the built-in pattern (not Devise / not custom)
      #   2. which controllers opt out via `allow_unauthenticated_access`
      #   3. where the Authentication concern lives so they can find before_actions
      def detect_rails_auth
        return nil unless file_exists?("app/models/session.rb") && file_exists?("app/models/current.rb")

        result = { detected: true }

        result[:authentication_concern] = "app/controllers/concerns/authentication.rb" if file_exists?("app/controllers/concerns/authentication.rb")
        result[:sessions_controller]    = "app/controllers/sessions_controller.rb"     if file_exists?("app/controllers/sessions_controller.rb")
        result[:passwords_controller]   = "app/controllers/passwords_controller.rb"    if file_exists?("app/controllers/passwords_controller.rb")

        unauth = scan_allow_unauthenticated_access
        result[:allow_unauthenticated_access] = unauth if unauth.any?

        result
      rescue => e
        $stderr.puts "[rails-ai-context] detect_rails_auth failed: #{e.message}" if ENV["DEBUG"]
        nil
      end

      def scan_allow_unauthenticated_access
        controllers_dir = File.join(root, "app/controllers")
        return [] unless Dir.exist?(controllers_dir)

        Dir.glob(File.join(controllers_dir, "**/*.rb")).flat_map do |path|
          ast = SourceIntrospector.walk(path, { macros: -> { Listeners::GenericMacroListener.new(:allow_unauthenticated_access) } })
          hits = ast[:macros]
          next [] if hits.empty?

          relative = path.sub("#{root}/", "")
          hits.map do |hit|
            opts = hit[:options] || {}
            if opts.empty?
              { file: relative, scope: "all actions" }
            else
              scope_parts = opts.map { |k, v| "#{k}: #{format_scope_value(v)}" }
              { file: relative, scope: scope_parts.join(", ") }
            end
          end
        end.compact.sort_by { |h| h[:file] }
      rescue => e
        $stderr.puts "[rails-ai-context] scan_allow_unauthenticated_access failed: #{e.message}" if ENV["DEBUG"]
        []
      end

      # Format a scope value extracted by the AST listener (symbol, array of
      # symbols, or arbitrary value) into the string form the tests expect.
      def format_scope_value(value)
        case value
        when Array
          "%i[#{value.map { |v| v.to_s.delete_prefix(":") }.join(" ")}]"
        when Symbol
          ":#{value}"
        else
          value.to_s
        end
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
          ast = SourceIntrospector.walk(path, { devise: -> { Listeners::GenericMacroListener.new(:devise) } })
          hits = ast[:devise]
          next if hits.empty?

          model_name = File.basename(path, ".rb").camelize
          modules = hits.flat_map { |h| h[:args].map(&:to_s) }
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
          content = RailsAiContext::SafeFile.read(devise_init)
          return { detected: true, jwt_configured: content&.match?(/config\.jwt\b/) || false }
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

        content = RailsAiContext::SafeFile.read(doorkeeper_init)
        return { detected: true } unless content

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
          ast = SourceIntrospector.walk(path, {
            token: -> { Listeners::GenericMacroListener.new(:authenticate_with_http_token, :authenticate_or_request_with_http_token) }
          })
          next if ast[:token].empty?
          path.sub("#{root}/", "")
        end.sort
      rescue => e
        $stderr.puts "[rails-ai-context] detect_http_token_auth failed: #{e.message}" if ENV["DEBUG"]
        []
      end

      def detect_omniauth_providers
        providers = []

        # Scan initializers for config.omniauth and provider calls
        initializers = Dir.glob(File.join(app.root, "config", "initializers", "*.rb"))
        initializers.each do |path|
          ast = SourceIntrospector.walk(path, {
            omniauth: -> { Listeners::ChainedCallListener.new(:omniauth) },
            provider: -> { Listeners::GenericMacroListener.new(:provider) }
          })
          ast[:omniauth].each do |hit|
            hit[:args].each { |a| providers << a.to_s }
          end
          ast[:provider].each do |hit|
            hit[:args].each { |a| providers << a.to_s unless a.to_s == "developer" }
          end
        end

        # Also check model files for devise omniauth_providers option
        models_dir = File.join(app.root, "app", "models")
        if Dir.exist?(models_dir)
          Dir.glob(File.join(models_dir, "**", "*.rb")).each do |path|
            ast = SourceIntrospector.walk(path, { devise: -> { Listeners::GenericMacroListener.new(:devise) } })
            ast[:devise].each do |hit|
              op_val = hit[:options][:omniauth_providers]
              next unless op_val.is_a?(Array)
              op_val.each { |p| providers << p.to_s }
            end
          end
        end

        providers.uniq
      rescue => e
        $stderr.puts "[rails-ai-context] detect_omniauth_providers failed: #{e.message}" if ENV["DEBUG"]
        []
      end

      def extract_devise_settings
        path = File.join(app.root, "config", "initializers", "devise.rb")
        return {} unless File.exist?(path)
        content = RailsAiContext::SafeFile.read(path)
        return {} unless content

        settings = {}
        settings[:timeout_in] = $1 if content.match(/config\.timeout_in\s*=\s*(\S+)/)
        settings[:lock_strategy] = $1 if content.match(/config\.lock_strategy\s*=\s*:(\w+)/)
        settings[:maximum_attempts] = $1.to_i if content.match(/config\.maximum_attempts\s*=\s*(\d+)/)
        settings[:unlock_strategy] = $1 if content.match(/config\.unlock_strategy\s*=\s*:(\w+)/)
        settings[:password_length] = $1 if content.match(/config\.password_length\s*=\s*(\S+)/)
        settings.empty? ? {} : settings
      rescue => e
        $stderr.puts "[rails-ai-context] extract_devise_settings failed: #{e.message}" if ENV["DEBUG"]
        {}
      end

      def scan_models_for_devise
        models_dir = File.join(root, "app/models")
        return [] unless Dir.exist?(models_dir)

        results = []
        Dir.glob(File.join(models_dir, "**/*.rb")).each do |path|
          ast = SourceIntrospector.walk(path, { devise: -> { Listeners::GenericMacroListener.new(:devise) } })
          next if ast[:devise].empty?

          model_name = File.basename(path, ".rb").camelize
          # Format matches the same way the old regex did: ":<module>, :<module>, ..."
          matches = ast[:devise].map { |h| h[:args].map { |a| ":#{a}" }.join(", ") }
          results << { model: model_name, matches: matches }
        end
        results.sort_by { |r| r[:model] }
      rescue => e
        $stderr.puts "[rails-ai-context] scan_models_for_devise failed: #{e.message}" if ENV["DEBUG"]
        []
      end

      def scan_models_for_macro(macro_name)
        models_dir = File.join(root, "app/models")
        return [] unless Dir.exist?(models_dir)

        results = []
        Dir.glob(File.join(models_dir, "**/*.rb")).each do |path|
          ast = SourceIntrospector.walk(path, { macros: Listeners::MacrosListener })
          hits = ast[:macros].select { |m| m[:macro] == macro_name }
          next if hits.empty?

          model_name = File.basename(path, ".rb").camelize
          results << { model: model_name }
        end
        results.sort_by { |r| r[:model] }
      rescue => e
        $stderr.puts "[rails-ai-context] scan_models_for_macro failed: #{e.message}" if ENV["DEBUG"]
        []
      end

      def gem_present?(name)
        lock_path = File.join(root, "Gemfile.lock")
        return false unless File.exist?(lock_path)
        content = RailsAiContext::SafeFile.read(lock_path)
        return false unless content

        content.include?("    #{name} (")
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
