# frozen_string_literal: true

require "open3"

module RailsAiContext
  module Tools
    class SearchCode < BaseTool
      tool_name "rails_search_code"
      description "Search the Rails codebase with smart modes. " \
        "Use match_type:\"trace\" to see where a method is defined, who calls it, and what it calls — in one call. " \
        "Use match_type:\"definition\" for definitions only, \"call\" for call sites only, \"class\" for class/module definitions. " \
        "Requires pattern:\"method_name\". Narrow with path:\"app/models\" and file_type:\"rb\"."

      def self.max_results_cap
        RailsAiContext.configuration.max_search_results
      end

      input_schema(
        properties: {
          pattern: {
            type: "string",
            description: "Search pattern (regex supported)."
          },
          path: {
            type: "string",
            description: "Subdirectory to search in (e.g. 'app/models', 'config'). Default: entire app."
          },
          file_type: {
            type: "string",
            description: "Filter by file extension (e.g. 'rb', 'js', 'erb'). Default: all files."
          },
          match_type: {
            type: "string",
            enum: %w[any definition class call trace],
            description: "any: all matches (default). definition: `def` lines only. class: `class/module` lines. call: call sites only (excludes definitions). trace: FULL PICTURE — shows definition + source code + all callers + what it calls internally."
          },
          exact_match: {
            type: "boolean",
            description: "Match whole words only (wraps pattern in \\b word boundaries). Default: false."
          },
          exclude_tests: {
            type: "boolean",
            description: "Exclude test/spec files from results. Default: false."
          },
          group_by_file: {
            type: "boolean",
            description: "Group results by file with match counts. Default: false."
          },
          offset: {
            type: "integer",
            description: "Skip this many results for pagination. Default: 0."
          },
          limit: {
            type: "integer",
            description: "Max results to return. Default: auto-sized based on total matches."
          },
          context_lines: {
            type: "integer",
            description: "Lines of context before and after each match (like grep -C). Default: 2, max: 5."
          }
        },
        required: [ "pattern" ]
      )

      annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true, open_world_hint: false)

      def self.call(pattern:, path: nil, file_type: nil, match_type: "any", exact_match: false, exclude_tests: false, group_by_file: false, offset: 0, limit: nil, context_lines: 2, server_context: nil) # rubocop:disable Metrics
        root = Rails.root.to_s
        original_pattern = pattern

        # Reject empty or whitespace-only patterns
        if pattern.nil? || pattern.strip.empty?
          return text_response("Pattern is required. Provide a search term or regex.")
        end

        # Trace mode — the game changer: full method picture in one call
        if match_type == "trace"
          return trace_method(pattern.strip, root, path, exclude_tests)
        end

        # Apply exact_match word boundaries
        pattern = "\\b#{pattern}\\b" if exact_match

        # Validate match_type
        valid_match_types = %w[any definition class call trace]
        unless valid_match_types.include?(match_type)
          return text_response("Unknown match_type: '#{match_type}'. Valid values: #{valid_match_types.join(', ')}")
        end

        # Apply match_type filter to pattern
        search_pattern = case match_type
        when "definition"
          cleaned = pattern.sub(/\A\s*def\s+/, "")
          "^\\s*def\\s+(self\\.)?#{Regexp.escape(cleaned)}"
        when "class"
          cleaned = pattern.sub(/\A\s*(class|module)\s+/, "")
          "^\\s*(class|module)\\s+\\w*#{Regexp.escape(cleaned)}"
        when "call"
          pattern
        else
          pattern
        end

        # Validate regex syntax early
        begin
          Regexp.new(search_pattern, timeout: 1)
        rescue RegexpError => e
          return text_response("Invalid regex pattern: #{e.message}")
        end

        # Validate file_type to prevent injection
        if file_type && !file_type.match?(/\A[a-zA-Z0-9]+\z/)
          return text_response("Invalid file_type: must contain only alphanumeric characters.")
        end

        context_lines = [ [ context_lines.to_i, 0 ].max, 5 ].min
        offset = [ offset.to_i, 0 ].max

        search_path = path ? File.join(root, path) : root

        # Path traversal protection
        unless Dir.exist?(search_path)
          top_dirs = Dir.glob(File.join(root, "*")).select { |f| File.directory?(f) }.map { |f| File.basename(f) }.sort
          return text_response("Path not found: #{path}. Top-level directories: #{top_dirs.first(15).join(', ')}")
        end

        begin
          real_search = File.realpath(search_path)
          real_root = File.realpath(root)
          unless real_search.start_with?(real_root)
            return text_response("Path not allowed: #{path}")
          end
        rescue Errno::ENOENT
          return text_response("Path not found: #{path}")
        end

        # Fetch all results (capped at 200 for safety)
        all_results = if ripgrep_available?
          search_with_ripgrep(search_pattern, search_path, file_type, max_results_cap, root, context_lines, exclude_tests: exclude_tests)
        else
          search_with_ruby(search_pattern, search_path, file_type, max_results_cap, root, exclude_tests: exclude_tests)
        end

        # Filter out definitions for match_type:"call"
        all_results.reject! { |r| r[:content].match?(/\A\s*def\s/) } if match_type == "call"

        if all_results.empty?
          return text_response("No results found for '#{original_pattern}' in #{path || 'app'}.")
        end

        # Smart default limit: <10 → all, 10-100 → half, >100 → 100
        total = all_results.size
        default_limit = if total <= 10 then total
        elsif total <= 100 then (total / 2.0).ceil
        else 100
        end

        page = paginate(all_results, offset: offset, limit: limit, default_limit: [ default_limit, 1 ].max)
        paginated = page[:items]

        if paginated.empty? && total > 0
          return text_response(page[:hint])
        end

        pagination = page[:hint].empty? ? "" : "\n#{page[:hint]}"

        showing = paginated.size.to_s
        header = "# Search: `#{original_pattern}`\n**#{total} total results**#{" in #{path}" if path}, showing #{showing}\n"

        if group_by_file
          text_response(header + "\n" + format_grouped(paginated) + pagination)
        else
          output = paginated.map { |r| "#{r[:file]}:#{r[:line_number]}: #{r[:content].strip}" }.join("\n")
          text_response("#{header}\n```\n#{output}\n```#{pagination}")
        end
      end

      private_class_method def self.ripgrep_available?
        return @rg_available unless @rg_available.nil?
        @rg_available = system("which rg > /dev/null 2>&1")
      end

      private_class_method def self.search_with_ripgrep(pattern, search_path, file_type, max_results, root, ctx_lines = 0, exclude_tests: false)
        cmd = [ "rg", "--no-heading", "--line-number", "--sort=path", "--max-count", max_results.to_s ]
        if ctx_lines > 0
          cmd.push("-C", ctx_lines.to_s)
          # Use colon separator for context lines so parse_rg_output handles them correctly
          # (default '-' separator is ambiguous with filenames containing dashes)
          cmd.push("--field-context-separator", ":")
        end

        RailsAiContext.configuration.excluded_paths.each do |p|
          cmd << "--glob=!#{p}"
        end

        # Block sensitive files from search results
        RailsAiContext.configuration.sensitive_patterns.each do |p|
          cmd << "--glob=!#{p}"
        end

        # Exclude generated AI context files (not source code)
        # Claude
        cmd << "--glob=!CLAUDE.md"
        cmd << "--glob=!.claude/"
        # Cursor
        cmd << "--glob=!.cursor/"
        cmd << "--glob=!.cursorrules"
        # GitHub Copilot
        cmd << "--glob=!.github/copilot-instructions.md"
        cmd << "--glob=!.github/instructions/"
        # OpenCode
        cmd << "--glob=!AGENTS.md"
        cmd << "--glob=!**/AGENTS.md"
        # JSON export
        cmd << "--glob=!.ai-context.json"

        # Exclude test/spec directories if requested
        if exclude_tests
          cmd << "--glob=!test/"
          cmd << "--glob=!spec/"
          cmd << "--glob=!features/"
        end

        if file_type
          cmd.push("--type-add", "custom:*.#{file_type}", "--type", "custom")
        end

        cmd << "--" # Prevent pattern from being parsed as flags
        cmd << pattern
        cmd << search_path

        sensitive = RailsAiContext.configuration.sensitive_patterns
        output, _status = Open3.capture2(*cmd, err: File::NULL)
        parse_rg_output(output, root)
          .reject { |r| sensitive_file?(r[:file], sensitive) }
          .first(max_results)
      rescue => e
        [ { file: "error", line_number: 0, content: e.message } ]
      end

      private_class_method def self.search_with_ruby(pattern, search_path, file_type, max_results, root, exclude_tests: false)
        results = []
        begin
          regex = Regexp.new(pattern, Regexp::IGNORECASE, timeout: 2)
        rescue RegexpError => e
          return [ { file: "error", line_number: 0, content: "Invalid regex: #{e.message}" } ]
        end
        extensions = RailsAiContext.configuration.search_extensions.join(",")
        glob = file_type ? "**/*.#{file_type}" : "**/*.{#{extensions}}"
        excluded = RailsAiContext.configuration.excluded_paths
        sensitive = RailsAiContext.configuration.sensitive_patterns
        test_dirs = %w[test/ spec/ features/]
        ai_context_files = %w[CLAUDE.md AGENTS.md .claude/ .cursor/ .cursorrules .github/copilot-instructions.md .github/instructions/ .ai-context.json]

        Dir.glob(File.join(search_path, glob)).each do |file|
          relative = file.sub("#{root}/", "")
          next if excluded.any? { |ex| relative.start_with?(ex) }
          next if sensitive_file?(relative, sensitive)
          next if ai_context_files.any? { |p| relative.start_with?(p) || relative == p }
          next if exclude_tests && test_dirs.any? { |td| relative.start_with?(td) }

          (RailsAiContext::SafeFile.read(file) || "").lines.each_with_index do |line, idx|
            if line.match?(regex)
              results << { file: relative, line_number: idx + 1, content: line }
              return results if results.size >= max_results
            end
          end
        rescue => _e
          next # Skip binary/unreadable files
        end

        results
      end

      private_class_method def self.sensitive_file?(relative_path, patterns)
        basename = File.basename(relative_path)
        flags = File::FNM_DOTMATCH | File::FNM_CASEFOLD
        patterns.any? do |pattern|
          File.fnmatch(pattern, relative_path, flags) ||
            File.fnmatch(pattern, basename, flags)
        end
      end

      # Group results by file for cleaner output
      private_class_method def self.format_grouped(results)
        grouped = results.group_by { |r| r[:file] }
        lines = []
        grouped.each do |file, matches|
          lines << "## #{file} (#{matches.size} matches)"
          lines << "```"
          matches.each { |r| lines << "#{r[:line_number]}: #{r[:content].strip}" }
          lines << "```"
          lines << ""
        end
        lines.join("\n")
      end

      private_class_method def self.parse_rg_output(output, root)
        output.lines.filter_map do |line|
          next if line.strip == "--" # Skip group separators from -C context output
          match = line.match(/^(.+?):(\d+):(.*)$/)
          next unless match

          {
            file: match[1].sub("#{root}/", ""),
            line_number: match[2].to_i,
            content: match[3]
          }
        end
      end

      # ── Trace Mode — the game changer ──────────────────────────────
      # Shows definition + source + callers + internal calls in one response

      private_class_method def self.trace_method(method_name, root, path, exclude_tests) # rubocop:disable Metrics
        # Clean input: strip "def ", "self.", parens
        cleaned = method_name.sub(/\A\s*def\s+/, "").sub(/\Aself\./, "").sub(/\(.*/, "").strip
        return text_response("Provide a method name to trace.") if cleaned.empty?

        search_path = path ? File.join(root, path) : root
        lines = [ "# Trace: `#{cleaned}`", "" ]

        # 1. Find the definition (no \b after ? or ! since they ARE word boundaries)
        def_pattern = "^\\s*def\\s+(self\\.)?#{Regexp.escape(cleaned)}"
        def_pattern += "\\b" unless cleaned.end_with?("?") || cleaned.end_with?("!")
        def_results = quick_search(def_pattern, search_path, root, 10, exclude_tests)

        if def_results.any?
          lines << "## Definition"
          def_results.each do |r|
            # Class/module context
            class_context = extract_class_context(File.join(root, r[:file]), r[:line_number])
            lines << "**#{r[:file]}:#{r[:line_number]}**#{class_context ? " in `#{class_context}`" : ""}"

            # Full method body
            body = extract_method_body(File.join(root, r[:file]), r[:line_number])
            if body
              lines << "```ruby"
              lines << body
              lines << "```"

              # What does this method call?
              internal_calls = body.scan(/\b([a-z_]\w*[!?]?)(?:\s*[\(])/).flatten.uniq
              internal_calls += body.scan(/\b([A-Z]\w+(?:::\w+)*)\.(new|call|perform_later|perform_async|find|where|create)/).map { |c| "#{c[0]}.#{c[1]}" }
              internal_calls.reject! { |c| %w[if else elsif unless return end def class module do begin rescue ensure raise puts print].include?(c) }
              internal_calls.reject! { |c| c == cleaned }

              if internal_calls.any?
                lines << "" << "## Calls internally"
                internal_calls.first(15).each { |c| lines << "- `#{c}`" }
              end
            end

            # Sibling methods in the same file
            siblings = extract_sibling_methods(File.join(root, r[:file]), r[:line_number], cleaned)
            if siblings.any?
              lines << "" << "## Sibling methods (same file)"
              siblings.first(10).each { |s| lines << "- `#{s}`" }
            end

            lines << ""
          end
        else
          lines << "_No definition found for `def #{cleaned}`_"
          lines << ""
        end

        # 2. Find all callers (everywhere the method is referenced, excluding the def line)
        call_pattern = if cleaned.end_with?("?") || cleaned.end_with?("!")
          "#{Regexp.escape(cleaned)}"
        else
          "\\b#{Regexp.escape(cleaned)}\\b"
        end
        call_results = quick_search(call_pattern, search_path, root, max_results_cap, exclude_tests)
        callers = call_results.reject { |r| r[:content].match?(/\A\s*def\s/) }

        # Exclude the definition file+line to avoid self-reference
        def_locations = def_results.map { |r| "#{r[:file]}:#{r[:line_number]}" }.to_set
        callers.reject! { |r| def_locations.include?("#{r[:file]}:#{r[:line_number]}") }

        if callers.any?
          # Separate app code from tests
          app_callers = callers.reject { |r| r[:file].match?(/\A(test|spec)\//) }
          test_callers = callers.select { |r| r[:file].match?(/\A(test|spec)\//) }

          if app_callers.any?
            lines << "## Called from (#{app_callers.size} sites)"
            grouped = app_callers.group_by { |r| r[:file] }
            grouped.each do |file, matches|
              category = case file
              when /controller/i then "Controller"
              when /model/i then "Model"
              when /view|\.erb/i then "View"
              when /job/i then "Job"
              when /service/i then "Service"
              when /\.js$|\.ts$/i then "JavaScript"
              else "Other"
              end

              # Route chain for controller callers
              route_hint = ""
              if category == "Controller" && file.match?(/app\/controllers\/(.+)_controller\.rb/)
                ctrl_path = $1
                route_actions = extract_controller_actions_from_matches(matches)
                routes = find_routes_for_controller(ctrl_path, route_actions, root)
                route_hint = " → #{routes}" if routes
              end

              lines << "### #{file} (#{category})#{route_hint}"
              matches.first(5).each do |r|
                lines << "  #{r[:line_number]}: #{r[:content].strip}"
              end
              lines << "  _(#{matches.size - 5} more)_" if matches.size > 5
            end
          end

          if test_callers.any?
            lines << "" << "## Tested by (#{test_callers.size} references)"
            test_callers.group_by { |r| r[:file] }.each do |file, matches|
              lines << "- `#{file}` (#{matches.size} references)"
            end
          end
        else
          lines << "## Called from"
          lines << "_No call sites found (method may be unused or called dynamically)_"
        end

        text_response(lines.join("\n"))
      rescue => e
        text_response("Trace error: #{e.message}")
      end

      # Fast ripgrep search for trace mode (no formatting, just results)
      private_class_method def self.quick_search(pattern, search_path, root, limit, exclude_tests)
        if ripgrep_available?
          search_with_ripgrep(pattern, search_path, nil, limit, root, 0, exclude_tests: exclude_tests)
        else
          search_with_ruby(pattern, search_path, nil, limit, root, exclude_tests: exclude_tests)
        end
      end

      # Extract class/module context for a line
      private_class_method def self.extract_class_context(file_path, line_num)
        return nil unless File.exist?(file_path)
        lines = (RailsAiContext::SafeFile.read(file_path) || "").lines
        # Walk backwards from the method to find the enclosing class/module
        (line_num - 2).downto(0) do |i|
          if lines[i]&.match?(/\A\s*(class|module)\s+(\S+)/)
            return lines[i].strip.sub(/\s*<.*/, "")
          end
        end
        nil
      rescue => e
        $stderr.puts "[rails-ai-context] extract_class_context failed: #{e.message}" if ENV["DEBUG"]
        nil
      end

      # Extract sibling methods in the same file (other public methods)
      private_class_method def self.extract_sibling_methods(file_path, def_line, exclude_method)
        return [] unless File.exist?(file_path)
        return [] if File.size(file_path) > RailsAiContext.configuration.max_file_size
        source = RailsAiContext::SafeFile.read(file_path)
        return [] unless source
        methods = []
        in_private = false
        source.each_line do |line|
          in_private = true if line.match?(/\A\s*private\s*$/)
          next if in_private
          if (m = line.match(/\A\s*def\s+((?:self\.)?\w+[?!]?)/))
            name = m[1]
            methods << name unless name == exclude_method || name.start_with?("initialize")
          end
        end
        methods
      rescue => e
        $stderr.puts "[rails-ai-context] extract_sibling_methods failed: #{e.message}" if ENV["DEBUG"]
        []
      end

      # Extract which action a controller caller is in
      private_class_method def self.extract_controller_actions_from_matches(matches)
        actions = []
        matches.each do |m|
          # Match standard RESTful action names from the content
          if (match = m[:content].match(/\b(index|show|new|create|edit|update|destroy)\b/))
            actions << match[1]
          end
        end
        actions.uniq.first(3)
      end

      # Find routes for a controller
      private_class_method def self.find_routes_for_controller(ctrl_path, _actions, _root)
        routes = cached_context[:routes]
        return nil unless routes
        by_controller = routes[:by_controller] || {}
        ctrl_routes = by_controller[ctrl_path]
        return nil unless ctrl_routes&.any?
        # Show the first 2 routes as hints
        ctrl_routes.first(2).map { |r| "`#{r[:verb]} #{r[:path]}`" }.join(", ")
      rescue => e
        $stderr.puts "[rails-ai-context] find_routes_for_controller failed: #{e.message}" if ENV["DEBUG"]
        nil
      end

      # Extract a method body from a file given the def line number
      private_class_method def self.extract_method_body(file_path, def_line)
        return nil unless File.exist?(file_path)
        return nil if File.size(file_path) > RailsAiContext.configuration.max_file_size

        source_lines = (RailsAiContext::SafeFile.read(file_path) || "").lines
        start_idx = def_line - 1
        return nil if start_idx >= source_lines.size

        def_indent = source_lines[start_idx][/\A\s*/].length
        result = [ source_lines[start_idx].rstrip ]

        source_lines[(start_idx + 1)..].each do |line|
          result << line.rstrip
          break if line.match?(/\A\s{#{def_indent}}end\b/)
        end

        result.join("\n")
      rescue => e
        $stderr.puts "[rails-ai-context] extract_method_body failed: #{e.message}" if ENV["DEBUG"]
        nil
      end
    end
  end
end
