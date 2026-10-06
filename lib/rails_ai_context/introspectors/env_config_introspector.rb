# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    # Parses config/environments/*.rb and config/application.rb, which every
    # environment runs. Captures, per environment file, which config keys
    # are assigned and the values of the toggles AI most often needs to
    # compare across environments (force_ssl, eager_load, caching, logging,
    # queue adapter, mailer delivery).
    #
    # Not EnvIntrospector, which reads environment variables and ENV[] usage.
    # This one reads the environment config files; that one reads the process
    # environment.
    class EnvConfigIntrospector < Base
      extend StaticTier
      static_tier :files_only

      # Assignments whose values are lifted into the per-env `notable` hash.
      # Keys are the config path relative to `config.` (one or two levels).
      NOTABLE_KEYS = %w[
        force_ssl eager_load cache_classes consider_all_requests_local
        log_level cache_store action_controller.perform_caching
        active_job.queue_adapter action_mailer.delivery_method
        action_mailer.raise_delivery_errors active_storage.service
        action_cable.mount_path i18n.fallbacks
      ].freeze

      # @return [Hash] per-environment config summary
      def call
        files = Dir.glob(File.join(root, "config", "environments", "*.rb")).sort.filter_map do |path|
          summarize(path)
        end

        {
          current: current_environment,
          count: files.size,
          environments: files,
          application: summarize_application
        }.compact
      end

      private

      APPLICATION = "config/application.rb"

      def summarize_application
        path = File.join(root, APPLICATION)
        return nil unless File.file?(path)

        entries = SourceIntrospector.walk(path, { config: Listeners::ConfigAssignmentListener })[:config]
        assignments = config_assignments(entries)
        {
          file: APPLICATION,
          config_keys: (assignments.keys + entries.filter_map { |entry| written_key(entry) }).uniq.sort,
          config_for: config_for_files(assignments).presence
        }.compact
      rescue => e
        RailsAiContext.debug_fail(e, nil, label: "summarize #{APPLICATION}")
      end

      # The keys config_for gives the environment it reads (`env:`, else this one):
      # `shared` deep-merged under that environment's section. Names only: a value is often a secret.
      def config_for_files(assignments)
        assignments.filter_map do |key, entries|
          call = entries.last[:config_for] or next
          entry = { key: key, call: call[:argument], file: call[:file] }.compact
          next entry.merge(path_unread: true) unless call[:file]

          environment = current_environment
          case call[:env]
          when :expression then next entry.merge(environment_unread: true)
          when String then environment = entry[:environment] = call[:env]
          end
          next entry.merge(missing: true) unless File.file?(File.join(root, call[:file]))

          data = RecurringSchedules.yaml(root, call[:file])
          next entry.merge(unreadable: true) unless data.is_a?(Hash)

          sections = [ data["shared"], data[environment] ].select { |section| section.is_a?(Hash) }
          entry.merge(keys: sections.flat_map(&:keys).uniq.sort)
        end
      end

      def summarize(path)
        relative = path.sub("#{root}/", "")
        entries = SourceIntrospector.walk(path, { config: Listeners::ConfigAssignmentListener })[:config]
        assignments = config_assignments(entries)
        name = File.basename(path, ".rb")
        {
          name: name,
          file: relative,
          config_keys: (assignments.keys + entries.filter_map { |entry| written_key(entry) }).uniq.sort,
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
      def config_assignments(entries)
        entries.each_with_object({}) do |entry, acc|
          next unless entry[:assignment]

          (acc[entry[:path].join(".")] ||= []) << entry
        end
      end

      # `config.hosts << x` and `config.middleware.use X` change the receiver's
      # setting; `config.session_store :cookie_store` names its own.
      def written_key(entry)
        path = entry[:path]
        case entry[:write]
        when :call then (path.size > 1 ? path[0..-2] : path).join(".")
        when :operator, :block then path.join(".")
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
          text = entry[:condition] == "else" ? "else #{value}" : "#{value} if #{entry[:condition]}"
          [ entry[:location].to_i, text ]
        }

        if unconditional.any?
          # The last line the file runs is the value in force, whatever ran
          # before it, so the winner is taken before any de-duplication - a
          # value that repeats is still the one that ran last.
          winner = unconditional.last
          overridden = unconditional[0..-2].map { |entry| one_line(entry[:source].to_s) }.uniq
          overridden -= [ one_line(winner[:source].to_s) ]
          text = one_line(winner[:source].to_s)
          text += " (overrides #{overridden.join(', ')})" if overridden.any?
          rendered << [ winner[:location].to_i, text ]
        end

        # Source order, because that is run order: a conditional assignment
        # printed after the unconditional one that follows it reads as the
        # value in force.
        rendered.each_with_index.sort_by { |(line, _), index| [ line, index ] }
                .map { |(_, text), _| text }.uniq.join(", ")
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
