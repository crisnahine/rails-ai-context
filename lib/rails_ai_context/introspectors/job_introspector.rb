# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    # Discovers ActiveJob jobs, mailers, and Action Cable channels. Sidekiq
    # reaches this only as config/sidekiq.yml: a class that includes
    # Sidekiq::Worker without subclassing ActiveJob::Base is not a descendant
    # and does not live in app/jobs/, so neither pass here finds it.
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
          mailers: extract_mailers_from_source,
          channels: extract_channels_from_source,
          recurring_jobs: extract_solid_queue_recurring,
          sidekiq_config: extract_sidekiq_config
        }
      end

      private

      def extract_jobs
        return [] unless defined?(ActiveJob::Base)

        ActiveJob::Base.descendants.filter_map do |job|
          next if job.name.nil? || job.name == "ApplicationJob" ||
                  job.name.start_with?("ActionMailer", "ActiveStorage::", "ActionMailbox::", "Turbo::", "Sentry::")
          next unless app_defined?(job)

          queue = job.queue_name
          queue = "dynamic" if queue.is_a?(Proc)

          {
            name: job.name,
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

        File.realpath(location).start_with?("#{app_root_real}/")
      rescue NameError, ArgumentError, TypeError, SystemCallError
        true
      end

      def app_root_real
        @app_root_real ||= File.realpath(app.root.to_s)
      rescue SystemCallError
        @app_root_real = app.root.to_s
      end

      def extract_jobs_from_source
        jobs_dir = File.join(app.root, "app", "jobs")
        return [] unless Dir.exist?(jobs_dir)

        Dir.glob(File.join(jobs_dir, "**/*.rb")).filter_map do |path|
          next unless File.exist?(path) && File.size(path) > 0

          ast = SourceIntrospector.walk(path, {
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

          # Extract class name from AST
          parse_result = AstCache.parse(path)
          name = extract_class_name(parse_result.value)
          next unless name
          next if name == "ApplicationJob"

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
            source = RailsAiContext::SafeFile.read(path)
            if source
              lines = source.lines
              retry_on_hits.each do |hit|
                line = lines[hit[:location] - 1]&.strip
                retry_on << line.sub(/\Aretry_on\s+/, "") if line
              end
              discard_on_hits.each do |hit|
                line = lines[hit[:location] - 1]&.strip
                discard_on << line.sub(/\Adiscard_on\s+/, "") if line
              end
            end
          end

          # Extract perform method signature from AST
          perform_method = ast[:methods].find { |m| m[:name] == "perform" && m[:scope] == :instance }
          perform_signature = nil
          if perform_method && perform_method[:params]&.any?
            perform_signature = perform_method[:params].map { |p|
              case p[:type]
              when :required then p[:name]
              when :optional then "#{p[:name]} = {}"
              when :rest then "*#{p[:name]}"
              when :keyword then "#{p[:name]}:"
              when :keyword_rest then "**#{p[:name]}"
              when :block then "&#{p[:name]}"
              else p[:name]
              end
            }.join(", ")
          end

          # Extract job callbacks
          callback_names = %i[before_enqueue after_enqueue before_perform after_perform around_perform around_enqueue]
          callbacks = ast[:macros]
            .select { |m| callback_names.include?(m[:macro]) }
            .map { |m| m[:macro].to_s }
            .uniq

          job = { name: name }
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

      # Walk a Prism AST tree to find the first class name.
      def extract_class_name(node)
        case node
        when Prism::ProgramNode
          extract_class_name(node.statements)
        when Prism::StatementsNode
          node.body.each do |child|
            result = extract_class_name(child)
            return result if result
          end
          nil
        when Prism::ClassNode
          name_parts = []
          current = node.constant_path
          while current.is_a?(Prism::ConstantPathNode)
            name_parts.unshift(current.name.to_s)
            current = current.parent
          end
          name_parts.unshift(current.name.to_s) if current.is_a?(Prism::ConstantReadNode)
          name_parts.join("::")
        when Prism::ModuleNode
          node.body&.body&.each do |child|
            result = extract_class_name(child)
            return result if result
          end
          nil
        else
          nil
        end
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
        # and mailers are reported as absent. Same pattern as eager_load_channels!.
        eager_load_mailers!

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
            actions: actions,
            delivery_method: mailer.delivery_method.to_s
          }
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
        source_classes(File.join(app.root, "app", "mailers")).filter_map do |name, methods|
          next if name == "ApplicationMailer"

          # The hook is as often a class method as an instance one, so the
          # whole declared method list is what decides, not the action list.
          next if Array(methods).any? { |m| MAILER_FRAMEWORK_HOOKS.include?(m[:name].to_s) }

          actions = ActionResolver.own_actions(methods, class_name: name)
          next if actions.empty?

          { name: name, actions: actions, confidence: RailsAiContext::Confidence::STATIC }
        end.sort_by { |m| m[:name] }
      end

      def extract_channels_from_source
        # ApplicationCable holds the base Channel and Connection, neither of
        # which is a channel of the app's own.
        source_classes(File.join(app.root, "app", "channels")).filter_map do |name, methods|
          next if name.start_with?("ApplicationCable::")

          stream_methods = ActionResolver.own_methods(methods, name)
                                         .select { |m| m[:scope] == :instance }
                                         .map { |m| m[:name] }
                                         .select { |m| m.start_with?("stream_") || m == "subscribed" }
          { name: name, stream_methods: stream_methods, confidence: RailsAiContext::Confidence::STATIC }
        end.sort_by { |c| c[:name] }
      end

      # Class name plus method list for every .rb under `dir`, read from the
      # AST. Yields nothing when the directory is absent.
      #
      # The name comes from the constant the source declares, with the path as
      # the fallback - see DeclaredConstant for which wins when. The path has
      # to stay in the picture because it is the only thing carrying the
      # namespace when the source does not: `class Channel` in
      # `application_cable/channel.rb` matches no base-class filter and no name
      # the booted app would report.
      def source_classes(dir)
        return [] unless Dir.exist?(dir)

        Dir.glob(File.join(dir, "**/*.rb")).sort.filter_map do |path|
          next unless File.exist?(path) && File.size(path) > 0
          next if File.size(path) > RailsAiContext.configuration.max_file_size
          # Rails adds app/*/concerns as its own autoload root, so what lives
          # there is a mixin, not a mailer or a channel - and naming it from
          # the path would invent a `Concerns::` namespace that never exists.
          next if path.sub("#{dir}/", "").start_with?("concerns/")

          source = RailsAiContext::SafeFile.read(path)
          next unless source

          # Whether a declaration belongs here is decided by its own methods -
          # see MAILER_FRAMEWORK_HOOKS - because a mailer's actions are as
          # often written as modules mixed into one class as they are methods
          # on it. Reading the file is only about naming it.
          #
          # The methods are the file's, not one class's, which is what lets a
          # mixin's actions count. The cost: a file declaring both a mailer and
          # an interceptor is read as one, and the hook drops both.
          path_name = path_name_for(path, dir)
          walked = SourceIntrospector.walk_source(source, { methods: Listeners::MethodsListener })
          [ DeclaredConstant.resolve(source, path_name), walked[:methods] || [] ]
        rescue StandardError, ScriptError => e
          $stderr.puts "[rails-ai-context] source_classes failed for #{path}: #{e.message}" if ENV["DEBUG"]
          nil
        end
      end

      # The candidate a path camelizes to. Not the constant when the app
      # registers an inflection for one of its segments, which is why the
      # source gets the first word.
      def path_name_for(path, dir)
        path.sub("#{dir}/", "").sub(/\.rb\z/, "").camelize
      end

      def extract_channels
        return [] unless defined?(ActionCable::Channel::Base)

        # In development (config.eager_load = false), channel files are not
        # loaded until a client subscribes. Without this, .descendants is empty
        # and the entire channels array is missing from the introspector output.
        # Mirrors the eager_load pattern used by ModelIntrospector / ControllerIntrospector.
        eager_load_channels!

        ActionCable::Channel::Base.descendants.filter_map do |channel|
          next if channel.name.nil? || channel.name == "ApplicationCable::Channel"

          source = channel_source(channel)

          {
            name:           channel.name,
            file:           channel_relative_path(channel),
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

      def eager_load_channels!
        return if Rails.application.config.eager_load

        channels_path = File.join(app.root, "app", "channels")
        if defined?(Zeitwerk) && Dir.exist?(channels_path) &&
           Rails.autoloaders.respond_to?(:main) && Rails.autoloaders.main.respond_to?(:eager_load_dir)
          Rails.autoloaders.main.eager_load_dir(channels_path)
        end
      rescue StandardError, ScriptError => e
        $stderr.puts "[rails-ai-context] eager_load_channels! failed: #{e.message}" if ENV["DEBUG"]
        nil
      end

      def eager_load_mailers!
        return if Rails.application.config.eager_load

        mailers_path = File.join(app.root, "app", "mailers")
        if defined?(Zeitwerk) && Dir.exist?(mailers_path) &&
           Rails.autoloaders.respond_to?(:main) && Rails.autoloaders.main.respond_to?(:eager_load_dir)
          Rails.autoloaders.main.eager_load_dir(mailers_path)
        end
      rescue StandardError, ScriptError => e
        $stderr.puts "[rails-ai-context] eager_load_mailers! failed: #{e.message}" if ENV["DEBUG"]
        nil
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

      def channel_relative_path(channel)
        path = channel_absolute_path(channel)
        return nil unless path
        rails_root = app.root.to_s
        path.start_with?(rails_root) ? path.sub("#{rails_root}/", "") : path
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
