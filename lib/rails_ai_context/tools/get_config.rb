# frozen_string_literal: true

module RailsAiContext
  module Tools
    class GetConfig < BaseTool
      tool_name "rails_get_config"
      # Each section and the tool that answered it before it was a section.
      # A retired name still reaches its section from the CLI and the MCP
      # server, and skip_tools lists it to turn the section off.
      SECTIONS = {
        "app" => "rails_get_config",
        "gems" => "rails_get_gems",
        "frontend" => "rails_get_frontend_stack",
        "api" => "rails_get_api",
        "engines" => "rails_get_engines",
        "conventions" => "rails_get_conventions",
        "autoload" => "rails_get_autoload",
        "active_support" => "rails_get_active_support",
        "env" => "rails_get_env",
        "env_config" => "rails_get_env_config",
        "i18n" => "rails_get_i18n"
      }.freeze

      # The parameters each section reads.
      SECTION_PARAMS = {
        "gems" => %i[category offset limit],
        "frontend" => %i[detail],
        "api" => %i[detail],
        "env" => %i[detail],
        "env_config" => %i[environment offset limit],
        "i18n" => %i[locale offset limit]
      }.freeze

      SECTION_SUMMARIES = {
        "app" => "default: database, auth, assets, cache, session, queue, Action Cable, middleware, initializers",
        "gems" => "notable gems by category",
        "frontend" => "JS framework, build tool, TypeScript, package manager",
        "api" => "serializers, GraphQL, versioning, CORS, rate limiting, pagination",
        "engines" => "mounted engines and Rack apps",
        "conventions" => "architecture and patterns",
        "autoload" => "Zeitwerk paths, inflections",
        "active_support" => "concerns, notifications, on_load hooks",
        "env" => "environment variables and credentials keys, never values",
        "env_config" => "config/environments/*.rb per environment",
        "i18n" => "locales, locale files, coverage"
      }.freeze

      # Each parameter's schema, less the description that names its sections.
      PARAM_SCHEMAS = {
        detail: [ {}, "summary, standard (default) or full." ],
        category: [
          { type: "string", enum: Introspectors::GemIntrospector::NOTABLE_GEMS.values.map { |gem| gem[:category].to_s }.uniq + %w[all] },
          "only this category. Default: all."
        ],
        environment: [ { type: "string" }, "only this environment (e.g. \"production\")." ],
        locale: [ { type: "string" }, "only this locale (e.g. \"fr\")." ],
        offset: [ { type: "integer" }, "skip this many entries. Default: 0." ],
        limit: [ { type: "integer" }, "max entries. Default: 50." ]
      }.freeze

      # The schema over the given sections: a parameter no section among them reads is left out.
      def self.schema_for(sections)
        properties = { section: { type: "string", enum: sections, description: "Which section to answer. Default: app." } }
        PARAM_SCHEMAS.each do |param, (schema, text)|
          readers = sections.select { |section| SECTION_PARAMS.fetch(section, []).include?(param) }
          next if readers.empty?

          text = "#{readers.join(', ')}: #{text}"
          properties[param] = param == :detail ? RailsAiContext::DetailLevel.schema(text) : schema.merge(description: text)
        end
        { properties: properties }
      end

      def self.description_for(sections)
        "Get the app's configuration, one section per call. section: " \
          "#{sections.map { |section| "#{section} (#{SECTION_SUMMARIES.fetch(section)})" }.join(', ')}."
      end

      def self.sections_on(config = RailsAiContext.configuration)
        SECTIONS.keys.select { |section| section_on?(section, config) }
      end

      # The full schema validates a call, so one naming an off section still
      # reaches the turned-off answer; tools/list publishes only the sections that are on.
      input_schema(schema_for(SECTIONS.keys))
      description(description_for(SECTIONS.keys))

      def self.input_schema(*args)
        args.empty? ? @input_schema_value : super
      end

      def self.input_schema_value
        MCP::Tool::InputSchema.new(schema_for(sections_on))
      end

      def self.description_value
        description_for(sections_on)
      end

      guide_row(order: 20, mcp: "rails_get_config", summary: "")

      def self.guide_row(**args)
        row = super
        return row unless args.empty? && row

        on = sections_on
        others = (on - [ "app" ]).join(", ")
        summary = [ ("App config (database, auth, assets, cache, queue)" if on.include?("app")),
                    ("`section` picks #{on.include?('app') ? 'another' : 'one'}: #{others}" unless others.empty?) ].compact.join("; ")
        row.dup.tap { |copy| copy.summary = summary }
      end

      annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true, open_world_hint: false)

      def self.call(section: nil, detail: nil, category: nil, offset: nil, limit: nil, environment: nil, locale: nil, server_context: nil)
        section = section.nil? ? "app" : section.to_s
        unless SECTIONS.key?(section)
          return error_response("`section` does not take '#{echo_input(section)}'. It takes: #{SECTIONS.keys.join(', ')}.")
        end
        return error_response(section_off_message(section)) unless section_on?(section)

        given = { detail: detail, category: category, offset: offset, limit: limit, environment: environment, locale: locale }.compact
        reads = SECTION_PARAMS.fetch(section, [])
        response = section == "app" ? app_section : renderer(section).call(**given.slice(*reads))
        append_note(response, unread_note(section, given.keys - reads))
      end

      # The section a tool name or CLI short name stands for, or nil.
      def self.section_for(name)
        name = name.to_s
        SECTIONS.key(name) || SECTIONS.key("rails_#{name}") || SECTIONS.key("rails_get_#{name}")
      end

      # skip_tools turns a section off by the name of the tool that answered it.
      def self.section_on?(section, config = RailsAiContext.configuration)
        !config.skip_tools.include?(SECTIONS.fetch(section))
      end

      def self.renderer(section)
        Tools.const_get(SECTIONS.fetch(section).delete_prefix("rails_").split("_").map(&:capitalize).join, false)
      end

      def self.section_off_message(section)
        "The `#{section}` section of rails_get_config is turned off in this app: skip_tools lists #{SECTIONS.fetch(section)} " \
          "(.rails-ai-context.yml or config/initializers/rails_ai_context.rb). Take it out of skip_tools to use it."
      end

      # Only a detail the caller sent is normalized, so a section that does
      # not read it can say so.
      def self.normalize_detail(kwargs)
        kwargs.key?(:detail) ? super : kwargs
      end

      private_class_method def self.unread_note(section, unread)
        return nil if unread.empty?

        names = unread.map { |name| "`#{name}`" }.join(", ")
        "\n\n_The `#{section}` section does not read #{names}, so #{unread.size > 1 ? 'they were' : 'it was'} ignored._"
      end

      private_class_method def self.app_section
        if static_refusal_for(:config) && (rackup = rackup_lines).any?
          return text_response(([ unavailable_text ] + rackup).join("\n"))
        end

        fetch_section(:config, subject: "Config introspection", remedy: "Add :config to introspectors or use `config.preset = :full`.") do |data|
          lines = [ "# Application Configuration", "" ]

          # Several values below (cache store, queue adapter, Action Cable)
          # differ per environment; name the one that produced them.
          lines << "- **Environment:** #{rails_env_name} (values below reflect this environment)"

          # Database - critical for query syntax decisions
          db_config = detect_database
          lines << "- **Database:** #{db_config}" if db_config

          # Auth framework - affects every controller
          auth = detect_auth_framework
          lines << "- **Auth:** #{auth}" if auth

          # Assets/CSS - uses frontend framework introspector data when available
          assets = detect_assets_stack
          lines << "- **Assets:** #{assets}" if assets

          # Action Cable - uses Rails config API with YAML fallback
          cable = detect_action_cable
          lines << "- **Action Cable:** #{cable}" if cable

          # Active Storage service
          storage = detect_active_storage
          lines << "- **Active Storage:** #{storage}" if storage

          # Action Mailer delivery method
          mailer_delivery = detect_mailer_delivery
          lines << "- **Mailer delivery:** #{mailer_delivery}" if mailer_delivery

          lines << "- **Cache store:** #{data[:cache_store]}" if data[:cache_store]
          lines << "- **Session store:** #{data[:session_store]}" if data[:session_store]
          lines << "- **Timezone:** #{data[:timezone]}" if data[:timezone]
          lines << "- **Queue adapter:** #{data[:queue_adapter]}" if data[:queue_adapter]
          if data[:mailer].is_a?(Hash) && data[:mailer].any?
            lines << "- **Mailer config:** #{data[:mailer].map { |k, v| "#{k}: #{v}" }.join(', ')}"
          end

          lines.concat(middleware_lines(data[:middleware_stack]))
          lines.concat(rackup_lines)

          if data[:initializers]&.any?
            # List every initializer - stock ones often carry active code
            # (filter_parameter_logging, assets), so hiding them misleads.
            lines << "" << "## Initializers"
            data[:initializers].each do |i|
              note = initializer_note(i)
              lines << (note ? "- `#{i}` - #{note}" : "- `#{i}`")
            end
          end

          if data[:current_attributes]&.any?
            lines << "" << "## CurrentAttributes"
            data[:current_attributes].each { |c| lines << current_attributes_line(c, data.dig(:current_attribute_details, c)) }
          end

          text_response(lines.join("\n"))
        end
      end

      private_class_method def self.current_attributes_line(name, detail)
        line = "- `#{name}`"
        return line unless detail

        attributes = Array(detail[:attributes]).map { |a| a[:default] ? "#{a[:name]} (default `#{a[:default]}`)" : a[:name] }
        line += ": #{attributes.join(', ')}" if attributes.any?
        line += "; hooks: #{detail[:hooks].map { |h| "`#{h}`" }.join(', ')}" if Array(detail[:hooks]).any?
        line
      end

      # Middleware Rails or a development gem puts in every stack.
      DEV_MIDDLEWARE = %w[
        Propshaft::Server WebConsole::Middleware ActionDispatch::Reloader
        Bullet::Rack ActiveSupport::Cache::Strategy::LocalCache
      ].freeze

      # The live stack split the way the middleware section splits it: the
      # app's own classes with their files, everything else as an addition.
      private_class_method def self.middleware_lines(stack)
        return [] unless stack&.any?

        excluded = RailsAiContext.configuration.excluded_middleware
        stacked = stack.reject { |m| excluded.include?(m) || DEV_MIDDLEWARE.include?(m) }
        owned = owned_middleware
        return [] if stacked.empty? && owned.empty?

        lines = [ "", "## Custom Middleware" ]
        if owned.any?
          owned.each { |name, file| lines << "- `#{name}` (#{file})" }
        else
          lines << "- No custom middleware in app/middleware/ or lib/middleware/"
        end

        added = stacked.reject { |m| owned.key?(m) }
        if added.any?
          lines << "### Added to the stack"
          added.each { |m| lines << "- `#{m}`" }
        end
        lines
      end

      # The static refusal reads config.ru alone rather than building every section,
      # and only when the middleware introspector the booted tier reads it through is on.
      private_class_method def self.rackup_lines
        calls = if RailsAiContext.static_tier?
          RailsAiContext.configuration.introspectors.include?(:middleware) ? Introspectors::MiddlewareIntrospector.rackup(rails_app.root.to_s) : []
        else
          Array(Payload.section(cached_context, :middleware)&.dig(:rackup))
        end
        return [] if calls.empty?

        lines = [ "", "## config.ru (runs before the Rails middleware stack)" ]
        calls.each do |call|
          next lines << "- not read: #{call[:unread]}, so the middleware it adds is unknown" if call[:unread]

          where = [ "line #{call[:line]}", ("inside `map #{call[:within]}`" if call[:within]), call[:condition] ].compact.join(", ")
          lines << if call[:call] == "map"
            "- `map #{call[:target]}` (#{where}) - its own Rack app; requests under it never reach Rails' router"
          else
            "- `use #{call[:target]}` (#{where})"
          end
        end
        lines
      end

      # What the middleware introspector found the app owns, by class name.
      private_class_method def self.owned_middleware
        Array(Payload.section(cached_context, :middleware)&.dig(:custom_middleware))
          .to_h { |entry| [ entry[:class_name], entry[:file] ] }
          .compact
      end

      # One-line descriptions for initializers Rails generates in every app.
      STOCK_INITIALIZER_NOTES = {
        "assets.rb" => "asset pipeline paths/version",
        "content_security_policy.rb" => "Content-Security-Policy headers",
        "cors.rb" => "cross-origin request rules",
        "filter_parameter_logging.rb" => "hides sensitive params in logs",
        "inflections.rb" => "custom singular/plural rules",
        "permissions_policy.rb" => "browser feature permissions",
        "wrap_parameters.rb" => "JSON params wrapping"
      }.freeze

      # A short note for a config/initializers file: flags a file that holds
      # nothing and one that is entirely commented out, otherwise describes
      # known stock initializers.
      private_class_method def self.initializer_note(name)
        path = rails_app.root.join("config", "initializers", name).to_s
        if File.exist?(path)
          content = RailsAiContext::SafeFile.read(path)
          if content
            # A zero-byte file has no line to be a comment, which took the
            # same branch and sent a reader to open it for the config it
            # supposedly holds.
            return "empty" if content.strip.empty?

            active = content.each_line.any? do |line|
              stripped = line.strip
              !stripped.empty? && !stripped.start_with?("#")
            end
            return "all commented out" unless active
          end
        end
        return "framework default toggles" if name.start_with?("new_framework_defaults")
        STOCK_INITIALIZER_NOTES[name]
      rescue StandardError
        nil
      end

      private_class_method def self.detect_database
        env = Rails.configuration.database_configuration&.dig(Rails.env) rescue nil
        return nil unless env.is_a?(Hash)

        # A multi-database environment nests one block per database; primary is the app's own.
        env["adapter"] || (env["primary"] || env.values.find { |v| v.is_a?(Hash) })&.dig("adapter")
      end

      # The auth section's rule, read from the files when the section did not
      # run: an Authentication concern alone is as often hand-written as
      # generated, so it does not make an app a Rails 8 authentication one.
      private_class_method def self.detect_auth_framework
        auth = Payload.section(cached_context, :auth)
        rails_auth = auth ? auth.dig(:authentication, :rails_auth) : Introspectors::AuthIntrospector.rails_auth?(rails_app.root)

        if auth&.dig(:authentication, :devise)&.any? || Payload.gem?(cached_context, "devise")
          "Devise"
        elsif rails_auth
          "Rails 8 authentication (built-in)"
        elsif Payload.gem?(cached_context, "rodauth-rails")
          "Rodauth"
        elsif Payload.gem?(cached_context, "sorcery")
          "Sorcery"
        elsif Payload.gem?(cached_context, "clearance")
          "Clearance"
        else
          parts = []
          models = Array(auth&.dig(:authentication, :has_secure_password))
          parts << "has_secure_password on #{models.join(', ')}" if models.any?
          concern = %w[app/controllers/concerns/authentication.rb app/models/concerns/authentication.rb]
            .find { |path| File.exist?(rails_app.root.join(path)) }
          parts << "the app's own Authentication concern (`#{concern}`)" if concern
          "#{parts.join(', ')}; no authentication gem or generator" if parts.any?
        end
      end

      private_class_method def self.detect_assets_stack
        parts = []

        # Use frontend framework introspector data when available
        frontend = Payload.section(cached_context, :frontend_frameworks)
        if frontend
          # Frameworks (React, Vue, etc.)
          (frontend[:frameworks] || {}).each_key { |fw| parts << fw.to_s.capitalize }

          # Build tool
          build = frontend[:build_tool]
          parts << build.to_s.capitalize if build && !build.to_s.empty?

          # CSS/component libraries
          (frontend[:component_libraries] || []).each do |lib|
            lib_str = lib.to_s.downcase
            parts << "Tailwind" if lib_str.include?("tailwind")
            parts << "Bootstrap" if lib_str.include?("bootstrap")
            parts << lib.to_s unless lib_str.include?("tailwind") || lib_str.include?("bootstrap")
          end
        end

        # The gems are read rather than the :assets section: assets is a
        # full-preset introspector, so the standard preset would lose the line.
        propshaft = Payload.gem?(cached_context, "propshaft")
        sprockets = Payload.gem?(cached_context, "sprockets-rails") ||
                    Payload.gem?(cached_context, "sprockets")
        parts << "Propshaft" if propshaft
        parts << "Sprockets" if sprockets && !propshaft
        parts << "Import Maps" if File.exist?(rails_app.root.join("config/importmap.rb"))

        parts.uniq!
        parts.any? ? parts.join(", ") : nil
      end

      # Action Cable's railtie loads the current environment's cable.yml block into
      # the server config; config.action_cable has no adapter of its own.
      private_class_method def self.detect_action_cable
        return nil unless defined?(ActionCable) && ActionCable.respond_to?(:server)

        cable = ActionCable.server.config.cable
        return nil unless cable

        adapter = cable[:adapter] || cable["adapter"]
        adapter.to_s.empty? ? "configured" : adapter.to_s
      rescue StandardError
        nil
      end

      private_class_method def self.detect_active_storage
        return nil unless defined?(ActiveStorage)

        service_name = Rails.application.config.active_storage.service rescue nil
        return nil unless service_name

        service_name.to_s
      rescue StandardError
        nil
      end

      private_class_method def self.detect_mailer_delivery
        method = Rails.application.config.action_mailer.delivery_method rescue nil
        return nil unless method

        method.to_s
      rescue StandardError
        nil
      end
    end
  end
end
