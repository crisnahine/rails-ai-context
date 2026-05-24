# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    # Discovers background jobs (ActiveJob/Sidekiq), mailers,
    # and Action Cable channels.
    class JobIntrospector
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

      private

      def extract_jobs
        return [] unless defined?(ActiveJob::Base)

        ActiveJob::Base.descendants.filter_map do |job|
          next if job.name.nil? || job.name == "ApplicationJob" ||
                  job.name.start_with?("ActionMailer", "ActiveStorage::", "ActionMailbox::", "Turbo::", "Sentry::")

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

        ActionMailer::Base.descendants.filter_map do |mailer|
          next if mailer.name.nil?

          actions = mailer.instance_methods(false).map(&:to_s).sort
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
      rescue => e
        $stderr.puts "[rails-ai-context] eager_load_channels! failed: #{e.message}" if ENV["DEBUG"]
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

      # `identified_by :current_user, :tenant` — declared on ApplicationCable::Connection,
      # but channels can also use it. Returns array of attribute names.
      def extract_identified_by(source)
        return nil unless source
        matches = source.scan(/\bidentified_by\s+([^\n]+)/)
        return nil if matches.empty?
        matches.flat_map { |m| m.first.scan(/:(\w+)/).flatten }.uniq
      end

      # `stream_from "channel_name"` and `stream_for object` — what the channel broadcasts.
      def extract_channel_streams(source)
        return nil unless source
        from_targets = source.scan(/\bstream_from\s+["']([^"']+)["']/).flatten
        for_targets  = source.scan(/\bstream_for\s+([^\s\n,]+)/).flatten
        result = {}
        result[:stream_from] = from_targets.uniq if from_targets.any?
        result[:stream_for]  = for_targets.uniq  if for_targets.any?
        result.empty? ? nil : result
      end

      # `periodically :method_name, every: 3.seconds`
      # The `[^\n]+` capture group is already line-bounded, so we keep the full
      # captured value (after stripping whitespace). Earlier versions tried to
      # trim past the first comma/whitespace, which mangled lambdas and
      # complex intervals like `-> { current_user.interval }`.
      def extract_channel_periodic(source)
        return nil unless source
        timers = source.scan(/\bperiodically\s+:(\w+),\s*every:\s*([^\n]+)/).map do |method_name, interval|
          { method: method_name, every: interval.strip }
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
