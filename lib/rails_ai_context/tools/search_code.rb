# frozen_string_literal: true

require "open3"

module RailsAiContext
  module Tools
    class SearchCode < BaseTool
      # Per-pattern Regexp timeout (a ReDoS guard) is Ruby 3.2+. Ruby 3.1 has
      # no per-match timeout, so the pattern is built without one there.
      REGEXP_TIMEOUT_SUPPORTED = Regexp.respond_to?(:timeout)
      # Named once so a rescue clause does not raise NameError on 3.1, where no match can time out.
      REGEXP_TIMEOUT_ERROR = defined?(Regexp::TimeoutError) ? Regexp::TimeoutError : Class.new(StandardError)

      # ripgrep's own field separators, so the parse is exact rather than two
      # ambiguous regexes tried in order: a match line whose content reads
      # `\t12\tsomething` is a context row to the ambiguous one, and vanishes
      # from the count. Neither character appears in a path or a line number.
      CONTEXT_FIELD_SEPARATOR = "\t"

      # ripgrep reads a file in 64 KiB blocks and calls it binary on a NUL in
      # the first one.
      BINARY_PROBE_BYTES = 64 * 1024

      TEST_DIRS = %w[test/ spec/ features/].freeze
      MATCH_FIELD_SEPARATOR = "\x1f"
      # A comment line by the file's own syntax. `#{` and ` * ` are Ruby code;
      # `#id` is a selector in a stylesheet and an element in Haml or Slim.
      HASH_COMMENT = /\A\s*(?:#(?!\{)|<%#)/
      JS_COMMENT_OPEN = %r{\A\s*(?://|/\*)}
      JS_COMMENT = Regexp.union(JS_COMMENT_OPEN, /\A\s*\*\s/)
      CSS_NOT_A_CALL = %r{\A\s*(?:/\*|\*\s|#)}
      STYLESHEET_LINE = Regexp.union(CSS_NOT_A_CALL, %r{\A\s*//})
      # A def behind a modifier (`private def x`, `ruby2_keywords def x`) and
      # one on a receiver (`def self.x`, `def Widget.x`) are definitions too.
      DEF_HEAD = "^\\s*(?:[a-z_]\\w*\\s+)*def\\s+(?:(?:self|[A-Z]\\w*(?:::[A-Z]\\w*)*)\\.)?"
      DEF_LINE = /\A\s*(?:[a-z_]\w*\s+)*def\s/
      # A method or constant name, receiver or namespace and all, or one of
      # Ruby's operator method names.
      PLAIN_NAME = %r{\A(?:(?:self|[A-Z]\w*(?:::[A-Z]\w*)*)\.)?(?:(?:::)?[A-Za-z_]\w*(?:::[A-Za-z_]\w*)*[?!=]?|\[\]=?|[-+]@|\*\*|<=>|===?|[=!]~|!=|<<|>>|[<>]=|[-+*/%<>&|^~!`])\z}
      # Constant forms that define a class without the keyword.
      CLASS_BUILDERS = "(?:::)?(?:Data\\.define|Struct\\.new|Class\\.new|Module\\.new)\\b"
      NOT_A_CALL_LINE = {
        ".erb" => Regexp.union(HASH_COMMENT, JS_COMMENT_OPEN),
        ".haml" => %r{\A\s*(?:-#|/)},
        ".slim" => %r{\A\s*/},
        ".css" => CSS_NOT_A_CALL
      }.merge(%w[.scss .sass .less].to_h { |ext| [ ext, STYLESHEET_LINE ] })
       .merge(%w[.js .jsx .mjs .cjs .ts .tsx .mts .cts .vue .svelte].to_h { |ext| [ ext, JS_COMMENT ] }).freeze

      tool_name "rails_search_code"
      description "Search the Rails codebase with smart modes. " \
        "Use match_type:\"trace\" to see where a method is defined, who calls it, and what it calls - in one call. " \
        "Use match_type:\"definition\" for definitions only, \"call\" for call sites only, \"class\" for class/module definitions. " \
        "Requires pattern:\"method_name\". Narrow with path:\"app/models\" and file_type:\"rb\"."

      def self.max_results_cap
        RailsAiContext.configuration.max_search_results
      end

      input_schema(
        properties: {
          pattern: {
            type: "string",
            description: "Search pattern (regex supported). For definition and class, a plain method or constant name matches literally (`valid?`), anything else as a regex (`generate_.*`)."
          },
          path: {
            type: "string",
            description: "Subdirectory or file to search (e.g. 'app/models', 'config/routes.rb'). Default: entire app."
          },
          file_type: {
            type: "string",
            description: "Filter by file extension (e.g. 'rb', 'js', 'erb'). Default: all files."
          },
          match_type: {
            type: "string",
            enum: %w[any definition class call trace],
            description: "any: all matches (default). definition: `def` lines whose method name contains the pattern. class: `class/module` lines whose name contains it. call: call sites only (excludes definitions). trace: FULL PICTURE - shows definition + source code + all callers + what it calls internally."
          },
          exact_match: {
            type: "boolean",
            description: "Match the pattern literally, whole-word where its edges are word characters. `def reblog?` will not match `def reblog`. Default: false."
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
            description: "Skip this many emitted lines for pagination. Default: 0."
          },
          limit: {
            type: "integer",
            description: "Max lines to return. Default: auto-sized so the page holds a useful number of matches. A limit too small for one match and its context still returns that match."
          },
          context_lines: {
            type: "integer",
            description: "Lines of context before and after each match (like grep -C). Default: 2, max: 5."
          }
        },
        required: [ "pattern" ]
      )

      guide_row(
        order: 3,
        mcp: "rails_search_code(pattern:\"X\", match_type:\"trace\")",
        cli_args: "pattern=X match_type=trace",
        summary: "Search + trace: definition, source, callers, test coverage. Also: `match_type:\"any\"` for regex search"
      )

      annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true, open_world_hint: false)

      def self.call(pattern:, path: nil, file_type: nil, match_type: "any", exact_match: false, exclude_tests: false, group_by_file: false, offset: 0, limit: nil, context_lines: 2, server_context: nil)
        root = rails_app.root.to_s
        original_pattern = pattern

        # Reject empty or whitespace-only patterns
        if pattern.nil? || pattern.strip.empty?
          return text_response("Pattern is required. Provide a search term or regex.")
        end

        # Trace mode: definition + source + callers + internal calls in one response
        if match_type == "trace"
          return trace_method(pattern.strip, root, path, exclude_tests)
        end

        # Validate match_type
        valid_match_types = %w[any definition class call trace]
        unless valid_match_types.include?(match_type)
          return text_response("Unknown match_type: '#{match_type}'. Valid values: #{valid_match_types.join(', ')}")
        end

        # Apply match_type filter to pattern (exact_match word boundaries applied per-type)
        search_pattern = case match_type
        when "definition"
          cleaned = pattern.sub(/\A\s*def\s+/, "")
          if exact_match
            # `def\s+` already anchors the left edge, so only a trailing boundary.
            "#{DEF_HEAD}#{literal(cleaned)}#{RailsAiContext::MethodName.definition_end(cleaned)}"
          else
            # Anywhere in the name, as `class` takes a prefix: `slug` finds
            # `def generate_slug` as well as `def slug_source`.
            "#{DEF_HEAD}\\w*#{name_source(cleaned)}"
          end
        when "class"
          cleaned = pattern.sub(/\A\s*(class|module)\s+/, "")
          name = "(?:\\w+::)*\\w*#{exact_match ? literal(cleaned) : name_source(cleaned)}"
          # `\w*` stays unbounded so a CamelCase prefix still resolves.
          tail = exact_match ? trailing_boundary(cleaned) : "\\w*"
          "^\\s*(?:(?:class|module)\\s+(?:::)?#{name}#{exact_match ? tail : ""}|#{name}#{tail}\\s*=\\s*#{CLASS_BUILDERS})"
        when "call"
          exact_match ? method_call_pattern(pattern) : pattern
        else
          exact_match ? exact_pattern(pattern) : pattern
        end

        # Validate regex syntax early
        begin
          build_regexp(search_pattern, timeout: 1)
        rescue RegexpError => e
          return text_response("Invalid regex pattern: #{e.message}")
        end

        # Validate file_type to prevent injection
        if file_type && !file_type.match?(/\A[a-zA-Z0-9]+\z/)
          return text_response("Invalid file_type: must contain only alphanumeric characters.")
        end

        context_lines = [ [ context_lines.to_i, 0 ].max, 5 ].min
        offset = [ offset.to_i, 0 ].max

        # Before the join, which would turn an absolute path into a subpath of
        # the root and leave it looking merely absent.
        return error_response("Path not allowed: #{path}") if path && RailsAiContext::SafePath.traversal?(path)

        search_path = path ? File.join(root, path) : root
        return error_response("Path not allowed: #{path}") if path && sensitive_file?(path)

        # A symlink under the root can still resolve outside it; that check is
        # on the realpath below.
        unless File.exist?(search_path)
          top_dirs = Dir.glob(File.join(root, "*")).select { |f| File.directory?(f) }.map { |f| File.basename(f) }.sort
          return text_response("Path not found: #{echo_input(path)}. Top-level directories: #{top_dirs.first(15).join(', ')}")
        end

        begin
          real_root = File.realpath(root)
          real_search = File.realpath(search_path)
        rescue Errno::ENOENT, Errno::EACCES, Errno::ELOOP, Errno::ENAMETOOLONG
          return text_response("Path not found: #{echo_input(path)}")
        end
        return error_response("Path not allowed: #{path}") unless RailsAiContext::SafePath.contained?(real_search, real_root)
        # A file named as the path is read whatever it is linked to.
        return error_response("Path not allowed: #{path}") if File.file?(real_search) && sensitive_file?(real_search.delete_prefix("#{real_root}/"))

        # The cap counts context lines too, so one below the first match's
        # leading context cut the match itself and the answer read "No results
        # found". It always holds that much.
        line_cap = [ max_results_cap, context_lines + 1 ].max
        # One row past the cap, so a cut list is knowable rather than silent.
        fetch_limit = line_cap + 1
        fetched, search_error = if ripgrep_available?
          search_with_ripgrep(search_pattern, search_path, file_type, fetch_limit, root, context_lines, exclude_tests: exclude_tests)
        else
          search_with_ruby(search_pattern, search_path, file_type, fetch_limit, root, context_lines, exclude_tests: exclude_tests)
        end
        all_results, truncated = cap_results(fetched, line_cap)

        # A definition or comment line stays as context, never as a call site.
        if match_type == "call"
          call_regex = build_regexp(search_pattern, timeout: 1)
          all_results.map! { |r| match_row?(r) && not_a_call_site?(r, call_regex) ? r.merge(match: false) : r }
        end
        all_results = confirmed_rows(all_results, root, build_regexp(search_pattern, timeout: 1), context_lines)

        if all_results.empty?
          # The lines past a cut were never read, so they may still match.
          unread = truncated ? " in the first #{count_phrase(line_cap, 'line')} scanned (max_search_results); more lines remain" : ""
          return empty_response("No results found for '#{echo_input(original_pattern)}' in #{path ? echo_input(path) : 'app'}#{unread}.")
        end

        # A non-empty row list whose flags all went missing still found
        # something, so the count falls back to rows rather than saying zero.
        unflagged = match_count(all_results).zero?
        match_total = unflagged ? all_results.size : match_count(all_results)

        # Smart default limit: <10 → all, 10-100 → half, >100 → 100. Sized in
        # matches, then read back as a row index so `offset` stays row-based.
        budget = if match_total <= 10 then match_total
        elsif match_total <= 100 then (match_total / 2.0).ceil
        else 100
        end
        match_rows = all_results.each_index.select { |i| match_row?(all_results[i]) }
        default_limit = budget < match_rows.size ? match_rows[budget] : all_results.size

        page = paginate(all_results, offset: offset, limit: limit, default_limit: [ default_limit, 1 ].max,
                        noun: "line", truncated: truncated)
        paginated = page[:items]

        if paginated.empty?
          return text_response(page[:hint])
        end

        # A limit smaller than one match's context block lands inside it; a page
        # size is never an answer of nothing, so the page moves to the next match.
        shown = unflagged ? paginated.size : match_count(paginated)
        moved_to_match = false
        if shown.zero?
          next_match = match_rows.find { |i| i >= offset }
          return empty_response("No matches at offset #{offset}. Total: #{capped_match_phrase(match_total, truncated)}.") unless next_match

          page = paginate(all_results, offset: next_match, limit: paginated.size,
                          default_limit: paginated.size, noun: "line", truncated: truncated)
          paginated = page[:items]
          shown = match_count(paginated)
          moved_to_match = true
        end

        pagination = page[:hint].empty? ? "" : "\n#{page[:hint]}"

        # When context lines are interleaved with matches, prefix matches with
        # '>' and context with a space so they stay distinguishable. Pure-match
        # output (context_lines: 0, Ruby fallback) keeps the plain format.
        mixed = paginated.any? { |r| !match_row?(r) }
        with_context = mixed ? " (#{count_phrase(paginated.size, 'line')} with context)" : ""
        header = "# Search: `#{original_pattern}`\n" \
          "**#{capped_match_phrase(match_total, truncated)}#{scanned_note(truncated, line_cap)}**#{" in #{path}" if path}, " \
          "showing #{shown}#{with_context}\n"
        header += "`>` = match line\n" if mixed
        header += "_The limit held only context lines, so this page starts at the next match._\n" if moved_to_match
        header += "_The search reported an error and may have skipped files._\n" if search_error

        if group_by_file
          text_response(header + "\n" + format_grouped(paginated, mixed, all_results) + pagination)
        else
          output = paginated.map { |r|
            "#{line_marker(r, mixed)}#{r[:file]}:#{r[:line_number]}: #{redacted(r)}"
          }.join("\n")
          text_response("#{header}\n```\n#{output}\n```#{pagination}")
        end
      end

      # A literal, whole-word pattern: the user's text is regex source
      # otherwise, so `def reblog?` would match `def reblog` too.
      private_class_method def self.exact_pattern(pattern)
        "#{leading_boundary(pattern)}#{literal(pattern)}#{trailing_boundary(pattern)}"
      end

      private_class_method def self.method_call_pattern(name)
        "#{leading_boundary(name)}#{literal(name)}#{RailsAiContext::MethodName.call_end(name)}"
      end

      # Regexp.escape writes a space as `\ `, which ripgrep 13 rejects as an
      # unknown escape; a bare space means the same to both engines.
      private_class_method def self.literal(text)
        Regexp.escape(text).gsub("\\ ", " ")
      end

      # A definition or class search reads a plain name literally, so `valid?`
      # is not `vali` and an optional `d`, and any other pattern as the regex
      # the schema promises: `\w+Job`, `generate_.*`.
      private_class_method def self.name_source(text)
        text.match?(PLAIN_NAME) ? literal(text) : "(?:#{text})"
      end

      # "> " for match lines, "  " for context lines; empty when the result
      # set has no context lines to distinguish from.
      private_class_method def self.line_marker(result, mixed)
        return "" unless mixed
        match_row?(result) ? "> " : "  "
      end

      # Build a Regexp, applying the ReDoS timeout only on runtimes that
      # support it (Ruby 3.2+). Keeps a single construction path for both the
      # syntax-validation probe and the actual Ruby-fallback search.
      private_class_method def self.build_regexp(pattern, options = nil, timeout:)
        if REGEXP_TIMEOUT_SUPPORTED
          Regexp.new(pattern, options, timeout: timeout)
        else
          Regexp.new(pattern, options)
        end
      end

      # A trailing slash marks a directory, the shape ripgrep wants; the Ruby fallback chomps it.
      private_class_method def self.ai_context_paths
        Install::AiTool.all.flat_map { |t|
          t.context_paths + [ t.mcp_config[:path], t.owned_dir && "#{t.owned_dir}/" ]
        }.compact.uniq + %w[.ai-context.json]
      end

      # ripgrep's own glob semantics for that list: an entry with a slash is a
      # path under the root, one without is a basename at any depth.
      private_class_method def self.ai_context_file?(paths, relative)
        paths.any? do |p|
          if p.include?("/")
            under = p.chomp("/")
            relative == under || relative.start_with?("#{under}/")
          else
            File.basename(relative) == p
          end
        end
      end

      private_class_method def self.ripgrep_available?
        return @rg_available unless @rg_available.nil?
        @rg_available = system("which rg > /dev/null 2>&1")
      end

      private_class_method def self.search_with_ripgrep(pattern, search_path, file_type, max_results, root, ctx_lines = 0, exclude_tests: false)
        cmd = [ "rg", "--no-heading", "--with-filename", "--line-number", "--sort=path", "--max-count", max_results.to_s ]
        if ctx_lines > 0
          cmd.push("-C", ctx_lines.to_s)
          cmd.push("--field-context-separator", CONTEXT_FIELD_SEPARATOR)
          cmd.push("--field-match-separator", MATCH_FIELD_SEPARATOR)
        end

        RailsAiContext.configuration.excluded_paths.each do |p|
          cmd << "--glob=!#{p}"
        end

        ai_context_paths.each do |p|
          cmd << "--glob=!#{p}"
        end

        TEST_DIRS.each { |dir| cmd << "--glob=!#{dir}" } if exclude_tests

        if file_type
          cmd.push("--type-add", "custom:*.#{file_type}", "--type", "custom")
        end
        # `search_extensions` is deliberately NOT applied here. Turning it into
        # a positive glob list makes ripgrep agree with the Ruby fallback and
        # costs the reach that makes the tool useful: `gem "devise"` in a
        # Gemfile, a TODO in a .md, a task in a Rakefile all stop being
        # findable, because none of those names carry a listed extension. The
        # fallback keeps the list because scanning every file in Ruby is the
        # expensive path; ripgrep does not need the help.

        cmd << "--" # Prevent pattern from being parsed as flags
        cmd << pattern
        cmd << search_path

        output, err, status = Open3.capture3(*cmd)

        # rg exits 1 for "no matches" and 2 for any error, including one it
        # recovered from - an unreadable file in the tree - and it still
        # prints every match it found. An rg too old for a flag prints
        # nothing, so an empty result from a failed run is the one worth
        # rerunning; a full one is kept and the answer says an error was hit.
        failed = !(status.success? || status.exitstatus == 1) && rg_error_outside_sensitive?(err, root)
        if failed && output.empty?
          return search_with_ruby(pattern, search_path, file_type, max_results, root, ctx_lines, exclude_tests: exclude_tests)
        end

        # SafePath, not an rg glob, drops sensitive files: a glob cannot exempt a placeholder.
        rows = parse_rg_output(output, root)
          .reject { |r| sensitive_file?(r[:file]) }
          .first(max_results)
        [ rows, failed ]
      rescue => e
        [ [ { file: "error", line_number: 0, content: e.message } ], false ]
      end

      # rg opens sensitive files too, and one it cannot read is not an error
      # the answer reports. A line that names no path counts as an error.
      private_class_method def self.rg_error_outside_sensitive?(err, root)
        lines = err.to_s.scrub.lines.map(&:chomp).reject(&:empty?)
        return true if lines.empty?

        lines.any? do |line|
          path = line.delete_prefix("rg: ")[/\A(.+?): [^:]*\(os error \d+\)\z/, 1]
          path.nil? || !sensitive_file?(path.delete_prefix("#{root}/"))
        end
      end

      private_class_method def self.search_with_ruby(pattern, search_path, file_type, max_results, root, ctx_lines = 0, exclude_tests: false)
        results = []
        search_error = false
        begin
          # Case-sensitive, as ripgrep is by default.
          regex = build_regexp(pattern, nil, timeout: 2)
        rescue RegexpError => e
          return [ [ { file: "error", line_number: 0, content: "Invalid regex: #{e.message}" } ], false ]
        end
        # ripgrep searches a file it is named whatever its type or ignore files say.
        if File.file?(search_path)
          relative = File.realpath(search_path).delete_prefix("#{File.realpath(root)}/")
          scan_file(File.realpath(search_path), relative, regex, ctx_lines, max_results, results)
          return [ results, search_error ]
        end
        return [ results, search_error ] unless File.directory?(search_path)

        # Every file ripgrep searches, unless the app narrowed the fallback
        # with search_extensions.
        extensions = file_type ? [ file_type ] : RailsAiContext.configuration.search_extensions&.map(&:to_s)
        # Read as ripgrep reads its `--glob=!` globs: `docs` at any depth, and
        # `log` never reaching `logo/`.
        skipped = RailsAiContext.configuration.excluded_paths + (exclude_tests ? TEST_DIRS : [])
        skip_rules = RailsAiContext::GitIgnore.parse(skipped.join("\n"))
        skip = ->(relative, dir) { RailsAiContext::GitIgnore.verdict(skip_rules, relative, dir: dir) == :ignore }
        ai_context = ai_context_paths

        # ripgrep's walk and ignore files, so both backends search the same
        # files, gitignored secrets excluded.
        RailsAiContext::GitIgnore.for_tree(root).each_file(File.realpath(search_path), skip: skip) do |file, relative|
          next if extensions && extensions.none? { |ext| file.end_with?(".#{ext}") }
          next if sensitive_file?(relative) || ai_context_file?(ai_context, relative)
          return [ results, search_error ] if scan_file(file, relative, regex, ctx_lines, max_results, results)
        rescue => _e
          search_error = true
          next # Skip a file this process cannot read or scan
        end

        [ results, search_error ]
      end

      # One file's rows, as ripgrep's -C and --max-count give them: at most
      # max_results matches, each with its context, overlapping context once.
      # A binary file (ripgrep's test, on the first block) gives none. True
      # when the rows reached the cap.
      private_class_method def self.scan_file(file, relative, regex, ctx_lines, max_results, results)
        return false if File.open(file, "rb") { |io| io.read(BINARY_PROBE_BYTES) }.to_s.include?("\0")

        lines = (RailsAiContext::SafeFile.read(file) || "").lines
        hits = lines.each_index.select { |i| lines[i].delete_suffix("\n").match?(regex) }.first(max_results)
        hit = hits.to_h { |i| [ i, true ] }
        shown = hits.flat_map { |i| ([ i - ctx_lines, 0 ].max..[ i + ctx_lines, lines.size - 1 ].min).to_a }.uniq.sort
        shown.each do |i|
          results << { file: relative, line_number: i + 1, content: lines[i], match: hit.key?(i) }
          return true if results.size >= max_results
        end
        false
      end


      # Rows are matches plus context lines; only the flagged ones are matches.
      # Rows are fetched one past the cap so a cut list is knowable.
      private_class_method def self.cap_results(rows, cap = max_results_cap)
        truncated = rows.size > cap
        [ truncated ? rows.first(cap) : rows, truncated ]
      end

      # The cap is on emitted lines, so a cut list means the count beside it
      # covers only the lines the search got to read.
      private_class_method def self.scanned_note(truncated, cap = max_results_cap)
        truncated ? " - first #{count_phrase(cap, 'line')} scanned" : ""
      end

      private_class_method def self.capped_match_phrase(total, truncated)
        phrase = count_phrase(total, "match")
        truncated ? floor_phrase(phrase) : phrase
      end

      # Rows are lines read off disk, so they pass through Redaction. Each file is redacted whole,
      # so a PEM key's body is filtered on every row it shows on.
      private_class_method def self.redact_rows(rows, root)
        files = {}
        rows.map do |row|
          lines = files.fetch(row[:file]) do
            source = RailsAiContext::SafeFile.read(File.join(root, row[:file]))
            files[row[:file]] = source && RailsAiContext::Redaction.redact_source_lines(source.scrub.lines.map(&:chomp), path: row[:file])
          end
          text = lines && lines[row[:line_number] - 1]
          row.merge(content: text || RailsAiContext::Redaction.redact_source_line(row[:content].to_s.chomp, path: row[:file]))
        end
      end

      # Rows redacted, and a match only a filtered value held turned into a context row: the pattern
      # runs on the raw file, so a hit there would confirm what the secret starts with. Context rows
      # stay only beside a real hit, so a right guess shows what a wrong one does.
      private_class_method def self.confirmed_rows(rows, root, regex, ctx_lines)
        redacted_rows = redact_rows(rows, root)
        kept = begin
          rows.zip(redacted_rows).map do |raw, row|
            hidden = match_row?(row) && raw[:content].to_s.chomp.match?(regex) && !row[:content].match?(regex)
            hidden ? row.merge(match: false) : row
          end
        rescue REGEXP_TIMEOUT_ERROR
          redacted_rows
        end
        hits = kept.select { |r| match_row?(r) }.group_by { |r| r[:file] }
        kept.select { |r| match_row?(r) || hits.fetch(r[:file], []).any? { |h| (h[:line_number] - r[:line_number]).abs <= ctx_lines } }
      end

      private_class_method def self.redacted(row)
        row[:content].strip
      end

      private_class_method def self.match_row?(row)
        row[:match] != false
      end

      # A definition or a comment line names a method without calling it,
      # except in the body of an endless def (`def call = sign(payload)`).
      private_class_method def self.not_a_call_site?(row, call_regex)
        content = row[:content].to_s
        return !endless_body(content).match?(call_regex) if content.match?(DEF_LINE)

        ext = File.extname(row[:file].to_s)
        # A live ERB tag runs whatever comment surrounds it.
        return false if ext == ".erb" && content.match?(/<%(?!#)/)

        content.match?(NOT_A_CALL_LINE.fetch(ext, HASH_COMMENT))
      end

      # The expression after `=` in a one-line endless def, "" for any other def line.
      private_class_method def self.endless_body(line)
        node = first_def(RailsAiContext::AstCache.parse_string(line.strip).value)
        node&.equal_loc && node.body ? node.body.slice : ""
      rescue StandardError
        ""
      end

      private_class_method def self.first_def(node)
        return node if node.is_a?(Prism::DefNode)

        node.compact_child_nodes.each do |child|
          found = first_def(child)
          return found if found
        end
        nil
      end

      private_class_method def self.match_count(rows)
        rows.count { |r| match_row?(r) }
      end

      # Group results by file for cleaner output. The file's heading counts the
      # whole result set, not the page, so a per-file label is not a page count.
      private_class_method def self.format_grouped(results, mixed = false, all_results = results)
        file_totals = all_results.group_by { |r| r[:file] }.transform_values { |rows| match_count(rows) }
        grouped = results.group_by { |r| r[:file] }
        lines = []
        grouped.each do |file, matches|
          shown = match_count(matches)
          total = file_totals.fetch(file, shown)
          heading = shown < total ? "#{count_phrase(total, "match")}, #{shown} shown" : count_phrase(shown, "match")
          lines << "## #{file} (#{heading})"
          lines << "```"
          matches.each { |r| lines << "#{line_marker(r, mixed)}#{r[:line_number]}: #{redacted(r)}" }
          lines << "```"
          lines << ""
        end
        lines.join("\n")
      end

      # Each row carries a :match flag the renderers and the header count read.
      # With context on, both kinds arrive under their own separator; without
      # it there are no context rows and match lines keep ripgrep's default.
      private_class_method def self.parse_rg_output(output, root)
        # ripgrep prints raw bytes; an invalid UTF-8 line must not raise.
        output.scrub.lines.filter_map do |line|
          next if line.strip == "--" # Skip group separators from -C context output

          if (m = line.match(/^(.+?)#{Regexp.escape(MATCH_FIELD_SEPARATOR)}(\d+)#{Regexp.escape(MATCH_FIELD_SEPARATOR)}(.*)$/o))
            { file: m[1].sub("#{root}/", ""), line_number: m[2].to_i, content: m[3], match: true }
          elsif (m = line.match(/^([^\t]+)#{Regexp.escape(CONTEXT_FIELD_SEPARATOR)}(\d+)#{Regexp.escape(CONTEXT_FIELD_SEPARATOR)}(.*)$/o))
            { file: m[1].sub("#{root}/", ""), line_number: m[2].to_i, content: m[3], match: false }
          elsif (m = line.match(/^(.+?):(\d+):(.*)$/))
            { file: m[1].sub("#{root}/", ""), line_number: m[2].to_i, content: m[3], match: true }
          end
        end
      end

      # ── Trace Mode ─────────────────────────────────────────────────
      # Shows definition + source + callers + internal calls in one response

      private_class_method def self.trace_method(method_name, root, path, exclude_tests)
        # Clean input: strip "def ", "self.", parens
        cleaned = method_name.sub(/\A\s*def\s+/, "").sub(/\Aself\./, "").sub(/\(.*/, "").strip
        return text_response("Provide a method name to trace.") if cleaned.empty?

        search_path = path ? File.join(root, path) : root
        lines = [ "# Trace: `#{cleaned}`", "" ]

        # 1. Find the definition: a `def`, else the `scope :name` that
        # defines the class method a model's scope is.
        def_pattern = "#{DEF_HEAD}#{literal(cleaned)}#{RailsAiContext::MethodName.definition_end(cleaned)}"
        def_results, = quick_search(def_pattern, search_path, root, 10, exclude_tests)
        scope = def_results.empty?
        def_results, = quick_search(scope_pattern(cleaned), search_path, root, 10, exclude_tests) if scope

        if def_results.any?
          lines << "## Definition"
          def_results.each do |r|
            # Class/module context
            class_context = extract_class_context(File.join(root, r[:file]), r[:line_number])
            lines << "**#{r[:file]}:#{r[:line_number]}**#{class_context ? " in `#{class_context}`" : ""}"

            # Full method body, or the whole scope declaration
            body = if scope
              extract_scope_source(File.join(root, r[:file]), r[:line_number], cleaned)
            else
              extract_method_body(File.join(root, r[:file]), r[:line_number])
            end
            if body
              lines << "```ruby"
              lines << RailsAiContext::Redaction.redact_source_lines(body.lines.map(&:chomp), path: r[:file]).join("\n")
              lines << "```"

              # What does this method call? Read off the AST: the paren regex
              # this replaced saw only `foo(...)`, so a body of paren-less
              # predicate calls reported nothing at all.
              # `private def x` is the modifier's line, and the modifier is no call the method makes.
              def_source = body.sub(/\A\s*(?:[a-z_]\w*\s+)*(?=def\s)/, "")
              internal_calls = internal_calls_in(def_source)
              internal_calls += Introspectors::SourceCalls.calls(def_source)
              internal_calls.uniq!
              internal_calls.reject! { |c| c == cleaned }
              # The scope macro and the lambda holding its body are no calls the scope makes.
              internal_calls -= SCOPE_WRAPPERS if scope

              if internal_calls.any?
                lines << "" << "## Calls internally"
                internal_calls.first(15).each { |c| lines << "- `#{c}`" }
              end
            end

            # Sibling methods in the same file
            siblings = extract_sibling_methods(File.join(root, r[:file]), cleaned)
            if siblings.any?
              lines << "" << "## Sibling methods (same file)"
              siblings.first(10).each { |s| lines << "- `#{s}`" }
            end

            lines << ""
          end
        else
          lines << "_No definition found for `def #{cleaned}` or `scope :#{cleaned}`_"
          lines << ""
        end

        # 2. Find all callers (everywhere the method is referenced, excluding the def line)
        call_pattern = method_call_pattern(cleaned)
        call_rows, = quick_search(call_pattern, search_path, root, max_results_cap + 1, exclude_tests)
        call_results, call_truncated = cap_results(call_rows)
        call_regex = build_regexp(call_pattern, timeout: 1)
        callers = call_results.reject { |r| not_a_call_site?(r, call_regex) }

        # Exclude the definition file+line to avoid self-reference
        def_locations = def_results.map { |r| "#{r[:file]}:#{r[:line_number]}" }.to_set
        callers.reject! { |r| def_locations.include?("#{r[:file]}:#{r[:line_number]}") }

        if callers.any?
          # Separate app code from tests
          app_callers = callers.reject { |r| r[:file].match?(/\A(test|spec)\//) }
          test_callers = callers.select { |r| r[:file].match?(/\A(test|spec)\//) }

          if app_callers.any?
            lines << "## Called from (#{count_phrase(app_callers.size, "site")})"
            # Every read of the shared cache deep-copies the whole payload, so
            # the route hints read it once for the whole group.
            ctx = cached_context
            grouped = app_callers.group_by { |r| r[:file] }
            grouped.each do |file, matches|
              # Directory before word: `app/services/models/...` is a
              # service, whatever the rest of the path says.
              category = case file
              when %r{\Aapp/controllers/}, /controller/i then "Controller"
              when %r{\Aapp/services/} then "Service"
              when %r{\Aapp/models/}, /model/i then "Model"
              when /view|\.erb/i then "View"
              when /job|worker/i then "Job"
              when /service/i then "Service"
              when /\.js$|\.ts$/i then "JavaScript"
              else "Other"
              end

              # Route chain for controller callers
              route_hint = ""
              # `match` and not `match?`: the capture is what the route lookup
              # below reads, and `match?` sets none.
              controller_match = file.match(%r{app/controllers/(.+)_controller\.rb})
              if category == "Controller" && controller_match
                routes = find_routes_for_controller(controller_match[1], enclosing_actions(file, matches, root), ctx)
                route_hint = " → #{routes}" if routes
              end

              lines << "### #{file} (#{category})#{route_hint}"
              redact_rows(matches.first(5), root).each do |r|
                lines << "  #{r[:line_number]}: #{redacted(r)}"
              end
              lines << "  _(#{matches.size - 5} more)_" if matches.size > 5
            end
          end

          if test_callers.any?
            lines << "" << "## Tested by (#{count_phrase(test_callers.size, "reference")})"
            test_callers.group_by { |r| r[:file] }.each do |file, matches|
              lines << "- `#{file}` (#{count_phrase(matches.size, "reference")})"
            end
          end

          # One note for the whole search, worded against the lines it read
          # rather than against a heading that counts sites.
          if call_truncated
            lines << "" << "_Only the first #{count_phrase(max_results_cap, 'matching line')} were scanned; there may be more call sites._"
          end
        else
          lines << "## Called from"
          lines << "_No call sites found (method may be unused or called dynamically)_"
        end

        return definition_missing_response(lines.join("\n")) if def_results.empty?

        text_response(lines.join("\n"))
      rescue => e
        text_response("Trace error: #{e.message}")
      end

      SCOPE_WRAPPERS = %w[scope lambda proc].freeze

      # `scope :published, -> { ... }` or `scope("published", ...)`: the
      # line that defines a model's scope method of that name.
      private_class_method def self.scope_pattern(name)
        "^\\s*scope\\s*\\(?\\s*(?::#{literal(name)}\\b|[\"']#{literal(name)}[\"'])"
      end

      # The whole `scope` call that starts on the line, however many lines
      # its lambda runs to; the line alone when it cannot be parsed.
      private_class_method def self.extract_scope_source(file_path, line, name)
        source = RailsAiContext::SafeFile.read(file_path) || ""
        found = nil
        visit = lambda do |node|
          return if found || !node.is_a?(Prism::Node)

          first = node.arguments&.arguments&.first if node.is_a?(Prism::CallNode)
          if node.is_a?(Prism::CallNode) && node.name == :scope && node.location.start_line == line &&
             (first.is_a?(Prism::SymbolNode) || first.is_a?(Prism::StringNode)) && first.unescaped == name
            found = node.slice
          else
            node.compact_child_nodes.each(&visit)
          end
        end
        visit.call(RailsAiContext::AstCache.parse_string(source).value)
        found || source.lines[line - 1]&.rstrip
      rescue => e
        RailsAiContext.debug_fail(e, nil, label: "extract_scope_source")
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
        lines = (RailsAiContext::SafeFile.read(file_path) || "").lines
        # Walk backwards from the method to find the enclosing class/module
        (line_num - 2).downto(0) do |i|
          if lines[i]&.match?(/\A\s*(class|module)\s+(\S+)/)
            return lines[i].strip.sub(/\s*<.*/, "")
          end
        end
        nil
      rescue => e
        RailsAiContext.debug_fail(e, nil, label: "extract_class_context")
      end

      # The other public defs in the file, in every form the definition search finds.
      private_class_method def self.extract_sibling_methods(file_path, exclude_method)
        source = RailsAiContext::SafeFile.read(file_path)
        return [] unless source

        Introspectors::ActionResolver.methods_in(source).filter_map do |method|
          next unless method[:end_location] && method[:visibility] == :public && method[:name] != exclude_method

          method[:scope] == :class ? "self.#{method[:name]}" : method[:name]
        end.uniq
      rescue => e
        RailsAiContext.debug_fail(e, [], label: "extract_sibling_methods")
      end

      # Extract which action a controller caller is in
      # The actions a controller file's matches sit in: the public instance
      # methods of the first class it declares. A call from a macro line, a
      # private method, a class method, a module or a nested class sits in none.
      private_class_method def self.enclosing_actions(file, matches, root)
        source = RailsAiContext::SafeFile.read(File.join(root, file)) || ""
        controller = Introspectors::DeclaredConstant.declared_names(source).first or return []
        actions = Introspectors::ActionResolver.own_methods_in(source, controller).select { |d|
          d[:end_location] && d[:scope] == :instance && d[:visibility] == :public
        }
        matches.filter_map { |m|
          actions.find { |d| (d[:location]..d[:end_location]).cover?(m[:line_number]) }&.dig(:name)
        }.uniq
      rescue => e
        RailsAiContext.debug_fail(e, [], label: "enclosing_actions")
      end

      # Routes of the actions the callers sit in, so the hint never names a
      # route that does not reach the call.
      private_class_method def self.find_routes_for_controller(ctrl_path, actions, ctx)
        routes = ctx[:routes]
        return nil unless routes
        ctrl_routes = Array(RouteCoverage.all_by_controller(routes)[ctrl_path]).select { |r| actions.include?(r[:action].to_s) }
        return nil unless ctrl_routes.any?
        ctrl_routes.first(2).map { |r| "`#{r[:verb]} #{r[:path]}`" }.join(", ")
      rescue => e
        RailsAiContext.debug_fail(e, nil, label: "find_routes_for_controller")
      end

      # The methods a body calls on itself, off the AST: a receiver-less call
      # node, or one on `self`. Local variables and keywords are not call
      # nodes, so nothing has to be filtered back out.
      private_class_method def self.internal_calls_in(body)
        result = RailsAiContext::AstCache.parse_string(body)
        root = result&.value
        return [] unless root

        calls = []
        collect_internal_calls(root, calls)
        calls.uniq
      rescue StandardError, ScriptError => e
        RailsAiContext.debug_fail(e, [], label: "internal_calls_in")
      end

      private_class_method def self.collect_internal_calls(node, found)
        return unless node.is_a?(Prism::Node)

        if node.is_a?(Prism::CallNode) && (node.receiver.nil? || node.receiver.is_a?(Prism::SelfNode))
          found << node.name.to_s
        end
        node.compact_child_nodes.each { |child| collect_internal_calls(child, found) }
      end

      # A method body from a file given the def line number, as the parser
      # bounds the def; a def the walk does not record is read by indentation.
      private_class_method def self.extract_method_body(file_path, def_line)
        source = RailsAiContext::SafeFile.read(file_path) || ""
        method = Introspectors::ActionResolver.methods_in(source).find { |m| m[:location] == def_line }
        return Introspectors::ActionResolver.body_of(source, method)&.dig(:code) if method

        source_lines = source.lines
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
        RailsAiContext.debug_fail(e, nil, label: "extract_method_body")
      end
    end
  end
end
