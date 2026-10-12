# frozen_string_literal: true

require "pathname"
require "prism"
require "set"

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
        left_out = EagerLoad.dir(app.root, kind: "app/controllers")
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

          # Never loaded: a file that does not compile, or whose class body
          # needs one that does not (see EagerLoad). Its source is not what
          # Rails runs, so why it cannot load is the answer, as for a model.
          unloaded = left_out.to_h[record.path] || EagerLoad.skipped(record.path)
          name, details = detail_for(record, path_name, unloaded: unloaded)
          next if name.nil? || result.key?(name)

          result[name] = details
        end

        { controllers: resolve_aliases(inherit_class_declarations(fill_inherited_actions(inherit_api_controller(result)))) }
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
        engine = PathResolver.bundle_engine_root(root)
        unread = Pathname.new(engine).relative_path_from(Pathname.new(File.expand_path(root))).to_s if engine
        {
          controllers: resolve_aliases(inherit_class_declarations(fill_inherited_actions(inherit_api_controller(result)))),
          note: "Parsed statically from app/controllers (app not booted)#{"; the engine at #{unread} is not read unbooted" if unread}",
          unread_engine: unread
        }.compact
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
          dispatched = routed_from_parents(controllers, name, info, routed, root)
          info[:actions] = (info[:actions] + dispatched).sort if dispatched.any?
          dir = File.join(root.to_s, "app", "views", path)
          next unless Dir.exist?(dir)

          extra = (routed & Dir.children(dir).map { |f| f.split(".").first }) - info[:actions]
          info[:actions] = (info[:actions] + extra).sort if extra.any?
        end
      end

      # A routed name that a parent controller, or a concern a parent
      # includes, defines as a public method: Rails dispatches it here. A
      # file read alone never sees what its parent mixes in, so the static
      # tier missed what the booted one lists. Only the names a route gives
      # this controller are asked about, so a shared helper stays out.
      def self.routed_from_parents(controllers, name, info, routed, root)
        (routed.uniq - info[:actions]).select do |action|
          found = ActionSource.unlisted_action(root.to_s, name, action, file: info[:file], controllers: controllers)
          # Rails dispatches by the exact name; the lookup by hand ignores case.
          found && found[:name] == action
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
      # A controller is an API controller when a base it inherits is one. A
      # file names only its own parent, so Api::V1::PostsController <
      # BaseController read as no API controller though BaseController is an
      # ActionController::API; the chain is followed through the listing.
      def inherit_api_controller(result)
        result.each do |name, info|
          next unless info.is_a?(Hash) && info[:api_controller] == false

          seen = Set[name]
          parent = ActionResolver.resolve_entry_name(result, info[:parent_class], name)
          while parent && result[parent].is_a?(Hash) && seen.add?(parent)
            if result[parent][:api_controller]
              info[:api_controller] = true
              break
            end

            parent = ActionResolver.resolve_entry_name(result, result[parent][:parent_class], parent)
          end
        end
        result
      end

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

      # Class-level declarations Rails hands down: responders' respond_to copies the formats the
      # parent set before adding its own, and a rate_limit is a before_action every subclass runs.
      # Folded over the listing as it was, with the bases it leaves out read from their files.
      def inherit_class_declarations(result)
        own = @class_declarations || {}
        folded = result.filter_map do |name, info|
          next unless info.is_a?(Hash) && own.key?(name)

          links, = ControllerSettings.lineage(result, name, app.root.to_s)
          lineage = links.reverse.filter_map do |link, entry, source|
            declared = entry ? own[link] : base_class_declarations(source, link)
            [ link, declared ] if declared
          end
          formats = lineage.each_with_object(Set.new) { |(_, declared), set| fold_formats(set, declared[:formats]) }
          limits = lineage.flat_map { |link, declared| link == name ? declared[:rate_limits] : declared[:rate_limits].map { |limit| limit.merge(from: link) } }
          [ name, (formats.to_a | own[name][:block_formats]).sort, limits, inherited_strong_params(result, links) ]
        end
        folded.each do |name, formats, limits, params|
          result[name][:respond_to_formats] = formats
          limits.any? ? result[name][:rate_limits] = limits : result[name].delete(:rate_limits)
          result[name][:strong_params] = params if params.any?
        end
        result
      end

      # A parent's strong-params method is the child's too unless a nearer class defines that name.
      def inherited_strong_params(result, links)
        nearer_defs = Set.new
        links.each_with_object({}) do |(link, entry, source), by_name|
          params = entry ? Array(entry[:strong_params]) : base_class_declarations(source, link)[:strong_params]
          params.each do |sp|
            next unless sp.is_a?(Hash) && !nearer_defs.include?(sp[:name])

            by_name[sp[:name]] ||= link == links.first.first ? sp : sp.merge(from: link)
          end
          nearer_defs.merge(defined_methods(entry ? controller_source(entry) : source))
        end.values
      end

      def controller_source(entry)
        entry[:file] && SafeFile.read(File.join(app.root.to_s, entry[:file]))
      end

      # The instance methods the class body defines, not a nested class's or a class method.
      def defined_methods(source)
        tree = source && AstCache.parse_string(source)&.value
        return [] unless tree

        nodes = AstWalk.each(tree).to_a
        elsewhere = nested_ranges(class_body_walk(source)) +
                    nodes.grep(Prism::SingletonClassNode).map { |node| node.location.start_offset...node.location.end_offset }
        nodes.grep(Prism::DefNode).filter_map do |def_node|
          def_node.name.to_s if def_node.receiver.nil? && elsewhere.none? { |range| range.cover?(def_node.location.start_offset) }
        end
      end

      # `clear_respond_to` empties the class attribute; each `respond_to` adds to it.
      def fold_formats(set, calls)
        calls.each { |formats| formats ? set.merge(formats) : set.clear }
        set
      end

      def own_class_declarations(name, source, walked)
        declared = class_declarations(source, walked).merge(block_formats: block_formats(source, walked))
        (@class_declarations ||= {})[name] = declared
        declared.merge(respond_to_formats: (fold_formats(Set.new, declared[:formats]).to_a | declared[:block_formats]).sort)
      end

      # A base the listing leaves out is read once per run however many controllers inherit it.
      def base_class_declarations(source, name)
        (@base_class_declarations ||= {})[source] ||= begin
          walked = class_body_walk(source)
          actions = ActionResolver.actions_from_source(source, class_name: name)
          class_declarations(source, walked).merge(strong_params: extract_strong_params(source, walked, actions))
        end
      end

      # { formats: [[format...] per respond_to, nil per clear_respond_to], rate_limits: [...] }
      def class_declarations(source, walked)
        calls = walked ? SourceIntrospector.class_level(walked[:respond_to], walked) : []
        formats = calls.map { |call| call[:macro] == :clear_respond_to ? nil : Array(call[:args]).map(&:to_s) }
        { formats: formats, rate_limits: extract_rate_limits(source, walked) }
      end

      # What both tiers do with a file: read it, name it by what it declares,
      # and extract. A file it cannot read is an entry saying so, not a gap,
      # and so is one the booted tier left unloaded (`unloaded:` says why),
      # whose source is never read for facts.
      def detail_for(record, path_name, unloaded: nil)
        source = SafeFile.read(record.path)
        return [ path_name, { error: "unreadable" } ] unless source
        if path_name.end_with?("Controller") && !DeclaredConstant.declares_class?(source, path_name: path_name) &&
           (targets = alias_candidates(source, path_name))
          return [ path_name, unloaded ? { error: unloaded, file: record.file } : { alias_of: targets, file: record.file } ]
        end
        # A *_controller.rb that declares only a module is a mixin controllers include.
        return nil if !DeclaredConstant.declares_class?(source, path_name: path_name) && DeclaredConstant.declared_module_names(source).any?
        return nil unless record.path.end_with?("_controller.rb") || subclasses_a_controller?(source, path_name)

        name = DeclaredConstant.resolve(source, path_name)
        return [ name, { error: unloaded, file: record.file } ] if unloaded

        [ name, extract_details_from_source(record, name, source) ]
      end

      # `GoogleController = OAuth2Controller`: the file names another controller, which Ruby looks
      # up from the innermost module outward; the candidates in that order.
      def alias_candidates(source, path_name)
        tree = AstCache.parse_string(source)&.value or return nil
        DeclaredConstant.constants(tree, assignments: true).each do |name, node, nesting|
          next unless (node.is_a?(Prism::ConstantWriteNode) || node.is_a?(Prism::ConstantPathWriteNode)) && name.casecmp?(path_name)
          next unless node.value.is_a?(Prism::ConstantReadNode) || node.value.is_a?(Prism::ConstantPathNode)

          target = node.value.slice
          return [ target.delete_prefix("::") ] if target.start_with?("::")

          return [ *nesting.map { |scope| "#{scope}::#{target}" }, target ]
        end
        nil
      end

      # An alias reads as the controller it names, so a route to it finds that controller's actions;
      # it keeps its own file, which its routes are keyed by.
      def resolve_aliases(result)
        result.each_key.to_a.each do |name|
          entry = result[name]
          next unless entry.is_a?(Hash) && entry[:alias_of].is_a?(Array)

          target = alias_target(result, name)
          details = result[target]
          target_details = details.is_a?(Hash) && !details[:alias_of] ? details : {}
          result[name] = target_details.merge(alias_of: target, file: entry[:file])
        end
        result
      end

      # The controller an alias names, through any alias that names another.
      def alias_target(result, name, seen = Set.new)
        entry = result[name]
        return nil unless entry.is_a?(Hash) && entry[:alias_of] && seen.add?(name)
        return entry[:alias_of] if entry[:alias_of].is_a?(String)

        target = entry[:alias_of].find { |candidate| result.key?(candidate) } || entry[:alias_of].last
        alias_target(result, target, seen) || target
      end

      # A file not named *_controller.rb is a controller only if it subclasses one: a mixin,
      # a plain helper class or a Grape API is not.
      def subclasses_a_controller?(source, path_name)
        DeclaredConstant.declarations(source, path_name: path_name).any? { |d| d.superclass.to_s.split("::").last.to_s.end_with?("Controller") }
      end

      def discover_controllers
        return [] unless defined?(ActionController::Base)

        bases = [ ActionController::Base ]
        bases << ActionController::API if defined?(ActionController::API)

        bases.flat_map(&:descendants).reject do |ctrl|
          ctrl.name.nil? || ctrl.name == "ApplicationController" || DeclaredConstant.renamed?(ctrl) ||
            ctrl.name.start_with?("Rails::", "ActionMailbox::", "ActiveStorage::") || gem_controller?(ctrl)
        end.uniq.sort_by(&:name)
      end

      # A gem's controller is in descendants only when something loaded it, which a rake
      # boot and a generator boot do differently; it is not the app's. One with no source location stays.
      def gem_controller?(ctrl)
        located = Object.const_source_location(ctrl.name)&.first
        return false unless located && File.exist?(located)

        project_relative(located).nil? || SourceScan.installed_gem?(File.realpath(located), File.realpath(app.root.to_s))
      rescue StandardError => e
        RailsAiContext.debug_fail(e, false, label: "gem_controller?")
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
        declaration = parent_declaration(source, class_name)
        parent = declaration&.superclass || "Unknown"
        filters, unread = ControllerFilters.with_concerns(source, root: app.root.to_s, within: class_name,
                                                                  cache: (@concern_cache ||= {}))
        concerns = extract_concerns_from_source(source)
        walked = class_body_walk(source)
        declared = own_class_declarations(class_name, source, walked)
        own = ActionResolver.actions_from_source(source, class_name: class_name, filters: filter_names(filters))
        mixed_in = concern_actions(concerns, class_name, filters) - own
        details = {
          parent_class: parent,
          parent_nesting: odd_nesting(class_name, declaration&.nesting),
          api_controller: parent.include?("API"),
          actions: (own + mixed_in).sort,
          inherited_actions: mixed_in.presence,
          filters: filters,
          concerns: concerns,
          concerns_unread: unread.presence,
          strong_params: extract_strong_params(source, walked, own),
          respond_to_formats: declared[:respond_to_formats],
          rescue_from: extract_rescue_from(source, walked),
          rate_limits: declared[:rate_limits].presence,
          turbo_stream_actions: extract_turbo_stream_actions(source),
          **ControllerSettings.from_source(source, walked, root: app.root.to_s, within: class_name),
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
        filters = from_unread_mixins(ctrl, extract_filters(ctrl, source))
        concerns = extract_concerns(ctrl)
        actions = extract_actions(ctrl, source, filters) | concern_actions(concerns, ctrl.name, filters)
        # What the file does not define itself is inherited or mixed in, for
        # the routes to settle as they do for a statically read entry.
        own = source ? ActionResolver.actions_from_source(source, class_name: ctrl.name, filters: filter_names(filters)) : actions
        walked = class_body_walk(source)
        declared = own_class_declarations(ctrl.name, source, walked)

        {
          parent_class: ctrl.superclass.name,
          parent_nesting: booted_parent_nesting(ctrl),
          api_controller: api_controller?(ctrl),
          actions: actions.sort,
          inherited_actions: (actions - own).presence,
          filters: filters,
          concerns: concerns,
          strong_params: extract_strong_params(source, walked, own),
          respond_to_formats: declared[:respond_to_formats],
          rescue_from: extract_rescue_from(source, walked),
          rate_limits: declared[:rate_limits].presence,
          turbo_stream_actions: extract_turbo_stream_actions(source),
          **ControllerSettings.from_source(source, walked, root: app.root.to_s, within: ctrl.name),
          file: relative_source_path(ctrl)
        }.compact
      end

      # App-relative path of the file the class was defined in, for consumers
      # that would otherwise reconstruct it from the name.
      def relative_source_path(ctrl)
        path = source_path(ctrl)
        return nil unless path && File.exist?(path)

        project_relative(path)
      end

      # Under the app root, or `../../app/...` in the engine a test/dummy runs in; nil anywhere else,
      # and for a file a symlink carries out of the app.
      def project_relative(path)
        return nil if PathResolver.linked_out?(path, app.root)

        root = "#{app.root.to_s.chomp("/")}/"
        return path.to_s.delete_prefix(root) if path.to_s.start_with?(root)
        return nil unless PathResolver.project_file?(path, app.root)

        Pathname.new(File.realpath(path)).relative_path_from(Pathname.new(File.realpath(app.root.to_s))).to_s
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
          own_file = relative_source_path(ctrl)
          reflection_filters = ctrl._process_action_callbacks.filter_map do |cb|
            name = callback_name(cb.filter, own_file)
            next if name.nil? || excluded_filters.include?(name)
            { name: name, kind: cb.kind.to_s }
          end

          # Collect only/except constraints from source files in the inheritance chain
          source_constraints, blocks = reflection_filters.any? ? collect_source_constraints(ctrl, source) : [ {}, {} ]
          reflection_filters.each do |f|
            key = [ f[:kind], f[:name] ]
            # Each block is a callback of its own, so blocks with one name pair up in chain order.
            sc = ControllerFilters.block?(f[:name]) && blocks[key]&.any? ? blocks[key].shift : source_constraints[key]
            if sc
              f[:only] = sc[:only] if sc[:only]&.any?
              f[:except] = sc[:except] if sc[:except]&.any?
              f[:unless] = sc[:unless] if sc[:unless]
              f[:if] = sc[:if] if sc[:if]
              f[:condition] = sc[:condition] if sc[:condition]
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

      # cancancan adds its callbacks as blocks; the static tier names them for the macro, and so does this.
      def cancan_callback(filter, path)
        if path&.end_with?("cancan/controller_resource.rb")
          filter.binding.local_variable_get(:method).to_s
        elsif path&.end_with?("cancan/controller_additions.rb")
          filter.binding.local_variable_defined?(:options) ? "check_authorization" : "skip_authorization_check"
        end
      rescue StandardError
        nil
      end

      # A block the app wrote is named by its line, as the static tier names it, and the one
      # http_basic_authenticate_with adds by that macro; any other framework's or gem's
      # block (`allow_browser`, `rate_limit`) is not a filter the app wrote.
      def callback_name(filter, own_file = nil)
        case filter
        when Symbol, String then return filter.to_s.start_with?("_") ? nil : filter.to_s
        # An anonymous class is the object `Class.new` made; an anonymous class's instance is
        # named by its nearest named ancestor (`Struct.new(...).new`), as the static tier reads it.
        when Module then return filter.name || "#{filter.class.name} (object)"
        when Proc then nil
        # An object's to_s is its inspect string, with an address that changes every run.
        else return "#{filter.class.ancestors.find { |a| a.is_a?(Class) && a.name }.name} (object)"
        end

        path, line = filter.source_location
        return "http_basic_authenticate_with" if path&.end_with?("action_controller/metal/http_authentication.rb")
        cancan = cancan_callback(filter, path)
        return cancan if cancan

        file = path && project_relative(path)
        return if file.nil? || file.start_with?("vendor/") || PortablePath.gem_file?(path, app.root)

        ControllerFilters.block_name(line, (file unless own_file.nil? || file == own_file), lambda: filter.lambda?)
      end

      # A compiled callback keeps only:/except: in private ivars, so the
      # constraint has to come from the chain's source. A skip record states
      # the actions on which the filter does NOT run, which is the opposite
      # of what the filter is being asked for, so it never supplies one.
      def collect_source_constraints(ctrl, current_source = nil)
        constraints = {}
        bodies = []
        klass = ctrl
        while klass&.name && !ActionResolver.framework?(klass, kind: :controller)
          src = (klass == ctrl) ? (current_source || read_source(klass)) : read_source(klass)
          if src
            own = own_filters(src, klass.name)
            own = ControllerFilters.in_file(own, relative_source_path(klass)) unless klass == ctrl
            # Within one body the last declaration wins; across the chain the most specific class does.
            effective_declarations(own).each { |key, sf| constraints[key] ||= sf }
            bodies.unshift(own)
          end
          klass = klass.superclass
        end
        blocks = bodies.flatten.select { |f| !f[:skipped] && ControllerFilters.block?(f[:name]) }.group_by { |f| [ f[:kind], f[:name] ] }
        [ constraints, blocks ]
      rescue => e
        RailsAiContext.debug_fail(e, [ {}, {} ], label: "collect_source_constraints")
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
          rows = Array(by_key[key])
          # Each block is a callback of its own: the body's are the last ones of that name, in its order.
          pairs = if ControllerFilters.block?(key.last)
            mine = own.select { |f| !f[:skipped] && [ f[:kind], f[:name] ] == key }
            rows.last(mine.size).zip(mine)
          else
            rows.map { |f| [ f, declared ] }
          end
          pairs.each do |f, source_record|
            f[:declared] = true
            source_record[:from_concern] ? f[:from_concern] = source_record[:from_concern] : f.delete(:from_concern)
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
        ControllerFilters.from_source(source, root: app.root.to_s)
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

      # A filter whose method a module from outside the app defines (`include ActiveStorage::SetBlob`)
      # is declared in no file the walk reads, so it is credited to that module.
      def from_unread_mixins(ctrl, filters)
        unread = mixins_unread(ctrl)
        return filters if unread.empty?

        filters.map do |f|
          next f if f[:declared] || f[:skipped] || f[:from_concern]

          owner = begin
            ctrl.instance_method(f[:name]).owner.name
          rescue NameError
            nil
          end
          unread.include?(owner) ? f.merge(from_concern: owner) : f
        end
      end

      # Modules an app class on the chain mixes in from a file outside the app. A gem's on_load
      # lands above the framework base.
      def mixins_unread(ctrl)
        ancestors = ctrl.ancestors
        base = ancestors.index { |mod| mod.is_a?(Class) && ActionResolver.framework?(mod, kind: :controller) }
        ancestors.first(base || 0).filter_map do |mod|
          next if mod.is_a?(Class) || mod.name.nil?

          path, = Object.const_source_location(mod.name)
          mod.name unless path && project_relative(path) && !PortablePath.gem_file?(path, app.root)
        end
      rescue => e
        RailsAiContext.debug_fail(e, [], label: "mixins_unread")
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

      # An action that permits inline is still an action, not a strong-params helper;
      # a public method named *_params is a helper left above `private`.
      def extract_strong_params(source, walked = class_body_walk(source), actions = [])
        return [] if source.nil?

        nested = nested_ranges(walked)
        all_defs = AstWalk.each(AstCache.parse_string(source).value).grep(Prism::DefNode)
        defs = all_defs.reject do |def_node|
          name = def_node.name.to_s
          nested.any? { |range| range.cover?(def_node.location.start_offset) } || (actions.include?(name) && !name.end_with?("_params"))
        end
        entries = defs.to_h { |def_node| [ def_node, strong_params_entry(def_node) ] }.compact
        add_delegating_params(defs, entries, all_defs.to_set { |def_node| def_node.name.to_s })
        defs.filter_map { |def_node| entries[def_node] }
      rescue => e
        RailsAiContext.debug_fail(e, [], label: "extract_strong_params AST")
      end

      PERMITS = %i[permit! permit expect].freeze
      # What these return is still the permitted params; `[]`, `fetch` or `dig` returns one value.
      PARAMS_PRESERVING = %i[merge reverse_merge tap to_h to_hash slice except with_indifferent_access compact compact_blank].freeze
      # A nested key of a strong-params answer (`permitted_params[:post]`) is params too, as is Devise's `sanitize`.
      NESTED_PARAMS = %i[[] fetch require sanitize].freeze
      VARIABLE_READS = [ Prism::LocalVariableReadNode, Prism::InstanceVariableReadNode ].freeze
      # `x += 1` makes a new value, so only `=` and `||=` give a variable the one it holds.
      VARIABLE_WRITES = [ Prism::LocalVariableWriteNode, Prism::LocalVariableOrWriteNode, Prism::InstanceVariableWriteNode, Prism::InstanceVariableOrWriteNode ].freeze

      # A method that permits: one named *_params anywhere in it, one of another name only when it returns
      # the permitted params themselves, so a helper that permits to build a URL, or reads one value, is not one.
      def strong_params_entry(def_node)
        name = def_node.name.to_s
        locals = params_locals(def_node.body)
        chains = returned_chains(def_node.body)
        call = if name.end_with?("_params")
          PERMITS.lazy.filter_map { |method| find_call_in_tree(def_node.body, method, locals) }.first
        else
          returned_permit(chains, locals)
        end
        permit_entry(name, call, locals) if call
      end

      # A *_params method that returns what super, a call given the whole params, or another strong-params
      # method makes: one this file defines only when it is one, one it does not (a parent's, a concern's,
      # Pundit's) taken at its *_params or permitted_* name.
      def add_delegating_params(defs, entries, defined)
        chains = defs.to_h { |def_node| [ def_node, def_node.name.end_with?("_params") ? returned_chains(def_node.body) : [] ] }
        loop do
          strong = entries.keys.to_set { |def_node| def_node.name.to_s }
          added = defs.select do |def_node|
            !entries.key?(def_node) && def_node.name.end_with?("_params") &&
              hands_params_on?(chains[def_node]) { |called| !defined.include?(called) || strong.include?(called) }
          end
          break if added.empty?

          added.each { |def_node| entries[def_node] = { name: def_node.name.to_s } }
        end
      end

      def returned_permit(chains, locals)
        chains.each do |chain|
          index = chain.index { |node| node.is_a?(Prism::CallNode) && PERMITS.include?(node.name) && params_value?(node.receiver, locals) }
          next unless index && chain.first(index).all? { |outer| outer.is_a?(Prism::CallNode) && PARAMS_PRESERVING.include?(outer.name) }

          call = chain[index]
          return call unless call.name == :expect && (call.arguments&.arguments || []).all? { |arg| arg.is_a?(Prism::SymbolNode) || arg.is_a?(Prism::StringNode) }
        end
        nil
      end

      def permit_entry(name, call, locals)
        result = { name: name }
        case call.name
        when :permit!
          sliced = sliced_keys(call, locals)
          return result.merge(unrestricted: true) unless sliced

          sliced.any? ? result.merge(permits: sliced) : result
        when :permit
          require_call = find_require_in_chain(call, locals)
          if require_call
            req_arg = require_call.arguments&.arguments&.first
            # Only a literal key is a name to print; `params.require(resource.object_name)` computes one.
            result[:requires] = req_arg.unescaped if req_arg.is_a?(Prism::SymbolNode) || req_arg.is_a?(Prism::StringNode)
          end

          result.merge(parse_permit_args_ast(call))
        else result.merge(parse_expect_args_ast(call))
        end
      end

      # Devise's sanitizer permits what each of its actions takes.
      DELEGATE_NAME = /_params\z|\Apermitted_|\Adevise_parameter_sanitizer\z/

      # A returned super, call given the whole params, or call to a *_params or permitted_* method `may_permit`
      # allows; only through calls that keep it params (`base_params.merge(...)`), not `edition_params[:x] = nil`.
      def hands_params_on?(chains, &may_permit)
        chains.any? do |chain|
          chain.each_with_index.any? do |call, index|
            delegate = call.is_a?(Prism::SuperNode) || call.is_a?(Prism::ForwardingSuperNode) ||
                       (call.receiver.nil? && call.name.to_s.match?(DELEGATE_NAME) && may_permit.call(call.name.to_s))
            next chain.first(index).all? { |outer| outer.is_a?(Prism::CallNode) && (PARAMS_PRESERVING.include?(outer.name) || NESTED_PARAMS.include?(outer.name)) } if delegate

            (call.arguments&.arguments || []).any? do |arg|
              bare_params?(arg) || (arg.is_a?(Prism::KeywordHashNode) && arg.elements.any? { |assoc| assoc.respond_to?(:value) && bare_params?(assoc.value) })
            end
          end
        end
      end

      def bare_params?(node)
        node.is_a?(Prism::CallNode) && node.name == :params && own_receiver?(node) && node.arguments.nil?
      end

      # `params` or `self.params`.
      def own_receiver?(call)
        call.receiver.nil? || call.receiver.is_a?(Prism::SelfNode)
      end

      # Each chain of calls the method can return, outermost first, followed through receivers and through
      # a local to the value it was last given (`attrs = params.permit(:a); attrs.merge(b: 1)`).
      def returned_chains(body)
        return [] unless body

        nodes = AstWalk.each(body).to_a
        writes = nodes.select { |n| VARIABLE_WRITES.any? { |type| n.is_a?(type) } }
                      .group_by(&:name).transform_values { |found| found.max_by { |n| n.location.start_offset } }
        explicit = nodes.grep(Prism::ReturnNode).flat_map { |node| Array(node.arguments&.arguments) }
        [ body, *explicit ].flat_map { |node| tail_expressions(node) }.flat_map { |node| call_chains(node, writes, Set.new) }
      end

      # The expressions a node can end on: the last statement, each branch's last, both sides of && and ||,
      # an array's elements.
      def tail_expressions(node)
        case node
        when nil then []
        when Prism::StatementsNode then tail_expressions(node.body.last)
        when Prism::BeginNode then tail_expressions(node.statements) + tail_expressions(node.else_clause)
        when Prism::ParenthesesNode, Prism::ElseNode then tail_expressions(node.respond_to?(:body) ? node.body : node.statements)
        when Prism::IfNode then tail_expressions(node.statements) + tail_expressions(node.subsequent)
        when Prism::UnlessNode then tail_expressions(node.statements) + tail_expressions(node.else_clause)
        when Prism::CaseNode, Prism::CaseMatchNode then node.conditions.flat_map { |branch| tail_expressions(branch.statements) } + tail_expressions(node.else_clause)
        when Prism::AndNode, Prism::OrNode then tail_expressions(node.left) + tail_expressions(node.right)
        when Prism::ReturnNode then Array(node.arguments&.arguments).flat_map { |arg| tail_expressions(arg) }
        when Prism::ArrayNode then node.elements.flat_map { |element| tail_expressions(element) }
        else node.respond_to?(:value) && node.class.name.end_with?("WriteNode") ? tail_expressions(node.value) : [ node ]
        end
      end

      # `writes` holds each local's last write in the method.
      def call_chains(node, writes, seen)
        case node
        when Prism::CallNode then call_chains(node.receiver, writes, seen).map { |chain| [ node, *chain ] }
        when Prism::SuperNode, Prism::ForwardingSuperNode then [ [ node ] ]
        when *VARIABLE_READS
          return [ [] ] unless seen.add?(node.name)

          write = writes[node.name]
          write ? tail_expressions(write.value).flat_map { |value| call_chains(value, writes, seen) } : [ [] ]
        else [ [] ]
        end
      end

      # Locals that hold params, by name, to the value they hold: one the method assigns
      # (`attrs = params.require(:user)`), or a block's parameter over params (`params[:items].map { |item| ... }`).
      def params_locals(body)
        return {} unless body

        AstWalk.each(body).each_with_object({}) do |node, locals|
          if VARIABLE_WRITES.any? { |type| node.is_a?(type) }
            locals[node.name] = node.value if params_value?(node.value, locals)
          elsif node.is_a?(Prism::CallNode) && node.block.is_a?(Prism::BlockNode) && params_value?(node.receiver, locals)
            block_params = node.block.parameters
            names = block_params.respond_to?(:parameters) && block_params.parameters ? block_params.parameters.requireds : []
            names.each { |param| locals[param.name] = node if param.respond_to?(:name) && param.name }
          end
        end
      end

      def find_call_in_tree(node, method_name, locals = {})
        return nil unless node.respond_to?(:child_nodes)
        if node.is_a?(Prism::CallNode) && node.name == method_name && params_value?(node.receiver, locals)
          return node
        end
        node.child_nodes.compact.each do |child|
          found = find_call_in_tree(child, method_name, locals)
          return found if found
        end
        nil
      end

      # A chain that starts at `params`, at `ActionController::Parameters.new`, or at a local holding one.
      def params_value?(node, locals)
        case node
        when *VARIABLE_READS then locals.key?(node.name)
        when Prism::CallNode
          return true if node.name == :params && own_receiver?(node)
          return node.receiver.slice.delete_prefix("::") == "ActionController::Parameters" if node.name == :new && node.receiver

          params_value?(node.receiver, locals)
        else false
        end
      end

      # `params.slice(:a, :b).permit!` lets through only the keys it slices (none read when they are
      # computed); nil when nothing in the chain slices.
      def sliced_keys(call, locals)
        receiver = through_local(call.receiver, locals)
        return nil unless receiver.is_a?(Prism::CallNode)
        return sliced_keys(receiver, locals) unless receiver.name == :slice

        args = receiver.arguments&.arguments || []
        keys = args.filter_map { |arg| arg.unescaped if arg.is_a?(Prism::SymbolNode) || arg.is_a?(Prism::StringNode) }
        keys.size == args.size ? keys : []
      end

      # A local the method assigned from params reads as the value it holds.
      def through_local(node, locals)
        VARIABLE_READS.any? { |type| node.is_a?(type) } ? locals[node.name] : node
      end

      def find_require_in_chain(node, locals = {})
        receiver = through_local(node.receiver, locals)
        return nil unless receiver.is_a?(Prism::CallNode)
        return receiver if receiver.name == :require
        find_require_in_chain(receiver, locals)
      end

      def parse_permit_args_ast(permit_call)
        permits = []
        nested = {}
        arrays = []
        hashes = []
        computed = {}

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
              if val.is_a?(Prism::ArrayNode) || val.is_a?(Prism::HashNode)
                fields = permit_value(val)
                fields.any? ? nested[key] = fields : (val.is_a?(Prism::HashNode) ? hashes : arrays) << key
              else
                computed[key] = filter_source(val)
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
        result[:hashes] = hashes if hashes.any?
        result[:computed] = computed if computed.any?
        result
      end

      # A key's value always filters a nested hash or array, so one computed at run time is kept as written, on one line.
      def filter_source(node)
        node.slice.gsub(/\s*\n\s*/, " ")
      end

      # params.expect(article: [ :title, :body ]) combines require + permit in
      # one call. Map it to the same shape permit produces: the hash key
      # becomes :requires and the array members become :permits.
      def parse_expect_args_ast(expect_call)
        result = {}
        permits = []
        nested = {}
        arrays = []
        hashes = []
        computed = {}

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
                collect_expect_array(assoc.value, key, permits, nested, arrays, hashes, computed)
              else
                result[:requires] ||= key
                computed[key] = filter_source(assoc.value)
              end
            end
          end
        end

        result[:permits] = permits if permits.any?
        result[:nested] = nested if nested.any?
        result[:arrays] = arrays if arrays.any?
        result[:hashes] = hashes if hashes.any?
        result[:computed] = computed if computed.any?
        result
      end

      def collect_expect_array(array_node, key, permits, nested, arrays, hashes, computed)
        array_node.elements.each do |el|
          case el
          when Prism::SymbolNode
            permits << el.unescaped
          when Prism::ArrayNode
            # Doubly-wrapped array marks an array-of-hashes attribute
            nested[key] = [ permit_fields(el) ]
          when Prism::KeywordHashNode, Prism::HashNode
            el.elements.each do |inner|
              next unless inner.is_a?(Prism::AssocNode)
              inner_key = extract_ast_value(inner.key).to_s
              if inner.value.is_a?(Prism::ArrayNode) && inner.value.elements.empty?
                arrays << inner_key
              elsif inner.value.is_a?(Prism::ArrayNode)
                nested[inner_key] = permit_fields(inner.value)
              elsif inner.value.is_a?(Prism::HashNode)
                fields = permit_value(inner.value)
                fields.any? ? nested[inner_key] = fields : hashes << inner_key
              else
                computed[inner_key] = filter_source(inner.value)
              end
            end
          end
        end
      end

      # What a nested list permits: a scalar by name, `{ key => fields }` for an
      # array (empty for scalars), `{ key => {} }` for any hash,
      # `{ key => { inner => fields } }` for a hash that names its keys, and an
      # inner list as an array, which `expect` reads as an array of hashes.
      def permit_fields(array_node)
        array_node.elements.flat_map do |el|
          case el
          when Prism::SymbolNode, Prism::StringNode then [ el.unescaped ]
          when Prism::ArrayNode then [ permit_fields(el) ]
          when Prism::KeywordHashNode, Prism::HashNode
            el.elements.grep(Prism::AssocNode).map do |assoc|
              key = extract_ast_value(assoc.key).to_s
              value = permit_value(assoc.value)
              value.nil? ? key : { key => value }
            end
          else []
          end
        end
      end

      # Rails reads only an empty `{}` as any hash; a hash with keys permits those keys alone.
      def permit_value(node)
        case node
        when Prism::ArrayNode then permit_fields(node)
        when Prism::HashNode
          node.elements.grep(Prism::AssocNode).each_with_object({}) do |assoc, members|
            value = permit_value(assoc.value)
            members[extract_ast_value(assoc.key).to_s] = value unless value.nil?
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

      def block_formats(source, walked = class_body_walk(source))
        return [] if source.nil?

        parse_result = AstCache.parse_string(source)
        respond_to_blocks = []
        formats = []
        find_respond_to_blocks(parse_result.value, respond_to_blocks)
        nested = nested_ranges(walked)
        respond_to_blocks.reject! { |block| nested.any? { |range| range.cover?(block.location.start_offset) } }
        respond_to_blocks.each { |block| find_format_calls(block, formats) }
        formats.uniq
      rescue => e
        RailsAiContext.debug_fail(e, [], label: "block_formats AST")
      end

      def find_respond_to_blocks(node, blocks)
        return unless node.respond_to?(:child_nodes)
        blocks << node.block if node.is_a?(Prism::CallNode) && node.name == :respond_to && node.block
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

      def extract_rescue_from(source, walked = class_body_walk(source))
        return [] if source.nil? || walked.nil?

        SourceIntrospector.class_level(walked[:rescue_from], walked).flat_map do |entry|
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

      # One walk of the class body serves the rate limits, the respond_to formats, rescue_from and the settings.
      def class_body_walk(source)
        return nil if source.nil?

        SourceIntrospector.walk_source(source, ControllerSettings::LISTENERS.merge(
          rate_limit: -> { Listeners::GenericMacroListener.new(:rate_limit) },
          rescue_from: -> { Listeners::GenericMacroListener.new(:rescue_from) },
          respond_to: -> { Listeners::GenericMacroListener.new(:respond_to, :clear_respond_to) }
        ))
      rescue => e
        RailsAiContext.debug_fail(e, nil, label: "class_body_walk")
      end

      # A class or module nested in the controller declares and defines only for itself.
      def nested_ranges(walked)
        Array(walked && walked[:nested])
      end

      # Each `rate_limit` the class body declares (`name:` lets one controller declare
      # several), as its options read and the literals among them.
      def extract_rate_limits(source, walked = class_body_walk(source))
        return [] if walked.nil?

        SourceIntrospector.class_level(walked[:rate_limit], walked).map do |entry|
          options = entry[:options] || {}
          sources = entry[:option_values] || {}
          text = options.map { |key, value| "#{key}: #{inferred?(value) ? sources[key] : value.inspect}" }.join(", ")
          { text: text, to: options[:to], within: sources[:within]&.to_s, only: options.key?(:only) ? Array(options[:only]).map(&:to_s) : nil,
            name: options[:name] }.select { |key, value| key == :text || literal?(value) }
        end
      rescue => e
        RailsAiContext.debug_fail(e, [], label: "extract_rate_limits")
      end

      def inferred?(value)
        case value
        when Array then value.any? { |item| inferred?(item) }
        when Hash then value.values.any? { |item| inferred?(item) }
        else value == Confidence::INFERRED
        end
      end

      def literal?(value)
        !value.nil? && !inferred?(value)
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

      def parent_declaration(source, class_name)
        DeclaredConstant.parent_declaration(source, class_name)
      end

      # Only a nesting the class name does not already imply is carried: the
      # compact form, or a root-anchored superclass.
      def odd_nesting(class_name, nesting)
        nesting unless nesting.nil? || nesting == SuperclassChain.nesting_of(class_name)
      end

      # Reflection names the superclass absolutely; reading it back by the
      # class's own namespace would land on a namesake there.
      def booted_parent_nesting(ctrl)
        nearest = SuperclassChain.resolve_in_scope(ctrl.name, ctrl.superclass.name) { |c| c.safe_constantize.presence }
        [] unless nearest.nil? || nearest.equal?(ctrl.superclass)
      end

      def read_source(ctrl)
        path = source_path(ctrl)
        return nil unless path && File.exist?(path) && !PathResolver.linked_out?(path, app.root)
        RailsAiContext::SafeFile.read(path)
      end

      # Ruby knows where the class was defined; the underscored name only
      # agrees when the app registers no inflection. See CONTEXT.md,
      # "Declared constant".
      def source_path(ctrl)
        # The app's own, or the engine's its test/dummy runs in: a constant defined by a gem - or by
        # a spec - is not this app's controller file.
        located = Object.const_source_location(ctrl.name)&.first
        return located if located && File.exist?(located) && project_relative(located)

        File.join(app.root.to_s, "app", "controllers", "#{ctrl.name.underscore}.rb")
      rescue StandardError
        File.join(app.root.to_s, "app", "controllers", "#{ctrl.name.underscore}.rb")
      end
    end
  end
end
