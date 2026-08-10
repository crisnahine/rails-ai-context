# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    # Parses config/environments/*.rb - the one config surface no other
    # introspector covers. Captures, per environment file, which config keys
    # are assigned and the values of the toggles AI most often needs to
    # compare across environments (force_ssl, eager_load, caching, logging,
    # queue adapter, mailer delivery).
    #
    # Not EnvIntrospector, which reads environment variables and ENV[] usage.
    # This one reads the environment config files; that one reads the process
    # environment.
    class EnvConfigIntrospector
      extend StaticTier
      static_tier :files_only

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
        $stderr.puts "[rails-ai-context] EnvConfigIntrospector#call failed: #{e.message}" if ENV["DEBUG"]
        { error: e.message }
      end

      private

      def root
        app.root.to_s
      end

      def summarize(path)
        relative = path.sub("#{root}/", "")
        assignments = config_assignments(path)
        {
          name: File.basename(path, ".rb"),
          file: relative,
          config_keys: assignments.keys.sort,
          notable: extract_notable(assignments)
        }
      rescue => e
        $stderr.puts "[rails-ai-context] summarize environment #{path} failed: #{e.message}" if ENV["DEBUG"]
        nil
      end

      # Assigned `config.*` paths at any depth, mapped to their value source:
      # `config.eager_load`, `config.action_mailer.delivery_method`,
      # `config.active_record.encryption.primary_key`. The listener matches the
      # root anywhere in the chain, so the `Rails.application.config.x` form
      # resolves to the same path as the bare `config.x` inside `configure`.
      def config_assignments(path)
        walked = SourceIntrospector.walk(path, { config: Listeners::ConfigAssignmentListener })
        walked[:config].each_with_object({}) do |entry, acc|
          next unless entry[:assignment]

          acc[entry[:path].join(".")] ||= entry[:source]
        end
      end

      def extract_notable(assignments)
        NOTABLE_KEYS.each_with_object({}) do |key, notable|
          source = assignments[key]
          next unless source

          notable[key] = RailsAiContext::Redaction.redact_and_shorten(one_line(source), 60)
        end
      end

      # A node slice spans as many lines as the expression did, and the value
      # renders inside backticks on one markdown line.
      def one_line(source)
        source.gsub(/\s+/, " ").strip
      end

      def current_environment
        return Rails.env.to_s if defined?(Rails) && Rails.respond_to?(:env)

        ENV["RAILS_ENV"] || "development"
      end
    end
  end
end
