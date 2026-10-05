# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    # Discovers controllers and extracts filters, strong params,
    # respond_to formats, concerns, actions, and API detection.
    # Uses source-file parsing (not just Ruby reflection) so that
    # changes made mid-session are always visible.
    class ControllerIntrospector < Base
      extend StaticTier
      static_tier :alternate_source

      def excluded_filters
        RailsAiContext.configuration.excluded_filters
      end

      def call
        EagerLoad.dir(app.root, kind: "app/controllers")
        controllers = discover_controllers

        result = controllers.each_with_object({}) do |ctrl, hash|
          hash[ctrl.name] = extract_controller_details(ctrl)
        rescue => e
          hash[ctrl.name] = { error: portable_message(e) }
        end

        # Discover controllers from filesystem that may not be loaded as classes.
        # Reflection has already named every controller it loaded, so the file's
        # own source is only worth parsing for the ones it did not - resolving
        # the declared constant up front would parse every controller in the
        # app to produce a name this loop throws away.
        discover_from_filesystem.each do |path_name, record|
          next if result.key?(path_name)

          name, details = detail_for(record, path_name)
          next if name.nil? || result.key?(name)

          result[name] = details
        end

        { controllers: fill_inherited_actions(result) }
      end

      # Static tier: every controller goes through the source-only extractor;
      # class loading and reflection never run.
      def static_call
        # No reflection here, so every file's own source is the only source of
        # its name as well as its details.
        result = discover_from_filesystem.each_with_object({}) do |(path_name, record), hash|
          name, details = detail_for(record, path_name)
          next if name.nil?

          hash[name] = details[:error] ? details : details.merge(confidence: Confidence::STATIC)
        rescue => e
          hash[path_name] = { error: portable_message(e) }
        end
        {
          controllers: fill_inherited_actions(result),
          note: "Parsed statically from app/controllers (app not booted)"
        }
      end

      # Rails renders a routed action's template when the controller has no method for it,
      # and a public base method no route names for this controller is a helper.
      def self.apply_routes(section, routes, root)
        return unless section.is_a?(Hash) && section[:controllers].is_a?(Hash)

        by_controller = RouteCoverage.all_by_controller(routes)
        controllers = section[:controllers]
        # Underscored names stay out, as they do for methods; so do partials.
        routed_for = controllers.to_h do |name, info|
          path = controller_path(name, info.is_a?(Hash) ? info[:file] : nil)
          [ name, Array(by_controller[path]).map { |r| r[:action].to_s }.reject { |a| a.start_with?("_") } ]
        end
        by_subclasses = routed_by_subclasses(controllers, routed_for)
        controllers.each do |name, info|
          next unless info.is_a?(Hash) && info[:actions].is_a?(Array)

          inherited = Array(info.delete(:inherited_actions))
          path = controller_path(name, info[:file])
          routed = routed_for[name]
          # A base is never routed itself; what its subclasses route is its
          # actions. With none of them routed, the table says nothing about it.
          if routed.empty?
            if by_subclasses[name]&.any?
              info[:actions] &= by_subclasses[name]
            elsif by_controller.any? && info[:file].to_s.start_with?("app/controllers/")
              # Unrouted and no one's base: only what it defines itself may be
              # an action. An engine's or module's controller is routed by a
              # route file the static walk may not read, so it is left alone.
              info[:actions] -= inherited
            end
            next
          end

          info[:actions] -= inherited - routed
          dir = File.join(root.to_s, "app", "views", path)
          next unless Dir.exist?(dir)

          extra = (routed & Dir.children(dir).map { |f| f.split(".").first }) - info[:actions]
          info[:actions] = (info[:actions] + extra).sort if extra.any?
        end
      end

      # {base => every action a subclass of it is routed for}, for each
      # controller another one in the listing inherits from.
      def self.routed_by_subclasses(controllers, routed_for)
        controllers.each_with_object({}) do |(name, info), found|
          seen = Set.new
          parent = info.is_a?(Hash) && ActionResolver.resolve_entry_name(controllers, info[:parent_class], name)
          while parent && controllers.key?(parent) && seen.add?(parent)
            (found[parent] ||= Set.new).merge(routed_for[name])
            parent_info = controllers[parent]
            parent = parent_info.is_a?(Hash) && ActionResolver.resolve_entry_name(controllers, parent_info[:parent_class], parent)
          end
        end.transform_values(&:to_a)
      end

      # The file's path, where there is one: `ActivityPub::` lives in activitypub/, which
      # underscoring the name misses without the app's inflections.
      def self.controller_path(name, file)
        from_file = file.to_s[%r{app/controllers/(.+)_controller\.rb\z}, 1]
        from_file || name.delete_suffix("Controller").underscore
      end

      private

      # One file cannot see its ancestor, so the inherited answer is filled in
      # over the finished listing, walked by the parent name each entry
      # carries. Every walk reads the listing as it was, before any entry took
      # on its ancestors' actions, and the child's own filters come off the
      # union: an inherited method the child names in a callback is a filter.
      def fill_inherited_actions(result)
        unions = result.each_with_object({}) do |(name, info), acc|
          next unless info.is_a?(Hash)

          inherited = ActionResolver.inherited_actions_by_name(result, info[:parent_class],
                                                               kind: :controller, within: name)
          next if inherited.empty?

          own = Array(info[:actions]) - Array(info[:inherited_actions])
          union = ActionResolver.deliverable_actions((Array(info[:actions]) | inherited).sort, filter_names(info[:filters]))
          acc[name] = [ union, union - own ]
        end
        unions.each do |name, (actions, inherited_only)|
          result[name][:actions] = actions
          result[name][:inherited_actions] = inherited_only if inherited_only.any?
        end
        result
      end

      # What both tiers do with a file: read it, name it by what it declares,
      # and extract. A file it cannot read is an entry saying so, not a gap.
      def detail_for(record, path_name)
        source = SafeFile.read(record.path)
        return [ path_name, { error: "unreadable" } ] unless source
        return nil unless record.path.end_with?("_controller.rb") || subclasses_a_controller?(source)

        name = DeclaredConstant.resolve(source, path_name)
        [ name, extract_details_from_source(record, name, source) ]
      end

      # A file not named *_controller.rb is a controller only if it subclasses one: a mixin,
      # a plain helper class or a Grape API is not.
      def subclasses_a_controller?(source)
        DeclaredConstant.declarations(source).any? { |d| d.superclass.to_s.split("::").last.to_s.end_with?("Controller") }
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
          # A base the app names by what it is (`enumerations_controller_base.rb`)
          # is a controller all the same; a concern is not.
          next unless record.path.end_with?(".rb") && !record.path.include?("/concerns/")
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
        filters, unread = ControllerFilters.with_concerns(source, root: app.root.to_s, within: class_name,
                                                                  cache: (@concern_cache ||= {}))
        concerns = extract_concerns_from_source(source)
        own = ActionResolver.actions_from_source(source, class_name: class_name, filters: filter_names(filters))
        mixed_in = concern_actions(concerns, class_name, filters) - own
        details = {
          parent_class: parent,
          api_controller: parent.include?("API"),
          actions: (own + mixed_in).sort,
          inherited_actions: mixed_in.presence,
          filters: filters,
          concerns: concerns,
          concerns_unread: unread.presence,
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
        { error: portable_message(e) }
      end

      # The context is committed, so a load error names the file as the app does.
      def portable_message(error)
        PortablePath.relativize_text(error.message, app.root)
      end

      def extract_controller_details(ctrl)
        source = read_source(ctrl)
        rate_limit = rate_limit_entry(source)
        filters = extract_filters(ctrl, source)
        concerns = extract_concerns(ctrl)
        actions = extract_actions(ctrl, source, filters) | concern_actions(concerns, ctrl.name, filters)
        # What the file does not define itself is inherited or mixed in, for
        # the routes to settle as they do for a statically read entry.
        own = source ? ActionResolver.actions_from_source(source, class_name: ctrl.name, filters: filter_names(filters)) : actions

        {
          parent_class: ctrl.superclass.name,
          api_controller: api_controller?(ctrl),
          actions: actions.sort,
          inherited_actions: (actions - own).presence,
          filters: filters,
          concerns: concerns,
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
      # The filters are read first and handed over: a method a `before_action`
      # names is that filter, not an action Rails would route to.
      def extract_actions(ctrl, source = nil, filters = [])
        ActionResolver.resolve(ctrl, source: source, kind: :controller,
                               read_source: method(:read_source),
                               filters: filter_names(filters))
      end

      # What an app controller concern (Whitehall's TranslationControllerConcern)
      # would have Rails dispatch to; the routes decide which are actions.
      def concern_actions(concerns, within, filters)
        Array(concerns).flat_map do |concern|
          source = ConcernPaths.module_source(app.root.to_s, concern.to_s, prefer: "controller", within: within)
          next [] unless source

          offered = (@concern_actions ||= {})[source] ||= ActionResolver.module_actions(source)
          ActionResolver.deliverable_actions(offered, filter_names(filters))
        end.uniq
      rescue => e
        RailsAiContext.debug_fail(e, [], label: "concern_actions")
      end

      def filter_names(filters)
        Array(filters).map { |f| f.is_a?(Hash) ? f[:name] : f }.compact.map(&:to_s)
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

          # Collect only/except constraints from source files in the inheritance chain
          source_constraints = reflection_filters.any? ? collect_source_constraints(ctrl, source) : {}
          reflection_filters.each do |f|
            if (sc = source_constraints[[ f[:kind], f[:name] ]])
              f[:only] = sc[:only] if sc[:only]&.any?
              f[:except] = sc[:except] if sc[:except]&.any?
              f[:unless] = sc[:unless] if sc[:unless]
              f[:if] = sc[:if] if sc[:if]
            end
          end

          # Evaluate known runtime conditions to remove inapplicable filters
          reflection_filters.reject! { |f| filter_excluded_by_condition?(ctrl, f) }

          # An empty chain still has the body's skips to show: what took the filters out.
          return merge_own_source(reflection_filters, source || read_source(ctrl), ctrl)
        end

        # Fallback to source parsing when reflection is unavailable
        source ? extract_filters_from_source(source) : []
      rescue => e
        RailsAiContext.debug_fail(e, [], label: "extract_filters")
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
            # Within one body the last declaration wins; across the chain the most specific class does.
            effective_declarations(own_filters(src, klass.name)).each { |key, sf| constraints[key] ||= sf }
          end
          klass = klass.superclass
        end
        constraints
      rescue => e
        RailsAiContext.debug_fail(e, {}, label: "collect_source_constraints")
      end

      # Reflection hands every class the whole chain and no skips at all, so
      # the class's own body is the only thing that says which of those names
      # it declares itself and what it took out. Both go on the record: the
      # skips the way the static tier carries them, and `declared` on the rest.
      # The chain's own order is the run order, so it is kept: each skip is
      # spliced in beside the record it takes out, and the body's order
      # decides only whether the skip reads before or after a re-declaration
      # of the same name.
      # A concern the body includes declares as the body does, so it is read
      # the way the static tier reads it and keeps its `from_concern`.
      def merge_own_source(filters, source, ctrl)
        return filters unless source

        own = own_filters(source, ctrl.name).reject { |f| inherited_concern?(ctrl, f[:from_concern]) }
        # Kind and name: `after_action :audit` inherited beside an own
        # `before_action :audit` is still the ancestor's.
        by_key = filters.group_by { |f| [ f[:kind], f[:name] ] }
        effective_declarations(own).each do |key, declared|
          Array(by_key[key]).each do |f|
            f[:declared] = true
            declared[:from_concern] ? f[:from_concern] = declared[:from_concern] : f.delete(:from_concern)
          end
        end
        skips = own.select { |f| f[:skipped] }
        return filters if skips.empty?

        splice_skips(filters, own, skips)
      end

      # ActiveSupport::Concern skips a module already in the ancestors; a plain module's hook runs again.
      def inherited_concern?(ctrl, label)
        return false unless label && ctrl.superclass

        mod = SuperclassChain.resolve_in_scope(ctrl.name, label) { |candidate| candidate.safe_constantize }
        mod.is_a?(ActiveSupport::Concern) && ctrl.superclass.include?(mod)
      end

      def own_filters(source, within)
        ControllerFilters.with_concerns(source, root: app.root.to_s, within: within.to_s,
                                                cache: (@concern_cache ||= {})).first
      end

      # A later declaration of the same kind and name replaces the earlier one, as Rails does.
      def effective_declarations(own)
        own.reject { |f| f[:skipped] }.to_h { |f| [ [ f[:kind], f[:name] ], f ] }
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
        if filter[:unless].to_s == "devise_controller?"
          return true if devise_controller?(ctrl)
        end

        # if: :devise_controller? - filter ONLY applies to Devise controllers
        if filter[:if].to_s == "devise_controller?"
          return true unless devise_controller?(ctrl)
        end

        false
      end

      def devise_controller?(ctrl)
        return false unless defined?(::DeviseController)
        ctrl < ::DeviseController || ctrl.ancestors.any? { |a| a.name&.start_with?("Devise::") }
      rescue => e
        RailsAiContext.debug_fail(e, false, label: "devise_controller?")
      end

      def extract_concerns(ctrl)
        ConcernMembership.from_ancestors(ctrl)
      rescue => e
        RailsAiContext.debug_fail(e, [], label: "extract_concerns")
      end

      # Through MixinsListener rather than a hand walk: the listener knows
      # `prepend` reaches the ancestor chain and a singleton-class `include`
      # does not, so this tier answers the same question the booted one does.
      def extract_concerns_from_source(source)
        walked = SourceIntrospector.walk_source(source, { mixins: Listeners::MixinsListener })
        ConcernMembership.from_mixins(walked[:mixins])
      rescue => e
        RailsAiContext.debug_fail(e, [], label: "extract_concerns_from_source AST")
      end

      def extract_strong_params(source)
        return [] if source.nil?

        parse_result = AstCache.parse_string(source)
        param_methods = []
        find_param_methods(parse_result.value, param_methods)
        param_methods
      rescue => e
        RailsAiContext.debug_fail(e, [], label: "extract_strong_params AST")
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
            permits << arg.unescaped
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
            permits << arg.unescaped
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
            permits << el.unescaped
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
          when Prism::SymbolNode then [ el.unescaped ]
          when Prism::ArrayNode then expect_symbol_values(el)
          else []
          end
        end
      end

      def extract_ast_value(node)
        case node
        when Prism::SymbolNode       then node.unescaped
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
        RailsAiContext.debug_fail(e, [], label: "extract_respond_to AST")
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
        RailsAiContext.debug_fail(e, [], label: "extract_rescue_from AST")
      end

      def rate_limit_entry(source)
        return nil if source.nil?

        ast_result = SourceIntrospector.walk_source(source, {
          rate_limit: -> { Listeners::GenericMacroListener.new(:rate_limit) }
        })
        (ast_result[:rate_limit] || []).first
      rescue => e
        RailsAiContext.debug_fail(e, nil, label: "rate_limit_entry")
      end

      def extract_rate_limit(source, entry)
        return nil unless entry

        line_num = entry[:location]
        lines = source.lines
        return nil unless line_num && line_num > 0 && line_num <= lines.size

        raw_line = lines[line_num - 1].strip
        raw_line.sub(/\Arate_limit\s+/, "")
      rescue => e
        RailsAiContext.debug_fail(e, nil, label: "extract_rate_limit AST")
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
        RailsAiContext.debug_fail(e, nil, label: "parse_rate_limit")
      end

      def extract_turbo_stream_actions(source)
        return [] if source.nil?

        parse_result = AstCache.parse_string(source)
        actions = []
        find_turbo_stream_in_defs(parse_result.value, nil, actions)
        actions.uniq.sort
      rescue => e
        RailsAiContext.debug_fail(e, [], label: "extract_turbo_stream_actions AST")
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
