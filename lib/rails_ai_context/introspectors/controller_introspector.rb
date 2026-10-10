# frozen_string_literal: true

require "pathname"
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

        { controllers: inherit_class_declarations(fill_inherited_actions(inherit_api_controller(result))) }
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
          controllers: inherit_class_declarations(fill_inherited_actions(inherit_api_controller(result))),
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
            declared = entry ? own[link] : base_class_declarations(source)
            [ link, declared ] if declared
          end
          formats = lineage.each_with_object(Set.new) { |(_, declared), set| fold_formats(set, declared[:formats]) }
          limits = lineage.flat_map { |link, declared| link == name ? declared[:rate_limits] : declared[:rate_limits].map { |limit| limit.merge(from: link) } }
          [ name, (formats.to_a | own[name][:block_formats]).sort, limits ]
        end
        folded.each do |name, formats, limits|
          result[name][:respond_to_formats] = formats
          limits.any? ? result[name][:rate_limits] = limits : result[name].delete(:rate_limits)
        end
        result
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
      def base_class_declarations(source)
        (@base_class_declarations ||= {})[source] ||= class_declarations(source, class_body_walk(source))
      end

      # { formats: [[format...] per respond_to, nil per clear_respond_to], rate_limits: [...] }
      def class_declarations(source, walked)
        calls = walked ? SourceIntrospector.class_level(walked[:respond_to], walked) : []
        formats = calls.map { |call| call[:macro] == :clear_respond_to ? nil : Array(call[:args]).map(&:to_s) }
        { formats: formats, rate_limits: extract_rate_limits(source, walked) }
      end

      # What both tiers do with a file: read it, name it by what it declares,
      # and extract. A file it cannot read is an entry saying so, not a gap.
      def detail_for(record, path_name)
        source = SafeFile.read(record.path)
        return [ path_name, { error: "unreadable" } ] unless source
        return nil unless record.path.end_with?("_controller.rb") || subclasses_a_controller?(source, path_name)

        name = DeclaredConstant.resolve(source, path_name)
        [ name, extract_details_from_source(record, name, source) ]
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
          strong_params: extract_strong_params(source, walked),
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
          strong_params: extract_strong_params(source, walked),
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

      def extract_strong_params(source, walked = class_body_walk(source))
        return [] if source.nil?

        parse_result = AstCache.parse_string(source)
        param_methods = []
        find_param_methods(parse_result.value, param_methods)
        nested = nested_ranges(walked)
        param_methods.reject do |entry|
          offset = entry.delete(:offset)
          nested.any? { |range| range.cover?(offset) }
        end
      rescue => e
        RailsAiContext.debug_fail(e, [], label: "extract_strong_params AST")
      end

      def find_param_methods(node, results)
        return unless node.respond_to?(:child_nodes)
        if node.is_a?(Prism::DefNode) && node.name.to_s.end_with?("_params")
          results << extract_permit_from_def(node).merge(offset: node.location.start_offset)
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
        hashes = []

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
        result[:hashes] = hashes if hashes.any?
        result
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
                collect_expect_array(assoc.value, key, permits, nested, arrays, hashes)
              else
                permits << key
              end
            end
          end
        end

        result[:permits] = permits if permits.any?
        result[:nested] = nested if nested.any?
        result[:arrays] = arrays if arrays.any?
        result[:hashes] = hashes if hashes.any?
        result
      end

      def collect_expect_array(array_node, key, permits, nested, arrays, hashes)
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
                permits << inner_key
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
