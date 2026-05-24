# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    # Discovers controllers and extracts filters, strong params,
    # respond_to formats, concerns, actions, and API detection.
    # Uses source-file parsing (not just Ruby reflection) so that
    # changes made mid-session are always visible.
    class ControllerIntrospector
      attr_reader :app

      def excluded_filters
        RailsAiContext.configuration.excluded_filters
      end

      def initialize(app)
        @app = app
      end

      def call
        eager_load_controllers!
        controllers = discover_controllers

        result = controllers.each_with_object({}) do |ctrl, hash|
          hash[ctrl.name] = extract_controller_details(ctrl)
        rescue => e
          hash[ctrl.name] = { error: e.message }
        end

        # Discover controllers from filesystem that may not be loaded as classes
        discover_from_filesystem.each do |name, path|
          next if result.key?(name)
          result[name] = extract_details_from_source(path)
        end

        { controllers: result }
      rescue => e
        { error: e.message }
      end

      private

      def eager_load_controllers!
        return if Rails.application.config.eager_load

        # Use targeted eager_load_dir to pick up newly created controller files
        controllers_path = File.join(app.root, "app", "controllers")
        if defined?(Zeitwerk) && Dir.exist?(controllers_path) &&
           Rails.autoloaders.respond_to?(:main) && Rails.autoloaders.main.respond_to?(:eager_load_dir)
          Rails.autoloaders.main.eager_load_dir(controllers_path)
        else
          Rails.application.eager_load!
        end
      rescue => e
        $stderr.puts "[rails-ai-context] eager_load_controllers! failed: #{e.message}" if ENV["DEBUG"]
        nil
      end

      def discover_controllers
        return [] unless defined?(ActionController::Base)

        bases = [ ActionController::Base ]
        bases << ActionController::API if defined?(ActionController::API)

        bases.flat_map(&:descendants).reject do |ctrl|
          ctrl.name.nil? || ctrl.name == "ApplicationController" ||
            ctrl.name.start_with?("Rails::", "ActionMailbox::", "ActiveStorage::")
        end.uniq.sort_by(&:name)
      end

      # Scan filesystem for controller files not yet loaded as classes
      def discover_from_filesystem
        controllers_dir = File.join(app.root, "app", "controllers")
        return {} unless Dir.exist?(controllers_dir)

        Dir.glob(File.join(controllers_dir, "**/*_controller.rb")).each_with_object({}) do |path, hash|
          relative = path.sub("#{controllers_dir}/", "")
          class_name = relative.sub(/\.rb\z/, "").split("/").map(&:camelize).join("::")
          next if class_name == "ApplicationController"
          next if class_name.start_with?("Rails::", "ActionMailbox::", "ActiveStorage::")
          hash[class_name] = path
        end
      end

      # Extract details purely from source file (for controllers not loaded as classes)
      def extract_details_from_source(path)
        source = RailsAiContext::SafeFile.read(path)
        return { error: "unreadable" } unless source
        parent = extract_parent_class_ast(source)
        rate_limit_raw = extract_rate_limit(source)
        details = {
          parent_class: parent,
          api_controller: parent.include?("API"),
          actions: extract_actions_from_source(source),
          filters: extract_filters_from_source(source),
          concerns: extract_concerns_from_source(source),
          strong_params: extract_strong_params(source),
          respond_to_formats: extract_respond_to(source),
          rescue_from: extract_rescue_from(source),
          rate_limit: rate_limit_raw,
          rate_limit_parsed: parse_rate_limit(rate_limit_raw),
          turbo_stream_actions: extract_turbo_stream_actions(source)
        }.compact
        details
      rescue => e
        { error: e.message }
      end

      def extract_controller_details(ctrl)
        source = read_source(ctrl)
        rate_limit_raw = extract_rate_limit(source)

        {
          parent_class: ctrl.superclass.name,
          api_controller: api_controller?(ctrl),
          actions: extract_actions(ctrl, source),
          filters: extract_filters(ctrl, source),
          concerns: extract_concerns(ctrl),
          strong_params: extract_strong_params(source),
          respond_to_formats: extract_respond_to(source),
          rescue_from: extract_rescue_from(source),
          rate_limit: rate_limit_raw,
          rate_limit_parsed: parse_rate_limit(rate_limit_raw),
          turbo_stream_actions: extract_turbo_stream_actions(source)
        }.compact
      end

      def api_controller?(ctrl)
        return true if defined?(ActionController::API) && ctrl.ancestors.include?(ActionController::API)
        false
      end

      # Prefer source-based parsing for actions — always reflects current file state.
      # Falls back to reflection for controllers without readable source files.
      def extract_actions(ctrl, source = nil)
        if source
          actions = extract_actions_from_source(source)
          return actions if actions.any?
        end
        ctrl.action_methods.to_a.sort
      rescue => e
        $stderr.puts "[rails-ai-context] extract_actions failed: #{e.message}" if ENV["DEBUG"]
        []
      end

      def extract_actions_from_source(source)
        ast_result = SourceIntrospector.walk_source(source, {
          methods: Listeners::MethodsListener
        })
        methods = ast_result[:methods] || []
        methods
          .select { |m| m[:scope] == :instance && m[:visibility] == :public }
          .map { |m| m[:name] }
          .reject { |name| name.start_with?("_") }
          .sort
      rescue => e
        $stderr.puts "[rails-ai-context] extract_actions_from_source AST failed: #{e.message}" if ENV["DEBUG"]
        []
      end

      # Hybrid approach: reflection for complete filter names (handles inheritance + skips),
      # source parsing from inheritance chain for only/except constraints.
      def extract_filters(ctrl, source = nil)
        if ctrl.respond_to?(:_process_action_callbacks)
          reflection_filters = ctrl._process_action_callbacks.filter_map do |cb|
            next if cb.filter.is_a?(Proc) || cb.filter.to_s.start_with?("_")
            next if excluded_filters.include?(cb.filter.to_s)
            { name: cb.filter.to_s, kind: cb.kind.to_s }
          end

          if reflection_filters.any?
            # Collect only/except constraints from source files in the inheritance chain
            source_constraints = collect_source_constraints(ctrl, source)
            reflection_filters.each do |f|
              if (sc = source_constraints[f[:name]])
                f[:only] = sc[:only] if sc[:only]&.any?
                f[:except] = sc[:except] if sc[:except]&.any?
                f[:unless] = sc[:unless] if sc[:unless]
                f[:if] = sc[:if] if sc[:if]
              end
            end

            # Evaluate known runtime conditions to remove inapplicable filters
            reflection_filters.reject! { |f| filter_excluded_by_condition?(ctrl, f) }

            return reflection_filters
          end
        end

        # Fallback to source parsing when reflection is unavailable
        if source
          filters = extract_filters_from_source(source)
          return filters if filters.any?
        end

        []
      rescue => e
        $stderr.puts "[rails-ai-context] extract_filters failed: #{e.message}" if ENV["DEBUG"]
        []
      end

      # Walk up the controller inheritance chain and collect filter constraints from source files
      def collect_source_constraints(ctrl, current_source = nil)
        constraints = {}
        klass = ctrl
        while klass && klass.name
          break if klass.name.start_with?("ActionController::", "AbstractController::")
          break if klass == ActionController::Base
          break if defined?(ActionController::API) && klass == ActionController::API

          src = (klass == ctrl) ? (current_source || read_source(klass)) : read_source(klass)
          if src
            extract_filters_from_source(src).each do |sf|
              # First definition wins (most specific controller in chain)
              constraints[sf[:name]] ||= sf
            end
          end
          klass = klass.superclass
        end
        constraints
      rescue => e
        $stderr.puts "[rails-ai-context] collect_source_constraints failed: #{e.message}" if ENV["DEBUG"]
        {}
      end

      def extract_filters_from_source(source)
        filter_macros = %i[
          before_action after_action around_action
          prepend_before_action append_before_action
          skip_before_action skip_after_action append_after_action
        ]
        ast_result = SourceIntrospector.walk_source(source, {
          filters: -> { Listeners::GenericMacroListener.new(*filter_macros) }
        })
        raw = ast_result[:filters] || []
        raw.filter_map do |entry|
          name_sym = entry[:args]&.first
          next unless name_sym
          kind = entry[:macro].to_s.sub(/_action\z/, "").sub(/\A(?:prepend|append|skip)_/, "")
          filter = { name: name_sym.to_s, kind: kind }

          opts = entry[:options] || {}
          only = normalize_constraint(opts[:only])
          except = normalize_constraint(opts[:except])
          filter[:only] = only if only&.any?
          filter[:except] = except if except&.any?

          if opts[:unless]
            filter[:unless] = opts[:unless].to_s
          end
          if opts[:if]
            filter[:if] = opts[:if].to_s
          end

          filter
        end
      rescue => e
        $stderr.puts "[rails-ai-context] extract_filters_from_source AST failed: #{e.message}" if ENV["DEBUG"]
        []
      end

      # Normalize constraint values from AST extraction.
      # Could be a single symbol, an array of symbols, or a string.
      def normalize_constraint(value)
        case value
        when Array then value.map(&:to_s)
        when Symbol then [ value.to_s ]
        when String then [ value ]
        when nil then nil
        else [ value.to_s ]
        end
      end

      # Statically evaluate known runtime conditions to exclude inapplicable filters.
      # e.g., `unless: :devise_controller?` on a Devise controller means the filter doesn't apply.
      def filter_excluded_by_condition?(ctrl, filter)
        # unless: :devise_controller? — filter does NOT apply to Devise controllers
        if filter[:unless] == "devise_controller?"
          return true if devise_controller?(ctrl)
        end

        # if: :devise_controller? — filter ONLY applies to Devise controllers
        if filter[:if] == "devise_controller?"
          return true unless devise_controller?(ctrl)
        end

        false
      end

      def devise_controller?(ctrl)
        return false unless defined?(::DeviseController)
        ctrl < ::DeviseController || ctrl.ancestors.any? { |a| a.name&.start_with?("Devise::") }
      rescue => e
        $stderr.puts "[rails-ai-context] devise_controller? failed: #{e.message}" if ENV["DEBUG"]
        false
      end

      def extract_action_condition(condition)
        return nil unless condition.is_a?(String) || condition.respond_to?(:to_s)
        match = condition.to_s.match(/action_name\s*==\s*['"](\w+)['"]/)
        match ? [ match[1] ] : nil
      end

      def extract_concerns(ctrl)
        ctrl.ancestors
          .select { |mod| mod.is_a?(Module) && !mod.is_a?(Class) }
          .reject { |mod| mod.name&.start_with?("ActionController", "ActionDispatch", "ActiveSupport", "AbstractController") }
          .map(&:name)
          .compact
      rescue => e
        $stderr.puts "[rails-ai-context] extract_concerns failed: #{e.message}" if ENV["DEBUG"]
        []
      end

      def extract_concerns_from_source(source)
        result = AstCache.parse_string(source)
        concerns = []
        find_include_calls(result.value, concerns)
        concerns
      rescue => e
        $stderr.puts "[rails-ai-context] extract_concerns_from_source AST failed: #{e.message}" if ENV["DEBUG"]
        []
      end

      def find_include_calls(node, concerns)
        return unless node.respond_to?(:child_nodes)
        if node.is_a?(Prism::CallNode) && node.receiver.nil? && node.name == :include
          node.arguments&.arguments&.each do |arg|
            name = constant_node_to_string(arg)
            concerns << name unless name == "Unknown"
          end
        end
        node.child_nodes.compact.each { |child| find_include_calls(child, concerns) }
      end

      def extract_strong_params(source)
        return [] if source.nil?

        parse_result = AstCache.parse_string(source)
        param_methods = []
        find_param_methods(parse_result.value, param_methods)
        param_methods
      rescue => e
        $stderr.puts "[rails-ai-context] extract_strong_params AST failed: #{e.message}" if ENV["DEBUG"]
        []
      end

      # Also keep extract_permit_details for specs that call it directly
      def extract_permit_details(source, method_name)
        result = { name: method_name }
        parse_result = AstCache.parse_string(source)
        def_node = find_def_node(parse_result.value, method_name)
        return result unless def_node

        permit_bang = find_call_in_tree(def_node.body, :permit!)
        if permit_bang && call_on_params?(permit_bang)
          result[:unrestricted] = true
          return result
        end

        permit_call = find_call_in_tree(def_node.body, :permit)
        return result unless permit_call

        # Walk up the receiver chain for require
        require_call = find_require_in_chain(permit_call)
        if require_call
          req_arg = require_call.arguments&.arguments&.first
          result[:requires] = extract_ast_value(req_arg).to_s if req_arg
        end

        result.merge(parse_permit_args_ast(permit_call))
      end

      def find_param_methods(node, results)
        return unless node.respond_to?(:child_nodes)
        if node.is_a?(Prism::DefNode) && node.name.to_s.end_with?("_params")
          details = extract_permit_from_def(node)
          results << details
        end
        node.child_nodes.compact.each { |child| find_param_methods(child, results) }
      end

      def extract_permit_from_def(def_node)
        result = { name: def_node.name.to_s }

        permit_bang = find_call_in_tree(def_node.body, :permit!)
        if permit_bang && call_on_params?(permit_bang)
          result[:unrestricted] = true
          return result
        end

        permit_call = find_call_in_tree(def_node.body, :permit)
        return result unless permit_call

        require_call = find_require_in_chain(permit_call)
        if require_call
          req_arg = require_call.arguments&.arguments&.first
          result[:requires] = extract_ast_value(req_arg).to_s if req_arg
        end

        result.merge(parse_permit_args_ast(permit_call))
      end

      def find_def_node(node, method_name)
        return nil unless node.respond_to?(:child_nodes)
        if node.is_a?(Prism::DefNode) && node.name.to_s == method_name
          return node
        end
        node.child_nodes.compact.each do |child|
          found = find_def_node(child, method_name)
          return found if found
        end
        nil
      end

      def find_call_in_tree(node, method_name)
        return nil unless node.respond_to?(:child_nodes)
        if node.is_a?(Prism::CallNode) && node.name == method_name
          return node
        end
        node.child_nodes.compact.each do |child|
          found = find_call_in_tree(child, method_name)
          return found if found
        end
        nil
      end

      def call_on_params?(node)
        receiver = node.receiver
        return false unless receiver
        return true if receiver.is_a?(Prism::CallNode) && receiver.name == :params
        call_on_params?(receiver) if receiver.is_a?(Prism::CallNode)
      end

      def find_require_in_chain(node)
        receiver = node.receiver
        return nil unless receiver.is_a?(Prism::CallNode)
        return receiver if receiver.name == :require
        find_require_in_chain(receiver)
      end

      def parse_permit_args_ast(permit_call)
        permits = []
        nested = {}
        arrays = []

        args = permit_call.arguments&.arguments || []
        args.each do |arg|
          case arg
          when Prism::SymbolNode
            permits << arg.value.to_s
          when Prism::KeywordHashNode
            arg.elements.each do |assoc|
              next unless assoc.is_a?(Prism::AssocNode)
              key = extract_ast_value(assoc.key).to_s
              val = assoc.value
              if val.is_a?(Prism::ArrayNode)
                inner = val.elements.map { |e| extract_ast_value(e).to_s }
                if inner.any? { |v| v != "" && v != "inferred" }
                  nested[key] = inner.reject { |v| v == "" || v == "inferred" }
                else
                  arrays << key
                end
              else
                permits << key
              end
            end
          when Prism::AssocSplatNode
            # **opts style - skip
          end
        end

        result = {}
        result[:permits] = permits if permits.any?
        result[:nested] = nested if nested.any?
        result[:arrays] = arrays if arrays.any?
        result
      end

      def extract_ast_value(node)
        case node
        when Prism::SymbolNode       then node.value.to_s
        when Prism::StringNode       then node.unescaped
        when Prism::IntegerNode      then node.value
        when Prism::ConstantReadNode then node.name.to_s
        else "inferred"
        end
      end

      def extract_respond_to(source)
        return [] if source.nil?

        parse_result = AstCache.parse_string(source)
        # Only extract format calls inside respond_to blocks
        respond_to_blocks = []
        find_respond_to_blocks(parse_result.value, respond_to_blocks)
        return [] if respond_to_blocks.empty?

        formats = []
        respond_to_blocks.each { |block| find_format_calls(block, formats) }
        formats.uniq.sort
      rescue => e
        $stderr.puts "[rails-ai-context] extract_respond_to AST failed: #{e.message}" if ENV["DEBUG"]
        []
      end

      def find_respond_to_blocks(node, blocks)
        return unless node.respond_to?(:child_nodes)
        if node.is_a?(Prism::CallNode) && node.name == :respond_to && node.block
          blocks << node.block
        end
        node.child_nodes.compact.each { |child| find_respond_to_blocks(child, blocks) }
      end

      def find_format_calls(node, formats)
        return unless node.respond_to?(:child_nodes)
        if node.is_a?(Prism::CallNode) && node.receiver
          receiver = node.receiver
          is_format = case receiver
          when Prism::LocalVariableReadNode then receiver.name == :format
          when Prism::CallNode then receiver.name == :format && receiver.receiver.nil?
          else false
          end
          formats << node.name.to_s if is_format
        end
        node.child_nodes.compact.each { |child| find_format_calls(child, formats) }
      end

      def extract_rescue_from(source)
        return [] if source.nil?

        ast_result = SourceIntrospector.walk_source(source, {
          rescue_from: -> { Listeners::GenericMacroListener.new(:rescue_from) }
        })
        raw = ast_result[:rescue_from] || []
        raw.flat_map do |entry|
          handler = entry[:options][:with]&.to_s
          # Extract constant arguments (exception classes)
          exceptions = extract_constant_args_from_source(source, entry[:location])
          exceptions = entry[:args].map(&:to_s) if exceptions.empty?
          exceptions.map { |ex| { exception: ex, handler: handler }.compact }
        end
      rescue => e
        $stderr.puts "[rails-ai-context] extract_rescue_from AST failed: #{e.message}" if ENV["DEBUG"]
        []
      end

      # For rescue_from, we need constants (not symbols). GenericMacroListener's
      # extract_symbol_args skips them. Walk the AST for the specific call node
      # at the given line to get ConstantReadNode/ConstantPathNode args.
      def extract_constant_args_from_source(source, line_number)
        parse_result = AstCache.parse_string(source)
        constants = []
        find_call_at_line(parse_result.value, :rescue_from, line_number, constants)
        constants
      end

      def find_call_at_line(node, method_name, line_number, constants)
        return unless node.respond_to?(:child_nodes)
        if node.is_a?(Prism::CallNode) && node.name == method_name &&
           node.location.start_line == line_number
          node.arguments&.arguments&.each do |arg|
            case arg
            when Prism::ConstantReadNode
              constants << arg.name.to_s
            when Prism::ConstantPathNode
              constants << constant_node_to_string(arg)
            end
          end
          return
        end
        node.child_nodes.compact.each { |child| find_call_at_line(child, method_name, line_number, constants) }
      end

      def extract_rate_limit(source)
        return nil if source.nil?

        ast_result = SourceIntrospector.walk_source(source, {
          rate_limit: -> { Listeners::GenericMacroListener.new(:rate_limit) }
        })
        entries = ast_result[:rate_limit] || []
        return nil if entries.empty?

        entry = entries.first
        line_num = entry[:location]
        lines = source.lines
        return nil unless line_num && line_num > 0 && line_num <= lines.size

        raw_line = lines[line_num - 1].strip
        raw_line.sub(/\Arate_limit\s+/, "")
      rescue => e
        $stderr.puts "[rails-ai-context] extract_rate_limit AST failed: #{e.message}" if ENV["DEBUG"]
        nil
      end

      def parse_rate_limit(rate_limit_raw)
        return nil if rate_limit_raw.nil?

        parsed = {}
        parsed[:to] = $1.to_i if rate_limit_raw.match(/to:\s*(\d+)/)
        parsed[:within] = $1 if rate_limit_raw.match(/within:\s*(\S+)/)
        parsed[:only] = $1.scan(/:(\w+)/).flatten if rate_limit_raw.match(/only:\s*(.+?)(?:,\s*\w+:|$)/)

        parsed.empty? ? nil : parsed
      rescue => e
        $stderr.puts "[rails-ai-context] parse_rate_limit failed: #{e.message}" if ENV["DEBUG"]
        nil
      end

      def extract_turbo_stream_actions(source)
        return [] if source.nil?

        parse_result = AstCache.parse_string(source)
        actions = []
        find_turbo_stream_in_defs(parse_result.value, nil, actions)
        actions.uniq.sort
      rescue => e
        $stderr.puts "[rails-ai-context] extract_turbo_stream_actions AST failed: #{e.message}" if ENV["DEBUG"]
        []
      end

      # Walk AST tracking which DefNode we're inside,
      # look for format.turbo_stream calls
      def find_turbo_stream_in_defs(node, current_def_name, actions)
        return unless node.respond_to?(:child_nodes)

        if node.is_a?(Prism::DefNode)
          current_def_name = node.name.to_s
        end

        if node.is_a?(Prism::CallNode) && node.name == :turbo_stream && node.receiver
          receiver = node.receiver
          is_format = case receiver
          when Prism::LocalVariableReadNode then receiver.name == :format
          when Prism::CallNode then receiver.name == :format && receiver.receiver.nil?
          else false
          end
          if is_format && current_def_name
            actions << current_def_name
          end
        end

        node.child_nodes.compact.each do |child|
          find_turbo_stream_in_defs(child, current_def_name, actions)
        end
      end

      # --- AST helpers ---

      # Extract parent class name from source via Prism AST.
      # Walks for ClassNode and reads superclass constant path.
      def extract_parent_class_ast(source)
        result = AstCache.parse_string(source)
        find_class_superclass(result.value) || "Unknown"
      rescue => e
        $stderr.puts "[rails-ai-context] extract_parent_class_ast failed: #{e.message}" if ENV["DEBUG"]
        "Unknown"
      end

      def find_class_superclass(node)
        return nil unless node.respond_to?(:child_nodes)
        node.child_nodes.compact.each do |child|
          if child.is_a?(Prism::ClassNode) && child.superclass
            return constant_node_to_string(child.superclass)
          end
          found = find_class_superclass(child)
          return found if found
        end
        nil
      end

      def constant_node_to_string(node)
        case node
        when Prism::ConstantReadNode
          node.name.to_s
        when Prism::ConstantPathNode
          parts = []
          current = node
          while current.is_a?(Prism::ConstantPathNode)
            parts.unshift(current.name.to_s)
            current = current.parent
          end
          parts.unshift(current.name.to_s) if current.is_a?(Prism::ConstantReadNode)
          parts.join("::")
        else
          "Unknown"
        end
      end

      def read_source(ctrl)
        path = source_path(ctrl)
        return nil unless path && File.exist?(path)
        RailsAiContext::SafeFile.read(path)
      end

      def source_path(ctrl)
        root = app.root.to_s
        underscored = ctrl.name.underscore
        File.join(root, "app", "controllers", "#{underscored}.rb")
      end
    end
  end
end
