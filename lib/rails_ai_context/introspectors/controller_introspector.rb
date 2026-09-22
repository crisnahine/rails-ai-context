# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    # Discovers controllers and extracts filters, strong params,
    # respond_to formats, concerns, actions, and API detection.
    # Uses source-file parsing (not just Ruby reflection) so that
    # changes made mid-session are always visible.
    class ControllerIntrospector
      extend StaticTier
      static_tier :alternate_source

      attr_reader :app

      def excluded_filters
        RailsAiContext.configuration.excluded_filters
      end

      def initialize(app)
        @app = app
      end

      def call
        EagerLoad.dir(app.root, kind: "app/controllers")
        controllers = discover_controllers

        result = controllers.each_with_object({}) do |ctrl, hash|
          hash[ctrl.name] = extract_controller_details(ctrl)
        rescue => e
          hash[ctrl.name] = { error: e.message }
        end

        # Discover controllers from filesystem that may not be loaded as classes.
        # Reflection has already named every controller it loaded, so the file's
        # own source is only worth parsing for the ones it did not - resolving
        # the declared constant up front would parse every controller in the
        # app to produce a name this loop throws away.
        discover_from_filesystem.each do |path_name, record|
          next if result.key?(path_name)

          name, details = detail_for(record, path_name)
          next if result.key?(name)

          result[name] = details
        end

        { controllers: fill_inherited_actions(result) }
      rescue => e
        { error: e.message }
      end

      # Static tier: every controller goes through the source-only extractor;
      # class loading and reflection never run.
      def static_call
        # No reflection here, so every file's own source is the only source of
        # its name as well as its details.
        result = discover_from_filesystem.each_with_object({}) do |(path_name, record), hash|
          name, details = detail_for(record, path_name)
          hash[name] = details[:error] ? details : details.merge(confidence: Confidence::STATIC)
        rescue => e
          hash[path_name] = { error: e.message }
        end
        {
          controllers: fill_inherited_actions(result),
          note: "Parsed statically from app/controllers (app not booted)"
        }
      rescue => e
        { error: e.message }
      end

      private

      # One file cannot see its ancestor, so the inherited answer is filled in
      # over the finished listing, walked by the parent name each entry
      # carries. Only entries with no actions of their own are touched.
      def fill_inherited_actions(result)
        result.each do |name, info|
          next unless info.is_a?(Hash) && Array(info[:actions]).empty?

          inherited = ActionResolver.inherited_actions_by_name(result, info[:parent_class],
                                                               kind: :controller, within: name)
          info[:actions] = inherited if inherited.any?
        end
        result
      end

      # What both tiers do with a file: read it, name it by what it declares,
      # and extract. A file it cannot read is an entry saying so, not a gap.
      def detail_for(record, path_name)
        source = SafeFile.read(record.path)
        return [ path_name, { error: "unreadable" } ] unless source

        name = DeclaredConstant.resolve(source, path_name)
        [ name, extract_details_from_source(record, name, source) ]
      end

      def discover_controllers
        return [] unless defined?(ActionController::Base)

        bases = [ ActionController::Base ]
        bases << ActionController::API if defined?(ActionController::API)

        bases.flat_map(&:descendants).reject do |ctrl|
          ctrl.name.nil? || ctrl.name == "ApplicationController" || DeclaredConstant.renamed?(ctrl) ||
            ctrl.name.start_with?("Rails::", "ActionMailbox::", "ActiveStorage::")
        end.uniq.sort_by(&:name)
      end

      # Controller files not yet loaded as classes, keyed by the name the path
      # camelizes to. Stats only: reflection has already named most of these,
      # and reading their source here would be a read per file the caller
      # throws away. Callers resolve the declared constant where they need it.
      def discover_from_filesystem
        SourceScan.paths(app.root, kind: "app/controllers").each_with_object({}) do |record, result|
          next unless record.path.end_with?("_controller.rb")
          next if record.path_name == "ApplicationController"
          next if record.path_name.start_with?("Rails::", "ActionMailbox::", "ActiveStorage::")

          result[record.path_name] ||= record
        end
      end

      # Extract details purely from source file (for controllers not loaded as classes)
      def extract_details_from_source(record, class_name, source)
        # Carry the file that was read: the declared name does not round-trip
        # back to a path. See CONTEXT.md, "Declared constant".
        relative_file = record.file
        parent = parent_class_of(source, class_name)
        rate_limit = rate_limit_entry(source)
        details = {
          parent_class: parent,
          api_controller: parent.include?("API"),
          actions: ActionResolver.actions_from_source(source, class_name: class_name),
          filters: extract_filters_from_source(source),
          concerns: extract_concerns_from_source(source),
          strong_params: extract_strong_params(source),
          respond_to_formats: extract_respond_to(source),
          rescue_from: extract_rescue_from(source),
          rate_limit: extract_rate_limit(source, rate_limit),
          rate_limit_parsed: parse_rate_limit(rate_limit),
          turbo_stream_actions: extract_turbo_stream_actions(source),
          file: relative_file
        }.compact
        details
      rescue => e
        { error: e.message }
      end

      def extract_controller_details(ctrl)
        source = read_source(ctrl)
        rate_limit = rate_limit_entry(source)

        {
          parent_class: ctrl.superclass.name,
          api_controller: api_controller?(ctrl),
          actions: extract_actions(ctrl, source),
          filters: extract_filters(ctrl, source),
          concerns: extract_concerns(ctrl),
          strong_params: extract_strong_params(source),
          respond_to_formats: extract_respond_to(source),
          rescue_from: extract_rescue_from(source),
          rate_limit: extract_rate_limit(source, rate_limit),
          rate_limit_parsed: parse_rate_limit(rate_limit),
          turbo_stream_actions: extract_turbo_stream_actions(source),
          file: relative_source_path(ctrl)
        }.compact
      end

      # App-relative path of the file the class was defined in, for consumers
      # that would otherwise reconstruct it from the name.
      def relative_source_path(ctrl)
        path = source_path(ctrl)
        return nil unless path && File.exist?(path)

        path.to_s.sub("#{app.root}/", "")
      end

      def api_controller?(ctrl)
        return true if defined?(ActionController::API) && ctrl.ancestors.include?(ActionController::API)
        false
      end

      # The whole chain - own source, app-owned ancestors, reflection with the
      # base subtraction - lives in ActionResolver, shared with the mailer
      # path. `rails g devise:controllers` is the live reflection case: the
      # app owns the file, every action in it is commented out, and the gem
      # class supplies them.
      def extract_actions(ctrl, source = nil)
        ActionResolver.resolve(ctrl, source: source, kind: :controller,
                               read_source: method(:read_source))
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

            return merge_own_source(reflection_filters, source || read_source(ctrl))
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

      # A compiled callback keeps only:/except: in private ivars, so the
      # constraint has to come from the chain's source. A skip record states
      # the actions on which the filter does NOT run, which is the opposite
      # of what the filter is being asked for, so it never supplies one.
      def collect_source_constraints(ctrl, current_source = nil)
        constraints = {}
        klass = ctrl
        while klass&.name && !ActionResolver.framework?(klass, kind: :controller)
          src = (klass == ctrl) ? (current_source || read_source(klass)) : read_source(klass)
          if src
            extract_filters_from_source(src).each do |sf|
              next if sf[:skipped]

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

      # Reflection hands every class the whole chain and no skips at all, so
      # the class's own body is the only thing that says which of those names
      # it declares itself and what it took out. Both go on the record: the
      # skips the way the static tier carries them, and `declared` on the rest.
      # The chain's own order is the run order, so it is kept: each skip is
      # spliced in beside the record it takes out, and the body's order
      # decides only whether the skip reads before or after a re-declaration
      # of the same name.
      def merge_own_source(filters, source)
        return filters unless source

        own = extract_filters_from_source(source)
        declared = own.reject { |f| f[:skipped] }.map { |f| f[:name] }.to_set
        by_name = filters.group_by { |f| f[:name] }
        declared.each { |name| Array(by_name[name]).each { |f| f[:declared] = true } }
        skips = own.select { |f| f[:skipped] }
        return filters if skips.empty?

        splice_skips(filters, own, skips)
      end

      def splice_skips(filters, own, skips)
        placed = Set.new
        merged = filters.flat_map do |f|
          name = f[:name]
          mine = skips.select { |s| s[:name] == name }
          next [ f ] if mine.empty? || placed.include?(name)

          placed << name
          skip_at = own.index { |o| o[:name] == name && o[:skipped] }
          declare_at = own.index { |o| o[:name] == name && !o[:skipped] }
          declare_at && skip_at < declare_at ? mine + [ f ] : [ f ] + mine
        end
        merged + skips.reject { |s| placed.include?(s[:name]) }
      end

      def extract_filters_from_source(source)
        ControllerFilters.from_source(source)
      end

      # Statically evaluate known runtime conditions to exclude inapplicable filters.
      # e.g., `unless: :devise_controller?` on a Devise controller means the filter doesn't apply.
      def filter_excluded_by_condition?(ctrl, filter)
        # unless: :devise_controller? - filter does NOT apply to Devise controllers
        if filter[:unless] == "devise_controller?"
          return true if devise_controller?(ctrl)
        end

        # if: :devise_controller? - filter ONLY applies to Devise controllers
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

      def extract_concerns(ctrl)
        ConcernMembership.from_ancestors(ctrl)
      rescue => e
        $stderr.puts "[rails-ai-context] extract_concerns failed: #{e.message}" if ENV["DEBUG"]
        []
      end

      # Through MixinsListener rather than a hand walk: the listener knows
      # `prepend` reaches the ancestor chain and a singleton-class `include`
      # does not, so this tier answers the same question the booted one does.
      def extract_concerns_from_source(source)
        walked = SourceIntrospector.walk_source(source, { mixins: Listeners::MixinsListener })
        ConcernMembership.from_mixins(walked[:mixins])
      rescue => e
        $stderr.puts "[rails-ai-context] extract_concerns_from_source AST failed: #{e.message}" if ENV["DEBUG"]
        []
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
        if permit_call
          require_call = find_require_in_chain(permit_call)
          if require_call
            req_arg = require_call.arguments&.arguments&.first
            result[:requires] = extract_ast_value(req_arg).to_s if req_arg
          end

          return result.merge(parse_permit_args_ast(permit_call))
        end

        expect_call = find_call_in_tree(def_node.body, :expect)
        return result unless expect_call && call_on_params?(expect_call)

        result.merge(parse_expect_args_ast(expect_call))
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

      # params.expect(article: [ :title, :body ]) combines require + permit in
      # one call. Map it to the same shape permit produces: the hash key
      # becomes :requires and the array members become :permits.
      def parse_expect_args_ast(expect_call)
        result = {}
        permits = []
        nested = {}

        args = expect_call.arguments&.arguments || []
        args.each do |arg|
          case arg
          when Prism::SymbolNode
            permits << arg.value.to_s
          when Prism::KeywordHashNode, Prism::HashNode
            arg.elements.each do |assoc|
              next unless assoc.is_a?(Prism::AssocNode)
              key = extract_ast_value(assoc.key).to_s
              if assoc.value.is_a?(Prism::ArrayNode)
                result[:requires] ||= key
                collect_expect_array(assoc.value, key, permits, nested)
              else
                permits << key
              end
            end
          end
        end

        result[:permits] = permits if permits.any?
        result[:nested] = nested if nested.any?
        result
      end

      def collect_expect_array(array_node, key, permits, nested)
        array_node.elements.each do |el|
          case el
          when Prism::SymbolNode
            permits << el.value.to_s
          when Prism::ArrayNode
            # Doubly-wrapped array marks an array-of-hashes attribute
            nested[key] = expect_symbol_values(el)
          when Prism::KeywordHashNode, Prism::HashNode
            el.elements.each do |inner|
              next unless inner.is_a?(Prism::AssocNode)
              inner_key = extract_ast_value(inner.key).to_s
              if inner.value.is_a?(Prism::ArrayNode)
                nested[inner_key] = expect_symbol_values(inner.value)
              else
                permits << inner_key
              end
            end
          end
        end
      end

      def expect_symbol_values(array_node)
        array_node.elements.flat_map do |el|
          case el
          when Prism::SymbolNode then [ el.value.to_s ]
          when Prism::ArrayNode then expect_symbol_values(el)
          else []
          end
        end
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
          # The exception classes are the listener's positional values; `args`
          # is symbols only, so a constant reaches this line through `values`.
          exceptions = entry[:values].grep(String)
          exceptions = entry[:args].map(&:to_s) if exceptions.empty?
          exceptions.map { |ex| { exception: ex, handler: handler }.compact }
        end
      rescue => e
        $stderr.puts "[rails-ai-context] extract_rescue_from AST failed: #{e.message}" if ENV["DEBUG"]
        []
      end

      def rate_limit_entry(source)
        return nil if source.nil?

        ast_result = SourceIntrospector.walk_source(source, {
          rate_limit: -> { Listeners::GenericMacroListener.new(:rate_limit) }
        })
        (ast_result[:rate_limit] || []).first
      rescue => e
        $stderr.puts "[rails-ai-context] rate_limit_entry failed: #{e.message}" if ENV["DEBUG"]
        nil
      end

      def extract_rate_limit(source, entry)
        return nil unless entry

        line_num = entry[:location]
        lines = source.lines
        return nil unless line_num && line_num > 0 && line_num <= lines.size

        raw_line = lines[line_num - 1].strip
        raw_line.sub(/\Arate_limit\s+/, "")
      rescue => e
        $stderr.puts "[rails-ai-context] extract_rate_limit AST failed: #{e.message}" if ENV["DEBUG"]
        nil
      end

      def parse_rate_limit(entry)
        return nil unless entry

        options = entry[:options] || {}
        sources = entry[:option_values] || {}

        parsed = {}
        parsed[:to] = options[:to] if options[:to].is_a?(Integer)
        parsed[:within] = sources[:within].to_s if sources.key?(:within)
        parsed[:only] = Array(options[:only]).map(&:to_s) if options.key?(:only)

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

      # The superclass this file's own class names. A file may declare more
      # than one class, so the one matching the resolved constant answers
      # first; anything else in the file only answers when it does not.
      def parent_class_of(source, class_name)
        declarations = DeclaredConstant.declarations(source)
        named = declarations.find { |d| d.name == class_name }
        named&.superclass || declarations.find(&:superclass)&.superclass || "Unknown"
      end

      def read_source(ctrl)
        path = source_path(ctrl)
        return nil unless path && File.exist?(path)
        RailsAiContext::SafeFile.read(path)
      end

      # Ruby knows where the class was defined; the underscored name only
      # agrees when the app registers no inflection. See CONTEXT.md,
      # "Declared constant".
      def source_path(ctrl)
        # Contained under the app root: a constant defined by a gem - or by a
        # spec - is not this app's controller file.
        located = Object.const_source_location(ctrl.name)&.first
        if located && File.exist?(located) && located.to_s.start_with?("#{app.root}/")
          return located
        end

        File.join(app.root.to_s, "app", "controllers", "#{ctrl.name.underscore}.rb")
      rescue StandardError
        File.join(app.root.to_s, "app", "controllers", "#{ctrl.name.underscore}.rb")
      end
    end
  end
end
