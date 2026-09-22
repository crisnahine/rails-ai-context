# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    # Discovers ActiveJob jobs, mailers, Action Cable channels, and the
    # Sidekiq workers that are none of those: a class that includes
    # Sidekiq::Job or Sidekiq::Worker is not an ActiveJob descendant and does
    # not live in app/jobs/, so both job passes miss it. On an app that runs
    # its background work that way, workers are the whole picture.
    class JobIntrospector
      extend StaticTier
      static_tier :alternate_source

      CHANNEL_MACROS = %i[identified_by stream_from stream_for periodically].freeze

      attr_reader :app

      def initialize(app)
        @app = app
      end

      # @return [Hash] async workers, mailers, and channels
      def call
        jobs = extract_jobs
        # Source parsing fallback when runtime reflection yields no results
        jobs = extract_jobs_from_source if jobs.empty?

        {
          jobs: jobs,
          workers: extract_workers,
          mailers: extract_mailers,
          channels: extract_channels,
          recurring_jobs: extract_solid_queue_recurring,
          sidekiq_config: extract_sidekiq_config
        }
      end

      # Mailers and channels are ordinary classes in ordinary directories, so
      # the answer is the same with or without a booted app. Only the way in
      # differs: descendants when Rails is up, the AST when it is not.
      def static_call
        {
          jobs: extract_jobs_from_source,
          workers: extract_workers,
          mailers: extract_mailers_from_source,
          channels: extract_channels_from_source,
          recurring_jobs: extract_solid_queue_recurring,
          sidekiq_config: extract_sidekiq_config
        }
      end

      private

      def extract_jobs
        return [] unless defined?(ActiveJob::Base)

        EagerLoad.dir(app.root, kind: "app/jobs")

        ActiveJob::Base.descendants.filter_map do |job|
          next if job.name.nil? || job.name == "ApplicationJob" ||
                  job.name.start_with?("ActionMailer", "ActiveStorage::", "ActionMailbox::", "Turbo::", "Sentry::")
          next unless app_defined?(job)

          queue = job.queue_name
          queue = "dynamic" if queue.is_a?(Proc)

          {
            name: job.name,
            file: source_file_for(job),
            queue: queue.to_s,
            priority: job.priority
          }.compact
        end.sort_by { |j| j[:name] }
      rescue => e
        $stderr.puts "[rails-ai-context] extract_jobs failed: #{e.message}" if ENV["DEBUG"]
        []
      end

      # `descendants` is every ActiveJob subclass in the process, and the name
      # prefixes above only cover the framework's own - a job from any other gem
      # was counted as the app's. Where the class is defined answers it for gems
      # the list has never heard of. A class with no source location stays:
      # dropping one would understate what the app runs.
      def app_defined?(job)
        location = Object.const_source_location(job.name)&.first
        return true unless location

        SourceScan.under_root?(location, File.realpath(location), app.root.to_s, app_root_real)
      rescue NameError, ArgumentError, TypeError, SystemCallError
        true
      end

      def app_root_real
        @app_root_real ||= File.realpath(app.root.to_s)
      rescue SystemCallError
        @app_root_real = app.root.to_s
      end

      def extract_jobs_from_source
        SourceScan.classes(app.root, kind: "app/jobs").filter_map do |name, record|
          next if name == "ApplicationJob"

          ast = SourceIntrospector.walk_source(record.source, {
            macros: -> {
              Listeners::GenericMacroListener.new(
                :queue_as, :retry_on, :discard_on,
                :before_enqueue, :after_enqueue,
                :before_perform, :after_perform,
                :around_perform, :around_enqueue
              )
            },
            methods: Listeners::MethodsListener
          })

          # Extract queue_as
          queue_hit = ast[:macros].find { |m| m[:macro] == :queue_as }
          queue = queue_hit[:args].first.to_s if queue_hit && queue_hit[:args].any?

          # Extract retry_on declarations (need source text for full arg string)
          retry_on_hits = ast[:macros].select { |m| m[:macro] == :retry_on }
          discard_on_hits = ast[:macros].select { |m| m[:macro] == :discard_on }

          # For retry_on/discard_on, reconstruct the argument text from source
          # since the full argument string includes constants and keyword args
          retry_on = []
          discard_on = []
          if retry_on_hits.any? || discard_on_hits.any?
            lines = record.source.lines
            retry_on_hits.each do |hit|
              line = lines[hit[:location] - 1]&.strip
              retry_on << line.sub(/\Aretry_on\s+/, "") if line
            end
            discard_on_hits.each do |hit|
              line = lines[hit[:location] - 1]&.strip
              discard_on << line.sub(/\Adiscard_on\s+/, "") if line
            end
          end

          perform_method = ast[:methods].find { |m| m[:name] == "perform" && m[:scope] == :instance }
          perform_signature = ActionResolver.parameter_list(perform_method) if perform_method && perform_method[:params]&.any?

          # Extract job callbacks
          callback_names = %i[before_enqueue after_enqueue before_perform after_perform around_perform around_enqueue]
          callbacks = ast[:macros]
            .select { |m| callback_names.include?(m[:macro]) }
            .map { |m| m[:macro].to_s }
            .uniq

          job = { name: name, file: record.file }
          job[:queue] = queue if queue
          job[:retry_on] = retry_on if retry_on.any?
          job[:discard_on] = discard_on if discard_on.any?
          job[:perform_signature] = perform_signature if perform_signature
          job[:callbacks] = callbacks if callbacks.any?
          job
        end.sort_by { |j| j[:name] }
      rescue => e
        $stderr.puts "[rails-ai-context] extract_jobs_from_source failed: #{e.message}" if ENV["DEBUG"]
        []
      end

      # Sidekiq workers, read from source in both tiers: the class is not an
      # ActiveJob descendant, so reflection has no list to walk.
      WORKER_MIXINS = %w[Sidekiq::Job Sidekiq::Worker].freeze

      def extract_workers
        SourceScan.each(app.root, kind: "app/workers").filter_map do |record|
          next unless WORKER_MIXINS.any? { |mixin| record.source.include?(mixin) }

          ast = SourceIntrospector.walk_source(record.source, {
            macros:  -> { Listeners::GenericMacroListener.new(:sidekiq_options, :include) },
            methods: Listeners::MethodsListener
          })
          next unless ast[:macros].any? { |m| m[:macro] == :include && m[:values].flatten.map(&:to_s).any? { |v| WORKER_MIXINS.include?(v) } }

          options = ast[:macros].find { |m| m[:macro] == :sidekiq_options }
          perform = ast[:methods].find { |m| m[:name] == "perform" && m[:scope] == :instance }

          {
            name: DeclaredConstant.resolve(record.source, record.path_name),
            file: record.file,
            options: options ? (options[:option_values] || {}).transform_keys(&:to_s) : {},
            perform_signature: perform && perform[:params]&.any? ? ActionResolver.parameter_list(perform) : nil
          }.compact
        end.sort_by { |w| w[:name] }
      rescue => e
        $stderr.puts "[rails-ai-context] extract_workers failed: #{e.message}" if ENV["DEBUG"]
        []
      end

      def extract_solid_queue_recurring
        paths = [
          File.join(app.root, "config", "recurring.yml"),
          File.join(app.root, "config", "solid_queue.yml")
        ]
        path = paths.find { |p| File.exist?(p) }
        return [] unless path

        content = RailsAiContext::SafeFile.read(path)
        return [] unless content
        jobs = []
        content.scan(/(\w+):\s*\n\s+class:\s*(\w+).*?(?:schedule:\s*["']?([^"'\n]+))?/m) do |name, klass, schedule|
          jobs << { name: name, class: klass, schedule: schedule&.strip }.compact
        end
        jobs
      rescue => e
        $stderr.puts "[rails-ai-context] extract_solid_queue_recurring failed: #{e.message}" if ENV["DEBUG"]
        []
      end

      def extract_sidekiq_config
        path = File.join(app.root, "config", "sidekiq.yml")
        return nil unless File.exist?(path)

        content = RailsAiContext::SafeFile.read(path)
        return nil unless content
        config = {}
        config[:concurrency] = $1.to_i if content.match(/concurrency:\s*(\d+)/)
        queues = content.scan(/-\s*(?:\[?\s*)?(\w+)/).flatten.uniq
        config[:queues] = queues if queues.any?
        config.empty? ? nil : config
      rescue => e
        $stderr.puts "[rails-ai-context] extract_sidekiq_config failed: #{e.message}" if ENV["DEBUG"]
        nil
      end

      def extract_mailers
        return [] unless defined?(ActionMailer::Base)

        # In development (config.eager_load = false), mailer files are not
        # loaded until first delivery. Without this, .descendants is empty
        # and mailers are reported as absent.
        EagerLoad.dir(app.root, kind: "app/mailers")

        ActionMailer::Base.descendants.filter_map do |mailer|
          next if mailer.name.nil?

          # Reflection with the app-base subtraction: `action_methods` stops
          # subtracting at the framework base, so a public helper on a
          # non-abstract ApplicationMailer would arrive as a deliverable
          # action - the mailer reading of the controller leak.
          actions = ActionResolver.reflected_actions(mailer, kind: :mailer)
          next if actions.empty?

          {
            name: mailer.name,
            file: source_file_for(mailer),
            actions: actions,
            delivery_method: mailer.delivery_method.to_s
          }.compact
        end.sort_by { |m| m[:name] }
      rescue => e
        $stderr.puts "[rails-ai-context] extract_mailers failed: #{e.message}" if ENV["DEBUG"]
        []
      end

      # A mailer's actions are its public instance methods, and the AST sees
      # one file at a time. `action_methods` counts the public methods a mailer
      # inherits too, so a public helper on a base class is an action the
      # booted tier reports and this one cannot - the entries are tagged STATIC
      # for that reason.
      # ActionMailer's interceptor and observer hooks. A class or module under
      # app/mailers that implements one is registered with the framework, not
      # delivered by it: reporting OpenProject's Interceptors::DefaultHeaders
      # as a mailer offered `delivering_email` as an email somebody can send.
      # Everything else in that directory stays - a mailer's actions are as
      # often written as modules mixed into one class as they are methods on
      # it, and GitLab keeps 20 such modules holding every notification it
      # sends.
      MAILER_FRAMEWORK_HOOKS = %w[delivering_email previewing_email delivered_email].freeze

      def extract_mailers_from_source
        source_classes("app/mailers").filter_map do |name, methods, file|
          next if name == "ApplicationMailer"

          # The hook is as often a class method as an instance one, so the
          # whole declared method list is what decides, not the action list.
          next if Array(methods).any? { |m| MAILER_FRAMEWORK_HOOKS.include?(m[:name].to_s) }

          actions = ActionResolver.own_actions(methods, class_name: name)
          next if actions.empty?

          { name: name, file: file, actions: actions, confidence: RailsAiContext::Confidence::STATIC }
        end.sort_by { |m| m[:name] }
      end

      def extract_channels_from_source
        # ApplicationCable holds the base Channel and Connection, neither of
        # which is a channel of the app's own.
        source_classes("app/channels").filter_map do |name, methods, file|
          next if name.start_with?("ApplicationCable::")

          stream_methods = ActionResolver.own_methods(methods, name)
                                         .select { |m| m[:scope] == :instance }
                                         .map { |m| m[:name] }
                                         .select { |m| m.start_with?("stream_") || m == "subscribed" }
          { name: name, file: file, stream_methods: stream_methods, confidence: RailsAiContext::Confidence::STATIC }
        end.sort_by { |c| c[:name] }
      end

      # Class name, method list and file for every .rb of a kind, read from
      # the AST. Concerns stay out: Rails adds app/*/concerns as its own
      # autoload root, so what lives there is a mixin, not a mailer or a
      # channel.
      #
      # The name comes from the constant the source declares, with the path as
      # the fallback - see DeclaredConstant for which wins when. The path has
      # to stay in the picture because it is the only thing carrying the
      # namespace when the source does not: `class Channel` in
      # `application_cable/channel.rb` matches no base-class filter and no name
      # the booted app would report.
      def source_classes(kind)
        SourceScan.each(app.root, kind: kind).filter_map do |record|
          next if record.source.empty?

          # Whether a declaration belongs here is decided by its own methods -
          # see MAILER_FRAMEWORK_HOOKS - because a mailer's actions are as
          # often written as modules mixed into one class as they are methods
          # on it. Reading the file is only about naming it.
          #
          # The methods are the file's, not one class's, which is what lets a
          # mixin's actions count. The cost: a file declaring both a mailer and
          # an interceptor is read as one, and the hook drops both.
          walked = SourceIntrospector.walk_source(record.source, { methods: Listeners::MethodsListener })
          [ DeclaredConstant.resolve(record.source, record.path_name), walked[:methods] || [], record.file ]
        rescue StandardError, ScriptError => e
          $stderr.puts "[rails-ai-context] source_classes failed for #{record.path}: #{e.message}" if ENV["DEBUG"]
          nil
        end
      end

      # The file a loaded class was read from, root-relative; nil when the
      # constant has no source location or it lies outside the app. Compared
      # as real paths, the way app_defined? does, so a symlinked root keeps it.
      def source_file_for(klass)
        location = Object.const_source_location(klass.name)&.first
        return nil unless location

        real = File.realpath(location)
        root = app.root.to_s
        return nil unless SourceScan.under_root?(location, real, root, app_root_real)

        SourceScan.relative_file(location, real, root, app_root_real)
      rescue NameError, ArgumentError, TypeError, SystemCallError
        nil
      end

      def extract_channels
        return [] unless defined?(ActionCable::Channel::Base)

        # In development (config.eager_load = false), channel files are not
        # loaded until a client subscribes. Without this, .descendants is empty
        # and the entire channels array is missing from the introspector output.
        EagerLoad.dir(app.root, kind: "app/channels")

        ActionCable::Channel::Base.descendants.filter_map do |channel|
          next if channel.name.nil? || channel.name == "ApplicationCable::Channel"

          source = channel_source(channel)

          {
            name:           channel.name,
            file:           source_file_for(channel),
            stream_methods: channel.instance_methods(false)
              .select { |m| m.to_s.start_with?("stream_") || m == :subscribed }
              .map(&:to_s),
            identified_by:  extract_identified_by(source),
            streams:        extract_channel_streams(source),
            periodic:       extract_channel_periodic(source),
            actions:        extract_channel_actions(channel)
          }.compact
        end.sort_by { |c| c[:name] }
      rescue => e
        $stderr.puts "[rails-ai-context] extract_channels failed: #{e.message}" if ENV["DEBUG"]
        []
      end

      def channel_source(channel)
        path = channel_absolute_path(channel)
        return nil unless path && File.exist?(path)
        RailsAiContext::SafeFile.read(path)
      end

      def channel_absolute_path(channel)
        method_source = channel.instance_methods(false).first
        return nil unless method_source
        location = channel.instance_method(method_source).source_location
        location&.first
      rescue => e
        $stderr.puts "[rails-ai-context] channel_absolute_path failed: #{e.message}" if ENV["DEBUG"]
        nil
      end

      def channel_macros(source, macro)
        return [] unless source
        ast = SourceIntrospector.walk_source(source, {
          channel: -> { Listeners::GenericMacroListener.new(CHANNEL_MACROS) }
        })
        ast[:channel].select { |hit| hit[:macro] == macro }
      end

      # `identified_by :current_user, :tenant` - declared on ApplicationCable::Connection,
      # but channels can also use it. Returns array of attribute names.
      def extract_identified_by(source)
        hits = channel_macros(source, :identified_by)
        return nil if hits.empty?
        hits.flat_map { |hit| hit[:args].map(&:to_s) }.uniq
      end

      # `stream_from "channel_name"` and `stream_for object` - what the channel broadcasts.
      def extract_channel_streams(source)
        return nil unless source
        from_targets = channel_macros(source, :stream_from).filter_map { |hit| hit[:values].first&.to_s }
        for_targets  = channel_macros(source, :stream_for).filter_map { |hit| hit[:values].first&.to_s }
        result = {}
        result[:stream_from] = from_targets.uniq if from_targets.any?
        result[:stream_for]  = for_targets.uniq  if for_targets.any?
        result.empty? ? nil : result
      end

      # `periodically :method_name, every: 3.seconds`. The interval keeps its
      # source form so lambdas like `-> { current_user.interval }` survive whole.
      def extract_channel_periodic(source)
        timers = channel_macros(source, :periodically).filter_map do |hit|
          method_name = hit[:args].first
          next unless method_name
          { method: method_name.to_s, every: hit[:option_values][:every].to_s }
        end
        timers.any? ? timers : nil
      end

      # RPC actions = public instance methods that aren't lifecycle hooks or stream helpers.
      def extract_channel_actions(channel)
        ignored = %i[subscribed unsubscribed]
        actions = channel.instance_methods(false).reject do |m|
          ignored.include?(m) || m.to_s.start_with?("stream_")
        end
        actions.empty? ? nil : actions.map(&:to_s).sort
      end
    end
  end
end
