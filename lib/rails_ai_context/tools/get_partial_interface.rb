# frozen_string_literal: true

module RailsAiContext
  module Tools
    class GetPartialInterface < BaseTool
      tool_name "rails_get_partial_interface"
      description "Analyze a partial's interface: local variables it expects, where it's rendered from, and what methods are called on each local. " \
        "Use when: rendering a partial, understanding what locals to pass, or refactoring partial dependencies. " \
        "Specify partial:\"shared/status_badge\" to see its full interface. Supports both underscore-prefixed and non-prefixed names."

      input_schema(
        properties: {
          partial: {
            type: "string",
            description: "Partial path relative to app/views (e.g. 'shared/status_badge', 'users/form'). The leading underscore is optional."
          },
          detail: RailsAiContext::DetailLevel.schema("Detail level. summary: locals list + usage count. standard: locals + usage examples from codebase (default). full: locals + usage + full partial source.")
        },
        required: [ "partial" ]
      )

      guide_row(
        order: 18,
        mcp: "rails_get_partial_interface(partial:\"X\")",
        cli_args: "partial=X",
        summary: "Partial locals contract: what to pass + usage examples"
      )

      annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true, open_world_hint: false)

      def self.call(partial:, detail: "standard", server_context: nil)
        # Guard: required parameter
        if partial.nil? || partial.strip.empty?
          return text_response("The `partial` parameter is required. Provide a partial path relative to app/views (e.g. 'shared/status_badge').")
        end

        root = rails_app.root.to_s
        # Every views root the app has, so a partial an in-repo engine or
        # plugin keeps is found the way one under app/views is.
        view_dirs = RailsAiContext::PathResolver.view_dirs(root)
        views_dir = File.join(root, "app", "views")

        # Only the caller string is judged here; the candidate search below
        # decides whether the partial exists.
        guard = RailsAiContext::SafePath.locate(partial, under: views_dir, root: root)
        case guard.refusal
        when :traversal then return error_response("Path not allowed: #{partial}")
        when :sensitive then return error_response("Path not allowed: #{partial} (sensitive file)")
        end

        if view_dirs.empty?
          note = api_only_note("app/views")
          return text_response(note) if note

          return text_response("No app/views/ directory found.")
        end

        # A bare name is a name, not a path: an app has several `_form`, and the first in sorted
        # order would give one directory's locals for another's.
        same_name = view_dirs.flat_map { |dir| bare_name_matches(dir, partial) }
        if same_name.size > 1
          return empty_response(
            [ "Partial '#{partial}' matches #{count_phrase(same_name.size, 'file')}:", "",
              *same_name.map { |f| "- `#{view_relative(f, view_dirs)}`" }, "",
              "_Pass one with its directory, e.g. `#{view_relative(same_name.first, view_dirs).sub(%r{/_}, "/").sub(/\..*\z/, "")}`._" ].join("\n")
          )
        end

        located = view_dirs.lazy.filter_map { |dir| resolve_partial_path(dir, partial) }.first

        unless located
          available = view_dirs.flat_map { |dir| find_available_partials(dir, root) }.uniq.sort.first(30)
          return not_found_response("Partial", partial, available,
            recovery_tool: "Call rails_get_view(detail:\"summary\") to see all views and partials")
        end

        file_path = located.realpath
        if located.refusal == :too_large
          return text_response("Partial file too large: #{file_path} (#{File.size(file_path)} bytes, max: #{max_file_size})")
        end

        source = safe_read(file_path)
        return text_response("Could not read partial file.") unless source

        relative_path = located.relative
        partial_name = relative_path.sub(%r{\A.*app/views/}, "")

        # Parse the partial's interface
        magic_locals = extract_magic_comment_locals(source)
        render_sites = view_dirs.flat_map { |dir| find_render_sites(dir, partial, root) }
        method_calls = {}

        # Primary: locals from render call sites (ground truth)
        render_locals = render_sites.flat_map { |rs| rs[:locals] || [] }.uniq

        # Secondary: local_assigns checks + defined? guards in partial source
        source_locals = extract_local_variable_references(source, Introspectors::HelperNames.for(root))

        # Combine: render-site locals first, then source-detected locals
        # Filter out noise: single chars, capitalized words, known helpers
        all_locals = (magic_locals + render_locals + source_locals).uniq
          .reject { |l| l.length <= 1 || l.match?(/\A[A-Z]/) || l.match?(/\Arender_/) }
          .sort

        # Extract method calls only for confirmed locals
        method_calls = extract_method_calls_on_locals(source, all_locals) if all_locals.any?

        case detail
        when "summary"
          format_summary(partial_name, all_locals, magic_locals, render_sites)
        else
          format_detail(partial_name, relative_path, source, all_locals, magic_locals, render_sites, method_calls,
                        full: RailsAiContext::DetailLevel.full?(detail))
        end
      end

      private_class_method def self.format_summary(partial_name, all_locals, magic_locals, render_sites)
        lines = [ "# Partial: #{partial_name}", "" ]

        if all_locals.any?
          magic_note = magic_locals.any? ? " (#{magic_locals.size} declared via magic comment)" : ""
          lines << "**Locals:** #{all_locals.join(', ')}#{magic_note}"
        else
          lines << "**Locals:** none detected"
        end

        lines << "**Rendered from:** #{count_phrase(render_sites.size, "location")}"
        lines << ""
        lines << "_Use `detail:\"standard\"` for usage examples, or `detail:\"full\"` for full partial source._"

        text_response(lines.join("\n"))
      end

      private_class_method def self.format_detail(partial_name, relative_path, source, all_locals, magic_locals, render_sites, method_calls, full:)
        lines = [ "# Partial: #{partial_name}", "" ]
        lines << "**File:** `#{relative_path}` (#{count_phrase(source.lines.size, "line")})"

        if magic_locals.any?
          lines << "**Declared locals** (Rails 7.1+ magic comment): #{magic_locals.join(', ')}"
        end

        if all_locals.any?
          lines << "" << "## Local Variables"
          all_locals.each do |local|
            methods = method_calls[local]
            if methods&.any?
              shown = full ? methods : methods.first(10)
              more = !full && methods.size > 10 ? ", ...and #{methods.size - 10} more" : ""
              lines << "- **#{local}** - calls: #{shown.join(', ')}#{more}"
            else
              lines << "- **#{local}**"
            end
          end
        elsif !full
          lines << "" << "_No local variables detected in this partial._"
        end

        if render_sites.any?
          cap = full ? 25 : 15
          lines << "" << "## Rendered From (#{render_sites.size})"
          render_sites.first(cap).each do |site|
            locals_str = site[:locals].any? ? " - locals: #{site[:locals].join(', ')}" : ""
            lines << "- `#{site[:file]}:#{site[:line]}`#{locals_str}"
            next unless full && site[:snippet]

            lines << "  ```erb"
            lines << "  #{site[:snippet].strip}"
            lines << "  ```"
          end
          if render_sites.size > cap
            lines << "- _...and #{render_sites.size - cap} more_"
          end
        elsif !full
          lines << "" << "_No render calls found for this partial._"
        end

        if full
          lines << "" << "## Source"
          lines << "```erb"
          lines << source
          lines << "```"
        else
          lines << ""
          lines << "_Next: `rails_get_view(path:\"#{partial_name}\")` for full file content_"
        end

        text_response(lines.join("\n"))
      end

      # Resolve a partial reference to an actual file path on disk.
      # Handles both underscore-prefixed filenames and non-prefixed input.
      # Falls back to recursive search when no directory is specified.
      private_class_method def self.resolve_partial_path(views_dir, partial)
        # Normalize: strip leading underscore from basename if provided
        parts = partial.split("/")
        basename = parts.last
        dir_parts = parts[0...-1]

        # Try with underscore prefix (standard Rails partial naming)
        prefixed_basename = basename.start_with?("_") ? basename : "_#{basename}"
        unprefixed_basename = basename.delete_prefix("_")

        # A fixed extension list refused `.text.erb`, which the Available
        # list built by globbing had just offered. Rails names a partial by
        # its directory and basename, whatever format and handler follow.
        candidates = [
          *Dir.glob(File.join(views_dir, *dir_parts, "#{prefixed_basename}.*")).sort,
          *Dir.glob(File.join(views_dir, *dir_parts, "#{unprefixed_basename}.*")).sort,
          File.join(views_dir, partial)
        ]

        found = candidates.find { |c| File.file?(c) }

        found = bare_name_matches(views_dir, partial).first if found.nil? && dir_parts.empty?

        return nil unless found

        located = RailsAiContext::SafePath.locate(found.delete_prefix(views_dir + File::SEPARATOR), under: views_dir, root: rails_app.root.to_s)
        located.ok? || located.refusal == :too_large ? located : nil
      end

      # A view file's name as the app renders it: its path under whichever
      # views root holds it.
      private_class_method def self.view_relative(path, view_dirs)
        dir = view_dirs.find { |d| path.start_with?(d + File::SEPARATOR) }
        dir ? path.delete_prefix(dir + File::SEPARATOR) : path
      end

      # Every partial of this name anywhere under app/views, for a caller who
      # gave a name with no directory. Empty for a path: that names one file.
      private_class_method def self.bare_name_matches(views_dir, partial)
        name = partial.to_s.strip
        return [] if name.include?("/")

        name = "_#{name}" unless name.start_with?("_")
        Dir.glob(File.join(views_dir, "**", "#{name}.*")).sort.select { |c| File.file?(c) }
      end

      # Extract locals declared via Rails 7.1+ magic comment: <%# locals: (name:, title: "default") %>
      private_class_method def self.extract_magic_comment_locals(source)
        locals = []

        source.each_line do |line|
          if (match = line.match(/<%#\s*locals:\s*\(([^)]+)\)\s*%>/))
            params_str = match[1]
            # Parse Ruby-style keyword params: name:, title: "default", count: 0
            params_str.scan(/([\w]+):/) do |param_match|
              locals << param_match[0]
            end
          end
        end

        locals.uniq
      rescue => e
        RailsAiContext.debug_fail(e, [], label: "extract_magic_comment_locals")
      end

      # Extract local variable references from ERB source.
      # Locals are variables NOT prefixed with @ and NOT known Ruby/Rails globals.
      private_class_method def self.extract_local_variable_references(source, helpers = Set.new)
        locals = Set.new
        # Known non-local identifiers to exclude
        known_non_locals = Set.new(%w[
          true false nil self yield render partial content_for
          form_for form_with form_tag fields_for button_to link_to
          image_tag stylesheet_link_tag javascript_include_tag
          csrf_meta_tags csp_meta_tag action_name controller_name
          content_tag tag concat raw html_safe j escape_javascript
          t translate l localize pluralize truncate number_to_currency
          number_with_delimiter number_to_percentage number_to_human
          simple_format sanitize strip_tags highlight excerpt
          time_ago_in_words distance_of_time_in_words
          debug inspect to_s to_i to_f to_a to_h
          each map select reject find collect detect any? all? none?
          first last size length count empty? blank? present?
          if else elsif unless case when end do begin rescue ensure
          class module def return break next raise
          puts print p require require_relative
          turbo_frame_tag turbo_stream_from turbo_stream
          capture provide request response params session flash cookies
          current_page? url_for polymorphic_path polymorphic_url
          new_record? persisted? errors model_name
        ])

        # Block parameters (form_with do |form|, errors.each do |error|) are
        # yielded inside the template, not passed as render locals - names
        # declared between pipes must not be reported as expected locals.
        block_params = Set.new
        source.scan(/(?:\bdo|\{)\s*\|([^|]+)\|/).each do |(params_str)|
          params_str.split(",").each do |param|
            name = param[/[a-z_]\w*/]
            block_params << name if name
          end
        end

        # High-confidence local detection only - avoids false positives from HTML/CSS text
        source.scan(RailsAiContext::ErbSource::TAG).each do |match|
          code = match[0].strip
          next if code.start_with?("#")

          # 1. Standalone ERB output: <%= local_name %> or <%= local_name.method %>
          if (m = code.match(/\A\s*([a-z_]\w*)\s*(?:\z|\.|\()/))
            name = m[1]
            locals << name unless known_non_locals.include?(name) || block_params.include?(name) || helpers.include?(name)
          end

          # 2. defined?(local) guard pattern
          code.scan(/defined\?\s*\(?([a-z_]\w*)\)?/).each do |var_match|
            locals << var_match[0]
          end
        end

        # Also check for local_assigns usage: local_assigns[:name] or local_assigns.fetch(:name)
        source.scan(/local_assigns\[:(\w+)\]/).each { |m| locals << m[0] }
        source.scan(/local_assigns\.fetch\(:(\w+)/).each { |m| locals << m[0] }

        # Also check for `defined?(name)` guard pattern
        source.scan(/defined\?\((\w+)\)/).each { |m| locals << m[0] }

        # Filter out things that are clearly method definitions or blocks
        locals.reject { |l| l.match?(/\A(each|map|select|reject|find|collect|do|end)\z/) }.to_a.sort
      rescue => e
        RailsAiContext.debug_fail(e, [], label: "extract_local_variable_references")
      end

      # Find all views that render this partial and extract the locals they pass.
      private_class_method def self.find_render_sites(views_dir, partial, root)
        sites = []
        # Build search names: the partial can be referenced multiple ways
        # Normalize: strip underscore prefix from basename and extensions
        parts = partial.split("/")
        basename = parts.last.delete_prefix("_").sub(/\..*\z/, "")
        dir_prefix = parts[0...-1].join("/")

        # Build the canonical render name (how Rails references partials in render calls)
        # "shared/_status_badge.html.erb" → "shared/status_badge"
        # "_status_badge" → "status_badge"
        canonical = (dir_prefix.empty? ? basename : "#{dir_prefix}/#{basename}")

        # Possible render references:
        # render "shared/status_badge"
        # render partial: "shared/status_badge"
        # render "status_badge" (from same directory)
        search_patterns = [
          canonical,                                                # shared/status_badge
          basename                                                  # status_badge
        ].uniq

        # Implicit object/collection rendering resolves to this partial via
        # to_partial_path: `render @post`, `render post`, `render @posts`,
        # `render posts` all hit posts/_post. These are extremely common and
        # carry no quoted partial name, so the explicit-string match above
        # misses them. Only treat the partial as a conventional resource
        # partial (posts/_post) when its directory is the pluralized basename
        # or it is top-level, to avoid matching unrelated variables.
        plural = basename.pluralize
        implicit_names =
          if dir_prefix.empty? || dir_prefix.split("/").last == plural
            [ basename, plural ].uniq
          else
            []
          end

        view_files = Dir.glob(File.join(views_dir, RailsAiContext::ViewFile::MARKUP_GLOB)).sort

        view_files.each do |file|
          content = safe_read(file)
          next unless content

          relative = file.sub("#{root}/", "")

          lines = content.lines
          # Per call, not per line: `render(` and a call split over lines are
          # one call whose arguments the line alone does not hold.
          covered = 0
          Introspectors::ViewTemplateIntrospector.render_calls(content).each do |at, args|
            args = args.split("%>", 2).first
            # A render inside another's arguments is already part of that call's site.
            next if at < covered

            covered = at + args.length
            line_num = content[0...at].count("\n") + 1
            line = "render #{args.gsub(/\s+/, " ").strip}"
            spanned = lines[(line_num - 1)..(line_num - 1 + args.chomp.count("\n"))]
            snippet = spanned.size > 1 ? spanned.join(" ").squish : lines[line_num - 1].strip

            matched_line = false
            search_patterns.each do |search_name|
              # Match render "partial_name" or render partial: "partial_name"
              # Allow content before search_name (e.g. "shared/status_badge" matches "status_badge")
              next unless line.match?(/render\s.*["'][^"']*#{Regexp.escape(search_name)}["']/)

              # For short basename matches, verify directory context
              if search_name == basename && dir_prefix.length > 0
                # Only match if the full path is referenced, or the render is in the same directory
                file_dir = File.dirname(file).sub("#{views_dir}/", "")
                next unless line.include?(dir_prefix) || file_dir == dir_prefix
              end

              locals_passed = extract_locals_from_render(line)

              sites << {
                file: relative,
                line: line_num,
                locals: locals_passed,
                snippet: snippet
              }
              matched_line = true
              break # one match per call is enough
            end

            next if matched_line

            # Implicit object/collection render: `render @post`, `render post`,
            # `render @posts`. The variable is a bareword or ivar (no quotes),
            # and \b guards against prefixes like post_path / posts_controller.
            implicit_names.each do |var|
              next unless line.match?(/render\s+@?#{Regexp.escape(var)}\b/)
              next if line.match?(/render\s.*["']/) # a quoted render is explicit, handled above

              sites << {
                file: relative,
                line: line_num,
                locals: [],
                snippet: snippet
              }
              break
            end
          end
        end

        sites
      rescue => e
        RailsAiContext.debug_fail(e, [], label: "find_render_sites")
      end

      # Extract local variable names from a render call line.
      private_class_method def self.extract_locals_from_render(line)
        locals = []

        # Pattern 1: render partial: "name", locals: { key1: val, key2: val }
        if (match = line.match(/locals:\s*\{([^}]+)\}/))
          match[1].scan(/(\w+):/) { |m| locals << m[0] }
        end

        # Pattern 2: render "name", key1: val, key2: val (shorthand)
        # Match render "..." or render partial: "..." followed by comma-separated key: val pairs
        if locals.empty?
          # Strip the render call and partial name, look for remaining key: value pairs
          remaining = line.sub(/render\s+(?:partial:\s*)?["'][^"']+["']\s*,?\s*/, "")
          remaining = remaining.sub(/locals:\s*\{[^}]*\}/, "") # already handled above
          remaining.scan(/(\w+):\s*(?!["']\w+["'])/) do |m|
            name = m[0]
            next if %w[partial locals collection as cached object spacer_template layout formats].include?(name)
            locals << name
          end
        end

        locals.uniq
      rescue => e
        RailsAiContext.debug_fail(e, [], label: "extract_locals_from_render")
      end

      # Extract method calls made on each local variable within the partial.
      private_class_method def self.extract_method_calls_on_locals(source, locals)
        calls = {}
        return calls if locals.empty?

        locals.each do |local|
          methods = Set.new

          # Match: local.method_name or local.method_name(args)
          source.scan(/\b#{Regexp.escape(local)}\.(\w+[?!]?)/).each do |match|
            method_name = match[0]
            # Exclude common Ruby/ERB noise
            next if %w[to_s to_i to_f to_a to_h to_json to_param inspect class nil? is_a? respond_to? send freeze dup clone].include?(method_name)
            methods << method_name
          end

          # Match: local&.method_name (safe navigation)
          source.scan(/\b#{Regexp.escape(local)}&\.(\w+[?!]?)/).each do |match|
            methods << match[0]
          end

          calls[local] = methods.to_a.sort if methods.any?
        end

        calls
      rescue => e
        RailsAiContext.debug_fail(e, {}, label: "extract_method_calls_on_locals")
      end

      # Find available partials for fuzzy matching in not_found_response.
      private_class_method def self.find_available_partials(views_dir, root)
        Dir.glob(File.join(views_dir, "**", "_*")).select { |f| File.file?(f) && RailsAiContext::ViewFile.template?(f) }.map do |f|
          relative = f.sub("#{views_dir}/", "")
          # Strip underscore prefix and extension for display
          parts = relative.split("/")
          parts[-1] = parts[-1].delete_prefix("_").sub(/\..*\z/, "")
          parts.join("/")
        end.uniq.sort.first(30)
      rescue => e
        RailsAiContext.debug_fail(e, [], label: "find_available_partials")
      end
    end
  end
end
