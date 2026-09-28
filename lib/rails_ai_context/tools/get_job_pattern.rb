# frozen_string_literal: true

module RailsAiContext
  module Tools
    class GetJobPattern < BaseTool
      tool_name "rails_get_job_pattern"
      description "Analyze background jobs in app/jobs/, app/workers/ and app/sidekiq/: queues, retries, perform signatures, guards, and what they call. " \
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

      # Built from the introspector's own directory list, so it names only what the scan read.
      NOT_COVERED = "Jobs and workers are read from " \
        "#{Introspectors::JobIntrospector::JOB_DIRS.map { |dir| "#{dir}/" }.join(", ")} " \
        "(packs and in-repo engines included); a job class anywhere else is not covered by this tool."

      def self.call(job: nil, detail: "standard", server_context: nil)
        blank = blank_name_response("job", job)
        return blank if blank

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

        if job
          return format_single_job(job, jobs, real_root, sidekiq_line, workers, job_bases(jobs_data), enqueue_helpers)
        end

        # No jobs and no channels - bail out. Channel absence is only a real
        # negative when the :jobs section actually ran - if it's unavailable
        # (static tier), say so instead of claiming "no channels detected".
        if jobs.empty? && channels.empty? && workers.empty?
          return text_response(with_bases_note(no_jobs_or_channels_message(channels_note, sidekiq_line), jobs_data))
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
        bases = bases_note("jobs", job_bases(jobs_data).map { |base| base[:name] })
        if bases
          lines << "" if lines.any?
          lines << bases
        end
        # Counts are bounded by the directories scanned, so the caveat goes under any listing.
        lines << "" if lines.any?
        lines << "_#{[ sidekiq_line, NOT_COVERED ].compact.join(" ")}_"

        text_response(lines.join("\n"))
      end

      # A Sidekiq worker is not an ActiveJob job, and on an app that runs its
      # background work this way it is the only async code there is. Size,
      # retries and calls ride the record, so the listing opens no file.
      private_class_method def self.format_workers_section(workers, detail)
        detailed = RailsAiContext::DetailLevel.full?(detail) || detail == "standard"
        lines = [ "## Sidekiq Workers (#{workers.size})", "" ]
        workers.each do |worker|
          label = options_label(worker[:options] || {}, worker[:inherited_from] || {})
          size = detailed && worker[:line_count] ? " (#{count_phrase(worker[:line_count], "line")})" : ""
          retries = detailed ? own_retries(worker) : []
          calls = detailed ? Array(worker[:calls]) : []
          retry_label = retries.any? ? " - #{retries.first}" : ""
          calls_label = calls.any? ? " → #{calls.join(', ')}" : ""
          lines << "- **#{worker[:name]}**#{label}#{size}#{retry_label}#{calls_label}"
          next unless detailed

          lines << "  - throttle: #{worker[:throttle]}" if worker[:throttle]
          lines << "  - `#{worker[:entry_point] || "perform"}(#{worker[:perform_signature]})`" if worker[:perform_signature]
          lines << "  - `#{worker[:file]}`" if worker[:file]
        end
        lines
      end

      # The record the listing renders, as its own page: everything the
      # introspector holds about a worker whose file it cannot re-read.
      private_class_method def self.worker_summary(worker)
        lines = [ "# #{worker[:name]}", "" ]
        options = worker[:options] || {}
        lines << "**Options:** #{options.map { |key, value| "#{key}: #{value}" }.join(', ')}" if options.any?
        lines << "**Throttle:** #{worker[:throttle]}" if worker[:throttle]
        lines << "**Perform:** `#{worker[:entry_point] || "perform"}(#{worker[:perform_signature]})`" if worker[:perform_signature]
        lines << "" << "_No file was recorded for this worker, so only what the listing holds is shown._"
        lines.join("\n")
      end

      # Longer base option values are left to the base's own page, not repeated on every worker.
      SHORT_OPTION = 24

      private_class_method def self.options_label(options, inherited_from)
        own = options.reject { |key, _| inherited_from.key?(key) }.map { |key, value| "#{key}: #{value}" }
        # Options merge from the root down, so the nearest base comes last.
        groups = options.select { |key, _| inherited_from.key?(key) }.group_by { |key, _| inherited_from[key] }
        inherited = groups.to_a.reverse.map do |source, pairs|
          keys = pairs.map { |key, value| (text = value.to_s).length <= SHORT_OPTION && !text.include?("\n") ? "#{key}: #{text}" : key.to_s }
          "#{keys.join(', ')} (from #{source})"
        end
        parts = [ own.join(", ").presence, *inherited ].compact
        parts.any? ? " [#{parts.join('; ')}]" : ""
      end

      # `retry:` shows in the worker's bracket, so this line carries only its own retry_on.
      private_class_method def self.own_retries(worker)
        Array(worker[:retries]).reject { |entry| entry.start_with?("sidekiq retry:") }
      end

      # An empty answer still names the bases it left out, as every listing
      # does, so the name it offers can be asked for.
      private_class_method def self.with_bases_note(message, jobs_data)
        [ message, bases_note("jobs", job_bases(jobs_data).map { |base| base[:name] }) ].compact.join("\n\n")
      end

      HEIRS_SHOWN = 12
      ENQUEUERS_SHOWN = 20

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
      private_class_method def self.job_bases(jobs_data)
        (jobs_data.is_a?(Hash) ? jobs_data[:job_bases] : nil).then { |list| Array(list).select { |b| b.is_a?(Hash) } }
      end

      private_class_method def self.format_single_job(job, jobs, root, sidekiq_line, workers, bases = [], helpers = [])
        names = jobs.map { |j| j[:name] }
        worker_names = workers.map { |w| w[:name] }.compact
        # A base answers by name because every listing, the empty one too,
        # offers it; any other name on an app with no jobs gets that answer.
        base_names = bases.filter_map { |b| b[:name] }
        # "SendWelcomeEmailJob", "send_welcome_email_job" and "send_welcome_email" all name one job.
        query = job.to_s.delete_suffix(".rb")
        if names.empty? && worker_names.empty? && !fuzzy_find_key(base_names, query)
          return text_response(no_job_files_message(sidekiq_line))
        end
        class_name = fuzzy_find_key(names, query) ||
                     fuzzy_find_key(names, "#{query.underscore.delete_suffix("_job")}_job")
        relative = class_name && RailsAiContext::Payload.job_file(cached_context, class_name)
        worker = nil
        unless relative
          # A Sidekiq worker is not in the ActiveJob list, and the listing
          # above it prints both, so the name a reader copied is in either.
          worker_name = fuzzy_find_key(worker_names, query)
          worker = worker_name && workers.find { |w| w[:name] == worker_name }
          base_name = worker ? nil : fuzzy_find_key(base_names, query)
          if worker
            class_name = worker_name
            relative = worker[:file]
            # A worker the walk recorded without a file has no source to read,
            # and joining nil onto the root raises. What the listing holds is
            # still an answer.
            return text_response(worker_summary(worker)) if relative.nil?
          elsif base_name
            class_name = base_name
            relative = bases.find { |b| b[:name] == base_name }[:file]
            return text_response("# #{class_name}\n\n_A base class: other jobs inherit from it, " \
                                 "and no file was recorded for it._") if relative.nil?
          else
            return not_found_response("Job", job, (names + worker_names + base_names).sort,
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
        if jobs.any? { |j| j[:name] == class_name && j[:unknown_base] }
          lines << "**Base:** no ActiveJob or Sidekiq ancestry found; listed for its `perform`"
        end
        base = bases.find { |b| b[:name] == class_name }
        record = worker || jobs.find { |j| j[:name] == class_name } || base
        if base
          lines << "**Base class:** not counted as a job of its own; other jobs inherit from it."
          options = base[:options] || {}
          lines << "**Options:** #{options.map { |key, value| "#{key}: #{value}" }.join(', ')}" if options.any?
          if (heirs = Array(base[:inherited_by])).any?
            shown = heirs.first(HEIRS_SHOWN).join(", ")
            shown += ", ...#{heirs.size - HEIRS_SHOWN} more" if heirs.size > HEIRS_SHOWN
            lines << "**Inherited by (#{heirs.size}):** #{shown}"
          end
        end

        # A worker or base declares its queue in `sidekiq_options`, which the introspector read.
        queue = extract_queue(source) || (record && (record[:queue] || (record[:options] || {})["queue"]))
        lines << "**Queue:** `#{queue}`" if queue
        lines << "**Throttle:** #{worker[:throttle]}" if worker && worker[:throttle]
        if base && (declares = Array(base[:declares])).any?
          lines << "" << "## Declares (every job below inherits these)"
          declares.each { |line| lines << "- `#{line}`" }
        end

        retry_config = Array(record && record[:retries])
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
        dependencies = Introspectors::SourceCalls.calls(source, own: class_name)
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
        # The section always prints: missing, it would read as "nothing enqueues it".
        known = (names + worker_names + base_names).uniq
        enqueuers = find_enqueuers(class_name, root, relative, helpers, known)
        lines << "" << "## Enqueued By"
        if enqueuers.any?
          enqueuers.first(ENQUEUERS_SHOWN).each { |e| lines << "- `#{e}`" }
          lines << "_...and #{enqueuers.size - ENQUEUERS_SHOWN} more._" if enqueuers.size > ENQUEUERS_SHOWN
        else
          lines << "_No enqueue calls found in #{ENQUEUER_SCOPE}._"
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
            # No ActiveJob or Sidekiq ancestry found, and the bracket says so.
            unknown_base: job[:unknown_base],
            retry_config: Array(job[:retries]),
            perform_sig: source ? extract_perform_signature(source) : job[:perform_signature],
            dependencies: source ? Introspectors::SourceCalls.calls(source, own: class_name) : []
          }
        end

        total = job_data.size
        lines = [ "# Background Jobs (#{total})", "" ]

        # Queue summary
        # An unresolved base has no queue the scan can claim, so it is counted apart.
        queues = job_data.map { |j| j[:queue] || (j[:unknown_base] ? "unknown" : "default") }
                         .tally.sort_by { |_, c| -c }
        if queues.any?
          queue_str = queues.map { |q, c| "#{q}(#{c})" }.join(", ")
          lines << "**Queues:** #{queue_str}"
          lines << ""
        end

        case detail
        when "summary"
          job_data.each do |j|
            lines << "- #{j[:class_name]}#{queue_label(j)}"
          end
          lines << "" << "_Use `job:\"Name\"` for full detail, or `detail:\"standard\"` for retries and dependencies._"

        when "standard"
          job_data.each do |j|
            retry_label = j[:retry_config].any? ? " - #{j[:retry_config].first}" : ""
            deps_label = j[:dependencies].any? ? " → #{j[:dependencies].join(', ')}" : ""
            size_label = j[:line_count] ? " (#{count_phrase(j[:line_count], "line")})" : ""
            lines << "- **#{j[:class_name]}**#{queue_label(j)}#{size_label}#{retry_label}#{deps_label}"
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

      private_class_method def self.queue_label(job)
        return " [#{job[:queue]}]" if job[:queue]

        job[:unknown_base] ? " [unknown base]" : ""
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

      private_class_method def self.perform_method(source)
        Introspectors::ActionResolver.entry_point(Introspectors::ActionResolver.methods_in(source))
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
        effects << "job enqueue" if Introspectors::SourceCalls.enqueue_calls(source, enqueue_helpers).any?
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

      # Read off call nodes, so a call inside a comment does not count. The app's own enqueue
      # helper (`Jobs.enqueue(:process_post)`) counts, and a bare constant resolves as Ruby would.
      private_class_method def self.enqueues?(source, class_name, helpers, known)
        names = Introspectors::SourceCalls::ENQUEUE_CALLS + %w[perform_all_later new] + helpers.map { |helper| helper[:method].to_s }
        calls = Introspectors::SourceIntrospector.walk_source(source, {
          calls: -> { Introspectors::Listeners::MethodCallListener.new(names: names) }
        })[:calls]
        return false if calls.empty?

        nesting = module_nesting(source)
        resolve = ->(call, written) { resolve_constant(written.to_s, nesting.call(call[:line]), known) }
        all_later = calls.any? { |call| call[:name] == "perform_all_later" }

        calls.any? do |call|
          case call[:name]
          when *Introspectors::SourceCalls::ENQUEUE_CALLS then resolve.call(call, call[:receiver]) == class_name
          when "new" then all_later && resolve.call(call, call[:receiver]) == class_name
          else helper_names_job?(call, class_name, helpers, resolve)
          end
        end
      end

      private_class_method def self.helper_names_job?(call, class_name, helpers, resolve)
        helper = helpers.find { |h| h[:owner] == call[:receiver].to_s.delete_prefix("::") && h[:method] == call[:name] }
        named = helper && Array(call[:arguments])[helper[:job_arg]]
        return false if named.nil?

        # A class passed as itself, or a name the helper camelizes into its own
        # namespace: "chat/notify" is Jobs::Chat::Notify.
        as_class = named.is_a?(String) && named.match?(/\A(?:::)?[A-Z]/)
        resolved = as_class ? resolve.call(call, named) : "#{helper[:owner]}::#{named.to_s.camelize}"
        resolved.casecmp?(class_name)
      end

      # Module.nesting at a line, innermost first: every class and module
      # whose body holds it, a method body and a class-body block
      # (`after_commit { SyncJob.perform_later }`) alike. Each is named the
      # way Ruby nests it, so `class Admin::Exports` puts Admin::Exports on the
      # list and not Admin, where `module Admin; class Exports` puts both.
      private_class_method def self.module_nesting(source)
        spans = nil
        lambda do |line|
          spans ||= begin
            root = RailsAiContext::AstCache.parse_string(source)&.value
            root ? Introspectors::DeclaredConstant.constants(root).to_a : []
          end
          inner = spans.select { |_, node, _| node.location.start_line <= line.to_i && line.to_i <= node.location.end_line }
                       .max_by { |_, node, _| node.location.start_offset }
          inner ? inner[2] : []
        end
      end

      # A constant as Ruby resolves it lexically: each namespace on the
      # nesting that holds a job of that name, innermost first, else the name
      # as written (the top level).
      private_class_method def self.resolve_constant(written, nesting, known)
        return written.delete_prefix("::") if written.start_with?("::")

        nesting.each do |namespace|
          candidate = "#{namespace}::#{written}"
          return candidate if known.include?(candidate)
        end
        written
      end

      private_class_method def self.find_enqueuers(class_name, real_root, own_file = nil, helpers = [], known = [])
        enqueuers = Set.new
        helpers = helpers.select { |helper| class_name.start_with?("#{helper[:owner]}::") }
        # Only a file containing one of these spellings is parsed.
        spellings = [ class_name, class_name.split("::").last ] +
                    helpers.map { |helper| class_name.delete_prefix("#{helper[:owner]}::").underscore }
        ruby_files(real_root).each do |real|
            source = safe_read(real)
            next unless source && spellings.any? { |spelling| source.include?(spelling) }
            next unless enqueues?(source, class_name, helpers, known)

            relative = real.sub("#{real_root}/", "")
            # Skip the job's own file, matched by constant too: a path spelled through an acronym
            # holds no substring of the underscored name.
            next if relative == own_file || Introspectors::DeclaredConstant.declared_names(source).include?(class_name)

            enqueuers << relative
        end

        enqueuers.to_a.sort
      end

      # Every place the app runs Ruby from, and how the empty answer names it:
      # one list, so the files read and the scope the answer states cannot
      # drift. Rake tasks and migrations enqueue backfills as often as app
      # code does. `program` files are Ruby by extension or shebang.
      ENQUEUER_PLACES = [
        [ "app/", ->(root) { PathResolver.dirs_for(root, "app") }, "**/*.{rb,rake}", false ],
        [ "lib/ (rake tasks included)", ->(root) { PathResolver.dirs_for(root, "lib") }, "**/*.{rb,rake}", false ],
        [ "bin/", ->(root) { [ File.join(root, "bin") ] }, "**/*", true ],
        [ "script/", ->(root) { [ File.join(root, "script") ] }, "**/*", true ],
        [ "db/ (migrations and seeds)", ->(root) { [ File.join(root, "db") ] }, "**/*.rb", false ]
      ].freeze

      ENQUEUER_SCOPE = "#{ENQUEUER_PLACES[0..-2].map(&:first).join(', ')} or #{ENQUEUER_PLACES.last.first}"

      private_class_method def self.ruby_files(real_root)
        ENQUEUER_PLACES.flat_map { |_label, dirs, pattern, program|
          files = dirs.call(real_root).flat_map { |dir| safe_glob(dir, pattern, real_root) }
          program ? files.select { |path| File.file?(path) && ruby_program?(path) } : files
        }.uniq
      end

      # A bin/ or script/ file is Ruby by its extension or its shebang.
      private_class_method def self.ruby_program?(path)
        return true if path.end_with?(".rb", ".rake")

        first = File.open(path, &:gets).to_s
        first.start_with?("#!") && first.include?("ruby")
      rescue StandardError
        false
      end
    end
  end
end
