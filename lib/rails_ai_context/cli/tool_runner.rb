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

      def initialize(tool_name, raw_args, json_mode: false)
        @tool_class = resolve_tool(tool_name)
        @raw_args = raw_args
        @json_mode = json_mode
        @error = false
        @missing_required = false
        @out_of_type = {}
      end

      def run
        kwargs = build_kwargs
        schema = tool_schema
        validate_kwargs!(kwargs, schema)
        response = tool_class.call(**kwargs)
        extract_output(response)
      end

      # List all available tools with short names and descriptions.
      def self.tool_list
        lines = [ "Available tools:", "" ]
        available_tools.each do |tool|
          short = short_name(tool.tool_name)
          desc = truncate_at_word(tool.description_value.to_s, 79)
          lines << "  #{short.ljust(24)} #{desc}"
        end
        lines << ""
        # Standalone installs have no rake tasks, so advertising the rake form
        # would point users at a command that does not exist.
        if RailsAiContext::InstallMode.standalone?
          lines << "Usage: rails-ai-context tool NAME --param value"
          lines << "JSON envelope: rails-ai-context tool NAME --json"
        else
          lines << "Usage: rails 'ai:tool[NAME]' param=value"
          lines << "       rails-ai-context tool NAME --param value"
          lines << "JSON envelope: rails-ai-context tool NAME --json, or JSON=1 rails 'ai:tool[NAME]'"
        end
        lines.join("\n")
      end

      # Truncate at the last whole word within `limit` chars and append "..."
      # so descriptions never cut off mid-word. Returns `text` unchanged when
      # it already fits.
      def self.truncate_at_word(text, limit)
        return text if text.length <= limit

        cut = text[0...limit]
        boundary = cut.rindex(" ")
        cut = cut[0...boundary] if boundary
        "#{cut}..."
      end

      # Filtered tool list respecting skip_tools config.
      def self.available_tools
        skip = RailsAiContext.configuration.skip_tools
        tools = Server.builtin_tools
        tools += Server.resolve_custom_tools
        return tools if skip.empty?
        tools.reject { |t| skip.include?(t.tool_name) }
      end

      # Generate help for a specific tool from its input_schema.
      def self.tool_help(tool_class)
        schema = tool_class.input_schema_value&.to_h || {}
        properties = schema[:properties] || {}
        required = schema[:required] || []

        lines = [
          "#{tool_class.tool_name} - #{tool_class.description_value}",
          "",
          "Usage:"
        ]
        # Standalone installs have no rake tasks; only show the rake form when
        # the gem lives in the app's Gemfile.
        unless RailsAiContext::InstallMode.standalone?
          lines << "  rails 'ai:tool[#{short_name(tool_class.tool_name)}]' #{properties.keys.map { |k| "#{k}=VALUE" }.join(' ')}"
        end
        lines << "  rails-ai-context tool #{short_name(tool_class.tool_name)} #{properties.keys.map { |k| "--#{k.to_s.tr('_', '-')} VALUE" }.join(' ')}"
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

      private

      # InputSchema#to_h is stable across the mcp gem's >= 0.13, < 2.0 range;
      # the older #schema accessor was removed in mcp 0.20.0. to_h returns a
      # symbol-keyed hash carrying the :properties and :required this runner
      # reads (newer mcp also merges a benign :$schema key we ignore).
      def tool_schema
        tool_class.input_schema_value&.to_h || {}
      end

      # Resolve tool name: tries short → medium → full form.
      # "schema" → "rails_get_schema", "search_code" → "rails_search_code"
      def resolve_tool(name)
        tools = self.class.available_tools
        tool_names = tools.map(&:tool_name)

        # Try exact match
        found = tools.find { |t| t.tool_name == name }
        return found if found

        # Try rails_ prefix
        found = tools.find { |t| t.tool_name == "rails_#{name}" }
        return found if found

        # Try rails_get_ prefix
        found = tools.find { |t| t.tool_name == "rails_get_#{name}" }
        return found if found

        # Try case-insensitive short name match
        found = tools.find { |t| self.class.short_name(t.tool_name) == name }
        return found if found

        # Fuzzy suggestion
        short_names = tools.map { |t| self.class.short_name(t.tool_name) }
        suggestion = Tools::BaseTool.find_closest_match(name, short_names)
        msg = "Unknown tool '#{name}'."
        msg += " Did you mean '#{suggestion}'?" if suggestion
        # In-Gemfile, this message reaches both the CLI (`--list` works) and
        # the rake task (`--list` does not - it's a Thor-only option), so name
        # both working invocations instead of one that fails half the time.
        # Standalone installs have no rake tasks, so only name the CLI form.
        msg += if RailsAiContext::InstallMode.standalone?
          "\n\nSee all tools: rails-ai-context tool --list."
        else
          "\n\nSee all tools: rails 'ai:tool' (rake) or rails-ai-context tool --list (CLI)."
        end
        raise ToolNotFoundError, msg
      end

      # Parse raw_args into keyword arguments hash.
      # Supports both hash input (rake) and array input (CLI).
      def build_kwargs
        kwargs = case raw_args
        when Hash
                   raw_args.transform_keys(&:to_sym).except(:server_context)
        when Array
                   return parse_cli_args(raw_args).except(:server_context)
        else
                   {}
        end

        properties = (tool_schema[:properties] || {})
        kwargs.each do |key, value|
          prop = properties[key]
          next unless prop
          kwargs[key] = coerce_value(value, prop, key)
        end

        kwargs
      end

      # Parse ["--table", "users", "--detail", "full", "--app-only"] into { table: "users", ... }
      def parse_cli_args(args)
        result = {}
        i = 0
        properties = (tool_schema[:properties] || {})

        while i < args.size
          arg = args[i]

          if arg.start_with?("--no-")
            key = arg.sub("--no-", "").tr("-", "_").to_sym
            result[key] = false
            i += 1
          elsif arg.start_with?("--")
            if arg.include?("=")
              key, value = arg.sub("--", "").split("=", 2)
              key = key.tr("-", "_").to_sym
              prop = properties[key] || {}
              if prop[:type] == "array"
                # `--files=a.rb b.rb` is the same call as `--files a.rb b.rb`;
                # honouring only one of the two spellings docs/CLI.md teaches
                # left the other still dropping every file after the first.
                trailing = collect_array_values(args, i + 1)
                result[key] = Array(coerce_value(value, prop, key)) + trailing
                i += 1 + values_consumed(args, i + 1)
                next
              end
              result[key] = coerce_value(value, prop, key)
            else
              key = arg.sub("--", "").tr("-", "_").to_sym
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

              if prop[:type] == "array"
                values = collect_array_values(args, i + 1)
                unless values.empty?
                  result[key] = values
                  i += 1 + values_consumed(args, i + 1)
                  next
                end
              end

              # A bare `--files` with nothing after it is a mistake, not a
              # request for `files: true` - an array param holding a Boolean
              # reaches the tool as a type it never accepts.
              if prop[:type] == "array"
                result[key] = []
                i += 1
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

      # The flag a stray word was most likely meant for: a required param
      # first, since that is the one a caller must supply.
      def suggested_flag
        schema = tool_schema
        properties = (schema[:properties] || {})
        return nil if properties.empty?

        required = (schema[:required] || []).map(&:to_s)
        name = properties.keys.find { |k| required.include?(k.to_s) } || properties.keys.first
        "--#{name.to_s.tr('_', '-')}"
      end

      def valid_params_line
        keys = (tool_schema[:properties] || {}).keys.map(&:to_s)
        keys.any? ? "Valid params: #{keys.join(', ')}" : "This tool takes no params."
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
      # mixing the two spellings does not fabricate a path.
      def collect_array_values(args, from)
        args[from..].to_a
            .take_while { |a| !a.start_with?("--") && !a.include?("=") }
            .flat_map { |a| Array(coerce_value(a, { type: "array" })) }
      end

      def values_consumed(args, from)
        args[from..].to_a.take_while { |a| !a.start_with?("--") && !a.include?("=") }.size
      end

      # Coerce a string value to the type specified in the JSON Schema property.
      def coerce_value(raw, property_schema, key = nil)
        case property_schema[:type]
        when "integer"
          # `--limit abc` is 0 through `to_i`, which answers a question
          # nobody asked. Record it instead, so validation refuses it the way
          # an out-of-enum value is refused.
          if raw.is_a?(Integer) || raw.to_s.strip.match?(/\A[-+]?\d+\z/)
            raw.to_i
          else
            @out_of_type[key] = raw if key
            nil
          end
        when "boolean"
          TRUTHY_WORDS.include?(raw.to_s.downcase)
        when "array"
          raw.is_a?(Array) ? raw : raw.to_s.split(",").map(&:strip)
        else
          raw.to_s
        end
      end

      # Validate kwargs against the tool's input_schema.
      # For missing required params: strip empty values so the tool's own guards
      # can return a friendly response (matching MCP behavior).
      # For invalid enums: strip the bad value and let the tool use its default.
      # For unknown params: raise InvalidArgumentError with closest-match suggestion.
      def validate_kwargs!(kwargs, schema)
        properties = schema[:properties] || {}
        required = (schema[:required] || []).map(&:to_s)
        known_keys = properties.keys.map(&:to_s)

        # Check for unknown params and raise a helpful error with suggestions.
        # server_context is always allowed (internal MCP param).
        unknown = Tools::BaseTool.unknown_param_names(kwargs.keys, properties)
        if unknown.any?
          msgs = unknown.map do |k|
            suggestion = Tools::BaseTool.find_closest_match(k, known_keys)
            suggestion ? "  '#{k}' - did you mean '#{suggestion}='?" : "  '#{k}'"
          end
          raise InvalidArgumentError, "Unknown param#{unknown.size > 1 ? 's' : ''}:\n#{msgs.join("\n")}\n#{valid_params_line}"
        end

        # A value the schema's type cannot hold is dropped with a warning, the
        # same treatment an out-of-enum value gets, so the tool applies its own
        # default rather than the zero `to_i` would invent.
        @out_of_type.each do |key, raw|
          prop = properties[key] || {}
          $stderr.puts "Warning: '#{raw}' is not a valid value for #{key}. Expected #{prop[:type]}. Using default."
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

        # Check enum constraints - downcase before comparing for case-insensitive match.
        # If invalid, strip the param so the tool uses its default behavior.
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
            $stderr.puts "Warning: '#{value}' is not a valid value for #{key}. Valid: #{prop[:enum].join(', ')}. Using default."
            kwargs.delete(key)
          end
        end
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
        @error = @missing_required || (response.respond_to?(:error?) && response.error?)
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
