# frozen_string_literal: true

module RailsAiContext
  module Tools
    class GetEditContext < BaseTool
      tool_name "rails_get_edit_context"
      description "Get targeted code context for surgical edits: returns matching lines with surrounding code and line numbers. " \
        "Use when: you need to edit a specific method or section without reading the entire file. " \
        "Requires file:\"app/models/user.rb\" and near:\"def activate\" to locate the code region."

      input_schema(
        properties: {
          file: {
            type: "string",
            description: "File path relative to Rails root (e.g. 'app/models/cook.rb', 'app/controllers/cooks_controller.rb')."
          },
          near: {
            type: "string",
            description: "What to find in the file — a method name, keyword, or string to locate (e.g. 'scope', 'def index', 'validates', 'STATUSES')."
          },
          context_lines: {
            type: "integer",
            description: "Lines of context above and below the match. Default: 5."
          }
        },
        required: %w[file near]
      )

      annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true, open_world_hint: false)

      def self.call(file:, near:, context_lines: 5, server_context: nil)
        # Reject empty parameters
        if file.nil? || file.strip.empty?
          return text_response("The `file` parameter is required. Provide a path relative to Rails root (e.g. 'app/models/cook.rb').")
        end

        if near.nil? || near.strip.empty?
          return text_response("The `near` parameter is required. Provide a method name, keyword, or string to find.")
        end

        full_path = Rails.root.join(file)

        # Block access to sensitive files (secrets, keys, credentials)
        if sensitive_file?(file)
          return text_response("Access denied: #{file} is a sensitive file (secrets/keys/credentials).")
        end

        # Path traversal protection (resolves symlinks)
        unless File.exist?(full_path)
          # Try to find a matching file to suggest
          basename = File.basename(file)
          candidates = Dir.glob(File.join(Rails.root, "app", "**", basename)).first(5)
          hint = if candidates.any?
            suggestions = candidates.map { |c| c.sub("#{Rails.root}/", "") }
            " Did you mean: #{suggestions.join(', ')}? Use the full path relative to Rails root."
          else
            " Use the full path relative to Rails root (e.g., 'app/models/#{basename}')."
          end
          return text_response("File not found: #{file}.#{hint}")
        end
        begin
          unless File.realpath(full_path).start_with?(File.realpath(Rails.root))
            return text_response("Path not allowed: #{file}")
          end
        rescue Errno::ENOENT
          return text_response("File not found: #{file}")
        end
        if File.size(full_path) > max_file_size
          return text_response("File too large: #{file}")
        end

        source_lines = (RailsAiContext::SafeFile.read(full_path) || "").lines
        context_lines = [ context_lines.to_i, 0 ].max

        # Find all matching lines
        matches = []
        source_lines.each_with_index do |line, idx|
          matches << idx if line.include?(near) || line.match?(/\b#{Regexp.escape(near)}\b/)
        end

        if matches.empty?
          return text_response("'#{near}' not found in #{file} (#{source_lines.size} lines).\n\nAvailable methods:\n#{extract_methods(source_lines)}")
        end

        # Build context window around first match
        match_idx = matches.first
        start_idx = [ match_idx - context_lines, 0 ].max
        end_idx = [ match_idx + context_lines, source_lines.size - 1 ].min

        # If match is inside a method, expand to include the full method
        method_start = find_method_start(source_lines, match_idx)
        method_end = find_method_end(source_lines, method_start) if method_start
        if method_start && method_end && source_lines[match_idx].match?(/\A\s*def\s/)
          # Match IS a method definition — show the complete method, no extra context
          start_idx = method_start
          end_idx = method_end
        elsif method_start && method_end
          # Match is inside a method — expand to include full method + context
          start_idx = [ start_idx, method_start ].min
          end_idx = [ end_idx, method_end ].max
        end

        context_code = source_lines[start_idx..end_idx].map.with_index do |line, i|
          "#{(start_idx + i + 1).to_s.rjust(4)}  #{line.rstrip}"
        end.join("\n")

        lang = case file
        when /\.rb$/ then "ruby"
        when /\.js$/ then "javascript"
        when /\.erb$/ then "erb"
        when /\.yml$/, /\.yaml$/ then "yaml"
        else ""
        end

        # Detect enclosing class and method for context
        class_name = source_lines[0..match_idx].reverse.find { |l| l.match?(/\A\s*(class|module)\s/) }&.strip&.sub(/\s*<.*/, "")
        method_name = method_start ? source_lines[method_start].strip.sub(/\s*\(.*/, "").sub(/\Adef\s+/, "def ") : nil
        context_label = [ class_name, method_name ].compact.join(" > ")

        output = [ "# #{file} (lines #{start_idx + 1}-#{end_idx + 1} of #{source_lines.size})", "" ]
        output << "**Context:** `#{context_label}`" unless context_label.empty?
        output << "```#{lang}"
        output << context_code
        output << "```"
        output << ""
        output << "_Use the code between lines #{start_idx + 1}-#{end_idx + 1} as old_string for Edit._"

        if matches.size > 1
          outside = matches[1..].select { |i| i < start_idx || i > end_idx }
          if outside.any?
            other = outside.first(4).map { |i| "line #{i + 1}" }.join(", ")
            output << "_Also found '#{near}' at: #{other}_"
          end
        end

        text_response(output.join("\n"))
      end


      private_class_method def self.extract_methods(source_lines)
        methods = []
        source_lines.each_with_index do |line, idx|
          if line.match?(/^\s*def\s+/)
            name = line.strip.sub(/^def\s+/, "").sub(/[\s(].*/, "")
            methods << "- `#{name}` (line #{idx + 1})"
          end
        end
        methods.empty? ? "  (no methods found)" : methods.join("\n")
      end

      private_class_method def self.find_method_start(lines, from_idx)
        from_idx.downto(0) do |i|
          return i if lines[i].match?(/^\s*def\s+/)
        end
        nil
      end

      private_class_method def self.find_method_end(lines, from_idx)
        # Use indentation-based matching — the `end` for a `def` is always at the same indent level.
        # This is much more reliable than regex depth counting which miscounts inline if/unless modifiers.
        def_indent = lines[from_idx][/\A\s*/]&.length || 0
        lines[(from_idx + 1)..].each_with_index do |line, i|
          return from_idx + i + 1 if line.match?(/\A\s{#{def_indent}}end\b/)
        end
        nil
      end
    end
  end
end
