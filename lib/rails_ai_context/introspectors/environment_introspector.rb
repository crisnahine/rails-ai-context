# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    # Parses config/environments/*.rb - the one config surface no other
    # introspector covers. Captures, per environment file, which config keys
    # are assigned and the values of the toggles AI most often needs to
    # compare across environments (force_ssl, eager_load, caching, logging,
    # queue adapter, mailer delivery).
    #
    # File-based only: works in the static tier, so static_call aliases call.
    class EnvironmentIntrospector
      attr_reader :app

      # Assignments whose values are lifted into the per-env `notable` hash.
      # Keys are the config path relative to `config.` (one or two levels).
      NOTABLE_KEYS = %w[
        force_ssl eager_load cache_classes consider_all_requests_local
        log_level cache_store action_controller.perform_caching
        active_job.queue_adapter action_mailer.delivery_method
        action_mailer.raise_delivery_errors active_storage.service
        action_cable.mount_path i18n.fallbacks
      ].freeze

      def initialize(app)
        @app = app
      end

      # @return [Hash] per-environment config summary
      def call
        files = Dir.glob(File.join(root, "config", "environments", "*.rb")).sort.filter_map do |path|
          summarize(path)
        end

        {
          current: current_environment,
          count: files.size,
          environments: files
        }
      rescue => e
        $stderr.puts "[rails-ai-context] EnvironmentIntrospector#call failed: #{e.message}" if ENV["DEBUG"]
        { error: e.message }
      end

      # File-based only - the static tier serves the same data.
      def static_call
        call
      end

      private

      def root
        app.root.to_s
      end

      def summarize(path)
        content = RailsAiContext::SafeFile.read(path)
        return nil unless content

        relative = path.sub("#{root}/", "")
        {
          name: File.basename(path, ".rb"),
          file: relative,
          config_keys: extract_config_keys(content),
          notable: extract_notable(content)
        }
      rescue => e
        $stderr.puts "[rails-ai-context] summarize environment #{path} failed: #{e.message}" if ENV["DEBUG"]
        nil
      end

      # Sorted unique list of assigned `config.*` paths (up to two levels:
      # `config.eager_load` and `config.action_mailer.delivery_method`).
      def extract_config_keys(content)
        content.scan(/^\s*config\.([a-z_][\w]*(?:\.[a-z_][\w]*)?)\s*=/i)
               .flatten.uniq.sort
      end

      def extract_notable(content)
        notable = {}
        NOTABLE_KEYS.each do |key|
          match = content.match(/^\s*config\.#{Regexp.escape(key)}\s*=\s*(.+)$/i)
          next unless match

          value = match[1].sub(/\s+#.*$/, "").strip
          # Redact BEFORE truncating: a truncation cut landing between the
          # password and its `@host` would leave the regex nothing to match
          # and serve the credential prefix in plaintext.
          notable[key] = redact_credentials(value).truncate(60)
        end
        notable
      end

      # Values come from real config files and can embed credentials (a
      # Redis URL is the classic case). Strip URI userinfo before serving,
      # matching the gem's never-serve-secrets posture.
      def redact_credentials(value)
        value
          .gsub(%r{([a-z][a-z0-9+.-]*://)[^\s/]*:[^@\s]+@}i, "\\1[FILTERED]@")
          .gsub(/(?<![a-zA-Z0-9])(?:password|passwd|secret|token|api_key)\s*["']?\s*(?::|=>)\s*["'][^"']*["']/i) { |m| m.sub(/["'][^"']*["']\s*\z/, '"[FILTERED]"') }
      end

      def current_environment
        return Rails.env.to_s if defined?(Rails) && Rails.respond_to?(:env)

        ENV["RAILS_ENV"] || "development"
      end
    end
  end
end
