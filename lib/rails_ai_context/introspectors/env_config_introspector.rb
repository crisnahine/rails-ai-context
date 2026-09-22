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
        RailsAiContext.debug_fail(e, { error: e.message }, label: "EnvConfigIntrospector#call")
      end

      private

      def root
        app.root.to_s
      end

      def summarize(path)
        relative = path.sub("#{root}/", "")
        assignments = config_assignments(path)
        name = File.basename(path, ".rb")
        {
          name: name,
          file: relative,
          config_keys: assignments.keys.sort,
          notable: extract_notable(assignments, environment: name)
        }
      rescue => e
        RailsAiContext.debug_fail(e, nil, label: "summarize environment #{path}")
      end

      # Assigned `config.*` paths at any depth, mapped to their value source:
      # `config.eager_load`, `config.action_mailer.delivery_method`,
      # `config.active_record.encryption.primary_key`. The listener matches the
      # root anywhere in the chain, so the `Rails.application.config.x` form
      # resolves to the same path as the bare `config.x` inside `configure`.
      # Every assignment of a path, not the first: Rails' own development
      # template assigns `perform_caching` in both halves of one `if`, and
      # the first one is the branch that is not running.
      def config_assignments(path)
        walked = SourceIntrospector.walk(path, { config: Listeners::ConfigAssignmentListener })
        walked[:config].each_with_object({}) do |entry, acc|
          next unless entry[:assignment]

          (acc[entry[:path].join(".")] ||= []) << entry
        end
      end

      def extract_notable(assignments, environment:)
        NOTABLE_KEYS.each_with_object({}) do |key, notable|
          entries = assignments[key]
          next unless entries&.any?

          live = live_value(key, environment)
          rendered = live.nil? ? branch_values(entries) : one_line(live.inspect)
          # A branch-by-branch value carries a condition as well as a value,
          # and 60 characters cut it mid-predicate.
          limit = live.nil? && entries.size > 1 ? 140 : 60
          notable[key] = RailsAiContext::Redaction.redact_and_shorten(rendered, limit)
        end
      end

      # `:memory_store if Rails.root.join(...).exist?, else :null_store`.
      #
      # Two unconditional assignments of one key are not branches: Rails runs
      # both lines and the last one wins. Comma-joining them read exactly like
      # a single assignment whose value is a comma list
      # (`:mem_cache_store, { pool_size: 5 }`), so the winner is named and the
      # assignment it overrode is named after it.
      def branch_values(entries)
        return one_line(entries.first[:source].to_s) if entries.size == 1

        unconditional, conditional = entries.partition { |entry| entry[:condition].nil? }
        rendered = conditional.map { |entry|
          value = one_line(entry[:source].to_s)
          entry[:condition] == "else" ? "else #{value}" : "#{value} if #{entry[:condition]}"
        }

        if unconditional.any?
          values = unconditional.map { |entry| one_line(entry[:source].to_s) }.uniq
          last = values.last
          overridden = values[0..-2]
          rendered.unshift(overridden.any? ? "#{last} (overrides #{overridden.join(', ')})" : last)
        end

        rendered.uniq.join(", ")
      end

      # The booted app has already resolved the branch, and two tools reading
      # the same app disagreeing about `cache_store` is the whole complaint.
      def live_value(key, environment)
        return nil if RailsAiContext.static_tier?
        return nil unless defined?(Rails) && Rails.respond_to?(:application) && Rails.application
        return nil unless environment.to_s == current_environment

        key.split(".").reduce(Rails.application.config) do |target, segment|
          return nil unless target.respond_to?(segment)

          target.public_send(segment)
        end
      rescue StandardError => e
        RailsAiContext.debug_fail(e, nil, label: "EnvConfigIntrospector live value for #{key}")
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
