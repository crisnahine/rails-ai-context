# frozen_string_literal: true

module RailsAiContext
  module CLI
    # Runs MCP tools from the command line without requiring an MCP client.
    # Reads tool schemas at runtime - no hardcoded parameter lists.
    #
    # Usage:
    #   runner = ToolRunner.new("schema", ["--table", "users", "--detail", "full"])
    #   puts runner.run
    #
    #   runner = ToolRunner.new("schema", { table: "users", detail: "full" })
    #   puts runner.run
    class ToolRunner
      class ToolNotFoundError < StandardError; end
      class InvalidArgumentError < StandardError; end

      # The only words that read as true, and every word a boolean flag will
      # consume as its value. Kept together so the two cannot drift: a word
      # accepted here but missing from TRUTHY would silently mean false.
      TRUTHY_WORDS = %w[true 1 yes].freeze
      FALSEY_WORDS = %w[false 0 no].freeze
      BOOLEAN_WORDS = (TRUTHY_WORDS + FALSEY_WORDS).freeze

      attr_reader :tool_class, :raw_args, :json_mode, :error

      def initialize(tool_name, raw_args, json_mode: false, environment: nil)
        RunCache.around do
          @custom_tools = Server.resolve_custom_tools
          @tool_class, @retired = resolve_tool(tool_name)
        end
        @raw_args = raw_args
        @json_mode = json_mode
        @environment = environment
        @error = false
        @missing_required = false
        @refused = []
        @out_of_type = {}
        # How each param was typed, so a suggestion uses the same form.
        @flag_spellings = {}
      end

      # The answer is what the caller prints to stdout, so whatever the app's
      # code prints while the tool runs goes to stderr, as it does under
      # `serve`. Sidekiq's logger, made the first time a tool reaches it,
      # announced its Redis connection on stdout ahead of a --json envelope.
      def run
        OutputGuard.quarantine_stdout(across_exec: false) do
          Server.with_custom_tools(@custom_tools) do
            kwargs = build_kwargs
            schema = tool_schema
            validate_kwargs!(kwargs, schema)
            next extract_output(refusal_response) if @refused.any?

            response = tool_class.call(**kwargs)
            response = Tools::GetConfig.with_retired_note(response, @retired, kwargs) if @retired
            extract_output(response)
          end
        end
      end

      # The tool's help, or for a retired name its config section's.
      def help
        self.class.tool_help(tool_class, @retired)
      end

      # List all available tools with short names and descriptions.
      def self.tool_list
        lines = [ "Available tools:", "" ]
        Server.exposed_tools.each do |tool|
          short = short_name(tool.tool_name)
          full = tool.description_value.to_s
          desc = full.truncate(79, separator: " ", omission: "...")
          # A cut landing after a sentence or a dash would otherwise print
          # four dots, or a dash with nothing after it.
          desc = desc.sub(/[\s.,;:-]+\.\.\.\z/, "...") unless desc == full
          lines << "  #{short.ljust(24)} #{desc}"
        end
        lines << ""
        # Standalone installs have no rake tasks, so advertising the rake form
        # would point users at a command that does not exist; nor does an
        # engine's root, whose tasks run in its dummy app.
        case RailsAiContext::InstallMode.form
        when :tasks
          lines << "Usage: rails 'ai:tool[NAME]' param=value"
          lines << "       rails-ai-context tool NAME --param value"
          lines << "JSON envelope: rails-ai-context tool NAME --json, or JSON=1 rails 'ai:tool[NAME]'"
        else
          binary = RailsAiContext::InstallMode.tool_command("NAME")
          lines << "Usage: #{binary} --param value"
          lines << "JSON envelope: #{binary} --json"
        end
        lines.join("\n")
      end

      # Generate help for a specific tool from its input_schema. A retired
      # name gets its own section's parameters, read from rails_get_config.
      def self.tool_help(tool_class, retired = nil)
        schema = retired ? Tools::GetConfig.schema_for([ retired ]) : tool_class.input_schema_value&.to_h || {}
        properties = schema[:properties] || {}
        properties = properties.except(:section) if retired
        required = retired ? [] : schema[:required] || []
        name = retired ? retired.tool_name : tool_class.tool_name
        about = retired ? "runs the `#{retired.name}` section of rails_get_config (#{retired.summary})." : tool_class.description_value

        lines = [
          "#{name} - #{about}",
          "",
          "Usage:"
        ]
        # Standalone installs have no rake tasks; only show the rake form when
        # the gem lives in an app's Gemfile, not at an engine's root.
        form = RailsAiContext::InstallMode.form
        short = short_name(name)
        if form == :tasks
          lines << "  rails 'ai:tool[#{short}]' #{properties.keys.map { |k| "#{k}=VALUE" }.join(' ')}"
        end
        binary = form == :tasks ? "rails-ai-context tool #{short}" : RailsAiContext::InstallMode.tool_command(short, form: form)
        lines << "  #{binary} #{properties.keys.map { |k| "--#{k.to_s.tr('_', '-')} VALUE" }.join(' ')}"
        lines << ""

        if properties.any?
          lines << "Options:"
          properties.each do |name, prop|
            flag = "--#{name.to_s.tr('_', '-')}"
            type_hint = prop[:type] || "string"
            type_hint = "#{type_hint} (#{prop[:enum].join('/')})" if prop[:enum]
            req = required.include?(name.to_s) ? " [required]" : ""
            desc = prop[:description] || ""
            lines << "  #{flag.ljust(24)} #{desc} (#{type_hint})#{req}"
          end
        else
          lines << "  No parameters."
        end

        lines.join("\n")
      end

      # Derive short name: rails_get_schema → schema, rails_analyze_feature → analyze_feature
      def self.short_name(tool_name)
        tool_name.sub(/\Arails_get_/, "").sub(/\Arails_/, "")
      end

      # The full names a typed name can spell: `schema`, `get_schema` and `rails_get_schema` are one tool.
      def self.candidate_names(name)
        [ name, "rails_#{name}", "rails_get_#{name}" ]
      end

      private

      # The schema a call is checked against, as InputSchema#to_h gives it on every
      # supported mcp. rails_get_config's takes a section skip_tools turned off.
      def tool_schema
        tool_class.input_schema&.to_h || {}
      end

      # The tool a name spells and the config section a retired name stands for, loading
      # that one class and no other. A miss falls back to the full list for the suggestion.
      def direct_tool(name)
        self.class.candidate_names(name).each do |candidate|
          found = Server.served_tool(candidate)
          next unless found

          # A retired config tool name runs its section, as the MCP server does.
          section = Tools::GetConfig.retired_section(candidate)
          return section && found.equal?(section.renderer) ? [ Tools::GetConfig, section ] : [ found, nil ]
        end
        nil
      end

      # Resolve tool name: tries short → medium → full form.
      # "schema" → "rails_get_schema", "search_code" → "rails_search_code"
      def resolve_tool(name)
        direct = direct_tool(name)
        return direct if direct

        tools = Server.exposed_tools
        found = tools.find { |t| self.class.short_name(t.tool_name) == name }
        return [ found, nil ] if found

        skipped = self.class.candidate_names(name) & Server.skipped_tools
        raise ToolNotFoundError, Server.skipped_tool_message(skipped.first) if skipped.any?

        # Fuzzy suggestion
        short_names = (tools.map(&:tool_name) | Server.retired_names).map { |tool_name| self.class.short_name(tool_name) }
        suggestion = Tools::BaseTool.find_closest_match(name, short_names)
        msg = "Unknown tool '#{name}'."
        msg += " Did you mean '#{suggestion}'?" if suggestion
        # In-Gemfile, this message reaches both the CLI (`--list` works) and
        # the rake task (`--list` does not - it's a Thor-only option), so name
        # both working invocations instead of one that fails half the time.
        # Standalone installs have no rake tasks, so only name the CLI form.
        msg += case RailsAiContext::InstallMode.form
        when :tasks then "\n\nSee all tools: rails 'ai:tool' (rake) or rails-ai-context tool --list (CLI)."
        else "\n\nSee all tools: #{RailsAiContext::InstallMode.tool_command('--list')}."
        end
        raise ToolNotFoundError, msg
      end

      # Parse raw_args into keyword arguments hash.
      # Supports both hash input (rake) and array input (CLI).
      def build_kwargs
        kwargs = case raw_args
        when Hash
                   raw_args.transform_keys(&:to_sym).except(:server_context).transform_values { |value| utf8(value) }
        when Array
                   return with_environment(with_section(parse_cli_args(raw_args).except(:server_context)))
        else
                   {}
        end

        properties = (tool_schema[:properties] || {})
        kwargs.each do |key, value|
          prop = properties[key]
          next unless prop
          kwargs[key] = coerce_value(value, prop, key)
        end

        with_environment(with_section(kwargs))
      end

      def with_section(kwargs)
        @retired ? kwargs.merge(section: @retired.name) : kwargs
      end

      # `--environment` sets RAILS_ENV, so it never arrives as a tool argument; a tool that
      # declares the parameter gets it, unless an explicit `environment=` was given.
      def with_environment(kwargs)
        return kwargs if @environment.nil? || kwargs.key?(:environment)
        return kwargs unless (tool_schema[:properties] || {}).key?(:environment)
        # Only a section that reads it gets it; the others answer for RAILS_ENV.
        return kwargs if tool_class == Tools::GetConfig && !section_reads_environment?(kwargs[:section])

        kwargs.merge(environment: @environment)
      end

      def section_reads_environment?(name)
        Tools::GetConfig.section_named(name || "app")&.params&.include?(:environment)
      end

      # Parse ["--table", "users", "--detail", "full", "--app-only"] into { table: "users", ... }
      def parse_cli_args(args)
        args = args.map { |arg| utf8(arg) }
        result = {}
        i = 0
        properties = (tool_schema[:properties] || {})

        while i < args.size
          arg = args[i]

          if arg.start_with?("--no-")
            key = arg.sub("--no-", "").tr("-", "_").to_sym
            @flag_spellings[key] = arg
            type = properties.dig(key, :type)
            # Only a boolean has a false; an unknown flag passes through for the unknown-param message.
            @out_of_type[key] = arg if type && type != "boolean" && key != :detail
            result[key] = @out_of_type.key?(key) ? nil : false
            i += 1
          elsif arg.start_with?("--")
            if arg.include?("=")
              key, value = arg.sub("--", "").split("=", 2)
              key = key.tr("-", "_").to_sym
              @flag_spellings[key] = arg.split("=", 2).first
              prop = properties[key] || {}
              if prop[:type] == "array"
                # `--files=a.rb b.rb` is the same call as `--files a.rb b.rb`;
                # honouring only one of the two spellings docs/CLI.md teaches
                # left the other still dropping every file after the first.
                trailing, consumed = array_values(args, i + 1)
                result[key] = Array(coerce_value(value, prop, key)) + trailing
                i += 1 + consumed
                next
              end
              result[key] = coerce_value(value, prop, key)
            else
              key = arg.sub("--", "").tr("-", "_").to_sym
              @flag_spellings[key] = arg
              prop = properties[key] || {}

              if prop[:type] == "boolean"
                # `--flag false` is the form docs/CLI.md teaches for every
                # other param, so a boolean has to honour it too. Only an
                # explicit boolean word is consumed - anything else stays a
                # separate argument and the flag means true.
                nxt = args[i + 1]
                if nxt && BOOLEAN_WORDS.include?(nxt.downcase)
                  result[key] = coerce_value(nxt, prop)
                  i += 2
                else
                  result[key] = true
                  i += 1
                end
                next
              end

              # A bare `--files` with nothing after it is a mistake, not a
              # request for `files: true` - an array param holding a Boolean
              # reaches the tool as a type it never accepts.
              if prop[:type] == "array"
                result[key], consumed = array_values(args, i + 1)
                i += 1 + consumed
                next
              end

              value = (i + 1 < args.size) ? args[i + 1] : nil
              if value && !value.start_with?("--")
                result[key] = coerce_value(value, prop, key)
                i += 2
                next
              end

              # A value-taking flag with nothing after it would reach the tool
              # as the Boolean true, a type it never accepts. An unknown flag
              # still passes through, so the unknown-param message names it.
              raise InvalidArgumentError, missing_value_message(key, prop) if prop[:type]

              result[key] = true
              i += 1
              next
            end
            i += 1
          elsif arg.include?("=")
            # key=value style (rake)
            key, value = arg.split("=", 2)
            key = key.tr("-", "_").to_sym
            result[key] = coerce_value(value, properties[key] || {}, key)
            i += 1
          else
            # Every parameter takes a flag, so a bare word is a mistype of
            # one. Dropping it answered a different question than the one
            # asked, and said nothing about it.
            raise InvalidArgumentError, stray_argument_message(arg)
          end
        end

        result
      end

      # ARGV (here and in the rake task) carries the locale's encoding, BINARY
      # under LANG=C; MCP values are always UTF-8.
      def utf8(arg)
        return arg unless arg.is_a?(String)
        return arg if arg.encoding == Encoding::UTF_8 && arg.valid_encoding?

        if [ Encoding::UTF_8, Encoding::BINARY, Encoding::US_ASCII ].include?(arg.encoding)
          arg.dup.force_encoding(Encoding::UTF_8).scrub
        else
          arg.encode(Encoding::UTF_8, invalid: :replace, undef: :replace)
        end
      end

      # The flag a stray word was most likely meant for, among the ones
      # offered: a required param first, since a caller must supply it.
      def suggested_flag
        offered = offered_params
        return nil if offered.empty?

        required = (tool_schema[:required] || []).map(&:to_s)
        name = offered.find { |param| required.include?(param) } || offered.first
        "--#{name.tr('_', '-')}"
      end

      # A suggested param in the form the unknown one was typed: `--table`
      # after `--tabel`, `table=` after `tabel=` (the rake form).
      def spelled_like(typed, suggestion)
        typed.start_with?("--") ? "--#{suggestion.tr('_', '-')}" : "#{suggestion}="
      end

      def valid_params_line
        keys = offered_params
        keys.any? ? "Valid params: #{keys.join(', ')}" : "This tool takes no params."
      end

      # The parameters to name to the caller: the ones tools/list shows, or a retired name's own section's.
      def offered_params
        @retired ? @retired.params.map(&:to_s) : Tools::SafeCall.published_params(tool_class)
      end

      def stray_argument_message(arg)
        flag = suggested_flag
        hint = flag ? " - did you mean '#{flag} #{arg}'?" : ""
        "Unexpected argument:\n  '#{arg}' is not a flag#{hint}\n#{valid_params_line}"
      end

      def missing_value_message(key, prop)
        flag = "--#{key.to_s.tr('_', '-')}"
        expected = prop[:enum] ? "one of #{prop[:enum].join(', ')}" : "#{article(prop[:type])} #{prop[:type]} value"
        "Missing value:\n  '#{flag}' takes #{expected}\n#{valid_params_line}"
      end

      # The JSON Schema type names are a closed set, and array, integer and
      # object are the vowel-initial three.
      def article(type)
        type.to_s.start_with?("a", "e", "i", "o", "u") ? "an" : "a"
      end

      # Tokens belonging to an array flag: everything up to the next flag,
      # stopping at a rake-style `key=value` token so `--include a model=Post`
      # does not swallow the second parameter. Each token is still
      # comma-split, so the documented `a.rb,b.rb` form keeps working and
      # mixing the two spellings does not fabricate a path. The token count
      # comes back with the values because the cursor advances by tokens: a
      # comma token yields more values than it consumed.
      def array_values(args, from)
        tokens = args[from..].to_a.take_while { |a| !a.start_with?("--") && !a.include?("=") }
        [ tokens.flat_map { |a| Array(coerce_value(a, { type: "array" })) }, tokens.size ]
      end

      # Coerce a string value to its JSON Schema type. One of another type (`--limit abc`, `app_only=maybe`)
      # is recorded for validation to refuse: coerced to 0 or false it answers a question nobody asked.
      def coerce_value(raw, property_schema, key = nil)
        case property_schema[:type]
        when "integer"
          return raw.to_i if raw.is_a?(Integer) || raw.to_s.strip.match?(/\A[-+]?\d+\z/)

          @out_of_type[key] = raw if key
          nil
        when "boolean"
          return raw if raw == true || raw == false
          return TRUTHY_WORDS.include?(raw.to_s.downcase) if BOOLEAN_WORDS.include?(raw.to_s.downcase)

          @out_of_type[key] = raw if key
          nil
        when "array"
          raw.is_a?(Array) ? raw : raw.to_s.split(",").map(&:strip)
        else
          raw.to_s
        end
      end

      # Validate kwargs against the tool's input_schema.
      # For missing required params: strip empty values so the tool's own guards
      # can return a friendly response (matching MCP behavior).
      # For a value the parameter cannot take, by type or by list: refuse the call, except
      # `detail`, which falls back with a warning.
      # For unknown params: raise InvalidArgumentError with closest-match suggestion.
      def validate_kwargs!(kwargs, schema)
        properties = schema[:properties] || {}
        required = (schema[:required] || []).map(&:to_s)
        known_keys = offered_params

        # Check for unknown params and raise a helpful error with suggestions.
        # server_context is always allowed (internal MCP param).
        unknown = Tools::BaseTool.unknown_param_names(kwargs.keys, properties)
        if unknown.any?
          msgs = unknown.map do |k|
            suggestion = Tools::BaseTool.find_closest_match(k, known_keys)
            typed = @flag_spellings.fetch(k.to_sym, k.to_s)
            suggestion ? "  '#{typed}' - did you mean '#{spelled_like(typed, suggestion)}'?" : "  '#{typed}'"
          end
          raise InvalidArgumentError, "Unknown param#{unknown.size > 1 ? 's' : ''}:\n#{msgs.join("\n")}\n#{valid_params_line}"
        end

        @out_of_type.each do |key, raw|
          type = properties.dig(key, :type)
          refuse(key, raw, type == "boolean" ? "true or false" : properties.dig(key, :enum)&.join(", ") || "#{article(type)} #{type}")
          kwargs.delete(key)
        end

        # For required params with empty-string values, keep the key but set to nil
        # so the tool's own guards can return friendly "parameter is required" messages
        # (matching MCP behavior). We keep the key to avoid Ruby ArgumentError on
        # required keyword arguments. The tool's own wording is the best one, so
        # the call is only marked failed - the exit status a script reads was
        # saying success while the text said the parameter was required.
        required.each do |param|
          next unless blank?(kwargs[param.to_sym])

          kwargs[param.to_sym] = nil
          @missing_required = true
        end

        # A value outside the list answers another question, so the call is refused;
        # every `detail` level answers the same one, so that falls back.
        kwargs.each do |key, value|
          prop = properties[key]
          next unless prop&.dig(:enum)
          # A required param nobody supplied is nil here; the tool's own
          # "required" message says it better than a warning about ''.
          next if value.nil?

          # Try case-insensitive match first
          matched = prop[:enum].find { |e| e.to_s.downcase == value.to_s.downcase }
          if matched
            kwargs[key] = matched
          else
            valid = prop[:enum].join(", ")
            if key == :detail
              $stderr.puts "Warning: '#{value}' is not a valid value for #{key}. Valid: #{valid}. Using default."
              kwargs.delete(key)
            else
              refuse(key, value, valid)
            end
          end
        end
      end

      def refuse(key, value, valid)
        @refused << "**Error:** `#{value}` is not a valid `#{key}`. Valid: #{valid}"
      end

      # Through the tool's own wrapper when it has one, so the static-tier banner rides along.
      def refusal_response
        text = @refused.join("\n")
        return tool_class.text_response(text) if tool_class <= Tools::BaseTool

        MCP::Tool::Response.new([ { type: "text", text: text } ])
      end

      def blank?(value)
        return true if value.nil?
        return value.strip.empty? if value.is_a?(String)
        return value.empty? if value.respond_to?(:empty?)

        false
      end

      # Extract text from MCP::Tool::Response and record whether the tool
      # reported failure (isError), so callers can set a non-zero exit code.
      def extract_output(response)
        text = response.content.first&.dig(:text) || ""
        @error = @missing_required || @refused.any? || (response.respond_to?(:error?) && response.error?)
        if json_mode
          require "json"
          JSON.pretty_generate(tool: tool_class.tool_name, output: text, error: @error)
        else
          text
        end
      end
    end
  end
end
