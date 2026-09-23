# frozen_string_literal: true

module RailsAiContext
  module Tools
    class GetEnv < BaseTool
      tool_name "rails_get_env"
      description "Discover environment variables, external service dependencies, and credentials keys used by the app. " \
        "Use when: setting up a development environment, debugging missing config, or auditing external dependencies. " \
        "Scans .rb, .rake, ERB views and config YAML for ENV[], plus .env.example, Dockerfile, external HTTP calls, and credentials keys (never values)."

      input_schema(
        properties: {
          detail: RailsAiContext::DetailLevel.schema("Detail level. summary: env var names only. standard: env vars grouped by source + external services (default). full: everything including per-file locations, Dockerfile vars, and credentials keys.")
        }
      )

      guide_row(
        order: 17,
        mcp: "rails_get_env",
        summary: "Environment variables + credentials keys (not values)"
      )

      annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true, open_world_hint: false)

      # One wording for the same fact on both detail levels.
      DEFAULTS_DIFFER = "defaults differ by call site"

      # `ENV.fetch("PORT", defaults[:port])`: a fallback with no printable
      # value, which is still a site that never raises KeyError.
      COMPUTED_DEFAULT = :computed

      def self.call(detail: "standard", server_context: nil)
        root = rails_app.root.to_s

        env_vars = scan_env_vars(root)
        env_example = scan_env_example(root)
        dockerfile_vars = scan_dockerfile(root)
        external_services = detect_external_services(root, env_vars.values.flatten.map { |v| v[:name] }.uniq)
        credentials_keys = detect_credentials_keys
        encrypted_columns = detect_encrypted_columns

        # Merge all discovered env var names
        all_var_names = Set.new
        env_vars.each { |_file, vars| vars.each { |v| all_var_names << v[:name] } }
        env_example.each { |v| all_var_names << v[:name] }
        dockerfile_vars.each { |v| all_var_names << v[:name] if v[:type] == "ENV" }

        if all_var_names.empty? && external_services.empty? && credentials_keys.empty?
          return text_response("No environment variables, external services, or credentials keys detected.")
        end

        case detail
        when "summary"
          format_summary(all_var_names, external_services, credentials_keys)
        when "standard"
          format_standard(env_vars, env_example, external_services, credentials_keys, encrypted_columns)
        when "full"
          format_full(env_vars, env_example, dockerfile_vars, external_services, credentials_keys, encrypted_columns, root)
        end
      end

      private_class_method def self.format_summary(all_var_names, external_services, credentials_keys)
        lines = [ "# Environment Overview", "" ]
        lines << "**Environment variables:** #{all_var_names.size}"
        lines << "**External services:** #{external_services.size}" if external_services.any?
        lines << "**Credentials keys:** #{credentials_keys.size}" if credentials_keys.any?
        lines << ""

        if all_var_names.any?
          grouped = group_env_vars(all_var_names.to_a)
          grouped.each do |group, vars|
            lines << "## #{group}"
            vars.sort.each { |v| lines << "- `#{v}`" }
          end
        end

        lines << "" << "_Use `detail:\"standard\"` for sources and external services, or `detail:\"full\"` for per-file locations._"
        text_response(lines.join("\n"))
      end

      # Named in the answer, because a name missing from it is otherwise
      # indistinguishable from a name the app does not read. `database.yml`
      # and the other files on `sensitive_patterns` are never opened.
      SCAN_NOTE = "_Scanned `app`, `config` and `lib` for `.rb`, `.rake`, `.erb` and config `.yml`. " \
        "Files matching `sensitive_patterns` (config/database.yml, credentials, keys) are never read._"

      private_class_method def self.format_standard(env_vars, env_example, external_services, credentials_keys, encrypted_columns)
        lines = [ "# Environment Configuration", "" ]

        # ENV vars from code, grouped by purpose
        all_names = Set.new
        env_vars.each { |_file, vars| vars.each { |v| all_names << v[:name] } }

        if all_names.any?
          # One pass over the scan, not one per variable: the standard listing
          # asked every file about every name.
          sites_by_variable = sites_by_name(env_vars)
          grouped = group_env_vars(all_names.to_a)
          grouped.each do |group, vars|
            lines << "## #{group}"
            vars.sort.each do |name|
              sites = sites_by_variable[name] || []
              defaults = sites.map { |v| v[:default] }.uniq
              entry = "- `#{name}`"
              entry += if disagree?(sites)
                # A site with no default argument raises KeyError when the
                # variable is unset, and one site's fallback labelled as the
                # variable's said the opposite.
                " (#{DEFAULTS_DIFFER}; `detail:\"full\"` names each)"
              elsif defaults.size == 1 && defaults.first.is_a?(String)
                " (default: `#{defaults.first}`)"
              else
                ""
              end
              lines << entry
            end
            lines << ""
          end
        end

        # .env.example
        if env_example.any?
          example_only = env_example.select { |v| !all_names.include?(v[:name]) }
          if example_only.any?
            lines << "## From .env.example (not referenced in code)"
            example_only.each do |v|
              entry = "- `#{v[:name]}`"
              entry += " - #{v[:comment]}" if v[:comment]
              lines << entry
            end
            lines << ""
          end
        end

        # External services
        if external_services.any?
          lines << "## External Services"
          external_services.each do |svc|
            entry = "- **#{svc[:name]}**"
            entry += " (#{svc[:gem]})" if svc[:gem]
            entry += " - found in `#{svc[:file]}`" if svc[:file]
            lines << entry
          end
          lines << ""
        end

        lines.concat(credentials_and_encrypted_lines(credentials_keys, encrypted_columns))

        lines << SCAN_NOTE
        text_response(lines.join("\n"))
      end

      # Both `standard` and `full` end with these two sections, so a wording
      # change cannot land in one detail level and miss the other.
      private_class_method def self.credentials_and_encrypted_lines(credentials_keys, encrypted_columns)
        lines = []

        if credentials_keys.any?
          lines << "## Credentials Keys (values hidden)"
          credentials_keys.each { |k| lines << "- `#{k}`" }
          lines << ""
        elsif credentials_file_present?
          lines << "## Credentials Keys (values hidden)"
          lines << RailsAiContext::Confidence.unavailable("credentials are encrypted; reading the key names needs a booted app with its master key")
          lines << ""
        end

        if encrypted_columns.any?
          lines << "## Encrypted Model Columns"
          encrypted_columns.each do |model, cols|
            lines << "- **#{model}:** #{cols.join(', ')}"
          end
          lines << ""
        end

        lines
      end

      private_class_method def self.format_full(env_vars, env_example, dockerfile_vars, external_services, credentials_keys, encrypted_columns, root)
        lines = [ "# Environment Configuration (Full Detail)", "" ]

        # ENV vars grouped by category with file annotations
        if env_vars.any?
          lines << "## Environment Variables by Category"

          # Build a map: var_name -> { details from all files }
          var_details = {}
          env_vars.sort_by { |file, _| file }.each do |file, vars|
            relative = file.sub("#{root}/", "")
            vars.each do |v|
              var_details[v[:name]] ||= { files: [], defaults: [] }
              var_details[v[:name]][:files] << { file: relative, line: v[:line], default: v[:default], bracket: v[:bracket] }
              var_details[v[:name]][:defaults] << v[:default]
            end
          end

          # Group by category
          categorized = Hash.new { |h, k| h[k] = [] }
          var_details.each do |name, details|
            category = categorize_env_var(name)
            categorized[category] << { name: name, **details }
          end

          sorted_categories = categorized.keys.sort_by { |k| CATEGORY_ORDER.index(k) || 99 }

          sorted_categories.each do |category|
            vars = categorized[category]
            lines << "" << "### #{category}"
            vars.sort_by { |v| v[:name] }.each do |v|
              defaults = v[:defaults].uniq
              # Where the sites disagree the default belongs next to the site
              # that passes it: the one that passes none is the one a reader
              # most needs, since it raises KeyError when the variable is unset.
              file_locations = v[:files].map { |f|
                at = f[:line] ? "#{f[:file]}:#{f[:line]}" : f[:file]
                next at unless disagree?(v[:files])
                case f[:default]
                when String then "#{at} default: `#{f[:default]}`"
                when COMPUTED_DEFAULT then "#{at} default computed at runtime"
                else f[:bracket] ? "#{at} nil when unset" : "#{at} no default"
                end
              }.uniq
              entry = "- `#{v[:name]}`"
              entry += " (default: `#{defaults.first}`)" if defaults.size == 1 && defaults.first.is_a?(String)
              entry += " (#{DEFAULTS_DIFFER})" if disagree?(v[:files])
              entry += " (#{file_locations.join(', ')})"
              lines << entry
            end
          end
          lines << ""
        end

        # .env.example contents
        if env_example.any?
          lines << "## .env.example"
          env_example.each do |v|
            entry = "- `#{v[:name]}`"
            entry += " = `#{v[:example_value]}`" if v[:example_value] && !v[:example_value].empty?
            entry += " - #{v[:comment]}" if v[:comment]
            lines << entry
          end
          lines << ""
        end

        # Dockerfile ENV/ARG
        if dockerfile_vars.any?
          lines << "## Dockerfile Variables"
          dockerfile_vars.each do |v|
            entry = "- `#{v[:type]}` `#{v[:name]}`"
            entry += " = `#{v[:default]}`" if v[:default]
            lines << entry
          end
          lines << ""
        end

        # External services
        if external_services.any?
          lines << "## External Services"
          external_services.each do |svc|
            lines << "- **#{svc[:name]}**"
            lines << "  - Detected via: #{svc[:detection]}"
            lines << "  - Gem: `#{svc[:gem]}`" if svc[:gem]
            lines << "  - File: `#{svc[:file]}`" if svc[:file]
            lines << "  - Related env vars: #{svc[:env_vars].join(', ')}" if svc[:env_vars]&.any?
          end
          lines << ""
        end

        lines.concat(credentials_and_encrypted_lines(credentials_keys, encrypted_columns))

        lines << SCAN_NOTE
        text_response(lines.join("\n"))
      end

      # An app reads ENV from more than its Ruby: `config/database.yml` and
      # `config/newrelic.yml` through ERB, a rake task, a view. Scanning `.rb`
      # alone left those names out of the very answer someone writes a
      # `.env.example` from, with nothing saying a file type was skipped.
      SCAN_PATTERNS = {
        "app"       => %w[**/*.rb **/*.erb],
        "config"    => %w[**/*.rb **/*.yml **/*.yaml],
        "lib"       => %w[**/*.rb **/*.rake]
      }.freeze

      private_class_method def self.scan_files(root, real_root)
        SCAN_PATTERNS.flat_map do |dir_name, patterns|
          dir = File.join(root, dir_name)
          next [] unless Dir.exist?(dir)

          patterns.flat_map { |pattern| safe_glob(dir, pattern, real_root) }
        end.uniq
      end

      # ERB tags carry the Ruby of a `.yml` or `.erb` file.
      private_class_method def self.ruby_source(file, source)
        return source if file.end_with?(".rb", ".rake")

        RailsAiContext::ErbSource.ruby_in_place(source)
      end

      private_class_method def self.scan_env_vars(root)
        env_vars = {}
        real_root = File.realpath(root).to_s

        scan_files(root, real_root).each do |file|
          source = safe_read(file)
          next unless source
          next unless source.include?("ENV")

          vars = env_references(ruby_source(file, source))
          env_vars[file] = vars if vars.any?
        end

        env_vars
      end

      # The parser decides what counts as a name. A line scan matched whatever
      # sat between the quotes, so an app that builds its variable names by
      # interpolation - the normal shape for one carrying several Redis
      # connections - had `#{prefix}URL` reported as a variable, in the very
      # tool someone reaches for when writing a .env.example. Comments come out
      # for free, including one trailing a line that also reads ENV.
      private_class_method def self.env_references(source)
        ast = Introspectors::SourceIntrospector.walk_source(
          source, { env: -> { Introspectors::Listeners::EnvAccessListener.new } }
        )

        (ast[:env] || []).filter_map do |entry|
          name = entry[:key]
          # The parser already guaranteed a literal, so this only has to reject
          # what is not a variable name at all. Deliberately looser than
          # EnvIntrospector's uppercase rule: that one filters a catalogue of
          # known Rails variables, while this lists whatever the app reads, and
          # a lowercase `ENV["port"]` is still a variable the app reads.
          next unless name.match?(/\A[A-Za-z_][A-Za-z0-9_]*\z/)

          var = { name: name, line: entry[:location] }
          # `ENV["X"]` answers nil when unset; only a fetch without a default raises.
          var[:bracket] = true if entry[:method] == "[]"
          # The listener writes a `nil` default as the string "nil", which
          # redaction then treated as a value worth hiding.
          if entry[:default]
            var[:default] = entry[:default] == "nil" ? "nil" : RailsAiContext::Redaction.value(name, entry[:default])
          elsif entry[:has_default]
            var[:default] = COMPUTED_DEFAULT
          end
          var
        end
      rescue => e
        RailsAiContext.debug_fail(e, [], label: "env_references")
      end

      private_class_method def self.scan_env_example(root)
        # Only read .env.example or .env.sample - NEVER .env or .env.local
        candidates = %w[.env.example .env.sample .env.template]
        vars = []

        candidates.each do |name|
          path = File.join(root, name)
          source = safe_read(path)
          next unless source

          source.each_line do |line|
            stripped = line.strip
            next if stripped.empty? || stripped.start_with?("#")

            # Parse KEY=value # comment
            if (match = stripped.match(/\A([A-Z_][A-Z0-9_]*)\s*=\s*(.*)/))
              value_and_comment = match[2]
              comment = nil
              example_value = value_and_comment

              # Extract inline comment
              if value_and_comment.include?("#")
                parts = value_and_comment.split("#", 2)
                example_value = parts[0].strip
                comment = parts[1]&.strip
              end

              # Don't expose actual secret values - only show structure
              example_value = RailsAiContext::Redaction.value(match[1], example_value, placeholder_ok: true).to_s

              vars << { name: match[1], example_value: example_value, comment: comment }
            end
          end

          break # Only read the first found example file
        end

        vars
      end

      private_class_method def self.scan_dockerfile(root)
        vars = []
        candidates = %w[Dockerfile Dockerfile.production Dockerfile.dev]

        candidates.each do |name|
          path = File.join(root, name)
          source = safe_read(path)
          next unless source

          dockerfile_instructions(source).each do |instruction|
            if (match = instruction.match(/\AENV\s+(.+)/m))
              dockerfile_env_pairs(match[1]).each do |var_name, raw|
                default = RailsAiContext::Redaction.value(var_name, raw)
                default = nil if default.to_s.empty?
                vars << { type: "ENV", name: var_name, default: default, file: name }
              end
            end

            # ARG takes one variable per instruction.
            if (match = instruction.match(/\AARG\s+([A-Z_][A-Z0-9_]*)(?:\s*=\s*(.*))?/))
              default = RailsAiContext::Redaction.value(match[1], match[2])
              default = nil if default.to_s.empty?
              vars << { type: "ARG", name: match[1], default: default, file: name }
            end
          end
        end

        vars
      end

      # One entry per Dockerfile instruction, with backslash continuations
      # joined. Docker treats the continued lines as one instruction, so a
      # reader that works line by line sees a bare `ENV \\` and nothing else.
      private_class_method def self.dockerfile_instructions(source)
        instructions = []
        buffer = +""

        source.each_line do |line|
          stripped = line.strip
          next if stripped.start_with?("#")
          if buffer.empty? && stripped.empty?
            next
          end

          if stripped.end_with?("\\")
            buffer << stripped.delete_suffix("\\").strip << " "
          else
            buffer << stripped
            instructions << buffer.strip unless buffer.strip.empty?
            buffer = +""
          end
        end
        instructions << buffer.strip unless buffer.strip.empty?

        instructions
      end

      ENV_PAIR = /([A-Z_][A-Z0-9_]*)=("(?:[^"\\]|\\.)*"|'[^']*'|\S*)/
      private_constant :ENV_PAIR

      # `ENV A=1 B=2` declares two variables; the legacy `ENV KEY value`
      # form declares one whose value is the rest of the instruction.
      private_class_method def self.dockerfile_env_pairs(body)
        pairs = body.scan(ENV_PAIR)
        return pairs unless pairs.empty?

        legacy = body.match(/\A([A-Z_][A-Z0-9_]*)\s+(.*)/m)
        legacy ? [ [ legacy[1], legacy[2] ] ] : []
      end

      private_class_method def self.detect_external_services(root, env_names)
        services = []
        gemfile_path = File.join(root, "Gemfile")

        # Service detection rules: gem name → service name + detection method
        service_gems = {
          "aws-sdk" => { name: "AWS", env_prefix: "AWS_" },
          "aws-sdk-s3" => { name: "AWS S3", env_prefix: "AWS_" },
          "aws-sdk-ses" => { name: "AWS SES", env_prefix: "AWS_" },
          "stripe" => { name: "Stripe", env_prefix: "STRIPE_" },
          "braintree" => { name: "Braintree", env_prefix: "BRAINTREE_" },
          "twilio-ruby" => { name: "Twilio", env_prefix: "TWILIO_" },
          "sendgrid-ruby" => { name: "SendGrid", env_prefix: "SENDGRID_" },
          "postmark-rails" => { name: "Postmark", env_prefix: "POSTMARK_" },
          "redis" => { name: "Redis", env_prefix: "REDIS_" },
          "sidekiq" => { name: "Sidekiq (Redis)", env_prefix: "REDIS_" },
          "elasticsearch" => { name: "Elasticsearch", env_prefix: "ELASTICSEARCH_" },
          "searchkick" => { name: "Searchkick (Elasticsearch)", env_prefix: "ELASTICSEARCH_" },
          "sentry-ruby" => { name: "Sentry", env_prefix: "SENTRY_" },
          "sentry-rails" => { name: "Sentry", env_prefix: "SENTRY_" },
          "newrelic_rpm" => { name: "New Relic", env_prefix: "NEW_RELIC_" },
          "datadog" => { name: "Datadog", env_prefix: "DD_" },
          "bugsnag" => { name: "Bugsnag", env_prefix: "BUGSNAG_" },
          "rollbar" => { name: "Rollbar", env_prefix: "ROLLBAR_" },
          "pusher" => { name: "Pusher", env_prefix: "PUSHER_" },
          "cloudinary" => { name: "Cloudinary", env_prefix: "CLOUDINARY_" },
          "fog-aws" => { name: "AWS (via Fog)", env_prefix: "AWS_" },
          "plaid" => { name: "Plaid", env_prefix: "PLAID_" },
          "intercom-rails" => { name: "Intercom", env_prefix: "INTERCOM_" },
          "omniauth" => { name: "OAuth Provider", env_prefix: "OAUTH_" },
          "recaptcha" => { name: "reCAPTCHA", env_prefix: "RECAPTCHA_" }
        }

        gemfile = safe_read(gemfile_path)
        if gemfile
          service_gems.each do |gem_name, info|
            next unless gemfile.match?(/gem\s+["']#{Regexp.escape(gem_name)}["']/)
            services << {
              name: info[:name],
              gem: gem_name,
              detection: "Gemfile",
              env_vars: env_names.grep(/\A#{Regexp.escape(info[:env_prefix])}/).sort
            }
          end
        end

        # Detect HTTP client usage in app code
        http_services = detect_http_clients(root)
        services.concat(http_services)

        services.uniq { |s| s[:name] }
      end

      private_class_method def self.detect_http_clients(root)
        services = []
        app_dir = File.join(root, "app")
        return services unless Dir.exist?(app_dir)

        real_root = File.realpath(root).to_s
        safe_glob(app_dir, "**/*.rb", real_root).each do |file|
          source = safe_read(file)
          next unless source

          relative = file.sub("#{real_root}/", "")

          # Faraday connections
          source.scan(/Faraday\.new\s*\(?\s*(?:url:\s*)?["']([^"']+)["']/).each do |match|
            url = match[0]
            name = extract_service_name_from_url(url)
            services << { name: name, detection: "Faraday.new", file: relative } if name
          end

          # Net::HTTP
          source.scan(/Net::HTTP\.\w+\s*\(?\s*(?:URI\.parse\s*\(?\s*)?["']([^"']+)["']/).each do |match|
            url = match[0]
            name = extract_service_name_from_url(url)
            services << { name: name, detection: "Net::HTTP", file: relative } if name
          end

          # HTTParty
          source.scan(/HTTParty\.\w+\s*\(?\s*["']([^"']+)["']/).each do |match|
            url = match[0]
            name = extract_service_name_from_url(url)
            services << { name: name, detection: "HTTParty", file: relative } if name
          end
        end

        services.uniq { |s| "#{s[:name]}:#{s[:file]}" }
      rescue => e
        RailsAiContext.debug_fail(e, [], label: "detect_http_clients")
      end

      private_class_method def self.extract_service_name_from_url(url)
        return nil if url.start_with?("ENV") || url.include?("#" + "{")

        begin
          uri = URI.parse(url)
          return nil unless uri&.host
          # Extract meaningful service name from hostname
          host = uri.host
          # Remove common TLDs and subdomains
          parts = host.split(".")
          return nil if parts.size < 2
          # Use the main domain part
          parts[-2]&.capitalize
        rescue => e
          RailsAiContext.debug_fail(e, nil, label: "extract_service_name_from_url")
        end
      end

      # An encrypted credentials file the tool could not open is a different
      # fact from an app with no credentials, and only one of them is true here.
      private_class_method def self.credentials_file_present?
        root = rails_app.root.to_s
        # Rails 6+ apps commonly carry only per-environment credentials, with
        # no top-level file at all.
        File.exist?(File.join(root, "config", "credentials.yml.enc")) ||
          Dir.glob(File.join(root, "config", "credentials", "*.yml.enc")).any?
      rescue StandardError
        false
      end

      private_class_method def self.detect_credentials_keys
        keys = []

        begin
          creds = Rails.application.credentials
          return [] unless creds

          # Recursively extract key paths (never values)
          extract_key_paths(creds.config, [], keys)
        rescue => _e
          # Credentials not accessible (missing master key, etc.) - graceful degradation
          # Try parsing credentials file structure without decrypting
          keys = parse_credentials_structure
        end

        keys.sort
      end

      private_class_method def self.extract_key_paths(hash, prefix, keys)
        return unless hash.is_a?(Hash)

        hash.each do |key, value|
          path = prefix + [ key.to_s ]
          if value.is_a?(Hash)
            extract_key_paths(value, path, keys)
          else
            keys << path.join(".")
          end
        end
      end

      private_class_method def self.parse_credentials_structure
        # Look for credentials template or example
        root = rails_app.root.to_s
        candidates = %w[
          config/credentials.yml.example
          config/credentials.yml.sample
        ]

        candidates.each do |file|
          path = File.join(root, file)
          source = safe_read(path)
          next unless source

          keys = []
          source.each_line do |line|
            stripped = line.strip
            next if stripped.empty? || stripped.start_with?("#")
            if (match = stripped.match(/\A(\w[\w.]*\w?):/))
              keys << match[1]
            end
          end
          return keys if keys.any?
        end

        []
      end

      private_class_method def self.detect_encrypted_columns
        ctx = cached_context
        models = ctx[:models]
        return {} unless models.is_a?(Hash)

        encrypted = {}
        models.each do |name, data|
          next unless data.is_a?(Hash)
          if data[:encrypts]&.any?
            encrypted[name] = data[:encrypts].map(&:to_s)
          end
        end

        encrypted
      end

      # Matched on whole `_`-delimited segments: unanchored, PORT matched
      # inside PORTAL and SUPPORT, and MAIL inside VOICEMAIL. The mail keys
      # carry their own spellings, because MAILER_SENDER and MAILGUN_DOMAIN
      # are mail settings whose segment is not the bare word.
      CATEGORY_SEGMENTS = [
        [ "API Keys & Secrets", %w[API_KEY SECRET TOKEN] ],
        [ "Mail", %w[MAIL MAILER MAILGUN SENDGRID POSTMARK IMAP SMTP] ],
        [ "Database", %w[DATABASE DB REDIS] ],
        [ "Monitoring", %w[OTEL SENTRY DATADOG NEWRELIC APPSIGNAL] ],
        [ "Push Notifications", %w[PUSH VAPID FCM] ],
        [ "Infrastructure", %w[PORT CONCURRENCY THREADS WORKERS TIMEOUT QUEUE PIDFILE] ]
      ].freeze

      # Display order, not declaration order: CATEGORY_SEGMENTS is ordered by
      # how specific a match is, and reading the order off it would swap
      # Infrastructure and Monitoring in every answer.
      CATEGORY_ORDER = [
        "API Keys & Secrets", "Mail", "Database", "Infrastructure",
        "Monitoring", "Push Notifications", "Other"
      ].freeze

      private_class_method def self.categorize_env_var(name)
        segments = name.to_s.upcase.split("_")
        CATEGORY_SEGMENTS.each do |category, keys|
          return category if keys.any? { |key| segments.each_cons(key.count("_") + 1).any? { |run| run.join("_") == key } }
        end
        "Other"
      end

      private_class_method def self.group_env_vars(var_names)
        groups = Hash.new { |h, k| h[k] = [] }

        var_names.each do |name|
          groups[categorize_env_var(name)] << name
        end

        groups.sort_by { |k, _| CATEGORY_ORDER.index(k) || 99 }
      end

      # Every site each variable is read at.
      private_class_method def self.sites_by_name(env_vars)
        env_vars.each_value.with_object(Hash.new { |h, k| h[k] = [] }) do |vars, found|
          vars.each { |v| found[v[:name]] << v }
        end
      end

      # Whether the sites answer an unset variable differently. `ENV["X"]` and
      # `ENV.fetch("X", nil)` both answer nil, so they agree; a fetch with no
      # default raises, which is the difference a reader needs to see.
      private_class_method def self.disagree?(sites)
        sites.map { |v| v[:bracket] || v[:default] == "nil" ? :nil_when_unset : v[:default] }.uniq.size > 1
      end
    end
  end
end
