# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    # Extracts route information from the Rails router including
    # HTTP verb, path, controller#action, and route constraints.
    class RouteIntrospector < Base
      extend StaticTier
      static_tier :alternate_source

      # A drawn file can draw again. Rails allows it; this stops a cycle of
      # symlinked or mutually-drawing files from walking forever.
      MAX_DRAW_DEPTH = 5

      # @return [Hash] routes grouped by controller
      def call
        routes = extract_routes
        root = routes.find { |r| r[:path] == "/" && r[:verb]&.include?("GET") }

        {
          # Merged, because that is how every surface that lists routes counts
          # them: Rails registers PATCH and PUT separately for one update
          # action, and a raw total here left the generated context files
          # quoting a grand total their own app-route number cannot reach.
          total_routes: RouteCoverage.dedupe_put_patch_routes(routes).size,
          by_controller: group_by_controller(routes),
          api_namespaces: api_namespaces(routes),
          mounted_engines: detect_mounted_engines,
          # Everything routable that has no controller#action and is not a
          # redirect or a lambda: the same set the list above names.
          unrouted_mounts: count_unrouted_mounts,
          root_route: root ? "#{root[:controller]}##{root[:action]}" : nil
        }.tap do |result|
          # `get "/", to: redirect(...)` is routable, has no controller#action
          # and is not a mount, so no row and no count mentioned it. The static
          # tier already counts it as a construct it did not expand.
          dynamic = count_controllerless_constructs
          result[:dynamic_routes] = dynamic if dynamic.positive?
          engine_routes = booted_engine_routes
          result[:engine_routes] = engine_routes if engine_routes.any?
          add_grape_endpoints(result)
        end
      end

      def add_grape_endpoints(result)
        grape = GrapeEndpoints.call(app.root, result[:mounted_engines])
        result[:grape_endpoints] = grape if grape.any?
      end

      # Static tier: answer route questions from config/routes.rb and the
      # files it draws.
      # Output mirrors the runtime shape exactly so tools, resources, and
      # serializers need no static-awareness of their own. Routes behind
      # dynamic constructs (devise_for, an unreadable draw, a lambda or
      # redirect target) are counted in :dynamic_routes rather than
      # fabricated.
      def static_call
        top_files, computed = route_files
        return { error: "config/routes.rb not found in #{app.root}" } if top_files.empty?

        records, mounts, files = walk_route_files(top_files)
        records = records.map { |r| r.except(:engine) } if engine_root?
        in_repo = in_repo_routes(mounts)
        records += in_repo.values.flat_map(&:first)
        mounts = distinct_mounts(mounts + in_repo.values.flat_map(&:last))
        # What an app draws into an engine's table is the engine's, which the
        # booted tier's Rails.application.routes holds only as the mount.
        app_records, engine_records = records.partition { |r| r[:engine].nil? }
        entries = app_records.select { |r| r[:type] == :route }
        # A followed `draw` is no longer unexpanded - its routes are in the
        # list above. Counting it would overstate what is missing by exactly
        # the number of files this pass just read.
        dynamic = app_records.count { |r| r[:type] == :dynamic && !r[:followed] }

        result = {
          # Merged, for the reason `call` gives above: a raw total here made the
          # generated files say "8 total" where rails_get_routes, which merges
          # for itself, said 7 on the same `resources :posts`.
          total_routes: RouteCoverage.dedupe_put_patch_routes(entries).size,
          by_controller: group_by_controller(entries),
          api_namespaces: api_namespaces(entries),
          mounted_engines: mounts.map { |m| { engine: m[:engine], path: m[:path], condition: m[:condition] }.compact },
          # Every mount parsed from routes.rb is controller-less by
          # construction, so the booted tier's count has a static answer too.
          unrouted_mounts: mounts.size,
          root_route: static_root_route(entries),
          note: "Parsed statically from #{static_sources_phrase(files, top_files)}" \
                "#{initializers_phrase}" \
                "#{computed ? ', plus route files config/application.rb computes (not read)' : ''} (app not booted)",
          confidence: Confidence::STATIC
        }
        result[:dynamic_routes] = dynamic if dynamic.positive?
        engine_routes = engine_route_groups(engine_records, mounts) + unread_engine_tables(engine_records, mounts)
        result[:engine_routes] = engine_routes if engine_routes.any?
        unread = (in_repo_route_files - in_repo.keys).size
        result[:in_repo_route_files] = unread if unread.positive?
        add_grape_endpoints(result)
        result
      end

      # Run from a mountable engine's own root there is no app table: the
      # engine's table, drawn in its config/routes.rb, is the project's routes.
      def engine_root?
        return @engine_root unless @engine_root.nil?

        root = app.root.to_s
        @engine_root = !File.exist?(File.join(root, "config", "application.rb")) &&
                       !app_route_file?(File.join(root, "config", "routes.rb"))
      end

      # Every routes.rb under an in-repo engine or plugin root. One the app does not mount has
      # no place in the static table, so the count says it was skipped.
      def in_repo_route_files
        PathResolver.code_roots(app.root.to_s)
          .map { |dir| File.join(dir, "config", "routes.rb") }
          .select { |path| File.exist?(path) }
      end

      # Rails loads every engine's routes.rb. One that appends to the app's own
      # table adds app routes; one that draws into an engine the app mounts is
      # placed under the mount.
      # @return [Hash] path => [records, mounts], for files read into the app's table
      def in_repo_routes(mounts)
        walked = in_repo_route_files.to_h { |path| [ path, walk_routes_file(path) ] }
        app_files = walked.keys.select { |path| app_route_file?(path) }.to_set
        mounted = (mounts + app_files.flat_map { |path| walked[path][1] }).map { |m| m[:engine] }.to_set
        walked.each_with_object({}) do |(path, (records, file_mounts, _files)), found|
          app = app_files.include?(path)
          kept = records.select { |r| r[:engine] ? mounted.include?(r[:engine]) : app }
          file_mounts = app ? file_mounts : []
          # A file that draws nothing (all commented out) has nothing left unread.
          found[path] = [ kept, file_mounts ] if kept.any? || file_mounts.any? || records.empty?
        end
      end

      # `Rails.application.routes` or `X::Application.routes`, drawn, appended or prepended.
      def app_route_file?(path)
        AstWalk.each(AstCache.parse_string(SafeFile.read(path).to_s).value).any? do |node|
          next false unless node.is_a?(Prism::CallNode) && %i[draw append prepend].include?(node.name) && node.block

          routes = node.receiver
          routes.is_a?(Prism::CallNode) && routes.name == :routes &&
            routes.receiver&.slice.to_s.delete_prefix("::").match?(/\A(Rails\.application|(\w+::)*Application)\z/)
        end
      rescue StandardError, ScriptError => e
        RailsAiContext.debug_fail(e, false, label: "app_route_file? #{path}")
      end

      # What config/routes.rb and every file it draws mount, from source. The
      # engines section reads this rather than walking config/routes.rb on its
      # own, so the two sections name one set of mounted apps.
      #
      # @return [Array<Hash>] { engine:, path:, location: } per mounted app
      def static_mounts
        top_files, _computed = route_files
        _records, mounts, _files = walk_route_files(top_files)
        mounts
      end

      # Routes drawn into each engine, under the path the app mounts it at and
      # named through the engine's route proxy (`spree.admin_orders_path`).
      def engine_route_groups(engine_records, mounts)
        engine_records.group_by { |r| r[:engine] }.map do |engine, records|
          routes = records.select { |r| r[:type] == :route }
          dynamic = records.count { |r| r[:type] == :dynamic && !r[:followed] }
          mount_records = mounts.select { |m| m[:engine] == engine }
          mount_record = mount_records.first
          mount = mount_record&.dig(:path)
          proxy = route_proxy(engine, mount_record)
          {
            engine: engine,
            mount: mount,
            # Merged like the app's table, so the two counts beside each other count alike.
            routes: RouteCoverage.dedupe_put_patch_routes(routes.map do |route|
              route.except(:engine).merge(
                path: mount && mount != "/" ? "#{mount.chomp("/")}#{route[:path]}" : route[:path],
                name: route[:name] && "#{proxy}.#{route[:name]}"
              ).compact
            end),
            dynamic_routes: dynamic.positive? ? dynamic : nil,
            mount_computed: (true if mount_record && mount.nil?),
            also_mounted_at: mount_records.drop(1).map { |m| m[:path] }.presence
          }.compact
        end
      end

      # An engine the app draws nothing into still has its own table, drawn in
      # its own code, which only boot reads. A mounted Rack app has no table at all.
      def unread_engine_tables(engine_records, mounts)
        drawn = engine_records.map { |r| r[:engine] }.to_set
        roots = PathResolver.autoload_roots(app.root.to_s) + PathResolver.path_gem_libs(app.root.to_s)
        mounts.reject { |m| drawn.include?(m[:engine]) }
          .group_by { |m| m[:engine] }
          .select { |engine, _| engine_constant?(engine, roots) }
          .map do |engine, same|
            { engine: engine, mount: same.first[:path], mount_computed: (true unless same.first[:path]), routes: [],
              also_mounted_at: same.drop(1).map { |m| m[:path] }.presence,
              unavailable: "the engine's own routes are read only with the app booted" }.compact
          end
      end

      # The app's own definition says whether it subclasses Rails::Engine; a
      # gem's constant is read nowhere here, so its name is all there is.
      def engine_constant?(name, roots)
        path = PathResolver.file_for_constant(app.root.to_s, name, roots: roots)
        return name.to_s.match?(/(?:\A|::)Engine\z/) unless path

        SafeFile.read(path).to_s.match?(/<\s*(?:::)?Rails::Engine\b/)
      end

      # Rails names the proxy after the mount: its `as:`, else the engine's
      # engine_name, under the names of the scopes around it.
      def route_proxy(engine, mount)
        name = mount&.dig(:as) || engine_name(engine)
        [ mount&.dig(:name_prefix), name ].compact.join("_")
      end

      # `engine_name "x"`, else `isolate_namespace Mod` as mod, else Rails'
      # railtie name from the class (wiki/engine -> wiki_engine).
      def engine_name(engine)
        path = PathResolver.file_for_constant(app.root.to_s, engine)
        # An engine outside the repo has no file here to read its name from.
        return Listeners::RoutesDslListener.engine_namespace(engine) unless path

        source = SafeFile.read(path)
        declared = AstWalk.each(AstCache.parse_string(source).value)
          .find { |n| n.is_a?(Prism::CallNode) && n.receiver.nil? && n.name == :engine_name }&.then { |c| literal_arg(c) }
        isolated = TableName.isolated_namespaces(source).first
        declared || isolated&.underscore&.tr("/", "_") || engine.underscore.tr("/", "_")
      rescue StandardError, ScriptError => e
        RailsAiContext.debug_fail(e, Listeners::RoutesDslListener.engine_namespace(engine), label: "engine_name #{engine}")
      end

      def literal_arg(call)
        arg = call.arguments&.arguments&.first
        arg.unescaped if arg.is_a?(Prism::SymbolNode) || arg.is_a?(Prism::StringNode)
      end

      # Rails' route files in its order: config/routes.rb or config.paths["config/routes.rb"]
      # from application.rb. Returns [paths, whether part of the list is computed].
      def route_files
        root = app.root.to_s
        list = [ "config/routes.rb" ]
        computed = false
        app_rb = File.join(root, "config", "application.rb")
        if File.file?(app_rb)
          SourceIntrospector.walk(app_rb, { files: Listeners::RouteFilesListener })[:files].each do |entry|
            computed ||= entry[:computed] == true
            found = Array(entry[:paths]) + Array(entry[:globs]).flat_map { |glob| Dir.glob(glob, base: root).sort }
            list =
              case entry[:op]
              when :set then found
              when :prepend then found + list
              else list + found
              end
          end
        end
        [ contained_route_files(root, list), computed ]
      end

      def contained_route_files(root, list)
        real_root = File.realpath(root)
        list.filter_map do |relative|
          path = File.expand_path(relative, root)
          next unless File.file?(path)

          path if SafePath.contained?(File.realpath(path), real_root)
        end.uniq
      rescue SystemCallError
        []
      end

      def walk_route_files(top_files)
        already_read = []
        @route_names = Set.new
        records, mounts, files = top_files.each_with_object([ [], [], [] ]) do |path, (all_records, all_mounts, all_files)|
          next if already_read.include?([ path, [] ])

          sub_records, sub_mounts, sub_files = walk_routes_file(path, already_read)
          all_records.concat(sub_records)
          all_mounts.concat(sub_mounts)
          all_files.concat(sub_files)
        end
        added, added_mounts = walk_route_initializers(already_read)
        # An after_initialize hook adds its blocks after every initializer has added its own.
        prepended, appended = added.sort_by.with_index { |r, i| [ r[:late] ? 1 : 0, i ] }.partition { |r| r[:prepend] }
        records = (prepended + records + appended).map { |r| r.except(:prepend, :late) }
        [ records, distinct_mounts(mounts + added_mounts), files.uniq ]
      end

      # Both arms of an if/else can mount one app at one path; a mount is named once per app and
      # path, under no condition when a copy has none or the copies fill every arm of one chain.
      def distinct_mounts(mounts)
        mounts.group_by { |mount| [ mount[:engine], mount[:path] ] }.map do |_, same|
          mount = same.first.except(:condition, :arm)
          conditions = same.map { |copy| copy[:condition] }.uniq
          next mount if conditions.include?(nil) || every_arm?(same.map { |copy| copy[:arm] })

          mount.merge(condition: conditions.join(" or "))
        end
      end

      def every_arm?(arms)
        return false if arms.include?(nil)

        chain = arms.first.first(2)
        arms.all? { |arm| arm.first(2) == chain } && arms.map { |arm| arm[2] }.uniq.size == arms.first.last
      end

      # Initializers that add to the app's table with `routes.prepend` or
      # `routes.append`, which Rails evaluates before and after the draw.
      def route_initializers
        @route_initializers ||= begin
          root = app.root.to_s
          listed = Dir.glob("config/initializers/**/*.rb", base: root).sort
          contained_route_files(root, listed).select do |path|
            SafeFile.read(path).to_s.match?(/\.routes\.(?:append|prepend)\b/) && app_route_file?(path)
          end
        end
      end

      def walk_route_initializers(already_read)
        route_initializers.each_with_object([ [], [] ]) do |path, (records, mounts)|
          sub_records, sub_mounts = walk_draw_target(path, already_read, 0, {})
          records.concat(sub_records)
          mounts.concat(sub_mounts)
        end
      end

      private

      # An app that splits its routing table with `draw` keeps most of it in
      # config/routes/*.rb, and reading config/routes.rb alone answered 94 on a
      # 723-route app with nothing saying the count was partial. Rails resolves
      # `draw(:admin)` to config/routes/admin.rb by literal path, so following
      # it is a plain file read.
      #
      # Returns the merged records, mounts, and the files actually read.
      # A drawn file runs inside the scope its `draw` sits in, so it is walked
      # with that scope, and read once per scope that draws it.
      def walk_routes_file(path, already_read = [], depth = 0, draw = {})
        return [ [], [], [] ] if depth > MAX_DRAW_DEPTH

        scope = draw[:scope] || []
        already_read << [ path, scope ]
        ast = SourceIntrospector.walk(path, {
          routes: -> { Listeners::RoutesDslListener.new(scope: scope, route_set: method(:route_set_prefixes), names: @route_names, multi_path: multi_path_routes?) },
          mounts: -> { Listeners::MountListener.new(prefix: draw[:prefix], name_prefix: draw[:name_prefix]) }
        })
        records = ast[:routes] || []
        mounts = (ast[:mounts] || []).map { |m| m[:arm] ? m.merge(arm: [ path, *m[:arm] ]) : m }
        files = [ path ]

        records.select { |r| r[:type] == :dynamic && r[:macro] == :draw }.each do |record|
          target = draw_target_path(record[:target])
          next unless target

          # Two files can draw the same third one under one scope, and a cycle
          # brings the walk back to a file it started at. Both mean the routes are already in
          # the list, so the draw is expanded even though this branch will not
          # read it again - and this is also what stops the recursion.
          if already_read.include?([ target, record[:scope] ])
            record[:followed] = true
            next
          end

          sub_records, sub_mounts, sub_files = walk_draw_target(target, already_read, depth, record)
          # Only the depth cap and an unreadable file get here, and both mean
          # routes are missing. Marking the draw followed would drop the caveat
          # precisely where it is needed.
          next if sub_files.empty?

          record[:followed] = true
          records.concat(sub_records)
          mounts.concat(sub_mounts)
          files.concat(sub_files)
        end

        [ records, mounts, files ]
      end

      # `ApiRouteSet::V1.draw(self)` hands the block to an app class. Its
      # `self.prefix` and `mapper_prefix`, when they return a literal, are the
      # path and name prefixes; a class the app does not define answers nil.
      def route_set_prefixes(name)
        @route_set_prefixes ||= {}
        return @route_set_prefixes[name] if @route_set_prefixes.key?(name)

        @route_set_prefixes[name] = read_route_set(name)
      end

      def read_route_set(name)
        path = PathResolver.namespace_files(app.root.to_s, name).first
        return unless path

        classes = DeclaredConstant.constants(AstCache.parse(path).value)
          .each_with_object({}) { |(qualified, node), found| found[qualified] ||= node if node.is_a?(Prism::ClassNode) }
        return unless classes.key?(name)

        { prefix: literal_method(classes, name, :prefix, singleton: true),
          name_prefix: literal_method(classes, name, :mapper_prefix, singleton: false) }
      rescue StandardError, ScriptError => e
        RailsAiContext.debug_fail(e, nil, label: "route set #{name}")
      end

      # The string a method returns when its body is that one literal, looked
      # up through superclasses defined in the same file.
      def literal_method(classes, name, method, singleton:, seen: [])
        klass = classes[name]
        return if klass.nil? || seen.include?(name)

        found = Array(klass.body&.body).find do |d|
          d.is_a?(Prism::DefNode) && d.name == method && d.receiver.is_a?(Prism::SelfNode) == singleton
        end
        if found
          body = Array(found.body&.body)
          return body.first.unescaped if body.size == 1 && body.first.is_a?(Prism::StringNode)

          return
        end

        parent = klass.superclass&.slice&.delete_prefix("::")
        parent && literal_method(classes, parent, method, singleton: singleton, seen: seen + [ name ])
      end

      # A drawn file that cannot be parsed - over AstCache's size ceiling, or
      # syntax-broken - must cost its own routes, not the routing table. Before
      # this walk existed only config/routes.rb could fail the whole section;
      # letting the raise through would hand that power to every file it draws.
      # The draw stays unmarked, so the count already says routes are missing.
      def walk_draw_target(target, already_read, depth, draw)
        walk_routes_file(target, already_read, depth + 1, draw)
      rescue StandardError, ScriptError => e
        RailsAiContext.debug_fail(e, [ [], [], [] ], label: "draw target #{target}")
      end

      # `draw(:"admin/users")` is legal and resolves under config/routes/, but
      # the name reaches here from source text, so the resolved path has to be
      # confirmed inside that directory before it is read.
      #
      # Resolved with realpath, like safe_glob_realpath: expand_path folds
      # `..` without following links, so a symlink under config/routes/ was
      # enough to read a file anywhere on disk.
      # Rails 8.1 raises on `get "/a", "/b"`; with no version locked the routes are not guessed.
      def multi_path_routes?
        return @multi_path_routes if defined?(@multi_path_routes)

        locked = GemLock.for(app.root.to_s).version("actionpack")
        @multi_path_routes = !locked.nil? && Gem::Version.new(locked) < Gem::Version.new("8.1.0.a")
      end

      def draw_target_path(target)
        return nil if target.nil? || target.to_s.empty?

        dir = File.realpath(File.join(app.root.to_s, "config", "routes"))
        candidate = File.realpath(File.join(dir, "#{target}.rb"))
        return nil unless candidate.start_with?("#{dir}#{File::SEPARATOR}")
        return nil unless File.file?(candidate)

        candidate
      rescue SystemCallError
        # No config/routes/ at all, a dangling symlink, or a name that resolves
        # to nothing. None of them is a route this pass can read.
        nil
      end

      def static_sources_phrase(files, top_files = files.first(1))
        root = "#{app.root}#{File::SEPARATOR}"
        names = files.map { |f| f.delete_prefix(root) }
        tops = top_files.map { |f| f.delete_prefix(root) }
        drawn = names.size - tops.size
        lead = tops.size == 1 ? tops.first : "#{tops.join(', ')} (config.paths)"
        return lead if drawn <= 0

        "#{lead} and #{CountPhrase.call(drawn, "file")} #{tops.size == 1 ? 'it draws' : 'they draw'}"
      end

      def initializers_phrase
        return "" if route_initializers.empty?

        root = "#{app.root}#{File::SEPARATOR}"
        ", plus routes appended or prepended in #{route_initializers.map { |f| f.delete_prefix(root) }.join(', ')}"
      end

      def extract_routes
        # Force Rails to reload routes if routes.rb has changed
        app.routes_reloader&.execute_if_updated rescue nil

        table_routes(app.routes)
      end

      # Booted, each mounted engine's table under its mount and the mount's
      # name, as `bin/rails routes` prints it. Boot holds one table per engine,
      # so this is the whole of it, gem-drawn routes included.
      def booted_engine_routes
        groups = mounted_routes.filter_map do |mount|
          engine = mount.app.respond_to?(:app) ? mount.app.app : mount.app
          next unless engine.is_a?(Class) && engine < ::Rails::Engine

          prefix = mount_path(mount).chomp("/")
          rows = table_routes(engine.routes).map do |route|
            path = route[:path] == "/" && !prefix.empty? ? prefix : "#{prefix}#{route[:path]}"
            route.merge(path: path, name: route[:name] && "#{mount.name}.#{route[:name]}").compact
          end
          next if rows.empty?

          { engine: engine.name, mount: mount_path(mount), whole_table: true,
            routes: RouteCoverage.dedupe_put_patch_routes(rows) }
        end
        # One group per engine, listed under its first mount; the rest are named.
        groups.group_by { |group| group[:engine] }.map do |_engine, same|
          others = same.drop(1).map { |group| group[:mount] }
          others.any? ? same.first.merge(also_mounted_at: others) : same.first
        end
      rescue => e
        RailsAiContext.debug_fail(e, [], label: "booted_engine_routes")
      end

      def table_routes(route_set)
        route_set.routes.filter_map do |route|
          # Journey::Route exposes the flag as a plain attribute reader
          # (`internal`), not a predicate - a respond_to?(:internal?) guard
          # never matches and would let Rails' info/mailers routes through.
          next if route.respond_to?(:internal) && route.internal
          next if route.defaults[:controller].blank?

          route_path = route.path.spec.to_s.gsub("(.:format)", "")
          action = route.defaults[:action]

          entry = {
            verb: route.verb.presence || "ANY",
            path: route_path,
            controller: route.defaults[:controller],
            action: action,
            name: route.name,
            constraints: extract_constraints(route)
          }

          params = route_path.scan(/:(\w+)/).flatten
          entry[:params] = params if params.any?

          entry[:restful] = %w[index show new create edit update destroy].include?(action)

          entry.compact
        end
      end

      # The engines section counts an engine's table with these same rows.
      public :table_routes

      # What `bin/rails routes` prints beside the route, written alike on every Ruby.
      def extract_constraints(route)
        shown = route.requirements.except(:controller, :action)
        "{#{shown.map { |key, value| "#{key}: #{value.inspect}" }.join(', ')}}" if shown.any?
      rescue => e
        RailsAiContext.debug_fail(e, nil, label: "extract_constraints")
      end

      def group_by_controller(routes)
        routes.group_by { |r| r[:controller] }.transform_values do |controller_routes|
          controller_routes.map do |r|
            entry = { verb: r[:verb], path: r[:path], action: r[:action], name: r[:name] }
            entry[:params] = r[:params] if r[:params]
            entry[:restful] = r[:restful] unless r[:restful].nil?
            entry[:condition] = r[:condition] if r[:condition]
            entry[:constraints] = r[:constraints] if r[:constraints]
            entry.compact
          end
        end
      end

      def count_unrouted_mounts
        mounted_routes.size
      rescue => e
        RailsAiContext.debug_fail(e, 0, label: "count_unrouted_mounts")
      end

      def count_controllerless_constructs
        dynamic_route_count(app.routes)
      rescue => e
        RailsAiContext.debug_fail(e, 0, label: "count_controllerless_constructs")
      end

      # The redirects and lambdas a route set holds, which no controller#action row lists.
      def dynamic_route_count(route_set)
        controllerless_routes(route_set).count { |r| dynamic_target?(r) }
      end
      public :dynamic_route_count

      def controllerless_routes(route_set = app.routes)
        route_set.routes.reject do |r|
          (r.respond_to?(:internal) && r.internal) || r.defaults[:controller].present?
        end
      end

      # A redirect or a `to: ->(env) {}` route has no controller and is not a
      # mounted app.
      def dynamic_target?(route)
        rack_app = route.app.respond_to?(:app) ? route.app.app : route.app
        return true if defined?(ActionDispatch::Routing::Redirect) && rack_app.is_a?(ActionDispatch::Routing::Redirect)

        rack_app.is_a?(Proc)
      end

      # Every Rack app the route set carries, engine or not, read off the same
      # set the count reads: `mount App => path` is `match(path, to: app,
      # via: :all, anchor: false)` with a name derived, so the two forms build
      # the same endpoint, and keeping only Rails::Engine subclasses left a
      # plain Rack app counted in the header and named nowhere. An app mounted
      # as an instance (propshaft's Server) is named by its class, because the
      # count includes it either way and a header that disagrees with the list
      # below it is the thing this pairing exists to prevent.
      def detect_mounted_engines
        mounted_routes.map do |r|
          mounted = r.app.respond_to?(:app) ? r.app.app : r.app
          name = mounted.is_a?(Class) ? mounted.name : mounted.class.name
          # An app mounted as an instance of an anonymous class has no name to
          # print and is still one of the endpoints the count counts, so it is
          # named for what it is rather than dropped into a disagreement
          # between the two numbers.
          { engine: name || "(anonymous Rack app)", path: mount_path(r) }
        rescue => e
          RailsAiContext.debug_fail(e, { engine: "(unreadable Rack app)", path: nil }, label: "detect_mounted_engines")
        end
      end

      # Routable, controller-less, and not a redirect or a lambda: what is
      # left is a Rack app attached at a path. Walked once: the count and the
      # list are the same set, and reading it twice is reading the whole route
      # table twice.
      def mounted_routes
        @mounted_routes ||= controllerless_routes.reject { |r| dynamic_target?(r) }
      end

      # `match` records the format segment the path spec carries; `mount` does
      # not. The path a reader asks about is the one without it.
      def mount_path(route)
        route.path.spec.to_s.sub(/\(\.:format\)\z/, "")
      end

      # One rule for both tiers, like total_routes above: a namespace is a
      # prefix the app serves, so /admin/api/v1 is not one and /apidocs is not
      # /api. Sorted so the two tiers cannot differ on order either.
      def api_namespaces(entries)
        entries.filter_map { |e| e[:path][%r{\A/api(?:/v\d+)?(?=/|\z)}] }.uniq.sort
      end

      def static_root_route(entries)
        root = entries.find { |e| e[:path] == "/" && e[:verb] == "GET" }
        root && "#{root[:controller]}##{root[:action]}"
      end
    end
  end
end
