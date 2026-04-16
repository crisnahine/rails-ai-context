# frozen_string_literal: true

module RailsAiContext
  module Tools
    class ReadLogs < BaseTool
      tool_name "rails_read_logs"
      description "Read recent log entries with level filtering and sensitive data redaction. " \
        "Use when: debugging errors, checking recent activity, investigating failed requests. " \
        "Key params: lines (default 50), level (ERROR/WARN/INFO/DEBUG/FATAL/all), file, search."

      input_schema(
        properties: {
          lines: {
            type: "integer",
            description: "Number of lines to tail from the log file. Default: 50, max: 500."
          },
          level: {
            type: "string",
            enum: %w[DEBUG INFO WARN ERROR FATAL all],
            description: "Minimum log level filter. 'all' shows everything (default). 'ERROR' shows ERROR+FATAL only."
          },
          file: {
            type: "string",
            description: "Log file name (e.g. 'production', 'sidekiq'). Defaults to current Rails.env log. '.log' suffix optional."
          },
          search: {
            type: "string",
            description: "Case-insensitive text filter. Only lines containing this string are returned."
          }
        }
      )

      annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: false, open_world_hint: false)

      MAX_READ_BYTES = 1_048_576  # 1MB
      MAX_LINES = 500

      LEVEL_HIERARCHY = { "DEBUG" => 0, "INFO" => 1, "WARN" => 2, "ERROR" => 3, "FATAL" => 4 }.freeze

      ANSI_ESCAPE = /\e\[[0-9;]*[mGKHF]/

      REDACT_PATTERNS = [
        /(?<=password=)\S+/i,
        /(?<=password:\s)\S+/i,
        /("password":\s*")[^"]+(")/i,
        /("password"=>")[^"]+(")/i,
        /(?<=token=)\S+/i,
        /(?<=token:\s)\S+/i,
        /(?<=secret=)\S+/i,
        /(?<=secret:\s)\S+/i,
        /(?<=api_key=)\S+/i,
        /(?<=api_key:\s)\S+/i,
        /(?<=authorization:\s)(Bearer\s)?\S+/i,
        /(SECRET|PRIVATE|SIGNING|ENCRYPTION)[_A-Z]*=\S+/i,
        /(?<=cookie:\s)\S+/i,
        /(?<=session_id=)\S+/i,
        /(?<=_session=)\S+/i,
        /\bAKIA[0-9A-Z]{16}\b/,                          # AWS access key IDs
        /\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+/,  # JWT tokens
        /-----BEGIN\s+(RSA|DSA|EC|OPENSSH)?\s*PRIVATE KEY-----/,       # SSH/TLS private keys
        /\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Z]{2,}\b/i,
        /\bsk_(?:live|test)_[A-Za-z0-9]{10,}\b/,             # Stripe secret keys
        /\brk_(?:live|test)_[A-Za-z0-9]{10,}\b/,             # Stripe restricted keys
        /\bSG\.[A-Za-z0-9_-]{22,}\.[A-Za-z0-9_-]{10,}\b/,   # SendGrid API keys
        /\bxox[bpras]-[A-Za-z0-9-]{10,}\b/,                  # Slack tokens
        /\bghp_[A-Za-z0-9]{36,}\b/,                          # GitHub personal access tokens
        /\bghu_[A-Za-z0-9]{36,}\b/,                          # GitHub user-to-server tokens
        /\bghs_[A-Za-z0-9]{36,}\b/,                          # GitHub server-to-server tokens
        /\bglpat-[A-Za-z0-9_-]{20,}\b/,                      # GitLab personal access tokens
        /\bnpm_[A-Za-z0-9]{36,}\b/                           # npm tokens
      ].freeze

      # Lines that reveal env var names (dotenv, Figaro, etc.)
      DOTENV_PATTERN = /\[dotenv\]\s+Set\s+.*/i
      # Match ALL_CAPS env var assignments containing sensitive words
      ENV_VAR_LINE_PATTERN = /\b[A-Z][A-Z0-9_]*(SECRET|KEY|TOKEN|PASSWORD|API|CREDENTIAL)[A-Z0-9_]*=\S+/

      def self.call(lines: nil, level: "all", file: nil, search: nil, server_context: nil, **_extra)
        warnings = []

        # Normalize and validate lines
        original_lines = lines
        lines = (lines || config.log_lines).to_i
        if original_lines
          int_val = original_lines.to_i
          if int_val < 1
            lines = 1
            warnings << "lines must be >= 1, using 1"
          elsif int_val > MAX_LINES
            lines = MAX_LINES
            warnings << "lines clamped to #{MAX_LINES} (was #{int_val})"
          else
            lines = int_val
          end
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
            "Log file '#{file || "#{Rails.env}.log"}' not found.\nAvailable log files: #{available.join(', ')}"
          else
            "No log files found in log/. Your app may log to stdout (common in Docker/container environments)."
          end
          return text_response(msg)
        end

        # Tail the file
        raw_lines = tail_file(path, lines)
        if raw_lines.empty?
          return text_response("# Log: #{File.basename(path)}\nLog file is empty.\n\n---\nAvailable log files: #{available.join(', ')}")
        end

        # Detect format and filter by level
        format = detect_format(raw_lines)
        filtered = filter_by_level(raw_lines, level, format)

        # Apply search filter
        if search && !search.strip.empty?
          search_term = search.strip
          filtered = filtered.select { |line| line.downcase.include?(search_term.downcase) }
        end

        if filtered.empty?
          return text_response("# Log: #{File.basename(path)}\nNo entries matching level:#{level}#{" search:\"#{search}\"" if search}.\n\n---\nAvailable log files: #{available.join(', ')}")
        end

        # Redact sensitive data
        redacted = filtered.map { |line| redact(line) }

        # Format output
        file_size = File.size(path)
        size_label = if file_size > 1_000_000
          "#{(file_size / 1_000_000.0).round(1)} MB"
        elsif file_size > 1_000
          "#{(file_size / 1_000.0).round(1)} KB"
        else
          "#{file_size} B"
        end

        level_label = level == "all" ? "all levels" : "#{level}+"

        output = [ "# Log: #{File.basename(path)}" ]
        output << "Size: #{size_label} | Showing last #{redacted.size} lines | Level: #{level_label}"
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

      private_class_method def self.resolve_log_file(file_name)
        root = Rails.root.to_s

        if file_name
          # Strip .log suffix if provided, then re-add; sanitize null bytes and path separators
          name = file_name.to_s.strip.delete("\0").delete_suffix(".log")
          name = File.basename(name) # Prevent directory traversal via slashes
          path = File.join(root, "log", "#{name}.log")
        else
          path = File.join(root, "log", "#{Rails.env}.log")
        end

        # Path traversal protection: separator-aware containment so a sibling
        # directory (e.g. `/var/app/myapp_evil/log.log` vs `/var/app/myapp/`)
        # cannot pass `start_with?("/var/app/myapp")`. Return the realpath so
        # downstream callers (tail_file, File.size) operate on the canonical
        # path, closing the TOCTOU window between this check and the open().
        return nil unless File.exist?(path)
        real = File.realpath(path)
        real_root = File.realpath(root)
        return nil unless real == real_root || real.start_with?(real_root + File::SEPARATOR)

        # Post-realpath sensitive recheck (Rule 3 of the file-reading
        # conventions): a symlink placed inside `log/` pointing at a
        # sensitive file still under Rails.root (e.g. `log/sneak.log ->
        # ../config/master.key`) would otherwise pass the containment
        # check above and be read by `tail_file`. Reject anything whose
        # real path matches `sensitive_patterns`.
        relative_real = real.sub("#{real_root}/", "")
        return nil if sensitive_file?(relative_real)

        real
      rescue Errno::ENOENT
        nil
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

      # ── Log format detection + level filtering ─────────────────────

      private_class_method def self.detect_format(lines)
        return :json if lines.first&.strip&.start_with?("{")
        :standard
      end

      private_class_method def self.extract_level(line, format)
        case format
        when :json
          match = line.match(/"level"\s*:\s*"(\w+)"/i)
          match[1].upcase if match
        when :standard
          # Rails format: I, [timestamp] INFO -- : message
          # Or: [2026-03-29 10:00:00] INFO  message
          match = line.match(/\b(DEBUG|INFO|WARN(?:ING)?|ERROR|FATAL)\b/i)
          level = match[1].upcase if match
          level = "WARN" if level == "WARNING"
          level
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
            rank = LEVEL_HIERARCHY[level] || 0
            include_continuation = rank >= min_rank
          end
          # Lines without a level are continuations (stack traces)
          result << line if include_continuation
        end

        result
      end

      # ── Redaction ───────────────────────────────────────────────────

      private_class_method def self.redact(text)
        result = text.dup

        # Strip ANSI escape sequences (color codes from dotenv, zeitwerk, etc.)
        result.gsub!(ANSI_ESCAPE, "")

        # Strip dotenv lines that reveal env var names (e.g., "[dotenv] Set SECRET_KEY_BASE, DATABASE_URL")
        result.gsub!(DOTENV_PATTERN, "[dotenv] Set [ENV VARS REDACTED]")
        # Strip standalone env var assignment lines (e.g., "GEMINI_API_KEY=...")
        result.gsub!(ENV_VAR_LINE_PATTERN, "[ENV VAR REDACTED]")

        REDACT_PATTERNS.each do |pattern|
          if pattern.source.include?("password\":") || pattern.source.include?("password\"=>")
            result.gsub!(pattern, '\1[REDACTED]\2')
          elsif pattern.source.include?("SECRET|PRIVATE")
            result.gsub!(pattern) { |m| m.split("=", 2)[0] + "=[REDACTED]" }
          elsif pattern.source.include?("@")
            result.gsub!(pattern, "[EMAIL]")
          else
            result.gsub!(pattern, "[REDACTED]")
          end
        end
        result
      end

      # ── Available log files ─────────────────────────────────────────

      private_class_method def self.available_log_files
        log_dir = File.join(Rails.root.to_s, "log")
        return [] unless Dir.exist?(log_dir)
        Dir.glob(File.join(log_dir, "*.log"))
          .map { |f| File.basename(f) }
          .select { |f| f.match?(/\A[\w.\-]+\.log\z/) } # Only clean filenames (alphanumeric, dots, hyphens, underscores)
          .sort
      end
    end
  end
end
