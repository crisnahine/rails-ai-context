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
        "Pass files:[\"app/models/user.rb\"], use level:\"rails\" for semantic checks (missing partials, bad column refs, orphaned routes)."

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
            description: "Validation level. syntax: check syntax only (default, fast). rails: syntax + semantic checks (partial existence, route helpers, column references)."
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
            results << "- (empty) \u2014 skipped (empty filename)"
            next
          end

          # Block sensitive files on the caller-supplied string BEFORE any
          # filesystem stat. Closes the existence-oracle side channel where
          # an attacker could distinguish "file not found" from "access denied"
          # for a path like config/master.key. Mirrors get_edit_context.rb
          # ordering. v5.8.1 round 2 hardening.
          if sensitive_file?(file)
            results << "\u2717 #{file} \u2014 access denied (sensitive file)"
            total += 1
            next
          end

          full_path = Rails.root.join(file)

          unless File.exist?(full_path)
            suggestion = find_file_suggestion(file)
            hint = suggestion ? " Did you mean '#{suggestion}'?" : ""
            results << "\u2717 #{file} \u2014 file not found.#{hint}"
            total += 1
            next
          end

          begin
            real = File.realpath(full_path).to_s
            rails_root_real = File.realpath(Rails.root).to_s
            # Separator-aware containment — matches the v5.8.1-r2 hardening in
            # get_view.rb / vfs.rb. Without `+ File::SEPARATOR`, a sibling-dir
            # like `/app/rails_evil/...` would prefix-match a Rails root at
            # `/app/rails`. Same bug class as the original C1.
            unless real == rails_root_real || real.start_with?(rails_root_real + File::SEPARATOR)
              results << "\u2717 #{file} \u2014 path not allowed (outside Rails root)"
              total += 1
              next
            end
            # Defense-in-depth: re-run sensitive_file? on the resolved path.
            # Catches symlinks pointing into sensitive territory from a
            # non-sensitive caller string (e.g. app/views/leak.html.erb →
            # ../../config/master.key).
            relative_real = real.sub("#{rails_root_real}/", "")
            if sensitive_file?(relative_real)
              results << "\u2717 #{file} \u2014 access denied (resolves to sensitive file)"
              total += 1
              next
            end
          rescue Errno::ENOENT
            results << "\u2717 #{file} \u2014 file not found"
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
            results << "- #{file} \u2014 skipped (unsupported file type)"
            total -= 1
            next
          end

          if ok
            results << "\u2713 #{file} \u2014 syntax OK"
            passed += 1
          else
            results << "\u2717 #{file} \u2014 #{msg}"
          end

          (warnings || []).each { |w| results << "  \u26A0 #{w}" }

          if level == "rails" && ok
            rails_warnings = check_rails_semantics(file, real_path)
            rails_warnings.each { |w| results << "  \u26A0 #{w}" }
          end
        end

        # Run Brakeman security scan on validated files (if installed and level:"rails")
        if level == "rails"
          brakeman_warnings = check_brakeman_security(files)
          brakeman_warnings.each { |w| results << "  \u26A0 #{w}" }
        end

        output = results.join("\n")
        output += "\n\n#{passed}/#{total} files passed"
        text_response(output)
      end

      # ── Ruby validation ──────────────────────────────────────────────

      # Search common Rails directories for a file by basename and suggest the full path
      private_class_method def self.find_file_suggestion(file)
        basename = File.basename(file)
        %w[app/models app/controllers app/views app/helpers app/jobs app/mailers
           app/services app/channels lib config].each do |dir|
          candidate = File.join(dir, basename)
          return candidate if File.exist?(Rails.root.join(candidate))
        end

        # Broader recursive search
        matches = Dir.glob(File.join(Rails.root, "app", "**", basename)).first(1)
        return matches.first.sub("#{Rails.root}/", "") if matches.any?

        nil
      rescue => e
        $stderr.puts "[rails-ai-context] find_file_suggestion failed: #{e.message}" if ENV["DEBUG"]
        nil
      end

      private_class_method def self.validate_ruby(full_path)
        validate_ruby_prism(full_path)
      end

      private_class_method def self.validate_ruby_prism(full_path)
        result = Prism.parse_file(full_path.to_s)
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

        result = Prism.parse(compiled)
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

      # Prism AST Visitor — walks the AST once, extracts data for all checks
      class RailsSemanticVisitor < Prism::Visitor
        attr_reader :render_calls, :route_helper_calls, :validates_calls,
                    :permit_calls, :callback_registrations, :has_many_calls

        CALLBACK_NAMES = %i[
          before_validation after_validation before_save after_save
          before_create after_create before_update after_update
          before_destroy after_destroy after_commit after_rollback
        ].to_set.freeze

        def initialize
          super
          @render_calls = []
          @route_helper_calls = []
          @validates_calls = []
          @permit_calls = []
          @callback_registrations = []
          @has_many_calls = []
        end

        def visit_call_node(node)
          case node.name
          when :render     then extract_render(node)
          when :validates  then extract_validates(node)
          when :permit     then extract_permit(node)
          when :has_many   then extract_has_many(node)
          else
            if node.name.to_s.end_with?("_path", "_url") && node.receiver.nil?
              @route_helper_calls << { name: node.name.to_s, line: node.location.start_line }
            elsif CALLBACK_NAMES.include?(node.name) && node.receiver.nil?
              extract_callback(node)
            end
          end
          super
        end

        private

        def extract_render(node)
          args = node.arguments&.arguments || []
          args.each do |arg|
            case arg
            when Prism::StringNode
              @render_calls << { name: arg.unescaped, line: node.location.start_line }
            when Prism::KeywordHashNode
              arg.elements.each do |elem|
                next unless elem.is_a?(Prism::AssocNode)
                key = elem.key
                val = elem.value
                if key.is_a?(Prism::SymbolNode) && key.value == "partial" && val.is_a?(Prism::StringNode)
                  @render_calls << { name: val.unescaped, line: node.location.start_line }
                end
              end
            end
          end
        end

        def extract_validates(node)
          args = node.arguments&.arguments || []
          columns = []
          args.each do |arg|
            break unless arg.is_a?(Prism::SymbolNode)
            columns << arg.value
          end
          @validates_calls << { columns: columns, line: node.location.start_line } if columns.any?
        end

        def extract_permit(node)
          args = node.arguments&.arguments || []
          params = []
          args.each do |arg|
            case arg
            when Prism::SymbolNode then params << arg.value
            end
          end
          # Extract model key from params.require(:model).permit(...)
          require_key = nil
          receiver = node.receiver
          if receiver.is_a?(Prism::CallNode) && receiver.name == :require
            req_args = receiver.arguments&.arguments || []
            first = req_args.first
            require_key = first.value if first.is_a?(Prism::SymbolNode)
          end
          @permit_calls << { params: params, require_key: require_key, line: node.location.start_line } if params.any?
        end

        def extract_has_many(node)
          args = node.arguments&.arguments || []
          name = nil
          has_dependent = false
          args.each do |arg|
            case arg
            when Prism::SymbolNode
              name ||= arg.value
            when Prism::KeywordHashNode
              arg.elements.each do |elem|
                next unless elem.is_a?(Prism::AssocNode) && elem.key.is_a?(Prism::SymbolNode)
                has_dependent = true if elem.key.value == "dependent"
              end
            end
          end
          @has_many_calls << { name: name, has_dependent: has_dependent, line: node.location.start_line } if name
        end

        def extract_callback(node)
          args = node.arguments&.arguments || []
          methods = args.select { |a| a.is_a?(Prism::SymbolNode) }.map(&:value)
          @callback_registrations << { type: node.name.to_s, methods: methods, line: node.location.start_line } if methods.any?
        end
      end if defined?(Prism)

      # ── Semantic check dispatcher ────────────────────────────────────

      private_class_method def self.check_rails_semantics(file, full_path)
        warnings = []

        context = begin; cached_context; rescue; return warnings; end
        return warnings unless context

        content = RailsAiContext::SafeFile.read(full_path)
        return warnings unless content

        # Parse with Prism AST visitor (single pass for all checks)
        visitor = parse_and_visit(file, content)

        if file.end_with?(".html.erb", ".erb")
          if visitor
            warnings.concat(check_partial_existence_ast(file, visitor))
            warnings.concat(check_route_helpers_ast(visitor, context))
          else
            warnings.concat(check_partial_existence_regex(file, content))
            warnings.concat(check_route_helpers_regex(content, context))
          end
          warnings.concat(check_stimulus_controllers(content, context))
          warnings.concat(check_instance_variable_usage(file, content, context))
          warnings.concat(check_respond_to_template_existence(file, content))
        elsif file.end_with?(".rb")
          if visitor
            warnings.concat(check_route_helpers_ast(visitor, context))
            warnings.concat(check_column_references_ast(file, visitor, context))
            warnings.concat(check_strong_params_ast(file, visitor, context))
            warnings.concat(check_callback_existence_ast(file, visitor, context))
          else
            warnings.concat(check_route_helpers_regex(content, context))
            warnings.concat(check_column_references_regex(file, content, context))
          end
          # Cache-only checks (no AST needed)
          warnings.concat(check_has_many_dependent(file, context))
          warnings.concat(check_missing_fk_index(file, context))
          warnings.concat(check_route_action_consistency(file, context))
          warnings.concat(check_turbo_stream_channels(file, content, context))
          warnings.concat(check_memory_loading(file, content)) if file.start_with?("app/controllers/")
        end

        # Performance checks from performance introspector
        warnings.concat(check_performance_warnings(file, context))

        warnings
      end

      private_class_method def self.parse_and_visit(file, content)
        source = if file.end_with?(".html.erb", ".erb")
          processed = content.gsub("<%=", "<%")
          erb_src = +ERB.new(processed).src
          erb_src.force_encoding("UTF-8")
          "# encoding: utf-8\n#{erb_src}"
        else
          content
        end

        result = Prism.parse(source)
        visitor = RailsSemanticVisitor.new
        result.value.accept(visitor)
        visitor
      rescue => e
        $stderr.puts "[rails-ai-context] parse_and_visit failed: #{e.message}" if ENV["DEBUG"]
        nil
      end

      # ── CHECK 1: Partial existence (AST) ─────────────────────────────

      private_class_method def self.check_partial_existence_ast(file, visitor)
        warnings = []
        visitor.render_calls.each do |rc|
          ref = rc[:name]
          next if ref.include?("@") || ref.include?("#") || ref.include?("{")
          possible = resolve_partial_paths(file, ref)
          unless possible.any? { |p| File.exist?(File.join(Rails.root, "app", "views", p)) }
            warnings << "render \"#{ref}\" \u2014 partial not found (checked: #{possible.first(2).join(', ')})"
          end
        end
        warnings
      end

      # Regex fallback for non-Prism environments
      private_class_method def self.check_partial_existence_regex(file, content)
        warnings = []
        content.scan(/render\s+(?:partial:\s*)?["']([^"']+)["']/).flatten.uniq.each do |ref|
          next if ref.include?("@") || ref.include?("#") || ref.include?("{")
          possible = resolve_partial_paths(file, ref)
          unless possible.any? { |p| File.exist?(File.join(Rails.root, "app", "views", p)) }
            warnings << "render \"#{ref}\" \u2014 partial not found (checked: #{possible.first(2).join(', ')})"
          end
        end
        warnings
      end

      private_class_method def self.resolve_partial_paths(file, ref)
        paths = []
        if ref.include?("/")
          dir, base = File.dirname(ref), File.basename(ref)
          %w[.html.erb .erb .turbo_stream.erb .json.jbuilder].each { |ext| paths << "#{dir}/_#{base}#{ext}" }
        else
          view_dir = file.sub(%r{^app/views/}, "").then { |f| File.dirname(f) }
          %w[.html.erb .erb .turbo_stream.erb .json.jbuilder].each { |ext| paths << "#{view_dir}/_#{ref}#{ext}" }
          %w[.html.erb .erb].each { |ext| paths << "shared/_#{ref}#{ext}"; paths << "application/_#{ref}#{ext}" }
        end
        paths
      end

      # ── CHECK 2: Route helpers (AST) ─────────────────────────────────

      ASSET_HELPER_PREFIXES = %w[image asset font stylesheet javascript audio video file compute_asset auto_discovery_link favicon].freeze
      DEVISE_HELPER_NAMES = %w[session registration password confirmation unlock omniauth_callback user_session user_registration user_password user_confirmation user_unlock].freeze

      private_class_method def self.check_route_helpers_ast(visitor, context)
        warnings = []
        routes = context[:routes]
        return warnings unless routes && routes[:by_controller]
        valid_names = build_route_name_set(routes)
        return warnings if valid_names.empty?

        seen = Set.new
        visitor.route_helper_calls.each do |call|
          helper = call[:name]
          next if seen.include?(helper)
          seen << helper

          name = helper.sub(/_(path|url)\z/, "")
          next if ASSET_HELPER_PREFIXES.any? { |p| name.start_with?(p) }
          next if DEVISE_HELPER_NAMES.include?(name)
          next if %w[edit new polymorphic].include?(name)

          warnings << "#{helper} \u2014 route helper not found" unless valid_names.include?(name)
        end
        warnings
      end

      # Regex fallback
      private_class_method def self.check_route_helpers_regex(content, context)
        warnings = []
        routes = context[:routes]
        return warnings unless routes && routes[:by_controller]
        valid_names = build_route_name_set(routes)
        return warnings if valid_names.empty?

        seen = Set.new
        content.scan(/\b(\w+)_(path|url)\b/).each do |match|
          name, suffix = match
          helper = "#{name}_#{suffix}"
          next if seen.include?(helper)
          seen << helper
          next if ASSET_HELPER_PREFIXES.any? { |p| name.start_with?(p) }
          next if DEVISE_HELPER_NAMES.include?(name)
          next if %w[edit new polymorphic].include?(name)
          warnings << "#{helper} \u2014 route helper not found" unless valid_names.include?(name)
        end
        warnings
      end

      private_class_method def self.build_route_name_set(routes)
        names = Set.new
        routes[:by_controller].each_value do |actions|
          actions.each do |a|
            next unless a[:name]
            names << a[:name]
            names << "edit_#{a[:name]}"
            names << "new_#{a[:name]}"
          end
        end
        names
      end

      # ── CHECK 3: Column references (AST) ─────────────────────────────

      private_class_method def self.check_column_references_ast(file, visitor, context)
        warnings = []
        return warnings unless file.start_with?("app/models/") && !file.include?("/concerns/")

        valid = model_valid_columns(file, context)
        return warnings unless valid

        visitor.validates_calls.each do |vc|
          vc[:columns].each do |col|
            unless valid[:columns].include?(col)
              warnings << "validates :#{col} \u2014 column \"#{col}\" not found in #{valid[:table]} table. Fix: add migration `rails g migration Add#{col.camelize}To#{valid[:table].camelize} #{col}:string` or check concerns"
            end
          end
        end
        warnings
      end

      # Regex fallback
      private_class_method def self.check_column_references_regex(file, content, context)
        warnings = []
        return warnings unless file.start_with?("app/models/") && !file.include?("/concerns/")

        valid = model_valid_columns(file, context)
        return warnings unless valid

        content.each_line do |line|
          next unless line.match?(/\A\s*validates\s+:/)
          after = line.sub(/\A\s*validates\s+/, "")
          after.scan(/:(\w+)/).each do |m|
            col = m[0]
            break if after.include?("#{col}:")
            next if col == col.capitalize
            warnings << "validates :#{col} \u2014 column \"#{col}\" not found in #{valid[:table]} table" unless valid[:columns].include?(col)
          end
        end
        warnings
      end

      # Shared helper: build valid column set for a model file
      private_class_method def self.model_valid_columns(file, context)
        models = context[:models]
        schema = context[:schema]
        return nil unless models && schema

        model_name = file.sub("app/models/", "").sub(/\.rb$/, "").camelize
        model_data = models[model_name]
        return nil unless model_data

        table_name = model_data[:table_name]
        table_data = schema[:tables] && schema[:tables][table_name]
        return nil unless table_data

        columns = Set.new
        table_data[:columns]&.each { |c| columns << c[:name] }
        model_data[:associations]&.each do |a|
          columns << a[:name] if a[:name]
          columns << a[:foreign_key] if a[:foreign_key]
        end

        { columns: columns, table: table_name, model: model_name, model_data: model_data }
      end

      # ── CHECK 4: Strong params vs schema (AST) ───────────────────────

      private_class_method def self.check_strong_params_ast(file, visitor, context)
        warnings = []
        return warnings unless file.start_with?("app/controllers/")
        return warnings if visitor.permit_calls.empty?

        schema = context[:schema]
        models = context[:models]
        return warnings unless schema && models

        visitor.permit_calls.each do |pc|
          # Infer model: prefer require_key (:post → Post), fall back to controller filename
          model_name = if pc[:require_key]
            pc[:require_key].to_s.classify
          else
            File.basename(file, ".rb").sub(/_controller$/, "").classify
          end

          model_data = models[model_name]
          next unless model_data

          table_name = model_data[:table_name]
          table_data = schema[:tables] && schema[:tables][table_name]
          next unless table_data

          valid = Set.new
          table_data[:columns]&.each { |c| valid << c[:name] }
          model_data[:associations]&.each { |a| valid << a[:name]; valid << a[:foreign_key] if a[:foreign_key] }
          valid.merge(%w[id _destroy created_at updated_at])

          # When JSONB columns exist, plain-word params may be keys inside JSONB columns.
          # Only flag _id params (FKs must be real columns) when JSONB is present.
          has_json_columns = table_data[:columns]&.any? { |c| %w[jsonb json].include?(c[:type]) }

          pc[:params].each do |param|
            next if param.end_with?("_attributes") # nested attributes
            next if valid.include?(param)
            # When JSONB columns exist, only flag _id params (FKs must be real columns)
            # Plain-word params could be keys inside JSONB columns
            next if has_json_columns && !param.end_with?("_id")
            warnings << "permits :#{param} \u2014 not a column in #{table_name} table (check virtual attributes or add migration)"
          end
        end
        warnings
      end

      # ── CHECK 5: Callback method existence (AST) ─────────────────────

      private_class_method def self.check_callback_existence_ast(file, visitor, context)
        warnings = []
        return warnings unless file.start_with?("app/models/") && !file.include?("/concerns/")
        return warnings if visitor.callback_registrations.empty?

        models = context[:models]
        return warnings unless models

        model_name = file.sub("app/models/", "").sub(/\.rb$/, "").camelize
        model_data = models[model_name]
        return warnings unless model_data

        # Build set of known methods (instance + from source content)
        known = Set.new(model_data[:instance_methods] || [])
        # Also check the file source for private methods
        source = RailsAiContext::SafeFile.read(Rails.root.join(file))
        source&.scan(/\bdef\s+(\w+[?!]?)/)&.each { |m| known << m[0] }

        # Skip check if model has concerns (method may be in concern)
        has_concerns = (model_data[:concerns] || []).any?

        visitor.callback_registrations.each do |reg|
          reg[:methods].each do |method_name|
            next if known.include?(method_name)
            next if has_concerns # uncertain — method may come from concern
            warnings << "#{reg[:type]} :#{method_name} \u2014 method not found in #{model_name}"
          end
        end
        warnings
      end

      # ── CHECK 6: Route-action consistency (cache only) ───────────────

      private_class_method def self.check_route_action_consistency(file, context)
        warnings = []
        return warnings unless file.start_with?("app/controllers/")

        routes = context[:routes]
        controllers = context[:controllers]
        return warnings unless routes && controllers

        # Map file to controller name: app/controllers/posts_controller.rb → posts
        relative = file.sub("app/controllers/", "").sub(/_controller\.rb$/, "")
        ctrl_key = relative.gsub("/", "::")
        ctrl_class = ctrl_key.camelize + "Controller"

        # Get controller actions
        ctrl_data = controllers[:controllers] && controllers[:controllers][ctrl_class]
        return warnings unless ctrl_data
        actions = Set.new(ctrl_data[:actions] || [])

        # Get routes pointing to this controller
        route_controller = relative.gsub("::", "/")
        route_actions = routes[:by_controller] && routes[:by_controller][route_controller]
        return warnings unless route_actions

        route_actions.each do |route|
          action = route[:action]
          next unless action
          unless actions.include?(action)
            warnings << "route #{route[:verb]} #{route[:path]} \u2192 #{action} \u2014 action not found in #{ctrl_class}. Fix: add `def #{action}; end` to #{ctrl_class} or remove the route"
          end
        end
        warnings
      end

      # ── CHECK 7: has_many without :dependent (cache only) ────────────

      private_class_method def self.check_has_many_dependent(file, context)
        warnings = []
        return warnings unless file.start_with?("app/models/") && !file.include?("/concerns/")

        models = context[:models]
        return warnings unless models

        model_name = file.sub("app/models/", "").sub(/\.rb$/, "").camelize
        model_data = models[model_name]
        return warnings unless model_data

        (model_data[:associations] || []).each do |assoc|
          next unless assoc[:type] == "has_many"
          next if assoc[:through] # through associations don't need dependent
          next if assoc[:dependent] # already has dependent
          warnings << "has_many :#{assoc[:name]} \u2014 missing :dependent option (orphaned records risk). Fix: add `dependent: :destroy` or `:nullify`"
        end
        warnings
      end

      # ── CHECK 8: Missing FK index (cache only) ──────────────────────

      private_class_method def self.check_missing_fk_index(file, context)
        warnings = []
        return warnings unless file.start_with?("app/models/") && !file.include?("/concerns/")

        schema = context[:schema]
        models = context[:models]
        return warnings unless schema && models

        model_name = file.sub("app/models/", "").sub(/\.rb$/, "").camelize
        model_data = models[model_name]
        return warnings unless model_data

        table_name = model_data[:table_name]
        table_data = schema[:tables] && schema[:tables][table_name]
        return warnings unless table_data

        # Only flag columns that are ACTUAL foreign keys (declared via add_foreign_key or belongs_to)
        declared_fk_columns = (table_data[:foreign_keys] || []).map { |fk| fk[:column] }
        assoc_fk_columns = (model_data[:associations] || [])
          .select { |a| a[:type] == "belongs_to" }
          .map { |a| a[:foreign_key] }
          .compact
        fk_columns = (declared_fk_columns + assoc_fk_columns).uniq

        # Build set of indexed columns (first column in any index)
        indexed = Set.new
        (table_data[:indexes] || []).each do |idx|
          indexed << idx[:columns]&.first if idx[:columns]&.any?
        end

        fk_columns.each do |col|
          unless indexed.include?(col)
            warnings << "#{col} in #{table_name} \u2014 foreign key without index (slow queries). Fix: `rails g migration AddIndexTo#{table_name.camelize} #{col}:index`"
          end
        end
        warnings
      end

      # ── CHECK 9: Stimulus controller existence ───────────────────────

      private_class_method def self.check_stimulus_controllers(content, context)
        warnings = []
        stimulus = context[:stimulus]
        return warnings unless stimulus

        # Build known controller names (normalize: both dash and underscore forms)
        known = Set.new
        if stimulus.is_a?(Hash) && stimulus[:controllers]
          stimulus[:controllers].each do |ctrl|
            name = ctrl.is_a?(Hash) ? (ctrl[:name] || ctrl["name"]) : ctrl.to_s
            if name
              known << name
              known << name.tr("_", "-")  # underscore → dash
              known << name.tr("-", "_")  # dash → underscore
            end
          end
        elsif stimulus.is_a?(Array)
          stimulus.each do |s|
            name = s.is_a?(Hash) ? (s[:name] || s["name"]) : s.to_s
            if name
              known << name
              known << name.tr("_", "-")
              known << name.tr("-", "_")
            end
          end
        end
        return warnings if known.empty?

        # Extract data-controller references from HTML
        content.scan(/data-controller=["']([^"']+)["']/).each do |match|
          controllers = match[0].split(/\s+/)
          controllers.each do |name|
            next if name.include?("<%") || name.include?("#") # dynamic
            next if name.include?("--") # namespaced npm package
            unless known.include?(name)
              warnings << "data-controller=\"#{name}\" \u2014 Stimulus controller not found"
            end
          end
        end
        warnings
      end

      # ── CHECK 10: Instance variable usage in views ─────────────────

      private_class_method def self.check_instance_variable_usage(file, content, context)
        warnings = []
        return warnings unless file.start_with?("app/views/") && !file.include?("/layouts/")

        # Extract instance variables used in ERB tags only (not HTML/JS content)
        erb_content = content.scan(/<%[=\-]?\s*(.+?)\s*-?%>/m).map { |m| m[0] }.join("\n")
        ivars = erb_content.scan(/@(\w+)/).flatten.uniq
        return warnings if ivars.empty?

        # Try to find the controller that renders this view
        parts = file.sub("app/views/", "").split("/")
        return warnings if parts.size < 2

        ctrl_dir = parts[0..-2].join("/")
        ctrl_class = "#{ctrl_dir.camelize}Controller"
        controllers = context.dig(:controllers, :controllers) || {}
        ctrl_data = controllers[ctrl_class]
        return warnings unless ctrl_data

        # Get all instance variables set across all actions
        source_path = Rails.root.join("app", "controllers", "#{ctrl_class.underscore}.rb")
        return warnings unless File.exist?(source_path)

        ctrl_source = RailsAiContext::SafeFile.read(source_path)
        return warnings unless ctrl_source

        # Detect ivars from controller — handles @a, @b = multi-assignment
        set_ivars = []
        ctrl_source.each_line do |line|
          next unless line.include?("@")
          if line.include?("=")
            line.split("=", 2).first.scan(/@(\w+)/).each { |m| set_ivars << m[0] }
          end
        end
        set_ivars.uniq!
        # Add common framework ivars that don't appear as explicit assignments
        set_ivars += %w[pagy current_user _request]

        ivars.each do |ivar|
          next if set_ivars.include?(ivar)
          next if ivar.start_with?("_") # framework internal
          next if %w[output_buffer virtual_path].include?(ivar)
          warnings << "@#{ivar} used in view but not set in #{ctrl_class}. Fix: add `@#{ivar} = ...` to action"
        end
        warnings
      rescue => e
        $stderr.puts "[rails-ai-context] check_instance_variable_usage failed: #{e.message}" if ENV["DEBUG"]
        []
      end

      # ── CHECK 11: Turbo Stream channel matching ────────────────────

      private_class_method def self.check_turbo_stream_channels(file, content, context)
        warnings = []
        return warnings unless file.start_with?("app/")

        # Detect broadcasts in Ruby files
        broadcasts = content.scan(/broadcast_(?:replace|append|prepend|remove|update|action)_to\s*\(\s*["']([^"']+)["']/).flatten
        return warnings if broadcasts.empty?

        # Scan views for turbo_stream_from subscriptions
        views_dir = Rails.root.join("app", "views")
        return warnings unless Dir.exist?(views_dir)

        subscriptions = Set.new
        Dir.glob(File.join(views_dir, "**", "*.{erb,html.erb}")).each do |path|
          view_content = RailsAiContext::SafeFile.read(path) or next
          view_content.scan(/turbo_stream_from\s+["']([^"']+)["']/).each do |match|
            subscriptions << match[0]
          end
        end

        broadcasts.each do |channel|
          # Skip dynamic channels (containing interpolation)
          next if channel.include?("#") || channel.include?("{")
          unless subscriptions.any? { |s| s == channel || channel.include?(s) || s.include?(channel) }
            warnings << "broadcast to \"#{channel}\" — no matching turbo_stream_from found in views"
          end
        end
        warnings
      rescue => e
        $stderr.puts "[rails-ai-context] check_turbo_stream_channels failed: #{e.message}" if ENV["DEBUG"]
        []
      end

      # ── CHECK 12: respond_to template existence ────────────────────

      private_class_method def self.check_respond_to_template_existence(file, content)
        warnings = []
        return warnings unless file.start_with?("app/views/") && file.end_with?(".html.erb")

        # Check if there's a turbo_stream version when turbo_stream_from is used
        # (This checks from the view side — controller respond_to check is separate)
        return warnings unless content.include?("turbo_stream_from") || content.include?("turbo_frame_tag")

        # If view has turbo_stream_from, check the controller action has respond_to :turbo_stream
        # and that a .turbo_stream.erb template exists
        base = file.sub(/\.html\.erb$/, "")
        turbo_template = "#{base}.turbo_stream.erb"
        turbo_path = Rails.root.join(turbo_template)

        if content.include?("turbo_stream_from") && !File.exist?(turbo_path)
          # Only warn if the controller likely needs it
          warnings << "#{file} uses turbo_stream_from but #{turbo_template} doesn't exist (Turbo Stream updates may need this)"
        end
        warnings
      rescue => e
        $stderr.puts "[rails-ai-context] check_respond_to_template_existence failed: #{e.message}" if ENV["DEBUG"]
        []
      end

      # ── CHECK: Memory-loading anti-pattern ───────────────────────────
      MEMORY_LOAD_METHODS = %w[map filter_map flat_map select reject collect reduce inject each_with_object].freeze

      private_class_method def self.check_memory_loading(file, content)
        warnings = []
        content.each_line.with_index(1) do |line, num|
          stripped = line.strip
          next if stripped.start_with?("#")

          MEMORY_LOAD_METHODS.each do |method|
            # Match: .scope.ruby_method{ or .scope.ruby_method do
            next unless stripped.match?(/\.\w+\.#{method}\s*[\{\(]/) || stripped.match?(/\.\w+\.#{method}\s+do\b/)
            # Skip if it's clearly not an AR chain (e.g., array.map)
            next if stripped.match?(/\[\]\.#{method}/) || stripped.match?(/\.to_a\.#{method}/)
            # Skip if preceded by pluck/select (already optimized)
            next if stripped.match?(/\.pluck\(.*\)\.#{method}/) || stripped.match?(/\.select\(.*\)\.#{method}/)
            warnings << "line #{num}: scope chain followed by .#{method} may load all records into memory — consider .pluck or SQL"
            break # one warning per line
          end
        end
        warnings.first(3) # cap at 3 to avoid noise
      rescue => e
        $stderr.puts "[rails-ai-context] check_memory_loading failed: #{e.message}" if ENV["DEBUG"]
        []
      end

      # ── CHECK 13+14: Performance warnings from introspector ────────

      private_class_method def self.check_performance_warnings(file, context)
        warnings = []
        perf = context[:performance]
        return warnings unless perf.is_a?(Hash) && !perf[:error]

        # Check 13: Model.all in controllers
        if file.start_with?("app/controllers/") && perf[:model_all_in_controllers]&.any?
          perf[:model_all_in_controllers].each do |finding|
            next unless finding.is_a?(Hash) && finding[:file]&.end_with?(File.basename(file))
            warnings << "#{finding[:model]}.all loaded in controller — consider pagination or scoping (line #{finding[:line]})"
          end
        end

        # Check 14: Missing FK indexes on tables referenced in validated files
        if file.start_with?("app/models/") && perf[:missing_fk_indexes]&.any?
          model_name = file.sub("app/models/", "").sub(/\.rb$/, "").tr("/", "::").camelize
          perf[:missing_fk_indexes].each do |finding|
            next unless finding.is_a?(Hash) && finding[:model] == model_name
            warnings << "#{finding[:column]} on #{finding[:table]} — missing index on foreign key (performance)"
          end
        end

        warnings.first(5)
      rescue => e
        $stderr.puts "[rails-ai-context] check_performance_warnings failed: #{e.message}" if ENV["DEBUG"]
        []
      end

      # ── Brakeman security scan (runs once for all files) ───────────

      private_class_method def self.check_brakeman_security(files)
        return [] unless brakeman_available?

        tracker = Brakeman.run(
          app_path: Rails.root.to_s,
          quiet: true,
          report_progress: false,
          print_report: false
        )

        warnings = tracker.filtered_warnings
        return [] if warnings.empty?

        # Filter to only warnings in the validated files
        normalized = files.map { |f| f.delete_prefix("/") }
        relevant = warnings.select do |w|
          path = w.file.relative
          normalized.any? { |f| path == f || path.start_with?(f) }
        end
        return [] if relevant.empty?

        relevant.sort_by(&:confidence).first(5).map do |w|
          loc = w.line ? "#{w.file.relative}:#{w.line}" : w.file.relative
          "[#{w.confidence_name}] #{w.warning_type} — #{loc}: #{w.message}"
        end
      rescue => e
        $stderr.puts "[rails-ai-context] check_brakeman_security failed: #{e.message}" if ENV["DEBUG"]
        []
      end

      private_class_method def self.brakeman_available?
        return @brakeman_available unless @brakeman_available.nil?

        @brakeman_available = begin
          require "brakeman"
          true
        rescue LoadError
          false
        end
      end
    end
  end
end
