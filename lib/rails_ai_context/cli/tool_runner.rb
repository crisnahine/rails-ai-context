# frozen_string_literal: true

module RailsAiContext
  module CLI
    # Runs MCP tools from the command line without requiring an MCP client.
    # Reads tool schemas at runtime — no hardcoded parameter lists.
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

      attr_reader :tool_class, :raw_args, :json_mode

      def initialize(tool_name, raw_args, json_mode: false)
        @tool_class = resolve_tool(tool_name)
        @raw_args = raw_args
        @json_mode = json_mode
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
          desc = tool.description_value.to_s[0..79]
          lines << "  #{short.ljust(24)} #{desc}"
        end
        lines << ""
        lines << "Usage: rails 'ai:tool[NAME]' param=value"
        lines << "       rails-ai-context tool NAME --param value"
        lines.join("\n")
      end

      # Filtered tool list respecting skip_tools config.
      def self.available_tools
        skip = RailsAiContext.configuration.skip_tools
        tools = Server.builtin_tools
        tools += RailsAiContext.configuration.custom_tools
        return tools if skip.empty?
        tools.reject { |t| skip.include?(t.tool_name) }
      end

      # Generate help for a specific tool from its input_schema.
      def self.tool_help(tool_class)
        schema = tool_class.input_schema_value&.schema || {}
        properties = schema[:properties] || {}
        required = schema[:required] || []

        lines = [
          "#{tool_class.tool_name} — #{tool_class.description_value}",
          "",
          "Usage:",
          "  rails 'ai:tool[#{short_name(tool_class.tool_name)}]' #{properties.keys.map { |k| "#{k}=VALUE" }.join(' ')}",
          "  rails-ai-context tool #{short_name(tool_class.tool_name)} #{properties.keys.map { |k| "--#{k.to_s.tr('_', '-')} VALUE" }.join(' ')}",
          ""
        ]

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

      def tool_schema
        tool_class.input_schema_value&.schema || {}
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
        msg += "\n\nRun with --list to see all available tools."
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
          kwargs[key] = coerce_value(value, prop)
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
              result[key] = coerce_value(value, properties[key] || {})
            else
              key = arg.sub("--", "").tr("-", "_").to_sym
              prop = properties[key] || {}

              if prop[:type] == "boolean"
                result[key] = true
                i += 1
                next
              end

              value = (i + 1 < args.size) ? args[i + 1] : nil
              if value && !value.start_with?("--")
                result[key] = coerce_value(value, prop)
                i += 2
                next
              else
                result[key] = true
                i += 1
                next
              end
            end
            i += 1
          elsif arg.include?("=")
            # key=value style (rake)
            key, value = arg.split("=", 2)
            key = key.tr("-", "_").to_sym
            result[key] = coerce_value(value, properties[key] || {})
            i += 1
          else
            i += 1
          end
        end

        result
      end

      # Coerce a string value to the type specified in the JSON Schema property.
      def coerce_value(raw, property_schema)
        case property_schema[:type]
        when "integer"
          raw.to_i
        when "boolean"
          %w[true 1 yes].include?(raw.to_s.downcase)
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
        unknown = kwargs.keys.map(&:to_s) - known_keys - [ "server_context" ]
        if unknown.any?
          msgs = unknown.map do |k|
            suggestion = Tools::BaseTool.find_closest_match(k, known_keys)
            suggestion ? "  '#{k}' — did you mean '#{suggestion}='?" : "  '#{k}'"
          end
          valid_str = known_keys.any? ? "Valid params: #{known_keys.join(', ')}" : "This tool takes no params."
          raise InvalidArgumentError, "Unknown param#{unknown.size > 1 ? 's' : ''}:\n#{msgs.join("\n")}\n#{valid_str}"
        end

        # For required params with empty-string values, keep the key but set to nil
        # so the tool's own guards can return friendly "parameter is required" messages
        # (matching MCP behavior). We keep the key to avoid Ruby ArgumentError on
        # required keyword arguments.
        required.each do |param|
          if kwargs.key?(param.to_sym) && kwargs[param.to_sym].to_s.strip == ""
            kwargs[param.to_sym] = nil
          elsif !kwargs.key?(param.to_sym)
            kwargs[param.to_sym] = nil
          end
        end

        # Check enum constraints — downcase before comparing for case-insensitive match.
        # If invalid, strip the param so the tool uses its default behavior.
        kwargs.each do |key, value|
          prop = properties[key]
          next unless prop&.dig(:enum)

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

      # Extract text from MCP::Tool::Response.
      def extract_output(response)
        text = response.content.first&.dig(:text) || ""
        if json_mode
          require "json"
          JSON.pretty_generate(tool: tool_class.tool_name, output: text)
        else
          text
        end
      end
    end
  end
end
