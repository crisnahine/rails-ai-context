# frozen_string_literal: true

module RailsAiContext
  module Tools
    class ReadLogs < BaseTool
      tool_name "rails_read_logs"
      description "Read recent log entries with level filtering and sensitive data redaction. " \
        "Use when: debugging errors, checking recent activity, investigating failed requests. " \
        "Key params: lines (default 50), level (ERROR/WARN/INFO/DEBUG/FATAL/all), file, search. " \
        "Search matches the redacted line, so a filtered value cannot be searched for."

      input_schema(
        properties: {
          lines: {
            type: "integer",
            description: "Number of lines to tail from the log file. With `search`, the number of matching lines to show, " \
              "searched for in the last 4 MB of the file. Default: 50, max: 500."
          },
          level: {
            type: "string",
            enum: %w[DEBUG INFO WARN ERROR FATAL all],
            description: "Minimum log level filter. 'all' shows everything (default). 'ERROR' shows ERROR+FATAL only."
          },
          file: {
            type: "string",
            description: "Log file name (e.g. 'production', 'sidekiq', or a rotated 'development.log.0'). Defaults to current Rails.env log. '.log' suffix optional."
          },
          search: {
            type: "string",
            description: "Case-insensitive text filter. Only lines containing this string are returned, " \
              "searched for in the last 4 MB of the file."
          }
        }
      )

      guide_row(
        order: 33,
        mcp: "rails_read_logs(level:\"X\")",
        cli_args: "level=X",
        summary: "Reverse file tail with level filtering and sensitive data redaction"
      )

      annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: false, open_world_hint: false)

      MAX_READ_BYTES = 1_048_576  # 1MB
      MAX_LINES = 500

      # How far back a search reaches. Searching only the lines a plain tail
      # shows answered "No entries matching" for an error a few thousand
      # lines up. Every line in the window is redacted before it is matched,
      # about half a second per megabyte, so the window is bounded, and the
      # answer says how much of the file it covered.
      SEARCH_READ_BYTES = 4 * 1_048_576

      LEVEL_HIERARCHY = { "DEBUG" => 0, "INFO" => 1, "WARN" => 2, "ERROR" => 3, "FATAL" => 4 }.freeze

      def self.call(lines: nil, level: "all", file: nil, search: nil, server_context: nil, **_extra)
        warnings = []

        # A log is named, not located: the name is reduced to its basename, so
        # a path would otherwise come back as the log of that basename not
        # being there rather than as the refusal it is.
        if file.to_s.match?(%r{[/\\]|\.\.})
          return error_response("Path not allowed: #{file}. Name a log file in log/, without a path (e.g. 'production').")
        end

        requested = lines&.to_i
        lines = requested ? requested.clamp(1, MAX_LINES) : config.log_lines.to_i
        if requested && requested != lines
          warnings << (requested < 1 ? "lines must be >= 1, using 1" : "lines clamped to #{MAX_LINES} (was #{requested})")
        end

        # Validate level
        level = level.to_s.strip.upcase
        level = "all" if level.empty?
        valid_levels = LEVEL_HIERARCHY.keys + [ "ALL" ]
        unless valid_levels.include?(level.upcase)
          return text_response("Unknown level: '#{level}'. Valid values: #{valid_levels.join(', ')}")
        end
        level = level == "ALL" ? "all" : level

        # Resolve log file
        path = resolve_log_file(file)
        available = available_log_files
        unless path
          msg = if available.any?
            "Log file '#{file || "#{rails_env_name}.log"}' not found.\nAvailable log files: #{available.join(', ')}"
          else
            "No log files found in log/. Your app may log to stdout (common in Docker/container environments)."
          end
          return empty_response(msg)
        end

        # Tail the file; a search reads back further and keeps its last matches.
        searching = !search.to_s.strip.empty?
        raw_lines, whole_file = searching ? read_window(path, SEARCH_READ_BYTES) : [ tail_file(path, lines), nil ]
        if raw_lines.empty?
          return empty_response("# Log: #{File.basename(path)}\nLog file is empty.\n\n---\nAvailable log files: #{available.join(', ')}")
        end

        # Detect format and filter by level
        format = detect_format(raw_lines)
        if level != "all" && !severity_format?(raw_lines, format)
          warnings << "most of these lines have no severity field, so they cannot be filtered by level; showing every line"
          level = "all"
        end
        filtered = filter_by_level(raw_lines, level, format)

        redacted = RailsAiContext::Redaction.redact_log_lines(filtered, search: search)
        window = searching ? search_window(raw_lines.size, whole_file) : nil

        if redacted.empty?
          return empty_response("# Log: #{File.basename(path)}\nNo entries matching level:#{level}#{" search:\"#{search}\"" if search}#{" #{window}" if window}.\n\n---\nAvailable log files: #{available.join(', ')}")
        end

        # Format output
        size_label = human_size(File.size(path))

        level_label = level == "all" ? "all levels" : "#{level}+"

        output = [ "# Log: #{File.basename(path)}" ]
        if searching
          matched = redacted.size
          redacted = redacted.last(lines)
          shown = redacted.size < matched ? "; showing the last #{redacted.size}" : ""
          output << "Size: #{size_label} | #{count_phrase(matched, "line")} matching \"#{search}\" #{window}#{shown} | Level: #{level_label}"
        else
          output << "Size: #{size_label} | Showing last #{count_phrase(redacted.size, "line")} | Level: #{level_label}"
        end
        warnings.each { |w| output << "**Warning:** #{w}" } if warnings.any?
        output << ""
        output << "```"
        output.concat(redacted)
        output << "```"
        output << ""
        output << "---"
        output << "Available log files: #{available.join(', ')}"

        text_response(output.join("\n"))
      end

      # ── Log file resolution ─────────────────────────────────────────

      ROTATED_LOG = /\.log\.\d+\z/

      private_class_method def self.resolve_log_file(file_name)
        base = file_name ? File.basename(file_name.to_s.strip.delete("\0")) : rails_env_name.to_s
        # Logger rotates by size to development.log.0, .1 and so on.
        base = "#{base.delete_suffix(".log")}.log" unless base.match?(ROTATED_LOG)

        # A log is tailed, never read whole, so the per-file cap does not apply.
        located = RailsAiContext::SafePath.locate(File.join("log", base), under: rails_app.root.to_s, max_size: Float::INFINITY)
        located.ok? ? located.realpath : nil
      end

      # ── Reverse tail ────────────────────────────────────────────────

      private_class_method def self.tail_file(path, num_lines)
        size = File.size(path)
        return [] if size == 0

        read_bytes = [ size, MAX_READ_BYTES ].min

        File.open(path, "rb") do |f|
          f.seek(-read_bytes, IO::SEEK_END) if size > read_bytes
          content = f.read
          content.force_encoding("UTF-8")
          content.encode!("UTF-8", invalid: :replace, undef: :replace)
          lines = content.split("\n")
          lines.last(num_lines)
        end
      end

      # Every whole line in the last `bytes` of the file, and whether that is
      # the whole file. A window that starts mid-file drops its first line,
      # which it holds only the end of.
      private_class_method def self.read_window(path, bytes)
        size = File.size(path)
        return [ [], true ] if size == 0

        whole = size <= bytes
        File.open(path, "rb") do |f|
          f.seek(-bytes, IO::SEEK_END) unless whole
          content = f.read
          content.force_encoding("UTF-8")
          content.encode!("UTF-8", invalid: :replace, undef: :replace)
          lines = content.split("\n")
          lines.shift unless whole
          [ lines, whole ]
        end
      end

      private_class_method def self.search_window(line_count, whole_file)
        scope = whole_file ? "the whole file" : "the last #{human_size(SEARCH_READ_BYTES)}; older lines were not searched"
        "in the last #{count_phrase(line_count, "line")} (#{scope})"
      end

      # ── Log format detection + level filtering ─────────────────────

      private_class_method def self.detect_format(lines)
        return :json if lines.first&.strip&.start_with?("{")
        :standard
      end

      SEVERITY = "DEBUG|INFO|WARN(?:ING)?|ERROR|FATAL|UNKNOWN|ANY"
      # Only where a formatter writes a severity: Logger::Formatter's "I, [ts]  INFO --",
      # a leading "INFO"/"[INFO]", "[ts] INFO", "<timestamp> INFO", Sidekiq 6/7's
      # "pid=.. tid=.. INFO: ", logfmt level=, or semantic_logger's "<timestamp> E [pid:thread]".
      SEVERITY_FIELD = Regexp.union(
        /\A\d{4}-\d\d-\d\d[T ][\d:.]+ ([TDIWEF]) \[/,
        /\A[DIWEFA], \[[^\]]*\]\s+(#{SEVERITY}) -- /o,
        /\A\[?(#{SEVERITY})\]?(?=[\s:]|\z)/o,
        /\A\[[^\]]*\]\s+\[?(#{SEVERITY})\]?\s/o,
        /\A\d{4}-\d\d-\d\d[T ][\d:.,]+(?:Z|[+-]\d\d:?\d\d)?\s+\[?(#{SEVERITY})\]?\s/o,
        /\A(?:\S+ )?pid=\d+ tid=\S+(?: [\w.]+=\S*)* (#{SEVERITY}): /o,
        /\b(?:level|severity)=(#{SEVERITY})\b/io
      )

      # semantic_logger writes the first letter of its level; trace sits below debug.
      LEVEL_ALIASES = { "WARNING" => "WARN", "T" => "DEBUG", "D" => "DEBUG", "I" => "INFO", "W" => "WARN", "E" => "ERROR", "F" => "FATAL" }.freeze
      ANSI_COLOR = /\e\[[\d;]*m/
      BACKTRACE_FRAME = /\S:\d+:in /

      # Filtering by level needs a severity on most lines: one message that
      # happens to start with "WARN:" in a log that writes no severity must
      # not turn every other line into its continuation.
      private_class_method def self.severity_format?(lines, format)
        heads = lines.reject { |l| l.strip.empty? || l.match?(/\A\s/) || l.match?(BACKTRACE_FRAME) }
        heads.count { |l| extract_level(l, format) } * 2 > heads.size
      end

      private_class_method def self.extract_level(line, format)
        case format
        when :json
          match = line.match(/"(?:level|severity|lvl)"\s*:\s*"(\w+)"/i)
          match[1].upcase if match
        when :standard
          match = line.gsub(ANSI_COLOR, "").match(SEVERITY_FIELD)
          level = match&.captures&.compact&.first&.upcase
          LEVEL_ALIASES.fetch(level, level)
        end
      end

      private_class_method def self.filter_by_level(lines, min_level, format)
        return lines if min_level == "all"

        min_rank = LEVEL_HIERARCHY[min_level.upcase] || 0

        result = []
        include_continuation = false

        lines.each do |line|
          level = extract_level(line, format)
          if level
            rank = LEVEL_HIERARCHY.fetch(level, LEVEL_HIERARCHY["FATAL"])
            include_continuation = rank >= min_rank
          end
          # Lines without a level are continuations (stack traces)
          result << line if include_continuation
        end

        result
      end

      # ── Available log files ─────────────────────────────────────────

      private_class_method def self.available_log_files
        log_dir = File.join(rails_app.root.to_s, "log")
        return [] unless Dir.exist?(log_dir)
        Dir.glob(File.join(log_dir, "*.log{,.*}"))
          .map { |f| File.basename(f) }
          .select { |f| f.match?(/\A[\w.\-]+\.log(?:\.\d+)?\z/) } # Only clean filenames (alphanumeric, dots, hyphens, underscores)
          .sort
      end
    end
  end
end
