# frozen_string_literal: true

module RailsAiContext
  module Tools
    class GetJobPattern < BaseTool
      tool_name "rails_get_job_pattern"
      description "Analyze background jobs in app/jobs/: queues, retries, perform signatures, guards, and what they call. " \
        "Use when: understanding job infrastructure, adding a new job, or tracing async workflows. " \
        "Specify job:\"SendWelcomeEmail\" for full detail, or omit to list all jobs with queue names and retry config."

      input_schema(
        properties: {
          job: {
            type: "string",
            description: "Job class name or filename (e.g. 'SendWelcomeEmailJob', 'send_welcome_email'). Omit to list all jobs."
          },
          detail: RailsAiContext::DetailLevel.schema("Detail level. summary: names + queues. standard: names + queues + retries + what they call (default). full: everything including guards, broadcasts, schedules, and enqueuers.")
        }
      )

      guide_row(
        order: 16,
        mcp: "rails_get_job_pattern",
        summary: "Jobs: queue, retries, guard clauses, broadcasts, schedules"
      )

      annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true, open_world_hint: false)

      NOT_COVERED = "Workers the introspector did not see (a Sidekiq worker outside app/workers/, for example) are not covered by this tool."
      UNSEEN_WORKERS = "Workers the introspector did not see are not covered by this tool."

      def self.call(job: nil, detail: "standard", server_context: nil)
        real_root = File.realpath(rails_app.root.to_s).to_s
        # The payload is the one list of jobs: it walked every job directory
        # the app has and carries the file each one was read from.
        jobs = RailsAiContext::Payload.jobs(cached_context).select { |j| j.is_a?(Hash) && j[:name] }

        # Pull enriched channel data from the cached introspector context - this
        # gives us the v5.8.0 fields (identified_by, streams, periodic, actions)
        # that JobIntrospector#extract_channels populates.
        jobs_data = cached_context[:jobs]
        channels = (jobs_data.is_a?(Hash) ? jobs_data[:channels] : nil) || []
        channels = channels.reject { |c| c.is_a?(Hash) && c[:error] }
        channels_note = unavailable_note(jobs_data)

        sidekiq_line = sidekiq_queues_line(jobs_data)
        workers = (jobs_data.is_a?(Hash) ? jobs_data[:workers] : nil) || []

        return format_single_job(job, jobs, real_root, sidekiq_line, workers) if job

        # No jobs and no channels - bail out. Channel absence is only a real
        # negative when the :jobs section actually ran - if it's unavailable
        # (static tier), say so instead of claiming "no channels detected".
        if jobs.empty? && channels.empty? && workers.empty?
          return text_response(no_jobs_or_channels_message(channels_note, sidekiq_line))
        end

        # Compose: jobs section (if any) + workers + channels section (if any).
        lines = []
        lines.concat(format_job_listing_lines(jobs, real_root, detail)) if jobs.any?
        if workers.any?
          lines << "" if lines.any?
          lines.concat(format_workers_section(workers, detail))
        end
        if channels.any?
          lines << "" if lines.any?
          lines.concat(format_channels_section(channels))
        end
        # A count of the jobs and workers the introspector saw is still a claim
        # about the app's async work, and an app that names its Sidekiq config
        # anything but config/sidekiq.yml used to get the count with no caveat
        # at all. The queues are a bonus when that file does exist.
        lines << "" if lines.any?
        lines << "_#{[ sidekiq_line, UNSEEN_WORKERS ].compact.join(" ")}_"
        text_response(lines.join("\n"))
      end

      # A Sidekiq worker is not an ActiveJob job, and on an app that runs its
      # background work this way it is the only async code there is.
      private_class_method def self.format_workers_section(workers, detail)
        lines = [ "## Sidekiq Workers (#{workers.size})", "" ]
        workers.each do |worker|
          options = worker[:options] || {}
          bits = options.map { |key, value| "#{key}: #{value}" }
          label = bits.any? ? " [#{bits.join(', ')}]" : ""
          lines << "- **#{worker[:name]}**#{label}"
          next unless RailsAiContext::DetailLevel.full?(detail) || detail == "standard"

          lines << "  - throttle: #{worker[:throttle]}" if worker[:throttle]
          lines << "  - `perform(#{worker[:perform_signature]})`" if worker[:perform_signature]
          lines << "  - `#{worker[:file]}`" if worker[:file]
        end
        lines
      end

      private_class_method def self.no_job_files_message(sidekiq_line = nil)
        [ "No jobs found. #{NOT_COVERED}", sidekiq_line ].compact.join(" ")
      end

      # The "nothing async at all" bail-out, phrased to keep reading naturally
      # when appended to the channels clause. `channels_note` carries an
      # [UNAVAILABLE: ...] marker when the :jobs section never ran (static
      # tier) - in that case, asserting "no Action Cable channels detected"
      # would be a fabricated negative rather than an observed one, so the
      # note replaces that claim instead of joining it.
      private_class_method def self.no_jobs_or_channels_message(channels_note, sidekiq_line = nil)
        channels_clause = channels_note || "no Action Cable channels detected"
        [ "No jobs found, and #{channels_clause}. #{NOT_COVERED}", sidekiq_line ].compact.join(" ")
      end

      # JobIntrospector#extract_sidekiq_config already read this file, and on an
      # app that runs everything through Sidekiq workers it is the only evidence
      # in reach that async work happens at all.
      private_class_method def self.sidekiq_queues_line(jobs_data)
        config = jobs_data.is_a?(Hash) ? jobs_data[:sidekiq_config] : nil
        return nil unless config.is_a?(Hash)

        queues = Array(config[:queues])
        return nil if queues.empty?

        line = "config/sidekiq.yml declares #{count_phrase(queues.size, "queue")}: #{queues.join(', ')}"
        line += " (concurrency: #{config[:concurrency]})" if config[:concurrency]
        "#{line}."
      end

      # The name never rebuilds the path: the file is the one the introspector
      # recorded, which is the only place a pack job's path is written down.
      private_class_method def self.format_single_job(job, jobs, root, sidekiq_line, workers = [])
        names = jobs.map { |j| j[:name] }
        worker_names = workers.map { |w| w[:name] }.compact
        return text_response(no_job_files_message(sidekiq_line)) if names.empty? && worker_names.empty?

        # "SendWelcomeEmailJob", "send_welcome_email_job" and "send_welcome_email" all name one job.
        query = job.to_s.delete_suffix(".rb")
        class_name = fuzzy_find_key(names, query) ||
                     fuzzy_find_key(names, "#{query.underscore.delete_suffix("_job")}_job")
        relative = class_name && RailsAiContext::Payload.job_file(cached_context, class_name)
        unless relative
          # A Sidekiq worker is not in the ActiveJob list, and the listing
          # above it prints both, so the name a reader copied is in either.
          worker_name = fuzzy_find_key(worker_names, query)
          worker = worker_name && workers.find { |w| w[:name] == worker_name }
          if worker
            class_name = worker_name
            relative = worker[:file]
          else
            return not_found_response("Job", job, (names + worker_names).sort,
              recovery_tool: "Call rails_get_job_pattern(detail:\"summary\") to see all jobs")
          end
        end

        file = File.join(root, relative)
        return text_response("Job file too large to analyze.") if File.file?(file) && File.size(file) > max_file_size

        source = safe_read(file)
        return text_response("Could not read job file.") unless source

        line_count = source.lines.size

        lines = [ "# #{class_name}", "" ]
        lines << "**File:** `#{relative}` (#{count_phrase(line_count, "line")})"

        # Queue
        queue = extract_queue(source)
        lines << "**Queue:** `#{queue}`" if queue

        # Retry/discard configuration
        retry_config = extract_retry_config(source)
        if retry_config.any?
          lines << "" << "## Retry Configuration"
          retry_config.each { |r| lines << "- #{r}" }
        end

        # Perform method signature
        perform_sig = extract_perform_signature(source)
        lines << "**Perform:** `#{perform_sig}`" if perform_sig

        # Guard clauses
        guards = extract_guard_clauses(source)
        if guards.any?
          lines << "" << "## Guard Clauses"
          guards.each { |g| lines << "- `#{g}`" }
        end

        # What service/class is called
        dependencies = extract_dependencies(source, class_name)
        if dependencies.any?
          lines << "" << "## Calls"
          dependencies.each { |d| lines << "- `#{d}`" }
        end

        # Turbo broadcasts
        broadcasts = extract_broadcasts(source)
        if broadcasts.any?
          lines << "" << "## Turbo Broadcasts"
          broadcasts.each { |b| lines << "- `#{b}`" }
        end

        # Sidekiq-cron / recurring schedule
        schedule = extract_schedule(source, class_name, root)
        lines << "**Schedule:** #{schedule}" if schedule

        # Side effects
        side_effects = extract_side_effects(source)
        if side_effects.any?
          lines << "" << "## Side Effects"
          side_effects.each { |s| lines << "- #{s}" }
        end

        # Cross-reference: who enqueues this job
        enqueuers = find_enqueuers(class_name, root)
        if enqueuers.any?
          lines << "" << "## Enqueued By"
          enqueuers.each { |e| lines << "- `#{e}`" }
        end

        # Cross-reference hints
        lines << "" << "_Next: `rails_search_code(pattern:\"#{class_name}\")` for all references_"

        text_response(lines.join("\n"))
      end

      # One entry per payload job. The source, read through the carried file,
      # adds what the payload does not hold; a job reflection found with no
      # file still lists with what the payload carries.
      private_class_method def self.format_job_listing_lines(jobs, root, detail)
        job_data = jobs.map do |job|
          relative = job[:file]
          source = relative && safe_read(File.join(root, relative))
          class_name = job[:name]

          {
            file: relative,
            class_name: class_name,
            line_count: source&.lines&.size,
            queue: job[:queue].presence || (source && extract_queue(source)),
            retry_config: source ? extract_retry_config(source) : Array(job[:retry_on]) + Array(job[:discard_on]),
            perform_sig: source ? extract_perform_signature(source) : job[:perform_signature],
            dependencies: source ? extract_dependencies(source, class_name) : []
          }
        end

        total = job_data.size
        lines = [ "# Background Jobs (#{total})", "" ]

        # Queue summary
        queues = job_data.map { |j| j[:queue] || "default" }.tally.sort_by { |_, c| -c }
        if queues.any?
          queue_str = queues.map { |q, c| "#{q}(#{c})" }.join(", ")
          lines << "**Queues:** #{queue_str}"
          lines << ""
        end

        case detail
        when "summary"
          job_data.each do |j|
            queue_label = j[:queue] ? " [#{j[:queue]}]" : ""
            lines << "- #{j[:class_name]}#{queue_label}"
          end
          lines << "" << "_Use `job:\"Name\"` for full detail, or `detail:\"standard\"` for retries and dependencies._"

        when "standard"
          job_data.each do |j|
            queue_label = j[:queue] ? " [#{j[:queue]}]" : ""
            retry_label = j[:retry_config].any? ? " - #{j[:retry_config].first}" : ""
            deps_label = j[:dependencies].any? ? " → #{j[:dependencies].join(', ')}" : ""
            size_label = j[:line_count] ? " (#{count_phrase(j[:line_count], "line")})" : ""
            lines << "- **#{j[:class_name]}**#{queue_label}#{size_label}#{retry_label}#{deps_label}"
          end
          lines << "" << "_Use `job:\"Name\"` for guards, broadcasts, schedules, and enqueuers._"

        when "full"
          job_data.each do |j|
            lines << "## #{j[:class_name]}"
            lines << "- **File:** `#{j[:file]}` (#{count_phrase(j[:line_count], "line")})" if j[:line_count]
            lines << "- **Queue:** `#{j[:queue]}`" if j[:queue]
            lines << "- **Perform:** `#{j[:perform_sig]}`" if j[:perform_sig]
            lines << "- **Retries:** #{j[:retry_config].join('; ')}" if j[:retry_config].any?
            lines << "- **Calls:** #{j[:dependencies].join(', ')}" if j[:dependencies].any?

            # Read source for additional detail
            source = j[:file] && safe_read(File.join(root, j[:file]))
            if source
              guards = extract_guard_clauses(source)
              lines << "- **Guards:** #{guards.join('; ')}" if guards.any?

              broadcasts = extract_broadcasts(source)
              lines << "- **Broadcasts:** #{broadcasts.join(', ')}" if broadcasts.any?

              side_effects = extract_side_effects(source)
              lines << "- **Side effects:** #{side_effects.join(', ')}" if side_effects.any?
            end
            lines << ""
          end
          lines << "_Use `job:\"Name\"` to see enqueuers and cross-references._"
        end

        lines
      end

      # Renders the v5.8.0 enriched Action Cable channel detail produced by
      # JobIntrospector#extract_channels (identified_by, streams, periodic, actions).
      # Returns lines, not a Response - caller composes.
      private_class_method def self.format_channels_section(channels)
        lines = [ "# Action Cable Channels (#{channels.size})", "" ]

        channels.each do |c|
          lines << "## `#{c[:name]}`"
          lines << ""
          lines << "- **File:** `#{c[:file]}`" if c[:file]

          if (ids = c[:identified_by]) && ids.any?
            lines << "- **Identified by:** #{ids.map { |i| "`#{i}`" }.join(', ')}"
          end

          if (streams = c[:streams])
            from = Array(streams[:stream_from])
            for_ = Array(streams[:stream_for])
            lines << "- **stream_from:** #{from.map { |s| "`#{s}`" }.join(', ')}" if from.any?
            lines << "- **stream_for:** #{for_.map { |s| "`#{s}`" }.join(', ')}"   if for_.any?
          end

          if (periodic = c[:periodic]) && periodic.any?
            lines << "- **Periodic timers:**"
            periodic.each do |t|
              lines << "  - `#{t[:method]}` every `#{t[:every]}`"
            end
          end

          if (actions = c[:actions]) && actions.any?
            lines << "- **RPC actions:** #{actions.map { |a| "`#{a}`" }.join(', ')}"
          end

          if (sm = c[:stream_methods]) && sm.any?
            lines << "- **Stream methods:** #{sm.map { |m| "`#{m}`" }.join(', ')}"
          end

          lines << ""
        end

        lines
      end

      private_class_method def self.extract_queue(source)
        match = source.match(/queue_as\s+[:'"](\w+)['"]?/)
        match[1] if match
      end

      # Options are read off the call, so `wait:` and `attempts:` come back in
      # one order however they were written, and a `retry_on` in a comment or
      # a string never counts.
      private_class_method def self.extract_retry_config(source)
        ast = Introspectors::SourceIntrospector.walk_source(source, {
          retries: -> { Introspectors::Listeners::GenericMacroListener.new(:retry_on, :discard_on, :sidekiq_options) }
        })

        ast[:retries].filter_map do |hit|
          options = hit[:option_nodes]
          case hit[:macro]
          when :retry_on
            entry = "retry_on #{hit[:values].join(', ')}"
            entry += ", attempts: #{option_source(options[:attempts])}" if options[:attempts]
            entry += ", wait: #{option_source(options[:wait])}" if options[:wait]
            entry
          when :discard_on
            "discard_on #{hit[:values].join(', ')}"
          when :sidekiq_options
            "sidekiq retry: #{option_source(options[:retry])}" if options[:retry]
          end
        end
      end

      private_class_method def self.option_source(node)
        node.slice.gsub(/\s+/, " ")
      end

      private_class_method def self.perform_method(source)
        Introspectors::ActionResolver.methods_in(source).find { |m| m[:name] == "perform" && m[:scope] == :instance }
      end

      private_class_method def self.extract_perform_signature(source)
        perform = perform_method(source)
        Introspectors::ActionResolver.signature(perform) if perform
      end

      # The `return` lines inside perform's own body, first ten.
      private_class_method def self.extract_guard_clauses(source)
        perform = perform_method(source)
        return [] unless perform

        body = source.lines[perform[:location]...(perform[:end_location] - 1)] || []
        body.map(&:strip).select { |line|
          line.match?(/\Areturn\s+(if|unless)\b/) || (line.match?(/\Areturn\b/) && line.length < 120)
        }.first(10)
      end

      private_class_method def self.extract_dependencies(source, own_class_name)
        deps = Set.new

        source.scan(/([A-Z][\w:]+)\.(new|call|perform_later|perform_async|create|find|where|deliver_later|deliver_now)\b/).each do |match|
          cls = match[0]
          next if cls == own_class_name
          next if %w[Rails ActiveRecord ApplicationRecord File Dir ENV String Integer Float Array Hash Set Time Date DateTime URI Regexp].include?(cls)
          deps << "#{cls}.#{match[1]}"
        end

        deps.to_a.sort
      end

      private_class_method def self.extract_broadcasts(source)
        broadcasts = Set.new

        source.scan(/(broadcast_\w+)\s*(?:_to\s+)?/).each do |match|
          broadcasts << match[0]
        end

        source.scan(/Turbo::StreamsChannel\.\w+/).each do |match|
          broadcasts << match
        end

        broadcasts.to_a.sort
      end

      private_class_method def self.extract_side_effects(source)
        effects = Set.new

        effects << "database write" if source.match?(/\.(save[!]?|update[!]?|create[!]?|destroy[!]?|delete)\b/)
        effects << "email delivery" if source.match?(/\.deliver_later|\.deliver_now/)
        effects << "job enqueue" if source.match?(/\.perform_later|\.perform_async/)
        effects << "Turbo broadcast" if source.match?(/broadcast_|Turbo::StreamsChannel/)
        effects << "HTTP request" if source.match?(/Faraday|Net::HTTP|HTTParty|RestClient/)
        effects << "cache write" if source.match?(/Rails\.cache\.write|Rails\.cache\.fetch/)
        effects << "file I/O" if source.match?(/File\.write|File\.open/)
        effects << "logging" if source.match?(/Rails\.logger|logger\./)
        effects << "notification" if source.match?(/ActiveSupport::Notifications\.instrument/)

        effects.to_a.sort
      end

      private_class_method def self.extract_schedule(source, class_name, root)
        # Check for sidekiq-cron in config/sidekiq.yml or config/schedule.yml
        schedule_files = %w[config/sidekiq.yml config/sidekiq_cron.yml config/schedule.yml config/recurring.yml]
        schedule_files.each do |file|
          path = File.join(root, file)
          content = safe_read(path)
          next unless content
          next unless content.include?(class_name)

          # Extract the cron expression near the class name
          content.each_line do |line|
            if line.include?("cron:") && content_near_class?(content, class_name, line)
              cron = line.match(/cron:\s*["']?([^"'\n]+)/)
              return "#{cron[1].strip} (from #{file})" if cron
            end
          end

          return "scheduled (found in #{file})"
        end

        # Check for inline Sidekiq::Cron or recurring
        if source.match?(/sidekiq_options\s+.*cron:|recurring\b/)
          match = source.match(/cron:\s*["']([^"']+)["']/)
          return match[1] if match
        end

        nil
      end

      private_class_method def self.content_near_class?(content, class_name, target_line)
        lines = content.lines
        target_idx = lines.index(target_line)
        return false unless target_idx

        # Check surrounding lines (within 5 lines) for the class name
        start_idx = [ target_idx - 5, 0 ].max
        end_idx = [ target_idx + 5, lines.size - 1 ].min
        lines[start_idx..end_idx].any? { |l| l.include?(class_name) }
      end

      private_class_method def self.find_enqueuers(class_name, real_root)
        enqueuers = Set.new
        search_dirs = %w[app/controllers app/models app/services app/jobs app/workers app/mailers]
                        .flat_map { |d| PathResolver.dirs_for(real_root, d) }

        search_dirs.each do |dir|
          safe_glob(dir, "**/*.rb", real_root).each do |real|
            source = safe_read(real)
            next unless source

            # Look for ClassName.perform_later, ClassName.perform_async, ClassName.set(...).perform_later
            next unless source.match?(/#{Regexp.escape(class_name)}\.(perform_later|perform_async|set\()/)

            relative = real.sub("#{real_root}/", "")
            # Skip the job's own file
            own_snake = class_name.underscore
            next if relative.include?(own_snake)

            enqueuers << relative
          end
        end

        enqueuers.to_a.sort.first(20)
      end
    end
  end
end
