# frozen_string_literal: true

require "open3"
require "erb"
require "json"
require "set"
require "prism"

module RailsAiContext
  module Tools
    class Validate < BaseTool
      tool_name "rails_validate"
      description "Validate syntax and semantics of Ruby, ERB, and JavaScript files in a single call. " \
        "Use when: after editing files, before committing, to catch syntax errors and Rails-specific issues. " \
        "Pass files:[\"app/models/user.rb\"], use level:\"rails\" for semantic checks (missing partials, route helpers, " \
        "column refs in validates/permit/callbacks)."

      def self.max_files
        RailsAiContext.configuration.max_validate_files
      end

      input_schema(
        properties: {
          files: {
            type: "array",
            items: { type: "string" },
            description: "File paths relative to Rails root (e.g. ['app/models/post.rb', 'app/views/posts/index.html.erb'])"
          },
          level: {
            type: "string",
            enum: %w[syntax rails],
            description: "Validation level. syntax: check syntax only (default, fast). rails: syntax + semantic checks (partial existence, route helpers, column refs in validates/permit/callbacks)."
          }
        },
        required: %w[files]
      )

      guide_row(
        order: 5,
        mcp: "rails_validate(files:[...], level:\"rails\")",
        cli_args: "files=a.rb,b.rb level=rails",
        summary: "Syntax + semantic validation (run after EVERY edit)"
      )

      annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true, open_world_hint: false)

      # ── Main entry point ─────────────────────────────────────────────

      VALID_LEVELS = %w[syntax rails].freeze

      def self.call(files:, level: "syntax", server_context: nil)
        # Both spellings, because the JSON form this used to suggest is not
        # something the CLI accepts - following the advice produced
        # "file not found" with the literal brackets in the name.
        if files.nil? || files.empty?
          return text_response(
            "No files provided. Pass paths relative to Rails root - " \
            "CLI: `--files app/models/post.rb app/models/user.rb`, " \
            "MCP: `files: [\"app/models/post.rb\"]`."
          )
        end
        return text_response("Too many files (#{files.size}). Maximum is #{max_files} per call.") if files.size > max_files
        return text_response("Unknown level: '#{level}'. Valid values: #{VALID_LEVELS.join(', ')}") unless VALID_LEVELS.include?(level)

        results = []
        passed = 0
        total = 0
        # Brakeman scans the app once, so findings are grouped by file before the loop and print
        # under their own file.
        brakeman = level == "rails" ? ValidateSemantics.check_brakeman_security(files) : {}

        files.each do |file|
          if file.nil? || file.strip.empty?
            results << "- (empty) - skipped (empty filename)"
            next
          end

          located = RailsAiContext::SafePath.locate(file, under: rails_app.root.to_s)
          case located.refusal
          when :sensitive then results << "\u2717 #{file} - access denied (sensitive file)"
          when :traversal, :outside then results << "\u2717 #{file} - path not allowed (outside Rails root)"
          when :too_large then results << "\u2717 #{file} - file too large"
          when :missing
            suggestion = find_file_suggestion(file)
            hint = suggestion ? " Did you mean '#{suggestion}'?" : ""
            results << "\u2717 #{file} - file not found.#{hint}"
          end

          total += 1
          next unless located.ok?

          real_path = Pathname.new(located.realpath)
          ok, msg, warnings = if file.end_with?(".rb")
            validate_ruby(real_path)
          elsif file.end_with?(".html.erb") || file.end_with?(".erb")
            validate_erb(real_path)
          elsif file.end_with?(*JAVASCRIPT_EXTENSIONS)
            validate_javascript(real_path)
          else
            results << "- #{file} - skipped (unsupported file type)"
            total -= 1
            next
          end

          # A check that could not judge the file says why rather than passing it.
          if ok == :skipped
            results << "- #{file} - skipped (#{msg})"
            total -= 1
            next
          end

          if ok
            results << "\u2713 #{file} - syntax OK"
            passed += 1
          else
            results << "\u2717 #{file} - #{msg}"
          end

          (warnings || []).each { |w| results << "  \u26A0 #{w}" }

          if level == "rails" && ok
            rails_warnings = ValidateSemantics.check_rails_semantics(file, real_path)
            rails_warnings.each { |w| results << "  \u26A0 #{w}" }
          end

          brakeman.delete(file)&.each { |w| results << "  \u26A0 #{w}" }
        end

        # A finding for a file the loop never printed a heading for. The
        # message names the file, and no indent claims it for another.
        brakeman.each_value { |found| found.each { |w| results << "\u26A0 #{w}" } }

        output = results.join("\n")
        output += "\n\n#{passed}/#{total} files passed"
        # A failed validation is the tool's core negative verdict, not
        # advisory guidance - flag it as an MCP error so CLI callers exit
        # non-zero. Mirrors the SQL-error promotion in query.rb.
        return error_response(output) if passed < total

        text_response(output)
      end

      # ── Ruby validation ──────────────────────────────────────────────

      # Search common Rails directories for a file by basename and suggest the full path
      private_class_method def self.find_file_suggestion(file)
        basename = File.basename(file)
        %w[app/models app/controllers app/views app/helpers app/jobs app/mailers
           app/services app/channels lib config].each do |dir|
          candidate = File.join(dir, basename)
          return candidate if File.exist?(rails_app.root.join(candidate))
        end

        # Broader recursive search
        matches = Dir.glob(File.join(rails_app.root, "app", "**", basename)).first(1)
        return matches.first.sub("#{rails_app.root}/", "") if matches.any?

        nil
      rescue => e
        RailsAiContext.debug_fail(e, nil, label: "find_file_suggestion")
      end

      private_class_method def self.validate_ruby(full_path)
        validate_ruby_prism(full_path)
      end

      private_class_method def self.validate_ruby_prism(full_path)
        result = AstCache.parse(full_path.to_s, ruby: app_ruby_version)
        basename = File.basename(full_path.to_s)
        warnings = result.warnings.map do |w|
          "#{basename}:#{w.location.start_line}:#{w.location.start_column}: warning: #{w.message}"
        end

        if result.success?
          [ true, nil, warnings ]
        else
          errors = result.errors.first(5).map do |e|
            "#{basename}:#{e.location.start_line}:#{e.location.start_column}: #{e.message}"
          end
          [ false, errors.join("\n") + grammar_note, warnings ]
        end
      rescue => _e
        validate_ruby_subprocess(full_path)
      end

      # Booted, the interpreter running this is the app's own; statically the app's declared Ruby, else this one.
      private_class_method def self.app_ruby_version
        (GemLock.for(rails_app.root.to_s).ruby_version if RailsAiContext.static_tier?) || RUBY_VERSION
      end

      # JRuby or TruffleRuby names its own version, not the Ruby it implements, so the
      # running Ruby's grammar may reject what the app's engine accepts.
      private_class_method def self.grammar_note
        return "" unless RailsAiContext.static_tier?

        lock = GemLock.for(rails_app.root.to_s)
        return "" if lock.ruby_version || lock.ruby_engine.nil?

        "\n(checked with Ruby #{RUBY_VERSION}'s grammar; the app declares #{lock.ruby_engine} and no Ruby version, " \
          "and that engine may implement an older Ruby)"
      end

      private_class_method def self.validate_ruby_subprocess(full_path)
        result, status = Open3.capture2e("ruby", "-c", full_path.to_s)
        if status.success?
          [ true, nil, [] ]
        else
          error_lines = result.lines
            .reject { |l| l.strip.empty? || l.include?("Syntax OK") }
            .first(5)
            .map { |l| l.strip.sub(full_path.to_s, File.basename(full_path.to_s)) }
          [ false, error_lines.any? ? error_lines.join("\n") : "syntax error", [] ]
        end
      end

      # ── ERB validation ───────────────────────────────────────────────

      private_class_method def self.validate_erb(full_path)
        return [ false, "file too large", [] ] if File.size(full_path) > RailsAiContext.configuration.max_file_size

        content = File.binread(full_path).force_encoding("UTF-8")
        processed = content.gsub("<%=", "<%")

        erb_src = +ERB.new(processed).src
        erb_src.force_encoding("UTF-8")
        compiled = "# encoding: utf-8\ndef __erb_syntax_check\n#{erb_src}\nend"

        result = AstCache.parse_string(compiled, ruby: app_ruby_version)
        if result.success?
          [ true, nil, [] ]
        else
          error = result.errors.first(5).map do |e|
            "line #{[ e.location.start_line - 2, 1 ].max}: #{e.message}"
          end.join("\n")
          [ false, error + grammar_note, [] ]
        end
      rescue => e
        [ false, "ERB check error: #{e.message}", [] ]
      end

      # ── JavaScript validation ────────────────────────────────────────

      JAVASCRIPT_EXTENSIONS = %w[.js .mjs .cjs].freeze

      # What CommonJS rejects only because the source is an ES module. Node
      # retries a .js file whose package declares no type as a module on
      # exactly these, so none of them is the file's own error.
      ESM_ONLY_SYNTAX = Regexp.union(
        "Cannot use import statement outside a module",
        "Unexpected token 'export'",
        "Cannot use 'import.meta' outside a module",
        "await is only valid in async functions and the top level bodies of modules",
        /Identifier '(?:module|exports|require|__filename|__dirname)' has already been declared/
      )

      # A tag opening where an expression should start is JSX, which node
      # does not parse, rather than a broken script.
      JSX_TAG = %r{<(?:/?[A-Za-z]|>)}

      # `node -c file.js` leaves the module system to Node, and for a .js file
      # whose package declares no type Node 22 decides it by retrying as a
      # module - a retry the check skips, so every Stimulus controller passed,
      # broken or not. The source goes to node on stdin with its type spelled
      # out, which parses it for real and writes nothing next to the app.
      private_class_method def self.validate_javascript(full_path)
        @node_available = system("which", "node", out: File::NULL, err: File::NULL) if @node_available.nil?
        return javascript_without_node(full_path) unless @node_available

        source = RailsAiContext::SafeFile.read(full_path)
        return [ false, "could not read file", [] ] unless source

        type = javascript_module_type(full_path)
        ok, output = node_check(source, type || "commonjs")
        ok, output = node_check(source, "module") if !ok && type.nil? && node_message(output).to_s.match?(ESM_ONLY_SYNTAX)
        return [ true, nil, [] ] if ok

        line = output[/^\[stdin\]:(\d+)$/, 1]&.to_i
        if node_message(output) == "SyntaxError: Unexpected token '<'" && line && source.lines[line - 1].to_s.match?(JSX_TAG)
          return [ :skipped, "line #{line} is JSX, which node does not parse" ]
        end

        [ false, node_error(output, line, File.basename(full_path.to_s)), [] ]
      end

      private_class_method def self.node_check(source, type)
        output, status = Open3.capture2e("node", "--check", "--input-type=#{type}", stdin_data: source)
        [ status.success?, output ]
      end

      # How Node itself decides: the extension, else the "type" of the nearest
      # package.json, looked for no higher than the app root. nil when that
      # package declares none, which is when Node tries both.
      private_class_method def self.javascript_module_type(full_path)
        case File.extname(full_path.to_s)
        when ".mjs" then return "module"
        when ".cjs" then return "commonjs"
        end

        root = File.realpath(rails_app.root.to_s)
        dir = File.dirname(full_path.to_s)
        while dir == root || dir.start_with?("#{root}/")
          manifest = File.join(dir, "package.json")
          if File.file?(manifest)
            type = (JSON.parse(RailsAiContext::SafeFile.read(manifest).to_s)["type"] rescue nil)
            return %w[module commonjs].include?(type) ? type : nil
          end
          dir = File.dirname(dir)
        end
        nil
      end

      # Node prints "[stdin]:LINE", the source line, a caret under the fault
      # and then "SyntaxError: message".
      private_class_method def self.node_message(output)
        output.lines.map(&:strip).find { |l| l.match?(/\A[A-Z]\w*Error: /) }
      end

      # Shaped like the Ruby check's answer: file:line:column: message.
      private_class_method def self.node_error(output, line, basename)
        message = node_message(output)
        unless line && message
          lines = output.lines.map(&:strip).reject(&:empty?).first(3).map { |l| l.gsub("[stdin]", basename) }
          return lines.any? ? lines.join("\n") : "syntax error"
        end

        caret = output.lines.map(&:chomp).find { |l| l.match?(/\A\s*\^+\s*\z/) }
        column = caret&.index("^")
        "#{basename}:#{line}#{":#{column}" if column}: #{message}"
      end

      # Without node, balanced brackets are all that is known, which is no
      # verdict on the syntax; an unmatched one still is.
      private_class_method def self.javascript_without_node(full_path)
        ok, message, = validate_javascript_fallback(full_path)
        return [ :skipped, "node is not installed, so only bracket balance was checked" ] if ok

        [ false, "#{message} (node is not installed; this is a bracket check only)", [] ]
      end

      private_class_method def self.validate_javascript_fallback(full_path)
        return [ false, "file too large for basic validation", [] ] if File.size(full_path) > RailsAiContext.configuration.max_file_size
        content = RailsAiContext::SafeFile.read(full_path)
        return [ false, "could not read file", [] ] unless content
        stack = []
        openers = { "{" => "}", "[" => "]", "(" => ")" }
        closers = { "}" => "{", "]" => "[", ")" => "(" }
        in_string = nil; in_line_comment = false; in_block_comment = false; escaped = false; prev_char = nil

        content.each_char.with_index do |char, i|
          if in_line_comment then (in_line_comment = false if char == "\n"); prev_char = char; next end
          if in_block_comment then (in_block_comment = false if prev_char == "*" && char == "/"); prev_char = char; next end
          if in_string
            if escaped then escaped = false
            elsif char == "\\" then escaped = true
            elsif char == in_string then in_string = nil
            end
            prev_char = char; next
          end

          case char
          when '"', "'", "`" then in_string = char
          when "/" then (in_line_comment = true; stack.pop if stack.last == "/") if prev_char == "/"
          when "*" then in_block_comment = true if prev_char == "/"
          else
            if openers.key?(char) then stack << char
            elsif closers.key?(char)
              return [ false, "line #{content[0..i].count("\n") + 1}: unmatched '#{char}'", [] ] if stack.empty? || stack.last != closers[char]
              stack.pop
            end
          end
          prev_char = char
        end

        stack.empty? ? [ true, nil, [] ] : [ false, "unmatched '#{stack.last}'", [] ]
      end
    end
  end
end
