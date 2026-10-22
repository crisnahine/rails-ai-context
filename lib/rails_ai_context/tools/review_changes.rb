# frozen_string_literal: true

require "open3"
require "prism"

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
            description: "Filter to files or directories (relative to Rails root). Omit to review all changed files."
          }
        }
      )

      guide_row(
        order: 31,
        mcp: "rails_review_changes(ref:\"main\")",
        cli_args: "ref=main",
        summary: "PR/commit review: file context + warnings (missing indexes, removed validations)"
      )

      annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: false, open_world_hint: true)

      MAX_DIFF_LINES_PER_FILE = 30
      # A diff as git prints it with no config of the user's in the way: colour, an external diff,
      # textconv, a submodule's own diff or a blank context line printed empty would each break the
      # line-by-line reading.
      DIFF = [ "git", "-c", "diff.suppressBlankEmpty=false", "diff", "--no-color", "--no-ext-diff", "--no-textconv", "--submodule=short" ].freeze
      VALIDATION_LINE = /\bvalidates?[\s(]/
      # Each schema method a migration names a table with - ActiveRecord's
      # SchemaStatements and its adapters', through Rails 8.1 - and how many
      # of its leading arguments are tables: the first, a rename's two, and
      # every one drop_table drops. However the call is written:
      # `create_table :orders`, `change_table "orders" do`,
      # `add_column("orders", :coupon_id, :integer)`.
      MIGRATION_TABLE_ARGUMENTS = %i[
        create_table change_table add_column remove_column remove_columns rename_column
        change_column change_column_default change_column_null change_column_comment change_table_comment
        add_index remove_index rename_index enable_index disable_index
        add_reference remove_reference add_belongs_to remove_belongs_to add_timestamps remove_timestamps
        add_foreign_key remove_foreign_key validate_foreign_key
        add_check_constraint remove_check_constraint validate_check_constraint validate_constraint
        add_exclusion_constraint remove_exclusion_constraint add_unique_constraint remove_unique_constraint
        create_virtual_table drop_virtual_table
      ].to_h { |name| [ name, 1 ] }.merge(rename_table: 2, create_join_table: 2, drop_join_table: 2, drop_table: nil).freeze
      # A join table is the one these make or drop from the two they name.
      JOIN_TABLE_METHODS = %i[create_join_table drop_join_table].freeze

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
          return error_response("Ref not allowed: #{echo_input(ref)} (git would read it as an option)") if ref.start_with?("-")

          target = resolve_commit(ref, root) or
            return error_response("Unknown ref: #{echo_input(ref)} names no commit in this repository. Pass a branch, a tag, `HEAD~3` or a commit SHA.")
          # What the branch changed since it left the ref, as a pull request
          # shows it: the file list and every diff are taken from the commit
          # the two last shared, so a change made on the ref since then does
          # not read as one the branch undid. Unrelated histories have none.
          base = merge_base(target, root) || target
        end

        changed = get_changed_files(base, root)
        changed = changed.select { |f| files.any? { |filter| path_matches?(f, filter) } } if files&.any?

        if changed.empty?
          return text_response("No changes found for ref '#{echo_input(ref)}'.#{files ? " Filter: #{echo_input(files.join(', '))}" : ""}")
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
          hint = next_hint(pointer("rails_validate", %(files:[#{file_list}], level:"rails"), "to validate all changes."))
          lines << hint if hint
        end

        text_response(lines.join("\n"))
      end

      class << self
        private

        # @return [String, nil] the full SHA of the commit `ref` names
        def resolve_commit(ref, root)
          return nil if ref.match?(/[\0\r\n]/)

          output, status = Open3.capture2("git", "rev-parse", "--verify", "--quiet", "#{ref}^{commit}", chdir: root, err: File::NULL)
          sha = output.strip
          sha if status.success? && sha.match?(/\A\h{40,64}\z/)
        rescue SystemCallError
          # A ref too long to hand git at all (Windows takes some 32,000
          # characters on a command line, Linux 128 KB in one argument) names
          # no commit; the error said so with the whole ref in it.
          nil
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

        # A filter names one file or a directory, never part of a name: `Gemfile` is not `Gemfile.lock`.
        def path_matches?(path, filter)
          wanted = filter.delete_prefix("./").chomp("/")
          path == wanted || path.start_with?("#{wanted}/")
        end

        # The Ruby folders count only Ruby files: the install writes app/models/AGENTS.md beside the models.
        def classify_file(path)
          case path
          when %r{\Aapp/models/.*\.rb\z}          then :model
          when %r{\Aapp/controllers/.*\.rb\z}     then :controller
          when %r{\Adb/migrate/.*\.rb\z}          then :migration
          when %r{\Aapp/views/}                   then :view
          when %r{\Aconfig/routes}                then :routes
          when %r{\A(spec|test)/}                 then :test
          when %r{\Aapp/services/.*\.rb\z}        then :service
          when %r{\Aapp/jobs/.*\.rb\z}            then :job
          when %r{\Aapp/javascript/}              then :javascript
          when %r{\Aconfig/}                      then :config
          else :other
          end
        end

        def gather_file_context(file, type, root, ref)
          lines = [ "### #{file} (#{type})", "" ]

          # Show diff summary
          diff = get_file_diff(file, root, ref)
          if diff
            # The file's header stands before the first hunk; after it a line can read like one (`--- comment`).
            # Of the header, what says how the file changed is kept: a mode, a rename, a binary file's note.
            all_lines = diff.lines
            first_hunk = all_lines.index { |l| l.start_with?("@@") } || all_lines.size
            content_lines = all_lines[0...first_hunk].reject { |l| l.start_with?("diff --git ", "index ", "--- ", "+++ ") } + all_lines[first_hunk..]
            added = content_lines.count { |l| l.start_with?("+") }
            removed = content_lines.count { |l| l.start_with?("-") }
            lines << "+#{added} / -#{removed} lines"

            # Show truncated diff. A file the tools may not read shows that it
            # changed, and none of its lines.
            if sensitive_file?(file)
              lines << "_diff not shown: the file is on `sensitive_patterns`_"
              content_lines = []
            end
            shown = content_lines.empty? ? [] : redacted_diff(content_lines.first(MAX_DIFF_LINES_PER_FILE).map(&:chomp), file, get_file_diff(file, root, ref, whole: true))
            if shown.any? && content_lines.size > MAX_DIFF_LINES_PER_FILE
              lines << "```diff"
              lines.concat(shown.map(&:rstrip))
              lines << "# ... #{count_phrase(content_lines.size - MAX_DIFF_LINES_PER_FILE, "more line")}"
              lines << "```"
            elsif shown.any?
              lines << "```diff"
              lines.concat(shown.map(&:rstrip))
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
              result = compose(GetModelDetails, model: model_name, detail: "standard")
              lines << "" << "**Model context:** #{model_name}" unless empty?(result)
            rescue => e; RailsAiContext.debug_fail(e, nil, label: "review_changes context lookup"); end

          when :controller
            ctrl_name = File.basename(file, ".rb").camelize
            snake = ctrl_name.underscore.delete_suffix("_controller")
            begin
              result = compose(GetRoutes, controller: snake, detail: "summary")
              lines << "" << "**Routes:**" << response_text(result) unless empty?(result)
            rescue => e; RailsAiContext.debug_fail(e, nil, label: "review_changes context lookup"); end

          when :migration
            # Parse migration for table/column info
            full_path = File.join(root, file)
            if File.exist?(full_path) && !RailsAiContext::PathResolver.linked_out?(full_path, root)
              source = RailsAiContext::SafeFile.read(full_path)
              if source
                tables = migration_tables(source)
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
              result = compose(GetRoutes, detail: "summary")
              summary = response_text(result).lines.first&.strip&.sub(/\A#+\s*/, "")
              lines << "" << "**Current routes:** #{summary}" unless summary.to_s.empty?
            rescue => e; RailsAiContext.debug_fail(e, nil, label: "review_changes context lookup"); end
          end

          lines << ""
          lines
        end

        # The tables a migration's statements name, in the order it names
        # them; a join table's own name comes before the two it joins. A
        # call on a block's table (`t.remove_index :number`) names no table
        # of its own, and a commented-out line is no statement.
        def migration_tables(source)
          tables = []
          visit = lambda do |node|
            if node.is_a?(Prism::CallNode) && node.receiver.nil? && MIGRATION_TABLE_ARGUMENTS.key?(node.name)
              args = node.arguments&.arguments || []
              names = args.take_while { |arg| arg.is_a?(Prism::SymbolNode) || arg.is_a?(Prism::StringNode) }.map(&:unescaped)
              names = names.first(MIGRATION_TABLE_ARGUMENTS[node.name]) if MIGRATION_TABLE_ARGUMENTS[node.name]
              if JOIN_TABLE_METHODS.include?(node.name) && names.size == 2
                joined = join_table_name(names, args)
                tables << joined if joined
              end
              tables.concat(names)
            end
            node.compact_child_nodes.each(&visit)
          end
          visit.call(RailsAiContext::AstCache.parse_string(source).value)
          tables.uniq
        rescue => e
          RailsAiContext.debug_fail(e, [], label: "migration_tables")
        end

        # The join table as Rails names it: `table_name:` when the call gives
        # one (nil when that is no literal), else the two tables sorted, with
        # a prefix they share written once - ActiveRecord::ModelSchema
        # .derive_join_table_name, so `:admin_users, :admin_roles` make
        # admin_roles_users.
        def join_table_name(tables, args)
          option = args.grep(Prism::KeywordHashNode).flat_map(&:elements).find do |assoc|
            assoc.is_a?(Prism::AssocNode) && assoc.key.is_a?(Prism::SymbolNode) && assoc.key.unescaped == "table_name"
          end
          return tables.sort.join("\0").gsub(/^(.*[_.])(.+)\0\1(.+)/, '\1\2_\3').tr("\0", "_") unless option

          option.value.unescaped if option.value.is_a?(Prism::SymbolNode) || option.value.is_a?(Prism::StringNode)
        end

        # A diff line is a mark (` `, `+` or `-`) and a line of one side of the
        # change, so it is shown as that line of that side, redacted with the
        # whole of it the way every tool's source is: a hunk can open inside a
        # PEM key, below its BEGIN line. A hunk header carries a line of the
        # file too, after its second @@. `whole` is the same diff with every
        # line as context; without it no line is shown.
        def redacted_diff(diff_lines, file, whole)
          # A merge conflict's combined diff has two mark columns, which this reading does not follow.
          return [] if whole.nil? || [ *diff_lines, *whole.lines ].any? { |line| line.start_with?("@@@") }
          # Both sides are read whole, so together they keep to the read limit a file has.
          limit = RailsAiContext.configuration.max_file_size
          return [] if limit.is_a?(Numeric) && whole.bytesize > limit

          plain = diff_sides(whole)
          sides = plain.map { |lines| RailsAiContext::Redaction.redact_source_lines(lines, path: file) }
          # The line numbers, from 1, of the next old and new line.
          old_line = new_line = 1
          diff_lines.map do |line|
            if (hunk = line.match(/\A(@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@)(.*)\z/m))
              old_line, new_line = hunk[2].to_i, hunk[3].to_i
              next hunk[1] + header_text(hunk[4], plain, sides)
            end
            next line unless (mark = line[0]) && " +-".include?(mark)

            text = mark == "-" ? sides[0][old_line - 1] : sides[1][new_line - 1]
            old_line += 1 unless mark == "+"
            new_line += 1 unless mark == "-"
            mark + (text || RailsAiContext::Redaction::FILTERED)
          end
        end

        # [the old side's lines, the new side's] of a diff that has every line as context.
        def diff_sides(whole)
          body = whole.lines.drop_while { |line| !line.start_with?("@@") }.reject { |line| line.start_with?("@@", "\\") }
          [ body.filter_map { |line| line.chomp[1..].to_s if line.start_with?(" ", "-") },
            body.filter_map { |line| line.chomp[1..].to_s if line.start_with?(" ", "+") } ]
        end

        # A hunk header's text, copied by git from a line of either side (the part a funcname pattern picks,
        # trimmed and cut at 80 bytes): as written when every line it can come from is shown so, redacted
        # when it is one whole line, else filtered.
        def header_text(text, plain, sides)
          start = text.delete_prefix(" ").rstrip.b
          return text if start.empty?

          found = [ 0, 1 ].flat_map { |side| plain[side].each_index.select { |i| plain[side][i].b.include?(start) }.map { |i| [ plain[side][i], sides[side][i] ] } }
          return text if found.any? && found.all? { |line, redacted| line == redacted }

          redacted = found.map { |_, line| line.strip }.uniq
          whole = found.any? && found.all? { |line, _| line.strip.b == start }
          " #{whole && redacted.one? ? redacted.first : RailsAiContext::Redaction::FILTERED}"
        end

        # The same two commits the file list came from, so a file's diff is
        # the change that put it on the list. `whole` asks for every line as context.
        def get_file_diff(file, root, base, whole: false)
          diff = [ *DIFF, *(whole ? [ "--unified=#{2**31 - 1}" ] : []) ]
          if base == "HEAD"
            output, status = Open3.capture2(*diff, "--relative", "--", file, chdir: root, err: File::NULL)
            if !status.success? || output.scrub.strip.empty?
              output, status = Open3.capture2(*diff, "--cached", "--relative", "--", file, chdir: root, err: File::NULL)
            end
          else
            output, status = Open3.capture2(*diff, "--relative", base, "HEAD", "--", file, chdir: root, err: File::NULL)
          end
          output = output.scrub
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
            source.scan(/\badd_column\b\(?\s*[:"']\w+["']?\s*,\s*[:"'](\w+_id)\b/).flatten.each do |col|
              unless source.include?("add_index") && source.include?(col)
                warnings << "**Missing index**: `#{entry[:file]}` adds `#{col}` without an index"
              end
            end

            # add_reference without index: false check
            source.scan(/\badd_(?:reference|belongs_to)\b\(?\s*[:"'](\w+)["']?\s*,\s*[:"'](\w+)/).each do |_table, ref_name|
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
              warnings << "**Removed validation**: `#{entry[:file]}` - `#{RailsAiContext::Redaction.redact_source_line(line, path: entry[:file])}`"
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
