# frozen_string_literal: true

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
          when :expect     then extract_expect(node)
          # An encrypted attribute (Lockbox's has_encrypted keeps `<name>_ciphertext`)
          # and a store key are attributes with no column of their own name.
          when :attribute, :attr_accessor, :attr_reader, :attr_writer, :has_encrypted, :encrypts, :attr_encrypted
            extract_virtual_attributes(node)
          # `alias_attribute :name, :lastname` reads the second name's column.
          when :alias_attribute then extract_virtual_attributes(node, only: 1)
          when :store_accessor then extract_virtual_attributes(node, skip: 1)
          when :store then extract_store_accessors(node)
          # An attachment and rich text are records of their own, reached by
          # the name; no column of the model carries it.
          when :has_one_attached, :has_many_attached, :has_rich_text
            extract_virtual_attributes(node, only: 1)
          when :has_secure_password then extract_secure_password(node)
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

        # A positional name is a partial or, in a Ruby file, a template; a leading options hash
        # renders what RenderCalls.options_partials says Rails renders.
        def extract_render(node)
          first = node.arguments&.arguments&.first
          line = node.location.start_line
          case first
          when Prism::StringNode
            @render_calls << { name: first.unescaped, line: line, explicit_partial: false }
          when Prism::KeywordHashNode, Prism::HashNode
            named = first.elements.each_with_object({}) do |elem, found|
              next unless elem.is_a?(Prism::AssocNode) && elem.key.is_a?(Prism::SymbolNode)

              found[elem.key.unescaped] = (elem.value.unescaped if elem.value.is_a?(Prism::StringNode))
            end
            Introspectors::RenderCalls.options_partials(named, block: !node.block.nil?).each do |name|
              @render_calls << { name: name, line: line, explicit_partial: true }
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

        # `has_secure_password :recovery_password` keeps only a
        # `recovery_password_digest` column and defines the attribute, its
        # confirmation and its challenge; the name defaults to `password`.
        def extract_secure_password(node)
          return unless node.receiver.nil?

          first = node.arguments&.arguments&.first
          name = first.is_a?(Prism::SymbolNode) || first.is_a?(Prism::StringNode) ? first.unescaped : "password"
          @virtual_attributes.merge([ name, "#{name}_confirmation", "#{name}_challenge" ])
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
          # The model key from params.require(:model).permit(...) or params.fetch(:model, {}).permit(...)
          require_key = nil
          receiver = node.receiver
          if receiver.is_a?(Prism::CallNode) && (receiver.name == :require || (receiver.name == :fetch && params_call?(receiver.receiver)))
            req_args = receiver.arguments&.arguments || []
            first = req_args.first
            require_key = first.unescaped if first.is_a?(Prism::SymbolNode)
          end
          @permit_calls << { params: params, require_key: require_key, line: node.location.start_line } if params.any?
        end

        def params_call?(node) = node.is_a?(Prism::CallNode) && node.name == :params && node.receiver.nil?

        # `params.expect(post: [ :title ])` requires post and permits its keys.
        def extract_expect(node)
          return unless node.receiver.is_a?(Prism::CallNode) && node.receiver.name == :params && node.receiver.receiver.nil?

          hash = (node.arguments&.arguments || []).find { |arg| arg.is_a?(Prism::KeywordHashNode) || arg.is_a?(Prism::HashNode) }
          hash&.elements&.each do |pair|
            next unless pair.is_a?(Prism::AssocNode) && pair.key.is_a?(Prism::SymbolNode) && pair.value.is_a?(Prism::ArrayNode)

            params = pair.value.elements.grep(Prism::SymbolNode).map(&:unescaped)
            @permit_calls << { params: params, require_key: pair.key.unescaped, line: node.location.start_line } if params.any?
          end
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
          warnings.concat(check_partial_existence(file, visitor ? visitor.render_calls : text_render_calls(content)))
          if visitor
            warnings.concat(check_route_helpers_ast(file, visitor, context))
          else
            warnings.concat(check_route_helpers_regex(file, content, context))
          end
          warnings.concat(check_stimulus_controllers(content, context))
          warnings.concat(check_instance_variable_usage(file, content, context))
          # No check pairs `turbo_stream_from` with a .turbo_stream.erb: the
          # tag subscribes to a channel that broadcasts render their own
          # partials into, and nothing renders a template for it.
        elsif file.end_with?(".rb")
          model = RailsAiContext::Payload.model_for_file(context, file) if file.start_with?("app/models/")
          methods, reaches_base = model_method_names(model, content)
          if visitor
            warnings.concat(check_route_helpers_ast(file, visitor, context))
            warnings.concat(check_partial_existence(file, visitor.render_calls, qualified_only: true))
            warnings.concat(check_column_references_ast(file, visitor, context, methods))
            warnings.concat(check_strong_params_ast(file, visitor, context))
            warnings.concat(check_callback_existence_ast(visitor, model, methods, reaches_base))
          else
            warnings.concat(check_route_helpers_regex(file, content, context))
            warnings.concat(check_column_references_regex(file, content, context, methods))
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
          "# encoding: utf-8\n#{RailsAiContext::ErbSource.compiled(content)}"
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
      # A name resolves the way get_view and the view introspector resolve it.
      private_class_method def self.check_partial_existence(file, render_calls, qualified_only: false)
        return [] if render_calls.empty?

        partials = Introspectors::RenderCalls.partials_on_disk(rails_app.root.to_s)
        folder = File.dirname(file.sub(%r{^app/views/}, ""))
        render_calls.filter_map do |rc|
          ref = rc[:name]
          next unless ref.match?(Introspectors::RenderCalls::PARTIAL_NAME) && !ref.include?("..")
          next if qualified_only && !ref.include?("/")

          key = qualified_only ? ref : Introspectors::RenderCalls.partial_key(ref, folder, partials, prefixes: view_prefixes(folder, ref, partials))
          next if partials.include?(key)
          # In a Ruby file, bare `render "dir/name"` renders the TEMPLATE
          # (only `partial:` has partial semantics there), so accept either.
          template_semantics = qualified_only && !rc[:explicit_partial]
          next if template_semantics && template_exists?(ref)

          label = template_semantics ? "template/partial not found" : "partial not found"
          "render \"#{ref}\" - #{label} (checked: #{File.join(File.dirname(key), "_#{File.basename(key)}").delete_prefix("./")})"
        end
      end

      # The folders a bare partial name is looked up in for a view in `folder`: its controller's, then each
      # parent controller's. A layout has no controller of its own, so the controllers that hold the name stand in.
      # Nil where no controller is known (a mailer or component folder).
      private_class_method def self.view_prefixes(folder, ref, partials)
        return partials.filter_map { |partial| File.dirname(partial) if File.basename(partial) == ref && !partial.start_with?("layouts/") } if folder.split("/").first == "layouts"

        context = cached_context
        controllers = RailsAiContext::Payload.controllers(context)
        name, = RailsAiContext::Payload.controller_for_route_key(context, folder)
        return unless name

        chain = []
        while name && controllers.key?(name) && chain.size < Introspectors::SuperclassChain::MAX_DEPTH
          chain << RailsAiContext::Payload.controller_route_key(context, name)
          name = Introspectors::ActionResolver.resolve_entry_name(controllers, controllers[name][:parent_class], name)
        end
        chain
      end

      private_class_method def self.template_exists?(ref)
        RailsAiContext::ViewFile.each(rails_app.root.to_s, "#{ref}.*").any? { |path, _| RailsAiContext::ViewFile.template?(path) }
      end

      # The partials a template's render calls name, read from its text where its compiled Ruby does not parse.
      private_class_method def self.text_render_calls(content)
        Introspectors::RenderCalls.render_calls(content).flat_map do |_, args, block|
          Introspectors::RenderCalls.partial_names(args, block: block).map { |name| { name: name, explicit_partial: true } }
        end
      end

      # ── CHECK 2: Route helpers (AST) ─────────────────────────────────

      ASSET_HELPER_PREFIXES = %w[image asset font stylesheet javascript audio video file compute_asset auto_discovery_link favicon].freeze
      DEVISE_HELPER_NAMES = %w[session registration password confirmation unlock omniauth_callback user_session user_registration user_password user_confirmation user_unlock].freeze

      # Rails' own engines name every route they draw `rails_*` (Active
      # Storage's rails_blob_url, Action Mailbox's rails_conductor_*), and a
      # static read of the app's route files sees none of them.
      FRAMEWORK_ROUTE_HELPER = /\A(?:(?:new|edit|update)_)?rails_\w+_(?:path|url)\z/

      # Shared by the AST and regex passes: the route names this app defines,
      # and the helper-shaped names that are methods rather than routes - a
      # column's reader, or a helper the app writes itself.
      private_class_method def self.route_helper_scope(file, context)
        routes = Payload.section(context, :routes)
        return nil unless routes && routes[:by_controller]
        valid_names = build_route_name_set(RouteCoverage.all_by_controller(routes))
        return nil if valid_names.empty?

        [ valid_names.merge(direct_route_names), helper_shaped_columns(file, context) | app_helper_methods ]
      end

      private_class_method def self.route_helper_warning(helper, valid_names, methods)
        return nil if methods.include?(helper)

        name = helper.sub(/_(path|url)\z/, "")
        return nil if ASSET_HELPER_PREFIXES.any? { |p| name.start_with?(p) }
        return nil if DEVISE_HELPER_NAMES.include?(name)
        return nil if %w[edit new polymorphic].include?(name)
        return nil if valid_names.include?(name) || url_helper?(helper)

        "#{helper} - route helper not found"
      end

      # Booted, the app's url_helpers answer for every helper its routes
      # define, a `direct` route and the ones Rails' engines draw included;
      # Rails 8 draws routes on first use, so they are drawn first.
      private_class_method def self.url_helper?(helper)
        return helper.match?(FRAMEWORK_ROUTE_HELPER) if RailsAiContext.static_tier?

        app = rails_app
        return false unless app.respond_to?(:routes)

        app.reload_routes_unless_loaded if app.respond_to?(:reload_routes_unless_loaded)
        app.routes.url_helpers.method_defined?(helper)
      rescue StandardError => e
        RailsAiContext.debug_fail(e, false, label: "url_helper?")
      end

      # `direct(:docs)` defines docs_url and docs_path and draws no route, so
      # no row of the route table names it.
      private_class_method def self.direct_route_names
        root = rails_app.root.to_s
        RunCache.fetch([ :direct_route_names, root ]) do
          app_sources(root, "config/routes.rb", "config/routes/**/*.rb").each_with_object(Set.new) do |source, names|
            macro_calls(source, :direct).each { |call| names << call[:args].first.to_s if call[:args].any? }
          end
        end
      end

      # A `*_path` or `*_url` method written in app/helpers, or a controller
      # method helper_method hands to the views, is a method a view calls
      # bare, not a route.
      private_class_method def self.app_helper_methods
        root = rails_app.root.to_s
        RunCache.fetch([ :app_helper_methods, root ]) do
          names = Set.new
          app_sources(root, "app/helpers/**/*.rb").each { |source| names.merge(local_route_like_method_names(source)) }
          app_sources(root, "app/controllers/**/*.rb").each do |source|
            macro_calls(source, :helper_method).each do |call|
              names.merge(call[:args].map(&:to_s).select { |name| name.end_with?("_path", "_url") })
            end
          end
          names
        end
      end

      # The sources the globs name under the app root, skipping a file a
      # symlink carries out of it.
      private_class_method def self.app_sources(root, *patterns)
        patterns.flat_map { |pattern| RailsAiContext::PathResolver.glob(root, pattern) }.uniq.filter_map do |path|
          RailsAiContext::SafeFile.read(path) unless RailsAiContext::PathResolver.linked_out?(path, root)
        end
      end

      private_class_method def self.macro_calls(source, *names)
        Introspectors::SourceIntrospector.walk_source(source, { calls: -> { Introspectors::Listeners::GenericMacroListener.new(*names) } })[:calls]
      end

      private_class_method def self.check_route_helpers_ast(file, visitor, context)
        valid_names, methods = route_helper_scope(file, context)
        return [] unless valid_names

        seen = Set.new
        visitor.route_helper_calls.filter_map do |call|
          helper = call[:name]
          next if seen.include?(helper)
          seen << helper
          next if visitor.local_route_method_defined?(helper, call[:scope], call[:method_kind])

          route_helper_warning(helper, valid_names, methods)
        end
      end

      # Regex fallback
      private_class_method def self.check_route_helpers_regex(file, content, context)
        valid_names, methods = route_helper_scope(file, context)
        return [] unless valid_names

        seen = Set.new
        local_method_names = local_route_like_method_names(content)
        content.scan(/\b(\w+)_(path|url)\b/).filter_map do |name, suffix|
          helper = "#{name}_#{suffix}"
          next if seen.include?(helper)
          seen << helper
          next if local_method_names.include?(helper)

          route_helper_warning(helper, valid_names, methods)
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
        Introspectors::ActionResolver.methods_in(content).map { |m| m[:name].to_s }.select { |name| name.end_with?("_path", "_url") }.to_set
      end

      # An engine's view calls its helpers bare, so `shop.admin_orders` counts as admin_orders.
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

      # A validator reads the value through read_attribute_for_validation, which calls the method.
      private_class_method def self.check_column_references_ast(file, visitor, context, methods)
        warnings = []
        return warnings unless file.start_with?("app/models/")

        valid = model_valid_columns(file, context)
        return warnings unless valid

        visitor.validates_calls.each do |vc|
          vc[:columns].each do |col|
            next if visitor.virtual_attributes.include?(col) || methods.include?(col)

            unless valid[:columns].include?(col)
              warnings << "validates :#{col} - column \"#{col}\" not found in #{valid[:table]} table. Fix: add migration `rails g migration Add#{col.camelize}To#{valid[:table].camelize} #{col}:string` or check concerns"
            end
          end
        end
        warnings
      end

      # Regex fallback
      private_class_method def self.check_column_references_regex(file, content, context, methods)
        warnings = []
        return warnings unless file.start_with?("app/models/")

        valid = model_valid_columns(file, context)
        return warnings unless valid

        content.each_line do |line|
          next unless line.match?(/\A\s*validates\s+:/)
          after = line.sub(/\A\s*validates\s+/, "")
          next if after.include?("acceptance:")
          after.scan(/:(\w+)/).each do |m|
            col = m[0]
            break if after.include?("#{col}:")
            next if col == col.capitalize || methods.include?(col)

            warnings << "validates :#{col} - column \"#{col}\" not found in #{valid[:table]} table" unless valid[:columns].include?(col)
          end
        end
        warnings
      end

      # A dump names a view or a skipped table without its columns; only a connection lists them.
      private_class_method def self.columns_known?(table)
        !(table[:kind] || table[:not_dumped]) || Array(table[:columns]).any?
      end

      # A view, a virtual table or a skipped table takes no index; a materialized view does, once its indexes are known.
      private_class_method def self.indexable?(table)
        return Array(table[:indexes]).any? if table[:kind] == "materialized_view"

        !(table[:kind] || table[:not_dumped])
      end

      # Shared helper: build valid column set for a model file
      private_class_method def self.model_valid_columns(file, context)
        models = Payload.models(context)
        schema = Payload.section(context, :schema)
        return nil if models.empty? || schema.nil?

        model_name, model_data = RailsAiContext::Payload.model_for_file(context, file)
        return nil unless model_data

        table_name = model_data[:table_name]
        table_data = RailsAiContext::Payload.model_schema_table(schema, model_data)
        return nil unless table_data && columns_known?(table_data)

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
          # Only the required key names a model: a bare `params.permit(:page)` reads query-string filters.
          model_name = Introspectors::TableName.model_for(pc[:require_key].to_s.classify, nil, models)
          model_data = model_name && models[model_name]
          next unless model_data

          table_name = model_data[:table_name]
          table_data = RailsAiContext::Payload.model_schema_table(schema, model_data)
          next unless table_data && columns_known?(table_data)

          valid = Set.new
          table_data[:columns]&.each { |c| valid << c[:name] }
          model_data[:associations]&.each { |a| valid << a[:name]; valid.merge(Array(a[:foreign_key])) }
          valid.merge(%w[id _destroy created_at updated_at])
          valid.merge(model_declared_attributes(model_name, context))

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

      # What the model's own source declares with no column of the name
      # (attr_accessor, has_secure_password's password and confirmation, an
      # attachment), which a form permits like any column.
      private_class_method def self.model_declared_attributes(model_name, context)
        file = RailsAiContext::Payload.model_file(context, model_name)
        source = RailsAiContext::SafeFile.read(rails_app.root.join(file)) or return Set.new
        parse_and_visit(file, source)&.virtual_attributes || Set.new
      end

      # ── CHECK 5: Callback method existence (AST) ─────────────────────

      # `model` is the model file's [name, data] from the payload, nil for any other file.
      private_class_method def self.check_callback_existence_ast(visitor, model, known, reaches_base)
        warnings = []
        model_name, model_data = model
        return warnings if model_data.nil? || visitor.callback_registrations.empty?

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
            # Unread on the static tier, a parent the walk could not follow may define it.
            next if live || (live.nil? && (truncated || !reaches_base))

            warnings << "#{reg[:type]} :#{method_name} - method not found in #{model_name}"
          end
        end
        warnings
      end

      # The instance methods the payload lists for a model file's model and every one its file and the app
      # classes it inherits from define, private ones included, and whether that walk reached ActiveRecord::Base.
      private_class_method def self.model_method_names(model, content)
        model_name, model_data = model
        return [ Set.new, false ] unless model_data

        chain = Introspectors::SuperclassChain.to(content, bases: %w[ActiveRecord::Base], only: model_name,
                                                  lookup: Introspectors::SuperclassChain.lookup_for(rails_app.root.to_s))
        names = Set.new(Array(model_data[:instance_methods]))
        [ content, *chain.map(&:source) ].uniq.each do |source|
          Introspectors::ActionResolver.methods_in(source).each { |m| names << m[:name].to_s if m[:scope] == :instance }
        end
        [ names, chain.any? ]
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
        return warnings unless file.start_with?("app/models/")

        models = Payload.models(context)
        return warnings if models.empty?

        _model_name, model_data = RailsAiContext::Payload.model_for_file(context, file)
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
        return warnings unless file.start_with?("app/models/")

        schema = Payload.section(context, :schema)
        models = Payload.models(context)
        return warnings if schema.nil? || models.empty?

        _model_name, model_data = RailsAiContext::Payload.model_for_file(context, file)
        return warnings unless model_data

        table_name = model_data[:table_name]
        table_data = RailsAiContext::Payload.model_schema_table(schema, model_data)
        # A static table whose block called what no reader interprets has columns and indexes unknown.
        return warnings if table_data.nil? || table_data[:unread_calls] || !indexable?(table_data)

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
                        "Fix: `add_index #{Introspectors::SchemaConventions.source_symbol(table_name)}, [#{col.map { |c| Introspectors::SchemaConventions.source_symbol(c) }.join(", ")}]`"
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

        Introspectors::ViewTemplateIntrospector.template_stimulus_refs(content).each do |name|
          next if name.include?("#") # dynamic
          next if name.include?("--") # namespaced npm package
          unless known.include?(name)
            warnings << "data-controller=\"#{name}\" - Stimulus controller not found"
          end
        end
        warnings
      end

      # ── CHECK 10: Instance variable usage in views ─────────────────

      private_class_method def self.check_instance_variable_usage(file, content, context)
        warnings = []
        return warnings unless file.start_with?("app/views/") && !RailsAiContext::ViewFile.in_layouts?(file.delete_prefix("app/views/"))

        ivars = Introspectors::ViewTemplateIntrospector.ivars_in(content, path: file)
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

        # A before_action in ApplicationController or in a concern sets an
        # ivar for this view as surely as the action does, so the controller,
        # its ancestors and the modules they include are all read.
        root = rails_app.root.to_s
        chain = Introspectors::ActionPresence.read(
          root, ctrl_class, ctrl_source, prefix: ctrl_dir,
          lookup: Introspectors::ActionPresence.lookup(root, Payload.section(context, :controllers)&.dig(:controllers))
        )
        sources = chain.sources.any? ? chain.sources : [ ctrl_source ]

        set_ivars = sources.flat_map { |source| Introspectors::ActionResolver.assigned_ivars(source) }.uniq
        # Add common framework ivars that don't appear as explicit assignments
        set_ivars += %w[pagy current_user _request]

        ivars.each do |ivar|
          next if set_ivars.include?(ivar)
          next if ivar.start_with?("_") # framework internal
          next if %w[output_buffer virtual_path].include?(ivar)
          warnings << "@#{ivar} used in view but not set in #{ctrl_class}, its ancestors or the modules they include. " \
                      "Fix: add `@#{ivar} = ...` to action"
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
        return warnings unless content.include?("broadcast_")

        code = RailsAiContext::RubySource.code_only(content)
        broadcasts = []
        RailsAiContext::RubySource.without_comments(content).scan(/broadcast_(?:replace|append|prepend|remove|update|action)_to\s*\(\s*["']([^"']+)["']/) do
          broadcasts << Regexp.last_match(1) unless code[Regexp.last_match.begin(0)] == " "
        end
        return warnings if broadcasts.empty?

        # Scan views for turbo_stream_from subscriptions
        views_dir = rails_app.root.join("app", "views")
        return warnings unless Dir.exist?(views_dir)

        subscriptions = Set.new
        RailsAiContext::FileWalk.glob(views_dir.to_s, "**/*.{erb,html.erb}", root: rails_app.root.to_s).each do |path|
          view_content = RailsAiContext::SafeFile.read(path) or next
          RailsAiContext::ErbSource.tag_bodies(view_content).scan(/turbo_stream_from\s+["']([^"']+)["']/).each do |match|
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

      # ── CHECK: Memory-loading anti-pattern ───────────────────────────
      MEMORY_LOAD_METHODS = %w[map filter_map flat_map select reject collect reduce inject each_with_object].freeze

      private_class_method def self.check_memory_loading(file, content)
        warnings = {}
        Introspectors::AstWalk.each(AstCache.parse_string(content).value) do |node|
          next unless node.is_a?(Prism::CallNode) && MEMORY_LOAD_METHODS.include?(node.name.to_s)
          # `select` with arguments and no block picks SQL columns.
          next unless node.block || (node.arguments && node.name != :select)
          next unless relation_chain?(node.receiver)

          line = (node.message_loc || node.location).start_line
          warnings[line] ||= "line #{line}: scope chain followed by .#{node.name} may load all records into memory - consider .pluck or SQL"
        end
        warnings.sort.map(&:last).first(3) # cap at 3 to avoid noise
      rescue => e
        RailsAiContext.debug_fail(e, [], label: "check_memory_loading")
      end

      # Methods no relation answers with a relation: once one is in the chain, the records are loaded or it was never a query.
      NOT_A_RELATION = %i[pluck ids to_a to_h keys values split to_s chars lines each_line bytes].freeze
      REQUEST_READERS = %i[params session cookies request flash headers].freeze

      # A scope or association chain ending in a call with no arguments (`Post.active`, `current_user.posts`),
      # never one over params or a literal.
      private_class_method def self.relation_chain?(node)
        return false unless node.is_a?(Prism::CallNode) && node.receiver && node.arguments.nil? && node.block.nil?

        while node.is_a?(Prism::CallNode)
          return false if NOT_A_RELATION.include?(node.name) || (node.name == :select && node.arguments)
          return false if node.receiver.nil? && REQUEST_READERS.include?(node.name)

          node = node.receiver
        end
        !node.is_a?(Prism::StringNode) && !node.is_a?(Prism::InterpolatedStringNode) &&
          !node.is_a?(Prism::ArrayNode) && !node.is_a?(Prism::HashNode)
      end

      # ── CHECK 12: Performance warnings from introspector ───────────

      private_class_method def self.check_performance_warnings(file, context)
        warnings = []
        perf = Payload.section(context, :performance)
        return warnings unless perf

        if file.start_with?("app/controllers/") && perf[:model_all_in_controllers]&.any?
          perf[:model_all_in_controllers].each do |finding|
            next unless finding.is_a?(Hash) && finding[:controller] == file
            warnings << "#{finding[:model]}.all loaded in controller - consider pagination or scoping"
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

        root = rails_app.root
        # Brakeman roots an entry by its leading slash, reads a folder by its trailing one, and rates a query lower on an unparsed model.
        # shortcut: a view's warning fed by its controller's params needs both files passed; scan the whole app if that matters more than the seconds.
        only_files = files.map do |f|
          relative = filter_path(f)
          "/#{relative}#{"/" if File.directory?(root.join(relative))}"
        end | [ "/app/models/" ]
        tracker = BrakemanGuard.quietly do
          Brakeman.run(
            app_path: root.to_s,
            only_files: only_files,
            quiet: true,
            report_progress: false,
            print_report: false,
            # Forked parse workers cannot Marshal the Binding web-console's bindex
            # hangs on a parse error, and the crash took every finding with it.
            parallel_checks: false
          )
        end

        warnings = tracker.filtered_warnings
        return {} if warnings.empty?

        # The validated file each warning belongs to: a caller may name a
        # directory, and then every warning under it is that entry's.
        found = {}
        warnings.sort_by.with_index { |w, i| [ w.confidence, i ] }.each do |warning|
          path = warning.file.relative
          owner = files.find { |name| path_matches?(path, name) }
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
          BrakemanGuard.quietly { require "brakeman" }
          true
        rescue LoadError
          false
        end
      end
    end
  end
end
