# frozen_string_literal: true

module RailsAiContext
  module Tools
    # Semantic (Rails-aware) half of the rails_validate tool: the Prism
    # visitor and the per-rule checks it feeds. Split from Validate, which
    # keeps syntax validation and orchestration, so a new rule lands here
    # without touching the tool entry point.
    #
    # Inherits BaseTool for cached_context only; abstract! keeps it out of
    # the MCP tool registry.
    class ValidateSemantics < BaseTool
      abstract!

      class RailsSemanticVisitor < Prism::Visitor
        attr_reader :render_calls, :route_helper_calls, :validates_calls,
                    :permit_calls, :callback_registrations, :has_many_calls,
                    :local_method_names_by_scope, :singleton_method_names_by_scope

        TOP_LEVEL_SCOPE = "__top_level__"
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
          @local_method_names_by_scope = Hash.new { |hash, key| hash[key] = Set.new }
          @singleton_method_names_by_scope = Hash.new { |hash, key| hash[key] = Set.new }
          @scope_stack = [ TOP_LEVEL_SCOPE ]
          @method_context_stack = []
        end

        def local_route_method_defined?(helper, scope, method_kind)
          case method_kind
          when :singleton
            @singleton_method_names_by_scope[scope].include?(helper)
          when :instance
            @local_method_names_by_scope[scope].include?(helper)
          else
            @local_method_names_by_scope[scope].include?(helper) ||
              @singleton_method_names_by_scope[scope].include?(helper)
          end
        end

        def visit_class_node(node)
          with_scope(node.constant_path&.slice) { super }
        end

        def visit_module_node(node)
          with_scope(node.constant_path&.slice) { super }
        end

        def visit_def_node(node)
          method_kind = node.receiver ? :singleton : :instance
          method_names_for(method_kind, current_scope) << node.name.to_s
          with_method_context(method_kind) { super }
        end

        def visit_call_node(node)
          case node.name
          when :render     then extract_render(node)
          when :validates  then extract_validates(node)
          when :permit     then extract_permit(node)
          when :has_many   then extract_has_many(node)
          else
            if node.name.to_s.end_with?("_path", "_url") && node.receiver.nil?
              @route_helper_calls << {
                name: node.name.to_s,
                line: node.location.start_line,
                scope: current_scope,
                method_kind: current_method_kind
              }
            elsif CALLBACK_NAMES.include?(node.name) && node.receiver.nil?
              extract_callback(node)
            end
          end
          super
        end

        private

        def with_scope(scope_name)
          @scope_stack << scope_name.to_s
          yield
        ensure
          @scope_stack.pop
        end

        def with_method_context(method_kind)
          @method_context_stack << method_kind
          yield
        ensure
          @method_context_stack.pop
        end

        def method_names_for(method_kind, scope)
          method_kind == :singleton ? @singleton_method_names_by_scope[scope] : @local_method_names_by_scope[scope]
        end

        def current_scope
          @scope_stack.join("::")
        end

        def current_method_kind
          @method_context_stack.last
        end

        def extract_render(node)
          args = node.arguments&.arguments || []
          args.each do |arg|
            case arg
            when Prism::StringNode
              @render_calls << { name: arg.unescaped, line: node.location.start_line, explicit_partial: false }
            when Prism::KeywordHashNode
              arg.elements.each do |elem|
                next unless elem.is_a?(Prism::AssocNode)
                key = elem.key
                val = elem.value
                if key.is_a?(Prism::SymbolNode) && key.value == "partial" && val.is_a?(Prism::StringNode)
                  @render_calls << { name: val.unescaped, line: node.location.start_line, explicit_partial: true }
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

      def self.check_rails_semantics(file, full_path)
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
            warnings.concat(check_route_helpers_ast(file, visitor, context))
          else
            warnings.concat(check_partial_existence_regex(file, content))
            warnings.concat(check_route_helpers_regex(file, content, context))
          end
          warnings.concat(check_stimulus_controllers(content, context))
          warnings.concat(check_instance_variable_usage(file, content, context))
          warnings.concat(check_respond_to_template_existence(file, content))
        elsif file.end_with?(".rb")
          if visitor
            warnings.concat(check_route_helpers_ast(file, visitor, context))
            warnings.concat(check_partial_existence_ast(file, visitor, qualified_only: true))
            warnings.concat(check_column_references_ast(file, visitor, context))
            warnings.concat(check_strong_params_ast(file, visitor, context))
            warnings.concat(check_callback_existence_ast(file, visitor, context))
          else
            warnings.concat(check_route_helpers_regex(file, content, context))
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

        result = AstCache.parse_string(source)
        visitor = RailsSemanticVisitor.new
        result.value.accept(visitor)
        visitor
      rescue => e
        $stderr.puts "[rails-ai-context] parse_and_visit failed: #{e.message}" if ENV["DEBUG"]
        nil
      end

      # ── CHECK 1: Partial existence (AST) ─────────────────────────────

      # qualified_only: a Ruby file has no view directory to resolve bare
      # partial names against, so only "dir/name" references are checkable.
      private_class_method def self.check_partial_existence_ast(file, visitor, qualified_only: false)
        warnings = []
        visitor.render_calls.each do |rc|
          ref = rc[:name]
          next if ref.include?("@") || ref.include?("#") || ref.include?("{")
          next if qualified_only && !ref.include?("/")
          possible = resolve_partial_paths(file, ref)
          # In a Ruby file, bare `render "dir/name"` renders the TEMPLATE
          # (only `partial:` has partial semantics there), so accept either.
          template_semantics = qualified_only && !rc[:explicit_partial]
          possible += resolve_template_paths(ref) if template_semantics
          unless possible.any? { |p| File.exist?(File.join(rails_app.root, "app", "views", p)) }
            label = template_semantics ? "template/partial not found" : "partial not found"
            warnings << "render \"#{ref}\" - #{label} (checked: #{possible.first(2).join(', ')})"
          end
        end
        warnings
      end

      private_class_method def self.resolve_template_paths(ref)
        %w[.html.erb .erb .turbo_stream.erb .json.jbuilder].map { |ext| "#{ref}#{ext}" }
      end

      # Regex fallback for non-Prism environments
      private_class_method def self.check_partial_existence_regex(file, content)
        warnings = []
        content.scan(/render\s+(?:partial:\s*)?["']([^"']+)["']/).flatten.uniq.each do |ref|
          next if ref.include?("@") || ref.include?("#") || ref.include?("{")
          possible = resolve_partial_paths(file, ref)
          unless possible.any? { |p| File.exist?(File.join(rails_app.root, "app", "views", p)) }
            warnings << "render \"#{ref}\" - partial not found (checked: #{possible.first(2).join(', ')})"
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

      private_class_method def self.check_route_helpers_ast(file, visitor, context)
        warnings = []
        routes = context[:routes]
        return warnings unless routes && routes[:by_controller]
        valid_names = build_route_name_set(routes)
        return warnings if valid_names.empty?

        columns = helper_shaped_columns(file, context)

        seen = Set.new
        visitor.route_helper_calls.each do |call|
          helper = call[:name]
          next if seen.include?(helper)
          seen << helper
          next if visitor.local_route_method_defined?(helper, call[:scope], call[:method_kind])
          next if columns.include?(helper)

          name = helper.sub(/_(path|url)\z/, "")
          next if ASSET_HELPER_PREFIXES.any? { |p| name.start_with?(p) }
          next if DEVISE_HELPER_NAMES.include?(name)
          next if %w[edit new polymorphic].include?(name)

          warnings << "#{helper} - route helper not found" unless valid_names.include?(name)
        end
        warnings
      end

      # Regex fallback
      private_class_method def self.check_route_helpers_regex(file, content, context)
        warnings = []
        routes = context[:routes]
        return warnings unless routes && routes[:by_controller]
        valid_names = build_route_name_set(routes)
        return warnings if valid_names.empty?

        columns = helper_shaped_columns(file, context)

        seen = Set.new
        local_method_names = local_route_like_method_names(content)
        content.scan(/\b(\w+)_(path|url)\b/).each do |match|
          name, suffix = match
          helper = "#{name}_#{suffix}"
          next if seen.include?(helper)
          seen << helper
          next if local_method_names.include?(helper)
          next if columns.include?(helper)
          next if ASSET_HELPER_PREFIXES.any? { |p| name.start_with?(p) }
          next if DEVISE_HELPER_NAMES.include?(name)
          next if %w[edit new polymorphic].include?(name)
          warnings << "#{helper} - route helper not found" unless valid_names.include?(name)
        end
        warnings
      end

      # A column named `shared_inbox_url` reads as a receiverless call to a
      # route helper, and the attribute reader it resolves to has no `def`
      # anywhere to find it by. Columns only: an association named like a
      # helper is not a reader, and suppressing on it would hide a real
      # missing route.
      private_class_method def self.helper_shaped_columns(file, context)
        valid = model_valid_columns(file, context)
        return Set.new unless valid

        valid[:table_columns].select { |c| c.to_s.end_with?("_path", "_url") }.to_set
      end

      private_class_method def self.local_route_like_method_names(content)
        content.scan(/^\s*(?:(?:private|protected|public|private_class_method)\s+)*def\s+(?:self\.)?(\w+_(?:path|url))\b/).flatten.to_set
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
              warnings << "validates :#{col} - column \"#{col}\" not found in #{valid[:table]} table. Fix: add migration `rails g migration Add#{col.camelize}To#{valid[:table].camelize} #{col}:string` or check concerns"
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
            warnings << "validates :#{col} - column \"#{col}\" not found in #{valid[:table]} table" unless valid[:columns].include?(col)
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

        table_columns = Set.new
        table_data[:columns]&.each { |c| table_columns << c[:name] }

        columns = table_columns.dup
        model_data[:associations]&.each do |a|
          columns << a[:name] if a[:name]
          columns << a[:foreign_key] if a[:foreign_key]
        end

        { columns: columns, table_columns: table_columns, table: table_name, model: model_name, model_data: model_data }
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
            warnings << "permits :#{param} - not a column in #{table_name} table (check virtual attributes or add migration)"
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
        source = RailsAiContext::SafeFile.read(rails_app.root.join(file))
        source&.scan(/\bdef\s+(\w+[?!]?)/)&.each { |m| known << m[0] }

        # Skip check if model has concerns (method may be in concern)
        has_concerns = (model_data[:concerns] || []).any?

        visitor.callback_registrations.each do |reg|
          reg[:methods].each do |method_name|
            next if known.include?(method_name)
            next if has_concerns # uncertain - method may come from concern
            warnings << "#{reg[:type]} :#{method_name} - method not found in #{model_name}"
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
            warnings << "route #{route[:verb]} #{route[:path]} \u2192 #{action} - action not found in #{ctrl_class}. Fix: add `def #{action}; end` to #{ctrl_class} or remove the route"
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
          warnings << "has_many :#{assoc[:name]} - missing :dependent option (orphaned records risk). Fix: add `dependent: :destroy` or `:nullify`"
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
            warnings << "#{col} in #{table_name} - foreign key without index (slow queries). Fix: `rails g migration AddIndexTo#{table_name.camelize} #{col}:index`"
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
              warnings << "data-controller=\"#{name}\" - Stimulus controller not found"
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
        source_path = rails_app.root.join("app", "controllers", "#{ctrl_class.underscore}.rb")
        return warnings unless File.exist?(source_path)

        ctrl_source = RailsAiContext::SafeFile.read(source_path)
        return warnings unless ctrl_source

        # Detect ivars from controller - handles @a, @b = multi-assignment
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
        views_dir = rails_app.root.join("app", "views")
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
            warnings << "broadcast to \"#{channel}\" - no matching turbo_stream_from found in views"
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
        # (This checks from the view side - controller respond_to check is separate)
        return warnings unless content.include?("turbo_stream_from") || content.include?("turbo_frame_tag")

        # If view has turbo_stream_from, check the controller action has respond_to :turbo_stream
        # and that a .turbo_stream.erb template exists
        base = file.sub(/\.html\.erb$/, "")
        turbo_template = "#{base}.turbo_stream.erb"
        turbo_path = rails_app.root.join(turbo_template)

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
            warnings << "line #{num}: scope chain followed by .#{method} may load all records into memory - consider .pluck or SQL"
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
            warnings << "#{finding[:model]}.all loaded in controller - consider pagination or scoping (line #{finding[:line]})"
          end
        end

        # Check 14: Missing FK indexes on tables referenced in validated files
        if file.start_with?("app/models/") && perf[:missing_fk_indexes]&.any?
          model_name = file.sub("app/models/", "").sub(/\.rb$/, "").tr("/", "::").camelize
          perf[:missing_fk_indexes].each do |finding|
            next unless finding.is_a?(Hash) && finding[:model] == model_name
            warnings << "#{finding[:column]} on #{finding[:table]} - missing index on foreign key (performance)"
          end
        end

        warnings.first(5)
      rescue => e
        $stderr.puts "[rails-ai-context] check_performance_warnings failed: #{e.message}" if ENV["DEBUG"]
        []
      end

      # ── Brakeman security scan (runs once for all files) ───────────

      def self.check_brakeman_security(files)
        return [] unless brakeman_available?

        tracker = Brakeman.run(
          app_path: rails_app.root.to_s,
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
          "[#{w.confidence_name}] #{w.warning_type} - #{loc}: #{w.message}"
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
