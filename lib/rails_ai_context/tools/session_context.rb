# frozen_string_literal: true

module RailsAiContext
  module Tools
    class SessionContext < BaseTool
      tool_name "rails_session_context"
      description "Track what you've already queried to avoid redundant calls. " \
        "Use action:\"status\" to see what tools you've called, action:\"summary\" for a compressed recap, " \
        "action:\"reset\" to clear session, or mark:\"tool:param\" to record a query. " \
        "Helps maintain focus during long development sessions."

      input_schema(
        properties: {
          action: {
            type: "string",
            enum: %w[status summary reset],
            description: "status: list queried tools with timestamps. summary: compressed recap. reset: clear session."
          },
          mark: {
            type: "string",
            description: "Mark a tool+params as already queried (e.g., 'get_schema:users', 'get_model_details:User')."
          }
        }
      )

      guide_row(
        order: 39,
        mcp: "rails_session_context(action:\"status\")",
        cli_args: "action=status",
        summary: "Track what you've already queried, avoid redundant calls"
      )

      annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: false, open_world_hint: false)

      def self.call(action: nil, mark: nil, server_context: nil)
        unless action || mark
          return error_response("Provide `action` (status/summary/reset) or `mark` (tool:param to record).")
        end

        if mark
          tool, params = parse_mark(mark)
          known = known_tool_name(tool)
          return error_response(unknown_mark_message(tool)) unless known

          session_record(known, params)
          return text_response("Marked `#{known}` with params `#{echo_input(params)}` as queried.")
        end

        case action
        when "status"
          render_status
        when "summary"
          render_summary
        when "reset"
          current_session_reset!
          text_response("Session cleared. All query records removed.")
        else
          text_response("Unknown action: #{echo_input(action)}. Use status, summary, or reset.")
        end
      rescue => e
        text_response("Session context error: #{e.message}")
      end

      class << self
        private

        def parse_mark(mark_string)
          parts = mark_string.split(":", 2)
          tool = parts[0]&.strip
          params = parts[1]&.strip || ""
          [ tool, params ]
        end

        # The tool a mark names, spelled the way the server names it, so a
        # mark and the call it stands for are one entry. Takes the short forms
        # the CLI takes (`schema`, `get_schema`). An empty or unknown name
        # recorded a query nothing could ever have answered.
        def known_tool_name(name)
          return nil if name.to_s.empty?

          tools = RailsAiContext::CLI::ToolRunner.available_tools.map(&:tool_name)
          [ name, "rails_#{name}", "rails_get_#{name}" ].find { |candidate| tools.include?(candidate) }
        end

        def unknown_mark_message(name)
          usage = "Pass `tool:params`, e.g. `get_schema:users`."
          return "`mark` names no tool. #{usage}" if name.to_s.empty?

          short_names = RailsAiContext::CLI::ToolRunner.available_tools.map { |t| RailsAiContext::CLI::ToolRunner.short_name(t.tool_name) }
          suggestion = find_closest_match(name, short_names)
          "Unknown tool '#{echo_input(name)}' in `mark`.#{" Did you mean '#{suggestion}'?" if suggestion} #{usage}"
        end

        def cli_note
          "_Note: CLI (`#{RailsAiContext::InstallMode.command(:tool)}`) runs each call in a separate process - " \
            "session tracking only works via MCP._"
        end

        def render_status
          queries = session_queries
          if queries.empty?
            return text_response("# Session Context\n\nNo queries recorded yet. Tools will be tracked as you use them.\n\n_Use `mark:\"tool:params\"` to manually record a query._\n#{cli_note}")
          end

          lines = [ "# Session Context (#{count_phrase(queries.size, "query")})", "" ]
          lines << "| Tool | Params | When |"
          lines << "|------|--------|------|"

          queries.sort_by { |q| q[:timestamp] }.each do |q|
            ago = time_ago(q[:last_timestamp] || q[:timestamp])
            params_str = q[:params].is_a?(Hash) ? q[:params].map { |k, v| "#{k}:#{v}" }.join(", ") : q[:params].to_s
            params_display = params_str.empty? ? "-" : params_str.truncate(40)
            count = q[:call_count] || 1
            count_display = count > 1 ? " (#{count}x)" : ""
            lines << "| `#{q[:tool]}`#{count_display} | #{params_display} | #{ago} |"
          end

          lines << ""
          lines << "_Use `action:\"reset\"` to clear, or `action:\"summary\"` for a compressed recap._"
          lines << cli_note
          text_response(lines.join("\n"))
        end

        def render_summary
          queries = session_queries
          if queries.empty?
            return text_response("No queries recorded yet.")
          end

          total_calls = queries.sum { |q| q[:call_count] || 1 }
          unique_tools = queries.map { |q| q[:tool] }.uniq.size
          lines = [ "# Session Summary", "" ]
          lines << "You have made #{count_phrase(total_calls, "tool call")} across #{count_phrase(unique_tools, "unique tool")} in this session:"
          lines << ""

          # Group by tool name, summing actual call counts
          by_tool = queries.group_by { |q| q[:tool] }
          by_tool.each do |tool, entries|
            total_calls = entries.sum { |e| e[:call_count] || 1 }
            params_list = entries.map { |c|
              p = c[:params]
              p.is_a?(Hash) ? p.map { |k, v| "#{k}:#{v}" }.join(", ") : p.to_s
            }.reject(&:empty?)

            if params_list.any?
              lines << "- **#{tool}** (#{total_calls}x): #{params_list.uniq.join('; ')}"
            else
              lines << "- **#{tool}** (#{total_calls}x)"
            end
          end

          lines << ""
          lines << "_Avoid re-querying these. Use `action:\"status\"` for timestamps._"
          text_response(lines.join("\n"))
        end

        def time_ago(iso_timestamp)
          diff = Time.now - Time.parse(iso_timestamp)
          if diff < 60
            "#{diff.to_i}s ago"
          elsif diff < 3600
            "#{(diff / 60).to_i}m ago"
          else
            "#{(diff / 3600).to_i}h ago"
          end
        rescue => e
          RailsAiContext.debug_fail(e, iso_timestamp, label: "time_ago")
        end
      end
    end
  end
end
