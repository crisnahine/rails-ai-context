# frozen_string_literal: true

require "ipaddr"
require "uri"

module RailsAiContext
  module Tools
    class GetEnv < BaseTool
      tool_name "rails_get_env"
      description "Discover environment variables, external service dependencies, and credentials keys used by the app. " \
        "Use when: setting up a development environment, debugging missing config, or auditing external dependencies. " \
        "Scans .rb, .rake, ERB views and config YAML for ENV[], plus .env.example, Dockerfile, the env Kamal's config/deploy.yml sets, config gem settings and Anyway::Config keys, external HTTP calls, and credentials keys (never values)."

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
      COMPUTED_DEFAULT = Introspectors::EnvReferences::COMPUTED_DEFAULT

      def self.call(detail: "standard", server_context: nil)
        root = rails_app.root.to_s

        env_vars = scan_env_vars(root)
        env_example = scan_env_example(root)
        dockerfile_vars = scan_dockerfile(root)
        kamal_env = scan_kamal_env(root)
        settings = scan_settings(root)
        anyway_configs = Introspectors::AnywayConfigs.scan(root)
        external_services = detect_external_services(root, env_vars.values.flatten.map { |v| v[:name] }.uniq)
        credentials_keys = detect_credentials_keys
        encrypted_columns = detect_encrypted_columns

        # Merge all discovered env var names
        all_var_names = Set.new
        env_vars.each { |_file, vars| vars.each { |v| all_var_names << v[:name] } }
        env_example.each { |v| all_var_names << v[:name] }
        dockerfile_vars.each { |v| all_var_names << v[:name] if v[:type] == "ENV" }
        kamal_env.each { |v| all_var_names << v[:name] if v[:name] }

        anyway_configs.each { |c| c[:attributes].each { |a| all_var_names << a[:env] if a[:env] } }
        deploy_and_settings = kamal_lines(kamal_env, root) + settings_lines(settings) + anyway_lines(anyway_configs)

        text = if all_var_names.empty? && external_services.empty? && credentials_keys.empty? && deploy_and_settings.empty?
          "No environment variables, external services, or credentials keys detected."
        else
          case detail
          when "summary"
            format_summary(all_var_names, external_services, credentials_keys)
          when "standard"
            format_standard(env_vars, env_example, deploy_and_settings, external_services, credentials_keys, encrypted_columns)
          when "full"
            format_full(env_vars, env_example, deploy_and_settings, dockerfile_vars, external_services, credentials_keys, encrypted_columns, root)
          end
        end
        text_response([ text, unread_bundle_note(root) ].compact.join("\n\n"))
      end

      # Without it, an unread bundle reads as an app that declares no service gems.
      private_class_method def self.unread_bundle_note(root)
        unread = RailsAiContext::GemLock.for(root).unread_bundle or return nil

        "_Gem-based services and config gem settings not read: #{unread}._"
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
        lines.join("\n")
      end

      # Named in the answer, because a name missing from it is otherwise
      # indistinguishable from a name the app does not read.
      SCAN_NOTE = "_Scanned `app`, `config` and `lib` for `.rb`, `.rake`, `.erb` and config `.yml`, plus `config.ru`, `db/seeds` and the Ruby scripts in `bin`. " \
        "Config YAML on `sensitive_patterns` (config/database.yml) is read for the ENV names in its ERB tags only; " \
        "credentials, keys and the rest are never read._"

      private_class_method def self.format_standard(env_vars, env_example, deploy_and_settings, external_services, credentials_keys, encrypted_columns)
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
              defaults = sites.reject { |v| v[:default_unread] }.map { |v| v[:default] }.uniq
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

        lines.concat(deploy_and_settings)

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
        lines.join("\n")
      end

      # Both `standard` and `full` end with these two sections, so a wording
      # change cannot land in one detail level and miss the other.
      private_class_method def self.credentials_and_encrypted_lines(credentials_keys, encrypted_columns)
        lines = []

        if credentials_keys.any?
          lines << "## Credentials Keys (values hidden)"
          credentials_keys.each { |k| lines << "- `#{k}`" }
          lines << ""
        elsif (empty = empty_credentials_file)
          lines << "## Credentials Keys (values hidden)"
          lines << "_`#{empty}` decrypts and holds no keys._"
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

      private_class_method def self.format_full(env_vars, env_example, deploy_and_settings, dockerfile_vars, external_services, credentials_keys, encrypted_columns, root)
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
              var_details[v[:name]][:files] << { file: relative, line: v[:line], default: v[:default],
                                                  bracket: v[:bracket], default_unread: v[:default_unread] }
              var_details[v[:name]][:defaults] << v[:default] unless v[:default_unread]
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
                next "#{at} default not read" if f[:default_unread]

                case f[:default]
                when String then "#{at} default: `#{f[:default]}`"
                when COMPUTED_DEFAULT then "#{at} default computed at runtime"
                else f[:bracket] ? "#{at} nil when unset" : "#{at} no default"
                end
              }.uniq
              entry = "- `#{v[:name]}`"
              if disagree?(v[:files])
                entry += " (#{DEFAULTS_DIFFER})"
              elsif defaults.size == 1 && defaults.first.is_a?(String)
                entry += " (default: `#{defaults.first}`)"
              end
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

        lines.concat(deploy_and_settings)

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
        lines.join("\n")
      end

      private_class_method def self.scan_env_vars(root)
        Introspectors::EnvReferences.scan(root)
      end

      KAMAL_DEPLOY = "config/deploy.yml"

      private_class_method def self.kamal_lines(kamal_env, root)
        return [] unless File.file?(File.join(root, KAMAL_DEPLOY))

        destinations = Dir.glob("config/deploy.*.yml", base: root).sort
        return [] if kamal_env.empty? && destinations.empty?

        lines = [ "## Set by Kamal (`#{KAMAL_DEPLOY}`)" ]
        kamal_env.each do |v|
          scope = v[:scope] ? " (#{v[:scope]})" : ""
          lines << if v[:name].nil?
            "- a #{v[:secret] ? 'secret' : 'variable'} whose name an ERB tag sets at deploy time#{scope}"
          elsif v[:secret]
            alias_note = if v[:secret] == v[:name] then ""
            elsif RailsAiContext::ConfigYaml.marked?(v[:secret]) then " (a name an ERB tag sets)"
            else " (`#{v[:secret]}`)"
            end
            "- `#{v[:name]}` - secret, from `.kamal/secrets`#{alias_note}#{scope}"
          elsif v[:value] == :computed
            "- `#{v[:name]}` - set by ERB at deploy time#{scope}"
          elsif v[:value] == :hidden
            "- `#{v[:name]}` - value hidden#{scope}"
          else
            "- `#{v[:name]}` = `#{v[:value]}`#{scope}"
          end
        end
        destinations.each { |file| lines << "- `#{file}` merges over this per destination and is not read" }
        lines << ""
      end

      # As Kamal's Role#env merges it: top-level env, `servers.<role>.env`, then each `env.tags.<tag>`.
      private_class_method def self.scan_kamal_env(root)
        config = RailsAiContext::ConfigYaml.read(root, KAMAL_DEPLOY, label: "Kamal", marker: RailsAiContext::ConfigYaml::ERB_OUTPUT)
        return [] unless config.is_a?(Hash)

        env = config["env"].is_a?(Hash) ? config["env"] : {}
        servers = config["servers"].is_a?(Hash) ? config["servers"] : {}
        roles = servers.filter_map { |role, options| [ "role `#{role}`", options["env"] ] if options.is_a?(Hash) && options["env"].is_a?(Hash) }
        tags = env["tags"].is_a?(Hash) ? env["tags"].filter_map { |tag, tag_env| [ "tag `#{tag}`", tag_env ] if tag_env.is_a?(Hash) } : []
        [ [ nil, env ], *roles, *tags ].flat_map { |scope, scoped| kamal_env_entries(scoped, scope) }
      end

      # Kamal::Configuration::Env's shape: `clear` and `secret` keys, or a bare hash that is all clear values.
      private_class_method def self.kamal_env_entries(env, scope)
        clear = env.fetch("clear", env.key?("secret") || env.key?("tags") ? {} : env)
        clear = {} unless clear.is_a?(Hash)
        secrets = Array(env["secret"]).filter_map do |key|
          name, aliased = key.to_s.split(":", 2)
          { name: kamal_name(name), secret: aliased || name, scope: scope }.compact unless name.to_s.empty?
        end
        secrets + clear.map { |name, value| { name: kamal_name(name.to_s), value: kamal_clear_value(name.to_s, value), scope: scope }.compact }
      end

      # nil for a name an ERB tag writes, so the marker is never printed as a variable.
      private_class_method def self.kamal_name(name)
        name unless RailsAiContext::ConfigYaml.marked?(name)
      end

      SAFE_ENV_NAMES = Introspectors::EnvIntrospector::KNOWN_ENV_VARS.select { |spec| spec[:safe] }.to_set { |spec| spec[:name] }.freeze
      # A run of letters and digits this long is a key or token, whatever the variable is called;
      # a hyphen or underscore breaks the run, so a host name such as `myapp-production-db-1` shows.
      OPAQUE_TOKEN = /(?=[A-Za-z0-9+\/=]*\d)(?=[A-Za-z0-9+\/=]*[A-Za-z])[A-Za-z0-9+\/=]{16,}/
      # A UUID or a hex key split into groups is still a key once the separators go.
      GROUPED_HEX = /\A\h{16,}\z/

      # Webhook URLs and DSNs hide their secret in the path or user part, where Redaction does not look.
      private_class_method def self.kamal_clear_value(name, value)
        return :computed if RailsAiContext::ConfigYaml.marked?(value)

        text = value.to_s
        return RailsAiContext::Redaction.value(name, text) if SAFE_ENV_NAMES.include?(name)
        return :hidden if text.include?("://") || text.match?(OPAQUE_TOKEN) || text.delete("-_").match?(GROUPED_HEX) || RailsAiContext::Redaction.value(name, text) != text

        text
      end

      # Without the config gem, config/settings.yml is the app's own file and no Settings constant exists.
      private_class_method def self.scan_settings(root)
        return [] unless RailsAiContext::GemLock.for(root).present?("config")

        files = [ "config/settings.yml" ] +
          %w[settings environments].flat_map { |dir| Dir.glob(File.join(root, "config", dir, "*.yml")).sort.map { |path| path.delete_prefix("#{root}/") } }
        files.filter_map do |file|
          data = RailsAiContext::ConfigYaml.read(root, file, label: "config gem settings")
          next unless data.is_a?(Hash) && data.any?

          { file: file, keys: setting_keys(data) }
        end
      end

      private_class_method def self.setting_keys(hash, prefix = nil)
        hash.flat_map do |key, value|
          path = [ prefix, key ].compact.join(".")
          value.is_a?(Hash) && value.any? ? setting_keys(value, path) : [ path ]
        end
      end

      private_class_method def self.settings_lines(settings)
        return [] if settings.empty?

        [ "## Settings (config gem, read as `Settings.<key>`; values hidden)" ] +
          settings.map { |s| "- `#{s[:file]}`: #{s[:keys].map { |k| "`#{k}`" }.join(', ')}" } + [ "" ]
      end

      private_class_method def self.anyway_lines(configs)
        return [] if configs.empty?

        [ "## Anyway::Config classes (values hidden)" ] + configs.map do |config|
          attributes = config[:attributes].map do |a|
            notes = [ ("`#{a[:env]}`" if a[:env]), ("required" if a[:required]) ].compact
            notes.any? ? "`#{a[:name]}` (#{notes.join(', ')})" : "`#{a[:name]}`"
          end
          "- `#{config[:name]}` (`#{config[:file]}`): #{attributes.join(', ')}"
        end + [ "" ]
      end

      private_class_method def self.scan_env_example(root)
        # Only the example files - NEVER .env or .env.local
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

        declared = RailsAiContext::Introspectors::GemfileGems.names(root)
        if declared.any?
          service_gems.each do |gem_name, info|
            next unless declared.include?(gem_name)
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

      # Prefilter: the AST decides, on the files that name a client at all.
      HTTP_CLIENT_NAME = /(?:#{Regexp.union(Introspectors::Listeners::HttpClientCallListener::CLIENTS).source})\.|URI\.open/
      BARE_HOST = /\A[a-z0-9-]+(?:\.[a-z0-9-]+)*\.[a-z]{2,}\z/i

      private_class_method def self.detect_http_clients(root)
        services = []
        real_root = File.realpath(root).to_s

        %w[app config lib].each do |dir|
          scan_dir = File.join(root, dir)
          next unless Dir.exist?(scan_dir)

          safe_glob(scan_dir, "**/*.rb", real_root).each do |file|
            source = safe_read(file)
            next unless source&.match?(HTTP_CLIENT_NAME)

            relative = file.sub("#{real_root}/", "")
            calls = Introspectors::SourceIntrospector.walk_source(source, { http: Introspectors::Listeners::HttpClientCallListener })[:http]
            calls.each do |call|
              name = if call[:url]
                extract_service_name_from_url(call[:url])
              else
                call[:host].match?(BARE_HOST) && service_name_from_host(call[:host])
              end
              services << { name: name, detection: call[:client], file: relative } if name
            end
          end
        end

        services.uniq { |s| "#{s[:name]}:#{s[:file]}" }
      rescue => e
        RailsAiContext.debug_fail(e, [], label: "detect_http_clients")
      end

      private_class_method def self.extract_service_name_from_url(url)
        return nil if url.start_with?("ENV") || url.include?("#" + "{")

        begin
          host = URI.parse(url).host
          host && service_name_from_host(host)
        rescue => e
          RailsAiContext.debug_fail(e, nil, label: "extract_service_name_from_url")
        end
      end

      private_class_method def self.service_name_from_host(host)
        # An address names no service; a loopback, private or unspecified one is not external at all.
        if (ip = (IPAddr.new(host.delete("[]")) rescue nil))
          return ip.loopback? || ip.private? || ip.link_local? || ip.to_i.zero? ? nil : host
        end

        parts = host.split(".")
        return nil if parts.size < 2

        parts[-2]&.capitalize
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

      # Rails answers {} both for a file it decrypted and found empty and for
      # one it had no key to open, so only a key plus the file tells them apart.
      private_class_method def self.empty_credentials_file
        return nil if RailsAiContext.static_tier?

        creds = Rails.application&.credentials
        return nil unless creds.respond_to?(:key) && creds.respond_to?(:content_path) && creds.respond_to?(:config)
        return nil unless creds.key && creds.content_path.exist? && creds.config.empty?

        creds.content_path.to_s.delete_prefix("#{rails_app.root}/")
      rescue StandardError
        nil
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
      # A site in a sensitive file was read for its name only, so its default
      # is unknown rather than different.
      # A default read only as a name is its own unknown value beside a read one,
      # and the same unknown beside another unread one.
      private_class_method def self.disagree?(sites)
        sites.map { |v| v[:default_unread] ? :unread : (v[:bracket] || v[:default] == "nil" ? :nil_when_unset : v[:default]) }
             .uniq.size > 1
      end
    end
  end
end
