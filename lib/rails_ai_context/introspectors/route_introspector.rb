# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    # Extracts route information from the Rails router including
    # HTTP verb, path, controller#action, and route constraints.
    class RouteIntrospector
      extend StaticTier
      static_tier :alternate_source

      # A drawn file can draw again. Rails allows it; this stops a cycle of
      # symlinked or mutually-drawing files from walking forever.
      MAX_DRAW_DEPTH = 5

      attr_reader :app

      def initialize(app)
        @app = app
      end

      # @return [Hash] routes grouped by controller
      def call
        routes = extract_routes
        root = routes.find { |r| r[:path] == "/" && r[:verb]&.include?("GET") }

        {
          # Merged, because that is how every surface that lists routes counts
          # them: Rails registers PATCH and PUT separately for one update
          # action, and a raw total here left the generated context files
          # quoting a grand total their own app-route number cannot reach.
          total_routes: Tools::BaseTool.dedupe_put_patch_routes(routes).size,
          by_controller: group_by_controller(routes),
          api_namespaces: api_namespaces(routes),
          mounted_engines: detect_mounted_engines,
          # Everything routable that has no controller#action: Engine mounts
          # AND bare rack apps (propshaft's /assets mounts a Server instance,
          # which detect_mounted_engines' Class check can't see).
          unrouted_mounts: count_unrouted_mounts,
          root_route: root ? "#{root[:controller]}##{root[:action]}" : nil
        }.tap do |result|
          # `get "/", to: redirect(...)` is routable, has no controller#action
          # and is not a mount, so no row and no count mentioned it. The static
          # tier already counts it as a construct it did not expand.
          dynamic = count_controllerless_constructs
          result[:dynamic_routes] = dynamic if dynamic.positive?
        end
      rescue => e
        { error: e.message }
      end

      # Static tier: answer route questions from config/routes.rb and the
      # files it draws.
      # Output mirrors the runtime shape exactly so tools, resources, and
      # serializers need no static-awareness of their own. Routes behind
      # dynamic constructs (devise_for, an unreadable draw, a lambda or
      # redirect target) are counted in :dynamic_routes rather than
      # fabricated.
      def static_call
        routes_path = File.join(app.root.to_s, "config", "routes.rb")
        return { error: "config/routes.rb not found in #{app.root}" } unless File.exist?(routes_path)

        records, mounts, files = walk_routes_file(routes_path)
        entries = records.select { |r| r[:type] == :route }
        # A followed `draw` is no longer unexpanded - its routes are in the
        # list above. Counting it would overstate what is missing by exactly
        # the number of files this pass just read.
        dynamic = records.count { |r| r[:type] == :dynamic && !r[:followed] }

        result = {
          # Merged, for the reason `call` gives above: a raw total here made the
          # generated files say "8 total" where rails_get_routes, which merges
          # for itself, said 7 on the same `resources :posts`.
          total_routes: Tools::BaseTool.dedupe_put_patch_routes(entries).size,
          by_controller: group_by_controller(entries),
          api_namespaces: api_namespaces(entries),
          mounted_engines: mounts.map { |m| { engine: m[:engine], path: m[:path] } },
          # Every mount parsed from routes.rb is controller-less by
          # construction, so the booted tier's count has a static answer too.
          unrouted_mounts: mounts.size,
          root_route: static_root_route(entries),
          note: "Parsed statically from #{static_sources_phrase(files)} (app not booted)",
          confidence: Confidence::STATIC
        }
        result[:dynamic_routes] = dynamic if dynamic.positive?
        result
      rescue => e
        { error: e.message }
      end

      private

      # An app that splits its routing table with `draw` keeps most of it in
      # config/routes/*.rb, and reading config/routes.rb alone answered 94 on a
      # 723-route app with nothing saying the count was partial. Rails resolves
      # `draw(:admin)` to config/routes/admin.rb by literal path, so following
      # it is a plain file read.
      #
      # Returns the merged records, mounts, and the files actually read.
      def walk_routes_file(path, already_read = [], depth = 0)
        return [ [], [], [] ] if depth > MAX_DRAW_DEPTH

        already_read << path
        ast = SourceIntrospector.walk(path, {
          routes: -> { Listeners::RoutesDslListener.new },
          mounts: -> { Listeners::MountListener.new }
        })
        records = ast[:routes] || []
        mounts = ast[:mounts] || []
        files = [ path ]

        records.select { |r| r[:type] == :dynamic && r[:macro] == :draw }.each do |record|
          target = draw_target_path(record[:target])
          next unless target

          # Two files can draw the same third one, and a cycle brings the walk
          # back to a file it started at. Both mean the routes are already in
          # the list, so the draw is expanded even though this branch will not
          # read it again - and this is also what stops the recursion.
          if already_read.include?(target)
            record[:followed] = true
            next
          end

          sub_records, sub_mounts, sub_files = walk_draw_target(target, already_read, depth)
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

      # A drawn file that cannot be parsed - over AstCache's size ceiling, or
      # syntax-broken - must cost its own routes, not the routing table. Before
      # this walk existed only config/routes.rb could fail the whole section;
      # letting the raise through would hand that power to every file it draws.
      # The draw stays unmarked, so the count already says routes are missing.
      def walk_draw_target(target, already_read, depth)
        walk_routes_file(target, already_read, depth + 1)
      rescue StandardError, ScriptError => e
        $stderr.puts "[rails-ai-context] draw target #{target} skipped: #{e.message}" if ENV["DEBUG"]
        [ [], [], [] ]
      end

      # `draw(:"admin/users")` is legal and resolves under config/routes/, but
      # the name reaches here from source text, so the resolved path has to be
      # confirmed inside that directory before it is read.
      #
      # Resolved with realpath, like safe_glob_realpath: expand_path folds
      # `..` without following links, so a symlink under config/routes/ was
      # enough to read a file anywhere on disk.
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

      def static_sources_phrase(files)
        root = "#{app.root}#{File::SEPARATOR}"
        names = files.map { |f| f.delete_prefix(root) }
        return names.first if names.size == 1

        "#{names.first} and #{CountPhrase.call(names.size - 1, "file")} it draws"
      end

      def extract_routes
        # Force Rails to reload routes if routes.rb has changed
        app.routes_reloader&.execute_if_updated rescue nil

        app.routes.routes.filter_map do |route|
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

      def extract_constraints(route)
        constraints = route.constraints.to_s
        constraints.empty? ? nil : constraints
      rescue => e
        RailsAiContext.debug_fail(e, nil, label: "extract_constraints")
      end

      def group_by_controller(routes)
        routes.group_by { |r| r[:controller] }.transform_values do |controller_routes|
          controller_routes.map do |r|
            entry = { verb: r[:verb], path: r[:path], action: r[:action], name: r[:name] }
            entry[:params] = r[:params] if r[:params]
            entry[:restful] = r[:restful] unless r[:restful].nil?
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
        controllerless_routes.count { |r| dynamic_target?(r) }
      rescue => e
        RailsAiContext.debug_fail(e, 0, label: "count_controllerless_constructs")
      end

      def controllerless_routes
        app.routes.routes.reject do |r|
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
