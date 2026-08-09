# frozen_string_literal: true

require "open3"
require "erb"
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

      annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true, open_world_hint: false)

      # ── Main entry point ─────────────────────────────────────────────

      VALID_LEVELS = %w[syntax rails].freeze

      def self.call(files:, level: "syntax", server_context: nil)
        return text_response("No files provided. Pass file paths relative to Rails root (e.g. files:[\"app/models/post.rb\"]).") if files.nil? || files.empty?
        return text_response("Too many files (#{files.size}). Maximum is #{max_files} per call.") if files.size > max_files
        return text_response("Unknown level: '#{level}'. Valid values: #{VALID_LEVELS.join(', ')}") unless VALID_LEVELS.include?(level)

        results = []
        passed = 0
        total = 0

        files.each do |file|
          if file.nil? || file.strip.empty?
            results << "- (empty) - skipped (empty filename)"
            next
          end

          # Block sensitive files on the caller-supplied string BEFORE any
          # filesystem stat. Closes the existence-oracle side channel where
          # an attacker could distinguish "file not found" from "access denied"
          # for a path like config/master.key. Mirrors get_edit_context.rb
          # ordering. v5.8.1 round 2 hardening.
          if sensitive_file?(file)
            results << "\u2717 #{file} - access denied (sensitive file)"
            total += 1
            next
          end

          full_path = rails_app.root.join(file)

          unless File.exist?(full_path)
            suggestion = find_file_suggestion(file)
            hint = suggestion ? " Did you mean '#{suggestion}'?" : ""
            results << "\u2717 #{file} - file not found.#{hint}"
            total += 1
            next
          end

          begin
            real = File.realpath(full_path).to_s
            rails_root_real = File.realpath(rails_app.root).to_s
            # Separator-aware containment - matches the v5.8.1-r2 hardening in
            # get_view.rb / vfs.rb. Without `+ File::SEPARATOR`, a sibling-dir
            # like `/app/rails_evil/...` would prefix-match a Rails root at
            # `/app/rails`. Same bug class as the original C1.
            unless real == rails_root_real || real.start_with?(rails_root_real + File::SEPARATOR)
              results << "\u2717 #{file} - path not allowed (outside Rails root)"
              total += 1
              next
            end
            # Defense-in-depth: re-run sensitive_file? on the resolved path.
            # Catches symlinks pointing into sensitive territory from a
            # non-sensitive caller string (e.g. app/views/leak.html.erb →
            # ../../config/master.key).
            relative_real = real.sub("#{rails_root_real}/", "")
            if sensitive_file?(relative_real)
              results << "\u2717 #{file} - access denied (resolves to sensitive file)"
              total += 1
              next
            end
          rescue Errno::ENOENT
            results << "\u2717 #{file} - file not found"
            total += 1
            next
          end

          total += 1

          real_path = Pathname.new(real)
          ok, msg, warnings = if file.end_with?(".rb")
            validate_ruby(real_path)
          elsif file.end_with?(".html.erb") || file.end_with?(".erb")
            validate_erb(real_path)
          elsif file.end_with?(".js")
            validate_javascript(real_path)
          else
            results << "- #{file} - skipped (unsupported file type)"
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
        end

        # Run Brakeman security scan on validated files (if installed and level:"rails")
        if level == "rails"
          brakeman_warnings = ValidateSemantics.check_brakeman_security(files)
          brakeman_warnings.each { |w| results << "  \u26A0 #{w}" }
        end

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
        $stderr.puts "[rails-ai-context] find_file_suggestion failed: #{e.message}" if ENV["DEBUG"]
        nil
      end

      private_class_method def self.validate_ruby(full_path)
        validate_ruby_prism(full_path)
      end

      private_class_method def self.validate_ruby_prism(full_path)
        result = AstCache.parse(full_path.to_s)
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
          [ false, errors.join("\n"), warnings ]
        end
      rescue => _e
        validate_ruby_subprocess(full_path)
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

        result = AstCache.parse_string(compiled)
        if result.success?
          [ true, nil, [] ]
        else
          error = result.errors.first(5).map do |e|
            "line #{[ e.location.start_line - 2, 1 ].max}: #{e.message}"
          end.join("\n")
          [ false, error, [] ]
        end
      rescue => e
        [ false, "ERB check error: #{e.message}", [] ]
      end

      # ── JavaScript validation ────────────────────────────────────────

      private_class_method def self.validate_javascript(full_path)
        @node_available = system("which", "node", out: File::NULL, err: File::NULL) if @node_available.nil?

        if @node_available
          result, status = Open3.capture2e("node", "-c", full_path.to_s)
          if status.success?
            [ true, nil, [] ]
          else
            error_lines = result.lines.reject { |l| l.strip.empty? }.first(3)
              .map { |l| l.strip.sub(full_path.to_s, File.basename(full_path.to_s)) }
            [ false, error_lines.any? ? error_lines.join("\n") : "syntax error", [] ]
          end
        else
          validate_javascript_fallback(full_path)
        end
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

        stack.empty? ? [ true, nil, [] ] : [ false, "unmatched '#{stack.last}' (node not available, basic check only)", [] ]
      end

      # ════════════════════════════════════════════════════════════════════
      # ── Rails-aware semantic checks (level: "rails") ─────────────────
      # ════════════════════════════════════════════════════════════════════

      # Prism AST Visitor - walks the AST once, extracts data for all checks
    end
  end
end
