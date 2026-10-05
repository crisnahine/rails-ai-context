# frozen_string_literal: true

require "yaml"

module RailsAiContext
  module Introspectors
    # Recurring tasks from each scheduler's own file, in the shape each gem reads it:
    # Solid Queue's config/recurring.yml, sidekiq-cron's config/schedule.yml,
    # sidekiq-scheduler's section of config/sidekiq.yml, GoodJob's
    # `config.good_job.cron` and whenever's config/schedule.rb.
    # Each task: { name:, class:, command:, schedule:, env:, file: }.
    module RecurringSchedules
      module_function

      def read(root, walks = {})
        solid_queue(root) + sidekiq_cron(root) + sidekiq_scheduler(root) + good_job(root, walks) + whenever(root)
      end

      # `walks` memoizes by file, so every reader of one config file in a run shares a walk.
      def config_assignments(root, file, walks = {})
        walks.fetch(file) do
          source = read_file(root, file)
          walks[file] = source ? Array(SourceIntrospector.walk_source(source, { config: Listeners::ConfigAssignmentListener })[:config]) : []
        end
      end

      # Solid Queue takes the section named for the environment, else the whole file,
      # and keeps only the entries that carry a `schedule`.
      def solid_queue(root)
        file = "config/recurring.yml"
        data = yaml(root, file)
        return [] unless data.is_a?(Hash)

        data.flat_map do |key, value|
          next [] unless value.is_a?(Hash)
          next [ task(file, key, value, :schedule) ].compact if value.key?("schedule")

          value.filter_map { |name, options| task(file, name, options, :schedule, env: key) }
        end
      end

      def sidekiq_cron(root)
        %w[config/schedule.yml config/schedule.yaml config/sidekiq_cron.yml].flat_map do |file|
          named_tasks(yaml(root, file)).filter_map { |name, options| task(file, name, options, :cron) }
        end
      end

      # sidekiq-scheduler runs a job by its entry's name when no class is given.
      def sidekiq_scheduler(root)
        file = "config/sidekiq.yml"
        data = yaml(root, file)
        return [] unless data.is_a?(Hash)

        section = data["scheduler"].is_a?(Hash) ? data["scheduler"]["schedule"] : data["schedule"]
        named_tasks(section).filter_map do |name, options|
          next unless options.is_a?(Hash)

          kind = SCHEDULER_KEYS.find { |key| options.key?(key.to_s) } or next
          task(file, name, { "class" => name }.merge(options), kind)
        end
      end

      SCHEDULER_KEYS = %i[cron every at in interval].freeze

      GOOD_JOB_FILES = %w[config/application.rb config/environments/*.rb config/initializers/*.rb].freeze

      def good_job(root, walks = {})
        GOOD_JOB_FILES.flat_map { |pattern| Dir.glob(pattern, base: root.to_s).sort }.flat_map do |file|
          next [] unless walks.key?(file) || read_file(root, file)&.include?("good_job")

          env = File.basename(file, ".rb") if file.start_with?("config/environments/")
          config_assignments(root, file, walks).select { |hit| hit[:path] == %i[good_job cron] && hit[:value].is_a?(Hash) }.flat_map do |hit|
            hit[:value].filter_map { |name, options| task(file, name, stringify(options), :cron, env: env) }
          end
        end
      end

      WHENEVER_JOBS = %i[runner rake command].freeze

      # `every 1.day, at: "4:30 am" do runner "CleanupJob.perform_later" end`: the job is
      # the constant the runner's code starts with.
      def whenever(root)
        file = "config/schedule.rb"
        source = read_file(root, file) or return []
        hits = SourceIntrospector.walk_source(source, {
          every: -> { Listeners::GenericMacroListener.new(:every, *WHENEVER_JOBS) }
        })[:every]
        everies = hits.select { |hit| hit[:macro] == :every }.to_h { |hit| [ hit[:offset], hit ] }
        hits.filter_map do |hit|
          every = everies[hit[:parent_offset]]
          code = hit[:values].first
          next unless every && WHENEVER_JOBS.include?(hit[:macro]) && code.is_a?(String)

          klass = code[/\A\s*(?:::)?([A-Z]\w*(?:::[A-Z]\w*)*)\./, 1] if hit[:macro] == :runner
          { class: klass, command: hit[:macro] == :runner ? code : "#{hit[:macro]} #{code}",
            schedule: whenever_schedule(every), file: file }.compact
        end
      rescue StandardError, ScriptError => e
        RailsAiContext.debug_fail(e, [], label: "whenever schedule")
      end

      def whenever_schedule(every)
        text = "every #{every[:values].first}"
        at = every[:option_values][:at]
        at ? "#{text} at #{at}" : text
      end

      def task(file, name, options, kind, env: nil)
        return nil unless options.is_a?(Hash)

        options = options.transform_values { |value| value == RailsAiContext::Confidence::INFERRED ? :computed : value }
        schedule = options[kind.to_s]
        return nil if schedule.nil?

        klass = options["class"] || options["klass"]
        klass = nil if klass == :computed
        command = options["command"] unless options["command"] == :computed
        { name: name.to_s, class: klass&.to_s&.delete_prefix("::"), command: command&.to_s,
          schedule: schedule.to_s, env: env&.to_s, file: file }.compact
      end

      # sidekiq-cron accepts a hash keyed by name or a list of hashes that carry it.
      def named_tasks(data)
        case data
        when Hash then data.to_a
        when Array then data.filter_map { |entry| [ entry["name"], entry ] if entry.is_a?(Hash) }
        else []
        end
      end

      def stringify(value)
        value.is_a?(Hash) ? value.to_h { |key, inner| [ key.to_s, inner ] } : value
      end

      def yaml(root, file)
        content = read_file(root, file) or return nil
        stringify_keys(YAML.safe_load(ErbSource.without_tags(content), aliases: true, permitted_classes: [ Symbol ]))
      rescue StandardError, ScriptError => e
        RailsAiContext.debug_fail(e, nil, label: "schedule #{file}")
      end

      def stringify_keys(value)
        case value
        when Hash then value.to_h { |key, inner| [ key.to_s.delete_prefix(":"), stringify_keys(inner) ] }
        when Array then value.map { |inner| stringify_keys(inner) }
        else value
        end
      end

      def read_file(root, file)
        SafePath.read(file, under: root.to_s).first
      end
    end
  end
end
