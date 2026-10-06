# frozen_string_literal: true

require "erb"
require "set"
require "prism"

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
                    :permit_calls, :callback_registrations, :virtual_attributes

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
          @virtual_attributes = Set.new
          @local_method_names_by_scope = Hash.new { |hash, key| hash[key] = Set.new }
          @singleton_method_names_by_scope = Hash.new { |hash, key| hash[key] = Set.new }
          @scope_stack = [ TOP_LEVEL_SCOPE ]
          @method_context_stack = []
          @uncertain_blocks = 0
          @hook_params = []
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
          hook = Introspectors::Listeners::WithOptionsScope.hook_param(node)
          @hook_params << hook if hook
          with_method_context(method_kind) { super }
        ensure
          @hook_params.pop if hook
        end

        def visit_call_node(node)
          case node.name
          when :render     then extract_render(node)
          when :validates  then extract_validates(node) if @uncertain_blocks.zero?
          when :permit     then extract_permit(node)
          # An encrypted attribute (Lockbox's has_encrypted keeps `<name>_ciphertext`)
          # and a store key are attributes with no column of their own name.
          when :attribute, :attr_accessor, :attr_reader, :attr_writer, :has_encrypted, :encrypts, :attr_encrypted
            extract_virtual_attributes(node)
          # `alias_attribute :name, :lastname` reads the second name's column.
          when :alias_attribute then extract_virtual_attributes(node, only: 1)
          when :store_accessor then extract_virtual_attributes(node, skip: 1)
          when :store then extract_store_accessors(node)
          else
            if node.name.to_s.end_with?("_path", "_url") && node.receiver.nil?
              @route_helper_calls << {
                name: node.name.to_s,
                line: node.location.start_line,
                scope: current_scope,
                method_kind: current_method_kind
              }
            elsif CALLBACK_NAMES.include?(node.name) && node.receiver.nil? && @uncertain_blocks.zero?
              extract_callback(node)
            end
          end
          uncertain = Introspectors::Listeners::WithOptionsScope.uncertain_block?(node) { |name| @hook_params.include?(name) }
          @uncertain_blocks += 1 if uncertain
          super
        ensure
          @uncertain_blocks -= 1 if uncertain
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
                if key.is_a?(Prism::SymbolNode) && key.unescaped == "partial" && val.is_a?(Prism::StringNode)
                  @render_calls << { name: val.unescaped, line: node.location.start_line, explicit_partial: true }
                end
              end
            end
          end
        end

        # An attribute validated with `acceptance:` needs no column:
        # ActiveModel defines the reader and the writer when none exists.
        SELF_DEFINING_VALIDATIONS = %w[acceptance].freeze

        def extract_validates(node)
          args = node.arguments&.arguments || []
          columns = []
          args.each do |arg|
            break unless arg.is_a?(Prism::SymbolNode)
            columns << arg.unescaped
          end
          return if columns.empty? || self_defining?(args)

          @validates_calls << { columns: columns, line: node.location.start_line }
        end

        def self_defining?(args)
          args.grep(Prism::KeywordHashNode).any? do |hash|
            hash.elements.grep(Prism::AssocNode).any? do |element|
              element.key.is_a?(Prism::SymbolNode) && SELF_DEFINING_VALIDATIONS.include?(element.key.unescaped)
            end
          end
        end

        # `attribute :foo` and `attr_accessor :foo` are real readers with no
        # column behind them, and a migration for one is a column nobody
        # wants.
        def extract_virtual_attributes(node, skip: 0, only: nil)
          return unless node.receiver.nil?

          args = (node.arguments&.arguments || []).drop(skip)
          (only ? args.first(only) : args).each do |arg|
            @virtual_attributes << arg.unescaped if arg.is_a?(Prism::SymbolNode)
          end
        end

        # `store :settings, accessors: [:color, :size]`
        def extract_store_accessors(node)
          return unless node.receiver.nil?

          hash = (node.arguments&.arguments || []).find { |arg| arg.is_a?(Prism::KeywordHashNode) }
          pair = hash&.elements&.find { |e| e.is_a?(Prism::AssocNode) && e.key.is_a?(Prism::SymbolNode) && e.key.unescaped == "accessors" }
          return unless pair&.value.is_a?(Prism::ArrayNode)

          pair.value.elements.each { |el| @virtual_attributes << el.unescaped if el.is_a?(Prism::SymbolNode) }
        end

        def extract_permit(node)
          args = node.arguments&.arguments || []
          params = []
          args.each do |arg|
            case arg
            when Prism::SymbolNode then params << arg.unescaped
            end
          end
          # Extract model key from params.require(:model).permit(...)
          require_key = nil
          receiver = node.receiver
          if receiver.is_a?(Prism::CallNode) && receiver.name == :require
            req_args = receiver.arguments&.arguments || []
            first = req_args.first
            require_key = first.unescaped if first.is_a?(Prism::SymbolNode)
          end
          @permit_calls << { params: params, require_key: require_key, line: node.location.start_line } if params.any?
        end

        def extract_callback(node)
          args = node.arguments&.arguments || []
          methods = args.select { |a| a.is_a?(Prism::SymbolNode) }.map(&:unescaped)
          @callback_registrations << { type: node.name.to_s, methods: methods, line: node.location.start_line } if methods.any?
        end
      end

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
            # Three AST checks have no regex twin. Saying so keeps a partial
            # answer from reading as "checked and clean".
            warnings << "AST parse failed - strong_params, callback and partial checks skipped for this file"
          end
          # Cache-only checks (no AST needed)
          warnings.concat(check_has_many_dependent(file, context, content))
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
        RailsAiContext.debug_fail(e, nil, label: "parse_and_visit")
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

      # Shared by the AST and regex passes: the route names this app defines,
      # and the helper-shaped columns that are readers rather than routes.
      private_class_method def self.route_helper_scope(file, context)
        routes = Payload.section(context, :routes)
        return nil unless routes && routes[:by_controller]
        valid_names = build_route_name_set(RouteCoverage.all_by_controller(routes))
        return nil if valid_names.empty?

        [ valid_names, helper_shaped_columns(file, context) ]
      end

      private_class_method def self.route_helper_warning(helper, valid_names, columns)
        return nil if columns.include?(helper)

        name = helper.sub(/_(path|url)\z/, "")
        return nil if ASSET_HELPER_PREFIXES.any? { |p| name.start_with?(p) }
        return nil if DEVISE_HELPER_NAMES.include?(name)
        return nil if %w[edit new polymorphic].include?(name)

        "#{helper} - route helper not found" unless valid_names.include?(name)
      end

      private_class_method def self.check_route_helpers_ast(file, visitor, context)
        valid_names, columns = route_helper_scope(file, context)
        return [] unless valid_names

        seen = Set.new
        visitor.route_helper_calls.filter_map do |call|
          helper = call[:name]
          next if seen.include?(helper)
          seen << helper
          next if visitor.local_route_method_defined?(helper, call[:scope], call[:method_kind])

          route_helper_warning(helper, valid_names, columns)
        end
      end

      # Regex fallback
      private_class_method def self.check_route_helpers_regex(file, content, context)
        valid_names, columns = route_helper_scope(file, context)
        return [] unless valid_names

        seen = Set.new
        local_method_names = local_route_like_method_names(content)
        content.scan(/\b(\w+)_(path|url)\b/).filter_map do |name, suffix|
          helper = "#{name}_#{suffix}"
          next if seen.include?(helper)
          seen << helper
          next if local_method_names.include?(helper)

          route_helper_warning(helper, valid_names, columns)
        end
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

      # An engine's view calls its helpers bare, so `spree.admin_orders` counts as admin_orders.
      private_class_method def self.build_route_name_set(by_controller)
        names = Set.new
        by_controller.each_value do |actions|
          actions.each do |a|
            next unless a[:name]
            name = a[:name].split(".").last
            names << name
            names << "edit_#{name}"
            names << "new_#{name}"
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
            next if visitor.virtual_attributes.include?(col)

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
          next if after.include?("acceptance:")
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
        models = Payload.models(context)
        schema = Payload.section(context, :schema)
        return nil if models.empty? || schema.nil?

        model_name, model_data = RailsAiContext::Payload.model_for_file(context, file)
        return nil unless model_data

        table_name = model_data[:table_name]
        table_data = RailsAiContext::Payload.model_table(schema, model_data)
        return nil unless table_data

        table_columns = Set.new
        table_data[:columns]&.each { |c| table_columns << c[:name] }

        columns = table_columns.dup
        model_data[:associations]&.each do |a|
          columns << a[:name] if a[:name]
          columns.merge(Array(a[:foreign_key]))
        end

        { columns: columns, table_columns: table_columns, table: table_name, model: model_name, model_data: model_data }
      end

      # ── CHECK 4: Strong params vs schema (AST) ───────────────────────

      private_class_method def self.check_strong_params_ast(file, visitor, context)
        warnings = []
        return warnings unless file.start_with?("app/controllers/")
        return warnings if visitor.permit_calls.empty?

        schema = Payload.section(context, :schema)
        models = Payload.models(context)
        return warnings if schema.nil? || models.empty?

        visitor.permit_calls.each do |pc|
          # Infer model: prefer require_key (:post → Post), fall back to controller filename
          guess = pc[:require_key] ? pc[:require_key].to_s.classify : File.basename(file, ".rb").sub(/_controller$/, "").classify
          model_name = Introspectors::TableName.model_for(guess, nil, models)
          model_data = model_name && models[model_name]
          next unless model_data

          table_name = model_data[:table_name]
          table_data = RailsAiContext::Payload.model_table(schema, model_data)
          next unless table_data

          valid = Set.new
          table_data[:columns]&.each { |c| valid << c[:name] }
          model_data[:associations]&.each { |a| valid << a[:name]; valid.merge(Array(a[:foreign_key])) }
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

        models = Payload.models(context)
        return warnings if models.empty?

        model_name, model_data = RailsAiContext::Payload.model_for_file(context, file)
        return warnings unless model_data

        # Build set of known methods (instance + from source content)
        known = Set.new(model_data[:instance_methods] || [])
        # Also check the file source for private methods
        source = RailsAiContext::SafeFile.read(rails_app.root.join(file))
        source&.scan(/\bdef\s+(\w+[?!]?)/)&.each { |m| known << m[0] }

        # Skip check if model has concerns (method may be in concern)
        has_concerns = (model_data[:concerns] || []).any?
        # The payload's list is capped, so past the cap an inherited method
        # is not in it and its absence says nothing.
        truncated = model_data[:instance_method_count].to_i > Array(model_data[:instance_methods]).size

        visitor.callback_registrations.each do |reg|
          reg[:methods].each do |method_name|
            next if known.include?(method_name)
            next if has_concerns # uncertain - method may come from concern

            live = live_method_defined?(model_name, method_name)
            next if live || (live.nil? && truncated)

            warnings << "#{reg[:type]} :#{method_name} - method not found in #{model_name}"
          end
        end
        warnings
      end

      # ── CHECK 6: Route-action consistency (cache only) ───────────────

      private_class_method def self.check_route_action_consistency(file, context)
        warnings = []
        return warnings unless file.start_with?("app/controllers/")

        routes = Payload.section(context, :routes)
        controllers = Payload.section(context, :controllers)
        return warnings unless routes && controllers

        # Map file to controller name: app/controllers/posts_controller.rb → posts
        relative = file.sub("app/controllers/", "").sub(/_controller\.rb$/, "")
        ctrl_class = RailsAiContext::Payload.controller_for_route_key(context, relative)&.first

        # Get controller actions
        ctrl_data = controllers[:controllers] && controllers[:controllers][ctrl_class]
        return warnings unless ctrl_data
        actions = Set.new(ctrl_data[:actions] || [])

        # Get routes pointing to this controller
        route_actions = RouteCoverage.all_by_controller(routes)[relative]
        return warnings unless route_actions

        missing = route_actions.reject { |route| route[:action].nil? || actions.include?(route[:action].to_s) }
        return warnings if missing.empty?

        root = rails_app.root.to_s
        chain = Introspectors::ActionPresence.read(
          root, ctrl_class, SafeFile.read(File.join(root, "app/controllers/#{relative}_controller.rb")),
          prefix: relative, lookup: Introspectors::ActionPresence.lookup(root, controllers[:controllers])
        )
        missing = missing.reject do |route|
          action = route[:action].to_s
          chain.defines?(action) || Introspectors::ActionPresence.template?(root, chain, action)
        end
        return warnings if missing.empty?

        unread = chain.unread
        if unread.any?
          names = missing.map { |route| route[:action].to_s }.uniq
          return warnings << "routes to #{names.join(', ')} have no method in #{ctrl_class}'s own sources or ancestors and no " \
                             "template, but #{unread.uniq.join(', ')} #{unread.uniq.size == 1 ? 'is' : 'are'} not read here " \
                             "(a gem or unread ancestor may define them)"
        end

        missing.each do |route|
          action = route[:action]
          warnings << "route #{route[:verb]} #{route[:path]} \u2192 #{action} - action not found in #{ctrl_class}. Fix: add `def #{action}; end` to #{ctrl_class} or remove the route"
        end
        warnings
      end

      # ── CHECK 7: has_many without :dependent (cache only) ────────────

      # Only what this file declares is judged: a has_many a gem macro adds (paper_trail's
      # `:versions`) has no line in the app to fix.
      private_class_method def self.check_has_many_dependent(file, context, content)
        warnings = []
        return warnings unless file.start_with?("app/models/") && !file.include?("/concerns/")

        models = Payload.models(context)
        return warnings if models.empty?

        model_name, model_data = RailsAiContext::Payload.model_for_file(context, file)
        return warnings unless model_data

        declared = Introspectors::SourceIntrospector
          .walk_source(content.to_s, { associations: Introspectors::Listeners::AssociationsListener })[:associations]
          .reject { |a| a[:scope_uncertain] }
          .map { |a| a[:name].to_s }.to_set

        (model_data[:associations] || []).each do |assoc|
          next unless assoc[:type] == "has_many"
          next unless declared.include?(assoc[:name].to_s)
          next if assoc[:through] # through associations don't need dependent
          next if assoc[:dependent] # already has dependent
          warnings << "has_many #{Serializers::SectionFacts.association_name(assoc)} - missing :dependent option (orphaned records risk). Fix: add `dependent: :destroy` or `:nullify`"
        end
        warnings
      end

      # ── CHECK 8: Missing FK index (cache only) ──────────────────────

      private_class_method def self.check_missing_fk_index(file, context)
        warnings = []
        return warnings unless file.start_with?("app/models/") && !file.include?("/concerns/")

        schema = Payload.section(context, :schema)
        models = Payload.models(context)
        return warnings if schema.nil? || models.empty?

        _model_name, model_data = RailsAiContext::Payload.model_for_file(context, file)
        return warnings unless model_data

        table_name = model_data[:table_name]
        table_data = RailsAiContext::Payload.model_table(schema, model_data)
        # A static table whose block called what no reader interprets has columns and indexes unknown.
        return warnings if table_data.nil? || table_data[:unread_calls]

        # Only flag columns that are ACTUAL foreign keys (declared via add_foreign_key or belongs_to)
        declared_fk_columns = (table_data[:foreign_keys] || []).map { |fk| fk[:column] }
        belongs_to = (model_data[:associations] || []).select { |a| a[:type] == "belongs_to" && column_key?(a) }
        table_columns = Array(table_data[:columns]).map { |c| c[:name].to_s }
        # A key the table lacks is a broken association, not an unindexed column.
        absent, belongs_to = belongs_to.partition do |a|
          table_columns.any? && !(Array(a[:foreign_key]).map(&:to_s) - table_columns).empty?
        end
        absent.each do |a|
          warnings << "belongs_to :#{a[:name]} - column \"#{Introspectors::SchemaConventions.key_text(a[:foreign_key])}\" not found in #{table_name} table. " \
                      "Fix: pass `foreign_key:` naming the real column, or add the column"
        end
        fk_columns = (declared_fk_columns + belongs_to.map { |a| a[:foreign_key] }).uniq

        indexed = Introspectors::SchemaConventions.lookup_indexed_columns(table_data)
        polymorphic_pairs = (model_data[:associations] || [])
          .select { |a| a[:type] == "belongs_to" && a[:polymorphic] && a[:foreign_key] }
          .to_h { |a| [ a[:foreign_key].to_s, [ (a[:foreign_type] || a.dig(:options, :foreign_type) || "#{a[:name]}_type").to_s, a[:foreign_key].to_s ] ] }

        fk_columns.each do |col|
          # `t.references polymorphic: true` indexes [type, id], led by the type.
          pair = polymorphic_pairs[col.to_s]
          next if pair && Introspectors::SchemaConventions.leading_index?(table_data[:indexes], pair)

          if col.is_a?(Array)
            primary_key = { columns: Array(table_data[:primary_key] || table_data.dig(:options, :primary_key)) }
            next if Introspectors::SchemaConventions.leading_index?(Array(table_data[:indexes]) + [ primary_key ], col)

            warnings << "#{Introspectors::SchemaConventions.key_text(col)} in #{table_name} - foreign key without an index leading with its columns (slow queries). " \
                        "Fix: `add_index :#{table_name}, [#{col.map { |c| ":#{c}" }.join(", ")}]`"
          elsif !indexed.include?(col)
            warnings << "#{col} in #{table_name} - foreign key without index (slow queries). Fix: `rails g migration AddIndexTo#{table_name.camelize} #{col}:index`"
          end
        end
        warnings
      end

      # A key the source names as columns, on a declaration the class itself makes.
      private_class_method def self.column_key?(assoc)
        return false if assoc[:computed_foreign_key] || assoc[:scope_uncertain]

        columns = Array(assoc[:foreign_key])
        columns.any? && columns.all? { |c| c.to_s.match?(/\A\w+\z/) }
      end

      # ── CHECK 9: Stimulus controller existence ───────────────────────

      private_class_method def self.check_stimulus_controllers(content, context)
        warnings = []
        stimulus = Payload.section(context, :stimulus)
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

        # Tag bodies only, so HTML and JS text cannot look like an ivar. The
        # in-place form blanks `<%#` comments, whose bodies are not code.
        erb_content = RailsAiContext::ErbSource.ruby_in_place(content)
        ivars = erb_content.scan(/@(\w+)/).flatten.uniq
        return warnings if ivars.empty?

        # Try to find the controller that renders this view
        parts = file.sub("app/views/", "").split("/")
        return warnings if parts.size < 2

        # A view directory names the route key, not the constant: camelizing
        # app/views/activitypub/ back gives Activitypub, which is not what the
        # app declares, and the check then stops running for that whole tree.
        ctrl_dir = parts[0..-2].join("/")
        ctrl_class, ctrl_data = RailsAiContext::Payload.controller_for_route_key(context, ctrl_dir)
        return warnings unless ctrl_data

        # Get all instance variables set across all actions
        ctrl_file = RailsAiContext::Payload.controller_file(context, ctrl_class)
        return warnings unless ctrl_file

        source_path = rails_app.root.join(ctrl_file)
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
        RailsAiContext.debug_fail(e, [], label: "check_instance_variable_usage")
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
        RailsAiContext.debug_fail(e, [], label: "check_turbo_stream_channels")
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
        RailsAiContext.debug_fail(e, [], label: "check_respond_to_template_existence")
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
        RailsAiContext.debug_fail(e, [], label: "check_memory_loading")
      end

      # ── CHECK 13: Performance warnings from introspector ───────────

      private_class_method def self.check_performance_warnings(file, context)
        warnings = []
        perf = Payload.section(context, :performance)
        return warnings unless perf

        if file.start_with?("app/controllers/") && perf[:model_all_in_controllers]&.any?
          perf[:model_all_in_controllers].each do |finding|
            next unless finding.is_a?(Hash) && finding[:file]&.end_with?(File.basename(file))
            warnings << "#{finding[:model]}.all loaded in controller - consider pagination or scoping (line #{finding[:line]})"
          end
        end

        warnings.first(5)
      rescue => e
        RailsAiContext.debug_fail(e, [], label: "check_performance_warnings")
      end

      # ── Brakeman security scan (runs once for all files) ───────────

      # @return [Hash{String => Array<String>}] findings by the validated file
      #   they belong to
      def self.check_brakeman_security(files)
        return {} unless brakeman_available?

        tracker = Brakeman.run(
          app_path: rails_app.root.to_s,
          quiet: true,
          report_progress: false,
          print_report: false
        )

        warnings = tracker.filtered_warnings
        return {} if warnings.empty?

        # The validated file each warning belongs to: a caller may name a
        # directory, and then every warning under it is that entry's.
        normalized = files.to_h { |f| [ f.delete_prefix("/"), f ] }
        found = {}
        warnings.sort_by(&:confidence).each do |warning|
          path = warning.file.relative
          owner = normalized.find { |name, _| path == name || path.start_with?(name) }&.last
          next unless owner
          break if found.values.sum(&:size) >= 5

          loc = warning.line ? "#{path}:#{warning.line}" : path
          (found[owner] ||= []) << "[#{warning.confidence_name}] #{warning.warning_type} - #{loc}: #{warning.message}"
        end
        found
      rescue => e
        RailsAiContext.debug_fail(e, {}, label: "check_brakeman_security")
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
