# frozen_string_literal: true

require "open3"
require "erb"
require "set"

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
            description: "File paths relative to Rails root (e.g. ['app/models/cook.rb', 'app/views/cooks/index.html.erb'])"
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

      def self.call(files:, level: "syntax", server_context: nil)
        return text_response("No files provided.") if files.empty?
        return text_response("Too many files (#{files.size}). Maximum is #{max_files} per call.") if files.size > max_files

        results = []
        passed = 0
        total = 0

        files.each do |file|
          full_path = Rails.root.join(file)

          unless File.exist?(full_path)
            results << "\u2717 #{file} \u2014 file not found"
            total += 1
            next
          end

          begin
            real = File.realpath(full_path)
            unless real.start_with?(File.realpath(Rails.root))
              results << "\u2717 #{file} \u2014 path not allowed (outside Rails root)"
              total += 1
              next
            end
          rescue Errno::ENOENT
            results << "\u2717 #{file} \u2014 file not found"
            total += 1
            next
          end

          total += 1

          ok, msg, warnings = if file.end_with?(".rb")
            validate_ruby(full_path)
          elsif file.end_with?(".html.erb") || file.end_with?(".erb")
            validate_erb(full_path)
          elsif file.end_with?(".js")
            validate_javascript(full_path)
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
            rails_warnings = check_rails_semantics(file, full_path)
            rails_warnings.each { |w| results << "  \u26A0 #{w}" }
          end
        end

        output = results.join("\n")
        output += "\n\n#{passed}/#{total} files passed"
        text_response(output)
      end

      # ── Prism detection ──────────────────────────────────────────────

      private_class_method def self.prism_available?
        return @prism_available unless @prism_available.nil?

        @prism_available = begin
          require "prism"
          true
        rescue LoadError
          false
        end
      end

      # ── Ruby validation ──────────────────────────────────────────────

      private_class_method def self.validate_ruby(full_path)
        prism_available? ? validate_ruby_prism(full_path) : validate_ruby_subprocess(full_path)
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

        if prism_available?
          result = Prism.parse(compiled)
          if result.success?
            [ true, nil, [] ]
          else
            error = result.errors.first(5).map do |e|
              "line #{[ e.location.start_line - 2, 1 ].max}: #{e.message}"
            end.join("\n")
            [ false, error, [] ]
          end
        else
          check_result, check_status = Open3.capture2e("ruby", "-c", "-", stdin_data: compiled)
          if check_status.success?
            [ true, nil, [] ]
          else
            error = check_result.lines
              .reject { |l| l.strip.empty? || l.include?("Syntax OK") }
              .first(5)
              .map { |l| l.strip.sub(/-:(\d+):/) { "ruby: -:#{$1.to_i - 2}:" } }
            [ false, error.any? ? error.join("\n") : "ERB syntax error", [] ]
          end
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
        content = File.read(full_path)
        stack = []
        openers = { "{" => "}", "[" => "]", "(" => ")" }
        closers = { "}" => "{", "]" => "[", ")" => "(" }
        in_string = nil; in_line_comment = false; in_block_comment = false; prev_char = nil

        content.each_char.with_index do |char, i|
          if in_line_comment then (in_line_comment = false if char == "\n"); prev_char = char; next end
          if in_block_comment then (in_block_comment = false if prev_char == "*" && char == "/"); prev_char = char; next end
          if in_string then (in_string = nil if char == in_string && prev_char != "\\"); prev_char = char; next end

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
          @permit_calls << { params: params, line: node.location.start_line } if params.any?
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

        content = File.read(full_path, encoding: "UTF-8", invalid: :replace, undef: :replace) rescue nil
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
        end

        warnings
      end

      private_class_method def self.parse_and_visit(file, content)
        return nil unless prism_available?

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
      rescue
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
            warnings << "render \"#{ref}\" \u2014 partial not found"
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
            warnings << "render \"#{ref}\" \u2014 partial not found"
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
              warnings << "validates :#{col} \u2014 column \"#{col}\" not found in #{valid[:table]} table"
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

        # Infer model from controller: posts_controller.rb → Post → posts table
        controller_base = File.basename(file, ".rb").sub(/_controller$/, "")
        model_name = controller_base.classify
        model_data = models[model_name]
        return warnings unless model_data

        table_name = model_data[:table_name]
        table_data = schema[:tables] && schema[:tables][table_name]
        return warnings unless table_data

        valid = Set.new
        table_data[:columns]&.each { |c| valid << c[:name] }
        model_data[:associations]&.each { |a| valid << a[:name]; valid << a[:foreign_key] if a[:foreign_key] }
        valid.merge(%w[id _destroy created_at updated_at])

        # V1: Smarter JSONB skip — only skip params matching JSON column names, check the rest
        json_column_names = table_data[:columns]
          &.select { |c| %w[jsonb json].include?(c[:type]) }
          &.map { |c| c[:name] }
          &.to_set || Set.new

        visitor.permit_calls.each do |pc|
          pc[:params].each do |param|
            next if param.end_with?("_attributes") # nested attributes
            next if valid.include?(param)
            next if json_column_names.include?(param) # param matches a JSON column, skip
            warnings << "permits :#{param} \u2014 not a column in #{table_name} table"
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
        source = File.read(Rails.root.join(file), encoding: "UTF-8") rescue nil
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

        # Map file to controller name: app/controllers/cooks_controller.rb → cooks
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
          warnings << "has_many :#{assoc[:name]} \u2014 missing :dependent option (orphaned records risk)"
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
            warnings << "#{col} in #{table_name} \u2014 foreign key without index (slow queries)"
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
    end
  end
end
