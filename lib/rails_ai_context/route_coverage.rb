# frozen_string_literal: true

module RailsAiContext
  # One answer to "how much of the routing table is this number", for every
  # surface that prints a route count.
  #
  # `RouteIntrospector` records the constructs it refused to fabricate -
  # `devise_for`, a `draw` whose target is computed or too large to parse - in
  # `:dynamic_routes`, and nothing read it. So `rails_get_routes`, `CLAUDE.md`,
  # the Cursor and Copilot rule files, `rails_onboard` and the rake summary all
  # quoted 94 routes on a 723-route app with nothing saying the count was
  # partial. Nine call sites each having to remember is what produced that;
  # this is the seam they share.
  module RouteCoverage
    module_function

    # A framework-engine controller per the excluded_route_prefixes config -
    # the boundary between "the app's routes" and what Rails mounts on its own.
    def framework_controller?(name)
      RailsAiContext.configuration.excluded_route_prefixes.any? { |p| name.downcase.start_with?(p) }
    end

    # {controller => deduped routes} for the app's own controllers. One
    # population for every surface that prints a route count, PUT/PATCH update
    # pairs merged, so every generated file and tool quotes one number.
    def app_controllers(routes)
      by_controller(routes)
        .reject { |name, _| framework_controller?(name) }
        .transform_values { |entries| dedupe_put_patch_routes(Array(entries)) }
    end

    def app_route_count(routes)
      app_controllers(routes).values.sum(&:size)
    end

    # A route can name a controller in an engine or plugin the controller listing never
    # scans, so the label is what lets a reader reconcile the two numbers.
    def controller_phrase(routes)
      CountPhrase.call(app_controllers(routes).size, "routed controller")
    end

    def framework_route_count(routes)
      by_controller(routes)
        .select { |name, _| framework_controller?(name) }
        .sum { |_, entries| dedupe_put_patch_routes(Array(entries)).size }
    end

    # Rails registers PATCH and PUT for one update action; every count and
    # listing merges the pair into one "PATCH|PUT" entry.
    def dedupe_put_patch_routes(actions)
      deduped = []
      actions.each do |r|
        # The controller is part of the key: two API versions on one path each have their own
        # PUT/PATCH pair. Grouped entries carry no :controller, so nil matches nil.
        existing = deduped.find do |d|
          d[:path] == r[:path] && d[:action] == r[:action] && d[:controller] == r[:controller]
        end
        if existing && %w[PUT PATCH].include?(r[:verb]) && %w[PUT PATCH].include?(existing[:verb])
          existing[:verb] = "PATCH|PUT"
        else
          deduped << r.dup
        end
      end
      deduped
    end

    def by_controller(routes)
      routes.is_a?(Hash) ? routes[:by_controller] || {} : {}
    end

    # {controller => routes} across the app's table and every engine's the app
    # draws into: what reaches a controller, as opposed to what the app counts.
    # An engine route carries `engine:` and its proxied name (`spree.admin_orders`).
    def all_by_controller(routes)
      merged = by_controller(routes).transform_values { |entries| Array(entries).dup }
      Array(routes.is_a?(Hash) ? routes[:engine_routes] : nil).each do |group|
        Array(group[:routes]).each do |route|
          (merged[route[:controller].to_s] ||= []) << route.except(:controller).merge(engine: group[:engine])
        end
      end
      merged
    end

    # A suffix rather than a predicate, so no call site needs a conditional of
    # its own - that shape is what let nine of them forget.
    #
    # @param routes [Hash] the :routes section of an introspection context
    # @return [String] a leading-comma clause naming what the count leaves out,
    #   or "" when the count is the whole table
    def suffix(routes)
      return "" unless Tools::SectionFetch.usable?(routes)

      parts = []
      unexpanded = routes[:dynamic_routes].to_i
      parts << "#{CountPhrase.call(unexpanded, 'dynamic construct')} not expanded" if unexpanded.positive?
      # An engine draws into its own table, mounted at boot, so the static walk cannot
      # place those paths; saying how many files it skipped keeps the count honest.
      unread = routes[:in_repo_route_files].to_i
      parts << "#{CountPhrase.call(unread, 'in-repo engine route file')} not read" if unread.positive?
      in_engines = Array(routes[:engine_routes]).sum { |group| Array(group[:routes]).size }
      parts << "#{in_engines} more in engine tables" if in_engines.positive?
      return "" if parts.empty?

      ", #{parts.join(', ')}"
    end
  end
end
