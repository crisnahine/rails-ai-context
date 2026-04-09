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
          detail: {
            type: "string",
            enum: %w[summary standard full],
            description: "Detail level. summary: locals list + usage count. standard: locals + usage examples from codebase (default). full: locals + usage + full partial source."
          }
        },
        required: [ "partial" ]
      )

      annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true, open_world_hint: false)

      def self.call(partial:, detail: "standard", server_context: nil)
        # Guard: required parameter
        if partial.nil? || partial.strip.empty?
          return text_response("The `partial` parameter is required. Provide a partial path relative to app/views (e.g. 'shared/status_badge').")
        end

        # Reject path traversal attempts
        if partial.include?("..") || partial.start_with?("/")
          return text_response("Path not allowed: #{partial}")
        end

        root = Rails.root.to_s
        views_dir = File.join(root, "app", "views")

        unless Dir.exist?(views_dir)
          return text_response("No app/views/ directory found.")
        end

        # Resolve partial to actual file path
        file_path = resolve_partial_path(views_dir, partial)

        unless file_path
          available = find_available_partials(views_dir, root)
          return not_found_response("Partial", partial, available,
            recovery_tool: "Call rails_get_view(detail:\"summary\") to see all views and partials")
        end

        if File.size(file_path) > max_file_size
          return text_response("Partial file too large: #{file_path} (#{File.size(file_path)} bytes, max: #{max_file_size})")
        end

        source = safe_read(file_path)
        return text_response("Could not read partial file.") unless source

        relative_path = file_path.sub("#{root}/", "")
        partial_name = file_path.sub("#{views_dir}/", "")

        # Parse the partial's interface
        magic_locals = extract_magic_comment_locals(source)
        render_sites = find_render_sites(views_dir, partial, root)
        method_calls = {}

        # Primary: locals from render call sites (ground truth)
        render_locals = render_sites.flat_map { |rs| rs[:locals] || [] }.uniq

        # Secondary: local_assigns checks + defined? guards in partial source
        source_locals = extract_local_variable_references(source)

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
        when "standard"
          format_standard(partial_name, relative_path, source, all_locals, magic_locals, render_sites, method_calls)
        when "full"
          format_full(partial_name, relative_path, source, all_locals, magic_locals, render_sites, method_calls)
        else
          text_response("Unknown detail level: #{detail}. Use summary, standard, or full.")
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

        lines << "**Rendered from:** #{render_sites.size} location(s)"
        lines << ""
        lines << "_Use `detail:\"standard\"` for usage examples, or `detail:\"full\"` for full partial source._"

        text_response(lines.join("\n"))
      end

      private_class_method def self.format_standard(partial_name, relative_path, source, all_locals, magic_locals, render_sites, method_calls)
        lines = [ "# Partial: #{partial_name}", "" ]
        lines << "**File:** `#{relative_path}` (#{source.lines.size} lines)"

        # Magic comment locals
        if magic_locals.any?
          lines << "**Declared locals** (Rails 7.1+ magic comment): #{magic_locals.join(', ')}"
        end

        # All locals with method calls
        if all_locals.any?
          lines << "" << "## Local Variables"
          all_locals.each do |local|
            methods = method_calls[local]
            if methods&.any?
              lines << "- **#{local}** — calls: #{methods.first(10).join(', ')}"
            else
              lines << "- **#{local}**"
            end
          end
        else
          lines << "" << "_No local variables detected in this partial._"
        end

        # Render sites with locals passed
        if render_sites.any?
          lines << "" << "## Rendered From (#{render_sites.size})"
          render_sites.first(15).each do |site|
            locals_str = site[:locals].any? ? " — locals: #{site[:locals].join(', ')}" : ""
            lines << "- `#{site[:file]}:#{site[:line]}`#{locals_str}"
          end
          if render_sites.size > 15
            lines << "- _...and #{render_sites.size - 15} more_"
          end
        else
          lines << "" << "_No render calls found for this partial._"
        end

        # Cross-reference hints
        lines << ""
        lines << "_Next: `rails_get_view(path:\"#{partial_name}\")` for full file content_"

        text_response(lines.join("\n"))
      end

      private_class_method def self.format_full(partial_name, relative_path, source, all_locals, magic_locals, render_sites, method_calls)
        lines = [ "# Partial: #{partial_name}", "" ]
        lines << "**File:** `#{relative_path}` (#{source.lines.size} lines)"

        # Magic comment locals
        if magic_locals.any?
          lines << "**Declared locals** (Rails 7.1+ magic comment): #{magic_locals.join(', ')}"
        end

        # All locals with method calls
        if all_locals.any?
          lines << "" << "## Local Variables"
          all_locals.each do |local|
            methods = method_calls[local]
            if methods&.any?
              lines << "- **#{local}** — calls: #{methods.join(', ')}"
            else
              lines << "- **#{local}**"
            end
          end
        end

        # Render sites with locals passed
        if render_sites.any?
          lines << "" << "## Rendered From (#{render_sites.size})"
          render_sites.first(25).each do |site|
            locals_str = site[:locals].any? ? " — locals: #{site[:locals].join(', ')}" : ""
            lines << "- `#{site[:file]}:#{site[:line]}`#{locals_str}"
            if site[:snippet]
              lines << "  ```erb"
              lines << "  #{site[:snippet].strip}"
              lines << "  ```"
            end
          end
          if render_sites.size > 25
            lines << "- _...and #{render_sites.size - 25} more_"
          end
        end

        # Full partial source
        lines << "" << "## Source"
        lines << "```erb"
        lines << source
        lines << "```"

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

        extensions = %w[.html.erb .erb .html.haml .haml .html.slim .slim .rb .json.jbuilder .jbuilder .turbo_stream.erb]
        candidates = []

        # Try prefixed name with various extensions
        extensions.each do |ext|
          candidates << File.join(views_dir, *dir_parts, "#{prefixed_basename}#{ext}")
          candidates << File.join(views_dir, *dir_parts, "#{unprefixed_basename}#{ext}")
        end

        # Also try the exact path as given
        candidates << File.join(views_dir, partial)

        found = candidates.find { |c| File.exist?(c) }

        # Fallback: if no directory was specified and direct lookup failed,
        # search recursively for the partial across all view directories
        if found.nil? && dir_parts.empty?
          extensions.each do |ext|
            matches = Dir.glob(File.join(views_dir, "**", "#{prefixed_basename}#{ext}"))
            if matches.any?
              found = matches.first
              break
            end
          end
        end

        return nil unless found

        # Path traversal protection
        begin
          unless File.realpath(found).start_with?(File.realpath(views_dir))
            return nil
          end
        rescue Errno::ENOENT
          return nil
        end

        found
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
        $stderr.puts "[rails-ai-context] extract_magic_comment_locals failed: #{e.message}" if ENV["DEBUG"]
        []
      end

      # Extract local variable references from ERB source.
      # Locals are variables NOT prefixed with @ and NOT known Ruby/Rails globals.
      private_class_method def self.extract_local_variable_references(source)
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

        # High-confidence local detection only — avoids false positives from HTML/CSS text
        source.scan(/<%[=\-]?\s*(.+?)\s*-?%>/m).each do |match|
          code = match[0]
          next if code.start_with?("#")

          # 1. Standalone ERB output: <%= local_name %> or <%= local_name.method %>
          if (m = code.match(/\A\s*([a-z_]\w*)\s*(?:\z|\.|\()/))
            name = m[1]
            locals << name unless known_non_locals.include?(name)
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
        $stderr.puts "[rails-ai-context] extract_local_variable_references failed: #{e.message}" if ENV["DEBUG"]
        []
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

        view_files = Dir.glob(File.join(views_dir, "**", "*.{erb,haml,slim}")).sort

        view_files.each do |file|
          next if File.size(file) > max_file_size
          content = safe_read(file)
          next unless content

          relative = file.sub("#{root}/", "")

          content.each_line.with_index(1) do |line, line_num|
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
                snippet: line.strip
              }
              break # one match per line is enough
            end
          end
        end

        sites
      rescue => e
        $stderr.puts "[rails-ai-context] find_render_sites failed: #{e.message}" if ENV["DEBUG"]
        []
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
        $stderr.puts "[rails-ai-context] extract_locals_from_render failed: #{e.message}" if ENV["DEBUG"]
        []
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
        $stderr.puts "[rails-ai-context] extract_method_calls_on_locals failed: #{e.message}" if ENV["DEBUG"]
        {}
      end

      # Find available partials for fuzzy matching in not_found_response.
      private_class_method def self.find_available_partials(views_dir, root)
        Dir.glob(File.join(views_dir, "**", "_*")).select { |f| File.file?(f) }.map do |f|
          relative = f.sub("#{views_dir}/", "")
          # Strip underscore prefix and extension for display
          parts = relative.split("/")
          parts[-1] = parts[-1].delete_prefix("_").sub(/\..*\z/, "")
          parts.join("/")
        end.sort.first(30)
      rescue => e
        $stderr.puts "[rails-ai-context] find_available_partials failed: #{e.message}" if ENV["DEBUG"]
        []
      end
    end
  end
end
