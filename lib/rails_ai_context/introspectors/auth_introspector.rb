# frozen_string_literal: true

require "prism"

module RailsAiContext
  module Introspectors
    # Discovers authentication and authorization setup: Devise, Rails 8 auth,
    # Pundit, CanCanCan, CORS, CSP.
    class AuthIntrospector < Base
      extend StaticTier
      static_tier :files_only

      # Settings reported as a bare word rather than as their literal value,
      # matching how Devise's own docs name the strategies.
      SYMBOL_DEVISE_SETTINGS = %i[lock_strategy unlock_strategy].freeze
      DEVISE_SETTINGS = (%i[timeout_in maximum_attempts password_length] + SYMBOL_DEVISE_SETTINGS).freeze

      def call
        {
          authentication: detect_authentication,
          authorization: detect_authorization,
          security: detect_security,
          devise_modules_per_model: detect_devise_modules_per_model,
          token_auth: detect_token_auth
        }
      end

      private

      # One walk per model and per controller answers every macro question below.
      def model_asts
        @model_asts ||= begin
          model_classes.map do |model_name, record|
            [ model_name, SourceIntrospector.walk_source(record.source, {
              devise: -> { Listeners::GenericMacroListener.new(:devise) },
              macros: Listeners::MacrosListener,
              mixins: Listeners::MixinsListener
            }) ]
          end
        rescue => e
          RailsAiContext.debug_fail(e, [], label: "model_asts")
        end
      end

      def controller_asts
        @controller_asts ||= begin
          SourceScan.each(root, kind: "app/controllers").map do |record|
            [ record.file, SourceIntrospector.walk_source(record.source, {
              unauthenticated: -> { Listeners::GenericMacroListener.new(:allow_unauthenticated_access) },
              http_token: -> { Listeners::GenericMacroListener.new(:authenticate_with_http_token, :authenticate_or_request_with_http_token) }
            }) ]
          end
        rescue => e
          RailsAiContext.debug_fail(e, [], label: "controller_asts")
        end
      end

      def detect_authentication
        auth = {}

        # Devise
        devise_models = scan_models_for_devise
        auth[:devise] = devise_models if devise_models.any?

        # Rails 8 built-in auth (`bin/rails generate authentication`)
        rails_auth = detect_rails_auth
        auth[:rails_auth] = rails_auth if rails_auth

        auth[:rodauth] = { classes: rodauth_classes } if gem_present?("rodauth-rails")

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
        RailsAiContext.debug_fail(e, nil, label: "detect_rails_auth")
      end

      def scan_allow_unauthenticated_access
        controller_asts.flat_map do |relative, ast|
          hits = ast[:unauthenticated]
          next [] if hits.empty?

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
        RailsAiContext.debug_fail(e, [], label: "scan_allow_unauthenticated_access")
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

      # rodauth-rails generates its auth class into app/misc.
      def rodauth_classes
        SourceScan.each(root, kind: "app/misc").flat_map { |record|
          DeclaredConstant.declarations(record.source)
            .select { |d| d.superclass.to_s.delete_prefix("::") == "Rodauth::Rails::Auth" }.map(&:name)
        }.uniq.sort
      rescue => e
        RailsAiContext.debug_fail(e, [], label: "rodauth_classes")
      end

      # A gem is named only when the app bundles it: an app can have app/policies without pundit.
      def detect_authorization
        authz = {}

        policies_dir = File.join(root, "app/policies")
        if Dir.exist?(policies_dir)
          # Named from the path relative to app/policies, not the basename:
          # Zeitwerk makes admin/collection_policy.rb `Admin::CollectionPolicy`,
          # and demodulizing it collided with the top-level policy of the same
          # base name, so one name was listed twice and the other class could
          # not be reached from the context at all.
          policies = Dir.glob(File.join(policies_dir, "**/*.rb")).map do |f|
            f.sub("#{policies_dir}/", "").delete_suffix(".rb").camelize
          end.sort
          key = if gem_present?("pundit") then :pundit
          elsif gem_present?("action_policy") then :action_policy
          else :policies
          end
          authz[key] = policies if policies.any?
        end

        if file_exists?("app/models/ability.rb")
          gem_present?("cancancan") ? authz[:cancancan] = true : authz[:ability_class] = "app/models/ability.rb"
        end

        authz
      end

      def detect_security
        security = {}

        # CORS
        if gem_present?("rack-cors")
          security[:cors] = { configured: ApiIntrospector.new(app).cors_configured? }
        end

        # CSP
        csp_init = File.join(root, "config/initializers/content_security_policy.rb")
        security[:csp] = true if File.exist?(csp_init)

        security
      end

      # Keyed by the declared name: `app/models/admin/user.rb` is
      # `Admin::User`, and keying it by basename overwrote `User`.
      def detect_devise_modules_per_model
        result = {}
        model_asts.each do |model_name, ast|
          next if ast[:devise].empty?

          result[model_name] = ast[:devise].flat_map { |h| h[:args].map(&:to_s) } | concern_devise_modules(model_name, ast[:mixins])
        end

        result
      rescue => e
        RailsAiContext.debug_fail(e, {}, label: "detect_devise_modules_per_model")
      end

      # The modules an included concern's `devise` adds to a model that calls devise
      # itself; one under a condition (`if ENV[...]`) depends on the environment, so it is left out.
      def concern_devise_modules(model_name, mixins)
        Array(mixins).select { |mixin| mixin[:ancestor] }.flat_map do |mixin|
          source = ConcernPaths.module_source(root, mixin[:name], prefer: "model", within: model_name)
          next [] unless source&.include?("devise")

          # Keyed by source: which file a name resolves to depends on the including model.
          (@concern_devise ||= {})[source] ||= unconditional_devise_modules(source)
        end
      end

      def unconditional_devise_modules(source)
        parsed = AstCache.parse_string(source)
        SourceIntrospector.walk_source(source, { devise: -> { Listeners::GenericMacroListener.new(:devise) } })[:devise]
          .reject { |hit| conditional_call?(parsed, hit[:offset]) }
          .flat_map { |hit| hit[:args].map(&:to_s) }
      end

      CONDITIONAL_NODES = [ Prism::IfNode, Prism::UnlessNode, Prism::CaseNode, Prism::DefNode ].freeze

      def conditional_call?(parsed, offset)
        line = parsed.source.line(offset)
        parsed.value.tunnel(line, parsed.source.column(offset)).any? { |node| CONDITIONAL_NODES.any? { |kind| node.is_a?(kind) } }
      end

      def detect_token_auth
        token_auth = {}

        token_auth[:devise_jwt] = detect_devise_jwt
        token_auth[:doorkeeper] = detect_doorkeeper
        token_auth[:http_token_auth] = detect_http_token_auth

        token_auth
      rescue => e
        RailsAiContext.debug_fail(e, {}, label: "detect_token_auth")
      end

      def detect_devise_jwt
        return { detected: false } unless gem_present?("devise-jwt")

        devise_init = File.join(root, "config/initializers/devise.rb")
        if File.exist?(devise_init)
          jwt = config_assignments(devise_init).any? { |hit| hit[:path].first == :jwt }
          return { detected: true, jwt_configured: jwt }
        end

        { detected: true }
      rescue => e
        RailsAiContext.debug_fail(e, { detected: false }, label: "detect_devise_jwt")
      end

      def detect_doorkeeper
        return nil unless gem_present?("doorkeeper")

        doorkeeper_init = File.join(root, "config/initializers/doorkeeper.rb")
        return { detected: true } unless File.exist?(doorkeeper_init)

        ast = SourceIntrospector.walk(doorkeeper_init, {
          settings: -> { Listeners::GenericMacroListener.new(:grant_flows, :access_token_expires_in) }
        })

        grant_flows = ast[:settings].find { |h| h[:macro] == :grant_flows }
        grant_flows = Array(grant_flows[:values].first).map(&:to_s) if grant_flows

        expires_in = ast[:settings].find { |h| h[:macro] == :access_token_expires_in }
        expires_in = expires_in[:values].first&.to_s if expires_in

        result = { detected: true }
        result[:grant_flows] = grant_flows if grant_flows
        result[:access_token_expires_in] = expires_in if expires_in
        result
      rescue => e
        RailsAiContext.debug_fail(e, nil, label: "detect_doorkeeper")
      end

      def detect_http_token_auth
        controller_asts.filter_map { |file, ast| file unless ast[:http_token].empty? }.sort
      rescue => e
        RailsAiContext.debug_fail(e, [], label: "detect_http_token_auth")
      end

      def detect_omniauth_providers
        providers = []

        # Scan initializers for config.omniauth and provider calls
        initializers = PathResolver.initializer_paths(app.root)
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
        RailsAiContext.debug_fail(e, [], label: "detect_omniauth_providers")
      end

      def extract_devise_settings
        path = File.join(app.root, "config", "initializers", "devise.rb")
        return {} unless File.exist?(path)

        settings = {}
        config_assignments(path).each do |hit|
          next unless hit[:assignment] && hit[:path].size == 1
          key = hit[:path].first
          next unless DEVISE_SETTINGS.include?(key)
          settings[key] = devise_setting_value(key, hit)
        end
        settings
      rescue => e
        RailsAiContext.debug_fail(e, {}, label: "extract_devise_settings")
      end

      def devise_setting_value(key, hit)
        return hit[:value].to_s if SYMBOL_DEVISE_SETTINGS.include?(key)
        return hit[:value] if key == :maximum_attempts && hit[:value].is_a?(Integer)
        hit[:source]
      end

      def config_assignments(path)
        SourceIntrospector.walk(path, { config: Listeners::ConfigAssignmentListener })[:config]
      end

      def scan_models_for_devise
        results = model_asts.filter_map do |model_name, ast|
          next if ast[:devise].empty?

          # Format matches the same way the old regex did: ":<module>, :<module>, ..."
          matches = ast[:devise].map { |h| h[:args].map { |a| ":#{a}" }.join(", ") }
          { model: model_name, matches: matches }
        end
        results.sort_by { |r| r[:model] }
      rescue => e
        RailsAiContext.debug_fail(e, [], label: "scan_models_for_devise")
      end

      def scan_models_for_macro(macro_name)
        results = model_asts.filter_map do |model_name, ast|
          next if ast[:macros].none? { |m| m[:macro] == macro_name }

          { model: model_name }
        end
        results.sort_by { |r| r[:model] }
      rescue => e
        RailsAiContext.debug_fail(e, [], label: "scan_models_for_macro")
      end

      def gem_present?(name)
        RailsAiContext::GemLock.for(root).present?(name)
      end

      def file_exists?(relative_path)
        File.exist?(File.join(root, relative_path))
      end
    end
  end
end
