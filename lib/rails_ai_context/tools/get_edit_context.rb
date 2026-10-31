# frozen_string_literal: true

module RailsAiContext
  module Tools
    class GetEditContext < BaseTool
      tool_name "rails_get_edit_context"
      description "Get targeted code context for surgical edits: returns matching lines with surrounding code and line numbers. " \
        "Use when: you need to edit a specific method or section without reading the entire file. " \
        "Requires file:\"app/models/user.rb\" and near:\"def activate\" (or line:42) to locate the code region."

      input_schema(
        properties: {
          file: {
            type: "string",
            description: "File path relative to Rails root (e.g. 'app/models/post.rb', 'app/controllers/posts_controller.rb')."
          },
          near: {
            type: "string",
            description: "What to find in the file - a method name, keyword, or string to locate (e.g. 'scope', 'def index', 'validates', 'STATUSES')."
          },
          context_lines: {
            type: "integer",
            description: "Lines of context above and below the match. Default: 5."
          },
          line: {
            type: "integer",
            description: "Show context_lines either side of this line number instead of searching for `near` (e.g. a line from a stack trace)."
          }
        },
        required: %w[file]
      )

      guide_row(
        order: 14,
        mcp: "rails_get_edit_context(file:\"X\", near:\"Y\")",
        cli_args: "file=X near=Y",
        summary: "Code around a match with class/method context"
      )

      annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true, open_world_hint: false)

      def self.call(file:, near: nil, context_lines: 5, line: nil, server_context: nil)
        # Reject empty parameters
        if file.nil? || file.strip.empty?
          return text_response("The `file` parameter is required. Provide a path relative to Rails root (e.g. 'app/models/post.rb').")
        end

        if line.nil? && (near.nil? || near.strip.empty?)
          return text_response("The `near` or `line` parameter is required. Provide a method name, keyword, or string to find, or a line number.")
        end

        located = RailsAiContext::SafePath.locate(file, under: rails_app.root.to_s)
        case located.refusal
        when :traversal, :outside then return error_response("Path not allowed: #{echo_input(file)}")
        when :sensitive then return error_response("Path not allowed: #{echo_input(file)} (sensitive file)")
        when :too_large then return text_response("File too large: #{file}")
        when :missing
          root = rails_app.root.to_s
          basename = File.basename(file)
          asked = File.expand_path(file, root)
          # Files of that name the tool would read, never the path asked for:
          # a link that resolves nowhere is not a file to retry.
          candidates = RailsAiContext::FileWalk.each_file(File.join(root, "app"), root: root)
            .select { |path| File.basename(path) == basename && path != asked }.sort.first(5)
          hint = if candidates.any?
            suggestions = candidates.map { |c| c.delete_prefix("#{root}/") }
            " Did you mean: #{suggestions.join(', ')}? Use the full path relative to Rails root."
          else
            # An example built from the name the caller gave was that same
            # path back for `app/models/nope.rb`, read as a file to retry.
            " No file named #{echo_input(basename)} is under app/."
          end
          return empty_response("File not found: #{echo_input(file)}.#{hint}")
        end
        real = located.realpath

        source_lines = (RailsAiContext::SafeFile.read(real) || "").lines
        context_lines = [ context_lines.to_i, 0 ].max

        # Source leaving the app passes through Redaction, the whole file at once, so a window
        # opening inside a PEM key still knows it is inside one. `near` is looked for in the lines
        # as the caller sees them: found in the file as written, a guess at a filtered value's
        # start brought back a window where a wrong guess brought "not found".
        redacted = RailsAiContext::Redaction.redact_source_lines(source_lines.map(&:rstrip), path: located.relative)

        at_line = line.to_i.between?(1, source_lines.size)
        matches = if at_line
          [ line.to_i - 1 ]
        elsif near.nil? || near.strip.empty?
          return empty_response("Line #{echo_input(line.to_s)} is not in #{file} (#{count_phrase(source_lines.size, "line")}).")
        else
          redacted.each_index.select { |idx| redacted[idx].include?(near) }
        end

        if matches.empty?
          return empty_response("'#{echo_input(near)}' not found in #{file} (#{count_phrase(source_lines.size, "line")}).\n\nAvailable methods:\n#{extract_methods(file, source_lines)}")
        end

        # Build context window around first match
        match_idx = matches.first
        start_idx = [ match_idx - context_lines, 0 ].max
        end_idx = [ match_idx + context_lines, source_lines.size - 1 ].min

        # If match is inside a method, expand to include the full method; a line asked for keeps its
        # window, which a 300-line method would push out of a caller's cut.
        method = enclosing_method(file, source_lines, match_idx)
        method_start, method_end = method && [ method[:location] - 1, method[:end_location] - 1 ]
        if method && !at_line && match_idx == method_start
          # Match IS a method definition - show the complete method, no extra context
          start_idx = method_start
          end_idx = method_end
        elsif method && !at_line
          # Match is inside a method - expand to include full method + context
          start_idx = [ start_idx, method_start ].min
          end_idx = [ end_idx, method_end ].max
        end

        context_code = redacted[start_idx..end_idx].map.with_index do |line, i|
          "#{(start_idx + i + 1).to_s.rjust(4)}  #{line}"
        end.join("\n")

        lang = case file
        when /\.rb$/ then "ruby"
        when /\.js$/ then "javascript"
        when /\.erb$/ then "erb"
        when /\.yml$/, /\.yaml$/ then "yaml"
        else ""
        end

        # Detect enclosing class and method for context, named from the redacted lines: an endless
        # method's line is its whole body (`def headers = { "Authorization" => "Bearer ..." }`), and
        # the label keeps its name alone.
        class_name = enclosing_class(file, source_lines, match_idx, redacted)
        method_name = method_start ? redacted[method_start].strip.sub(/\s*\(.*/, "").sub(/\s+=\s.*/, "").sub(/\Adef\s+/, "def ") : nil
        context_label = [ class_name, method_name ].compact.join(" > ")

        output = [ "# #{file} (lines #{start_idx + 1}-#{end_idx + 1} of #{source_lines.size})", "" ]
        output << "**Context:** `#{context_label}`" unless context_label.empty?
        output << "```#{lang}"
        output << context_code
        output << "```"
        output << ""
        output << "_Lines #{start_idx + 1}-#{end_idx + 1} shown; strip the line-number prefixes before using the code as old_string for Edit._"

        if matches.size > 1
          outside = matches[1..].select { |i| i < start_idx || i > end_idx }
          if outside.any?
            other = outside.first(4).map { |i| "line #{i + 1}" }.join(", ")
            output << "_Also found '#{near}' at: #{other}_"
          end
        end

        text_response(output.join("\n"))
      end


      private_class_method def self.extract_methods(file, source_lines)
        source = source_lines.join
        code_lines = ruby?(file, source) ? RailsAiContext::RubySource.code_only(source).lines : source_lines
        methods = []
        source_lines.each_with_index do |line, idx|
          if code_lines[idx].to_s.match?(/^\s*def\s+/)
            name = line.strip.sub(/^def\s+/, "").sub(/[\s(].*/, "")
            methods << "- `#{name}` (line #{idx + 1})"
          end
        end
        methods.empty? ? "  (no methods found)" : methods.join("\n")
      end

      # The innermost method whose lines, as Prism reads them, hold the match; nil outside every method.
      private_class_method def self.enclosing_method(file, source_lines, match_idx)
        source = source_lines.join
        return nil unless ruby?(file, source)

        line = match_idx + 1
        Introspectors::ActionResolver.methods_in(source)
          .select { |m| m[:location] && m[:end_location] && (m[:location]..m[:end_location]).cover?(line) }
          .min_by { |m| m[:end_location] - m[:location] }
      end

      # The innermost class or module holding the match, as written; a `class << self` body is its class's.
      private_class_method def self.enclosing_class(file, source_lines, match_idx, redacted)
        source = source_lines.join
        unless ruby?(file, source)
          class_idx = match_idx.downto(0).find { |i| source_lines[i].match?(/\A\s*(class|module)\s/) }
          return class_idx && redacted[class_idx].strip.sub(/\s*<.*/, "")
        end

        Introspectors::DeclaredConstant.enclosing(source, match_idx + 1)
      end

      # A .rake, Gemfile or .jbuilder is Ruby too, read only when it parses whole: error recovery finds a def in YAML's `def:` key.
      private_class_method def self.ruby?(file, source)
        file.end_with?(".rb") || RailsAiContext::AstCache.parse_string(source).success?
      end
    end
  end
end
