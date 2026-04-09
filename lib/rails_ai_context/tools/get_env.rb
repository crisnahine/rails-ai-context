# frozen_string_literal: true

module RailsAiContext
  module Tools
    class GetEnv < BaseTool
      tool_name "rails_get_env"
      description "Discover environment variables, external service dependencies, and credentials keys used by the app. " \
        "Use when: setting up a development environment, debugging missing config, or auditing external dependencies. " \
        "Scans Ruby files for ENV[], .env.example, Dockerfile, external HTTP calls, and credentials keys (never values)."

      input_schema(
        properties: {
          detail: {
            type: "string",
            enum: %w[summary standard full],
            description: "Detail level. summary: env var names only. standard: env vars grouped by source + external services (default). full: everything including per-file locations, Dockerfile vars, and credentials keys."
          }
        }
      )

      annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true, open_world_hint: false)

      def self.call(detail: "standard", server_context: nil)
        root = Rails.root.to_s

        env_vars = scan_env_vars(root)
        env_example = scan_env_example(root)
        dockerfile_vars = scan_dockerfile(root)
        external_services = detect_external_services(root)
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
        else
          text_response("Unknown detail level: #{detail}. Use summary, standard, or full.")
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

      private_class_method def self.format_standard(env_vars, env_example, external_services, credentials_keys, encrypted_columns)
        lines = [ "# Environment Configuration", "" ]

        # ENV vars from code, grouped by purpose
        all_names = Set.new
        env_vars.each { |_file, vars| vars.each { |v| all_names << v[:name] } }

        if all_names.any?
          grouped = group_env_vars(all_names.to_a)
          grouped.each do |group, vars|
            lines << "## #{group}"
            vars.sort.each do |name|
              # Find default value if any
              default = find_default_value(env_vars, name)
              entry = "- `#{name}`"
              entry += " (default: `#{default}`)" if default
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
              entry += " — #{v[:comment]}" if v[:comment]
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
            entry += " — found in `#{svc[:file]}`" if svc[:file]
            lines << entry
          end
          lines << ""
        end

        # Credentials keys
        if credentials_keys.any?
          lines << "## Credentials Keys (values hidden)"
          credentials_keys.each { |k| lines << "- `#{k}`" }
          lines << ""
        end

        # Encrypted columns
        if encrypted_columns.any?
          lines << "## Encrypted Model Columns"
          encrypted_columns.each do |model, cols|
            lines << "- **#{model}:** #{cols.join(', ')}"
          end
          lines << ""
        end

        text_response(lines.join("\n"))
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
              var_details[v[:name]] ||= { files: [], default: nil }
              var_details[v[:name]][:files] << { file: relative, line: v[:line] }
              var_details[v[:name]][:default] ||= v[:default]
            end
          end

          # Group by category
          categorized = Hash.new { |h, k| h[k] = [] }
          var_details.each do |name, details|
            category = categorize_env_var(name)
            categorized[category] << { name: name, **details }
          end

          category_order = [
            "API Keys & Secrets", "Mail", "Database", "Infrastructure",
            "Monitoring", "Push Notifications", "Other"
          ]
          sorted_categories = categorized.keys.sort_by { |k| category_order.index(k) || 99 }

          sorted_categories.each do |category|
            vars = categorized[category]
            lines << "" << "### #{category}"
            vars.sort_by { |v| v[:name] }.each do |v|
              file_locations = v[:files].map { |f| f[:line] ? "#{f[:file]}:#{f[:line]}" : f[:file] }.uniq
              entry = "- `#{v[:name]}`"
              entry += " (default: `#{v[:default]}`)" if v[:default]
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
            entry += " — #{v[:comment]}" if v[:comment]
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

        # Credentials keys
        if credentials_keys.any?
          lines << "## Credentials Keys (values hidden)"
          credentials_keys.each { |k| lines << "- `#{k}`" }
          lines << ""
        end

        # Encrypted columns
        if encrypted_columns.any?
          lines << "## Encrypted Model Columns"
          encrypted_columns.each do |model, cols|
            lines << "- **#{model}:** #{cols.join(', ')}"
          end
          lines << ""
        end

        text_response(lines.join("\n"))
      end

      private_class_method def self.scan_env_vars(root)
        env_vars = {}
        scan_dirs = %w[app config lib].map { |d| File.join(root, d) }

        scan_dirs.each do |dir|
          next unless Dir.exist?(dir)
          Dir.glob(File.join(dir, "**", "*.rb")).each do |file|
            next if File.size(file) > max_file_size
            next if sensitive_file?(file.sub("#{root}/", ""))

            source = safe_read(file)
            next unless source
            next unless source.include?("ENV")

            vars = []
            source.each_line.with_index(1) do |line, line_num|
              # ENV["VAR_NAME"] or ENV['VAR_NAME']
              line.scan(/ENV\[["']([^"']+)["']\]/).each do |match|
                vars << { name: match[0], line: line_num }
              end

              # ENV.fetch("VAR_NAME") or ENV.fetch("VAR_NAME", default)
              line.scan(/ENV\.fetch\(["']([^"']+)["'](?:\s*,\s*([^)]+))?\)/).each do |match|
                default = match[1]&.strip
                # Sanitize default — don't expose potential secrets
                default = sanitize_default(default) if default
                vars << { name: match[0], line: line_num, default: default }
              end
            end

            env_vars[file] = vars if vars.any?
          end
        end

        env_vars
      end

      private_class_method def self.scan_env_example(root)
        # Only read .env.example or .env.sample — NEVER .env or .env.local
        candidates = %w[.env.example .env.sample .env.template]
        vars = []

        candidates.each do |name|
          path = File.join(root, name)
          next unless File.exist?(path)
          next if File.size(path) > max_file_size

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

              # Don't expose actual secret values — only show structure
              example_value = sanitize_example_value(example_value)

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
          next unless File.exist?(path)
          next if File.size(path) > max_file_size

          source = safe_read(path)
          next unless source

          source.each_line do |line|
            stripped = line.strip

            # ENV KEY=value or ENV KEY value
            if (match = stripped.match(/\AENV\s+([A-Z_][A-Z0-9_]*)\s*=?\s*(.*)/))
              default = match[2].strip
              default = nil if default.empty?
              vars << { type: "ENV", name: match[1], default: default, file: name }
            end

            # ARG KEY=default
            if (match = stripped.match(/\AARG\s+([A-Z_][A-Z0-9_]*)(?:\s*=\s*(.*))?/))
              default = match[2]&.strip
              default = nil if default&.empty?
              vars << { type: "ARG", name: match[1], default: default, file: name }
            end
          end
        end

        vars
      end

      private_class_method def self.detect_external_services(root)
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

        if File.exist?(gemfile_path) && File.size(gemfile_path) < max_file_size
          gemfile = safe_read(gemfile_path)
          if gemfile
            service_gems.each do |gem_name, info|
              next unless gemfile.match?(/gem\s+["']#{Regexp.escape(gem_name)}["']/)
              services << {
                name: info[:name],
                gem: gem_name,
                detection: "Gemfile",
                env_vars: find_env_vars_with_prefix(info[:env_prefix], root)
              }
            end
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

        Dir.glob(File.join(app_dir, "**", "*.rb")).each do |file|
          next if File.size(file) > max_file_size
          source = safe_read(file)
          next unless source

          relative = file.sub("#{root}/", "")

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
        $stderr.puts "[rails-ai-context] detect_http_clients failed: #{e.message}" if ENV["DEBUG"]
        []
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
          $stderr.puts "[rails-ai-context] extract_service_name_from_url failed: #{e.message}" if ENV["DEBUG"]
          nil
        end
      end

      private_class_method def self.find_env_vars_with_prefix(prefix, root)
        return [] unless prefix

        vars = Set.new
        scan_dirs = %w[app config lib].map { |d| File.join(root, d) }

        scan_dirs.each do |dir|
          next unless Dir.exist?(dir)
          Dir.glob(File.join(dir, "**", "*.rb")).each do |file|
            next if File.size(file) > max_file_size
            source = safe_read(file)
            next unless source

            source.scan(/ENV(?:\[["']|\.fetch\(["'])(#{Regexp.escape(prefix)}[A-Z0-9_]+)/).each do |match|
              vars << match[0]
            end
          end
        end

        vars.to_a.sort
      rescue => e
        $stderr.puts "[rails-ai-context] find_env_vars_with_prefix failed: #{e.message}" if ENV["DEBUG"]
        []
      end

      private_class_method def self.detect_credentials_keys
        keys = []

        begin
          creds = Rails.application.credentials
          return [] unless creds

          # Recursively extract key paths (never values)
          extract_key_paths(creds.config, [], keys)
        rescue => _e
          # Credentials not accessible (missing master key, etc.) — graceful degradation
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
        root = Rails.root.to_s
        candidates = %w[
          config/credentials.yml.example
          config/credentials.yml.sample
        ]

        candidates.each do |file|
          path = File.join(root, file)
          next unless File.exist?(path)
          next if File.size(path) > max_file_size

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

      private_class_method def self.categorize_env_var(name)
        case name
        when /API_KEY|SECRET|TOKEN/i then "API Keys & Secrets"
        when /MAIL|IMAP|SMTP/i then "Mail"
        when /DATABASE|DB_|REDIS/i then "Database"
        when /OTEL|SENTRY|DATADOG|NEWRELIC|APPSIGNAL/i then "Monitoring"
        when /PUSH|VAPID|FCM/i then "Push Notifications"
        when /PORT|CONCURRENCY|THREADS|WORKERS|TIMEOUT|QUEUE|PIDFILE/i then "Infrastructure"
        else "Other"
        end
      end

      private_class_method def self.group_env_vars(var_names)
        groups = Hash.new { |h, k| h[k] = [] }

        var_names.each do |name|
          groups[categorize_env_var(name)] << name
        end

        # Sort groups: important ones first
        priority = [
          "API Keys & Secrets", "Mail", "Database", "Infrastructure",
          "Monitoring", "Push Notifications", "Other"
        ]
        groups.sort_by { |k, _| priority.index(k) || 99 }
      end

      private_class_method def self.find_default_value(env_vars, name)
        env_vars.each_value do |vars|
          vars.each do |v|
            return v[:default] if v[:name] == name && v[:default]
          end
        end
        nil
      end

      private_class_method def self.sanitize_default(value)
        return nil unless value
        stripped = value.strip.delete_prefix('"').delete_suffix('"').delete_prefix("'").delete_suffix("'")
        # Don't expose values that look like actual secrets
        if stripped.length > 30 || stripped.match?(/[a-f0-9]{16,}|sk_|pk_|key_|secret/i)
          "[redacted]"
        else
          stripped
        end
      end

      private_class_method def self.sanitize_example_value(value)
        return "" unless value
        stripped = value.strip.delete_prefix('"').delete_suffix('"').delete_prefix("'").delete_suffix("'")
        # Show placeholder/example values, redact anything that looks real
        if stripped.match?(/\Ayour_|\Aexample_|xxx|changeme|TODO|REPLACE/i) || stripped.empty?
          stripped
        elsif stripped.length > 40 || stripped.match?(/[a-f0-9]{16,}|sk_|pk_/)
          "[redacted]"
        else
          stripped
        end
      end
    end
  end
end
