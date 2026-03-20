# frozen_string_literal: true

module RailsAiContext
  module Tools
    class GetEditContext < BaseTool
      tool_name "rails_get_edit_context"
      description "Get just enough context to make a surgical Edit to a file. Returns the target area with line numbers and surrounding code. Purpose-built to replace Read + Edit workflow with a single call."

      MAX_FILE_SIZE = 2_000_000

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
        full_path = Rails.root.join(file)

        # Path traversal protection (resolves symlinks)
        unless File.exist?(full_path)
          return text_response("File not found: #{file}")
        end
        begin
          unless File.realpath(full_path).start_with?(File.realpath(Rails.root))
            return text_response("Path not allowed: #{file}")
          end
        rescue Errno::ENOENT
          return text_response("File not found: #{file}")
        end
        if File.size(full_path) > MAX_FILE_SIZE
          return text_response("File too large: #{file}")
        end

        source_lines = File.readlines(full_path)
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
        if method_start && method_end
          start_idx = [ start_idx, method_start ].min
          end_idx = [ end_idx, method_end ].max
        end

        context_code = source_lines[start_idx..end_idx].map.with_index do |line, i|
          "#{(start_idx + i + 1).to_s.rjust(4)}  #{line.rstrip}"
        end.join("\n")

        output = [ "# #{file} (lines #{start_idx + 1}-#{end_idx + 1} of #{source_lines.size})", "" ]
        output << "```ruby"
        output << context_code
        output << "```"
        output << ""
        output << "_Use the code between lines #{start_idx + 1}-#{end_idx + 1} as old_string for Edit._"

        if matches.size > 1
          other = matches[1..4].map { |i| "line #{i + 1}" }.join(", ")
          output << "_Also found '#{near}' at: #{other}_"
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
        depth = 0
        lines[from_idx..].each_with_index do |line, i|
          depth += line.scan(/\b(?:def|do|if|unless|case|begin|class|module)\b/).size
          depth -= line.scan(/\bend\b/).size
          return from_idx + i if depth <= 0
        end
        nil
      end
    end
  end
end
