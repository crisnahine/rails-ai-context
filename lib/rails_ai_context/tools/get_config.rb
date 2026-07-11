# frozen_string_literal: true

module RailsAiContext
  module Tools
    class GetConfig < BaseTool
      tool_name "rails_get_config"
      description "Get Rails app configuration: cache store, session store, timezone, queue adapter, custom middleware, initializers. " \
        "Use when: configuring caching, checking session/queue setup, or seeing what initializers exist. " \
        "No parameters needed. Returns non-default middleware and all initializers."

      input_schema(properties: {})

      annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true, open_world_hint: false)

      def self.call(server_context: nil)
        data = cached_context[:config]
        return text_response("Config introspection not available. Add :config to introspectors or use `config.preset = :full`.") unless data
        return text_response("Config introspection failed: #{data[:error]}") if data[:error]
        note = unavailable_note(data)
        return text_response(note) if note

        lines = [ "# Application Configuration", "" ]

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

        if data[:middleware_stack]&.any?
          # Filter default Rails middleware AND dev-only middleware
          dev_middleware = %w[
            Propshaft::Server WebConsole::Middleware ActionDispatch::Reloader
            Bullet::Rack ActiveSupport::Cache::Strategy::LocalCache
          ]
          excluded_mw = RailsAiContext.configuration.excluded_middleware
          custom = data[:middleware_stack].reject { |m| excluded_mw.include?(m) || dev_middleware.include?(m) }
          if custom.any?
            lines << "" << "## Custom Middleware"
            custom.each { |m| lines << "- #{m}" }
          end
        end

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
          data[:current_attributes].each { |c| lines << "- `#{c}`" }
        end

        text_response(lines.join("\n"))
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

      # A short note for a config/initializers file: flags files that are
      # entirely commented out, otherwise describes known stock initializers.
      private_class_method def self.initializer_note(name)
        path = rails_app.root.join("config", "initializers", name).to_s
        if File.exist?(path)
          content = RailsAiContext::SafeFile.read(path)
          if content
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
        adapter = Rails.configuration.database_configuration&.dig(Rails.env, "adapter") rescue nil
        return nil unless adapter
        adapter
      end

      private_class_method def self.detect_auth_framework
        gems = cached_context[:gems]
        return nil unless gems.is_a?(Hash)

        all_gems = (gems[:notable] || []) + (gems[:all] || [])
        gem_names = all_gems.map { |g| g.is_a?(Hash) ? g[:name] : g.to_s }

        if gem_names.include?("devise")
          "Devise"
        elsif gem_names.include?("rodauth-rails")
          "Rodauth"
        elsif gem_names.include?("sorcery")
          "Sorcery"
        elsif gem_names.include?("clearance")
          "Clearance"
        elsif File.exist?(rails_app.root.join("app/models/concerns/authentication.rb")) ||
              File.exist?(rails_app.root.join("app/controllers/concerns/authentication.rb"))
          "Rails 8 authentication (built-in)"
        end
      end

      private_class_method def self.detect_assets_stack
        parts = []

        # Use frontend framework introspector data when available
        frontend = cached_context[:frontend_frameworks]
        if frontend.is_a?(Hash) && !frontend[:error]
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

        # Asset pipeline detection (always check - not from introspector)
        parts << "Propshaft" if defined?(Propshaft)
        parts << "Sprockets" if defined?(Sprockets) && !defined?(Propshaft)
        parts << "Import Maps" if File.exist?(rails_app.root.join("config/importmap.rb"))

        parts.uniq!
        parts.any? ? parts.join(", ") : nil
      end

      private_class_method def self.detect_action_cable
        # Try Rails config API first
        if defined?(ActionCable) && Rails.application.config.respond_to?(:action_cable)
          cable_config = Rails.application.config.action_cable
          adapter = cable_config.adapter if cable_config.respond_to?(:adapter)
          return adapter.to_s if adapter && !adapter.to_s.empty?
        end

        # YAML fallback for older Rails or when config API isn't available
        cable_yml = rails_app.root.join("config/cable.yml")
        return nil unless File.exist?(cable_yml)

        content = RailsAiContext::SafeFile.read(cable_yml)
        return nil unless content

        adapter = content.match(/adapter:\s*(\w+)/)&.captures&.first
        adapter || "configured"
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
