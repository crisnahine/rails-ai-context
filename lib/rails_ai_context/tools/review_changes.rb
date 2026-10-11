# frozen_string_literal: true

require "open3"

module RailsAiContext
  module Tools
    class ReviewChanges < BaseTool
      tool_name "rails_review_changes"
      description "PR/commit review context: shows changed files with relevant schema/model/route context per file, " \
        "detects warnings (missing indexes, removed validations, changed associations, new routes without tests). " \
        "Use when: reviewing changes before merging, understanding what a commit changed and its impact. " \
        "Key params: ref (default 'HEAD' for uncommitted, or 'main', 'HEAD~3', commit SHA)."

      input_schema(
        properties: {
          ref: {
            type: "string",
            description: "Git ref to diff against. 'HEAD' = uncommitted changes (default). 'main' = diff from main. 'HEAD~3' = last 3 commits. 'abc123' = specific commit."
          },
          files: {
            type: "array",
            items: { type: "string" },
            description: "Filter to specific files (relative to Rails root). Omit to review all changed files."
          }
        }
      )

      guide_row(
        order: 36,
        mcp: "rails_review_changes(ref:\"main\")",
        cli_args: "ref=main",
        summary: "PR/commit review: file context + warnings (missing indexes, removed validations)"
      )

      annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: false, open_world_hint: true)

      MAX_DIFF_LINES_PER_FILE = 30
      VALIDATION_LINE = /\bvalidates?[\s(]/

      def self.call(ref: "HEAD", files: nil, server_context: nil)
        refused = refuse_unsafe_paths(files)
        return refused if refused

        root = rails_app.root.to_s

        # Verify git is available. Child stderr goes to File::NULL so git's own
        # "fatal: not a git repository" noise never reaches the server terminal;
        # the friendly message below is the only thing the caller sees.
        _, status = Open3.capture2("git", "rev-parse", "--git-dir", chdir: root, err: File::NULL)
        unless status.success?
          return text_response("Not a git repository. `rails_review_changes` requires a git repository.\n\n**To initialize:** `git init && git add -A && git commit -m 'Initial commit'`")
        end

        ref = ref.to_s.strip
        ref = "HEAD" if ref.empty?
        # Every git call below takes the ref as an argument, and one that
        # starts with a dash is read as an option: `--output=<path>` writes a
        # file. Past this point git sees the commit the ref names, never the
        # caller's text.
        target = "HEAD"
        base = "HEAD"
        unless ref == "HEAD"
          return error_response("Ref not allowed: #{ref} (git would read it as an option)") if ref.start_with?("-")

          target = resolve_commit(ref, root) or
            return error_response("Unknown ref: #{ref} names no commit in this repository. Pass a branch, a tag, `HEAD~3` or a commit SHA.")
          # What the branch changed since it left the ref, as a pull request
          # shows it: the file list and every diff are taken from the commit
          # the two last shared, so a change made on the ref since then does
          # not read as one the branch undid. Unrelated histories have none.
          base = merge_base(target, root) || target
        end

        changed = get_changed_files(base, root)
        changed = changed.select { |f| files.any? { |filter| f.include?(filter) } } if files&.any?

        if changed.empty?
          return text_response("No changes found for ref '#{ref}'.#{files ? " Filter: #{files.join(', ')}" : ""}")
        end

        # Classify files
        classified = changed.map { |f| { file: f, type: classify_file(f) } }

        # Get commit log
        commits = get_commit_log(target, root)

        # Build output
        lines = [ "# Review: #{ref}", "" ]

        # Summary
        type_counts = classified.group_by { |c| c[:type] }.transform_values(&:size)
        summary_parts = type_counts.map { |type, count| "#{count} #{type}" }
        lines << "**#{count_phrase(changed.size, "file")} changed** (#{summary_parts.join(', ')})"
        lines << ""

        if commits
          lines << "## Commits"
          lines << "```"
          lines << commits
          lines << "```"
          lines << ""
        end

        # Detect warnings
        warnings = detect_warnings(classified, root, base)
        if warnings.any?
          lines << "## Warnings"
          warnings.each { |w| lines << "- #{w}" }
          lines << ""
        end

        # File-by-file context - cap at 20 files to prevent overflow
        max_files = 20
        show_files = classified.first(max_files)
        lines << "## File-by-File Context (#{show_files.size} of #{classified.size})"
        lines << ""

        show_files.each do |entry|
          file_lines = gather_file_context(entry[:file], entry[:type], root, base)
          lines.concat(file_lines)
        end

        if classified.size > max_files
          remaining = classified[max_files..].map { |e| e[:file] }
          lines << "## Remaining #{count_phrase(remaining.size, "file")} (not shown)"
          remaining.each { |f| lines << "- #{f}" }
          lines << ""
        end

        # Next steps
        rb_files = classified.select { |c| c[:file].end_with?(".rb") }.map { |c| c[:file] }
        if rb_files.any?
          file_list = rb_files.first(10).map { |f| "\"#{f}\"" }.join(", ")
          lines << "_Next: `rails_validate(files:[#{file_list}], level:\"rails\")` to validate all changes._"
        end

        text_response(lines.join("\n"))
      rescue => e
        text_response("Review error: #{e.message}")
      end

      class << self
        private

        # @return [String, nil] the full SHA of the commit `ref` names
        def resolve_commit(ref, root)
          return nil if ref.match?(/[\0\r\n]/)

          output, status = Open3.capture2("git", "rev-parse", "--verify", "--quiet", "#{ref}^{commit}", chdir: root, err: File::NULL)
          sha = output.strip
          sha if status.success? && sha.match?(/\A\h{40,64}\z/)
        end

        # @return [String, nil] the full SHA of the commit `commit` and HEAD last shared
        def merge_base(commit, root)
          output, status = Open3.capture2("git", "merge-base", commit, "HEAD", chdir: root, err: File::NULL)
          sha = output.strip
          sha if status.success? && sha.match?(/\A\h{40,64}\z/)
        end

        # An app in a subfolder of its repository (a monorepo's backend/)
        # sees its own files only, named from the app root: `git diff` names
        # paths from the top of the repository unless told `--relative`,
        # while `ls-files` already answers from where it runs.
        #
        # @param base [String] "HEAD" for the uncommitted changes, else the
        #   commit the committed ones are taken from
        def get_changed_files(base, root)
          if base == "HEAD"
            staged, _ = Open3.capture2("git", "diff", "--cached", "--name-only", "--relative", chdir: root, err: File::NULL)
            unstaged, _ = Open3.capture2("git", "diff", "--name-only", "--relative", chdir: root, err: File::NULL)
            untracked, _ = Open3.capture2("git", "ls-files", "--others", "--exclude-standard", chdir: root, err: File::NULL)
            (staged.lines + unstaged.lines + untracked.lines).map(&:strip).reject(&:empty?).uniq
          else
            output, _ = Open3.capture2("git", "diff", "--name-only", "--relative", base, "HEAD", chdir: root, err: File::NULL)
            output.lines.map(&:strip).reject(&:empty?).uniq
          end
        end

        # In a subfolder app, only the commits that touched the app.
        def get_commit_log(ref, root)
          return nil if ref == "HEAD"
          within = subfolder_app?(root) ? [ "--", "." ] : []
          output, status = Open3.capture2("git", "log", "--oneline", "-10", "#{ref}..HEAD", *within, chdir: root, err: File::NULL)
          return nil unless status.success? && !output.strip.empty?
          output.strip
        end

        def subfolder_app?(root)
          prefix, status = Open3.capture2("git", "rev-parse", "--show-prefix", chdir: root, err: File::NULL)
          status.success? && !prefix.strip.empty?
        end

        def classify_file(path)
          case path
          when %r{\Aapp/models/}          then :model
          when %r{\Aapp/controllers/}     then :controller
          when %r{\Adb/migrate/}          then :migration
          when %r{\Aapp/views/}           then :view
          when %r{\Aconfig/routes}        then :routes
          when %r{\A(spec|test)/}         then :test
          when %r{\Aapp/services/}        then :service
          when %r{\Aapp/jobs/}            then :job
          when %r{\Aapp/javascript/}      then :javascript
          when %r{\Aconfig/}              then :config
          else :other
          end
        end

        def gather_file_context(file, type, root, ref)
          lines = [ "### #{file} (#{type})", "" ]

          # Show diff summary
          diff = get_file_diff(file, root, ref)
          if diff
            diff_lines = diff.lines
            added = diff_lines.count { |l| l.start_with?("+") && !l.start_with?("+++") }
            removed = diff_lines.count { |l| l.start_with?("-") && !l.start_with?("---") }
            lines << "+#{added} / -#{removed} lines"

            # Show truncated diff
            content_lines = diff_lines.reject { |l| l.start_with?("diff ", "index ", "--- ", "+++ ") }
            if content_lines.size > MAX_DIFF_LINES_PER_FILE
              lines << "```diff"
              lines.concat(content_lines.first(MAX_DIFF_LINES_PER_FILE).map(&:rstrip))
              lines << "# ... #{count_phrase(content_lines.size - MAX_DIFF_LINES_PER_FILE, "more line")}"
              lines << "```"
            elsif content_lines.any?
              lines << "```diff"
              lines.concat(content_lines.map(&:rstrip))
              lines << "```"
            end
          else
            # In the HEAD flow a nil diff means the file is untracked -
            # summarize it so the section isn't an empty heading. Against a
            # ref the diff is between commits, and a nil one means git gave
            # no text for it, so don't claim "new".
            full_path = File.join(root, file)
            if ref == "HEAD" && File.file?(full_path)
              # A file a symlink carries out of the app is not opened to count it.
              line_count = begin
                File.foreach(full_path).count unless RailsAiContext::PathResolver.linked_out?(full_path, root)
              rescue StandardError
                nil
              end
              lines << (line_count ? "_new file, #{line_count} lines_" : "_new file_")
            else
              lines << "_no diff available_"
            end
          end

          # Pull relevant context per file type
          case type
          when :model
            model_name = File.basename(file, ".rb").camelize
            begin
              result = GetModelDetails.call(model: model_name, detail: "standard")
              lines << "" << "**Model context:** #{model_name}" unless empty?(result)
            rescue => e; RailsAiContext.debug_fail(e, nil, label: "review_changes context lookup"); end

          when :controller
            ctrl_name = File.basename(file, ".rb").camelize
            snake = ctrl_name.underscore.delete_suffix("_controller")
            begin
              result = GetRoutes.call(controller: snake, detail: "summary")
              lines << "" << "**Routes:**" << response_text(result) unless empty?(result)
            rescue => e; RailsAiContext.debug_fail(e, nil, label: "review_changes context lookup"); end

          when :migration
            # Parse migration for table/column info
            full_path = File.join(root, file)
            if File.exist?(full_path) && !RailsAiContext::PathResolver.linked_out?(full_path, root)
              source = RailsAiContext::SafeFile.read(full_path)
              if source
                tables = source.scan(/(?:create_table|add_column|remove_column|rename_column|add_index|add_reference)\s+:(\w+)/).flatten.uniq
                if tables.any?
                  lines << "" << "**Affects tables:** #{tables.join(', ')}"
                  # The table as the schema has it now: its columns, or none
                  # yet for a table the migration creates. get_schema's first
                  # line was only its heading.
                  schema = cached_context&.dig(:schema)
                  tables.first(2).each do |t|
                    columns = Array(RailsAiContext::Payload.schema_table(schema, t)&.dig(:columns)).filter_map { |c| c[:name] if c.is_a?(Hash) }
                    shown = columns.first(8).join(", ") + (columns.size > 8 ? ", ..." : "")
                    lines << "  #{t}: #{columns.any? ? "#{count_phrase(columns.size, "column")} now (#{shown})" : "not in the schema yet"}"
                  rescue => e
                    RailsAiContext.debug_fail(e, nil, label: "review_changes context lookup")
                  end
                end
              end
            end

          when :routes
            begin
              result = GetRoutes.call(detail: "summary")
              summary = response_text(result).lines.first&.strip&.sub(/\A#+\s*/, "")
              lines << "" << "**Current routes:** #{summary}" unless summary.to_s.empty?
            rescue => e; RailsAiContext.debug_fail(e, nil, label: "review_changes context lookup"); end
          end

          lines << ""
          lines
        end

        # The same two commits the file list came from, so a file's diff is
        # the change that put it on the list.
        def get_file_diff(file, root, base)
          if base == "HEAD"
            output, status = Open3.capture2("git", "diff", "--relative", "--", file, chdir: root, err: File::NULL)
            if !status.success? || output.strip.empty?
              output, status = Open3.capture2("git", "diff", "--cached", "--relative", "--", file, chdir: root, err: File::NULL)
            end
          else
            output, status = Open3.capture2("git", "diff", "--relative", base, "HEAD", "--", file, chdir: root, err: File::NULL)
          end
          status.success? && !output.strip.empty? ? output : nil
        end

        def detect_warnings(classified, root, ref)
          warnings = []

          migration_files = classified.select { |c| c[:type] == :migration }
          model_files = classified.select { |c| c[:type] == :model }
          test_files = classified.select { |c| c[:type] == :test }
          controller_files = classified.select { |c| c[:type] == :controller }

          # Check migrations for missing indexes on foreign key columns
          migration_files.each do |entry|
            full_path = File.join(root, entry[:file])
            next unless File.exist?(full_path) && !RailsAiContext::PathResolver.linked_out?(full_path, root)
            source = RailsAiContext::SafeFile.read(full_path) or next

            # New columns ending in _id without add_index
            source.scan(/add_column\s+:\w+,\s+:(\w+_id)/).flatten.each do |col|
              unless source.include?("add_index") && source.include?(col)
                warnings << "**Missing index**: `#{entry[:file]}` adds `#{col}` without an index"
              end
            end

            # add_reference without index: false check
            source.scan(/add_reference\s+:(\w+),\s+:(\w+)/).each do |_table, ref_name|
              if source.include?("index: false")
                warnings << "**Disabled index**: `#{entry[:file]}` adds reference `#{ref_name}` with `index: false`"
              end
            end
          end

          # Check model diffs for removed validations
          model_files.each do |entry|
            diff = get_file_diff(entry[:file], root, ref)
            next unless diff
            removed_validations(diff).each do |line|
              warnings << "**Removed validation**: `#{entry[:file]}` - `#{line}`"
            end
          end

          # Check for controller changes without test changes
          controller_files.each do |entry|
            basename = File.basename(entry[:file], ".rb")
            next unless basename.end_with?("_controller")
            test_name = basename.sub("_controller", "_controller_test")
            spec_name = basename.sub("_controller", "_controller_spec")
            request_name = basename.sub("_controller", "_spec")
            ctrl_stem = basename.delete_suffix("_controller")
            unless test_files.any? { |t| File.basename(t[:file], ".rb").then { |tb| tb == test_name || tb == spec_name || tb == request_name || tb.include?(ctrl_stem) } }
              warnings << "**No test changes**: `#{entry[:file]}` was modified but no corresponding test file was changed"
            end
          end

          warnings
        end

        # The validation lines a diff takes out and puts nothing back for. An
        # edited `validates :name, ...` line is one removed and one added, and
        # :name is still validated; a line whose names are all validated by an
        # added line is an edit, and a commented-out line was no validation.
        def removed_validations(diff)
          removed, added = %w[- +].map do |sign|
            diff.lines.filter_map do |line|
              next unless line.start_with?(sign) && !line.start_with?(sign * 3)

              code = line[1..].strip
              code if code.match?(VALIDATION_LINE) && !code.start_with?("#")
            end
          end
          kept = added.flat_map { |code| validated_names(code) }.to_set
          removed.reject do |code|
            names = validated_names(code)
            names.any? ? names.all? { |name| kept.include?(name) } : added.include?(code)
          end
        end

        # The attributes `validates :a, :b, ...` names, or the method of `validate :check`.
        def validated_names(code)
          code[/\bvalidates?[\s(]+(.*)/, 1].to_s.scan(/\G\s*:(\w+[?!]?)\s*,?/).flatten
        end
      end
    end
  end
end
