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
          detail: {
            type: "string",
            enum: %w[summary standard full],
            description: "Detail level. summary: names + queues. standard: names + queues + retries + what they call (default). full: everything including guards, broadcasts, schedules, and enqueuers."
          }
        }
      )

      annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true, open_world_hint: false)

      def self.call(job: nil, detail: "standard", server_context: nil)
        root = Rails.root.to_s
        jobs_dir = File.join(root, "app", "jobs")

        unless Dir.exist?(jobs_dir)
          return text_response("No app/jobs/ directory found. This app may not use background jobs.")
        end

        job_files = Dir.glob(File.join(jobs_dir, "**", "*.rb")).sort
        # Filter out application_job.rb base class
        job_files.reject! { |f| File.basename(f) == "application_job.rb" }

        if job_files.empty?
          return text_response("app/jobs/ directory exists but contains no job files (besides ApplicationJob).")
        end

        if job
          return format_single_job(job, job_files, jobs_dir, root)
        end

        format_job_listing(job_files, jobs_dir, root, detail)
      end

      private_class_method def self.format_single_job(job, job_files, jobs_dir, root)
        # Match by class name or filename: "SendWelcomeEmailJob", "send_welcome_email_job", "send_welcome_email"
        snake = job.underscore.delete_suffix(".rb")
        snake_with_job = snake.end_with?("_job") ? snake : "#{snake}_job"
        snake_without_job = snake.delete_suffix("_job")

        file = job_files.find do |f|
          relative = f.sub("#{jobs_dir}/", "").delete_suffix(".rb")
          basename = relative.split("/").last
          basename == snake_with_job || basename == snake_without_job || relative == snake
        end

        unless file
          available = job_files.map { |f| File.basename(f, ".rb").camelize }
          return not_found_response("Job", job, available.sort,
            recovery_tool: "Call rails_get_job_pattern(detail:\"summary\") to see all jobs")
        end

        return text_response("Job file too large to analyze.") if File.size(file) > max_file_size

        source = safe_read(file)
        return text_response("Could not read job file.") unless source

        relative = file.sub("#{root}/", "")
        line_count = source.lines.size
        class_name = extract_class_name(source) || File.basename(file, ".rb").camelize

        lines = [ "# #{class_name}", "" ]
        lines << "**File:** `#{relative}` (#{line_count} lines)"

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

      private_class_method def self.format_job_listing(job_files, jobs_dir, root, detail)
        job_data = []

        job_files.each do |file|
          next if File.size(file) > max_file_size
          source = safe_read(file)
          next unless source

          relative = file.sub("#{root}/", "")
          class_name = extract_class_name(source) || File.basename(file, ".rb").camelize
          line_count = source.lines.size
          queue = extract_queue(source)
          retry_config = extract_retry_config(source)
          perform_sig = extract_perform_signature(source)
          dependencies = extract_dependencies(source, class_name)

          job_data << {
            file: relative,
            class_name: class_name,
            line_count: line_count,
            queue: queue,
            retry_config: retry_config,
            perform_sig: perform_sig,
            dependencies: dependencies
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
            retry_label = j[:retry_config].any? ? " — #{j[:retry_config].first}" : ""
            deps_label = j[:dependencies].any? ? " → #{j[:dependencies].join(', ')}" : ""
            lines << "- **#{j[:class_name]}**#{queue_label} (#{j[:line_count]} lines)#{retry_label}#{deps_label}"
          end
          lines << "" << "_Use `job:\"Name\"` for guards, broadcasts, schedules, and enqueuers._"

        when "full"
          job_data.each do |j|
            lines << "## #{j[:class_name]}"
            lines << "- **File:** `#{j[:file]}` (#{j[:line_count]} lines)"
            lines << "- **Queue:** `#{j[:queue]}`" if j[:queue]
            lines << "- **Perform:** `#{j[:perform_sig]}`" if j[:perform_sig]
            lines << "- **Retries:** #{j[:retry_config].join('; ')}" if j[:retry_config].any?
            lines << "- **Calls:** #{j[:dependencies].join(', ')}" if j[:dependencies].any?

            # Read source for additional detail
            full_path = File.join(root, j[:file])
            source = safe_read(full_path)
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

        text_response(lines.join("\n"))
      end

      private_class_method def self.extract_class_name(source)
        match = source.match(/class\s+([\w:]+)/)
        match[1] if match
      end

      private_class_method def self.extract_queue(source)
        match = source.match(/queue_as\s+[:'"](\w+)['"]?/)
        match[1] if match
      end

      private_class_method def self.extract_retry_config(source)
        config = []

        source.scan(/retry_on\s+([\w:]+)(?:.*?attempts:\s*(\d+))?(?:.*?wait:\s*([^,\n]+))?/m).each do |match|
          entry = "retry_on #{match[0]}"
          entry += ", attempts: #{match[1]}" if match[1]
          entry += ", wait: #{match[2].strip}" if match[2]
          config << entry
        end

        source.scan(/discard_on\s+([\w:]+(?:\s*,\s*[\w:]+)*)/).each do |match|
          config << "discard_on #{match[0].strip}"
        end

        # Sidekiq retry count
        if (match = source.match(/sidekiq_options\s+.*retry:\s*(\w+)/))
          config << "sidekiq retry: #{match[1]}"
        end

        config
      end

      private_class_method def self.extract_perform_signature(source)
        match = source.match(/def perform\(([^)]*)\)/m)
        return "perform(#{match[1].strip})" if match

        # No-arg perform
        return "perform" if source.match?(/def perform\s*$/)

        nil
      end

      private_class_method def self.extract_guard_clauses(source)
        guards = []
        in_perform = false
        perform_indent = nil

        source.each_line do |line|
          if line.match?(/\A\s*def perform/)
            in_perform = true
            perform_indent = line[/\A\s*/].length
            next
          end

          if in_perform
            # Stop at next method or end of perform
            break if line.match?(/\A\s{#{perform_indent}}end\b/) && perform_indent
            break if line.match?(/\A\s{0,#{perform_indent.to_i}}def\s/) && !line.match?(/\A\s*def perform/)

            stripped = line.strip
            if stripped.match?(/\Areturn\s+(if|unless)\b/)
              guards << stripped
            elsif stripped.match?(/\Areturn\b/) && stripped.length < 120
              guards << stripped
            end
          end
        end

        guards.first(10)
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
          next unless File.exist?(path)
          next if File.size(path) > max_file_size

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

      private_class_method def self.find_enqueuers(class_name, root)
        enqueuers = Set.new
        search_dirs = %w[app/controllers app/models app/services app/jobs app/workers app/mailers].map { |d| File.join(root, d) }

        search_dirs.each do |dir|
          next unless Dir.exist?(dir)
          Dir.glob(File.join(dir, "**", "*.rb")).each do |file|
            next if File.size(file) > max_file_size
            source = safe_read(file)
            next unless source

            # Look for ClassName.perform_later, ClassName.perform_async, ClassName.set(...).perform_later
            next unless source.match?(/#{Regexp.escape(class_name)}\.(perform_later|perform_async|set\()/)

            relative = file.sub("#{root}/", "")
            # Skip the job's own file
            own_snake = class_name.underscore
            next if relative.include?(own_snake)

            enqueuers << relative
          end
        end

        enqueuers.to_a.sort.first(20)
      end

      private_class_method def self.safe_read(path)
        File.read(path, encoding: "UTF-8", invalid: :replace, undef: :replace)
      rescue
        nil
      end

      private_class_method def self.max_file_size
        RailsAiContext.configuration.max_file_size
      end
    end
  end
end
