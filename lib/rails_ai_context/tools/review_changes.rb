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

      annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: false, open_world_hint: true)

      MAX_DIFF_LINES_PER_FILE = 30

      def self.call(ref: "HEAD", files: nil, server_context: nil)
        root = Rails.root.to_s

        # Verify git is available
        _, status = Open3.capture2("git", "rev-parse", "--git-dir", chdir: root)
        unless status.success?
          return text_response("Not a git repository. `rails_review_changes` requires a git repository.\n\n**To initialize:** `git init && git add -A && git commit -m 'Initial commit'`")
        end

        changed = get_changed_files(ref, root)
        changed = changed.select { |f| files.any? { |filter| f.include?(filter) } } if files&.any?

        if changed.empty?
          return text_response("No changes found for ref '#{ref}'.#{files ? " Filter: #{files.join(', ')}" : ""}")
        end

        # Classify files
        classified = changed.map { |f| { file: f, type: classify_file(f) } }

        # Get commit log
        commits = get_commit_log(ref, root)

        # Build output
        lines = [ "# Review: #{ref}", "" ]

        # Summary
        type_counts = classified.group_by { |c| c[:type] }.transform_values(&:size)
        summary_parts = type_counts.map { |type, count| "#{count} #{type}" }
        lines << "**#{changed.size} files changed** (#{summary_parts.join(', ')})"
        lines << ""

        if commits
          lines << "## Commits"
          lines << "```"
          lines << commits
          lines << "```"
          lines << ""
        end

        # Detect warnings
        warnings = detect_warnings(classified, root, ref)
        if warnings.any?
          lines << "## Warnings"
          warnings.each { |w| lines << "- #{w}" }
          lines << ""
        end

        # File-by-file context — cap at 20 files to prevent overflow
        max_files = 20
        show_files = classified.first(max_files)
        lines << "## File-by-File Context (#{show_files.size} of #{classified.size})"
        lines << ""

        show_files.each do |entry|
          file_lines = gather_file_context(entry[:file], entry[:type], root, ref)
          lines.concat(file_lines)
        end

        if classified.size > max_files
          remaining = classified[max_files..].map { |e| e[:file] }
          lines << "## Remaining #{remaining.size} files (not shown)"
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

        def get_changed_files(ref, root)
          if ref == "HEAD"
            staged, _ = Open3.capture2("git", "diff", "--cached", "--name-only", chdir: root)
            unstaged, _ = Open3.capture2("git", "diff", "--name-only", chdir: root)
            untracked, _ = Open3.capture2("git", "ls-files", "--others", "--exclude-standard", chdir: root)
            (staged.lines + unstaged.lines + untracked.lines).map(&:strip).reject(&:empty?).uniq
          else
            # Try three-dot (since divergence from ref)
            output, status = Open3.capture2("git", "diff", "--name-only", "#{ref}...HEAD", chdir: root)
            unless status.success?
              # Fall back to two-dot
              output, status = Open3.capture2("git", "diff", "--name-only", "#{ref}..HEAD", chdir: root)
              unless status.success?
                # Fall back to single ref diff
                output, _ = Open3.capture2("git", "diff", "--name-only", ref, chdir: root)
              end
            end
            output.lines.map(&:strip).reject(&:empty?).uniq
          end
        end

        def get_commit_log(ref, root)
          return nil if ref == "HEAD"
          output, status = Open3.capture2("git", "log", "--oneline", "-10", "#{ref}..HEAD", chdir: root)
          return nil unless status.success? && !output.strip.empty?
          output.strip
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

        def gather_file_context(file, type, root, ref) # rubocop:disable Metrics
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
              lines << "# ... #{content_lines.size - MAX_DIFF_LINES_PER_FILE} more lines"
              lines << "```"
            elsif content_lines.any?
              lines << "```diff"
              lines.concat(content_lines.map(&:rstrip))
              lines << "```"
            end
          end

          # Pull relevant context per file type
          case type
          when :model
            model_name = File.basename(file, ".rb").camelize
            begin
              result = GetModelDetails.call(model: model_name, detail: "standard")
              text = result.content.first[:text]
              lines << "" << "**Model context:** #{model_name}" unless text.include?("not found")
            rescue => e; $stderr.puts "[rails-ai-context] Context lookup skipped: #{e.message}" if ENV["DEBUG"]; end

          when :controller
            ctrl_name = File.basename(file, ".rb").camelize
            snake = ctrl_name.underscore.delete_suffix("_controller")
            begin
              result = GetRoutes.call(controller: snake, detail: "summary")
              text = result.content.first[:text]
              lines << "" << "**Routes:**" << text unless text.include?("not found") || text.include?("No routes")
            rescue => e; $stderr.puts "[rails-ai-context] Context lookup skipped: #{e.message}" if ENV["DEBUG"]; end

          when :migration
            # Parse migration for table/column info
            full_path = File.join(root, file)
            if File.exist?(full_path)
              source = RailsAiContext::SafeFile.read(full_path)
              if source
                tables = source.scan(/(?:create_table|add_column|remove_column|rename_column|add_index|add_reference)\s+:(\w+)/).flatten.uniq
                if tables.any?
                  lines << "" << "**Affects tables:** #{tables.join(', ')}"
                  tables.first(2).each do |t|
                    begin
                      result = GetSchema.call(table: t, detail: "summary")
                      text = result.content.first[:text]
                      lines << "  #{t}: #{text.lines.first&.strip}" unless text.include?("not found")
                    rescue => e; $stderr.puts "[rails-ai-context] Context lookup skipped: #{e.message}" if ENV["DEBUG"]; end
                  end
                end
              end
            end

          when :routes
            begin
              result = GetRoutes.call(detail: "summary")
              lines << "" << "**Current routes:** #{result.content.first[:text].lines.first&.strip}"
            rescue => e; $stderr.puts "[rails-ai-context] Context lookup skipped: #{e.message}" if ENV["DEBUG"]; end
          end

          lines << ""
          lines
        end

        def get_file_diff(file, root, ref)
          if ref == "HEAD"
            output, status = Open3.capture2("git", "diff", "--", file, chdir: root)
            if !status.success? || output.strip.empty?
              output, status = Open3.capture2("git", "diff", "--cached", "--", file, chdir: root)
            end
          else
            output, status = Open3.capture2("git", "diff", ref, "--", file, chdir: root)
          end
          status.success? && !output.strip.empty? ? output : nil
        end

        def detect_warnings(classified, root, ref) # rubocop:disable Metrics
          warnings = []

          migration_files = classified.select { |c| c[:type] == :migration }
          model_files = classified.select { |c| c[:type] == :model }
          test_files = classified.select { |c| c[:type] == :test }
          controller_files = classified.select { |c| c[:type] == :controller }

          # Check migrations for missing indexes on foreign key columns
          migration_files.each do |entry|
            full_path = File.join(root, entry[:file])
            next unless File.exist?(full_path)
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
            removed_validations = diff.lines.select { |l| l.start_with?("-") && l.match?(/validates?\s/) }
            removed_validations.each do |line|
              warnings << "**Removed validation**: `#{entry[:file]}` — `#{line.strip[1..].strip}`"
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
      end
    end
  end
end
